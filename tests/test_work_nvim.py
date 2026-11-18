"""Exercise captured failures and editable drafts through the real headless Neovim module."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from fixture_process import run as run_fixture

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
for _,name in ipairs({'claude','work','review'}) do package.loaded['desk.'..name]=dofile(vim.env.TEST_WORK_LUA..'/desk/'..name..'.lua') end
vim.fn.argv=function()return {'desk-work:file-diff',vim.env.TEST_SOURCE,''} end
require('desk.work').open_args()
vim.api.nvim_create_autocmd('VimLeavePre',{callback=function()
  vim.fn.writefile({vim.json.encode({closed=true})},vim.env.TEST_RESULT)
end})
vim.cmd('quit')
vim.wait(500)
error('one :q did not exit the dedicated review')
''')
            checked=run_fixture(['nvim','--headless','--clean','-l',str(script)],cwd=folder,env=env,
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
package.loaded['desk.claude'] = dofile(vim.env.TEST_WORK_LUA .. '/desk/claude.lua')
package.loaded['desk.work'] = dofile(vim.env.TEST_WORK_LUA .. '/desk/work.lua')
local C = require('desk.claude')
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
            checked = run_fixture(['nvim','--headless','--clean','-l',str(script)],
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
package.loaded['desk.claude'] = dofile(vim.env.TEST_WORK_LUA .. '/desk/claude.lua')
package.loaded['desk.work'] = dofile(vim.env.TEST_WORK_LUA .. '/desk/work.lua')
vim.fn.argv = function() return {'desk-work:file-diff', vim.env.TEST_SOURCE, ''} end
require('desk.work').open_args()
local C = require('desk.claude')
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
            checked = run_fixture(['nvim','--headless','--clean','-l',str(script)],
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
package.loaded['desk.work'] = dofile(vim.env.TEST_WORK_LUA .. '/desk/work.lua')
package.loaded['desk.claude'] = dofile(vim.env.TEST_WORK_LUA .. '/desk/claude.lua')
local W = require('desk.work')
local path = vim.env.TEST_SOURCE
local original = vim.fn.argv
vim.fn.argv = function() return {'desk-work:file-diff', path, 'abc'} end
W.open_args()
assert(vim.wo.diff, 'notebook did not open a diff')
-- A file opens with focus in the after pane; the before side is what this checks.
local function before() return table.concat(vim.api.nvim_buf_get_lines(require('desk.review').current.left_buf, 0, -1, false), '\n') end
assert(before() == 'int preexisting_edit = 2;', 'session diff lost the preexisting work')
vim.fn.argv = function() return {'desk-work:file-diff', path, ''} end
W.open_args()
assert(before() == 'int committed = 1;', 'all-changes diff did not use HEAD')
vim.cmd.badd('desk-work:file')   -- what Neovim makes of its first argument at start
vim.fn.argv = function() return {'desk-work:file', path} end
W.open_args()
assert(vim.api.nvim_buf_get_name(0) == path, 'editor changed the literal filename')
assert(vim.fn.bufnr('desk-work:file') == -1, 'the desk-work:file argument stayed as an empty buffer beside the file')
vim.fn.argv = original
''')
            checked = run_fixture(['nvim', '--headless', '--clean', '-l', str(script)],
                                     cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)

    def test_a_session_diff_never_opens_empty_for_a_file_the_notebook_counts_as_changed(self):
        # The notebook counts a file against HEAD. A session's before-copy that the file equals again (its part
        # undone, another agent's edits left), or one older than the file's last commit (its part committed), would open
        # an empty or stale review; both compare with HEAD instead.
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            repo = folder / 'repo'
            repo.mkdir()
            source = repo / 'Run.hpp'
            source.write_text('int committed = 1;\n')
            env = dict(os.environ, XDG_STATE_HOME=str(folder / 'state'), XDG_RUNTIME_DIR=str(folder / 'runtime'),
                       PATH=str(BIN.parent) + os.pathsep + os.environ['PATH'], FOXML_WORK_NOTIFY='0',
                       TEST_WORK_LUA=str(ROOT / 'shared/nvim_lua'), TEST_SOURCE=str(source), NVIM_LOG_FILE=str(folder / 'nvim.log'))
            git = lambda *args: subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false',
                                                '-c', 'core.hooksPath=/dev/null', *args], cwd=repo, env=env, check=True, capture_output=True)
            git('init', '-q'); git('add', '.'); git('commit', '-qm', 'initial')
            before = folder / 'runtime/foxml-claude/edits/abc/before'
            before.mkdir(parents=True)
            (before.parent.parent / 'abc.json').write_text(json.dumps({'before': {str(source): '1.txt'}}))
            # 1. Another agent's edit was there at the session's first edit; the session's own change was undone since.
            (before / '1.txt').write_text('int other_agent = 2;\n')
            source.write_text('int other_agent = 2;\n')
            script = folder / 'base.lua'
            script.write_text(r'''
package.path = vim.env.TEST_WORK_LUA .. '/?.lua;' .. package.path
package.loaded['desk.work'] = dofile(vim.env.TEST_WORK_LUA .. '/desk/work.lua')
package.loaded['desk.claude'] = dofile(vim.env.TEST_WORK_LUA .. '/desk/claude.lua')
local W = require('desk.work')
vim.fn.argv = function() return {'desk-work:file-diff', vim.env.TEST_SOURCE, 'abc'} end
W.open_args()
local R = require('desk.review')
local function side(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
assert(R.current, 'no review opened')
assert(side(R.current.left_buf) == 'int committed = 1;', 'before side is not HEAD: ' .. side(R.current.left_buf))
assert(side(R.current.left_buf) ~= side(R.current.right_buf), 'the review opened empty')
''')
            checked = run_fixture(['nvim', '--headless', '--clean', '-l', str(script)], cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, 'undone session part: ' + checked.stdout + checked.stderr)
            # 2. The session edited and committed the file; a later edit is what the notebook counts now.
            (before / '1.txt').write_text('int committed = 1;\n')
            old = time.time() - 120
            os.utime(before / '1.txt', (old, old))
            source.write_text('int session_commit = 3;\n')
            git('commit', '-qam', 'session commit')
            source.write_text('int later_edit = 4;\n')
            script.write_text(script.read_text().replace("'int committed = 1;'", "'int session_commit = 3;'"))
            checked = run_fixture(['nvim', '--headless', '--clean', '-l', str(script)], cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, 'committed session part: ' + checked.stdout + checked.stderr)

    def test_checking_every_file_of_a_commit_takes_it_off_the_review_count(self):
        # The notebook's path end to end: its needs-you row opens the commit's review (desk-work open --action reviews
        # --id SHA), every file is checked with m, and then desk-work counts the commit as reviewed everywhere
        # (reviews, attention, the notebook's list) without a finish: stamping stays the explicit R.
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            repo = folder / 'repo'
            repo.mkdir()
            env = dict(os.environ, XDG_STATE_HOME=str(folder / 'state'), XDG_RUNTIME_DIR=str(folder / 'runtime'),
                       PATH=str(BIN.parent) + os.pathsep + os.environ['PATH'], FOXML_WORK_NOTIFY='0',
                       TEST_WORK_LUA=str(ROOT / 'shared/nvim_lua'), NVIM_LOG_FILE=str(folder / 'nvim.log'))
            Path(env['XDG_RUNTIME_DIR']).mkdir()
            git = lambda *args: subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false',
                                                '-c', 'core.hooksPath=/dev/null', *args], cwd=repo, env=env, check=True, capture_output=True, text=True).stdout
            (repo / 'a.cpp').write_text('int a;\n'); git('init', '-q'); git('add', '.'); git('commit', '-qm', 'base')
            (repo / 'a.cpp').write_text('int a = 1;\n'); (repo / 'b dir').mkdir(); (repo / 'b dir/b.cpp').write_text('int b;\n')
            git('add', '.'); git('commit', '-qm', 'feat: two files\n\nClaude-Session: https://claude.ai/code/session_X')
            sha = git('rev-parse', 'HEAD').strip()
            work = lambda *args: json.loads(subprocess.run([str(BIN), *args, '--root', str(repo)], env=env, capture_output=True, text=True, check=True).stdout)
            pending = lambda: [c['sha'] for c in work('reviews') if not c.get('reviewed')]
            self.assertEqual(pending(), [sha], 'the commit starts out to review')
            self.assertIn('commit:' + sha, [i['id'] for i in work('attention')])
            script = folder / 'check.lua'
            script.write_text(r'''
package.path = vim.env.TEST_WORK_LUA .. '/?.lua;' .. package.path
for _, name in ipairs({ 'claude', 'work', 'review' }) do package.loaded['desk.' .. name] = dofile(vim.env.TEST_WORK_LUA .. '/desk/' .. name .. '.lua') end
vim.fn.argv = function() return { 'desk-work:reviews', vim.env.TEST_SHA, '' } end
require('desk.work').open_args()
local R = require('desk.review')
local r = assert(R.current, 'the commit review did not open')
assert(r.row.sha == vim.env.TEST_SHA, 'the review is keyed by something other than the commit id')
for i = 1, #r.files do R.select(i); R.mark() end
assert(r.status_line and r.status_line:find('every file checked', 1, true), 'no prompt to finish: ' .. tostring(r.status_line))
assert(vim.wo[r.right_win].statusline:find('all checked · R stamps it', 1, true), 'the footer does not offer the finish: ' .. vim.wo[r.right_win].statusline)
-- The marks go to desk-work in the background. Quit at once, the way a reader does after the last m: leaving must
-- not lose the last check.
vim.cmd('qa!')
''')
            checked = run_fixture(['nvim', '--headless', '--clean', '-l', str(script)], cwd=repo, env=dict(env, TEST_SHA=sha),
                                  capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            self.assertEqual(pending(), [], 'every file checked, and desk-work still counts the commit')
            self.assertNotIn('commit:' + sha, [i['id'] for i in work('attention')])
            notebook = json.loads(subprocess.run([str(BIN), 'notebook', '--root', str(repo), '--session', 'reader'], env=env, capture_output=True, text=True, check=True).stdout)
            self.assertNotIn('commit:' + sha, [i['id'] for i in notebook['attention']], 'the notebook still lists it')
            notes = subprocess.run(['git', 'notes', '--ref', 'reviews', 'list'], cwd=repo, env=env, capture_output=True, text=True).stdout
            self.assertEqual(notes, '', 'checking files must not stamp the commit; finishing does')

    def test_status_line_shows_the_newest_test_run_without_waiting_on_desk_work(self):
        # A stand-in desk-work that prints the fixture run; it lives under tests/ because /tmp may be noexec.
        with tempfile.TemporaryDirectory(prefix='.work-status-', dir=ROOT/'tests') as temp:
            folder = Path(temp)
            (folder/'bin').mkdir()
            (folder/'repo/.git').mkdir(parents=True)
            (folder/'repo/a.cpp').write_text('int a;\n')
            fake = folder/'bin/desk-work'
            fake.write_text('#!/usr/bin/python3\nimport os, sys\n'
                            "open(os.environ['FAKE_CALLS'], 'a').write(' '.join(sys.argv[1:]) + '\\n')\n"
                            "reply = open(os.environ['FAKE_RUN']).read()\n"
                            "if reply.strip() == 'fail': sys.exit(3)\n"
                            "print(reply)\n")
            fake.chmod(0o755)
            env = dict(os.environ, PATH=str(folder/'bin') + os.pathsep + '/usr/bin:/bin', FAKE_RUN=str(folder/'run.json'),
                       FAKE_CALLS=str(folder/'calls'), TEST_WORK_LUA=str(ROOT/'shared/nvim_lua'),
                       FAKE_TOOL=str(fake),
                       TEST_SOURCE=str(folder/'repo/a.cpp'), NVIM_LOG_FILE=str(folder/'nvim.log'))
            script = folder/'status.lua'
            script.write_text(r'''
local W = dofile(vim.env.TEST_WORK_LUA .. '/desk/work_events.lua')
-- Every desk-work call must be asynchronous: a callback given, never waited on, never through vim.fn.system.
local system, calls = vim.system, 0
vim.system = function(argv, opts, on_exit)
  calls = calls + 1
  assert(type(on_exit) == 'function', 'desk-work was run without a callback: ' .. table.concat(argv, ' '))
  assert(opts and opts.timeout and opts.timeout <= 5000, 'desk-work read has no timeout')
  local job = system(argv, opts, on_exit)
  return setmetatable({ wait = function() error('the status line waited on desk-work') end }, { __index = job })
end
vim.fn.system = function() error('vim.fn.system blocks') end
io.popen = function() error('io.popen blocks') end
vim.cmd('edit ' .. vim.fn.fnameescape(vim.env.TEST_SOURCE))
local root = vim.uv.fs_realpath(vim.fs.dirname(vim.env.TEST_SOURCE))
local function fixture(run) vim.fn.writefile({ vim.json.encode(run) }, vim.env.FAKE_RUN) end
local function shown(retro, expected)
  vim.api.nvim_exec_autocmds('User', { pattern = 'FoxWorkChanged', data = { root = root } })
  local text
  assert(vim.wait(3000, function() text = W.tests_status(retro); return text == expected end, 10), vim.inspect(text) .. ' ~= ' .. vim.inspect(expected))
  return true
end
fixture(vim.NIL)
local before = calls
assert(W.tests_status(true) == '', 'a status before any read must be empty')
assert(calls == before, 'drawing the status line started desk-work')
vim.wait(1000, function() return calls > before end, 10)
assert(calls > before, 'no background read was started')
assert(vim.wait(2000, function() return vim.uv.fs_stat(vim.env.FAKE_CALLS) ~= nil end, 10), 'desk-work was never asked')
vim.wait(200)
assert(W.tests_status(true) == '', 'no run must show nothing')
fixture({ state = 'passed', tests = { passed = 128, failed = 0 } })
assert(shown(true, '     √ 128'))
assert(W.tests_state() == 'passed')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'int unsaved;' })
vim.fn.writefile({ 'fail' }, vim.env.FAKE_RUN)
assert(shown(true, 'LAST PASS · UNAVAILABLE'))
assert(W.tests_state() == 'unavailable', 'a failed refresh kept the green state')
fixture({ state = 'passed', tests = { passed = 128, failed = 0 } })
assert(shown(true, '     √ 128') and W.tests_state() == 'passed', 'the same result can be verified again')
vim.fn.writefile({ '{broken' }, vim.env.FAKE_RUN)
assert(shown(false, 'last pass · unavailable'))
fixture({ state = 'passed', stale = true, tests = { passed = 128, failed = 0 } })
assert(shown(true, 'LAST PASS · STALE') and W.tests_state() == 'stale', 'a pass for older source stayed green')
assert(vim.uv.fs_rename(vim.env.FAKE_TOOL, vim.env.FAKE_TOOL .. '.held'))
assert(shown(true, 'LAST PASS · UNAVAILABLE') and W.tests_state() == 'unavailable')
assert(vim.uv.fs_rename(vim.env.FAKE_TOOL .. '.held', vim.env.FAKE_TOOL))
fixture({ state = 'passed', tests = { passed = 128, failed = 0 } })
assert(shown(true, '     √ 128') and W.tests_state() == 'passed', 'the status recovered when the backend returned')
assert(vim.bo.modified and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'int unsaved;', 'the outage lost an unsaved buffer')
assert(vim.fn.readfile(vim.env.TEST_SOURCE)[1] == 'int a;', 'the outage wrote the unsaved edit to disk')
fixture({ state = 'failed', tests = { passed = 126, failed = 2 } })
assert(shown(true, '  2 FAILED'))
fixture({ state = 'running', tests = { passed = vim.NIL, failed = vim.NIL } })
assert(shown(true, ' ☼ RUNNING'))
fixture(vim.NIL)
assert(shown(true, ''))
-- Drawing never reads: the count only moves in the background.
local idle = calls
for _ = 1, 50 do W.tests_status(true) end
assert(calls == idle, 'the status line part ran desk-work while drawing')
-- The other themes' marks, padded to one width.
local function label(run) return W.test_label(run, false) end
assert(label({ state = 'passed', tests = { passed = 128, failed = 0 } }) == '       ✓ 128')
assert(label({ state = 'failed', tests = { passed = 1, failed = 2 } }) == '✗   2 failed')
assert(label({ state = 'running', tests = {} }) == '   ◷ running')
assert(label(nil) == '' and label(vim.NIL) == '')
local widths = {}
for _, run in ipairs({ { state = 'passed', tests = { passed = 5 } }, { state = 'failed', tests = { failed = 12 } }, { state = 'running' },
                       { state = 'interrupted' }, { state = 'failed', tests = {} } }) do
  widths[vim.api.nvim_strwidth(W.test_label(run, true))] = true
  widths[100 + vim.api.nvim_strwidth(W.test_label(run, false))] = true
end
assert(vim.tbl_count(widths) == 2, 'labels of one style differ in width: ' .. vim.inspect(widths))
for _, line in ipairs(vim.fn.readfile(vim.env.FAKE_CALLS)) do assert(line == 'tests --root ' .. root, line) end
print('work status: async test run labels passed')
vim.cmd('qa!')
''')
            checked = run_fixture(['nvim', '--headless', '--clean', '-l', str(script)], cwd=folder/'repo', env=env,
                                  capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            self.assertIn('work status: async test run labels passed', checked.stdout + checked.stderr)
            # Without desk-work the part stays empty and nothing is ever started.
            script.write_text(r'''
local W = dofile(vim.env.TEST_WORK_LUA .. '/desk/work_events.lua')
local calls = 0
local system = vim.system
vim.system = function(...) calls = calls + 1; return system(...) end
vim.cmd('edit ' .. vim.fn.fnameescape(vim.env.TEST_SOURCE))
assert(W.tests_status(true) == '')
vim.wait(300)
vim.api.nvim_exec_autocmds('BufEnter', {})
vim.wait(300)
assert(W.tests_status(true) == '' and calls == 0, 'something ran without desk-work')
print('work status: idle without desk-work')
vim.cmd('qa!')
''')
            env['PATH'] = '/usr/bin:/bin'
            checked = run_fixture(['nvim', '--headless', '--clean', '-l', str(script)], cwd=folder/'repo', env=env,
                                  capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            self.assertIn('work status: idle without desk-work', checked.stdout + checked.stderr)
        init = (ROOT/'templates/nvim/init.lua').read_text()
        self.assertIn('work.tests_status(DeskStyle == "retro")', init, 'the status line does not show the test run')

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
package.loaded["desk.work"] = dofile(vim.env.TEST_WORK_LUA .. "/desk/work.lua")
package.loaded["desk.claude"] = dofile(vim.env.TEST_WORK_LUA .. "/desk/claude.lua")
vim.g.mapleader = ' '
local W, C = require('desk.work'), require('desk.claude')
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
            checked = run_fixture(["nvim", "--headless", "--clean", "-l", str(script)],
                                     cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)


if __name__ == "__main__":
    unittest.main()
