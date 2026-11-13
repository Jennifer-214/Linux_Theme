-- Test the theme's integration with native lists/signs and real local plugins.
local api=vim.api
local source=table.concat(vim.fn.readfile(vim.env.PAPER_WORKFLOW_INIT),'\n')
local palette=assert(source:match('(local P = %b{})'))
local block=assert(source:match('%-%- >>> fox%-paper%-details\n(.-)\n%-%- <<< fox%-paper%-details'))
local apply=assert(source:match('(local function apply_foxml_theme%(%)\n.-\nend)\n\napply_foxml_theme%(%)'))
local state=assert(loadstring('local map=vim.keymap.set\n'..palette..'\n'..block..'\n'..apply..'\napply_foxml_theme()\nreturn {P=P,Paper=Paper}'))()
local P,Paper=state.P,state.Paper
local function plugin(name)vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/'..name))end
local function options(name)
 local _,last=assert(source:find('"'..name..'"',1,true))
 return assert(loadstring('local Paper=...\nreturn '..assert(source:sub(last):match('opts = (%b{})'))))(Paper)
end
vim.cmd('cd '..vim.fn.fnameescape(vim.env.PAPER_WORKFLOW_PROJECT))
vim.cmd('edit note.py')
local origin=api.nvim_get_current_win()
vim.wo.winbar='existing symdeps size chip'
local before=api.nvim_buf_get_lines(0,0,-1,false)
vim.fn.setqflist({},' ',{items={{filename='note.py',lnum=1,col=1,text='first'},{filename='note.py',lnum=3,col=5,text='second'}},idx=2})
vim.cmd('copen');vim.cmd('cc 2')
assert(api.nvim_win_get_cursor(0)[1]==3 and api.nvim_win_get_cursor(0)[2]==4,'quickfix navigation changed')
vim.cmd('cclose')
assert(vim.wo[origin].winbar=='existing symdeps size chip','quickfix replaced the editor winbar')
plugin('nvim-dap');require('dap')
assert(vim.fn.sign_getdefined('DapStopped')[1].linehl=='FoxPaperDebugLine','DAP overrode the themed stopped sign')
vim.fn.sign_place(42,'workflow','DapStopped',api.nvim_get_current_buf(),{lnum=3,priority=100})
assert(vim.fn.sign_getplaced(api.nvim_get_current_buf(),{group='workflow'})[1].signs[1].lnum==3)
vim.fn.sign_unplace('workflow')
local completion={label='next_page',insertText='next_page($1)',detail='(bookmark: Bookmark) -> int',documentation='Keep the full documentation.'}
local entry={get_completion_item=function()return completion end}
for _,detail in ipairs({completion.detail,string.rep('a longer signature ',8)})do
 local candidate={get_completion_item=function()return {detail=detail}end}
 local item=Paper.completion_format(candidate,{kind='Function',abbr='next_page',word='next_page($1)',menu=''})
 assert(item.word==completion.insertText and item.abbr==completion.label,'completion changed insertion text')
 assert(vim.fn.strdisplaywidth(item.menu)<=math.min(52,math.max(18,math.floor(vim.o.columns*.32))),'completion detail overflowed')
end
local item=Paper.completion_format(entry,{kind='Function',menu='existing server detail'})
assert(item.menu=='existing server detail','completion discarded native label details')
assert(completion.detail=='(bookmark: Bookmark) -> int' and completion.documentation:find('full',1,true))
plugin('plenary.nvim');plugin('nvim-spectre')
local spectre=require('spectre');spectre.setup(options('nvim-pack/nvim-spectre'))
spectre.open({cwd='.',search_text='bookmark',replace_text='reading_note',is_insert_mode=false})
assert(vim.wait(3000,function()
 local buf=require('spectre.state').bufnr
 return buf and table.concat(api.nvim_buf_get_lines(buf,0,-1,false),'\n'):find('note.py:',1,true)~=nil
end,20),'Spectre search did not render')
assert(api.nvim_get_hl(0,{name='SpectreReplace',link=false}).bg==tonumber(P.sel:sub(2),16),'Spectre defaults replaced the Paper highlight')
spectre.close();api.nvim_set_current_win(origin)
assert(vim.deep_equal(before,api.nvim_buf_get_lines(0,0,-1,false)),'search preview edited the source')
plugin('nui.nvim');Paper.setup_choices()
local selected, index, calls
calls=0
vim.ui.select({'first','second'},{prompt='Choose an action'},function(item,i) selected,index,calls=item,i,calls+1 end)
local menu=Paper.active_choice.menu
api.nvim_win_set_cursor(menu.winid,{2,0})
menu.menu_props.on_submit()
assert(selected=='second' and index==2 and calls==1,'choice slip changed selection or called back twice')
vim.ui.select({'first'},{},function(item) selected,calls=item,calls+1 end)
Paper.active_choice.finish(nil)
assert(selected==nil and calls==2 and api.nvim_get_current_win()==origin,'choice cancellation lost focus or fired twice')
vim.ui.select({false},{},function(item,i) selected,index=item,i end)
Paper.active_choice.menu.menu_props.on_submit()
assert(selected==false and index==1,'false-valued choices lost their selected value')
vim.ui.select({'first'},{},function(item) selected,calls=item,calls+1 end)
vim.cmd('quit')
assert(vim.wait(200,function()return Paper.active_choice==nil end,10),'native :q left a stale choice menu')
assert(selected==nil and calls==3 and api.nvim_get_current_win()==origin,'native choice quit did not cancel exactly once')
plugin('diffview.nvim')
local diffview=require('diffview');diffview.setup(options('sindrets/diffview.nvim'))
diffview.open({})
assert(vim.wait(4000,function()
 local count=0
 for _,win in ipairs(api.nvim_list_wins())do
  local label=vim.wo[win].winbar
  if label:find('current · ours',1,true) or label:find('incoming · theirs',1,true) then count=count+1 end
 end
 return count==2
end,20),'real Diffview merge did not receive current/incoming labels')
diffview.close();vim.wait(100)
assert(api.nvim_win_is_valid(origin) and vim.wo[origin].winbar=='existing symdeps size chip','merge labels leaked into the editor')
assert(vim.deep_equal(before,api.nvim_buf_get_lines(api.nvim_win_get_buf(origin),0,-1,false)),'merge styling altered source')
print('PAPER_WORKFLOW_OK: quickfix jumps, DAP signs, completion insertion, Spectre read-only search, real merge labels and winbar restoration')
vim.cmd('qa!')
