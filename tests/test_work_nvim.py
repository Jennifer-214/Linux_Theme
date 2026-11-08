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
    def test_notebook_diff_uses_session_before_copy_and_all_changes_use_head(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            repo = folder / 'repo'
            repo.mkdir()
            source = repo / "a ' quote.cpp"
            source.write_text('int committed = 1;\n')
            env = dict(os.environ, XDG_STATE_HOME=str(folder / 'state'), XDG_RUNTIME_DIR=str(folder / 'runtime'),
                       PATH=str(BIN.parent) + os.pathsep + os.environ['PATH'], FOXML_WORK_NOTIFY='0',
                       TEST_WORK_LUA=str(ROOT / 'shared/nvim_lua'), TEST_SOURCE=str(source), NVIM_LOG_FILE=str(folder / 'nvim.log'))
            for args in [('init', '-q'), ('add', '.'), ('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'initial')]:
                subprocess.run(['git', *args], cwd=repo, env=env, check=True, capture_output=True)
            before = folder / 'runtime/foxml-claude/edits/abc/before'
            before.mkdir(parents=True)
            (before / '1.txt').write_text('int preexisting_edit = 2;\n')
            (before.parent.parent / 'abc.json').write_text(json.dumps({'before': {str(source): '1.txt'}}))
            source.write_text('int session_edit = 3;\n')
            script = folder / 'diff.lua'
            script.write_text(r'''
package.path = vim.env.TEST_WORK_LUA .. '/?.lua;' .. package.path
package.loaded['foxml.work'] = dofile(vim.env.TEST_WORK_LUA .. '/foxml/work.lua')
package.loaded['foxml.claude'] = dofile(vim.env.TEST_WORK_LUA .. '/foxml/claude.lua')
local W = require('foxml.work')
local path = vim.env.TEST_SOURCE
local original = vim.fn.argv
vim.fn.argv = function() return {'foxml-work:file-diff', path, 'abc'} end
W.open_args()
assert(vim.wo.diff, 'notebook did not open a diff')
assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') == 'int preexisting_edit = 2;', 'session diff lost the preexisting work')
vim.fn.argv = function() return {'foxml-work:file-diff', path, ''} end
W.open_args()
assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') == 'int committed = 1;', 'all-changes diff did not use HEAD')
vim.fn.argv = function() return {'foxml-work:file', path} end
W.open_args()
assert(vim.api.nvim_buf_get_name(0) == path, 'editor changed the literal filename')
vim.fn.argv = original
''')
            checked = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-l', str(script)],
                                     cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)

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
package.loaded["foxml.work"] = dofile(vim.env.TEST_WORK_LUA .. "/foxml/work.lua")
package.loaded["foxml.claude"] = dofile(vim.env.TEST_WORK_LUA .. "/foxml/claude.lua")
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
