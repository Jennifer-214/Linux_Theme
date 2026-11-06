"""Exercise the cover with real Snacks history and filenames, without user init."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SNACKS = Path.home()/'.local/share/nvim/lazy/snacks.nvim'

@unittest.skipUnless(shutil.which('nvim') and SNACKS.exists(), 'Neovim and Snacks are required')
class NotebookCover(unittest.TestCase):
    def test_native_actions_recent_paths_and_narrow_cover(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            render = root/'rendered'
            subprocess.run([str(ROOT/'src/fox-render/fox-render-fast'), str(ROOT/'themes/FoxML_Paper/palette.sh'), str(ROOT/'templates/nvim'), str(render)], check=True, capture_output=True)
            recent = root/'a | little #page.md'; recent.write_text('one little page')
            driver = root/'check.lua'
            driver.write_text('''
vim.opt.rtp:append('''+json.dumps(str(SNACKS))+''')
require('snacks').setup({dashboard={enabled=false}})
local source=table.concat(vim.fn.readfile('''+json.dumps(str(render/'init.lua'))+'''), '\\n')
local block=assert(source:match('(function Paper.notebook_sections%(dashboard%).-\\nend)'))
local cover=assert(loadstring('local Paper={}\\n'..block..'\\nreturn Paper.notebook_sections'))()
local path='''+json.dumps(str(recent))+'''
vim.v.oldfiles={path,'/not/a/real/recent/file'}
local keys={}
for _,key in ipairs({'f','g','r','p','s','l','q'}) do keys[#keys+1]={key=key,desc='native '..key,action=function() vim.g.native_action=key end} end
for _,width in ipairs({80,42}) do
 vim.o.columns=width
 local rows=cover({opts={width=60,preset={keys=keys}}})
 local actions={}
 for _,row in ipairs(rows) do
  local line=''
  for _,part in ipairs(row.text) do line=line..part[1] end
  assert(vim.fn.strdisplaywidth(line)<=math.min(60,width-8),line)
  if row.key then actions[row.key]=row.action end
 end
 for _,key in ipairs({'f','g','r','p','s','l','q'}) do assert(actions[key]);actions[key]();assert(vim.g.native_action==key) end
 assert(actions.n and actions['1'] and not actions['2'])
 actions['1']();assert(vim.api.nvim_buf_get_name(0)==path,'recent filename lost its literal characters')
end
vim.cmd('qa!')
''')
            result = subprocess.run(['nvim','--clean','--headless','-i','NONE','-l',str(driver)], cwd=root,
                env=os.environ|{'XDG_CACHE_HOME':str(root/'cache'),'XDG_STATE_HOME':str(root/'state'),'NVIM_LOG_FILE':str(root/'nvim.log')}, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

if __name__=='__main__': unittest.main()
