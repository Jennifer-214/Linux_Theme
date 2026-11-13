"""Exercise real filesystem kinds without interpreting eza's terminal output."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent


class Listing(unittest.TestCase):
    def setUp(self):
        # /tmp may be noexec; the fake child executable stays in the workspace.
        self.tmp = tempfile.TemporaryDirectory(prefix='.fixture-', dir=ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        child = self.bin / 'eza'
        child.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
folder=Path(os.environ['EZA_CONFIG_DIR'])
print(json.dumps({'argv':sys.argv[1:],'theme':(folder/'theme.yml').read_text(),'dir':str(folder)}))
sys.exit(int(os.environ.get('FAKE_EXIT','0')))
''')
        child.chmod(0o755)
        self.config = self.root / 'config'
        subprocess.run([str(REPO/'src/desk-render/desk-render-fast'), str(REPO/'themes/Paper/palette.sh'), str(REPO/'templates/eza'), str(self.config)], check=True, capture_output=True)
        self.env = os.environ | {'PATH':str(self.bin)+':'+os.environ['PATH'], 'EZA_CONFIG_DIR':str(self.config), 'TMPDIR':str(self.root)}
        self.desk = self.root / 'desk'
        self.desk.mkdir()

    def call(self, *args, code=0):
        result = subprocess.run([str(ROOT/'desk-eza'), *args], cwd=self.desk, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stderr)
        report = json.loads(result.stdout)
        if report['dir'] != str(self.config):
            self.assertFalse(Path(report['dir']).exists(), 'temporary theme leaked')
        return report

    def test_links_and_escaped_names_get_real_kinds(self):
        (self.desk/'notes.txt').write_text('hello')
        for name, target in [('a "quoted" note', 'notes.txt'), ('café', 'notes.txt'), ('broken', 'missing')]:
            (self.desk/name).symlink_to(target)
        before = (self.config/'theme.yml').read_bytes()
        report = self.call('-lh', '--icons=always', '--', '.')
        theme = json.loads(report['theme'])
        for name in ['a "quoted" note', 'café', 'broken']:
            self.assertEqual(theme['filenames'][name]['icon']['glyph'], '\uf0c6')
        self.assertEqual(theme['filenames']['notes.txt']['icon']['glyph'], '\uf0f6')
        self.assertEqual(report['argv'], ['-lh', '--icons=always', '--', '.'])
        self.assertEqual((self.config/'theme.yml').read_bytes(), before)

    def test_colliding_names_never_label_regular_files_as_links(self):
        for name in ['a', 'b']:
            (self.desk/name).mkdir()
        (self.desk/'a/page').symlink_to('missing')
        (self.desk/'b/page').write_text('real file')
        theme = json.loads(self.call('-T', '--level=2', '.')['theme'])
        self.assertNotIn('page', theme['filenames'])

    def test_directories_keep_folder_icons_even_with_a_file_extension(self):
        (self.desk/'notes.md').mkdir()
        theme = json.loads(self.call('.')['theme'])
        self.assertEqual(theme['filenames']['notes.md']['icon']['glyph'], '\uf07b')

    def test_personal_folder_badges_require_actual_directories(self):
        (self.desk/'Documents').mkdir()
        (self.desk/'Projects').mkdir()
        (self.desk/'Pictures').write_text('a file, not a folder')
        (self.desk/'Downloads').symlink_to('Documents')
        theme=json.loads(self.call('.')['theme'])
        self.assertEqual(theme['filenames']['Documents']['icon']['glyph'], '\uf0f6')
        self.assertEqual(theme['filenames']['Projects']['icon']['glyph'], '\uf121')
        self.assertEqual(theme['filenames']['Downloads']['icon']['glyph'], '\uf0c6')
        self.assertNotEqual(theme['filenames']['Pictures']['icon'].get('glyph'), '\uf03e')

    def test_depth_and_directory_links_do_not_trigger_extra_walks(self):
        (self.desk/'folder').mkdir()
        (self.desk/'folder/link').symlink_to('missing')
        (self.desk/'loop').symlink_to('.')
        shallow = json.loads(self.call('-T', '-L1', '.')['theme'])
        self.assertNotIn('link', shallow['filenames'])
        deeper = json.loads(self.call('-T', '-L2', '.')['theme'])
        self.assertEqual(deeper['filenames']['link']['icon']['glyph'], '\uf0c6')
        self.assertEqual(deeper['filenames']['loop']['icon']['glyph'], '\uf0c6')

    def test_unrecognized_options_and_invalid_themes_pass_through(self):
        self.env['FAKE_EXIT'] = '17'
        report = self.call('--future-option', 'a space', code=17)
        self.assertEqual(report['dir'], str(self.config))
        self.assertEqual(report['argv'], ['--future-option', 'a space'])
        (self.config/'theme.yml').write_text('a custom YAML theme: true\n')
        self.assertEqual(self.call('.', code=17)['dir'], str(self.config))

    @unittest.skipUnless(shutil.which('eza'), 'native eza required')
    def test_actual_eza_uses_note_and_link_glyphs_without_underlines(self):
        (self.desk/'notes.txt').write_text('hello')
        (self.desk/'link').symlink_to('notes.txt')
        env = self.env | {'PATH':os.environ['PATH'], 'EZA_COLORS':'reset', 'EZA_ICON_SPACING':'3', 'LS_COLORS':'', 'EXA_COLORS':''}
        result = subprocess.run([str(ROOT/'desk-eza'), '-lh', '--icons=always', '--color=always', '.'], cwd=self.desk, env=env, capture_output=True, text=True, check=True)
        self.assertIn('\uf0c6', result.stdout)
        self.assertIn('\uf0f6', result.stdout)
        color=json.loads((self.config/'theme.yml').read_text())['_foxml']['icon']['style']['foreground'].lstrip('#')
        ansi=';'.join(str(int(color[i:i+2],16)) for i in (0,2,4))
        self.assertIn(ansi, result.stdout)
        self.assertNotIn('\x1b[4;', result.stdout)


if __name__ == '__main__':
    unittest.main()
