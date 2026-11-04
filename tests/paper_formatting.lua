local api=vim.api
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/conform.nvim'))
local source=table.concat(vim.fn.readfile(vim.env.PAPER_READING_INIT),'\n')
local opts=assert(source:match('"stevearc/conform.nvim",%s*opts = (%b{})'))
local conform=require('conform')
local options=assert(loadstring('return '..opts))()
conform.setup(options)
local root=vim.env.PAPER_FORMATTING_ROOT
local function open(name,ft,text)
 vim.cmd('enew!');local buf=api.nvim_get_current_buf()
 api.nvim_buf_set_name(buf,root..'/'..name);vim.bo.filetype=ft
 api.nvim_buf_set_lines(buf,0,-1,false,text)
 return buf
end
local function lines()return table.concat(api.nvim_buf_get_lines(0,0,-1,false),'\n')end
local py=open('note.py','python',{'def page( count:int=1 ):',' return {"pages":count,"ready":True}'})
assert(conform.list_formatters(py)[1].name=='ruff_format')
vim.cmd('write!')
assert(lines():find('def page(count: int = 1):',1,true),'Python save did not format')
assert(lines():find('    return',1,true),'Python indentation was not formatted')
local once=lines();vim.cmd('write');assert(lines()==once,'Python format is not idempotent')
-- Config belongs to the project, rather than the theme.
vim.fn.writefile({'[tool.ruff]','line-length = 96','[tool.ruff.format]',"quote-style = 'single'"},root..'/pyproject.toml')
api.nvim_buf_set_lines(py,0,-1,false,{'name = "paper"'});vim.cmd('write')
assert(lines()=="name = 'paper'",'Ruff ignored project quote style')
vim.fn.writefile({'[tool.black]','line-length = 96'},root..'/pyproject.toml')
assert(options.formatters_by_ft.python(py)[1]=='black','explicit Black project was not respected')
vim.fn.delete(root..'/pyproject.toml')
api.nvim_buf_set_lines(py,0,-1,false,{'def invalid('})
local invalid=lines();conform.format({bufnr=py,timeout_ms=2000,lsp_format='fallback'})
assert(lines()==invalid,'invalid Python was rewritten')
local server=vim.fn.expand('~/.local/share/nvim/mason/bin/vscode-json-language-server')
if vim.fn.executable(server)==1 then
local json=open('note.json','json',{'{"name":"paper","pages":[1,2],"enabled":true,"id":9007199254740993}'})
local client=assert(vim.lsp.start({name='jsonls',cmd={vim.fn.expand('~/.local/share/nvim/mason/bin/vscode-json-language-server'),'--stdio'},root_dir=root,init_options={provideFormatter=true}}))
assert(vim.wait(5000,function()local c=vim.lsp.get_client_by_id(client);return c and c.initialized and c:supports_method('textDocument/formatting') end,20),'JSON formatter did not attach')
-- Exercise the LSP fallback without requiring another formatter package.
conform.formatters_by_ft.json={}
vim.cmd('write!')
assert(#api.nvim_buf_get_lines(json,0,-1,false)>1,'JSON save did not format')
assert(vim.json.decode(lines()).name=='paper','JSON formatting changed data')
assert(lines():find('9007199254740993',1,true),'JSON formatting lost integer precision')
once=lines();vim.cmd('write');assert(lines()==once,'JSON format is not idempotent')
api.nvim_buf_set_lines(json,0,-1,false,{'{"broken":'})
invalid=lines();vim.cmd('write')
assert(lines()==invalid,'invalid JSON was rewritten')
vim.lsp.stop_client(client,true)
else print('JSON LSP check skipped: not installed in this test environment') end
print('PAPER_FORMATTING_PASSED: real save, Ruff config, Black choice, JSON LSP, idempotence and invalid input')
vim.cmd('qa!')
