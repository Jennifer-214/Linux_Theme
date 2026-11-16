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
local col = l:find("panel", 1, true) - 1
eq(drawn.boxes[G.box_at(drawn, row, col)].item.name, "panel", "a position inside a box finds it")
eq(G.box_at(drawn, row, 0), nil, "the margin is no box")
eq(drawn.boxes[G.box_at(drawn, row + 1, col)].item.name, "panel", "the box's detail line is the box too")
eq(vim.tbl_map(function(b) return b.item.name end, drawn.boxes), { "panel", "turn_symbols", "changed_symbols", "unit_of" },
  "the boxes in reading order: callers, the centre, callees")
eq({ drawn.boxes[1].top + 1, drawn.boxes[1].name_col }, { row, col }, "a box knows where its name starts")
local function marked(d) return vim.tbl_map(function(m) return table.concat({ m[1], m[2], m[3], m[4] }, ":") end, d.marks) end
local keyed = G.layout(vim.tbl_extend("force", graph, { keys = G.VIEW_KEYS }), 78, false)
eq(keyed.lines[#keyed.lines], "j/k/h/l move · Enter go · BS back · c centre · r reload · q close · ? keys", "the key line comes last")
ok(vim.tbl_contains(marked(keyed), #keyed.lines .. ":0:7:DeskCallGraphKey"), "its keys are marked as keys")
eq(G.layout(vim.tbl_extend("force", graph, { keys = G.VIEW_KEYS }), 78, true).lines[#keyed.lines],
  "j/k/h/l MOVE · Enter GO · BS BACK · c CENTRE · r RELOAD · q CLOSE · ? KEYS", "retro: the keys as typed, the words in capitals")
local tight = G.layout({ keys = G.VIEW_KEYS }, 34, false)
eq({ tight.lines[#tight.lines - 2], tight.lines[#tight.lines - 1], tight.lines[#tight.lines] },
  { "j/k/h/l move · Enter go · BS back", "c centre · r reload · q close", "? keys" },
  "a narrow key line wraps between keys and drops none")
ok(vim.tbl_contains(marked(tight), #tight.lines .. ":0:1:DeskCallGraphKey"), "… its second line's keys marked too")
local headed = G.layout({ header = "PINNED", center = { name = "x", detail = "a:1" }, keys = G.panel_keys(true) }, 35, false)
eq(vim.trim(headed.lines[1]), "PINNED", "a header goes above everything")
eq(G.box_at(headed, headed.boxes[1].top + 1, headed.boxes[1].name_col), 1, "… and the boxes below it still know where they are")
eq({ headed.lines[#headed.lines - 1], headed.lines[#headed.lines] }, { "j/k/h/l move · Enter go · p unpin", "q close · ? keys" },
  "the panel's keys: p unpins while pinned")

-- ─── moving box to box ─────────────────────────────────────────────────────────────────────────────────────────
-- Five callers in two rows (three, then two), the centre, two callees; at 40 columns the rows sit at known places.
local function item(name) return { name = name, detail = "x.lua:1" } end
local B = G.layout({ callers = { item("aaaa1"), item("aaaa2"), item("aaaa3"), item("aaaa4"), item("aaaa5") },
  center = { name = "the_middle_one", detail = "x.lua:9" }, callees = { item("leaf1"), item("leaf2") } }, 40, false).boxes
eq(vim.tbl_map(function(b) return b.item.name end, B), { "aaaa1", "aaaa2", "aaaa3", "aaaa4", "aaaa5", "the_middle_one", "leaf1", "leaf2" },
  "callers row by row, the centre, callees row by row")
ok(B[1].top == B[3].top and B[4].top == B[5].top and B[4].top > B[1].top and B[6].centre and B[7].top == B[8].top and B[7].top > B[6].top,
  "two caller rows, the centre, a callee row")
eq({ G.nav(B, 6, "up"), G.nav(B, 5, "up"), G.nav(B, 2, "up") }, { 5, 2, 2 },
  "k: the box above nearest by its centre (a tie goes left); nothing above: it stays")
eq({ G.nav(B, 4, "down"), G.nav(B, 6, "down"), G.nav(B, 8, "down") }, { 6, 8, 8 }, "j: the box below nearest by its centre")
eq({ G.nav(B, 5, "left"), G.nav(B, 4, "left"), G.nav(B, 4, "right"), G.nav(B, 5, "right"), G.nav(B, 3, "right") }, { 4, 4, 5, 5, 3 },
  "h/l: along the row, stopping at its ends")
eq({ G.nav(B, 8, "next"), G.nav(B, 1, "prev"), G.nav(B, 3, "next"), G.nav(B, 5, "first"), G.nav(B, 2, "last") }, { 1, 8, 4, 1, 8 },
  "Tab/S-Tab: every box in order, wrapping; gg/G: the first and the last")
eq(G.nav({}, nil, "down"), nil, "no boxes, no selection")
ok(line_with(drawn.lines, "↓"), "an arrow says who calls whom")
eq(vim.tbl_map(function(b) return { b.role, b.line == b.top + 1 } end, B),
  { { "caller", true }, { "caller", true }, { "caller", true }, { "caller", true }, { "caller", true }, { "centre", true }, { "callee", true },
    { "callee", true } }, "each box says what it is and the line its name is on")
eq(G.layout({ header = "PINNED", center = { name = "x", detail = "a:1" } }, 30, false).boxes[1].line, 3, "… below a header too")
-- One-line rows (the pop-out's lists) move as boxes do: a row of boxes is the boxes whose names share a line.
local rows_list = { { line = 3, x = 0, w = 20 }, { line = 4, x = 0, w = 20 }, { line = 7, x = 0, w = 20 } }
eq({ G.nav(rows_list, 1, "down"), G.nav(rows_list, 2, "down"), G.nav(rows_list, 3, "down"), G.nav(rows_list, 3, "up"), G.nav(rows_list, 2, "right") },
  { 2, 3, 3, 2, 2 }, "rows: j and k go row to row, past the blank lines between them; nothing beside one")

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
eq(api.nvim_buf_get_name(view.buf):match("call graph · .*$"), "call graph · M.alpha", "the tab is named for its function, no buffer number")
eq(requests, { "textDocument/prepareCallHierarchy", "callHierarchy/incomingCalls", "callHierarchy/outgoingCalls" }, "prepare, then incoming, then outgoing")
eq(most, 1, "one request in flight at a time")
-- A narrower window draws the graph again to fit, and a wider one again for its width (a tmux pane resized to 30
-- columns cut the boxes and the key line until r). Headless Neovim does not fire WinResized by itself.
local function widest(lines) local n = 0; for _, l in ipairs(lines) do n = math.max(n, vim.fn.strdisplaywidth(l)) end; return n end
local full = widest(view.drawn.lines)
ok(full > 34, "the graph starts wider than 34 columns")
vim.cmd("vsplit")
local beside = api.nvim_get_current_win()
api.nvim_win_set_width(view.win, 34)
api.nvim_exec_autocmds("WinResized", {})
ok(widest(view.drawn.lines) <= 34, "narrowed to 34 columns, the graph is drawn again to fit them")
api.nvim_win_close(beside, true)
api.nvim_exec_autocmds("WinResized", {})
eq(widest(view.drawn.lines), full, "… and widened again, for the width it has")
api.nvim_set_current_win(view.win)
local function key(lhs) vim.fn.maparg(lhs, "n", false, true).callback() end
local function named(s, name) for i, b in ipairs(s.drawn.boxes) do if b.item.name == name then return i, b end end end
local function painted(s)
  return vim.tbl_map(function(m) return { m[2] + 1, m[3], m[4].end_col, m[4].hl_group } end,
    api.nvim_buf_get_extmarks(s.buf, G.sel_ns, 0, -1, { details = true }))
end
local function spans(b) return vim.tbl_map(function(sp) return { sp[1], sp[2], sp[3], "DeskCallGraphSelected" } end, b.spans) end
local _, middle = named(view, "M.alpha")
eq(G.selected(view).name, "M.alpha", "the view opens on the centre box")
eq(api.nvim_win_get_cursor(view.win), { middle.top + 1, middle.name_col }, "… with the cursor on its name")
eq(painted(view), spans(middle), "only the selected box is highlighted, all four of its lines")
-- What is here (actions.about): the selected box's function, the graph it is in, its callers and callees by name.
local A = require("desk.actions")
eq(A.about({ surface = "callgraph", graph = view }), { title = "M.alpha", excerpt = "M.alpha\ncallers: caller_of_M.alpha\ncallees: callee_of_M.alpha",
  refs = { { kind = "unit", file = file, line = 2, name = "M.alpha", label = "M.alpha · " .. file .. ":2" },
    { kind = "graph", file = file, line = 2, name = "M.alpha", label = "the call graph of M.alpha" } } }, "what is here: the selected box's function")
eq(A.about({ surface = "callgraph", view = { graph = view.graph }, item = view.graph.callees[1] }).refs[1],
  { kind = "unit", file = file, line = 5, name = "callee_of_M.alpha", label = "callee_of_M.alpha · " .. file .. ":5" },
  "… in the pop-out, the box its ask names")
eq({ A.about({ surface = "callgraph", view = {} }) }, { nil, "no box is selected" }, "… and none selected says so")
key("k")
local _, caller = named(view, "caller_of_M.alpha")
eq(G.selected(view).name, "caller_of_M.alpha", "k: the caller above")
eq(api.nvim_win_get_cursor(view.win), { caller.top + 1, caller.name_col }, "… the cursor follows to its name")
eq(painted(view), spans(caller), "… and so does the highlight")
key("<Tab>")
eq(G.selected(view).name, "M.alpha", "Tab: the next box")
key("G")
eq(G.selected(view).name, "callee_of_M.alpha", "G: the last")
key("gg")
eq(G.selected(view).name, "caller_of_M.alpha", "gg: the first")
-- The cursor moved by other means: into a box it selects that box (a click does this); elsewhere nothing changes.
local _, callee = named(view, "callee_of_M.alpha")
api.nvim_win_set_cursor(view.win, { callee.top, callee.spans[1][2] })
api.nvim_exec_autocmds("CursorMoved", { buffer = view.buf })
eq(G.selected(view).name, "callee_of_M.alpha", "a cursor that lands in a box selects it")
api.nvim_win_set_cursor(view.win, { 1, 0 })
api.nvim_exec_autocmds("CursorMoved", { buffer = view.buf })
eq(G.selected(view).name, "callee_of_M.alpha", "outside every box the selection stays")
key("<CR>")
eq(api.nvim_get_current_win(), origin, "Enter goes back to the code")
eq(api.nvim_win_get_cursor(origin)[1], 5, "… to the selected function, not where the cursor was")
api.nvim_set_current_win(view.win)
vim.fn.getmousepos = function() return { winid = view.win, line = caller.top + 1, column = caller.name_col + 1 } end
key("<2-LeftMouse>")
vim.fn.getmousepos = nil
eq(api.nvim_win_get_cursor(origin)[1], 8, "a double click goes to the box clicked")
api.nvim_set_current_win(view.win)
eq(G.selected(view).name, "caller_of_M.alpha", "… which it selected first")
key("c")
ok(vim.wait(2000, function() return view.drawn and text(view.drawn.lines):find("caller_of_caller_of_M.alpha", 1, true) end), "c: the graph of the selected box")
eq(G.selected(view).name, "caller_of_M.alpha", "… with it, now the centre, selected")
eq(api.nvim_buf_get_name(view.buf):match("call graph · .*$"), "call graph · caller_of_M.alpha", "… and the tab named for it")
eq(view.drawn.lines[#view.drawn.lines], "j/k/h/l move · Enter go · BS back · c centre · r reload · q close · ? keys", "the view ends with its keys")
-- Backspace: back to the code as it was, the graph left open behind.
local tabs, before = #api.nvim_list_tabpages(), api.nvim_win_get_cursor(origin)
key("<BS>")
eq({ api.nvim_get_current_win(), api.nvim_win_get_cursor(origin) }, { origin, before }, "BS goes back to the code window, its cursor where it was")
-- One graph tab: Space cc elsewhere brings it back on that function; on the same function it only switches.
api.nvim_win_set_cursor(origin, { 6, 2 })
eq(G.open_cursor(), view, "Space cc on another function: the same graph tab")
eq({ #api.nvim_list_tabpages(), api.nvim_get_current_win() }, { tabs, view.win }, "… no new tab, and the graph in front")
ok(vim.wait(2000, function() return text(view.drawn.lines):find("callee_of_M.beta", 1, true) end), "… now on that function")
eq(G.selected(view).name, "M.beta", "… its box selected")
eq(api.nvim_buf_get_name(view.buf):match("call graph · .*$"), "call graph · M.beta", "… the tab renamed")
key("<BS>")
local asked = #requests
eq(G.open_cursor(), view, "Space cc on the same function")
eq({ #api.nvim_list_tabpages(), api.nvim_get_current_win(), #requests }, { tabs, view.win, asked }, "… only switches: nothing asked again")
key("q")
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
-- The panel's boxes are selected the same way, without the panel ever taking the focus.
local _, centre_box = named(G.panel, "M.alpha")
eq({ G.selected(G.panel).name, api.nvim_win_get_cursor(G.panel.win) }, { "M.alpha", { centre_box.top + 1, centre_box.name_col } },
  "the panel selects its centre box, its cursor on the name")
eq(painted(G.panel), spans(centre_box), "… highlighted")
eq(api.nvim_get_current_win(), origin, "… while the focus stays in the code")
eq({ G.panel.drawn.lines[#G.panel.drawn.lines - 1], G.panel.drawn.lines[#G.panel.drawn.lines] }, { "j/k/h/l move · Enter go · p pin", "q close · ? keys" },
  "the panel ends with its keys")
api.nvim_set_current_win(G.panel.win)
key("j")
eq(G.selected(G.panel).name, "callee_of_M.alpha", "j in the panel: the callee below")
local _, panel_caller = named(G.panel, "caller_of_M.alpha")
api.nvim_win_set_cursor(G.panel.win, { panel_caller.top + 2, panel_caller.spans[3][2] + 1 })
api.nvim_exec_autocmds("CursorMoved", { buffer = G.panel.buf })
eq(G.selected(G.panel).name, "caller_of_M.alpha", "a cursor that lands in a panel box selects it")
api.nvim_win_set_cursor(G.panel.win, { 1, 0 })
key("<CR>")
eq({ api.nvim_get_current_win(), api.nvim_win_get_cursor(origin)[1] }, { origin, 8 }, "Enter in the panel goes to the selected function")
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

-- Pinned, the panel keeps its graph wherever the cursor goes; a save of its file reads it again; p follows again.
ok(vim.wait(1000, function() return text(G.panel.drawn.lines):find("callee_of_M.alpha", 1, true) ~= nil and G.panel.inflight == nil end), "the panel on M.alpha")
api.nvim_set_current_win(G.panel.win)
key("p")
api.nvim_set_current_win(origin)
eq({ G.panel.pinned, vim.trim(G.panel.drawn.lines[1]) }, { true, "PINNED" }, "p pins the panel, and its first line says so")
eq(G.panel.drawn.lines[#G.panel.drawn.lines - 1], "j/k/h/l move · Enter go · p unpin", "… its keys say p unpins")
requests = {}
api.nvim_win_set_cursor(origin, { 6, 2 })
G.panel_moved(origin)
vim.wait(250)
eq({ #requests, text(G.panel.drawn.lines):find("callee_of_M.alpha", 1, true) ~= nil }, { 0, true }, "pinned: the cursor in another function changes nothing")
api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
ok(vim.wait(1000, function() return #requests > 0 and G.panel.inflight == nil end), "a save of its file reads the pinned graph again")
eq({ prepares(), text(G.panel.drawn.lines):find("callee_of_M.alpha", 1, true) ~= nil, vim.trim(G.panel.drawn.lines[1]) }, { 0, true, "PINNED" },
  "… the same function, still pinned")
local _, pinned_callee = named(G.panel, "callee_of_M.alpha")
api.nvim_set_current_win(G.panel.win)
G.select(G.panel, (named(G.panel, "callee_of_M.alpha")), true)
key("<CR>")
G.panel_moved(origin)
vim.wait(250)
eq({ api.nvim_get_current_win(), api.nvim_win_get_cursor(origin)[1] }, { origin, 5 }, "Enter in a pinned panel goes there")
ok(text(G.panel.drawn.lines):find("callee_of_M.alpha", 1, true) and pinned_callee, "… without re-centring the panel")
api.nvim_set_current_win(G.panel.win)
key("p")
api.nvim_set_current_win(origin)
ok(vim.wait(1000, function() return text(G.panel.drawn.lines):find("callee_of_M.beta", 1, true) ~= nil end), "p again follows: the function under the cursor")
eq({ G.panel.pinned, vim.trim(G.panel.drawn.lines[1]) ~= "PINNED", G.panel.drawn.lines[#G.panel.drawn.lines - 1] },
  { false, true, "j/k/h/l move · Enter go · p pin" }, "… unpinned, and its keys say so")

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

-- ─── the pop-out's graph: its view kind, drawn as data ─────────────────────────────────────────────────────────────
local K = G.view_kind
eq(require("desk.popout").kinds.graph, K, "the graph is the pop-out's view kind 'graph'")
local pinned_view = K.render({ graph = graph, pinned = true }, 60, "paper")
eq({ pinned_view.title, pinned_view.state, (table.concat(pinned_view.lines, "\n"):find("PINNED", 1, true)) },
  { "call graph · changed_symbols", "PINNED", nil }, "its title and state; PINNED is the header's to show, not a line of the graph")
eq(vim.tbl_map(function(i) return i.name end, pinned_view.items), { "panel", "turn_symbols", "changed_symbols", "unit_of" },
  "an item per box, in reading order")
local centre_item = pinned_view.items[3]
eq({ centre_item.kind, centre_item.centre, centre_item.ref == graph.center, centre_item.key:match("^centre:") ~= nil, centre_item.line },
  { "box", true, true, true, (line_with(pinned_view.lines, "║ changed_symbols")) }, "… each a box, its function the ref, the cursor on its name")
local keys_seen = {}
for _, i in ipairs(pinned_view.items) do keys_seen[i.key] = true end
eq(vim.tbl_count(keys_seen), 4, "every item has a key of its own")
local both = { name = "A", detail = "x.lua:1", uri = "file:///x.lua", range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } } }
local loop = K.render({ graph = { center = { name = "B", detail = "x.lua:5" }, callers = { both }, callees = { both } } }, 60, "paper").items
ok(#loop == 3 and loop[1].key ~= loop[3].key, "a function both caller and callee: two boxes, two keys")
eq(vim.tbl_map(function(i) return i.key end, K.render({ graph = graph }, 40, "paper").items), vim.tbl_map(function(i) return i.key end, pinned_view.items),
  "drawn again (another width, unpinned) the boxes keep their keys")
local wide = K.render({ graph = graph, pinned = true }, 100, "paper").lines
ok(not table.concat(wide, "\n"):find("Enter go", 1, true), "no keys in its lines: the key line is the pop-out window's status line")
local pairs_said = vim.tbl_map(function(p) return p[1] .. " " .. p[2] end, require("desk.popout").key_pairs(pinned_view.footer))
eq(table.concat(pairs_said, " · "), "j/k/h/l move · Enter go · f go+focus · p follow · ? keys", "its key line: five keys, as she reads them")
eq(K.render({ graph = graph }, 60, "paper").footer[4].words, "pin", "… p says what it does: pin when following")
-- Its state as data and back: the history keeps it all, the layout record a pinned graph's function by file and line.
local fn_line = line_with(source, "function M.alpha()")
local saved = K.save({ pinned = true, graph = graph, target = { buf = buf, row = fn_line - 1, name = "M.alpha" } })
eq({ saved.step, saved.pinned, saved.graph == graph, saved.target }, { true, true, true, { file = vim.api.nvim_buf_get_name(buf), line = fn_line, name = "M.alpha" } },
  "save: everything for the history, and the function by file and line for the layout record")
eq(K.save({ pinned = false, graph = graph, target = { buf = buf, row = 1, name = "x" } }).target, nil, "… a following graph keeps no function")
local back = { pinned = false, graph = { message = "elsewhere" } }
K.restore(back, saved)
eq({ back.pinned, back.graph == graph, back.target and back.target.name }, { true, true, "M.alpha" },
  "restore of a step: the graph as it was, pinned as it was")
local after_restart = { graph = { message = "elsewhere" } }
K.restore(after_restart, { pinned = true, target = saved.target })
eq({ after_restart.pinned, after_restart.target and after_restart.target.name, after_restart.graph.center and after_restart.graph.center.name },
  { true, "M.alpha", "M.alpha" }, "restore from the layout record: pinned on that function again, its graph read for it")
if after_restart.stop then after_restart.stop() end
local at = G.target_at(vim.api.nvim_buf_get_name(buf), fn_line + 1)
eq({ at and at.name, at and at.buf }, { "M.alpha", buf }, "a function named by file and line: the one around that line")
eq({ G.target_at(dir .. "/no-such-file.lua", 1) }, { nil, "that file is no longer there" }, "… and a file that is gone says so")

-- ─── its keys are rows of the action registry ──────────────────────────────────────────────────────────────────
local A = require("desk.actions")
eq(A.problems, {}, "every call graph row was taken")
local function keys_of(surface) return vim.tbl_map(function(k) return k.key end, A.keys(surface)) end
eq(keys_of("callgraph"), { "?", "j", "k", "h", "l", "<Tab>", "<S-Tab>", "gg", "G", "s", "<CR>", "<BS>", "c", "r", "q", "gs", "o" }, "the graph tab's keys")
eq(keys_of("callgraph-panel"), { "?", "j", "k", "h", "l", "<Tab>", "<S-Tab>", "gg", "G", "s", "<CR>", "p", "q", "o" }, "the panel's keys")
for _, surface in ipairs({ "callgraph", "callgraph-panel" }) do
  local seen, twice = {}, {}
  for _, r in ipairs(A.rows()) do
    local on = type(r.on) == "table" and r.on or { r.on }
    if r.key and vim.tbl_contains(on, surface) then
      for _, mode in ipairs(type(r.mode) == "table" and r.mode or { r.mode or "n" }) do
        local spelled = mode .. ":" .. r.key:lower()
        if seen[spelled] then twice[#twice + 1] = r.id .. " and " .. seen[spelled] end
        seen[spelled] = r.id
      end
    end
  end
  eq(twice, {}, "no key twice on " .. surface)
end
for _, id in ipairs({ "callgraph.open", "callgraph.panel" }) do
  local r = A.get(id)
  eq({ r and r.group, r and r.remote, r and r.on }, { "This function", true, "editor" }, id .. ": in This function, open to the pop-out")
end
eq({ A.key("callgraph.open"), A.key("callgraph.panel") }, { "<leader>cc", "<leader>co" }, "Space cc and Space co")
eq(A.available(A.get("callgraph.open"), { surface = "callgraph" }), false, "inside the graph its own keys apply, not Space cc")
eq(A.available(A.get("callgraph.symdeps"), { surface = "callgraph" }), "requires symdeps", "gs without symdeps says what it needs")
-- A count reaches the move through the registry's mapping: 3j is three steps down.
local cbuf = api.nvim_create_buf(false, true)
api.nvim_win_set_buf(0, cbuf)
local laid = G.layout({ callers = { item("aaaa1"), item("aaaa2"), item("aaaa3"), item("aaaa4"), item("aaaa5") },
  center = { name = "the_middle_one", detail = "x.lua:9" }, callees = { item("leaf1"), item("leaf2") } }, 40, false)
api.nvim_buf_set_lines(cbuf, 0, -1, false, laid.lines)
local surface = { buf = cbuf, win = api.nvim_get_current_win(), drawn = laid }
A.map("callgraph", { buffer = cbuf, nowait = true, ctx = { graph = surface } })
G.select(surface, 1, true)
local want = G.nav(laid.boxes, G.nav(laid.boxes, G.nav(laid.boxes, 1, "down"), "down"), "down")
api.nvim_feedkeys("3j", "x", false)
eq(surface.index, want, "3j moves three boxes down")
api.nvim_feedkeys("2k", "x", false)
eq(surface.index, G.nav(laid.boxes, G.nav(laid.boxes, want, "up"), "up"), "… and 2k two up")

vim.fn.delete(dir, "rf")
print(string.format("test_callgraph: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
