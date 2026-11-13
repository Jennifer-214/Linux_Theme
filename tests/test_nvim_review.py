"""Review real commits and live edits without changing source files or the Git index."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'src/desk-work/desk-work'


@unittest.skipUnless(shutil.which('nvim') and shutil.which('git'), 'Neovim and Git required')
class NvimReview(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nvim-review-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'project'
        self.repo.mkdir()
        self.env = os.environ | {
            'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
            'XDG_STATE_HOME': str(self.base / 'state'), 'XDG_RUNTIME_DIR': str(self.base / 'runtime'),
            'XDG_CACHE_HOME': str(self.base / 'cache'), 'NVIM_LOG_FILE': str(self.base / 'nvim.log'),
            'TEST_REVIEW_LUA': str(ROOT / 'shared/nvim_lua'), 'TEST_REVIEW_ROOT': str(self.repo),
            'PATH': str(WORK.parent) + os.pathsep + os.environ['PATH'], 'FOXML_WORK_NOTIFY': '0',
        }
        Path(self.env['XDG_RUNTIME_DIR']).mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Review Test')
        self.git('config', 'user.email', 'review@example.invalid')
        (self.repo / 'a.lua').write_text('local value = 1\nprint(value)\n')
        (self.repo / 'deleted.txt').write_text('old text\n')
        (self.repo / "old ' name.txt").write_text('renamed text\n')
        self.git('add', '.')
        self.commit('base')
        self.env['TEST_REVIEW_PARENT'] = self.git('rev-parse', 'HEAD')
        (self.repo / 'a.lua').write_text('local value = 2\nprint(value)\n')
        (self.repo / 'deleted.txt').unlink()
        (self.repo / "old ' name.txt").rename(self.repo / 'new name.txt')
        (self.repo / 'added.txt').write_text('new text\n')
        (self.repo / 'line\nbreak%.txt').write_text('awkward name\n')
        self.git('add', '.')
        self.commit('change\n\nCo-Authored-By: Claude <claude@example.invalid>')
        self.env['TEST_REVIEW_SHA'] = self.git('rev-parse', 'HEAD')
        (self.repo / 'a.lua').write_text('local value = 999\nprint(value)\n')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, env=self.env, text=True).strip()

    def commit(self, message):
        self.git('-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', message)

    def run_lua(self, code, index_unchanged=True):
        script = self.base / 'exercise.lua'
        script.write_text('''
package.path = vim.env.TEST_REVIEW_LUA .. '/?.lua;' .. package.path
vim.g.mapleader = ' '
vim.opt.hidden = true
local api = vim.api
package.loaded['foxml.claude'] = dofile(vim.env.TEST_REVIEW_LUA .. '/foxml/claude.lua')
package.loaded['foxml.review'] = dofile(vim.env.TEST_REVIEW_LUA .. '/foxml/review.lua')
local C, R = require('foxml.claude'), require('foxml.review')
local root, sha, parent = vim.env.TEST_REVIEW_ROOT, vim.env.TEST_REVIEW_SHA, vim.env.TEST_REVIEW_PARENT
local row = {kind='commit',sha=sha,parent=parent,short=sha:sub(1,7),label='test commit',files={root .. '/a.lua'}}
local function content(buf) return table.concat(api.nvim_buf_get_lines(buf,0,-1,false),'\\n') end
local function find(rel)
  for i,f in ipairs(R.current.files) do if f.rel == rel then return i end end
  error('missing review file: ' .. rel)
end
''' + code)
        before = {p.name: p.read_bytes() for p in self.repo.iterdir() if p.is_file()}
        index = (self.repo / '.git/index').read_bytes()
        checked = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-l', str(script)],
                                 cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        if index_unchanged:
            self.assertEqual((self.repo / '.git/index').read_bytes(), index)
        self.assertEqual({p.name: p.read_bytes() for p in self.repo.iterdir() if p.is_file()}, before)

    def test_exact_snapshots_navigation_notes_and_editor_restoration(self):
        self.run_lua(r'''
vim.cmd.edit(root .. '/a.lua')
local origin, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
api.nvim_buf_set_lines(buf,0,-1,false,{'local unsaved = 7'})
vim.fn.setqflist({},' ',{title='existing errors',items={{filename=root .. '/a.lua',lnum=2,text='keep me'}}})
local quickfix = vim.fn.getqflist({id=0}).id
local diffopt = vim.o.diffopt
C.open_review(row,root)
local r = R.current
assert(#r.files == 5, vim.inspect(r.files))
assert(#api.nvim_list_tabpages() == 2 and #api.nvim_tabpage_list_wins(r.tab) == 3)
R.select(find('a.lua'))
assert(content(r.left_buf):find('value = 1',1,true))
assert(content(r.right_buf):find('value = 2',1,true), 'later work leaked into committed comparison')
assert(not vim.bo[r.right_buf].modifiable and vim.bo[r.right_buf].readonly)
assert(vim.wo[r.left_win].winbar:find(parent:sub(1,8),1,true))
assert(vim.wo[r.right_win].winbar:find(sha:sub(1,8),1,true))
assert(not pcall(api.nvim_buf_set_lines,r.right_buf,0,1,false,{'oops'}))
local ctx = R.note_context({1,1},r.left_buf)
assert(ctx.file == root .. '/a.lua' and ctx.first == 1)
assert(ctx.code:find('Before (a.lua:1)',1,true) and ctx.code:find('After (a.lua:1)',1,true))
assert(ctx.code:find('value = 1',1,true) and ctx.code:find('value = 2',1,true))
local tab, left, right = r.tab,r.left_win,r.right_win
local next = vim.fn.maparg(']f','n',false,true)
next.callback()
assert(R.current.tab == tab and R.current.left_win == left and R.current.right_win == right)
C.diff(root .. '/a.lua'); C.diff(root .. '/a.lua')
assert(#api.nvim_list_tabpages() == 2, 'revisiting a file opened extra tabs')
R.select(find('new name.txt'))
assert(r.files[r.index].old == "old ' name.txt" and content(r.left_buf) == content(r.right_buf))
R.select(find('deleted.txt')); assert(content(r.left_buf) == 'old text' and content(r.right_buf) == '')
R.select(find('added.txt')); assert(content(r.left_buf) == '' and content(r.right_buf) == 'new text')
api.nvim_set_current_win(r.left_win)
vim.fn.maparg('<Space>rw','n',false,true).callback(); assert(vim.o.diffopt:find('iwhiteall',1,true))
vim.fn.maparg('<Space>rc','n',false,true).callback(); assert(vim.o.diffopt:find('context:999999',1,true))
api.nvim_set_current_win(origin); assert(vim.o.diffopt == diffopt, 'review options leaked into editing')
api.nvim_set_current_tabpage(tab)
assert(vim.o.diffopt:find('iwhiteall',1,true))
C.close()
assert(C.review == nil and api.nvim_get_current_win() == origin and #api.nvim_list_tabpages() == 1)
assert(vim.o.diffopt == diffopt and vim.fn.getqflist({id=0}).id == quickfix)
assert(vim.bo[buf].modified and content(buf) == 'local unsaved = 7', 'review changed the editing buffer')
assert(vim.fn.maparg('q','n') == '' and vim.fn.maparg(']f','n') == '')
''')

    def test_native_quit_and_close_leave_the_whole_review_once(self):
        self.run_lua(r'''
vim.cmd.edit(root .. '/a.lua')
local origin,source=api.nvim_get_current_win(),api.nvim_get_current_buf()
api.nvim_buf_set_lines(source,0,1,false,{'local unsaved = 7'})
for _,command in ipairs({'quit','quit!','close','tabclose','bdelete','bwipeout'}) do
  for _,side in ipairs({'left_win','right_win','panel_win'}) do
    C.open_review(row,root)
    local r=R.current
    api.nvim_set_current_win(r[side])
    vim.v.errmsg=''
    vim.cmd(command)
    assert(vim.wait(300,function()return R.current==nil end,10),command..' left a partial review behind')
    assert(api.nvim_get_current_win()==origin and api.nvim_win_is_valid(origin),'quit closed the editing window')
    assert(vim.bo[source].modified and content(source):find('unsaved = 7',1,true),'quit lost unsaved work')
    assert(vim.v.errmsg=='','quit produced an error: '..vim.v.errmsg)
  end
end
''')

    def test_working_changes_include_renames_untracked_files_and_unsaved_drafts(self):
        self.git('mv', 'new name.txt', "renamed ' file.txt")
        (self.repo / 'untracked.lua').write_text('return 3\n')
        self.run_lua(r'''
local draft=api.nvim_create_buf(true,false)
api.nvim_buf_set_name(draft,root .. '/draft.lua')
api.nvim_buf_set_lines(draft,0,-1,false,{'return "unsaved"'})
local rows=C.rows(root)
assert(rows[1].kind=='working' and rows[1].short=='Working changes')
C.changes()
local r=R.current
assert(r.row.kind=='working','current work was hidden behind commit history')
R.select(find('a.lua'))
assert(content(r.left_buf):find('value = 2',1,true) and content(r.right_buf):find('value = 999',1,true))
R.select(find("renamed ' file.txt"))
assert(r.files[r.index].status=='R' and content(r.left_buf)=='renamed text' and content(r.right_buf)=='renamed text')
R.select(find('untracked.lua'))
assert(content(r.left_buf)=='' and content(r.right_buf)=='return 3')
R.select(find('draft.lua'))
assert(content(r.right_buf)=='return "unsaved"' and vim.bo[draft].modified)
C.close()
''')

    def test_changed_function_children_jump_to_exact_snapshot_lines(self):
        before = 'local Queue = {}\n\nfunction Queue:push(item)\n  return item\nend\n\nfunction Queue:pop()\n  return nil\nend\n'
        after = before.replace('return item', 'return item or false').replace('return nil', 'return "empty"')
        (self.repo / 'functions.lua').write_text(before)
        self.git('add', 'functions.lua'); self.commit('functions')
        self.env['TEST_REVIEW_PARENT'] = self.git('rev-parse', 'HEAD')
        (self.repo / 'functions.lua').write_text(after)
        self.git('add', 'functions.lua'); self.commit('update functions')
        self.env['TEST_REVIEW_SHA'] = self.git('rev-parse', 'HEAD')
        self.run_lua(r'''
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/site'))
if not pcall(vim.treesitter.language.add,'lua') then return end
C.open_review(row,root);R.tree({row})
local r=R.current
R.select(find('functions.lua'))
api.nvim_set_current_win(r.panel_win)
local line
for ln,e in pairs(r.entries) do if e.file==r.index and not e.symbol then line=ln;break end end
api.nvim_win_set_cursor(r.panel_win,{line,0});R.enter()
local found={}
for ln,e in pairs(r.entries) do if e.symbol then found[e.symbol.name]={line=ln,symbol=e.symbol} end end
assert(found['Queue:push'] and found['Queue:pop'],vim.inspect(found))
local selected=found['Queue:pop']
api.nvim_win_set_cursor(r.panel_win,{selected.line,0});R.enter()
assert(r.symbol.name=='Queue:pop' and api.nvim_get_current_win()==r.right_win)
assert(api.nvim_win_get_cursor(0)[1]==selected.symbol.line)
C.close()
''')

    @unittest.skipUnless(WORK.is_file(), 'desk-work required')
    def test_finish_and_next_commit_reuses_the_review_and_keeps_checkmarks_separate(self):
        self.run_lua(r'''
local base={kind='commit',sha=parent,parent='4b825dc642cb6eb9a060e54bf8d69288fbee4904',short=parent:sub(1,7),subject='base',files={}}
C.open_review(row,root);R.tree({row,base})
local r,tab=R.current,R.current.tab
for i,f in ipairs(r.files) do R.select(i);if r.marks[f.rel]~=f.signature then R.mark() end end
assert(R.finish_next(),'finish was not recorded')
assert(R.current==r and r.tab==tab and r.row==base,'next commit opened a new review or stayed on the old commit')
assert(r.sets[1].completed and next(r.marks)==nil,'commit review state leaked')
C.close()
''')

    @unittest.skipUnless(WORK.is_file(), 'desk-work required')
    def test_saved_checkmarks_resume_and_explicit_finish(self):
        self.run_lua(r'''
local function pending()
  local out = vim.system({'desk-work','reviews','--root',root,'--all','yes'},{text=true}):wait()
  assert(out.code == 0, out.stderr)
  for _,entry in ipairs(vim.json.decode(out.stdout)) do if entry.sha == sha then return not entry.reviewed end end
  error('fixture commit was not listed')
end
assert(pending())
C.open_review(row,root)
assert(pending(), 'opening a commit marked it reviewed')
assert(R.finish() == false, 'unfinished review was accepted')
local first = R.current.files[R.current.index].rel
R.mark(); R.mark(); assert(R.current.marks[first] == nil, 'unchecking a file kept its mark')
R.mark(); C.close()
C.open_review(row,root)
local r = R.current
assert(r.files[r.index].rel ~= first, 'review did not resume at first unread file')
assert(pending(), 'checking one file completed the commit')
for i,f in ipairs(r.files) do R.select(i); if r.marks[f.rel] ~= f.signature then R.mark() end end
assert(R.finish() == true and not pending(), 'explicit finish was not recorded')
C.close(); C.open_review(row,root)
for _,f in ipairs(R.current.files) do assert(R.current.marks[f.rel] == f.signature) end
C.close()
''')

    def test_commit_tree_expands_files_and_reuses_the_comparison(self):
        self.run_lua(r'''
local base={kind='commit',sha=parent,parent='4b825dc642cb6eb9a060e54bf8d69288fbee4904',short=parent:sub(1,7),subject='base',files={}}
row.subject='change'
C.open_review(row,root)
R.tree({row,base})
local r,tab=R.current,R.current.tab
local function entry(predicate)
  for line,e in pairs(r.entries) do if predicate(e) then return line,e end end
  error('tree entry missing')
end
local line=entry(function(e)return e.set.row==base and not e.file end)
api.nvim_win_set_cursor(r.panel_win,{line,0}); R.enter()
line=entry(function(e)return e.set.row==base and e.file==1 end)
api.nvim_win_set_cursor(r.panel_win,{line,0}); R.enter()
assert(r.row==base and r.tab==tab and #api.nvim_list_tabpages()==2)
assert(content(r.left_buf)=='' and content(r.right_buf):find('value = 1',1,true))
R.mark()
line=entry(function(e)return e.set.row==base and e.file==1 and not e.symbol end)
api.nvim_win_set_cursor(r.panel_win,{line,0}); R.fold()
assert(not r.files[1].expanded,'first h should collapse the file contents')
R.fold()
local _,e=entry(function(e)return e.set.row==base and not e.file end)
assert(not e.set.expanded)
line=entry(function(e)return e.set.row==row and e.file and not e.symbol and e.set.files[e.file].rel=='a.lua' end)
api.nvim_win_set_cursor(r.panel_win,{line,0}); R.enter()
assert(r.row==row and content(r.right_buf):find('value = 2',1,true))
assert(r.marks['a.lua']==nil,'checkmark leaked from another commit')
local choices
vim.ui.select=function(items,opts,callback) choices=items end
R.actions()
assert(choices and choices[1].name=='Check & next','visible review actions are missing')
local file=r.files[r.index]
R.primary()
assert(r.marks[file.rel]==file.signature,'Check and next did not mark the file')
C.close()
''')

    def test_a_file_edited_after_it_was_checked_opens_against_the_reviewed_copy_and_the_toggle_is_remembered(self):
        source = self.repo / 'since.lua'
        source.write_text('local a = 1\nreturn a\n')
        head = r'''
local file=root .. '/since.lua'
local function content(buf) return table.concat(api.nvim_buf_get_lines(buf,0,-1,false),'\n') end
local row={kind='live',sid='since1',name='example',short='example',files={file}}
C.open_review(row,root)
local r=R.current
'''
        self.run_lua(head + r'''
assert(R.since_mode()==true,'new-since is the default')
R.mark()
assert(r.marks['since.lua']==r.files[1].signature)
C.close()
''')
        source.write_text('local a = 1\nlocal b = 2\nreturn a + b\n')       # edited after it was checked
        self.run_lua(head + r'''
assert(r.files[1].since==true,'a file edited after its check should open against the reviewed copy')
assert(content(r.left_buf)=='local a = 1\nreturn a','the left side is what was reviewed: '..content(r.left_buf))
assert(content(r.right_buf):find('local b = 2',1,true))
assert(r.marks['since.lua']~=r.files[1].signature,'the old check no longer counts')
R.toggle_since()
r=R.current
assert(R.since_mode()==false and not r.files[1].since,'the toggle shows the whole change')
assert(content(r.left_buf)=='','the whole change of a new file starts from nothing: '..content(r.left_buf))
C.close()
''')
        self.run_lua(head + r'''
assert(R.since_mode()==false,'the choice is remembered for the next review')
R.toggle_since()
r=R.current
assert(r.files[1].since==true)
R.mark()
C.close()
C.open_review(row,root)
r=R.current
assert(not r.files[1].since and r.marks['since.lua']==r.files[1].signature,'checked again: nothing new to show')
C.close()
''')

    def test_risk_marks_say_why_and_the_riskiest_unread_file_comes_first(self):
        (self.repo / 'plain.lua').write_text('return 1\n')
        (self.repo / 'setup.sh').write_text('#!/bin/sh\nsudo tee /etc/pam.d/sudo < pam.conf\n')
        (self.repo / 'engine').mkdir(exist_ok=True)
        (self.repo / 'engine/core.lua').write_text('return 2\n')
        (self.repo / '.review-risk').write_text('# paths that need care\nengine/\n')
        plan = self.repo / 'plan.md'
        plan.write_text('# Plan: tidy\n1. Change `plain.lua` and `setup.sh`\n')
        self.run_lua(r'''
local files={root..'/plain.lua',root..'/setup.sh',root..'/engine/core.lua'}
package.loaded['foxml.planmarks']=nil
local P=require('foxml.planmarks'); P.plan={title='Plan: tidy',file=root..'/plan.md'}
C.open_review({kind='live',sid='risk1',name='example',short='example',files=files},root)
local r=R.current
local by={}
for i,f in ipairs(r.files) do R.select(i); by[f.rel]=f.risks end
assert(#by['plain.lua']==0,'a plain file the plan names has no risk: '..vim.inspect(by['plain.lua']))
assert(vim.deep_equal(by['setup.sh'],{'touches /etc/pam.d'}),vim.inspect(by['setup.sh']))
assert(vim.deep_equal(by['engine/core.lua'],{'marked risky in this project','outside the plan'}),vim.inspect(by['engine/core.lua']))
R.select(1); R.unread()
assert(r.files[r.index].rel=='setup.sh','the first unread file with a risk comes first, got '..r.files[r.index].rel)
R.mark(); R.unread()
assert(r.files[r.index].rel=='engine/core.lua')
R.mark(); R.unread()
assert(r.files[r.index].rel=='plain.lua','then the rest in order')
local shown=table.concat(api.nvim_buf_get_lines(r.panel_buf,0,-1,false),'\n')
assert(shown:find('⚠',1,true),'the panel marks a risky file')
C.close()
''')

    def test_the_base_works_in_a_bare_project_without_plans_symdeps_or_the_work_tool(self):
        # The rule for everything here: the base works in anyone's project; plans, symdeps, desk-work and the notebook
        # only add to it. So: no work tool on PATH, no symdeps, no plan, an ordinary commit.
        self.run_lua(r'''
vim.env.PATH='/usr/bin:/bin'
assert(R.work_tool()==nil,'the work tool must be absent for this test')
assert(package.loaded['fox-symdeps']==nil and not pcall(require,'fox-symdeps'),'symdeps must be absent for this test')
package.loaded['foxml.planmarks']={plan=nil,parse=function() return {} end}
C.open_review(row,root); R.tree({row})
local r=R.current
local text=table.concat(api.nvim_buf_get_lines(r.panel_buf,0,-1,false),'\n')
assert(text:find('Other changes',1,true),'with no work tool every commit sits in one plain group:\n'..text)
assert(text:find(row.short,1,true) and text:find('a.lua',1,true),text)
assert(#r.files[1].risks==0,'no plan and no list means no invented risk: '..vim.inspect(r.files[1].risks))
for i,f in ipairs(r.files) do R.select(i); R.mark(); assert(r.marks[f.rel]==f.signature,'checkmarks work on their own') end
assert(R.finish()==true and r.completed==true,'a review finishes without the work tool')
R.actions()
C.close()
''')

    def test_symdeps_bridge_uses_a_real_cpp_buffer_and_the_selected_base(self):
        source = self.repo / 'inspect.cpp'
        source.write_text('struct Item { int count; };\n')
        self.run_lua(r'''
local file=root .. '/inspect.cpp'
C.open_review({kind='live',sid='abc',name='example',short='example',files={file}},root)
local inspected,compared=false,false
package.loaded['fox-symdeps']={inspect_cursor=function()
  assert(api.nvim_buf_get_name(0)==file and vim.bo.buftype=='')
  inspected=true
end,_menu_ctx=function() return {file=api.nvim_buf_get_name(0),bufnr=api.nvim_get_current_buf(),line=1} end}
R.symdeps(false)
assert(inspected,'changed symbol was not sent to symdeps')
local r=R.current
r.row.kind='commit';r.row.parent=parent
package.loaded['fox-symdeps.revcompare']={open=function(ctx,rev)
  assert(ctx.file==file and rev==parent);compared=true
end}
api.nvim_set_current_win(r.right_win);R.symdeps(true)
assert(compared,'selected commit base was not passed to layout comparison')
C.close()
''')

    @unittest.skipUnless((Path.home() / 'code/tick-trader-percore-workspace/tools/plugins/fox-symdeps.nvim').is_dir(),
                         'local symdeps plugin required')
    def test_real_symdeps_menu_groups_toggles_mouse_and_cursor_restoration(self):
        self.run_lua(r'''
vim.opt.rtp:append(vim.fn.expand('~/code/tick-trader-percore-workspace/tools/plugins/fox-symdeps.nvim'))
local native=require('fox-symdeps.menu')
C.open_review(row,root)
local r=R.current
local cursor=vim.o.guicursor
R.actions()
local opened=native._last
assert(opened and api.nvim_win_is_valid(opened.win),'review did not use the real symdeps renderer')
local buf=api.nvim_win_get_buf(opened.win)
assert(vim.b[buf].fox_symdeps_menu)
local body=content(buf)
assert(body:find('review',1,true) and body:find('comparison',1,true) and body:find('Ignore whitespace',1,true))
assert(body:find('<ldr>rw',1,true) and body:find('○ off',1,true),'menu lost the shortcut and state columns')
local function click(name)
  local current=native._last
  local rows=api.nvim_buf_get_lines(api.nvim_win_get_buf(current.win),0,-1,false)
  local target
  for line in pairs(current.layout.rows) do if rows[line]:find(name,1,true) then target=line;break end end
  assert(target,'missing action '..name)
  local getmouse=vim.fn.getmousepos
  vim.fn.getmousepos=function() return {winid=current.win,line=target,column=12} end
  local mapping=vim.fn.maparg('<LeftMouse>','n',false,true)
  assert(type(mapping.callback)=='function','mouse mapping missing after toggle reopened menu')
  mapping.callback()
  vim.fn.getmousepos=getmouse
  assert(vim.wait(500,function()
    return native._last~=current and api.nvim_win_is_valid(native._last.win)
      and type(vim.fn.maparg('<LeftMouse>','n',false,true).callback)=='function'
  end,10),'toggle did not reopen its menu with mouse support')
end
click('Ignore whitespace')
assert(r.whitespace==true)
body=content(api.nvim_win_get_buf(native._last.win))
assert(body:find('● on',1,true),'toggle state did not refresh')
click('Ignore whitespace')
assert(r.whitespace==false,'second mouse click ran a different action')
vim.fn.maparg('q','n',false,true).callback()
assert(vim.o.guicursor==cursor,'menu did not restore the editing cursor')
assert(R.current==r and api.nvim_tabpage_is_valid(r.tab),'closing the menu closed the comparison')
R.actions()
local popup=native._last.win
vim.cmd('quit')
assert(vim.wait(300,function()return not api.nvim_win_is_valid(popup) and vim.o.guicursor==cursor end,10),'native menu quit left a hidden cursor')
assert(R.current==r and api.nvim_tabpage_is_valid(r.tab),'native popup quit closed the review')
C.close()
''')

    def test_live_unsaved_changes_invalidate_progress_and_notes_keep_source_path(self):
        before = Path(self.env['XDG_RUNTIME_DIR']) / 'foxml-claude/edits/abc/before'
        before.mkdir(parents=True)
        (before / '1.txt').write_text('local value = 8\nprint(value)\n')
        self.run_lua(r'''
vim.cmd.edit(root .. '/a.lua')
local buf = api.nvim_get_current_buf()
api.nvim_buf_set_lines(buf,0,-1,false,{'local value = 10','print(value)'})
local live = {kind='live',sid='abc',name='A session',short='A session',files={root .. '/a.lua'},before={[root .. '/a.lua']='1.txt'}}
C.open_review(live,root)
local r = R.current
assert(content(r.left_buf):find('value = 8',1,true))
assert(content(r.right_buf):find('value = 10',1,true), 'unsaved work omitted from live comparison')
C.live = {{id='abc',name='A session'}}
local selected, prompted = false,false
vim.ui.select = function(items,opts,cb) selected=true; cb(items[1]) end
vim.ui.input = function(opts,cb) prompted=true; cb('Please check this change') end
C.send({1,1})
assert(selected and prompted)
local inbox = vim.env.XDG_RUNTIME_DIR .. '/foxml-claude/inbox/abc'
local note = vim.json.decode(C.read(inbox .. '/' .. vim.fn.readdir(inbox)[1]))
assert(note.file == root .. '/a.lua' and note.lines == '1')
assert(note.code:find('Selected before',1,true) and note.code:find('value = 10',1,true))
R.mark()
api.nvim_buf_set_lines(buf,0,1,false,{'local value = 11'})
assert(R.finish() == false, 'live edits after checking a file retained a reviewed mark')
R.select(1,true)
assert(r.marks['a.lua'] ~= r.files[1].signature)
assert(content(r.right_buf):find('value = 11',1,true))
C.close(); C.open_review(live,root)
assert(R.current.marks['a.lua'] ~= R.current.files[1].signature)
C.close()
live.before={[root .. '/a.lua']='2.txt'}
C.open_review(live,root)
assert(R.current.files[1].error, 'missing before-copy silently fell back to a different baseline')
R.mark(); assert(R.finish() == false)
C.close()
''')

    @unittest.skipUnless((ROOT / 'src/desk-render/desk-render-fast').is_file()
                         and (Path.home() / '.local/share/nvim/lazy/gitsigns.nvim').is_dir(),
                         'renderer and installed Git plugin required')
    def test_ordinary_editing_hunks_save_controls_and_hidden_file_search(self):
        rendered = self.base / 'rendered'
        subprocess.run([str(ROOT / 'src/desk-render/desk-render-fast'),
                        str(ROOT / 'themes/FoxML_Paper/palette.sh'), str(ROOT / 'templates/nvim'), str(rendered)],
                       check=True, capture_output=True)
        self.env['TEST_REVIEW_INIT'] = str(rendered / 'init.lua')
        (self.repo / '.config-note').write_text('find this hidden file\n')
        (self.repo / '.gitignore').write_text('ignored-output\n')
        (self.repo / 'ignored-output').write_text('skip generated content\n')
        self.run_lua(r'''
local source = table.concat(vim.fn.readfile(vim.env.TEST_REVIEW_INIT),'\n')
assert(loadstring(source), 'rendered config does not parse')
local function options(plugin)
  local _,last = assert(source:find('"' .. plugin .. '"',1,true))
  return assert(loadstring('local Paper={enabled=false}\nreturn ' .. assert(source:sub(last):match('opts = (%b{})'))))()
end
api.nvim_set_current_buf(vim.fn.bufadd(root .. '/a.lua')); vim.fn.bufload(0)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/gitsigns.nvim'))
local gs = require('gitsigns'); gs.setup(options('lewis6991/gitsigns.nvim')); gs.attach()
assert(vim.wait(2000,function()
  local hunks = gs.get_hunks()
  return type(vim.fn.maparg(']c','n',false,true).callback) == 'function' and hunks and #hunks > 0
end,10), 'Git hunks were not attached')
vim.fn.maparg('<Space>gs','n',false,true).callback()
assert(vim.wait(2000,function()
  return vim.system({'git','-C',root,'diff','--cached','--name-only'},{text=true}):wait().stdout:find('a.lua',1,true) ~= nil
end,10), 'stage shortcut did not stage the change')
vim.fn.maparg('<Space>gu','n',false,true).callback()
assert(vim.wait(2000,function()
  return vim.system({'git','-C',root,'diff','--cached','--quiet'}):wait().code == 0
end,10), 'undo staging shortcut did not restore the index')
local controls = assert(source:match('%-%- === QoL ===\n(.-)\n%-%- Navigate splits'))
assert(loadstring('local map=vim.keymap.set\n' .. controls))()
local conform = options('stevearc/conform.nvim')
vim.fn.maparg('<Space>tf','n',false,true).callback()
assert(conform.format_on_save(0) == nil, 'format-off control did not disable formatting')
vim.fn.maparg('<Space>tf','n',false,true).callback()
assert(type(conform.format_on_save(0)) == 'table')
local whitespace = assert(source:match('(%-%- Markdown\'s trailing double space.-)\n%-%- Directory events'))
assert(loadstring(whitespace))()
api.nvim_buf_set_lines(0,0,-1,false,{'local value = 99   '})
vim.fn.setreg('/','keep-this-search')
api.nvim_exec_autocmds('BufWritePre',{buffer=0})
assert(content(0) == 'local value = 99' and vim.fn.getreg('/') == 'keep-this-search')
local prose=api.nvim_create_buf(true,false); api.nvim_set_current_buf(prose); vim.bo.filetype='markdown'
api.nvim_buf_set_lines(prose,0,-1,false,{'keep this line break  ','on the next line'})
api.nvim_exec_autocmds('BufWritePre',{buffer=prose})
assert(api.nvim_buf_get_lines(prose,0,1,false)[1] == 'keep this line break  ')
local called
package.loaded['telescope.builtin']={find_files=function(opts)called=opts end,live_grep=function(opts)called=opts end}
local search = assert(source:match('(local function file_project%(%)\n.-)\n%-%- Highlight on yank'))
assert(loadstring('local map=vim.keymap.set\nlocal project_path=function(p)return p end\n' .. search))()
vim.b.foxml_review_root=root
vim.fn.maparg('<Space>ff','n',false,true).callback()
local result=vim.system(called.find_command,{cwd=called.cwd,text=true}):wait()
assert(result.code == 0 and result.stdout:find('.config-note',1,true),'hidden configuration file missing')
assert(not result.stdout:find('.git/',1,true) and not result.stdout:find('ignored-output',1,true),'search included Git internals or ignored output')
vim.fn.maparg('<Space>fg','n',false,true).callback()
assert(called.cwd == root and vim.tbl_contains(called.additional_args,'--hidden'))
''', index_unchanged=False)


if __name__ == '__main__':
    unittest.main()
