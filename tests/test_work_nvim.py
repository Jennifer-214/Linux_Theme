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
BIN = ROOT / "src/desk-work/desk-work"


@unittest.skipUnless(shutil.which("nvim") and BIN.exists(), "build desk-work and install Neovim first")
class WorkNvim(unittest.TestCase):
    def test_native_quit_exits_a_dedicated_review_with_one_command(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            source = folder/'sample.cpp'
            source.write_text('int example;\n')
            result = folder/'closed.json'
            env = dict(os.environ, TEST_WORK_LUA=str(ROOT/'shared/nvim_lua'), TEST_SOURCE=str(source),
                       TEST_RESULT=str(result), XDG_STATE_HOME=str(folder/'state'), XDG_RUNTIME_DIR=str(folder/'runtime'),
                       NVIM_LOG_FILE=str(folder/'nvim.log'))
            (folder/'runtime').mkdir()
            script = folder/'quit.lua'
            script.write_text(r'''
package.path=vim.env.TEST_WORK_LUA..'/?.lua;'..package.path
for _,name in ipairs({'claude','work','review'}) do package.loaded['foxml.'..name]=dofile(vim.env.TEST_WORK_LUA..'/foxml/'..name..'.lua') end
vim.fn.argv=function()return {'foxml-work:file-diff',vim.env.TEST_SOURCE,''} end
require('foxml.work').open_args()
vim.api.nvim_create_autocmd('VimLeavePre',{callback=function()
  vim.fn.writefile({vim.json.encode({closed=true})},vim.env.TEST_RESULT)
end})
vim.cmd('quit')
vim.wait(500)
error('one :q did not exit the dedicated review')
''')
            checked=subprocess.run(['nvim','--headless','--clean','-l',str(script)],cwd=folder,env=env,
                                   capture_output=True,text=True,timeout=15)
            self.assertEqual(checked.returncode,0,checked.stdout+checked.stderr)
            self.assertTrue(json.loads(result.read_text())['closed'])
            self.assertEqual(source.read_text(),'int example;\n')

    def test_review_exit_closes_its_tabs_and_preserves_editor_and_edits(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            source = folder / 'a.cpp'
            source.write_text('int original;\n')
            env = dict(os.environ, TEST_WORK_LUA=str(ROOT/'shared/nvim_lua'),
                       TEST_SOURCE=str(source), NVIM_LOG_FILE=str(folder/'nvim.log'))
            script = folder/'exit.lua'
            script.write_text(r'''
package.path = vim.env.TEST_WORK_LUA .. '/?.lua;' .. package.path
vim.g.mapleader = ' '
package.loaded['foxml.claude'] = dofile(vim.env.TEST_WORK_LUA .. '/foxml/claude.lua')
package.loaded['foxml.work'] = dofile(vim.env.TEST_WORK_LUA .. '/foxml/work.lua')
local C = require('foxml.claude')
C.setup()
vim.cmd('set hidden')
vim.cmd('edit ' .. vim.fn.fnameescape(vim.env.TEST_SOURCE))
local editor, file = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(file, 0, -1, false, {'int unsaved;'})
vim.cmd('tabnew')
local unrelated = vim.api.nvim_get_current_tabpage()
vim.api.nvim_set_current_win(editor)
local row = {kind='live', sid='test', name='test', short='test', label='test', files={vim.env.TEST_SOURCE}, before={}}
C.open_review(row, vim.fs.dirname(vim.env.TEST_SOURCE))
C.diff(vim.env.TEST_SOURCE)
C.diff(vim.env.TEST_SOURCE)
assert(#vim.api.nvim_list_tabpages() == 3, 'review should reuse one tab')
local close = vim.fn.maparg('<Space>Cq', 'n', false, true)
assert(type(close.callback) == 'function')
close.callback()
assert(#vim.api.nvim_list_tabpages() == 2, 'review tabs remained')
assert(vim.api.nvim_tabpage_is_valid(unrelated), 'unrelated tab was closed')
assert(vim.api.nvim_get_current_win() == editor, 'did not return to editor')
assert(C.review == nil and vim.fn.getqflist({winid=0}).winid == 0)
assert(vim.bo[file].modified and vim.api.nvim_buf_get_lines(file,0,1,false)[1] == 'int unsaved;', 'unsaved edit lost')
assert(vim.fn.maparg('q','n') == '', 'normal editor macro key was replaced')
C.open_review(row, vim.fs.dirname(vim.env.TEST_SOURCE))
C.diff(vim.env.TEST_SOURCE)
vim.cmd('tabclose')
vim.cmd('ChangedDone')
assert(#vim.api.nvim_list_tabpages() == 2, 'manually closed diff broke cleanup')
C.follow(row)
assert(C.following and #vim.api.nvim_list_tabpages() == 3)
C.close()
assert(C.following == nil and #vim.api.nvim_list_tabpages() == 2, 'follow view remained')
C.close()
assert(#vim.api.nvim_list_tabpages() == 2, 'repeated exit closed ordinary tabs')
''')
            checked = subprocess.run(['nvim','--headless','--clean','-l',str(script)],
                                     cwd=folder, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)

    def test_notebook_review_quits_all_windows_with_one_key(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            source = folder/'a.cpp'
            source.write_text('int a;\n')
            result = folder/'closed.json'
            env = dict(os.environ, TEST_WORK_LUA=str(ROOT/'shared/nvim_lua'), TEST_SOURCE=str(source),
                       TEST_RESULT=str(result), NVIM_LOG_FILE=str(folder/'nvim.log'))
            script = folder/'standalone.lua'
            script.write_text(r'''
package.path = vim.env.TEST_WORK_LUA .. '/?.lua;' .. package.path
vim.g.mapleader = ' '
package.loaded['foxml.claude'] = dofile(vim.env.TEST_WORK_LUA .. '/foxml/claude.lua')
package.loaded['foxml.work'] = dofile(vim.env.TEST_WORK_LUA .. '/foxml/work.lua')
vim.fn.argv = function() return {'foxml-work:file-diff', vim.env.TEST_SOURCE, ''} end
require('foxml.work').open_args()
local C = require('foxml.claude')
C.diff(vim.env.TEST_SOURCE)
vim.cmd('vsplit')
assert(#vim.api.nvim_list_wins() >= 4, 'fixture has too few review windows')
vim.api.nvim_create_autocmd('VimLeavePre', {callback=function()
  vim.fn.writefile({vim.json.encode({closed=true, windows=#vim.api.nvim_list_wins()})}, vim.env.TEST_RESULT)
end})
local close = vim.fn.maparg('q','n',false,true)
assert(type(close.callback) == 'function', 'one-key exit missing')
close.callback()
error('review exit did not quit the dedicated viewer')
''')
            checked = subprocess.run(['nvim','--headless','--clean','-l',str(script)],
                                     cwd=folder, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            self.assertTrue(json.loads(result.read_text())['closed'])

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
            checked = subprocess.run(['nvim', '--headless', '--clean', '-l', str(script)],
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
  if argv[1] == 'desk-drawer' then return {wait=function() return {code=0,stdout=vim.json.encode({{id='abc',name='test session',project='repo',state='waiting'}})} end} end
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
            checked = subprocess.run(["nvim", "--headless", "--clean", "-l", str(script)],
                                     cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)


if __name__ == "__main__":
    unittest.main()
