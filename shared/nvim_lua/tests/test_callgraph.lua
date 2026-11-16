-- nvim --headless --clean -l shared/nvim_lua/tests/test_callgraph.lua : desk.callgraph with a fake language server.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
-- Neovim looks in the runtime path (the installed copy under ~/.config/nvim) before package.path: load the repo's.
table.insert(package.loaders, 2, function(name)
  local file = here .. "../" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
-- The look in use here would otherwise decide (retro says everything in capitals); retro is tested on its own below.
vim.g.desk_style = "paper"
local G = require("desk.callgraph")
local api = vim.api
local passed, failed = 0, 0
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want)) end
end
local function ok(cond, what) eq(not not cond, true, what) end
local function text(lines) return table.concat(lines, "\n") end
local function line_with(lines, pattern)
  for i, l in ipairs(lines) do if l:find(pattern, 1, true) then return i, l end end
end

-- ─── layout ────────────────────────────────────────────────────────────────────────────────────────────────────
local graph = {
  center = { name = "changed_symbols", detail = "review.lua:317" },
  callers = { { name = "panel", detail = "review.lua:560" }, { name = "turn_symbols", detail = "callgraph.lua:400" } },
  callees = { { name = "unit_of", detail = "review.lua:320" } },
}
local drawn = G.layout(graph, 60, false)
local up, down = line_with(drawn.lines, "callers · 2"), line_with(drawn.lines, "callees · 1")
local centre = line_with(drawn.lines, "║ changed_symbols")
ok(up and centre and down and up < centre and centre < down, "callers above, the function in the middle, callees below")
ok(line_with(drawn.lines, "╔═"), "the function sits in a double box")
ok(line_with(drawn.lines, "╭─") and not line_with(drawn.lines, "┌"), "neighbours in rounded boxes outside retro")
for i, l in ipairs(drawn.lines) do ok(api.nvim_strwidth(l) <= 60, "line " .. i .. " fits the width") end
local row, l = line_with(drawn.lines, "│ panel")
eq(G.item_at(drawn, row, l:find("panel", 1, true)).name, "panel", "Enter on a box finds its function")
eq(G.item_at(drawn, row, 0), nil, "the margin is no box")
eq(G.item_at(drawn, row + 1, l:find("panel", 1, true)).name, "panel", "the box's detail line is the box too")
ok(line_with(drawn.lines, "↓"), "an arrow says who calls whom")

local retro = G.layout(graph, 60, true)
ok(line_with(retro.lines, "CALLERS · 2") and line_with(retro.lines, "┌─") and line_with(retro.lines, "╔═"), "retro: capitals, CP437 single and double boxes")
ok(not line_with(retro.lines, "╭"), "retro has no rounded corners (not in code page 437)")

local narrow = G.layout({ center = { name = "a_very_long_function_name_indeed", detail = "x.lua:1" },
  callers = { { name = "one", detail = "a:1" }, { name = "two", detail = "b:2" } }, callees = {} }, 18, false)
for _, line in ipairs(narrow.lines) do ok(api.nvim_strwidth(line) <= 18, "a narrow panel never overflows: " .. line) end
ok(line_with(narrow.lines, "…"), "a long name is cut with an ellipsis")
ok(line_with(narrow.lines, "calls nothing"), "an empty group says so")
ok(line_with(G.layout({ center = { name = "x", detail = "" }, callers = {}, callees = {} }, 40, true).lines, "NO CALLERS FOUND"), "retro says it in capitals")
eq(G.layout({ message = "waiting for the language server…" }, 40, false).lines, { "    waiting for the language server…" }, "a message alone, centred")

-- ─── the symbol under the cursor ───────────────────────────────────────────────────────────────────────────────
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local file = dir .. "/sample.lua"
local source = { "local M = {}", "function M.alpha()", "  return M.beta()", "end", "function M.beta()", "  return 1", "end",
                 "local function gamma() return M.alpha() end", "return M" }
vim.fn.writefile(source, file)
vim.cmd.edit(file)
local buf = api.nvim_get_current_buf()
local s = G.symbol_at(buf, 2, 4)
eq({ s.name, s.row, s.col }, { "M.alpha", 1, 11 }, "inside M.alpha: its name, and the point an LSP request names")
eq(G.symbol_at(buf, 5, 2).name, "M.beta", "inside M.beta")
eq(G.symbol_at(buf, 7, 30).name, "gamma", "a local function")
local none, why = G.symbol_at(buf, 0, 0)
eq({ none, why }, { nil, "the cursor is not in a function" }, "outside every function: refused with why")
eq(G.symbol_at(buf, 2, 0).key, G.symbol_at(buf, 3, 0).key, "two lines of one function: one key")

-- ─── a fake language server ────────────────────────────────────────────────────────────────────────────────────
local uri = vim.uri_from_fname(file)
local names = { [1] = "M.alpha", [4] = "M.beta", [7] = "gamma" }
local requests, inflight, most, delay = {}, 0, 0, 10
local function at(line) return { start = { line = line, character = 0 }, ["end"] = { line = line, character = 1 } } end
local function answer(method, params)
  if method == "textDocument/prepareCallHierarchy" then
    local name = names[params.position.line]
    return name and { { name = name, kind = 12, uri = uri, range = at(params.position.line), selectionRange = at(params.position.line) } } or {}
  elseif method == "callHierarchy/incomingCalls" then
    return { { from = { name = "caller_of_" .. params.item.name, kind = 12, uri = uri, range = at(7), selectionRange = at(7) }, fromRanges = {} } }
  end
  return { { to = { name = "callee_of_" .. params.item.name, kind = 12, uri = uri, range = at(4), selectionRange = at(4) }, fromRanges = {} } }
end
local fake = { id = 77, name = "fakels", offset_encoding = "utf-16" }
local served = { fake }
G.clients = function() return served end
G.attached = function() return served end
G.expected = function() return true end
G.transport = function(_, _, method, params, handler)
  requests[#requests + 1] = method
  inflight = inflight + 1
  most = math.max(most, inflight)
  vim.defer_fn(function() inflight = inflight - 1; handler(nil, answer(method, params)) end, delay)
  return function() end
end
local function prepares()
  local n = 0
  for _, m in ipairs(requests) do if m == "textDocument/prepareCallHierarchy" then n = n + 1 end end
  return n
end

-- ─── the graph view ────────────────────────────────────────────────────────────────────────────────────────────
local origin = api.nvim_get_current_win()
api.nvim_win_set_cursor(origin, { 3, 4 })
local view = G.open_cursor()
ok(vim.wait(2000, function() return view.drawn and text(view.drawn.lines):find("callee_of_M.alpha", 1, true) end), "the view draws the graph")
ok(line_with(view.drawn.lines, "caller_of_M.alpha") < line_with(view.drawn.lines, "║ M.alpha"), "the caller is drawn above the function")
eq(vim.bo[view.buf].modifiable, false, "the graph is read-only")
eq(requests, { "textDocument/prepareCallHierarchy", "callHierarchy/incomingCalls", "callHierarchy/outgoingCalls" }, "prepare, then incoming, then outgoing")
eq(most, 1, "one request in flight at a time")
local lnum, line = line_with(view.drawn.lines, "caller_of_M.alpha")
api.nvim_win_set_cursor(view.win, { lnum, (line:find("caller_of", 1, true)) })
vim.fn.maparg("<CR>", "n", false, true).callback()
eq(api.nvim_get_current_win(), origin, "Enter goes back to the code")
eq(api.nvim_win_get_cursor(origin)[1], 8, "… at the function the box names")
api.nvim_set_current_win(view.win)
vim.fn.maparg("q", "n", false, true).callback()
eq(#api.nvim_list_tabpages(), 1, "q closes the graph's tab")

-- No server with a call hierarchy: refused, with the servers named; none yet: it waits and says so.
served = {}
G.attached = function() return { { id = 5, name = "bashls" } } end
view = G.open_cursor()
ok(vim.wait(1000, function() return view.drawn and text(view.drawn.lines):find("no language server here has a call hierarchy (bashls)", 1, true) end),
  "a server without a call hierarchy is named in the refusal")
vim.fn.maparg("q", "n", false, true).callback()
G.attached = function() return served end
local waited = false
api.nvim_win_set_cursor(origin, { 3, 4 })
view = G.open_cursor()
vim.defer_fn(function() waited = view.drawn and text(view.drawn.lines):find("waiting for the language server", 1, true) ~= nil; served = { fake } end, 100)
ok(vim.wait(3000, function() return view.drawn and text(view.drawn.lines):find("callee_of_M.alpha", 1, true) end), "once the server comes, the graph")
ok(waited, "until then it says it waits, never an empty graph")
vim.fn.maparg("q", "n", false, true).callback()

-- ─── the live panel ────────────────────────────────────────────────────────────────────────────────────────────
G.DEBOUNCE_MS = 60
api.nvim_win_set_cursor(origin, { 1, 0 })
G.panel_toggle()
eq(api.nvim_get_current_win(), origin, "the panel never takes the focus")
ok(G.panel.win and api.nvim_win_get_width(G.panel.win) == G.PANEL_WIDTH, "a narrow split")
ok(vim.wait(500, function() return G.panel.drawn and text(G.panel.drawn.lines):find("not in a function", 1, true) end), "outside a function it says so")
requests, most = {}, 0
for i = 1, 8 do
  api.nvim_win_set_cursor(origin, { i % 2 == 0 and 3 or 6, 2 })
  G.panel_moved(origin)
end
ok(vim.wait(1000, function() return G.panel.drawn and text(G.panel.drawn.lines):find("callee_of_M.alpha", 1, true) end), "the panel draws where the cursor rested")
eq(prepares(), 1, "eight quick moves: one request")
api.nvim_win_set_cursor(origin, { 4, 0 })
G.panel_moved(origin)
vim.wait(200)
eq(prepares(), 1, "a move inside the same function asks nothing")
api.nvim_win_set_cursor(origin, { 6, 2 })
G.panel_moved(origin)
ok(vim.wait(1000, function() return text(G.panel.drawn.lines):find("callee_of_M.beta", 1, true) end), "another function: its graph")
api.nvim_win_set_cursor(origin, { 3, 2 })
G.panel_moved(origin)
ok(vim.wait(500, function() return text(G.panel.drawn.lines):find("callee_of_M.alpha", 1, true) end), "back again")
eq(prepares(), 2, "… drawn from the cache")
G.panel_forget(buf)
G.panel_moved(origin)
ok(vim.wait(1000, function() return prepares() == 3 and G.panel.inflight == nil end), "a save of the file forgets its graphs")

-- A slow server: the cursor leaves while a request is out; that answer is not drawn, the new one is.
delay, requests, most = 150, {}, 0
G.panel_forget(buf)
api.nvim_win_set_cursor(origin, { 6, 2 })
G.panel_moved(origin)
vim.wait(120)
api.nvim_win_set_cursor(origin, { 8, 30 })
G.panel_moved(origin)
local stale = false
ok(vim.wait(3000, function()
  if text(G.panel.drawn.lines):find("callee_of_M.beta", 1, true) then stale = true end
  return text(G.panel.drawn.lines):find("callee_of_gamma", 1, true) ~= nil
end), "the panel ends on where the cursor is")
eq(stale, false, "the answer for the function the cursor left is never drawn")
eq(most, 1, "still one request in flight")
ok(G.panel.cache[vim.uri_from_bufnr(buf) .. "\0M.beta\0" .. 4] ~= nil, "… though it is kept for when the cursor comes back")

-- Away and back while the answer is out: the function the cursor came back to is not asked about twice.
requests = {}
G.panel_forget(buf)
api.nvim_win_set_cursor(origin, { 3, 2 })
G.panel_moved(origin)
vim.wait(100)
api.nvim_win_set_cursor(origin, { 6, 2 })
G.panel_moved(origin)
vim.wait(100)
api.nvim_win_set_cursor(origin, { 3, 2 })
G.panel_moved(origin)
ok(vim.wait(3000, function() return text(G.panel.drawn.lines):find("callee_of_M.alpha", 1, true) ~= nil and G.panel.inflight == nil end), "back on M.alpha: its graph")
vim.wait(100)
eq(prepares(), 1, "… from the one request already out; M.beta, left before it was asked about, never is")
delay = 10

-- Closing the last window beside the panel closes the panel (here another tab remains).
vim.cmd("tabnew")
vim.cmd("tabprevious")
api.nvim_win_close(origin, true)
ok(vim.wait(500, function() return G.panel.win == nil end), "the panel does not outlive the code beside it")
eq(#api.nvim_list_tabpages(), 1, "… and its tab goes with it")

-- ─── a turn's changed symbols ──────────────────────────────────────────────────────────────────────────────────
local after = { "local M = {}", "function M.alpha()", "  return M.beta() + 1", "end", "function M.beta()", "  return 1", "end",
                "function M.delta()", "  return 4", "end", "return M" }
vim.fn.writefile(after, file)
local before = table.concat(source, "\n") .. "\n"
local found = G.turn_symbols({ root = dir, files = { { rel = "sample.lua", before = before }, { rel = "../etc/passwd" }, { rel = "/abs" } } })
eq(#found.files, 1, "paths outside the root are refused")
local got = vim.tbl_map(function(x) return x.name .. ":" .. x.side end, found.files[1].symbols)
eq(got, { "M.alpha:after", "M.delta:after", "gamma:before" }, "the functions the turn changed, added and removed")
local cli = vim.system({ "nvim", "--headless", "--clean", "-l", here .. "../desk/callgraph.lua", "--turn-symbols" },
  { stdin = vim.json.encode({ root = dir, files = { { rel = "sample.lua", before = before } } }), text = true }):wait(20000)
local decoded = vim.json.decode(cli.stdout)
eq(vim.tbl_map(function(x) return x.name end, decoded.files[1].symbols), { "M.alpha", "M.delta", "gamma" }, "the same answer headless, for the notebook")

vim.fn.delete(dir, "rf")
print(string.format("test_callgraph: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
