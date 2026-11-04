"""One icon definition must drive glyphs, MIME aliases and palette-rendered vectors."""
import configparser
import json
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
RENDER=ROOT/'src/fox-render/fox-render-fast'

@unittest.skipUnless(RENDER.exists(),'build the renderer first')
class IconFamily(unittest.TestCase):
    def test_consumers_share_each_family(self):
        with tempfile.TemporaryDirectory() as temp:
            dest=Path(temp)
            subprocess.run([str(RENDER),str(ROOT/'themes/FoxML_Paper/palette.sh'),str(ROOT/'templates'),str(dest)],check=True,capture_output=True)
            family=json.loads((dest/'icons/icon-family.json').read_text())
            self.assertEqual(family['accent'],family['ink'])
            self.assertFalse((dest/'icons/foxml-paper/16x16').exists())
            eza=json.loads((dest/'eza/theme.yml').read_text())
            yazi=tomllib.loads((dest/'yazi/theme.toml').read_text())
            extensions={item['name']:item for item in yazi['icon']['exts']}
            aliases=configparser.ConfigParser(interpolation=None);aliases.read(dest/'icons/foxml-paper/index.theme')
            for item in family['families']:
                vector=dest/'icons/foxml-paper/scalable/mimetypes'/(item['asset']+'.svg')
                ET.parse(vector)
                self.assertNotIn('{{',vector.read_text())
                for ext in item['extensions']:
                    self.assertEqual(eza['extensions'][ext]['icon']['glyph'],item['glyph'])
                    self.assertEqual(extensions[ext]['text'].rstrip(),item['glyph'])
                    expected=family['muted'] if item.get('muted') else family['ink']
                    self.assertEqual(extensions[ext]['fg'],expected)
                    self.assertEqual(eza['extensions'][ext]['icon']['style']['foreground'],expected)
                for mime in item['mimes']:
                    icon=mime.replace('/','-')
                    self.assertTrue(icon==item['asset'] or icon in aliases['FoxML Aliases'][item['asset']].split(','),(mime,item['asset']))
            self.assertEqual(eza['_foxml']['directory']['glyph'],family['directory']['glyph'])
            self.assertIn(family['symlink']['glyph'],(dest/'yazi/init.lua').read_text())
            self.assertEqual(yazi['input']['selected']['bg'],family['blush'])
            self.assertFalse(yazi['help']['hovered'].get('reversed',False))

    def test_shell_and_native_renderer_generate_identical_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);native=root/'native';shell=root/'shell'
            args=[str(ROOT/'themes/FoxML_Paper/palette.sh'),str(ROOT/'templates'),str(native)]
            subprocess.run([str(RENDER),*args],check=True,capture_output=True)
            subprocess.run(['bash',str(ROOT/'render.sh'),*args[:-1],str(shell)],check=True,capture_output=True)
            for app in ['eza','yazi','icons']:
                for file in (native/app).rglob('*'):
                    if file.is_file():self.assertEqual(file.read_bytes(),(shell/file.relative_to(native)).read_bytes(),str(file))

if __name__=='__main__':unittest.main()
