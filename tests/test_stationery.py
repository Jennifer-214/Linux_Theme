"""Palette assets and a read-only Caps Lock LED fixture; never lock the session."""
import os
import configparser
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
RENDER=ROOT/'src/fox-render/fox-render-fast'

@unittest.skipUnless(RENDER.exists(), 'build fox-render-fast first')
class Stationery(unittest.TestCase):
    def test_listing_theme_renders_for_every_palette(self):
        with tempfile.TemporaryDirectory() as tmp:
            for palette in (ROOT/'themes').glob('*/palette.sh'):
                dest=Path(tmp)/palette.parent.name
                subprocess.run([str(RENDER),str(palette),str(ROOT/'templates/eza'),str(dest)],check=True,capture_output=True)
                text=(dest/'theme.yml').read_text()
                self.assertNotIn('{{',text)
                theme=json.loads(text)
                if palette.parent.name=='FoxML_Paper':
                    self.assertEqual(len(theme['_foxml']['symlink']['glyph']),1)
                self.assertFalse(theme['header']['is_underline'])

    def test_caps_lock_tag_stays_above_entry_and_clear_of_cat(self):
        try:
            import gi
            gi.require_version('Pango','1.0');gi.require_version('PangoCairo','1.0')
            from gi.repository import Pango,PangoCairo
        except (ImportError, ValueError):
            self.skipTest('Pango is required to measure the rendered label')
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            subprocess.run([str(RENDER),str(ROOT/'themes/FoxML_Paper/palette.sh'),str(ROOT/'templates/hyprlock'),str(root/'lock')],check=True,capture_output=True)
            widgets=[(kind,body) for kind,body in re.findall(r'(?ms)^(label|input-field|image) \{\n(.*?)^\}',(root/'lock/hyprlock.conf').read_text())]
            caps=next(body for kind,body in widgets if kind=='label' and 'capslock-label.sh' in body)
            cat=next(body for kind,body in widgets if kind=='image' and 'paper-cat.png' in body)
            entry=next(body for kind,body in widgets if kind=='input-field')
            def value(body,key):return re.search(r'^\s*'+re.escape(key)+r'\s*=\s*(.+)$',body,re.M).group(1)
            def y(body):
                self.assertEqual(value(body,'valign'),'center')
                return float(value(body,'position').split(',')[1])
            leds=root/'leds/input3::capslock';leds.mkdir(parents=True);(leds/'brightness').write_text('1\n')
            markup=subprocess.check_output(['sh',str(root/'lock/capslock-label.sh'),str(leds.parent)],text=True)
            layout=Pango.Layout.new(PangoCairo.FontMap.get_default().create_context())
            layout.set_font_description(Pango.FontDescription(value(caps,'font_family')+' '+value(caps,'font_size')))
            layout.set_markup(markup,-1);tag_height=layout.get_pixel_size().height
            width,height=struct.unpack('>II',(ROOT/'shared/quickshell/foxml/paper-cat.png').read_bytes()[16:24])
            cat_height=height*float(value(cat,'size'))/min(width,height)
            field_height=float(value(entry,'size').split(',')[1])
            for screen_width,screen_height,scale in [(1920,1080,1),(1080,1920,1),(3840,2160,2),(2160,3840,2),(720,1280,1)]:
                def top(body,widget_height):return (screen_height/scale/2-y(body)-widget_height/2)*scale
                tag_bottom=top(caps,tag_height)+tag_height*scale
                self.assertGreaterEqual(top(entry,field_height)-tag_bottom,6*scale)
                self.assertGreaterEqual(top(cat,cat_height)-tag_bottom,100*scale)
                self.assertLessEqual(top(cat,cat_height)+cat_height*scale,screen_height)

    def test_mime_icons_resolve_and_keep_inherited_folders(self):
        try:
            import gi
            gi.require_version('Gtk','3.0')
            from gi.repository import Gtk,Gio
        except (ImportError, ValueError):
            self.skipTest('GTK is required for native icon lookup')
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);rendered=root/'rendered'
            subprocess.run([str(RENDER),str(ROOT/'themes/FoxML_Paper/palette.sh'),str(ROOT/'templates/icons'),str(rendered)],check=True,capture_output=True)
            target=root/'icons/FoxML-Paper';shutil.copytree(rendered/'foxml-paper',target)
            index=configparser.ConfigParser(interpolation=None);index.read(target/'index.theme')
            for owner,names in index['FoxML Aliases'].items():
                source=next(target.rglob(owner+'.svg'))
                for name in filter(None,names.split(',')):shutil.copy2(source,source.with_name(name+'.svg'))
            theme=Gtk.IconTheme.new();theme.prepend_search_path(str(root/'icons'));theme.set_custom_theme('FoxML-Paper')
            for mime in ['text/plain','text/markdown','application/pdf','application/zip','application/x-tar','application/gzip','application/x-7z-compressed']:
                icon=theme.lookup_by_gicon(Gio.content_type_get_icon(mime),48,0)
                self.assertIsNotNone(icon,mime)
                self.assertTrue(str(icon.get_filename()).startswith(str(target)),(mime,icon.get_filename()))
            emblem=theme.lookup_icon('emblem-symbolic-link',24,0)
            self.assertIsNotNone(emblem)
            self.assertTrue(str(emblem.get_filename()).startswith(str(target)))
            code=theme.lookup_by_gicon(Gio.content_type_get_icon('text/x-python'),48,0)
            if code:self.assertTrue(str(code.get_filename()).startswith(str(target)),code.get_filename())
            small=theme.lookup_by_gicon(Gio.content_type_get_icon('text/x-python'),16,0)
            self.assertEqual(small.get_filename(),code.get_filename())
            folder=theme.lookup_icon('folder',48,0)
            if folder:self.assertFalse(str(folder.get_filename()).startswith(str(target)),folder.get_filename())

    def test_caps_lock_tag_from_available_keyboards(self):
        with tempfile.TemporaryDirectory() as tmp:
            work=Path(tmp)
            subprocess.run([str(RENDER),str(ROOT/'themes/FoxML_Paper/palette.sh'),str(ROOT/'templates/hyprlock'),str(work/'lock')],check=True,capture_output=True)
            leds=work/'leds';leds.mkdir()
            script=work/'lock/capslock-label.sh'
            def tag():return subprocess.check_output(['sh',str(script),str(leds)],text=True)
            self.assertEqual(tag(),'')
            for index,value in [(3,'0\n'),(7,'1\n')]:
                keyboard=leds/f'input{index}::capslock';keyboard.mkdir();(keyboard/'brightness').write_text(value)
            self.assertEqual(tag().count('caps lock'),1)
            self.assertIn('bgcolor="#',tag())
            (leds/'input7::capslock/brightness').write_text('0\n')
            self.assertEqual(tag(),'')

    def test_icon_vectors_render_for_every_palette(self):
        with tempfile.TemporaryDirectory() as tmp:
            for palette in (ROOT/'themes').glob('*/palette.sh'):
                dest=Path(tmp)/palette.parent.name
                subprocess.run([str(RENDER),str(palette),str(ROOT/'templates/icons'),str(dest)],check=True,capture_output=True)
                for svg in dest.rglob('*.svg'):
                    self.assertNotIn('{{',svg.read_text())
                    ET.parse(svg)

if __name__=='__main__':unittest.main()
