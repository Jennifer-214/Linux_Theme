"""Verify the Paper search behavior using rendered templates and local Neovim."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / 'src/desk-render/desk-render-fast'


@unittest.skipUnless(RENDER.is_file() and shutil.which('nvim'), 'renderer and Neovim required')
class PaperSearch(unittest.TestCase):
    def test_all_palettes_parse_and_paper_search(self):
        with tempfile.TemporaryDirectory(prefix='paper-search-') as temp:
            work = Path(temp)
            for palette in sorted((ROOT / 'themes').glob('*/palette.sh')):
                output = work / palette.parent.name
                subprocess.run([str(RENDER), str(palette), str(ROOT / 'templates/nvim'), str(output)], check=True, capture_output=True)
                env = os.environ | {'PAPER_SEARCH_INIT': str(output / 'init.lua'),
                                    'XDG_STATE_HOME': str(work / 'state'),
                                    'XDG_CACHE_HOME': str(work / 'cache'),
                                    'NVIM_LOG_FILE': str(work / 'nvim.log')}
                check = subprocess.run(['nvim', '--clean', '--headless', '-c', 'lua assert(loadfile(vim.env.PAPER_SEARCH_INIT))', '-c', 'qa!'], env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
                if palette.parent.name == 'Paper' and (Path.home() / '.local/share/nvim/lazy/nvim-hlslens').is_dir():
                    check = subprocess.run(['nvim', '--clean', '--headless', '-l', str(ROOT / 'tests/paper_search.lua')], env=env, capture_output=True, text=True, timeout=15)
                    self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
                    self.assertIn('PAPER_SEARCH_OK', check.stdout + check.stderr)


if __name__ == '__main__':
    unittest.main()
