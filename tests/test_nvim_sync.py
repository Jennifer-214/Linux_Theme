"""Real file events, atomic saves and simultaneous local/agent edits."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from fixture_process import run as run_fixture

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('nvim') and shutil.which('git'), 'Neovim and Git required')
class NvimSync(unittest.TestCase):
    def exercise(self, code):
        with tempfile.TemporaryDirectory(prefix='nvim-live-') as tmp:
            base = Path(tmp)
            path = base/'sample.lua'
            path.write_text('local first = 1\n\nlocal middle = 2\n\nlocal last = 3\n')
            env = os.environ | {'TEST_SYNC_LUA':str(ROOT/'shared/nvim_lua'), 'TEST_SYNC_FILE':str(path),
                                'XDG_STATE_HOME':str(base/'state'), 'XDG_CACHE_HOME':str(base/'cache'),
                                'XDG_RUNTIME_DIR':str(base/'runtime'), 'NVIM_LOG_FILE':str(base/'nvim.log')}
            (base/'runtime').mkdir()
            script = base/'exercise.lua'
            script.write_text(r'''
package.path = vim.env.TEST_SYNC_LUA .. '/?.lua;' .. package.path
for _,name in ipairs({'sync','review','claude'}) do package.loaded['foxml.'..name]=dofile(vim.env.TEST_SYNC_LUA..'/foxml/'..name..'.lua') end
vim.g.mapleader=' '
vim.opt.autoread=true
vim.opt.hidden=true
vim.opt.autowriteall=true
local api=vim.api
local S=require('foxml.sync')
local path=vim.env.TEST_SYNC_FILE
local function disk(text,atomic)
  local target=atomic and path..'.new' or path
  local f=assert(io.open(target,'wb'));f:write(text);f:close()
  if atomic then assert(vim.uv.fs_rename(target,path)) end
end
S.setup()
vim.cmd.edit(vim.fn.fnameescape(path))
local buf=api.nvim_get_current_buf()
assert(S.buffers[buf] and next(S.watchers))
''' + code)
            result = run_fixture(['nvim','--headless','--clean','-l',str(script)],cwd=base,env=env,
                                    capture_output=True,text=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_atomic_agent_save_updates_without_focus_or_idle_event(self):
        self.exercise(r'''
api.nvim_win_set_cursor(0,{3,2})
disk('local first = 9\n\nlocal middle = 2\n\nlocal last = 3\n',true)
assert(vim.wait(2000,function() return api.nvim_buf_get_lines(buf,0,1,false)[1]=='local first = 9' end,20),'file event did not reload clean buffer')
assert(not vim.bo[buf].modified and api.nvim_win_get_cursor(0)[1]==3)
assert(S.status()=='updated externally')
api.nvim_buf_delete(buf,{force=true})
assert(next(S.watchers)==nil,'unused directory watcher remained')
''')

    def test_unavailable_auto_reload_does_not_acknowledge_unread_disk_changes(self):
        self.exercise(r'''
vim.opt.autoread=false
disk('local first = 9\n\nlocal middle = 2\n\nlocal last = 3\n',true)
assert(vim.wait(500,function()return S.buffers[buf].pending~=nil end,10),'unread changes were acknowledged as reloaded')
assert(api.nvim_buf_get_lines(buf,0,1,false)[1]=='local first = 1')
assert(S.buffers[buf].base:find('first = 1',1,true),'baseline advanced past unread edits')
assert(not pcall(vim.cmd.write),'saving could overwrite an unread agent change')
''')

    def test_unsaved_edits_are_preserved_compared_and_cleanly_merged(self):
        self.exercise(r'''
api.nvim_buf_set_lines(buf,0,1,false,{'local first = 100'})
disk('local first = 1\n\nlocal middle = 2\n\nlocal last = 300\n',true)
assert(vim.wait(2000,function() return S.buffers[buf].pending~=nil end,20))
assert(api.nvim_buf_get_lines(buf,0,1,false)[1]=='local first = 100')
local saved=pcall(vim.cmd.write)
assert(not saved,'save silently overwrote outside edits')
S.compare()
local R=require('foxml.review')
assert(R.current and R.current.row.kind=='external')
assert(table.concat(api.nvim_buf_get_lines(R.current.left_buf,0,-1,false),'\n'):find('first = 100',1,true))
assert(table.concat(api.nvim_buf_get_lines(R.current.right_buf,0,-1,false),'\n'):find('last = 300',1,true))
require('foxml.claude').close()
assert(api.nvim_get_current_buf()==buf)
S.merge()
assert(S.buffers[buf].pending==nil)
assert(api.nvim_buf_get_lines(buf,0,1,false)[1]=='local first = 100')
assert(api.nvim_buf_get_lines(buf,4,5,false)[1]=='local last = 300')
assert(vim.bo[buf].modified,'merge saved the working file')
local f=assert(io.open(path,'rb'));local text=f:read('*a');f:close()
assert(text:find('first = 1\n',1,true),'merge wrote local work to disk')
vim.cmd.write()
f=assert(io.open(path,'rb'));text=f:read('*a');f:close()
assert(text:find('first = 100',1,true) and text:find('last = 300',1,true))
''')

    def test_overlapping_agent_edits_are_never_applied_as_conflict_markers(self):
        self.exercise(r'''
api.nvim_buf_set_lines(buf,0,1,false,{'local first = 100'})
disk('local first = 900\n\nlocal middle = 2\n\nlocal last = 3\n',true)
assert(vim.wait(2000,function()return S.buffers[buf].pending~=nil end,20))
S.merge()
assert(S.buffers[buf].pending~=nil)
assert(api.nvim_buf_get_lines(buf,0,1,false)[1]=='local first = 100')
assert(not table.concat(api.nvim_buf_get_lines(buf,0,-1,false),'\n'):find('<<<<<<<',1,true))
S.keep(); assert(S.buffers[buf].pending==nil and vim.bo[buf].modified)
''')

    def test_attaching_to_an_already_modified_buffer_never_invents_a_merge_baseline(self):
        self.exercise(r'''
S.detach(buf)
api.nvim_buf_set_lines(buf,0,1,false,{'local first = 100'})
S.track(buf)
assert(S.buffers[buf].base==nil,'an unsaved buffer has no known shared baseline at first attach')
disk('local first = 1\n\nlocal middle = 2\n\nlocal last = 300\n',true)
assert(vim.wait(2000,function() return S.buffers[buf].pending~=nil end,20))
S.merge()
assert(api.nvim_buf_get_lines(buf,0,1,false)[1]=='local first = 100','a guessed baseline lost local edits')
assert(S.buffers[buf].pending~=nil)
''')


    def test_a_new_file_saves_and_an_untouched_empty_file_is_not_an_outside_edit(self):
        # An empty buffer read as one newline never matched an empty file (or a missing one), so opening an empty
        # file warned of outside edits and saving any new file was refused.
        self.exercise(r'''
local new = vim.fs.dirname(path) .. '/brand-new.txt'
vim.cmd.edit(vim.fn.fnameescape(new))
api.nvim_buf_set_lines(0, 0, -1, false, {'hello'})
api.nvim_exec_autocmds('CursorHold', {})
assert(S.status() == '', 'a never-saved file reads as: ' .. S.status())
local ok, err = pcall(vim.cmd.write)
assert(ok, 'saving a new file was refused: ' .. tostring(err))
local empty = vim.fs.dirname(path) .. '/empty.txt'
local f = assert(io.open(empty, 'wb')); f:close()
vim.cmd.edit(vim.fn.fnameescape(empty))
local b = api.nvim_get_current_buf()
api.nvim_exec_autocmds('CursorHold', {})
assert(S.buffers[b].pending == nil, 'an untouched empty file reads as outside edits waiting')
api.nvim_buf_set_lines(b, 0, -1, false, {'typed'})
ok, err = pcall(vim.cmd.write)
assert(ok, 'saving an empty file was refused: ' .. tostring(err))
''')

if __name__ == '__main__': unittest.main()
