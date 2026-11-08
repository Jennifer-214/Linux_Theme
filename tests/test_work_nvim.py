"""Exercise captured failures and editable drafts through the real headless Neovim module."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "src/fox-work/fox-work"


@unittest.skipUnless(shutil.which("nvim") and BIN.exists(), "build fox-work and install Neovim first")
class WorkNvim(unittest.TestCase):
    def test_quickfix_targets_selected_failure_and_draft_sends_only_after_recipient_selection(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            repo = folder / "repo"
            repo.mkdir()
            (repo / "a.cpp").write_text("int a;\nint b;\n")
            (repo / "b.cpp").write_text("int b;\n")
            env = dict(os.environ, XDG_STATE_HOME=str(folder / "state"), XDG_RUNTIME_DIR=str(folder / "runtime"),
                       PATH=str(BIN.parent) + os.pathsep + os.environ["PATH"], FOXML_WORK_NOTIFY="0",
                       TEST_WORK_LUA=str(ROOT / "shared/nvim_lua"), NVIM_LOG_FILE=str(folder / "nvim.log"))
            Path(env["XDG_RUNTIME_DIR"]).mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True, env=env)
            p = subprocess.run([str(BIN), "run", "--", sys.executable, "-c",
                                "import sys; print('a.cpp:2: failure one\\nb.cpp:1: failure two\\n1 passed, 2 failed'); sys.exit(1)"],
                               cwd=repo, env=env, capture_output=True, text=True)
            self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
            script = folder / "exercise.lua"
            script.write_text(r'''
package.path = vim.env.TEST_WORK_LUA .. "/?.lua;" .. package.path
vim.g.mapleader = ' '
local W, C = require('foxml.work'), require('foxml.claude')
W.tests(nil, 2)
local qf = vim.fn.getqflist({items=0,idx=0})
assert(#qf.items == 2 and qf.idx == 2, vim.inspect(qf))
assert(vim.api.nvim_buf_get_name(0):match('/b.cpp$'))
local draft = 'Please inspect this failure.\n' .. string.rep('log detail\n', 500)
W.draft(draft)
assert(vim.fn.isdirectory(C.runtime() .. '/inbox') == 0, 'opening a draft sent it')
local original = vim.system
vim.system = function(argv, opts)
  if argv[1] == 'fox-drawer' then return {wait=function() return {code=0,stdout=vim.json.encode({{id='abc',name='test session',project='repo',state='waiting'}})} end} end
  return original(argv, opts)
end
local selected = false
vim.ui.select = function(rows, opts, callback) selected = true; callback(rows[1]) end
local map = vim.fn.maparg('<Space>ws', 'n', false, true)
assert(type(map.callback) == 'function', 'send mapping missing')
map.callback()
assert(selected, 'recipient selection was skipped')
local box = C.runtime() .. '/inbox/abc'
local entries = vim.fn.readdir(box)
assert(#entries == 1)
local note = vim.json.decode(C.read(box .. '/' .. entries[1]))
assert(#note.text <= 2000 and note.text .. note.code == draft:gsub('\n$', ''), 'draft was truncated')
print('work nvim: quickfix and explicit draft delivery passed')
''')
            checked = subprocess.run(["nvim", "--headless", "-u", "NONE", "-l", str(script)],
                                     cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)


if __name__ == "__main__":
    unittest.main()
