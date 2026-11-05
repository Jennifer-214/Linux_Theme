vim.g.mapleader=' '
local api=vim.api
local source=table.concat(vim.fn.readfile(vim.env.PAPER_READING_INIT),'\n')
local palette=assert(source:match('(local P = %b{})'))
local block=assert(source:match('%-%- >>> fox%-paper%-details\n(.-)\n%-%- <<< fox%-paper%-details'))
local apply=assert(source:match('(local function apply_foxml_theme%(%)\n.-\nend)\n\napply_foxml_theme%(%)'))
local state=assert(loadstring('local map=vim.keymap.set\n'..palette..'\n'..block..'\n'..apply..'\napply_foxml_theme()\nreturn {P=P,Paper=Paper}'))()
local P,Paper=state.P,state.Paper
local comment=api.nvim_get_hl(0,{name='@comment',link=false})
local unused=api.nvim_get_hl(0,{name='DiagnosticUnnecessary',link=false})
assert(comment.italic and not comment.bold and comment.fg==tonumber(P.syn.comment:sub(2),16))
assert(unused.fg~=comment.fg and not unused.italic and not unused.bg,'unused code looks like a comment or selected code')
assert(api.nvim_get_hl(0,{name='Comment',link=false}).fg==comment.fg,'classic syntax differs from Treesitter comments')
Paper.setup_popup_styles()
local buf=api.nvim_get_current_buf();vim.bo[buf].buflisted=true
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/site'))
if pcall(vim.treesitter.language.add,'cpp') then
  local initial_list, initial_chars=vim.wo.list,vim.wo.listchars
  api.nvim_buf_set_lines(buf,0,-1,false,{'int qzzidentifier = 1;', '// A misstakke in this comment.', 'const char* path = "qzzidentifier";'})
  vim.bo.filetype='cpp';vim.treesitter.start(buf,'cpp');Paper.spelling()
  assert(vim.wo.spell,'native comment spelling was not enabled')
  vim.cmd('redraw!');api.nvim_win_set_cursor(0,{1,0});vim.cmd('normal! ]s')
  assert(api.nvim_win_get_cursor(0)[1]==2,'spelling marked a code identifier instead of comment prose')
  local ui=api.nvim_create_buf(false,true);api.nvim_win_set_buf(0,ui);Paper.spelling()
  assert(not vim.wo.spell,'spelling leaked into a utility buffer')
  api.nvim_win_set_buf(0,buf);vim.treesitter.stop(buf);Paper.spelling()
  vim.wo.list,vim.wo.listchars=initial_list,initial_chars
  vim.w.foxml_paper_whitespace=nil
end
api.nvim_buf_set_lines(buf,0,-1,false,{'int page = 1;  ','int other = 2;'})
vim.bo.filetype='cpp';assert(vim.wo.list and vim.wo.listchars:find('trail:·',1,true))
local md=api.nvim_create_buf(true,false);vim.bo[md].filetype='markdown';api.nvim_win_set_buf(0,md)
assert(not vim.wo.list,'code whitespace markings leaked into Markdown')
api.nvim_win_set_buf(0,buf);assert(vim.wo.list,'returning to code lost trailing-space markers')
local member=api.nvim_get_hl(0,{name='@variable.member',link=false});local parameter=api.nvim_get_hl(0,{name='@lsp.type.parameter',link=false})
assert(member.bold and member.fg~=parameter.fg and not parameter.italic)
assert(parameter.fg~=comment.fg,'function inputs share the comment color')
local function luminance(rgb)
 local value=0
 for _,part in ipairs({{16,.2126},{8,.7152},{0,.0722}})do
  local channel=math.floor(rgb/2^part[1])%256/255
  value=value+part[2]*(channel<=.04045 and channel/12.92 or ((channel+.055)/1.055)^2.4)
 end
 return value
end
assert(luminance(parameter.fg)<luminance(comment.fg)*.65,'parameters are too close in brightness to comments')
local references=api.nvim_get_hl(0,{name='IlluminatedWordRead',link=false})
assert(references.underline and not references.bg,'symbol tracing is not underline-only')
local signature=api.nvim_get_hl(0,{name='LspSignatureActiveParameter',link=false})
assert(signature.bg==tonumber(P.sel:sub(2),16) and signature.fg==tonumber(P.fg:sub(2),16))
local selected=api.nvim_get_hl(0,{name='TelescopeSelection',link=false})
assert(selected.bg==signature.bg,'Telescope selection differs from the active parameter')
assert(api.nvim_get_hl(0,{name='@property.json',link=false}).bold,'JSON keys lost pencil emphasis')
api.nvim_buf_set_lines(buf,0,-1,false,{'one','two'})
api.nvim_win_set_cursor(0,{1,0})
vim.fn.setreg('a','note','v')
api.nvim_feedkeys(vim.keycode('"a2p'),'xt',false)
assert(api.nvim_get_current_line()=='onotenotene','put changed register or count semantics: '..api.nvim_get_current_line())
assert(#api.nvim_buf_get_extmarks(buf,Paper.paste_namespace,0,-1,{})>0,'put did not flash')
api.nvim_feedkeys('.','xt',false)
assert(api.nvim_get_current_line()=='onotenotenotenotene','dot-repeat changed native put')
api.nvim_feedkeys('u','xt',false)
assert(api.nvim_get_current_line()=='onotenotene','paste flash broke undo')
vim.wait(240)
assert(#api.nvim_buf_get_extmarks(buf,Paper.paste_namespace,0,-1,{})==0,'paste flash stayed visible')
api.nvim_buf_set_lines(buf,0,-1,false,{'a'})
api.nvim_win_set_cursor(0,{1,0})
assert(api.nvim_paste('x',true,1));assert(api.nvim_paste('y',true,3))
assert(api.nvim_get_current_line()=='axy','streamed bracketed paste changed text')
assert(#api.nvim_buf_get_extmarks(buf,Paper.paste_namespace,0,-1,{})>0,'bracketed paste did not flash')
api.nvim_buf_set_lines(buf,0,-1,false,{'int​ value = 1;','// note'})
local original=api.nvim_buf_get_lines(buf,0,-1,false)
Paper.invisibles(buf)
assert(#api.nvim_buf_get_extmarks(buf,Paper.invisible_namespace,0,-1,{})==1,'zero-width byte is not visible')
assert(vim.deep_equal(original,api.nvim_buf_get_lines(buf,0,-1,false)),'invisible clues modified source')
api.nvim_feedkeys(vim.keycode('A <Esc>'),'xt',false)
Paper.last_edit(buf)
local edit=api.nvim_buf_get_extmarks(buf,Paper.edit_namespace,0,-1,{details=true})
assert(#edit==1 and edit[1][4].priority==0,'last-edit pencil competes with diagnostics')
vim.bo.filetype='markdown';Paper.invisibles(buf)
assert(#api.nvim_buf_get_extmarks(buf,Paper.invisible_namespace,0,-1,{})==0,'code clues leaked into prose')
vim.bo.filetype='cpp'
api.nvim_buf_set_lines(buf,0,-1,false,{'int page = 1;  ','int other = 2;'})
local diag=assert(source:match('%-%- Diagnostics config\nvim.diagnostic.config%((%b{})%)'))
assert(loadstring('local Paper,border=...\nvim.diagnostic.config('..diag..')'))(Paper,'rounded')
local ns=api.nvim_create_namespace('paper_reading_checks')
api.nvim_win_set_cursor(0,{1,1})
vim.diagnostic.set(ns,buf,{{lnum=0,col=0,end_col=8,severity=vim.diagnostic.severity.WARN,message='First note',_tags={unnecessary=true}},{lnum=1,col=0,end_col=8,severity=vim.diagnostic.severity.WARN,message='Second note'}})
vim.wait(30)
local underline_ns=assert(vim.diagnostic.get_namespace(ns).user_data.underline_ns)
local unnecessary=0
local warning=0
for _,mark in ipairs(api.nvim_buf_get_extmarks(buf,underline_ns,0,-1,{details=true}))do
 if mark[4].hl_group=='DiagnosticUnnecessary' then
  unnecessary=unnecessary+1;assert(mark[2]==0,'unused style leaked onto live code')
 elseif mark[4].hl_group=='DiagnosticUnderlineWarn' then warning=warning+1 end
end
assert(unnecessary==1 and warning==2,'unused styling hid a warning or ignored its tag')
local text_ns=assert(vim.diagnostic.get_namespace(ns).user_data.virt_text_ns)
local marks=api.nvim_buf_get_extmarks(buf,text_ns,0,-1,{details=true})
assert(#marks==1 and marks[1][2]==0,'off-line diagnostics still show messages: '..vim.inspect(marks))
api.nvim_win_set_cursor(0,{2,1});api.nvim_exec_autocmds('CursorMoved',{buffer=buf});vim.wait(30)
marks=api.nvim_buf_get_extmarks(buf,text_ns,0,-1,{details=true})
assert(#marks==1 and marks[1][2]==1,'message does not follow the current line')
assert(next(vim.diagnostic.config().signs.linehl)==nil,'diagnostics still wash entire source lines')
for _,key in ipairs({'td','tl'})do
 local mapping=assert(source:match('(map%("n", "<leader>'..key..'", function%(%)\n.-\nend, %b{}%))'))
 assert(loadstring('local map=vim.keymap.set\nlocal Paper=...\n'..mapping))(Paper)
end
local function press(key)api.nvim_feedkeys(vim.keycode('<Space>'..key),'xt',false)end
press('td');assert(vim.diagnostic.config().virtual_text==false)
press('td');assert(vim.diagnostic.config().virtual_text.current_line)
press('tl');assert(vim.diagnostic.config().virtual_lines and vim.diagnostic.config().virtual_text==false)
press('tl');assert(not vim.diagnostic.config().virtual_lines and vim.diagnostic.config().virtual_text.current_line)
local origin=api.nvim_get_current_win()
local floatbuf=api.nvim_create_buf(false,true);vim.bo[floatbuf].filetype='markdown'
api.nvim_buf_set_lines(floatbuf,0,-1,false,{'A little documentation.'})
local float=api.nvim_open_win(floatbuf,true,{relative='editor',row=1,col=1,width=34,height=3,border='rounded',title=' Documentation '})
vim.wait(30)
local ns_active=api.nvim_get_hl_ns({winid=float});assert(api.nvim_get_hl(ns_active,{name='FloatTitle',link=false}).bg==tonumber(P.sel:sub(2),16))
api.nvim_set_current_win(origin);vim.wait(30)
local ns_inactive=api.nvim_get_hl_ns({winid=float});assert(not api.nvim_get_hl(ns_inactive,{name='FloatTitle',link=false}).bg)
api.nvim_win_close(float,true)
local nui=vim.fn.expand('~/.local/share/nvim/lazy/nui.nvim')
if vim.fn.isdirectory(nui)==1 then
 vim.opt.rtp:append(nui)
 local popup=require('nui.popup')({enter=true,relative='editor',position={row=2,col=2},size={width=40,height=6},border={style='rounded',padding={0,2},text={top=' Documentation '}},buf_options={filetype='noice'}})
 popup:mount();vim.wait(30)
 local frame_ns=api.nvim_get_hl_ns({winid=popup.border.winid})
 assert(api.nvim_get_hl(frame_ns,{name='FloatTitle',link=false}).bg==tonumber(P.sel:sub(2),16),'NUI title did not match its focused document')
 api.nvim_set_current_win(origin);vim.wait(30)
 frame_ns=api.nvim_get_hl_ns({winid=popup.border.winid})
 assert(not api.nvim_get_hl(frame_ns,{name='FloatTitle',link=false}).bg,'inactive NUI title retained blush')
 popup:unmount()
end
if pcall(vim.treesitter.language.add,'markdown') then
 local notebook=api.nvim_create_buf(true,false);vim.bo[notebook].filetype='markdown';api.nvim_win_set_buf(0,notebook)
 local lines={'```markdown','# An example, not a title','```','','# A little notebook','','## A quiet section','A line of prose.'}
 api.nvim_buf_set_lines(notebook,0,-1,false,lines);Paper.refresh_quotes(notebook)
 local function titles()
  return vim.tbl_filter(function(mark)return mark[4].hl_group=='FoxPaperMarkdownTitle'end,api.nvim_buf_get_extmarks(notebook,Paper.quote_namespace,0,-1,{details=true}))
 end
 local heading=titles();assert(#heading==1 and heading[1][2]==4,'title underline leaked into a fenced example or other headings: '..vim.inspect(heading))
 assert(api.nvim_get_hl(0,{name='@markup.heading.2.markdown',link=false}).fg==tonumber(P.fg:sub(2),16),'secondary heading is not pencil')
 api.nvim_buf_set_lines(notebook,0,0,false,{'A small preface.',''});Paper.refresh_quotes(notebook)
 heading=titles();assert(#heading==1 and heading[1][2]==6,'title underline did not follow edits')
 assert(api.nvim_get_hl(0,{name='FoxPaperMarkdownTitle',link=false}).sp==tonumber(P.search.cur_bg:sub(2),16),'title underline left the palette')
end
print('PAPER_READING_PASSED: whitespace scope, semantic contrast, title underline, symbol underlines, current-line diagnostics, toggles and native/NUI popup focus')
vim.cmd('qa!')
