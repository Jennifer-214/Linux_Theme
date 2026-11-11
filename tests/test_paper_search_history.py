"""Search styles must leave machine output and user configuration intact."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT/'src/desk-render/desk-render-fast'

@unittest.skipUnless(RENDER.exists(), 'build desk-render-fast first')
class SearchHistory(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def render(self, theme, app):
        dest = self.root/theme/app
        subprocess.run([str(RENDER),str(ROOT/'themes'/theme/'palette.sh'),str(ROOT/'templates'/app),str(dest)],check=True,capture_output=True)
        return dest

    def test_all_palettes_render_valid_search_git_and_yazi_configs(self):
        for palette in (ROOT/'themes').glob('*/palette.sh'):
            theme = palette.parent.name
            search = (self.render(theme,'ripgrep')/'config').read_text()
            self.assertNotIn('{{',search)
            self.assertTrue(all(line.startswith(('#','--colors=')) for line in search.splitlines() if line))
            yazi = tomllib.loads((self.render(theme,'yazi')/'theme.toml').read_text())
            self.assertNotEqual(yazi['mgr']['marker_cut'],yazi['mgr']['marker_copied'])
            git = self.render(theme,'git')/'delta.gitconfig'
            pretty = subprocess.check_output(['git','config','--file',str(git),'--get','pretty.paper'],text=True)
            self.assertIn('%s',pretty)
            self.assertNotIn('{{',pretty)
            qt=json.loads((self.render(theme,'qt')/'gtk-palette.json').read_text())
            self.assertIn('Highlight',qt['QtGtk3Palettes']['SystemPalette'])

    @unittest.skipUnless(shutil.which('rg'), 'ripgrep required')
    def test_search_colors_do_not_change_json_results(self):
        config = self.render('FoxML_Paper','ripgrep')/'config'
        sample = self.root/'a note.txt'
        sample.write_text('a note\nanother note\n')
        base = os.environ.copy()
        base.pop('RIPGREP_CONFIG_PATH',None)
        def run(env):
            text = subprocess.check_output(['rg','--json','note',str(sample)],env=env,text=True)
            self.assertNotIn('\x1b',text)
            return [x for x in map(json.loads,text.splitlines()) if x['type']=='match']
        self.assertEqual(run(base),run(base|{'RIPGREP_CONFIG_PATH':str(config)}))

    @unittest.skipUnless(shutil.which('zsh'), 'zsh required')
    def test_custom_ripgrep_config_is_preserved(self):
        colors = self.render('FoxML_Paper','zsh')/'colors.zsh'
        env = os.environ|{'RIPGREP_CONFIG_PATH':str(self.root/'custom-search'),'XDG_CONFIG_HOME':str(self.root/'config')}
        result = subprocess.check_output(['zsh','-f','-c','source "$1"; print -r -- "$RIPGREP_CONFIG_PATH"','check',str(colors)],env=env,text=True)
        self.assertEqual(result.strip(),env['RIPGREP_CONFIG_PATH'])

    def test_paper_footer_has_light_surfaces_and_readable_ink(self):
        theme = tomllib.loads((self.render('FoxML_Paper','yazi')/'theme.toml').read_text())
        def luminance(color):
            rgb = [int(color[i:i+2],16)/255 for i in (1,3,5)]
            linear = [c/12.92 if c <= .04045 else ((c+.055)/1.055)**2.4 for c in rgb]
            return sum(c*w for c,w in zip(linear,(.2126,.7152,.0722)))
        # The pink labels go no paler than #e8becd, the palest pink that still reads on a bright 4K panel.
        proven = luminance('#e8becd')
        for name, style in theme['mode'].items():
            bg,fg = luminance(style['bg']),luminance(style['fg'])
            self.assertGreater(bg,.4,name)
            self.assertGreaterEqual((bg+.05)/(fg+.05),4.5,name)
            if name.endswith('_main'):
                self.assertLessEqual(bg,proven+1e-9,name)

if __name__ == '__main__':
    unittest.main()
