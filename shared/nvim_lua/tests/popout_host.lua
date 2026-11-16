-- The main editor of test_popout.lua (started by it: nvim --headless --clean --listen … -c "luafile popout_host.lua"):
-- desk.popout's host side over a sample file, with a fake language server, as test_callgraph.lua has one.
local dir = assert(os.getenv('POPOUT_TEST'), 'started by test_popout.lua')
vim.fn.writefile({ tostring(vim.fn.getpid()) }, dir .. '/host.pid')
local api = vim.api
local G = require('desk.callgraph')
local P = require('desk.popout')
P.PING_MS = tonumber(os.getenv('POPOUT_PING_MS') or '') or P.PING_MS
_G.popout_test = { requests = {} }

local file = dir .. '/sample.lua'
vim.fn.writefile({ 'local M = {}', 'function M.alpha()', '  return M.beta()', 'end', 'function M.beta()', '  return 1', 'end',
                   'local function gamma() return M.alpha() end', 'return M' }, file)
vim.cmd.edit(vim.fn.fnameescape(file))
_G.popout_test.code_win = api.nvim_get_current_win()

-- Each function's callers and callees, by the line of its name: one caller (gamma's line), one callee (M.beta's).
local uri = vim.uri_from_fname(file)
local names = { [1] = 'M.alpha', [4] = 'M.beta', [7] = 'gamma' }
local function at(line) return { start = { line = line, character = 0 }, ['end'] = { line = line, character = 1 } } end
local function answer(method, params)
  if method == 'textDocument/prepareCallHierarchy' then
    local name = names[params.position.line]
    return name and { { name = name, kind = 12, uri = uri, range = at(params.position.line), selectionRange = at(params.position.line) } } or {}
  elseif method == 'callHierarchy/incomingCalls' then
    return { { from = { name = 'caller_of_' .. params.item.name, kind = 12, uri = uri, range = at(7), selectionRange = at(7) }, fromRanges = {} } }
  end
  return { { to = { name = 'callee_of_' .. params.item.name, kind = 12, uri = uri, range = at(4), selectionRange = at(4) }, fromRanges = {} } }
end
local fake = { id = 77, name = 'fakels', offset_encoding = 'utf-16' }
G.clients = function() return { fake } end
G.attached = function() return { fake } end
G.expected = function() return true end
G.transport = function(_, _, method, params, handler)
  table.insert(_G.popout_test.requests, method)
  vim.defer_fn(function() handler(nil, answer(method, params)) end, 5)
  return function() end
end

G.setup()
P.setup()
api.nvim_win_set_cursor(0, { 3, 2 })   -- inside M.alpha
_G.popout_test.ready = true
