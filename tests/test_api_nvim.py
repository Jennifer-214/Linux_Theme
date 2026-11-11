"""The Neovim side of API tasks: an answer's path:line citations become a quickfix list and keys on the result."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NVIM = shutil.which('nvim')

DRIVER = r'''
package.path = vim.env.WORK_LUA .. '/?.lua;' .. package.path
local work = require('foxml.work')
local folder = vim.env.PROJECT
local items = work.api_citations({'See src/a.cpp:2 and src/a.cpp:2 again.', 'Missing: nope.cpp:4', 'Also ' .. folder .. '/b.h:1.'}, folder)
assert(#items == 2, 'expected the two readable, de-duplicated citations, got ' .. #items)
assert(items[1].filename == folder .. '/src/a.cpp' and items[1].lnum == 2)
assert(items[2].filename == folder .. '/b.h' and items[2].lnum == 1)
local md = {'# Why is a slow?', '', '- Project: Trader · folder: ' .. folder,
            '- completed · claude-sonnet-5-5 · $0.12 estimated · budget $1.00', '- Task ID: ' .. string.rep('c', 32), '',
            'The loop at src/a.cpp:2 copies.'}
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, md)
vim.api.nvim_set_current_buf(buf)
work.api_result_opened(buf)
local qf = vim.fn.getqflist({title=1, items=1})
assert(qf.title == 'API answer citations' and #qf.items == 1, vim.inspect(qf))
assert(vim.bo[buf].filetype == 'markdown' and not vim.bo[buf].modifiable)
assert(vim.fn.maparg('f', 'n', false, true).desc == 'Ask a follow-up', 'follow-up key missing')
vim.api.nvim_win_set_cursor(0, {7, 0})
vim.fn.maparg('<CR>', 'n', false, true).callback()
assert(vim.api.nvim_buf_get_name(0) == folder .. '/src/a.cpp' and vim.api.nvim_win_get_cursor(0)[1] == 2, 'Enter did not jump')
print('API_NVIM_PASSED')
'''


@unittest.skipUnless(NVIM, 'nvim is not installed')
class ApiNvim(unittest.TestCase):
    def test_citations_quickfix_and_result_keys(self):
        # Not /tmp: it is noexec here, and the fake claude-api must run.
        with tempfile.TemporaryDirectory(prefix='.api-nvim-', dir=ROOT/'tests') as temp:
            base = Path(temp)
            project = base/'project'
            (project/'src').mkdir(parents=True)
            (project/'src/a.cpp').write_text('int a;\nint b;\n')
            (project/'b.h').write_text('int c;\n')
            bins = base/'bin'
            bins.mkdir()
            (bins/'claude-api').write_text('#!/bin/sh\n[ "$1" = history ] && echo \'[{"id":"' + 'c'*32 + '","project":"trader"}]\'\n')
            (bins/'claude-api').chmod(0o755)
            (base/'driver.lua').write_text(DRIVER)
            env = dict(os.environ, PATH=str(bins)+os.pathsep+os.environ['PATH'], PROJECT=str(project),
                       WORK_LUA=str(ROOT/'shared/nvim_lua'), XDG_STATE_HOME=str(base/'state'), XDG_CACHE_HOME=str(base/'cache'),
                       NVIM_LOG_FILE=str(base/'nvim.log'))
            result = subprocess.run([NVIM, '--clean', '--headless', '-l', str(base/'driver.lua')], env=env,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('API_NVIM_PASSED', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
