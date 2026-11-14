"""Review real commits and live edits without changing source files or the Git index."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from fixture_process import run as run_fixture

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
        checked = run_fixture(['nvim', '--headless', '--clean', '-l', str(script)],
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

    def test_native_quit_closes_the_diff_but_only_hides_a_sidebar(self):
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
    if side=='panel_win' and command~='tabclose' then
      assert(vim.wait(300,function()return not api.nvim_win_is_valid(r.panel_win) end,10),command..' left a deleted sidebar window behind')
      assert(R.current==r and api.nvim_win_is_valid(r.left_win) and api.nvim_win_is_valid(r.right_win),'hiding a sidebar closed the diff')
      C.close()
    else
      assert(vim.wait(300,function()return R.current==nil end,10),command..' left a partial review behind')
    end
    assert(api.nvim_get_current_win()==origin and api.nvim_win_is_valid(origin),'quit closed the editing window')
    assert(vim.bo[source].modified and content(source):find('unsaved = 7',1,true),'quit lost unsaved work')
    assert(vim.v.errmsg=='','quit produced an error: '..vim.v.errmsg)
  end
end
''')

    def test_sidebar_toggle_and_reselection_preserve_diff_buffers_focus_folds_and_reading_positions(self):
        self.run_lua(r'''
vim.cmd.edit(root..'/a.lua')
local origin,source=api.nvim_get_current_win(),api.nvim_get_current_buf()
api.nvim_buf_set_lines(source,0,1,false,{'local unsaved = 7'})
local neo_calls=0
local neo_win
vim.keymap.set('n','<leader>e',function()
  neo_calls=neo_calls+1
  if neo_win and api.nvim_win_is_valid(neo_win) then api.nvim_win_close(neo_win,false);return end
  local here=api.nvim_get_current_win()
  vim.cmd('topleft vsplit');neo_win=api.nvim_get_current_win()
  local tree=api.nvim_create_buf(false,true);api.nvim_win_set_buf(neo_win,tree);vim.bo[tree].filetype='neo-tree'
  vim.wo[neo_win].winfixwidth=true;api.nvim_win_set_width(neo_win,16)
  api.nvim_set_current_win(here)
end,{desc='Neo-tree fixture'})
local before,after={},{}
for i=1,100 do before[i]='-- line '..i;after[i]=before[i] end
after[50]='-- changed line'
local pair={table.concat(before,'\n'),table.concat(after,'\n')}
C.open_review({kind='external',sid='toggle-fixture',short='toggle fixture',files={root..'/a.lua',root..'/added.txt'},
  snapshots={[root..'/a.lua']=pair,[root..'/added.txt']=pair}},root)
local r=R.current
vim.fn.maparg('<Space>e','n',false,true).callback()
assert(neo_calls==1 and api.nvim_win_is_valid(r.panel_win),'review mappings replaced the normal Neo-tree binding')
assert(type(vim.fn.maparg('<Space>re','n',false,true).callback)=='function','the review toggle has no separate binding')
api.nvim_set_current_win(r.right_win);vim.cmd('normal! zR');api.nvim_win_set_cursor(r.right_win,{40,0})
local left,right,tab=r.left_buf,r.right_buf,r.tab
local width=api.nvim_win_get_width(r.right_win)
local tree_width=api.nvim_win_get_width(neo_win)
assert(R.hide_panel())
assert(R.current==r and not api.nvim_win_is_valid(r.panel_win) and api.nvim_get_current_win()==r.right_win)
assert(api.nvim_win_get_width(neo_win)==tree_width,'review layout resized the independent tree')
assert(api.nvim_win_get_width(r.right_win)>width,'hiding the list did not give the diff its room')
assert(api.nvim_win_get_cursor(r.right_win)[1]==40 and vim.fn.foldclosed(1)==-1,'hiding the list changed the reading position or folds')
assert(R.show_panel(true) and api.nvim_get_current_win()==r.panel_win)
local selected=api.nvim_win_get_cursor(r.panel_win)
vim.fn.maparg('q','n',false,true).callback()
assert(R.current==r and not api.nvim_win_is_valid(r.panel_win),'q in the file list closed the comparison')
assert(api.nvim_get_current_win()==r.right_win,'hiding the list lost the previous diff side')
R.toggle_panel()
assert(api.nvim_get_current_win()==r.panel_win and api.nvim_win_get_cursor(r.panel_win)[1]==selected[1],'showing the list lost its selection')
api.nvim_set_current_win(r.right_win)
R.select(1);R.select(1,true)
assert(r.left_buf==left and r.right_buf==right,'reselecting unchanged content rebuilt the diff')
assert(api.nvim_win_get_cursor(r.right_win)[1]==40 and vim.fn.foldclosed(1)==-1,'reselection reset cursor or fold state')
R.select(2);api.nvim_win_set_cursor(r.right_win,{70,0});R.select(1)
assert(api.nvim_win_get_cursor(r.right_win)[1]==40,'returning to a file lost its reading position')
R.show_panel(true);vim.cmd('bdelete')
assert(vim.wait(300,function()return not api.nvim_win_is_valid(r.panel_win) end,10),'deleting the file-list buffer did not hide it')
R.toggle_panel()
assert(R.current==r and api.nvim_win_is_valid(r.panel_win) and api.nvim_win_is_valid(r.left_win),'the file list did not reopen after buffer deletion')
assert(type(vim.fn.maparg('q','n',false,true).callback)=='function','the reopened list lost its mappings')
assert(r.tab==tab and #api.nvim_list_tabpages()==2,'toggling created another comparison')
api.nvim_set_current_win(r.right_win);vim.fn.maparg('<Space>e','n',false,true).callback()
vim.wait(50,function()return R.current==nil end,5)
assert(R.current==r and not api.nvim_win_is_valid(neo_win),'closing an independent tree closed the comparison')
C.close()
assert(api.nvim_get_current_win()==origin and vim.bo[source].modified,'toggling lost the original unsaved editor')
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

    def test_a_line_gone_from_the_after_copy_reads_as_removed_on_the_before_side(self):
        self.run_lua(r'''
C.open_review(row,root)
local r=R.current
local left, right = vim.wo[r.left_win].winhighlight, vim.wo[r.right_win].winhighlight
assert(left:find('DiffAdd:FoxReviewRemoved', 1, true), 'before side: a line found only there is a removal: ' .. left)
assert(left:find('DiffDelete:FoxReviewFiller', 1, true) and right:find('DiffDelete:FoxReviewFiller', 1, true), 'filler rows are faint')
assert(not right:find('DiffAdd:', 1, true), 'after side keeps added lines as added: ' .. right)
assert(vim.fn.hlexists('FoxReviewRemoved') == 1 and vim.fn.hlexists('FoxReviewFiller') == 1)
vim.cmd('colorscheme default')
assert(vim.fn.hlexists('FoxReviewRemoved') == 1, 'a colour scheme change keeps the review colours')
C.close()
''')

    def test_the_selection_bar_follows_the_cursor_and_the_open_file_keeps_a_quiet_band(self):
        self.run_lua(r'''
C.open_review(row,root)
local r=R.current
local function bars()
  local selection, open = {}, {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(r.panel_buf, -1, 0, -1, { details = true })) do
    local group = m[4].line_hl_group
    if group == 'FoxSymdepsSelection' or group == 'Visual' then selection[#selection + 1] = m[2] + 1 end
    if group == 'CursorLine' then open[#open + 1] = m[2] + 1 end
  end
  return selection, open
end
local open_line
for line, e in pairs(r.entries) do if e.file == r.index and not e.symbol then open_line = line end end
local other
for line, e in pairs(r.entries) do if e.file and e.file ~= r.index and not e.symbol then other = line; break end end
assert(open_line and other, 'the fixture needs two files in the list')
api.nvim_set_current_win(r.panel_win)
api.nvim_win_set_cursor(r.panel_win, { other, 0 })
api.nvim_exec_autocmds('CursorMoved', { buffer = r.panel_buf })
local selection, open = bars()
assert(vim.deep_equal(selection, { other }), 'the bar moves to the row under the cursor: ' .. vim.inspect(selection))
assert(vim.deep_equal(open, { open_line }), 'the open file keeps a quiet band: ' .. vim.inspect(open))
api.nvim_win_set_cursor(r.panel_win, { open_line, 0 })
api.nvim_exec_autocmds('CursorMoved', { buffer = r.panel_buf })
selection, open = bars()
assert(vim.deep_equal(selection, { open_line }) and #open == 0, 'on the open file, only the bar shows')
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
package.loaded['foxml.menu']={open=function(items) choices=items end}
R.actions()
package.loaded['foxml.menu']=nil
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

    def test_the_built_in_menu_follows_the_symdeps_rules_when_that_plugin_is_absent(self):
        self.run_lua(r'''
local Menu=require('foxml.menu')
local ran,toggled={},false
local items={
  {name='Check & next',label='Mark this file and open the next unread one.',group='review',bind='m',run=function() ran[#ran+1]='check' end},
  {name='Only what is new',label='Open an edited file against the copy you reviewed.',group='review',bind='n',stays=true,
   state=function() return toggled end,run=function() toggled=not toggled end},
  {name='Whitespace',label='Hide whitespace-only changes.',group='view',bind='<leader>rw',state=function() return false end,run=function() ran[#ran+1]='ws' end},
}
local laid=Menu.layout(items,{title='Review'})
local text=table.concat(laid.lines,'\n')
assert(text:find(' ── review ',1,true) and text:find(' ── view ',1,true),'groups sit under rule lines:\n'..text)
assert(text:find('○ off',1,true) and text:find('<ldr>rw',1,true),'state and shortcut columns:\n'..text)
assert(text:find('╭',1,true) and text:find('/ filter',1,true),'the strip and the footer:\n'..text)
local columns={}
for line,item in pairs(laid.rows) do
  local shown,text=item.bind:gsub('<[lL]eader>','<ldr>'),laid.lines[line]
  local trimmed=text:gsub('%s+$','')
  assert(trimmed:sub(-#shown)==shown,'the shortcut ends the row: '..text)
  columns[#columns+1]=vim.fn.strdisplaywidth(trimmed:sub(1,#trimmed-#shown))
end
assert(columns[1]==columns[2] and columns[2]==columns[3],'the shortcut column lines up: '..vim.inspect(columns))
assert(#Menu.layout(items,{filter='whitesp'}).lines<#laid.lines and vim.tbl_count(Menu.layout(items,{filter='whitesp'}).rows)==1,'the filter narrows')
local win=Menu.open(items,{title='Review',memo='test-menu'})
local buf=api.nvim_win_get_buf(win)
local function press(lhs) vim.fn.maparg(lhs,'n',false,true).callback() end
assert(laid.rows[api.nvim_win_get_cursor(win)[1]].name=='Check & next','it opens on the first row')
press('j')
assert(table.concat(api.nvim_buf_get_lines(buf,0,-1,false),'\n'):find('Open an edited file',1,true),'the strip follows the cursor')
press('<CR>')
assert(toggled and api.nvim_win_is_valid(win),'a toggle runs and the menu stays')
assert(table.concat(api.nvim_buf_get_lines(buf,0,-1,false),'\n'):find('● on',1,true),'and shows its new state')
press('k'); press('<CR>')
assert(ran[1]=='check' and not api.nvim_win_is_valid(win),'an action runs and the menu closes')
win=Menu.open(items,{title='Review',memo='test-menu'})
assert(laid.rows[api.nvim_win_get_cursor(win)[1]].name=='Check & next','the last choice is remembered')
press('q')
assert(not api.nvim_win_is_valid(win))
''')

    def test_a_change_request_waits_on_its_file_then_reads_ready_for_re_review_and_a_check_settles_it(self):
        source = self.repo / 'asked.lua'
        source.write_text('local a = 1\nreturn a\n')
        head = r'''
local file=root .. '/asked.lua'
local row={kind='live',sid='ask1',name='example',short='example',files={file}}
C.open_review(row,root)
local r=R.current
local function panel_text() return table.concat(api.nvim_buf_get_lines(r.panel_buf,0,-1,false),'\n') end
'''
        self.run_lua(head + r'''
C.live={{id='abc',name='A session'}}
vim.ui.select=function(items,opts,cb) cb(items[1]) end
vim.ui.input=function(opts,cb) cb('handle the empty case differently') end
api.nvim_set_current_win(r.right_win)
C.send({1,1})
local request=R.request_of(r,r.files[1])
assert(request and request.name=='A session' and request.text=='handle the empty case differently' and not request.ready,vim.inspect(request))
assert(panel_text():find('✉',1,true),'the row waits with an envelope:\n'..panel_text())
R.unread()
assert(panel_text():find('✉',1,true),'a file still with the session is not offered as unread')
-- withdrawn from the notebook: the shared store no longer lists it, so it is gone here too
do
  local rr=R.current
  local f=rr.files[rr.index]
  local kept=rr.shared_requests
  rr.shared_requests={}
  assert(R.request_of(rr,f)==nil or rr.row.kind=='commit','a withdrawn request no longer shows')
  rr.shared_requests=kept
end
C.close()
''')
        source.write_text('local a = 1\nif not a then return nil end\nreturn a\n')    # the session answered
        self.run_lua(head + r'''
R.select(1)
local request=R.request_of(r,r.files[1])
assert(request and request.ready,'the file changed after the request: '..vim.inspect(request))
assert(panel_text():find('↻ asked.lua',1,true),'the row reads as changed, not waiting:\n'..panel_text())
assert(panel_text():find('changed sin',1,true) and panel_text():find('✉ A session',1,true),'the strip says why and keeps the request:\n'..panel_text())
R.select(1); R.unread()
assert(r.files[r.index].rel=='asked.lua','a file ready for re-review is offered as unread')
R.mark()
assert(R.request_of(r,r.files[1])==nil,'checking the file settles the request')
C.close()
''')

    @unittest.skipUnless(WORK.exists(), 'build desk-work first')
    def test_requests_refresh_in_an_open_review_and_waiting_is_not_reported_as_checked(self):
        (self.repo / '.review-risk').write_text('a.lua\n')
        self.run_lua(r'''
local notices={}
vim.notify=function(text) notices[#notices+1]=text end
C.open_review({kind='live',sid='refresh1',name='example',short='example',files={root..'/a.lua'}},root)
local r=R.current
assert(vim.wait(3000,function() return r.shared_requests~=nil end,10))
assert(R.requested(root..'/a.lua',{id='abc',name='A session'},'handle the empty case'))
R.unread()
assert(notices[#notices]=='Waiting on 1 change request.',vim.inspect(notices))
assert(not R.finish(),'a waiting request must not finish the review')
local function backend(args)
  local argv={R.work_tool(),'review-request','--root',root,'--file','a.lua'}
  vim.list_extend(argv,args)
  local out=vim.system(argv,{text=true}):wait(3000)
  assert(out.code==0 and vim.json.decode(out.stdout).ok)
end
backend({'--text','a revised request','--sid','abc','--name','A session'})
R.select(1,true)
assert(R.request_of(r,r.files[1]).text=='a revised request','shared text must replace the local copy')
backend({'--clear','yes'})
api.nvim_exec_autocmds('FocusGained',{})
assert(vim.wait(3000,function() return R.request_of(r,r.files[1])==nil end,10),'withdrawal did not reach the open review')
R.unread()
assert(notices[#notices]~='Every file is checked. R finishes the review.','withdrawal is not a checkmark')
assert(vim.wait(3000,function() return not r.requests_pending end,10))
-- A read already in flight cannot undo a new request.
local system=vim.system
local delayed
vim.system=function(argv,opts,callback)
  if argv[2]=='review-requests' and callback then delayed=callback; return {} end
  return system(argv,opts,callback)
end
R.refresh_requests()
assert(delayed)
assert(R.requested(root..'/a.lua',{id='abc',name='A session'},'keep this one'))
delayed({code=0,stdout='[]'})
vim.wait(20)
vim.system=system
assert(R.request_of(r,r.files[1]).text=='keep this one','an old read erased a new request')
-- A failed read preserves the last known request, rather than settling it.
vim.system=function() return {wait=function() return {code=1,stdout='[]'} end} end
R.refresh_requests(true)
vim.system=system
assert(R.request_of(r,r.files[1]).text=='keep this one')
assert(notices[#notices]:find('Could not refresh change requests',1,true))
-- A failed shared write must leave the request pending and undo the local checkmark.
vim.system=function(argv,opts,callback)
  if argv[2]=='review-request' then return {wait=function() return {code=1,stdout='{}'} end} end
  return system(argv,opts,callback)
end
R.mark()
vim.system=system
assert(r.marks['a.lua']==nil,'a failed settlement must not check the file')
assert(R.request_of(r,r.files[1]).text=='keep this one')
C.close()
-- Reviewing a request on an old commit must not settle the current file's request.
C.open_review(row,root)
R.select(find('a.lua'))
assert(R.requested(root..'/a.lua',{id='abc',name='A session'},'about the old commit'))
R.mark()
local current=vim.system({R.work_tool(),'review-requests','--root',root},{text=true}):wait(3000)
assert(vim.json.decode(current.stdout)[1].text=='keep this one','checking an old commit settled a live request')
C.close()
''')

    @unittest.skipUnless(WORK.exists(), 'build desk-work first')
    def test_an_open_live_review_updates_on_a_shared_event_without_moving_focus(self):
        self.run_lua(r'''
local origin=api.nvim_get_current_tabpage()
C.open_review({kind='live',sid='events1',name='example',short='example',files={root..'/a.lua',root..'/added.txt'}},root)
local r=R.current
R.select(find('added.txt')); R.mark()
local checked=r.marks['added.txt']
R.select(find('a.lua'))
api.nvim_set_current_win(r.panel_win)
local file=root..'/a.lua'
local saved=assert(io.open(file,'rb')); local original=saved:read('*a'); saved:close()
local f=assert(io.open(file,'wb')); f:write('local value = 1000\nprint(value)\n'); f:close()
local out=vim.system({R.work_tool(),'signal','--root',root},{text=true}):wait(3000)
assert(out.code==0)
assert(vim.wait(6000,function() return content(r.right_buf):find('value = 1000',1,true)~=nil end,20),'the shared event did not refresh the open comparison')
assert(api.nvim_get_current_win()==r.panel_win,'a live refresh stole keyboard focus')
local events=require('foxml.work_events')
local state=events.roots[vim.uv.fs_realpath(root) or root]
local previous_pid=state.job.pid
state.job:kill(15) -- only the disposable review's owned watcher
assert(vim.wait(6000,function() return state.job.pid~=previous_pid and not state.watch_failed end,20),'the change stream did not reconnect')
local other=assert(io.open(root..'/added.txt','wb')); other:write('new text\nchanged again\n'); other:close()
vim.system({R.work_tool(),'signal','--root',root},{text=true}):wait(3000)
assert(vim.wait(6000,function() return r.files[find('added.txt')].signature~=checked end,20),'the unselected file kept a stale checkmark')
assert(content(r.right_buf):find('value = 1000',1,true),'refreshing another file changed the selection')
api.nvim_set_current_tabpage(origin)
f=assert(io.open(file,'wb')); f:write('local value = 2000\nprint(value)\n'); f:close()
vim.system({R.work_tool(),'signal','--root',root},{text=true}):wait(3000)
assert(vim.wait(6000,function() return r.live_dirty end,20),'the hidden review lost its invalidation')
assert(api.nvim_get_current_tabpage()==origin,'a hidden review took over the editing tab')
api.nvim_set_current_tabpage(r.tab)
assert(content(r.right_buf):find('value = 2000',1,true),'the review did not catch up on returning to its tab')
f=assert(io.open(file,'wb')); f:write(original); f:close()
other=assert(io.open(root..'/added.txt','wb')); other:write('new text\n'); other:close()
C.close()
assert(next(require('foxml.work_events').roots)==nil,'the review left its subscription behind')
''')

    def test_api_review_sends_exactly_the_displayed_change_and_is_remembered_for_that_version(self):
        self.run_lua(r'''
local asked
package.loaded['foxml.work']={api_available=function() return true end,
  api_question=function(question,done) asked=question; done({id='task-1'}) end}
C.open_review(row,root)
local r=R.current
R.select(find('a.lua'))
R.api_review('file')
assert(asked and asked:find('Review this change',1,true) and asked:find('+++ b/a.lua',1,true),'the question carries the displayed diff: '..tostring(asked))
assert(asked:find('\n+',1,true),'with its added lines')
local record=R.api_of(r,r.files[r.index])
assert(record and record.id=='task-1' and record.current==true and record.scope=='file',vim.inspect(record))
asked=nil
R.api_review('commit')
local n=0; for _ in asked:gmatch('%+%+%+ b/') do n=n+1 end
assert(n>=2 and n<=#r.files,'the whole change sends every file that is text: '..n..' of '..#r.files)
local items
package.loaded['foxml.menu']={open=function(list) items=list end}
R.actions()
local names={}; for _,item in ipairs(items) do names[item.name]=item end
assert(names['API review: file'] and names['API review: file'].right==nil,'offered when the API is set up')
assert(names['Open API review'],'the saved review can be opened')
package.loaded['foxml.work']={api_available=function() return false end,api_question=function() error('must not be asked') end}
R.actions()
names={}; for _,item in ipairs(items) do names[item.name]=item end
assert(names['API review: file'].right=='needs API' and names['API review: file'].label:find('Requires the API setup',1,true),'without the setup the row stays and says what it needs')
assert(names['API review: file'].label:find('API credits',1,true))
R.api_review('file')
C.close()
''')

    def test_an_api_citation_opens_the_version_that_was_reviewed_once_the_file_has_moved_on(self):
        (self.repo / 'plain.lua').write_text('local a = 1\nreturn a\n')
        self.run_lua(r'''
package.loaded['foxml.work']={api_available=function() return true end,api_question=function(_,done) done({id='task-9'}) end}
C.open_review({kind='live',sid='api9',name='example',short='example',files={root..'/plain.lua'}},root)
R.api_review('file')
local target=R.api_target(root,'task-9','plain.lua')
assert(target.current==true and target.path==root..'/plain.lua','unchanged: the citation opens the file itself: '..vim.inspect(target))
C.close()
''')
        (self.repo / 'plain.lua').write_text('-- a new first line\nlocal a = 1\nreturn a\n')
        self.run_lua(r'''
local target=R.api_target(root,'task-9','plain.lua')
assert(target.current==false and target.text=='local a = 1\nreturn a\n','changed: the kept version: '..vim.inspect(target))
R.api_jump(root,'task-9','plain.lua',2)
local buf=vim.api.nvim_get_current_buf()
assert(vim.b[buf].foxml_api_snapshot=='task-9' and vim.bo[buf].modifiable==false)
assert(vim.api.nvim_get_current_line()=='return a','line 2 of the reviewed version, not of the file now: '..vim.api.nvim_get_current_line())
assert(vim.api.nvim_buf_get_name(buf):find('as the API reviewed it',1,true))
assert(R.api_target(root,'task-9','never-sent.lua').current==true,'nothing kept: the working file')
''')

    def test_a_review_reopens_on_the_file_and_line_it_was_left_on(self):
        (self.repo / 'plain.lua').write_text('local a = 1\nlocal b = 2\nreturn a + b\n')
        (self.repo / 'other.lua').write_text('return 1\n')
        live = "{kind='live',sid='resume1',name='example',short='example',files={root..'/other.lua',root..'/plain.lua'}}"
        self.run_lua(r'''
C.open_review(%s,root)
local r=R.current
for i,f in ipairs(r.files) do if f.rel=='plain.lua' then R.select(i) end end
vim.api.nvim_win_set_cursor(R.current.right_win,{3,0})
C.close()
''' % live)
        self.run_lua(r'''
C.open_review(%s,root)
local r=R.current
assert(r.files[r.index].rel=='plain.lua','the file it was left on: '..r.files[r.index].rel)
assert(vim.api.nvim_win_get_cursor(r.right_win)[1]==3,'and the line')
C.close()
''' % live)

    def test_review_next_uses_the_backends_review_projection_without_reordering(self):
        self.run_lua(r'''
local answer='[{"kind":"request","file":"b.lua","why":"Changed since you asked Queue"},{"kind":"changed","file":"c.lua"}]'
R.work_tool=function() return 'desk-work' end
local real=vim.system
vim.system=function(argv,opts) if argv[1]~='desk-work' then return real(argv,opts) end
  assert(argv[2]=='attention' and argv[5]=='--scope' and argv[6]=='review',vim.inspect(argv))
  return {wait=function() return {code=0,stdout=answer} end} end
local item=R.next_item(root)
assert(item.kind=='request' and item.file=='b.lua' and item.why:find('Queue',1,true),vim.inspect(item))
answer='[{"kind":"changed","file":"c.lua"}]'
item=R.next_item(root); assert(item.kind=='changed' and item.file=='c.lua',vim.inspect(item))
answer='[{"kind":"commit","sha":"'..string.rep('a',40)..'"}]'
item=R.next_item(root); assert(item.kind=='commit' and item.sha==string.rep('a',40),vim.inspect(item))
answer='[]'
assert(R.next_item(root)==nil,'nothing left')
R.work_tool=function() return nil end
local none,why=R.next_item(root); assert(none==nil and why:find('work tool',1,true))
vim.system=real
''')

    def test_a_plan_that_names_no_files_is_covered_by_the_step_recorded_on_each_commit(self):
        (self.repo / 'plan.md').write_text('# Tidy\n1. Split the header\n2. Move the workers\n3. Write it up\n')
        self.run_lua(r'''
local plan=root..'/plan.md'
local r={row={kind='commit',plan=plan,short='aaa1111'},root=root,files={},sets={
  {row={kind='commit',plan=plan,short='aaa1111',step='step 1 · split'},files={}},
  {row={kind='commit',plan=plan,short='bbb2222',step='Move the workers'},files={}},
  {row={kind='commit',plan=plan,short='ccc3333',subject='Odd one',step=''},files={}}}}
local data=R.plan_coverage_data(r)
assert(data.recorded and #data.steps==3,vim.inspect(data))
assert(data.steps[1].commits[1]=='aaa1111' and data.steps[2].commits[1]=='bbb2222' and #data.steps[3].commits==0,vim.inspect(data.steps))
assert(#data.outside==1 and data.outside[1].where=='no step recorded' and data.outside[1].commit,vim.inspect(data.outside))
''')

    def test_margin_notes_stay_with_the_file_follow_their_line_and_mark_the_row(self):
        (self.repo / 'plain.lua').write_text('local a = 1\nlocal b = 2\nreturn a + b\n')
        self.run_lua(r'''
C.open_review({kind='live',sid='notes1',name='example',short='example',files={root..'/plain.lua'}},root)
local r=R.current
vim.api.nvim_set_current_win(r.right_win); vim.api.nvim_win_set_cursor(r.right_win,{2,0})
vim.ui.input=function(opts,done) assert(opts.prompt=='Note to self: ',opts.prompt); done('check b again') end
R.note_here()
local notes=R.notes(root)
assert(#notes['plain.lua']==1 and notes['plain.lua'][1].line==2 and notes['plain.lua'][1].context=='local b = 2',vim.inspect(notes))
local marks=vim.api.nvim_buf_get_extmarks(r.right_buf,vim.api.nvim_create_namespace('foxml_review_notes'),0,-1,{details=true})
assert(#marks==1 and marks[1][2]==1 and marks[1][4].virt_text[1][1]:find('check b again',1,true),vim.inspect(marks))
local panel=table.concat(vim.api.nvim_buf_get_lines(r.panel_buf,0,-1,false),'\n')
assert(panel:find('✎',1,true),'the row carries the note mark: '..panel)
-- the line moved down two: the note follows its text
assert(R.note_line(notes['plain.lua'][1],{'-- new','-- new','local a = 1','local b = 2'})==4)
local line,found=R.note_line(notes['plain.lua'][1],{'x','y'}); assert(line==2 and found==false)
local items
package.loaded['foxml.menu']={open=function(list,opts) items=list; assert(opts.title=='My notes · 1',opts.title) end}
R.notes_list()
assert(items[1].group=='plain.lua' and items[1].right=='line 2' and items[1].name=='check b again')
vim.ui.input=function(opts,done) assert(opts.default=='check b again'); done('') end
vim.api.nvim_set_current_win(r.right_win); vim.api.nvim_win_set_cursor(r.right_win,{2,0})
R.note_here()
assert(next(R.notes(root))==nil,'an empty note removes it')
C.close()
''')

    def test_plan_coverage_goes_by_the_files_each_step_names(self):
        (self.repo / 'plain.lua').write_text('return 1\n')
        (self.repo / 'extra.lua').write_text('return 3\n')
        (self.repo / 'plan.md').write_text('# Plan: tidy the queue\n1. Change `plain.lua`\n2. Then `later.lua`\n')
        self.run_lua(r'''
package.loaded['foxml.planmarks']=nil
local P=require('foxml.planmarks'); P.plan={title='Plan: tidy the queue',file=root..'/plan.md'}
C.open_review({kind='live',sid='cov1',name='example',short='example',files={root..'/plain.lua',root..'/extra.lua'}},root)
local r=R.current
local data=R.plan_coverage_data(r)
assert(data and data.title=='Plan: tidy the queue',vim.inspect(data))
assert(#data.steps==2 and data.steps[1].label=='1 · Change plain.lua' and #data.steps[1].commits==1,'step 1 was touched: '..vim.inspect(data.steps))
assert(#data.steps[2].commits==0,'step 2 names a file nothing changed: not started')
assert(#data.outside==1 and data.outside[1].rel=='extra.lua','a changed file no step names: '..vim.inspect(data.outside))
local items
package.loaded['foxml.menu']={open=function(list,opts) items=list; assert(opts.title:find('Plan coverage',1,true)) end}
R.plan_coverage()
assert(items[1].right=='example' and items[2].right=='no matching edits' and items[3].group=='outside the plan',vim.inspect(items))
P.plan=nil
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
end}
package.loaded['fox-symdeps.context']={under_cursor=function() return {file=api.nvim_buf_get_name(0),bufnr=api.nvim_get_current_buf(),line=1} end}
package.preload['fox-symdeps.card']=function() error('an older symdeps: no card module') end
R.symdeps(false)
assert(inspected,'changed symbol was not sent to symdeps')
-- a newer symdeps keeps the card in its own module: that one is preferred
local by_card=false
package.preload['fox-symdeps.card']=nil
package.loaded['fox-symdeps.card']={inspect_cursor=function() by_card=true end}
inspected=false
R.symdeps(false)
assert(by_card and not inspected,'the card module is used when it exists')
package.loaded['fox-symdeps.card']=nil
package.preload['fox-symdeps.card']=function() error('an older symdeps: no card module') end
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

    def test_a_burst_of_work_events_over_a_large_change_never_stalls_the_editor(self):
        # 300 changed files, every one loaded, then 50 project signals in about a second through the real watcher: the
        # longest gap between 10 ms heartbeats must stay short. Before committed copies were cached, each event re-read
        # every loaded file with its own blocking git process (seconds per event at this size).
        bulk = self.repo / 'bulk'
        bulk.mkdir()
        for i in range(300):
            (bulk / f'f{i}.lua').write_text(f'local value = {i}\nreturn value\n')
        self.git('add', 'bulk')
        self.commit('bulk')
        for i in range(300):
            (bulk / f'f{i}.lua').write_text(f'local value = {i + 1}\nreturn value\n')
        limit = int(os.environ.get('TEST_STALL_LIMIT_MS', '250'))
        self.run_lua(r'''
local uv = vim.uv or vim.loop
local files = {}
for i = 0, 299 do files[#files + 1] = root .. '/bulk/f' .. i .. '.lua' end
C.open_review({kind='live', sid='burst', name='burst', short='burst', files=files}, root)
local r = R.current
assert(vim.wait(25000, function()
  for _, f in ipairs(r.files) do if not f.loaded then return false end end
  return true
end, 20), 'the background loader did not load every file')
local last, worst, ticks = uv.hrtime(), 0, 0
local beat = uv.new_timer()
beat:start(10, 10, vim.schedule_wrap(function()
  local now = uv.hrtime(); worst = math.max(worst, (now - last) / 1e6); last = now; ticks = ticks + 1
end))
local refreshed = 0
local unsubscribe = require('foxml.work_events').subscribe(root, function() refreshed = refreshed + 1 end)
local signals = vim.system({'sh', '-c', 'i=0; while [ $i -lt 50 ]; do desk-work signal --root "$1" >/dev/null; sleep 0.02; i=$((i+1)); done', '_', root})
assert(vim.wait(20000, function() return signals:is_closing() end, 10), 'the signal burst did not finish')
vim.wait(1500, function() return false end, 10)
beat:stop(); beat:close(); unsubscribe()
io.stdout:write(('stall: worst %.0f ms over %d heartbeats, %d refreshes\n'):format(worst, ticks, refreshed))
assert(refreshed > 0, 'the burst must have reached the review')
assert(worst < ''' + str(limit) + r''', ('the editor stalled for %.0f ms during the burst'):format(worst))
C.close()
''')


if __name__ == '__main__':
    unittest.main()
