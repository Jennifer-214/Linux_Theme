#!/usr/bin/env python3
"""Exercise real Vim marks, folds, and optional local symdeps UI without loading user init."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NVIM = shutil.which('nvim')
RENDER = ROOT/'src/fox-render/fox-render-fast'

DRIVER = r'''
vim.g.mapleader=' '
local source = table.concat(vim.fn.readfile(vim.env.NOTEBOOK_INIT), "\n")
assert(loadstring(source), "rendered init does not parse")
local palette = source:match('(local P = %b{})')
local block = source:match('%-%- >>> fox%-paper%-details\n(.-)\n%-%- <<< fox%-paper%-details')
local folds = source:match('(function _G.FoxCommentFoldExpr%(%)\n.-)\n%-%- === Per%-project settings ===')
assert(palette and block and folds)
local footer = source:match('(local function paper_footer_mode.-)\n%-%- Treesitter — main branch')
local lualine = vim.env.NOTEBOOK_LUALINE
if lualine and lualine ~= '' then vim.opt.rtp:append(lualine) else footer = '' end
local Paper = assert(loadstring('local map = vim.keymap.set\n' .. palette .. '\n' .. block .. '\n' .. footer .. '\n' .. folds .. '\nreturn Paper'))()
assert(Paper.enabled)
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, vim.env.NOTEBOOK_SOURCE)
vim.bo.filetype = 'cpp'
vim.wo.signcolumn = 'yes:2'
vim.wo.winbar = 'existing symdeps size chip'
vim.wo.statusline = 'existing footer'
local lines = {'struct Note {', '  int count;', '  // Keep these notes together.', '  // A second comment line.', '  // And a third.', '  bool marked;', '};'}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.api.nvim_buf_set_mark(buf, 'a', 2, 0, {})
vim.api.nvim_buf_set_mark(buf, 'b', 6, 0, {})
vim.api.nvim_buf_set_mark(buf, 'A', 1, 0, {})
Paper.refresh(buf)
local function marks() return vim.api.nvim_buf_get_extmarks(buf, Paper.namespace, 0, -1, {details=true}) end
assert(#marks() == 3, 'local and global named marks must get ribbons')
local foreign = vim.api.nvim_create_namespace('symdeps_fixture_annotations')
vim.api.nvim_buf_set_extmark(buf, foreign, 1, 0, {sign_text='!',priority=100})
local diagnostics = vim.api.nvim_create_namespace('symdeps_fixture_diagnostics')
vim.diagnostic.set(diagnostics, buf, {{lnum=1,col=0,message='fixture',severity=vim.diagnostic.severity.ERROR}})
Paper.refresh(buf)
assert(#vim.api.nvim_buf_get_extmarks(buf, foreign, 0, -1, {}) == 1)
assert(#vim.diagnostic.get(buf, {namespace=diagnostics}) == 1)
for _, mark in ipairs(marks()) do assert(mark[4].priority < 10, 'bookmark displaced higher-priority signs') end
assert(vim.wo.signcolumn == 'yes:2' and vim.wo.winbar == 'existing symdeps size chip')
vim.api.nvim_buf_set_lines(buf, 0, 0, false, {'// inserted above'})
Paper.refresh(buf)
local arow
for _, mark in ipairs(marks()) do if mark[4].sign_text == 'a' then arow=mark[2] end end
assert(arow == 2, 'bookmark did not follow the native mark after an edit')
vim.api.nvim_buf_del_mark(buf,'b'); Paper.refresh(buf)
assert(#marks() == 2, 'deleted mark left a ribbon behind')
local old_foldtext = vim.wo.foldtext
local toggle = vim.fn.maparg('<Space>tc','n',false,true).callback
assert(type(toggle)=='function')
local parser = vim.env.NOTEBOOK_CPP_PARSER
if parser and parser ~= '' then
  vim.treesitter.language.add('cpp',{path=parser})
  vim.treesitter.get_parser(buf,'cpp'):parse()
  toggle()
  assert(vim.wo.foldtext == 'v:lua.FoxPaperFoldText()')
  assert(vim.fn.foldclosed(4) == 4, 'indented comments did not fold')
  local text = vim.fn.foldtextresult(4)
  assert(text:find('Keep these notes together',1,true) and text:find('3 lines',1,true),vim.inspect(text))
  assert(vim.fn.foldclosed(3) == -1 and vim.fn.foldclosed(7) == -1, 'fold swallowed code')
  toggle()
  assert(vim.wo.foldtext == old_foldtext, 'toggle did not restore the existing fold text')
end
local plugin = vim.env.NOTEBOOK_SYMDEPS
if plugin and plugin ~= '' then
  vim.opt.rtp:append(plugin)
  local hud = require('fox-symdeps.hud').open({symbol='fixture',kind='function',bufnr=buf,file=vim.env.NOTEBOOK_SOURCE}, {}, {mode='panel'})
  local winbar, signcolumn, foldtext = vim.wo[hud.win].winbar, vim.wo[hud.win].signcolumn, vim.wo[hud.win].foldtext
  Paper.refresh(hud.buf)
  vim.api.nvim_exec_autocmds('CursorHold',{buffer=hud.buf})
  if lualine and lualine ~= '' then require('lualine').refresh({scope='all',place={'statusline','winbar'}}) end
  vim.wait(120)
  assert(not Paper.file_buffer(hud.buf) and #vim.api.nvim_buf_get_extmarks(hud.buf,Paper.namespace,0,-1,{})==0)
  assert(vim.wo[hud.win].winbar == winbar and vim.wo[hud.win].signcolumn == signcolumn)
  vim.api.nvim_set_current_win(hud.win);toggle()
  assert(vim.wo[hud.win].foldtext == foldtext, 'comment toggle altered symdeps folds')
  assert(vim.fn.maparg('q','n',false,true).buffer==1,'symdeps local navigation was lost')
  hud:close()
  print('Actual symdeps panel: bookmark exclusion, winbar, gutter, folds and local navigation passed')
else
  print('symdeps is not installed here; real-plugin panel check skipped')
end
assert(vim.wo.winbar == 'existing symdeps size chip')
print('PAPER_NOTEBOOK_ASSERTIONS_PASSED')
vim.cmd('qa!')
'''

@unittest.skipUnless(NVIM and RENDER.exists(), 'build fox-render-fast and install nvim')
class PaperNotebook(unittest.TestCase):
    def test_marks_folds_and_symdeps_panel(self):
        with tempfile.TemporaryDirectory(prefix='foxml-notebook-test-') as temp:
            base=Path(temp)
            rendered=base/'rendered'
            subprocess.run([str(RENDER),str(ROOT/'themes/FoxML_Paper/palette.sh'),str(ROOT/'templates/nvim'),str(rendered)],check=True,capture_output=True)
            driver=base/'driver.lua';driver.write_text(DRIVER)
            plugin=Path.home()/'code/tick-trader-percore-workspace/tools/plugins/fox-symdeps.nvim'
            parser=Path.home()/'.local/share/nvim/site/parser/cpp.so'
            lualine=Path.home()/'.local/share/nvim/lazy/lualine.nvim'
            env=os.environ|{'NOTEBOOK_INIT':str(rendered/'init.lua'),'NOTEBOOK_SOURCE':str(base/'note.cpp'),
                            'NOTEBOOK_SYMDEPS':str(plugin) if plugin.is_dir() else '',
                            'NOTEBOOK_CPP_PARSER':str(parser) if parser.is_file() else '',
                            'NOTEBOOK_LUALINE':str(lualine) if lualine.is_dir() else '',
                            'XDG_STATE_HOME':str(base/'state'),'XDG_CACHE_HOME':str(base/'cache'),'NVIM_LOG_FILE':str(base/'nvim.log')}
            result=subprocess.run([NVIM,'--clean','--headless','-l',str(driver)],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('PAPER_NOTEBOOK_ASSERTIONS_PASSED',result.stdout+result.stderr)
            if plugin.is_dir():self.assertIn('Actual symdeps panel:',result.stdout+result.stderr)
            print((result.stdout+result.stderr).strip())

    def test_session_selector_marks_bells_without_changing_targets(self):
        with tempfile.TemporaryDirectory(prefix='.notebook-session-',dir=ROOT/'tests') as temp:
            base=Path(temp);bins=base/'bin';bins.mkdir()
            fake=bins/'tmux'
            fake.write_text("#!/usr/bin/python3\n" +
                "import os,sys\n" +
                "a=sys.argv[1:]\n" +
                "if a[0]=='display-message':print('active')\n" +
                "elif a[0]=='list-sessions':print('active\\nother')\n" +
                "elif a[0]=='list-panes':print('1.0\\t%1\\t/dev/null\\t1\\tnvim\\t'+('1' if a[a.index('-t')+1]=='other' and os.environ.get('TEST_BELL')=='1' else '0'))\n")
            fake.chmod(0o755)
            zoxide=bins/'zoxide';zoxide.write_text('#!/bin/sh\nexit 0\n');zoxide.chmod(0o755)
            env=os.environ|{'HOME':str(base),'XDG_DATA_HOME':str(base/'data'),'PATH':str(bins)+':/usr/bin:/bin','FOX_SESH_BELL':'b8336a'}
            for enabled in (False,True):
                result=subprocess.run(['/bin/bash',str(ROOT/'shared/bin/tmux-sessionizer'),'--list'],env=env|{'TEST_BELL':'1' if enabled else '0'},text=True,capture_output=True,timeout=5)
                self.assertEqual(result.returncode,0,result.stderr)
                rows=[row.split('\t') for row in result.stdout.splitlines()]
                self.assertEqual([row[-1] for row in rows],['active','other'])
                self.assertEqual('\x1b[38;2;184;51;106m●' in rows[1][1],enabled)
                self.assertNotIn('\x1b[38;2;184;51;106m●',rows[0][1])

    @unittest.skipUnless(shutil.which('tmux'), 'tmux is not installed')
    def test_tmux_bell_dot_uses_existing_window_flag(self):
        with tempfile.TemporaryDirectory(prefix='foxml-notebook-tmux-') as temp:
            base=Path(temp);out=base/'rendered';socket=base/'tmux.sock'
            subprocess.run([str(RENDER),str(ROOT/'themes/FoxML_Paper/palette.sh'),str(ROOT/'templates/tmux'),str(out)],check=True,capture_output=True)
            env=os.environ.copy();env.pop('TMUX',None)
            def tmux(*args, check=True):
                return subprocess.run(['tmux','-S',str(socket),*args],env=env,cwd=base,check=check,capture_output=True,text=True,timeout=5)
            try:
                tmux('-f',str(out/'.tmux.conf'),'new-session','-d','-s','notebook','sleep','30')
                self.assertEqual(tmux('show-options','-gv','status').stdout.strip(),'off')
                self.assertEqual(tmux('show-options','-gv','monitor-bell').stdout.strip(),'on')
                text=tmux('show-options','-gv','pane-border-format').stdout.strip()
                self.assertIn('window_bell_flag',text)
                for bell in (False,True):
                    sample=text.replace('window_bell_flag','#{==:1,'+('1' if bell else '0')+'}')
                    label=tmux('display-message','-p','-F',sample).stdout.strip()
                    self.assertEqual('●' in label,bell)
                    self.assertNotIn('#{',label)
                    if bell:self.assertIn('#b8336a',label)
            finally:
                tmux('kill-server',check=False)

    def test_all_theme_configs_render_and_parse(self):
        with tempfile.TemporaryDirectory(prefix='foxml-notebook-themes-') as temp:
            for palette in sorted((ROOT/'themes').glob('*/palette.sh')):
                with self.subTest(theme=palette.parent.name):
                    out=Path(temp)/palette.parent.name
                    subprocess.run([str(RENDER),str(palette),str(ROOT/'templates'),str(out)],check=True,capture_output=True)
                    kitty=(out/'kitty/kitty.conf').read_text()
                    expected='hidden' if palette.parent.name=='FoxML_Paper' else 'powerline'
                    self.assertIn('tab_bar_style              '+expected,kitty)
                    driver=Path(temp)/'parse.lua'
                    driver.write_text('assert(loadfile('+json.dumps(str(out/'nvim/init.lua'))+')); vim.cmd("qa!")')
                    result=subprocess.run([NVIM,'--clean','--headless','-l',str(driver)],env=os.environ|{'NVIM_LOG_FILE':str(Path(temp)/'nvim.log')},capture_output=True,text=True,timeout=5)
                    self.assertEqual(result.returncode,0,result.stderr)

if __name__=='__main__':unittest.main()
