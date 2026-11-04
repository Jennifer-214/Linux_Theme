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
for _, mark in ipairs(marks()) do if mark[4].sign_text == '󰃀a' then arow=mark[2] end end
assert(arow == 2, 'bookmark did not follow the native mark after an edit')
vim.api.nvim_buf_del_mark(buf,'b'); Paper.refresh(buf)
assert(#marks() == 2, 'deleted mark left a ribbon behind')
local old_foldtext = vim.wo.foldtext
local mapping = vim.fn.maparg('<Space>tc','n',false,true)
assert(type(mapping.callback)=='function' and mapping.desc=='Toggle comment folding')
local function toggle() vim.api.nvim_feedkeys(vim.keycode('<Space>tc'),'xt',false) end
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
  vim.api.nvim_win_set_cursor(0, {4, 2})
  for _ = 1, 3 do
    vim.cmd('normal! zo')
    assert(vim.fn.foldclosed(4) == -1, 'zo did not open the comment')
    vim.cmd('normal! zc')
    assert(vim.fn.foldclosed(4) == 4, 'zc did not close the comment again')
  end
  vim.cmd('normal! zo')
  toggle()
  assert(vim.wo.foldtext == old_foldtext, 'toggle did not restore the existing fold text')
  toggle()
  assert(vim.fn.foldclosed(4) == 4, 're-enabling comment folds reopened the comment under the cursor')
  toggle()
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

FOCUS_DRIVER = r'''
vim.opt.termguicolors=true
vim.o.columns=150
vim.o.lines=45
local plugins=vim.env.NOTEBOOK_PLUGINS..'/'
for _,name in ipairs({'lualine.nvim','bufferline.nvim','neo-tree.nvim','plenary.nvim','nui.nvim','nvim-web-devicons'}) do vim.opt.rtp:append(plugins..name) end
local source=table.concat(vim.fn.readfile(vim.env.NOTEBOOK_INIT),'\n')
local palette=assert(source:match('(local P = %b{})'))
local paper=assert(source:match('%-%- >>> fox%-paper%-details\n(.-)\n%-%- <<< fox%-paper%-details'))
local footer=assert(source:match('(local function paper_footer_mode.-)\n%-%- Treesitter — main branch'))
local function options(name)
  local _,last=assert(source:find('"'..name..'"',1,true))
  return assert(source:sub(last):match('opts = (%b{})'))
end
local highlights=assert(source:match('(local function apply_foxml_theme%(%)\n.-\nend)\n\napply_foxml_theme%(%)'))
local opts=assert(loadstring(palette..'\n'..paper..'\n'..highlights..'\napply_foxml_theme()\n'..footer..'\nreturn {buffers='..options('akinsho/bufferline.nvim')..',tree='..options('nvim-neo-tree/neo-tree.nvim')..'}'))()
require('bufferline').setup(opts.buffers)
require('neo-tree').setup(opts.tree)
local file_icon=require('neo-tree.sources.common.components').icon(opts.tree.default_component_configs.icon,{type='file',name='note.cpp'},{})
local glyph,group=require('nvim-web-devicons').get_icon('note.cpp')
assert(glyph and file_icon.text==glyph..' ' and file_icon.highlight==group,'folder styling replaced the normal file icon provider')
local project=vim.fn.fnamemodify(vim.env.NOTEBOOK_SOURCE,':h:h')
vim.cmd('cd '..vim.fn.fnameescape(project))
vim.cmd('edit '..vim.fn.fnameescape(vim.env.NOTEBOOK_SOURCE))
local editor=vim.api.nvim_get_current_win()
local file=vim.api.nvim_get_current_buf()
local function filename()
  require('lualine').refresh({scope='all',place={'statusline'},force=true})
  vim.wait(30)
  return vim.api.nvim_eval_statusline(vim.wo[editor].statusline,{winid=editor,maxwidth=150}).str
end
local match=vim.api.nvim_get_hl(0,{name='MatchParen',link=false})
assert(match.fg==0xb8336a and match.underline and not match.bold)
local before=filename()
require('neo-tree.command').execute({action='focus',position='left',dir=project})
vim.wait(300)
assert(vim.bo.filetype=='neo-tree','tree did not open')
local during=filename()
assert(before:find('nested/note.cpp',1,true),before)
assert(during:find('nested/note.cpp',1,true),during)
for _,name in ipairs({'BufferLineBufferSelected','BufferLineBufferVisible'}) do
 local hl=vim.api.nvim_get_hl(0,{name=name,link=false})
 assert(hl.fg==0x2b2b2d and hl.bold and not hl.italic,name..vim.inspect(hl))
end
assert(vim.api.nvim_win_get_buf(editor)==file)
vim.api.nvim_set_current_win(editor)
local after=filename()
assert(after:find('nested/note.cpp',1,true),after)
assert(after:find('✎',1,true) and not after:find('draft',1,true),'writable marker or clean state is wrong: '..after)
vim.bo[file].modified=true
assert(filename():find('draft',1,true),'unsaved file lost its draft tag')
require('neo-tree.command').execute({action='focus',position='left',dir=project});vim.wait(100)
assert(filename():find('draft',1,true),'tree focus hid the editor draft tag')
vim.api.nvim_set_current_win(editor);vim.bo[file].modified=false;vim.bo[file].readonly=true
local locked=filename();assert(locked:find('',1,true) and not locked:find('draft',1,true),'read-only marker or saved state is wrong: '..locked)
vim.bo[file].readonly=false;vim.bo[file].modifiable=false
assert(filename():find('',1,true),'non-modifiable buffer did not show the lock')
vim.bo[file].modifiable=true
print('Actual Neo-tree and Lualine: editor filename stays stable across focus; visible tab names retain pencil, bold, upright lettering.')
vim.cmd('qa!')
'''


SYMDEPS_STYLE_DRIVER = r'''
vim.g.mapleader=' '
local api=vim.api
local source=table.concat(vim.fn.readfile(vim.env.NOTEBOOK_INIT),'\n')
assert(loadstring(source),'rendered init does not parse')
local palette=assert(source:match('(local P = %b{})'))
local block=assert(source:match('%-%- >>> fox%-paper%-details\n(.-)\n%-%- <<< fox%-paper%-details'))
local state=assert(loadstring('local map=vim.keymap.set\n'..palette..'\n'..block..'\nreturn {P=P,Paper=Paper}'))()
local P,Paper=state.P,state.Paper
vim.opt.rtp:append(vim.env.NOTEBOOK_SYMDEPS)
local _,last=assert(source:find('name = "fox-symdeps"',1,true))
local opts=assert(source:sub(last):match('opts = (%b{})'))
local settings=assert(loadstring('local P,Paper=...\nlocal role_model=function()return nil end\nreturn '..opts))(P,Paper)
local plugin=require('fox-symdeps')
local menu,nav=require('fox-symdeps.menu'),require('fox-symdeps.nav')
local layout,open,help=menu._layout,menu.open,nav.help
require('fox-symdeps.config').set(settings)
plugin._set_highlights(settings.palette)
require('fox-symdeps.kit').highlights()
vim.cmd('edit '..vim.fn.fnameescape(vim.env.NOTEBOOK_SOURCE))
local origin=api.nvim_get_current_win()
vim.wo.winbar='existing source chip'
local h=require('fox-symdeps.hud').open({symbol='Note',kind='struct',file=vim.env.NOTEBOOK_SOURCE,bufnr=0},{},{mode='panel'})
Paper.setup_symdeps();vim.wait(30)
local function hl(name)return api.nvim_get_hl(0,{name=name,link=false})end
assert(hl('FoxSymdepsText').fg==tonumber(P.fg:sub(2),16))
assert(hl('FoxSymdepsDim').fg==tonumber(P.comment:sub(2),16) and not hl('FoxSymdepsDim').italic)
assert(vim.wo[h.win].winbar:find('FoxPaperSymdepsFocusTitle',1,true))
assert(hl('FoxPaperSymdepsFocusTitle').bg==tonumber(P.sel:sub(2),16))
api.nvim_set_current_win(origin);vim.wait(30)
assert(vim.wo[h.win].winbar:find('FoxSymdepsTitle',1,true))
assert(not vim.wo[h.win].winbar:find('FoxPaperSymdepsFocusTitle',1,true))
assert(vim.wo[origin].winbar=='existing source chip')
api.nvim_set_current_win(h.win);vim.wait(30)
assert(vim.wo[h.win].winbar:find('FoxPaperSymdepsFocusTitle',1,true))
h:close();vim.wait(30)
local actions=0
menu.open({{name='A group',label='A group',right='18 actions',run=function()actions=actions+1 end}},{title='Settings'})
local win,buf=api.nvim_get_current_win(),api.nvim_get_current_buf()
local lines=api.nvim_buf_get_lines(buf,0,-1,false)
local maps=api.nvim_buf_get_keymap(buf,'n')
vim.wait(30)
local title=api.nvim_win_get_config(win).title
assert(title[1][2]=='FoxPaperSymdepsFocusTitle',vim.inspect(title))
assert(#api.nvim_buf_get_extmarks(buf,api.nvim_create_namespace('foxml_paper_symdeps_counts'),0,-1,{})==1)
assert(vim.deep_equal(lines,api.nvim_buf_get_lines(buf,0,-1,false)),'styling changed menu content')
assert(vim.deep_equal(maps,api.nvim_buf_get_keymap(buf,'n')),'styling changed menu bindings')
local question=vim.fn.maparg('?','n',false,true).callback
question();vim.wait(30)
local child=api.nvim_get_current_win()
assert(child~=win and api.nvim_win_is_valid(win),'native help no longer preserves its parent menu')
assert(api.nvim_win_get_config(win).title[1][2]=='FoxSymdepsTitle','unfocused menu still has blush')
assert(api.nvim_win_get_config(child).title[1][2]=='FoxPaperSymdepsFocusTitle')
vim.fn.maparg('q','n',false,true).callback();vim.wait(30)
assert(api.nvim_get_current_win()==win)
api.nvim_set_hl(0,'FoxSymdepsText',{fg='#ff0000'})
api.nvim_exec_autocmds('ColorScheme',{});vim.wait(30)
assert(hl('FoxSymdepsText').fg==tonumber(P.fg:sub(2),16))
Paper.setup_symdeps()
assert(menu._layout==layout and menu.open==open and nav.help==help,'theme replaced plugin behavior')
assert(actions==0,'styling ran an action')
vim.fn.maparg('q','n',false,true).callback();vim.wait(30)
local asm=api.nvim_create_buf(false,true)
vim.bo[asm].filetype='asm'
api.nvim_win_set_buf(origin,asm)
vim.wo[origin].winhighlight='Normal:FoxSymdepsText'
local get_lines,reads=api.nvim_buf_get_lines,0
api.nvim_buf_get_lines=function(buf,...)
  if buf==asm then reads=reads+1 end
  return get_lines(buf,...)
end
api.nvim_exec_autocmds('ColorScheme',{});vim.wait(30)
api.nvim_buf_get_lines=get_lines
assert(reads==0,'count styling scanned an assembly buffer')
print('PAPER_SYMDEPS_STYLE_PASSED: focus, colors, counts, native help, bindings and action isolation')
vim.cmd('qa!')
'''

@unittest.skipUnless(NVIM and RENDER.exists(), 'build fox-render-fast and install nvim')
class PaperNotebook(unittest.TestCase):
    def test_symdeps_style_preserves_plugin_behavior(self):
        plugin=Path.home()/'code/tick-trader-percore-workspace/tools/plugins/fox-symdeps.nvim'
        if not plugin.is_dir():
            self.skipTest('local symdeps plugin is not installed')
        with tempfile.TemporaryDirectory(prefix='foxml-symdeps-style-') as temp:
            base=Path(temp);rendered=base/'rendered'
            subprocess.run([str(RENDER),str(ROOT/'themes/FoxML_Paper/palette.sh'),str(ROOT/'templates/nvim'),str(rendered)],check=True,capture_output=True)
            driver=base/'style.lua';driver.write_text(SYMDEPS_STYLE_DRIVER)
            note=base/'note.cpp';note.write_text('struct Note { int page; };\n')
            env=os.environ|{'NOTEBOOK_INIT':str(rendered/'init.lua'),'NOTEBOOK_SOURCE':str(note),
                            'NOTEBOOK_SYMDEPS':str(plugin),'XDG_STATE_HOME':str(base/'state'),
                            'XDG_CACHE_HOME':str(base/'cache'),'NVIM_LOG_FILE':str(base/'nvim.log')}
            result=subprocess.run([NVIM,'--clean','--headless','-l',str(driver)],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('PAPER_SYMDEPS_STYLE_PASSED',result.stdout+result.stderr)

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

    def test_filename_stays_stable_between_real_tree_and_editor(self):
        plugins = Path.home()/'.local/share/nvim/lazy'
        required = ('lualine.nvim','bufferline.nvim','neo-tree.nvim','plenary.nvim','nui.nvim','nvim-web-devicons')
        if not all((plugins/name).is_dir() for name in required):
            self.skipTest('local editor UI plugins are not installed')
        with tempfile.TemporaryDirectory(prefix='foxml-notebook-focus-') as temp:
            base=Path(temp); rendered=base/'rendered'
            subprocess.run([str(RENDER),str(ROOT/'themes/FoxML_Paper/palette.sh'),str(ROOT/'templates/nvim'),str(rendered)],check=True,capture_output=True)
            note=base/'project/nested/note.cpp';note.parent.mkdir(parents=True)
            note.write_text('int main() { return 0; }\n')
            (base/'data/nvim').mkdir(parents=True)
            driver=base/'focus.lua';driver.write_text(FOCUS_DRIVER)
            env=os.environ|{'NOTEBOOK_INIT':str(rendered/'init.lua'),'NOTEBOOK_SOURCE':str(note),'NOTEBOOK_PLUGINS':str(plugins),
                            'XDG_DATA_HOME':str(base/'data'),'XDG_STATE_HOME':str(base/'state'),
                            'XDG_CACHE_HOME':str(base/'cache'),'NVIM_LOG_FILE':str(base/'nvim.log')}
            result=subprocess.run([NVIM,'--clean','--headless','-l',str(driver)],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('Actual Neo-tree and Lualine:',result.stdout+result.stderr)
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
                    self.assertIn('#[fg=#b8336a] ✎ #[fg=#1c1c1e]',label)
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
