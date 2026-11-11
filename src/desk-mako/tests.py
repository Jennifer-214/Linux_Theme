"""Check the shape geometry and stock-compatible config without a live bus."""
from pathlib import Path
import os,shlex,shutil,subprocess,tempfile,unittest

ROOT=Path(__file__).resolve().parent
class PaperMako(unittest.TestCase):
    def test_stamp_tracks_aligned_text_at_both_scales_and_skips_wrapped_labels(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'build',prefix='stamp-') as temp:
            root=Path(temp);source=root/'stamp.c';binary=root/'stamp'
            source.write_text('''#include "paper-stamp.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 cairo_surface_t *s=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,800,400);
 cairo_t *c=cairo_create(s);PangoLayout *layout=pango_cairo_create_layout(c);
 for(int scale=1;scale<=2;scale++) {
  PangoFontDescription *font=pango_font_description_from_string("MonaspiceKr Nerd Font 9");
  pango_font_description_set_size(font,9*scale*PANGO_SCALE);
  pango_layout_set_font_description(layout,font);pango_font_description_free(font);
  pango_layout_set_width(layout,320*scale*PANGO_SCALE);
  pango_layout_set_alignment(layout,PANGO_ALIGN_CENTER);
  const char *labels[]={" RECEIVED "," SAVED "," COPIED "," READY "};
  for(int i=0;i<4;i++) {
   char text[80];snprintf(text,sizeof(text),"%s\\nA little note",labels[i]);
   pango_layout_set_text(layout,text,-1);PangoRectangle b;
   assert(foxml_stamp_bounds(layout,&b));
   double mid=(b.x+b.width/2.)/PANGO_SCALE;
   assert(mid>159*scale && mid<161*scale);
   foxml_stamp_frame(c,layout,10*scale,10*scale,0x3c3c40ff,scale);
  }
  pango_layout_set_text(layout,"A regular notification\\nNo stamp",-1);
  PangoRectangle b;assert(!foxml_stamp_bounds(layout,&b));
  pango_layout_set_text(layout," RECEIVED \\nA little note",-1);
  pango_layout_set_wrap(layout,PANGO_WRAP_WORD_CHAR);
  pango_layout_set_width(layout,15*scale*PANGO_SCALE);
  assert(!foxml_stamp_bounds(layout,&b));
 }
 g_object_unref(layout);cairo_destroy(c);cairo_surface_destroy(s);return 0;
}''')
            flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','pangocairo'],text=True))
            subprocess.run(['cc','-I'+str(ROOT),str(source),'-o',str(binary),*flags],check=True,capture_output=True)
            subprocess.run([str(binary)],check=True)

    def test_bootstrap_install_defers_build_and_preserves_the_installed_binary(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'build',prefix='bootstrap-') as temp:
            root=Path(temp);shutil.copy2(ROOT/'Makefile',root/'Makefile')
            prefix=root/'bin';prefix.mkdir();binary=prefix/'desk-mako';binary.write_text('old user binary')
            # No sources, compiler setup or downloaded archive in the fixture:
            # the pre-dependency umbrella install must leave this to --drawer.
            subprocess.run(['make','-C',str(root),'install','PREFIX='+str(prefix)],check=True,capture_output=True)
            self.assertEqual(binary.read_text(),'old user binary')
            self.assertFalse((root/'vendor').exists())

    def test_bar_bridge_tracks_output_height_and_clears_without_a_daemon(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'build',prefix='bridge-') as temp:
            root=Path(temp);source=root/'bridge.c';binary=root/'bridge'
            source.write_text('''#include "bar-bridge.h"
#include <assert.h>
int main(int argc,char **argv){
 struct mako_state state={0};wl_list_init(&state.surfaces);wl_list_init(&state.notifications);
 struct mako_output out={.name="portrait"};
 struct mako_surface surface={.surface_output=&out,.anchor=ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP};
 struct mako_notification n={.surface=&surface};n.style.foxml_paper_shape=1;
 wl_list_insert(&state.surfaces,&surface.link);wl_list_insert(&state.notifications,&n.link);
 setenv("FOXML_MAKO_BAR_GEOMETRY",argv[1],1);setenv("FOXML_MAKO_BANNER_STATE",argv[2],1);
 assert(foxml_banner_header(&state,&surface)==53);foxml_publish_banner(&state,false);
 FILE *f=fopen(argv[2],"r");char text[64]={0};assert(f);assert(fgets(text,sizeof(text),f));fclose(f);assert(strcmp(text,"portrait\\n")==0);
 n.style.invisible=true;assert(foxml_banner_header(&state,&surface)==0);foxml_publish_banner(&state,false);
 f=fopen(argv[2],"r");assert(fgetc(f)==EOF);fclose(f);
 n.style.invisible=false;surface.anchor=ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;assert(foxml_banner_header(&state,&surface)==0);
 return 0;
}''')
            geometry=root/'geometry';geometry.write_text('landscape 86\nportrait 53\n')
            flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','pangocairo','wayland-client','libsystemd'],text=True))
            subprocess.run(['cc','-D_POSIX_C_SOURCE=200809L','-DHAVE_LIBSYSTEMD','-I'+str(ROOT),'-I'+str(ROOT/'vendor/mako-1.11.0/include'),'-I'+str(ROOT/'build'),str(source),'-o',str(binary),*flags],check=True,capture_output=True)
            subprocess.run([str(binary),str(geometry),str(root/'state')],check=True)

    def test_outline_keeps_text_area_and_cuts_only_the_lower_edge(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'build',prefix='test-') as temp:
            root=Path(temp);source=root/'shape.c';binary=root/'shape'
            source.write_text('''#include "paper-edge.h"
#include <assert.h>
int main(void){
 cairo_surface_t *s=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,800,400);
 cairo_t *c=cairo_create(s);
 for(int scale=1;scale<=2;scale++){
  cairo_new_path(c);foxml_paper_path(c,0,0,360,150,scale,1);
  assert(cairo_in_fill(c,180*scale,60*scale));
  assert(cairo_in_fill(c,20*scale,148*scale));
  assert(!cairo_in_fill(c,180*scale,149*scale));
  assert(cairo_in_fill(c,180*scale,143*scale));
  cairo_new_path(c);foxml_paper_path(c,0,0,360,150,scale,2);
  assert(cairo_in_fill(c,180*scale,60*scale));
  assert(!cairo_in_fill(c,5*scale,151*scale));
 }
 cairo_destroy(c);cairo_surface_destroy(s);return 0;
}''')
            flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','cairo'],text=True))
            subprocess.run(['cc','-I'+str(ROOT),str(source),'-o',str(binary),*flags],check=True,capture_output=True)
            subprocess.run([str(binary)],check=True)

    def test_config_directives_are_optional_and_validated(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'config'
            env=os.environ|{'DBUS_SESSION_BUS_ADDRESS':'unix:path=/nonexistent-foxml-test','WAYLAND_DISPLAY':'nonexistent-foxml-test'}
            for shape in ['none','bookmark','receipt']:
                path.write_text('# foxml-paper-shape='+shape+'\ntext-alignment=center\n[app-name=fox-osd]\n# foxml-paper-shape=none\n')
                result=subprocess.run([str(ROOT/'desk-mako'),'-c',str(path)],env=env,capture_output=True,text=True,timeout=3)
                self.assertNotIn('Failed to parse option',result.stderr)
                self.assertNotIn('Invalid criteria',result.stderr)
                self.assertNotEqual(result.returncode,0,'Test must not connect to a live notification bus')
            path.write_text('# foxml-paper-shape=invalid\n')
            result=subprocess.run([str(ROOT/'desk-mako'),'-c',str(path)],env=env,capture_output=True,text=True,timeout=3)
            self.assertIn('Failed to parse option',result.stderr)
            for stamp in ['0','1','invalid']:
                path.write_text('# foxml-paper-stamp='+stamp+'\n')
                result=subprocess.run([str(ROOT/'desk-mako'),'-c',str(path)],env=env,capture_output=True,text=True,timeout=3)
                self.assertEqual('Failed to parse option' in result.stderr,stamp=='invalid')

if __name__=='__main__':unittest.main()
