#!/usr/bin/env python3
"""Build a checksum-pinned Mako with a small optional paper-outline extension.

Use its existing C compiler/library dependencies directly; no vendored Meson,
Ninja, Python modules, or replacement notification protocol implementation.
"""
from pathlib import Path
import hashlib, os, shlex, shutil, subprocess, sys, tarfile, urllib.request

ROOT=Path(__file__).resolve().parent
VENDOR=ROOT/'vendor'
SOURCE=VENDOR/'mako-1.11.0'
URL='https://codeload.github.com/emersion/mako/tar.gz/refs/tags/v1.11.0'
SHA256='72d11d3fca20a3dfbca0107ff875eace479751be0cf2ddd1dd5bafa131ac7282'

def replace(name, old, new):
    p=SOURCE/name;s=p.read_text()
    if s.count(old)!=1:raise RuntimeError('Upstream patch anchor changed: '+name)
    p.write_text(s.replace(old,new,1))

def prepare():
    VENDOR.mkdir(exist_ok=True)
    archive=VENDOR/'upstream.tar.gz'
    if not archive.exists():
        with urllib.request.urlopen(URL,timeout=30) as response:data=response.read(2_000_000)
        if hashlib.sha256(data).hexdigest()!=SHA256:raise RuntimeError('Mako source checksum mismatch')
        archive.write_bytes(data)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=SHA256:raise RuntimeError('Mako source checksum mismatch')
    if SOURCE.exists():shutil.rmtree(SOURCE)
    with tarfile.open(archive) as tar:tar.extractall(VENDOR,filter='data')
    shutil.copyfile(ROOT/'paper-edge.h',SOURCE/'include/foxml-paper.h')
    shutil.copyfile(ROOT/'bar-bridge.h',SOURCE/'include/foxml-bar-bridge.h')
    replace('include/config.h','\tint32_t border_size;','\tint32_t border_size;\n\tint32_t foxml_paper_shape;')
    replace('include/config.h','\tbool touch_binding, notify_binding;','\tbool touch_binding, notify_binding;\n\tbool foxml_paper_shape;')
    replace('config.c','\tstyle->border_size = 2;','\tstyle->border_size = 2;\n\tstyle->foxml_paper_shape = 0;')
    replace('config.c','\t// Now on to actually setting things!', '''\t// Now on to actually setting things!
    if (style->spec.foxml_paper_shape) {
        target->foxml_paper_shape = style->foxml_paper_shape;
        target->spec.foxml_paper_shape = true;
    }''')
    replace('config.c','\tif (strcmp(name, "font") == 0) {','''    if (strcmp(name, "foxml-paper-shape") == 0) {
        if (strcmp(value, "none") == 0) style->foxml_paper_shape = 0;
        else if (strcmp(value, "bookmark") == 0) style->foxml_paper_shape = 1;
        else if (strcmp(value, "receipt") == 0) style->foxml_paper_shape = 2;
        else return false;
        return spec->foxml_paper_shape = true;
    } else if (strcmp(name, "font") == 0) {''')
    # Stock Mako ignores these comments. This binary interprets only this one
    # namespaced directive, in the normal per-criterion config/reload flow.
    replace('config.c',"\t\tif (stripped_line[0] == '\\0' || stripped_line[0] == '\\n' ||",'''        if (strncmp(stripped_line, "# foxml-paper-shape=", 19) == 0) {
            stripped_line += 2;
            len -= 2;
        }
\t\tif (stripped_line[0] == '\\0' || stripped_line[0] == '\\n' ||''')
    replace('render.c','#include "render.h"','#include "render.h"\n#include "foxml-paper.h"\n#include "foxml-bar-bridge.h"\nstatic bool foxml_ribbon_contents = false;')
    # A centered Pango layout already aligns text inside its configured width.
    # The vertical-icon centering offset would otherwise be applied twice.
    replace('render.c','\t// Render text\n','''    if (icon_vertical && style->text_alignment == PANGO_ALIGN_CENTER) {
        text_x = style->padding.left;
    }
\t// Render text
''')
    replace('wayland.c','#include "render.h"','#include "render.h"\n#include "foxml-bar-bridge.h"')
    replace('wayland.c','\t\tzwlr_layer_surface_v1_set_size(surface->layer_surface, width, height);','''        zwlr_layer_surface_v1_set_exclusive_zone(surface->layer_surface,
            foxml_banner_header(state, surface) ? -1 : 0);
\t\tzwlr_layer_surface_v1_set_size(surface->layer_surface, width, height);''')
    replace('main.c','#include "render.h"','#include "render.h"\n#include "foxml-bar-bridge.h"')
    replace('main.c','\tfinish(&state);','\tfoxml_publish_banner(&state, true);\n\tfinish(&state);')
    replace('render.c','\tint notif_background_width = notif_width - style->border_size;','''    bool paper = style->foxml_paper_shape != 0 && style->border_size > 0;
    int notif_background_width = notif_width - style->border_size - (paper ? 3 : 0);''')
    old='''\tset_rounded_rectangle(cairo,
\t\toffset_x + style->border_size / 2.0,
\t\toffset_y + style->border_size / 2.0,
\t\tnotif_background_width,
\t\tnotif_height - style->border_size,
\t\tscale, radius_top_left, radius_top_right, radius_bottom_right, radius_bottom_left);'''
    replace('render.c',old,'''    if (paper) {
        double x = offset_x + style->border_size / 2.0;
        double y = offset_y + style->border_size / 2.0;
        double h = notif_height - style->border_size - 4;
        cairo_save(cairo);
        cairo_translate(cairo, 2 * scale, 3 * scale);
        foxml_paper_path(cairo, x, y, notif_background_width, h, scale, style->foxml_paper_shape);
        uint32_t ink = style->colors.text;
        cairo_set_source_rgba(cairo, (ink >> 24 & 255) / 255.0,
            (ink >> 16 & 255) / 255.0, (ink >> 8 & 255) / 255.0, .055);
        cairo_fill(cairo);
        cairo_restore(cairo);
        foxml_paper_path(cairo, x, y, notif_background_width, h, scale, style->foxml_paper_shape);
    } else {
'''+old+'\n    }')
    # Render the normal notification contents onto one shared paper surface.
    # Compact OSDs (shape=none) retain upstream rendering, including progress.
    replace('render.c','    bool paper = style->foxml_paper_shape', '    if (!foxml_ribbon_contents || style->foxml_paper_shape == 0) {\n    bool paper = style->foxml_paper_shape')
    replace('render.c','\tcairo_path_destroy(border_path);','''\tcairo_path_destroy(border_path);
    } else if (progress >= 0) {
        set_source_u32(cairo, style->colors.progress.value);
        double amount = progress < 0 ? 0 : progress > 100 ? 1 : progress / 100.0;
        cairo_rectangle(cairo, (offset_x + style->padding.left) * scale,
            (offset_y + notif_height - 8) * scale,
            (notif_width - padding_width) * amount * scale, 2 * scale);
        cairo_fill(cairo);
    }''')
    replace('render.c','\t*rendered_width = *rendered_height = 0;','''\t*rendered_width = *rendered_height = 0;
    foxml_publish_banner(state, false);''')
    replace('render.c','\tint total_height = 0;','''    int header = foxml_banner_header(state, surface);
    bool ribbon = header > 0;
    if (ribbon) cairo_push_group(cairo);
    foxml_ribbon_contents = ribbon;
\tint total_height = header;''')
    replace('render.c','\t*rendered_width = max_width;','''    foxml_ribbon_contents = false;
    if (ribbon) {
        cairo_pattern_t *contents = cairo_pop_group(cairo);
        struct mako_style *base = &global_criteria(&state->config)->style;
        double x = surface->width - max_width + base->margin.left + .5;
        double width = max_width - base->margin.left - base->margin.right - 4;
        if (visible_count > 0 && width > 0) {
            cairo_save(cairo);cairo_translate(cairo, 2 * scale, 3 * scale);
            foxml_paper_path(cairo,x,0,width,total_height-4,scale,1);
            uint32_t ink=base->colors.text;
            cairo_set_source_rgba(cairo,(ink>>24&255)/255.0,(ink>>16&255)/255.0,(ink>>8&255)/255.0,.055);
            cairo_fill(cairo);cairo_restore(cairo);
            foxml_paper_path(cairo,x,0,width,total_height-4,scale,1);
            set_source_u32(cairo,base->colors.background);cairo_fill_preserve(cairo);
            set_source_u32(cairo,base->colors.border);cairo_set_line_width(cairo,base->border_size*scale);cairo_stroke(cairo);
        }
        cairo_set_source(cairo,contents);cairo_paint(cairo);cairo_pattern_destroy(contents);
    }
\t*rendered_width = max_width;''')
    (VENDOR/'.ready').write_text(SHA256+'\n')

def build():
    generated=ROOT/'build';generated.mkdir(exist_ok=True)
    protos=Path(subprocess.check_output(['pkg-config','--variable=pkgdatadir','wayland-protocols'],text=True).strip())
    xmls=[protos/'stable/xdg-shell/xdg-shell.xml',protos/'staging/cursor-shape/cursor-shape-v1.xml',protos/'staging/xdg-activation/xdg-activation-v1.xml',protos/'unstable/tablet/tablet-unstable-v2.xml',SOURCE/'protocol/wlr-layer-shell-unstable-v1.xml']
    protocols=[]
    for xml in xmls:
        name=xml.stem
        for kind,suffix in [('client-header','-client-protocol.h'),('private-code','-protocol.c')]:
            subprocess.run(['wayland-scanner',kind,str(xml),str(generated/(name+suffix))],check=True)
        protocols.append(str(generated/(name+'-protocol.c')))
    libs=['cairo','pangocairo','glib-2.0','gobject-2.0','wayland-client','wayland-cursor','gdk-pixbuf-2.0','libsystemd']
    flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs',*libs],text=True))
    names=['config.c','event-loop.c','dbus/dbus.c','dbus/mako.c','dbus/xdg.c','main.c','mode.c','notification.c','pool-buffer.c','render.c','wayland.c','criteria.c','types.c','surface.c','icon.c','string-util.c','cairo-pixbuf.c']
    command=shlex.split(os.environ.get('CC','cc'))+['-std=c11','-O2','-Wall','-Wextra','-Wno-unused-parameter','-Wno-missing-braces','-D_POSIX_C_SOURCE=200809L','-DHAVE_LIBSYSTEMD','-DHAVE_ICONS','-I'+str(SOURCE/'include'),'-I'+str(generated),'-o',str(ROOT/'fox-mako')]+[str(SOURCE/n) for n in names]+protocols+flags+['-lrt','-lm']
    subprocess.run(command,check=True)

if __name__=='__main__':
    if '--build' in sys.argv:build()
    else:prepare()
