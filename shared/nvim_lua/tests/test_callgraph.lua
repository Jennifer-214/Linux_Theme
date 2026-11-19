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
vim.fn.mkdir(dir .. "/.git")
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
eq(view.graph.read_at and { view.graph.read_at.buf, view.graph.read_at.tick } or {}, { buf, api.nvim_buf_get_changedtick(buf) },
  "the graph keeps where its centre's file stood when it was read (the edited-since note reads it)")
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
  refs = { { kind = "unit", file = "sample.lua", line = 2, name = "M.alpha", label = "M.alpha · sample.lua:2" },
    { kind = "graph", file = "sample.lua", line = 2, name = "M.alpha", label = "the call graph of M.alpha" } } }, "what is here: the selected box's function")
eq(A.about({ surface = "callgraph", view = { graph = view.graph }, item = view.graph.callees[1] }).refs[1],
  { kind = "unit", file = "sample.lua", line = 5, name = "callee_of_M.alpha", label = "callee_of_M.alpha · sample.lua:5" },
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
-- c in the panel centres it on the selected box and pins it there, as c does in the pop-out (2026-11-16: it was Vim's
-- c there, an error on the read-only buffer).
ok(vim.wait(1000, function() return G.panel.inflight == nil and named(G.panel, "callee_of_M.beta") ~= nil end), "the panel on M.beta")
api.nvim_set_current_win(G.panel.win)
G.select(G.panel, (named(G.panel, "callee_of_M.beta")), true)
ok(vim.fn.maparg("c", "n", false, true).callback ~= nil, "c is the panel's own key")
key("c")
api.nvim_set_current_win(origin)
ok(vim.wait(1000, function() return G.panel.inflight == nil and text(G.panel.drawn.lines):find("callee_of_callee_of_M.beta", 1, true) ~= nil end),
  "c in the panel: the graph of the selected box")
eq({ G.panel.pinned, vim.trim(G.panel.drawn.lines[1]), G.selected(G.panel).name }, { true, "PINNED", "callee_of_M.beta" },
  "… pinned there, its centre selected")
api.nvim_win_set_cursor(origin, { 3, 2 })
G.panel_moved(origin)
vim.wait(400)
ok(text(G.panel.drawn.lines):find("callee_of_callee_of_M.beta", 1, true), "… and it stays there while the cursor moves")
-- r in the panel reads it again (2026-11-16: it was Vim's r there, an error on the read-only buffer).
requests = {}
api.nvim_set_current_win(G.panel.win)
ok(vim.fn.maparg("r", "n", false, true).callback ~= nil, "r is the panel's own key")
key("r")
api.nvim_set_current_win(origin)
ok(vim.wait(1000, function() return #requests > 0 and G.panel.inflight == nil end), "r in the panel asks the language server again")
eq({ prepares(), G.panel.pinned, text(G.panel.drawn.lines):find("callee_of_callee_of_M.beta", 1, true) ~= nil }, { 0, true, true },
  "… for the function it is pinned on")
-- m and gs in the panel, as on the other graphs (2026-11-16: m set a Vim mark there, gs slept a second).
local crowded = { center = G.panel.graph.center, callers = { { name = "caller_a", detail = "x:1" } },
  hidden = { callers = { { name = "caller_b", detail = "x:2" } } }, more = { callers = 1 }, callees = {} }
G.panel_open_with(crowded, G.panel.target, true)
ok(text(G.panel.drawn.lines):find("+1 more", 1, true) and not text(G.panel.drawn.lines):find("caller_b", 1, true), "a panel that leaves one out")
ok(text(G.panel.drawn.lines):find("+1 more · m shows them", 1, true) and text(G.panel.drawn.lines):find("m show all", 1, true),
  "… its +1 more names m, and so does the panel's key line")
api.nvim_set_current_win(G.panel.win)
ok(vim.fn.maparg("m", "n", false, true).callback ~= nil, "m is the panel's own key")
key("m")
ok(text(G.panel.drawn.lines):find("caller_b", 1, true) and not text(G.panel.drawn.lines):find("+1 more", 1, true), "… m draws it too")
ok(not text(G.panel.drawn.lines):find("m show all", 1, true), "… and the key line leaves m out once nothing is left out")
-- A level that + read past M.MAX (level 2 here) is drawn whole by m too.
do
  local deep, near = {}, { name = "near", detail = "x:0" }
  for i = 1, G.MAX + 3 do deep[i] = { name = string.format("deep%02d", i), detail = "x:" .. i } end
  G.panel_open_with({ center = G.panel.graph.center, callers = {}, callees = { near }, layers = { callees = { { near }, deep } } }, G.panel.target, true)
  local drawn_text = text(G.panel.drawn.lines)
  ok(drawn_text:find("callees 2 · " .. (G.MAX + 3), 1, true) and drawn_text:find("+3 more · m shows them", 1, true)
    and not drawn_text:find(deep[G.MAX + 1].name, 1, true), "level 2 of " .. (G.MAX + 3) .. " functions: +3 more, with its key")
  key("m")
  drawn_text = text(G.panel.drawn.lines)
  ok(drawn_text:find(deep[G.MAX + 3].name, 1, true) and not drawn_text:find("+3 more", 1, true), "… m draws the rest of that level")
end
local said_gs = {}
local real_notify = vim.notify
vim.notify = function(msg) said_gs[#said_gs + 1] = msg end
ok(vim.fn.maparg("gs", "n", false, true).callback ~= nil, "gs is the panel's own key")
key("gs")
vim.notify = real_notify
api.nvim_set_current_win(origin)
eq(said_gs, { "Requires symdeps (an optional plugin for C and C++ symbols)." }, "… without symdeps gs says what it needs")

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
  { "call graph · changed_symbols", "", nil }, "its title, no state words: PINNED is the header's to show (from view.pinned), not a line of the graph")
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
-- Edited since it was read (2026-11-16: it looked current while the lines it names had moved): a note says so, in
-- the pop-out and in the tab, and goes once the graph is read again.
do
  local b = api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(b, 0, -1, false, { "local x = 1" })
  local read = vim.tbl_extend("force", vim.deepcopy(graph), { read_at = { buf = b, tick = api.nvim_buf_get_changedtick(b) } })
  local function noted(g) return table.concat(K.render({ graph = g }, 90, "paper").lines, "\n"):find("edited since it was read", 1, true) ~= nil end
  eq({ G.edited_since(read), noted(read) }, { false, false }, "read and not edited: no note")
  api.nvim_buf_set_lines(b, 0, 0, false, { "-- a line above" })
  eq({ G.edited_since(read), noted(read) }, { true, true }, "edited since: the pop-out's drawing says so")
  read.read_at.tick = api.nvim_buf_get_changedtick(b)
  eq(noted(read), false, "… and read again: the note goes")
  api.nvim_buf_delete(b, { force = true })
end
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
eq(keys_of("callgraph"), { "?", "j", "k", "h", "l", "<Tab>", "<S-Tab>", "gg", "G", "s", "<CR>", "<BS>", "c", "+", "-", "I", ">", "m", "r", "q", "gs", "t", "gl", "o" }, "the graph tab's keys")
eq(keys_of("callgraph-panel"), { "?", "j", "k", "h", "l", "<Tab>", "<S-Tab>", "gg", "G", "s", "<CR>", "c", "+", "-", "I", ">", "m", "r", "gs", "t", "p", "q", "gl", "o" }, "the panel's keys")
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
  eq({ r and r.group, r and r.remote, r and r.on }, { "This function", false, "editor" },
    id .. ": in This function, the editor's own (it reads the current window there; the pop-out does not offer it)")
end
eq({ A.key("callgraph.open"), A.key("callgraph.panel") }, { "<leader>cc", "<leader>co" }, "Space cc and Space co")
eq(A.available(A.get("callgraph.open"), { surface = "callgraph" }), false, "inside the graph its own keys apply, not Space cc")
eq(A.available(A.get("callgraph.symdeps"), { surface = "callgraph" }), "requires symdeps", "gs without symdeps says what it needs")
-- gs in a graph tab: the selected box's function, as in the panel and the pop-out (it once took the centre's), and the
-- menus say which before it is pressed.
do
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  vim.fn.writefile({ "local function middle() end", "local function callee_one()", "end" }, d .. "/b.lua")
  local function box(name, line) return { item = { name = name, detail = "b.lua:" .. line, uri = vim.uri_from_fname(d .. "/b.lua"),
    range = { start = { line = line - 1, character = 15 }, ["end"] = { line = line - 1, character = 25 } } } } end
  local was_buf = api.nvim_get_current_buf()
  vim.fn.writefile({ "local code_here = 1" }, d .. "/a.lua")
  vim.cmd("edit " .. vim.fn.fnameescape(d .. "/a.lua")) -- a code window (the LSP jump reads the word under its cursor)
  local code_win = api.nvim_get_current_win()
  local tab = { drawn = { boxes = { box("middle", 1), box("callee_one", 2) } }, index = 2, origin = code_win }
  tab.graph = { center = tab.drawn.boxes[1].item }
  local inspected
  package.loaded["fox-symdeps"] = { inspect_cursor = function() inspected = { vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), api.nvim_win_get_cursor(0)[1] } end }
  eq(A.about_of(A.get("callgraph.symdeps"), { graph = tab }):find("callee_one · b.lua:2 — ", 1, true), 1, "gs's description names the selected box's function first")
  eq(A.about_of(A.get("callgraph.trace"), { graph = tab }):find("callee_one · b.lua:2 — ", 1, true), 1, "… and t's")
  A.get("callgraph.symdeps").run({ graph = tab })
  eq(inspected, { "b.lua", 2 }, "gs in a tab inspects the selected box's function, not the centre")
  local Mp = require("desk.map")
  local real_trace_at, traced = Mp.trace_at, nil
  Mp.trace_at = function(path, line, opts) traced = { vim.fn.fnamemodify(path, ":t"), line, opts and opts.pop } end
  A.get("callgraph.trace").run({ view = { pop = 2 }, item = tab.drawn.boxes[2].item })
  Mp.trace_at = real_trace_at
  eq(traced, { "b.lua", 2, 2 }, "t on pop-out 2's graph asks for the trace in pop-out 2")
  package.loaded["fox-symdeps"] = nil
  api.nvim_win_set_buf(0, was_buf)
  vim.fn.delete(d, "rf")
end
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

-- m: what the cap left out ("+N more") drawn too, the boxes still in name order (2026-11-16: no way to see them).
do
  local shown, rest = {}, {}
  for i = 1, G.MAX do shown[i] = item(string.format("f%02d", i)) end
  for i = 1, 3 do rest[i] = item(string.format("f%02d", G.MAX + i)) end
  local capped = { center = item("centre"), callers = shown, more = { callers = 3 }, hidden = { callers = rest } }
  local before = table.concat(G.layout(vim.deepcopy(capped), 120, false).lines, "\n")
  ok(before:find("+3 more", 1, true) and not before:find(rest[1].name, 1, true), "capped: +3 more, the rest not drawn")
  -- The line names its key; the key lines list it while something is left out (her ask, 2026-11-17: "there also isnt
  -- a way to see the +53 more on the call grap").
  local keyed = G.layout(vim.tbl_extend("force", vim.deepcopy(capped), { keys = G.VIEW_KEYS }), 120, false)
  local row, said = line_with(keyed.lines, "+3 more")
  eq(vim.trim(said or ""), "+3 more · m shows them", "the +N more line names its key")
  local key_at = row and said:find(" · m ", 1, true)
  key_at = key_at and key_at + #" · " - 1
  ok(key_at and vim.tbl_contains(marked(keyed), table.concat({ row, key_at, key_at + 1, "DeskCallGraphKey" }, ":")), "… marked as a key")
  eq(vim.trim(G.layout(vim.deepcopy(capped), 120, true).lines[row] or ""), "+3 MORE · m SHOWS THEM", "… in retro the key keeps its case")
  eq(keyed.left_out, 3, "the drawing says how many boxes it left out")
  eq(keyed.lines[#keyed.lines], "j/k/h/l move · Enter go · BS back · c centre · r reload · q close · m show all · ? keys",
    "the tab's key line lists m while something is left out")
  local K = G.view_kind
  local function footer_m(g)
    return vim.iter(K.render({ graph = g }, 120, "paper").footer):any(function(p) return vim.tbl_contains(p.ids, "callgraph.more") end)
  end
  eq(footer_m(vim.deepcopy(capped)), true, "… and so does the pop-out's")
  local all = vim.deepcopy(capped)
  G.show_all(all)
  local after = table.concat(G.layout(all, 120, false).lines, "\n")
  ok(not after:find("+3 more", 1, true) and after:find(rest[3].name, 1, true), "m: every caller drawn, no +N more")
  eq({ #all.callers, all.callers[G.MAX + 1].name, all.more, all.hidden }, { G.MAX + 3, rest[1].name, nil, nil }, "… in name order")
  local unkeyed = G.layout(vim.tbl_extend("force", vim.deepcopy(all), { keys = G.VIEW_KEYS }), 120, false)
  eq({ unkeyed.left_out, unkeyed.lines[#unkeyed.lines], footer_m(all) },
    { 0, "j/k/h/l move · Enter go · BS back · c centre · r reload · q close · ? keys", false },
    "nothing left out: no m in the tab's key line or the pop-out's")
  local A = require("desk.actions")
  eq(A.get("callgraph.more").available({ graph = { graph = all } }), "nothing is left out", "m says when nothing is left out")
end

do
  local Map = require('desk.map')
  local reads = 0
  Map.desk_work = function(args, done)
    reads = reads + 1
    eq({ args[6], args[8], args[10], args[14] }, { 'reach', file, '2', '2' }, 'the next tier uses the exact map source location')
    -- desk-work's walk from M.alpha: M.beta is where the server's callee_of_M.alpha is (line 5), gamma below it.
    vim.schedule(function() done({ ok = true, root = dir, nodes = {
      { id = 'alpha', label = 'M.alpha', file = 'sample.lua', line = 2, depth = 0 },
      { id = 'beta', label = 'M.beta', file = 'sample.lua', line = 5, depth = 1 },
      { id = 'gamma', label = 'gamma', file = 'sample.lua', line = 8, depth = 2 },
    }, steps = { { from = 'alpha', to = 'beta', depth = 1, mark = 'follow' }, { from = 'beta', to = 'gamma', depth = 2, mark = 'leaf' } } }) end)
  end
  served = { fake }
  vim.bo[buf].modified = false
  local target = { buf = buf, row = 1, col = 11, name = 'M.alpha', key = 'depth fixture' }
  local layered = G.open(target)
  ok(vim.wait(2000, function() return layered.graph.callees end), 'the layered graph starts at one level')
  local before = #requests
  key('+')
  ok(vim.wait(2000, function() return named(layered, 'gamma') end), 'the deeper project-map level is drawn')
  eq({ reads, #requests }, { 1, before }, 'only one map traversal, with no server request for expansion')
  eq(vim.tbl_map(function(i) return i.name end, layered.graph.layers.callees[1]), { 'callee_of_M.alpha' }, "level 1 stays the language server's")
  G.select(layered, named(layered, 'gamma'), true)
  local gauge = api.nvim_buf_get_extmarks(layered.buf, G.gauge_ns, 0, -1, {})
  eq(gauge[1] and gauge[1][2] + 1, layered.drawn.boxes[layered.index].line, 'the gauge marker follows the selected box')
  vim.g.desk_style = 'retro'
  for _, name in ipairs({ 'M.alpha', 'gamma' }) do
    G.select(layered, named(layered, name), true)
    local band = layered.drawn.boxes[layered.index].gauge_band
    local expected = {}
    local rail = layered.drawn.boxes[layered.index].gauge_col + 1   -- the rail's bar, beside the drawing (D1)
    for row = band[1], band[2] do expected[#expected + 1] = { row, rail, { { '█', 'Title' } } } end
    local solid = api.nvim_buf_get_extmarks(layered.buf, G.gauge_ns, 0, -1, { details = true })
    eq(vim.tbl_map(function(mark) return { mark[2] + 1, mark[3], mark[4].virt_text } end, solid), expected,
      'retro lights the full selected bar for ' .. name)
  end
  vim.g.desk_style = 'paper'
  -- t: the project map's trace through the selected box's function, by its file and line.
  local Map_t, traced_at = require('desk.map'), nil
  local real_trace_at = Map_t.trace_at
  Map_t.trace_at = function(path, line) traced_at = { vim.fn.fnamemodify(path, ':t'), line } end
  G.select(layered, named(layered, 'gamma'), true)
  key('t')
  local gamma = layered.drawn.boxes[layered.index].item
  eq(traced_at, { vim.fn.fnamemodify(vim.uri_to_fname(gamma.uri), ':t'), gamma.range.start.line + 1 }, 't on a box: the trace through its function, by its file and line')
  Map_t.trace_at = real_trace_at
  ok(line_with(layered.drawn.lines, '+2') and line_with(layered.drawn.lines, '4 functions'), 'the header counts the layered functions')
  key('-')
  eq({ #layered.graph.layers.callees, G.selected(layered).name }, { 1, 'M.alpha' }, 'collapse removes the outer tier and returns selection to centre')

  Map.desk_work = function(_, done) vim.schedule(function() done(nil) end) end
  local transport = G.transport
  G.transport = function(client, source_buf, method, params, done)
    local name = params.item and params.item.name
    local function raw(label, line)
      return { name = label, uri = uri, selectionRange = { start = { line = line, character = 0 } } }
    end
    if method == 'callHierarchy/outgoingCalls' and name == 'callee_of_M.alpha' then
      vim.schedule(function() done(nil, { { to = raw('M.alpha', 1) }, { to = raw('gamma', 6) }, { to = raw('gamma', 6) } }) end)
      return function() end
    elseif method == 'callHierarchy/outgoingCalls' and name == 'gamma' then
      vim.schedule(function() done(nil, { { to = raw('M.alpha', 1) } }) end)
      return function() end
    end
    return transport(client, source_buf, method, params, done)
  end
  key('+')
  ok(vim.wait(2000, function() return layered.graph.layer_source.callees == 'server' end), 'the language server fills the next tier when the map is unavailable')
  eq(vim.tbl_map(function(i) return i.name end, layered.graph.layers.callees[2]), { 'gamma' }, 'the next tier excludes the centre cycle and duplicates')
  do
    -- who calls whom, kept as the level is read: gamma under callee_of_M.alpha (the call back to the centre too)
    local linked = {}
    local function name_of(id) local parts = vim.split(id, '\0', { plain = true }); return parts[#parts] end
    for a, to in pairs(layered.graph.links or {}) do
      if name_of(a) == 'gamma' then for b in pairs(to) do linked[name_of(b)] = true end end
    end
    linked = vim.tbl_keys(linked)
    table.sort(linked)
    eq(linked, { 'callee_of_M.alpha' }, "a level the server reads: each function linked to the one that calls it")
  end
  key('+')
  ok(vim.wait(2000, function() return layered.graph.exhausted.callees end), 'a level of only previously seen nodes stops expansion')
  local pending
  Map.desk_work = function(args, done)
    eq(args[6], 'callers', 'the caller box expands the other side')
    pending = done
  end
  G.select(layered, named(layered, 'caller_of_M.alpha'), true)
  key('+')
  ok(pending and layered.depth_requests.callers, 'the caller side has a request in flight')
  key('-')
  pending({ ok = true, root = dir, nodes = { { id = 'late', label = 'late', depth = 2 } } })
  eq({ layered.depth_requests.callers, layered.graph.layers.callers }, {}, 'collapse cancels a pending level and discards its late answer')
  local map_only = { center = item('M.alpha'), layers = { callees = { { item('M.beta') }, { item('gamma') } } } }
  layered.graph = map_only
  local moved = {}
  G.view_kind.open(moved, { graph = layered })
  ok(moved.graph == map_only and not moved.stop, 'transferring a map-only graph keeps its expanded levels without asking the server')
end

-- + under the language server's level 1, which stays (review of 2026-11-17, B1: the map's answer replaced the server's
-- levels, so a map that knew the function and none of its calls erased level 1 and said "no more callees").
do
  local Map = require('desk.map')
  local transport, outgoing, asked_for = G.transport, 0, {}
  local function raw(name, line, at_uri)
    local range = { start = { line = line, character = 0 }, ['end'] = { line = line, character = 1 } }
    return { name = name, kind = 12, uri = at_uri or uri, range = range, selectionRange = range }
  end
  local level1 = { raw('callee_of_M.alpha', 4) }
  G.transport = function(client, source_buf, method, params, done)
    if method ~= 'callHierarchy/outgoingCalls' then return transport(client, source_buf, method, params, done) end
    outgoing = outgoing + 1
    local name = params.item and params.item.name
    asked_for = asked_for or {}
    asked_for[#asked_for + 1] = name
    local found = name == 'M.alpha' and level1 or name == 'callee_of_M.alpha' and { raw('server_level_2', 7) }
      or name == 'other_callee' and { raw('other_level_2', 3) } or {}
    vim.defer_fn(function() done(nil, vim.tbl_map(function(r) return { to = r, fromRanges = {} } end, found)) end, 5)
    return function() end
  end
  local function names(tier) return vim.tbl_map(function(i) return i.name end, tier or {}) end
  local function node(id, label, line, depth) return { id = id, label = label, file = 'sample.lua', line = line, depth = depth } end
  local function expand(answer, label)
    Map.desk_work = function(_, done) vim.schedule(function() done(answer) end) end
    local v = G.open({ buf = buf, row = 1, col = 11, name = 'M.alpha', key = 'B1 ' .. label })
    ok(vim.wait(2000, function() return v.graph and v.graph.callees end), label .. ': the graph is read')
    api.nvim_set_current_win(v.win)
    outgoing = 0
    key('+')
    ok(vim.wait(2000, function() return not (v.depth_requests or {}).callees end), label .. ': the next level is read')
    return v, outgoing
  end
  served = { fake }
  vim.bo[buf].modified = false
  local v, asked = expand({ ok = true, root = dir, q = 'reach', nodes = { node('alpha', 'M.alpha', 2, 0) }, steps = {} }, 'none in the map')
  eq({ names(v.graph.layers.callees[1]), names(v.graph.layers.callees[2]), asked > 0 }, { { 'callee_of_M.alpha' }, { 'server_level_2' }, true },
    "the map knows the function and none of its calls: the server's level 1 stays, and the server reads level 2")
  ok(text(v.drawn.lines):find('callee_of_M.alpha', 1, true) and not text(v.drawn.lines):find('no more callees', 1, true),
    '… level 1 still drawn, and no "no more callees"')
  G.close_view(v.buf)
  -- The map has the server's callee (M.beta's place) and reads it; a call outside the checkout is not the map's.
  level1 = { raw('callee_of_M.alpha', 4), raw('lib_call', 0, vim.uri_from_fname(vim.fn.tempname() .. '/lib.lua')) }
  local walk = { ok = true, root = dir, q = 'reach',
    nodes = { node('alpha', 'M.alpha', 2, 0), node('beta', 'M.beta', 5, 1), node('gamma', 'gamma', 8, 2) },
    steps = { { from = 'alpha', to = 'beta', depth = 1, mark = 'follow' }, { from = 'beta', to = 'gamma', depth = 2, mark = 'leaf' },
              { from = 'beta', to = 'alpha', depth = 2, mark = 'seen', cycle = true } } }
  v, asked = expand(walk, 'under level 1')
  eq({ names(v.graph.layers.callees[1]), names(v.graph.layers.callees[2]), asked }, { { 'callee_of_M.alpha', 'lib_call' }, { 'gamma' }, 0 },
    "the map adds level 2 under the server's level 1, with no server request")
  ok(named(v, 'gamma') and not text(v.drawn.lines):find('M.beta', 1, true),
    '… each function once, at its nearest depth: M.beta is callee_of_M.alpha, and M.alpha the centre')
  G.close_view(v.buf)
  -- > on one box of level 1: only its own callees as level 2, the other box kept; + then reads the whole level
  do
    local saved_level1 = level1
    level1 = { raw('callee_of_M.alpha', 4), raw('other_callee', 6) }
    Map.desk_work = function(_, done) vim.schedule(function() done({ ok = true, root = dir, q = 'reach', nodes = { node('alpha', 'M.alpha', 2, 0) }, steps = {} }) end) end
    local u = G.open({ buf = buf, row = 1, col = 11, name = 'M.alpha', key = 'C2 unfold' })
    ok(vim.wait(2000, function() return u.graph and u.graph.callees and #u.graph.callees == 2 end), 'C2: two callees at level 1')
    api.nvim_set_current_win(u.win)
    G.select(u, named(u, 'callee_of_M.alpha'), true)
    asked_for = {}
    key('>')
    ok(vim.wait(2000, function() return u.graph.layers and u.graph.layers.callees and #u.graph.layers.callees == 2 and not (u.depth_requests or {}).callees end), '> reads one level')
    eq({ names(u.graph.layers.callees[1]), names(u.graph.layers.callees[2]), vim.tbl_contains(asked_for, 'other_callee') },
      { { 'callee_of_M.alpha', 'other_callee' }, { 'server_level_2' }, false },
      ">: that box's own callees alone, the box beside it kept, nothing asked of it")
    ok(text(u.drawn.lines):find("callee_of_M.alpha's callees only", 1, true), '… and the page says the level holds one branch: ' .. text(u.drawn.lines))
    key('+')
    ok(vim.wait(2000, function() return not (u.depth_requests or {}).callees and #names(u.graph.layers.callees[2]) == 2 end), '+ after >: the whole level read again')
    eq(names(u.graph.layers.callees[2]), { 'other_level_2', 'server_level_2' }, '… both branches')
    G.select(u, named(u, 'M.alpha'), true)
    eq(require('desk.actions').available(require('desk.actions').get('callgraph.unfold'), { graph = u }), 'on the centre `+` reads its next level', '> on the centre: says + does that')
    G.close_view(u.buf)
    level1 = saved_level1
  end
  walk.steps[1].mark = 'capped'
  v, asked = expand(walk, 'not read that far')
  eq({ names(v.graph.layers.callees[1]), names(v.graph.layers.callees[2]), asked > 0 }, { { 'callee_of_M.alpha', 'lib_call' }, { 'server_level_2' }, true },
    'a function the map did not read that far: the server reads the level')
  G.close_view(v.buf)
  served = {}
  Map.desk_work = function(_, done) vim.schedule(function() done(walk) end) end
  local map_only = G.open({ buf = buf, row = 1, col = 11, name = 'M.alpha', key = 'map without call hierarchy' })
  ok(vim.wait(2000, function() return map_only.graph and map_only.graph.message end), 'the graph opens without a server')
  api.nvim_set_current_win(map_only.win)
  key('+')
  ok(vim.wait(2000, function() return named(map_only, 'M.beta') end), 'the map adds the first callee using the centre buffer location')
  eq(map_only.graph.layer_source and map_only.graph.layer_source.callees, 'map', 'the first level comes from the map')
  G.close_view(map_only.buf)
  served = { fake }
  G.transport = transport
end
-- The callers side reads desk-work's steps the other way: a step's from is the caller (map_graph.hpp walk).
do
  local Map = require('desk.map')
  local transport, incoming = G.transport, 0
  G.transport = function(client, source_buf, method, params, done)
    if method == 'callHierarchy/incomingCalls' then incoming = incoming + 1 end
    return transport(client, source_buf, method, params, done)
  end
  local function names(tier) return vim.tbl_map(function(i) return i.name end, tier or {}) end
  local function node(id, label, line, depth) return { id = id, label = label, file = 'sample.lua', line = line, depth = depth } end
  Map.desk_work = function(_, done) vim.schedule(function() done({ ok = true, root = dir, q = 'callers',
    nodes = { node('alpha', 'M.alpha', 2, 0), node('gamma', 'gamma', 8, 1), node('beta', 'M.beta', 5, 2) },
    steps = { { from = 'gamma', to = 'alpha', depth = 1, mark = 'follow' }, { from = 'beta', to = 'gamma', depth = 2, mark = 'leaf' } } }) end) end
  local v = G.open({ buf = buf, row = 1, col = 11, name = 'M.alpha', key = 'B1 callers' })
  ok(vim.wait(2000, function() return v.graph and v.graph.callers end), 'callers: the graph is read')
  api.nvim_set_current_win(v.win)
  G.select(v, (named(v, 'caller_of_M.alpha')), true)
  incoming = 0
  key('+')
  ok(vim.wait(2000, function() return not (v.depth_requests or {}).callers end), 'callers: the next level is read')
  eq({ names(v.graph.layers.callers[1]), names(v.graph.layers.callers[2]), incoming }, { { 'caller_of_M.alpha' }, { 'M.beta' }, 0 },
    "callers: the map's level under the server's (caller_of_M.alpha is gamma's place), read from the caller's end")
  G.close_view(v.buf)
  G.transport = transport
end

-- ─── the depth rail beside the drawing, not at the window's edge (Codex's #1) ───────────────────────────────────
do
  local function at(name, line) return { name = name, detail = 'chain.lua:' .. line, uri = 'file:///w/c.lua', range = { start = { line = line, character = 0 } } } end
  local chain = { center = at('M.entry', 7), layers = { callees = { { at('M.one', 6) }, { at('M.two', 5) } } } }
  local d = G.layout(chain, 160, true)
  local centre = d.boxes[1]
  local rail_at = (d.lines[centre.line]:find('█', 1, true) or 0) - 2   -- its marker column, then the shade
  eq({ rail_at, centre.gauge_col }, { d.gauge_col, d.gauge_col }, 'the rail starts where the drawing says')
  local gap = math.huge
  for _, line in ipairs(d.lines) do
    -- the rail is GAUGE_WIDTH characters (its shade three bytes): counted in characters
    local rail = vim.fn.strcharpart(line, d.gauge_col, G.GAUGE_WIDTH)
    local rest = vim.fn.strcharpart(line, d.gauge_col + G.GAUGE_WIDTH)
    if rail:find('[█▓▒░]') and rest:find('%S') then gap = math.min(gap, #rest:match('^ *')) end
  end
  eq(gap, 2, 'two columns between the rail and the leftmost thing beside it, on a 160-column window')
  ok(rail_at > 40, 'the rail moved in from the edge (at column ' .. rail_at .. ')')
  for _, w in ipairs({ 40, 160 }) do
    local text = table.concat(G.layout(chain, w, true).lines, '\n')
    ok(text:find('LAYERS 0 .. +2 · 3 FUNCTIONS', 1, true), 'a heading wider than the drawing keeps its text whole at ' .. w .. ' columns')
  end
end

-- ─── a straight chain reads as one column (Codex's #2) ─────────────────────────────────────────────────────────
do
  local function at(name, line) return { name = name, detail = 'chain.lua:' .. line, uri = 'file:///w/c.lua', range = { start = { line = line, character = 0 } } } end
  local five = { center = at('M.entry', 7), layers = { callees = { { at('M.one', 6) }, { at('M.two', 5) }, { at('M.three', 4) }, { at('M.four', 3) }, { at('M.finish', 2) } } } }
  local d = G.layout(five, 120, true)
  local text = table.concat(d.lines, '\n')
  local _, headings = text:gsub('CALLEES', '')
  eq({ headings, #d.boxes, d.boxes[2].row, d.boxes[6].row }, { 1, 6, true, true }, 'five single-callee levels: one heading, a row each')
  local cols = {}
  for i = 2, 6 do cols[#cols + 1] = vim.fn.strdisplaywidth(d.lines[d.boxes[i].line]:sub(1, d.boxes[i].name_col)) end
  eq(#vim.tbl_keys(vim.iter(cols):fold({}, function(acc, c) acc[c] = true; return acc end)), 1, '… the names on one left edge')
  ok(#d.lines <= 14, '… and short: ' .. #d.lines .. ' lines (it was 34)')
  eq(vim.tbl_map(function(b) return b.level end, d.boxes), { 0, 1, 2, 3, 4, 5 }, '… each row its depth, for the rail')
  eq({ G.nav(d.boxes, 2, 'down'), G.nav(d.boxes, 3, 'up'), G.nav(d.boxes, 1, 'down') }, { 3, 2, 2 }, 'j and k go row to row, from the centre into the rows')
  local branch = G.layout({ center = at('Engine::tick', 118), layers = { callees = { { at('M.one', 6) }, { at('Book::apply', 40), at('Risk::check', 77) } } } }, 120, true)
  eq(vim.tbl_map(function(b) return b.row == true end, branch.boxes), { false, false, false, false }, 'a lone single level beside a choice stays a box: boxes where it branches')
  -- the selection keeps its screen row when a drawing changes under it
  local buf = api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, 200 do lines[i] = 'line ' .. i end
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.cmd('tabnew')
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  vim.fn.winrestview({ topline = 40 })
  api.nvim_win_set_cursor(win, { 90, 0 })   -- select puts the cursor on the box first
  G.keep_row(win, { line = 50, top = 40 }, 90)
  eq(vim.fn.line('w0', win), 80, 'the selected box moved from line 50 to 90: the window follows, it stays 10 rows from the top')
  vim.cmd('tabclose')
  api.nvim_buf_delete(buf, { force = true })
  -- … through a real redraw: a level of callers added above, the selected box deep below keeps its screen row
  local tall = { center = at('M.entry', 7), layers = { callees = {} } }
  for k = 1, 8 do tall.layers.callees[k] = { at('a' .. k, 100 + k), at('b' .. k, 200 + k) } end
  local gbuf = api.nvim_create_buf(false, true)
  vim.cmd('tabnew')
  local gwin = api.nvim_get_current_win()
  api.nvim_win_set_buf(gwin, gbuf)
  local s = { buf = gbuf, win = gwin }
  G._show(s, G.layout(tall, 100, true))
  local deep
  for i, b in ipairs(s.drawn.boxes) do if b.item.name == 'b8' then deep = i end end
  G.select(s, deep, true)
  local row_before = s.drawn.boxes[deep].line - vim.fn.line('w0', gwin)
  local taller = vim.deepcopy(tall)
  taller.layers.callers = { { at('c1', 300), at('c2', 301) } }
  G._show(s, G.layout(taller, 100, true), true)
  local now = s.drawn.boxes[s.index]
  eq({ now.item.name, now.line - vim.fn.line('w0', gwin) }, { 'b8', row_before }, 'a level of callers drawn above: b8 still selected, on the same screen row')
  vim.cmd('tabclose')
  api.nvim_buf_delete(gbuf, { force = true })
end

-- ─── a wide graph: the selected box's real callers and callees lit, the rest dimmed (Codex's #1) ───────────────
do
  local function at(name, line) return { name = name, detail = 'e.cpp:' .. line, uri = 'file:///w/e.cpp', range = { start = { line = line, character = 0 } } } end
  local tick, apply, check = at('Engine::tick', 118), at('Book::apply', 40), at('Risk::check', 77)
  local insert, cancel, limit = at('Book::insert', 52), at('Book::cancel', 61), at('Risk::limit', 90)
  local g = { center = tick, layers = { callees = { { apply, check }, { insert, cancel, limit } } } }
  G._link(g, apply, insert); G._link(g, apply, cancel); G._link(g, check, limit)
  local d = G.layout(g, 100, false)
  local idx = {}
  for i, b in ipairs(d.boxes) do idx[b.item.name] = i end
  local function names_of(list) local out = {}; for _, j in ipairs(list or {}) do out[#out + 1] = d.boxes[j].item.name end; table.sort(out); return out end
  eq(names_of(d.boxes[idx['Risk::limit']].near), { 'Risk::check' }, 'Risk::limit: its one caller, not the box nearest above it')
  eq(names_of(d.boxes[idx['Book::apply']].near), { 'Book::cancel', 'Book::insert', 'Engine::tick' }, 'Book::apply: the centre above, its two callees below')
  eq(G.layout({ center = tick, layers = { callees = { { apply }, { insert } } } }, 100, false).boxes[2].near, nil, 'a straight chain: nothing to dim')
  -- drawn: everything not linked to the selection takes the faint colour
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, d.lines)
  local s = { buf = buf, drawn = d }
  G.select(s, idx['Risk::limit'])
  local faint = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, G.sel_ns, 0, -1, { details = true })) do
    if m[4].hl_group == 'DeskCallGraphFaint' then faint[(m[2] + 1) .. ':' .. m[3]] = true end
  end
  local function dimmed(name) local sp = d.boxes[idx[name]].spans[2]; return faint[sp[1] .. ':' .. sp[2]] == true end
  eq({ dimmed('Book::insert'), dimmed('Book::apply'), dimmed('Engine::tick'), dimmed('Risk::check'), dimmed('Risk::limit') },
    { true, true, true, false, false }, 'Risk::limit selected: its caller stays lit, the others dim')
  api.nvim_buf_delete(buf, { force = true })
end

-- ─── I: the possible implementations of a virtual function (Codex's C8) ─────────────────────────────────────
do
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  vim.fn.writefile({ 'struct Sink { virtual void send(int) = 0; };', 'struct Wire : Sink { void send(int) override; };', 'struct Log : Sink { void send(int) override; };' }, d .. '/sink.hpp')
  local u = vim.uri_from_fname(d .. '/sink.hpp')
  local function at(line, ch) return { start = { line = line, character = ch }, ['end'] = { line = line, character = ch + 4 } } end
  local places = G.implementations({ { uri = u, range = at(1, 26) }, { targetUri = u, targetSelectionRange = at(2, 25), targetRange = at(2, 0) }, { uri = u, range = at(1, 26) } },
    function(file, line) return vim.fn.readfile(file)[line] end)
  eq(vim.tbl_map(function(p) return { p.line, p.col, p.label } end, places), {
    { 2, 26, 'struct Wire : Sink { void send(int) override; }; · sink.hpp:2' },
    { 3, 25, 'struct Log : Sink { void send(int) override; }; · sink.hpp:3' } },
    'the server\'s locations and location links, each once, in order, named by their line')
  -- asked of the server at the box's own place; several offered as possible implementations
  local real_clients, real_transport, real_select = G.clients, G.transport, vim.ui.select
  local sent, offered
  local src = vim.fn.bufadd(d .. '/sink.hpp')
  vim.fn.bufload(src)
  G.clients = function() return { { id = 5, name = 'fakeimpl' } } end
  G.transport = function(_, _, method, params, done)
    sent = { method, params.textDocument.uri == u, params.position.line }
    vim.schedule(function() done(nil, { { uri = u, range = at(1, 26) }, { uri = u, range = at(2, 25) } }) end)
    return function() end
  end
  vim.ui.select = function(items, opts, done) offered = { opts.prompt, vim.tbl_map(opts.format_item, items) }; done(nil) end
  G._implementations({ name = 'Sink::send', raw = { name = 'Sink::send', uri = u, selectionRange = at(0, 27) } }, src)
  ok(vim.wait(1000, function() return offered ~= nil end), 'I: the server asked, the answer offered')
  eq(sent, { 'textDocument/implementation', true, 0 }, '… at the box\'s own place')
  eq(offered and offered[1], 'Possible implementations of Sink::send (one of them runs)', '… as possible implementations, never as calls')
  G.clients, G.transport, vim.ui.select = real_clients, real_transport, real_select
  vim.fn.delete(d, 'rf')
end

-- ─── gl: the graph's functions in a window's location list ───────────────────────────────────────────────────────
do
  local function at(name, file, line) return { name = name, detail = file .. ':' .. line, uri = vim.uri_from_fname('/w/' .. file), range = { start = { line = line - 1, character = 2 } } } end
  local flush, push = at('Queue::flush', 'q.cpp', 84), at('push', 'q.cpp', 10)
  local graph = { center = at('drain', 'd.cpp', 5),
    layers = { callers = { { flush }, { push, flush } }, callees = { { at('grow', 'q.cpp', 30) } } } }
  local items, missing = G.loclist_items(graph)
  eq(vim.tbl_map(function(i) return { i.filename, i.lnum, i.col, i.text } end, items), {
    { '/w/d.cpp', 5, 3, 'Centre · drain · d.cpp:5' },
    { '/w/q.cpp', 84, 3, 'Caller, depth 1 · Queue::flush · q.cpp:84' },
    { '/w/q.cpp', 10, 3, 'Caller, depth 2 · push · q.cpp:10' },
    { '/w/q.cpp', 30, 3, 'Callee, depth 1 · grow · q.cpp:30' } },
    'gl: the centre, then each side level by level, each function once at its nearest depth')
  eq(missing, 0, '… none left out')
  local flat = { center = at('drain', 'd.cpp', 5), callers = { flush }, hidden = { callers = { push, { name = 'nowhere' } } } }
  items, missing = G.loclist_items(flat)
  eq({ #items, items[3] and items[3].text, missing }, { 3, 'Caller, depth 1 · push · q.cpp:10', 1 },
    'a graph of one level: what "+N more" left out is listed too; a box with no file is counted, not listed')
  -- Into a code window's location list; the quickfix list (the build's errors) kept.
  local code = vim.fn.tempname() .. '.c'
  vim.fn.writefile({ 'int x;' }, code)
  vim.cmd('tabnew ' .. vim.fn.fnameescape(code))
  local win = api.nvim_get_current_win()
  vim.fn.setqflist({}, ' ', { title = 'build', items = { { filename = code, lnum = 1, text = 'error: x' } } })
  local said
  local notify = vim.notify
  vim.notify = function(m) said = m end
  eq(G._to_loclist(graph), win, 'gl: the code window she is in')
  vim.notify = notify
  eq({ #vim.fn.getloclist(win), vim.fn.getloclist(win, { title = 1 }).title, vim.fn.getqflist({ title = 1 }).title, #vim.fn.getqflist() },
    { 4, 'call graph · drain', 'build', 1 }, '… its location list holds the four; the quickfix list is still the build\'s')
  ok(said and said:find('4 functions in the location list', 1, true) and said:find(':lnext', 1, true), '… and says how to walk them: ' .. tostring(said))
  vim.cmd('tabclose')
end

vim.fn.delete(dir, "rf")
print(string.format("test_callgraph: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
