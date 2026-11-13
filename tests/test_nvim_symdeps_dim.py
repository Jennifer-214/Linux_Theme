"""Every theme defines FoxSymdepsDim itself: the symdeps plugin only links it lazily, and never from the palette."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / 'src/desk-render/desk-render-fast'


@unittest.skipUnless(RENDER.exists() and shutil.which('nvim'), 'build desk-render-fast and install Neovim first')
class SymdepsDim(unittest.TestCase):
    def test_each_theme_sets_the_dim_group_from_its_palette_and_again_after_a_colorscheme_change(self):
        with tempfile.TemporaryDirectory(prefix='foxml-dim-') as temp:
            for palette in sorted((ROOT / 'themes').glob('*/palette.sh')):
                with self.subTest(theme=palette.parent.name):
                    out = Path(temp) / palette.parent.name
                    subprocess.run([str(RENDER), str(palette), str(ROOT / 'templates/nvim'), str(out)], check=True, capture_output=True)
                    driver = Path(temp) / 'dim.lua'
                    driver.write_text('''
local source = assert(io.open(''' + json.dumps(str(out / 'init.lua')) + ''')):read('*a')
local palette = assert(source:match('(local P = %b{})'), 'the palette table')
local first = assert(source:find('local function apply_foxml_theme()', 1, true))
local last = assert(source:find('\\nend\\n', first, true))
local apply = assert(loadstring(palette .. '\\nlocal Paper = { enabled = false }\\n' .. source:sub(first, last + 4) .. '\\nreturn { P = P, apply = apply_foxml_theme }'))()
apply.apply()
local function dim() return vim.api.nvim_get_hl(0, { name = 'FoxSymdepsDim' }) end
local want = tonumber(apply.P.comment:sub(2), 16)
assert(dim().fg == want and not dim().italic and not dim().link, 'set from the palette: ' .. vim.inspect(dim()))
-- the plugin's own lazy definition must not replace it
vim.api.nvim_set_hl(0, 'FoxSymdepsDim', { default = true, link = 'Comment' })
assert(dim().fg == want and not dim().link, 'a default link leaves it alone')
vim.cmd('highlight clear')
assert(dim().fg ~= want, 'cleared, as a colorscheme change does')
apply.apply()
assert(dim().fg == want, 'and set again')
vim.cmd('qa!')
''')
                    ran = subprocess.run(['nvim', '--clean', '--headless', '-l', str(driver)],
                                         env=os.environ | {'NVIM_LOG_FILE': str(Path(temp) / 'nvim.log')}, capture_output=True, text=True, timeout=20)
                    self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)


if __name__ == '__main__':
    unittest.main()
