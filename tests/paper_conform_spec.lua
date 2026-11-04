-- lazy.nvim evaluates a plugin's spec while it reads the config, before that plugin is on
-- the runtimepath. Run under --clean, so conform can't be found: anything in `opts` that
-- requires it at read time stops init.lua there and everything after it never runs.
local source = assert(io.open(vim.env.PAPER_READING_INIT)):read('*a')
local opts = assert(source:match('"stevearc/conform.nvim",%s*opts = (%b{})'))
assert(not pcall(require, 'conform'), 'conform must be absent for this test to mean anything')
local spec = assert(load('return ' .. opts))()
assert(type(spec.formatters.ruff_format.command) == 'function')
print('PAPER_CONFORM_SPEC_PASSED')
