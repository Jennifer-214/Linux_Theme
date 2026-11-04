-- Exercise the real parser and NUI input while submitting no LSP edits.
local source=table.concat(vim.fn.readfile(vim.env.PAPER_DETAILS_INIT),'\n')
local palette=assert(source:match('(local P = %b{})'))
local paper=assert(source:match('%-%- >>> fox%-paper%-details\n(.-)\n%-%- <<< fox%-paper%-details'))
local highlights=assert(source:match('(local function apply_foxml_theme%(%)\n.-\nend)\n\napply_foxml_theme%(%)'))
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nui.nvim'))
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/site'))
local Paper=assert(loadstring(palette..'\n'..paper..'\n'..highlights..'\napply_foxml_theme()\nreturn Paper'))()
local text={'A note[^one].','','[^one]: Pencil text.','','`[^code]`','','```markdown','Example[^fake]','```'}
local buf=vim.api.nvim_get_current_buf();vim.bo.filetype='markdown';vim.api.nvim_buf_set_lines(buf,0,-1,false,text)
vim.bo.buftype='';vim.api.nvim_buf_set_name(buf,'footnotes.md')
Paper.refresh_quotes(buf)
local marks=vim.api.nvim_buf_get_extmarks(buf,Paper.quote_namespace,0,-1,{details=true});local rows={}
for _,m in ipairs(marks) do if m[4].hl_group=='FoxPaperFootnote' then rows[m[2]]=true end end
assert(rows[0] and rows[2] and not rows[4] and not rows[7],vim.inspect(marks))
assert(vim.deep_equal(text,vim.api.nvim_buf_get_lines(buf,0,-1,false)))
local delegated=0
vim.ui.input=function(opts,cb)delegated=delegated+1;cb('ordinary')end
Paper.setup_correction_input()
vim.ui.input({prompt='Other input: '},function(value)assert(value=='ordinary')end)
assert(delegated==1)
local calls,answer=0,'pending'
local function done(value)calls=calls+1;answer=value end
vim.ui.input({prompt='New Name: ',default='page_count'},done)
assert(Paper.active_correction and vim.api.nvim_buf_is_valid(Paper.active_correction.input.bufnr))
assert(vim.fn.prompt_getprompt(Paper.active_correction.input.bufnr)=='→ ')
local finish=Paper.active_correction.finish
finish('note_count');finish('duplicate');vim.wait(80)
assert(calls==1 and answer=='note_count' and not Paper.active_correction)
vim.ui.input({prompt='New Name: ',default='page_count'},done)
vim.wait(40)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>',true,false,true),'xt',false)
vim.wait(80)
assert(calls==2 and answer==nil and not Paper.active_correction,'Escape did not cancel exactly once')
assert(vim.deep_equal(text,vim.api.nvim_buf_get_lines(buf,0,-1,false)),'Input UI changed the source buffer')
print('PAPER_CORRECTIONS_AND_FOOTNOTES_OK')
vim.cmd('qa!')
