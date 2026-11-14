"""Project resume keeps unsaved buffers and running terminal jobs, without requiring symdeps."""
import importlib.util
from pathlib import Path
import shutil
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(shutil.which('nvim') and (ROOT/'src/desk-work/desk-work').exists(), 'Neovim and desk-work required')
class Workspace(unittest.TestCase):
    def test_resume_preserves_running_terminal_and_local_edits(self):
        spec = importlib.util.spec_from_file_location('workspace_fixture', ROOT/'tests/test_nvim_review.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        fixture = module.NvimReview('test_exact_snapshots_navigation_notes_and_editor_restoration')
        fixture.setUp()
        try:
            fixture.run_lua(r'''
local W=require('foxml.workspace')
vim.cmd.edit(root..'/a.lua')
local source=api.nvim_get_current_buf()
api.nvim_win_set_cursor(0,{2,0})
W.save(true)
api.nvim_buf_set_lines(source,0,1,false,{'local draft = 10'})
vim.cmd.tabnew()
local terminal=api.nvim_get_current_buf()
local job=vim.fn.jobstart({'sleep','30'},{term=true})
assert(job>0)
local terminal_tab=api.nvim_get_current_tabpage()
W.resume()
assert(api.nvim_tabpage_is_valid(terminal_tab),'restoring a project closed a terminal tab')
assert(api.nvim_buf_is_valid(terminal),'restoring a project deleted a terminal buffer')
assert(vim.fn.jobwait({job},0)[1]==-1,'restoring a project ended its running command')
assert(vim.bo[source].modified and content(source):find('local draft = 10',1,true),'restoring a project replaced unsaved text')
assert(api.nvim_get_current_buf()==source and api.nvim_win_get_cursor(0)[1]==2,'the saved file and cursor were not restored')
require('foxml.work').health()
assert(content(api.nvim_get_current_buf()):find('# Work health',1,true),'health diagnostics did not open')
assert(vim.bo[source].modified and content(source):find('local draft = 10',1,true),'opening health replaced unsaved text')
assert(vim.fn.jobwait({job},0)[1]==-1,'opening health ended a terminal command')
vim.fn.jobstop(job) -- only this fixture's sleep process
''')
        finally: fixture.doCleanups()

if __name__=='__main__': unittest.main()
