-- nvim --headless --clean -l shared/nvim_lua/tests/test_nav.lua : the jump labels of desk.nav (s in the review's file
-- list and in the call graph), drawn by flash.nvim when it is installed, and the keys beside them: s in a diff is the
-- code's own s, and symdeps is gs on all of them.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
-- Neovim looks in the runtime path (the installed copy under ~/.config/nvim) before package.path: load the repo's.
table.insert(package.loaders, 2, function(name)
  local file = here .. "../" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
vim.g.mapleader = " "
vim.o.lines, vim.o.columns = 60, 120
local api = vim.api
local passed, failed = 0, 0
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want)) end
end
vim.notify = function() end

local N = require("desk.nav")
eq(N.label_list(3, { "a", "s", "d", "f" }), { { "a" }, { "s" }, { "d" } }, "one letter each while they last")
eq(N.label_list(5, { "a", "s" }), { { "a", "a" }, { "a", "s" }, { "s", "a" }, { "s", "s" }, false },
  "else two, the first picking a group; past two letters' worth, none")

local A = require("desk.actions")
local G = require("desk.callgraph")
local R = require("desk.review")
require("desk.popout")
eq(A.problems, {}, "every row was taken")

-- ─── the keys: s is labels in the list and the graphs, the code's s in a diff; gs is symdeps ─────────────────────
eq({ A.key("review.jump"), A.key("callgraph.jump"), A.get("callgraph.jump").drawn }, { "s", "s", true },
  "s labels, and the pop-out's graph has the tab's (drawn there, on its copy)")
eq({ A.key("review.symdeps"), A.key("callgraph.symdeps"), A.get("callgraph.symdeps").remote }, { "gs", "gs", true },
  "gs is symdeps in the review and the graph tab, and in the pop-out's graph (the tab's row, run in the editor)")
eq({ A.get("review.jump").on, A.get("callgraph.jump").on }, { "review-list", { "callgraph", "callgraph-panel" } },
  "labels in the review's list and the graphs (tab, panel; the pop-out's graph has the tab's keys), nowhere else")
local labelled = {}
for _, row in ipairs(A.rows()) do
  if row.key == "s" then for _, s in ipairs(type(row.on) == "table" and row.on or { row.on }) do labelled[#labelled + 1] = s end end
end
table.sort(labelled)
eq(labelled, { "callgraph", "callgraph-panel", "review-list" }, "no other view's s: menus, the notebook and the map have none")
local diff = api.nvim_create_buf(false, true)
A.map("review-diff", { buffer = diff, silent = true, ctx = { review = { id = "fake" } } })
api.nvim_buf_call(diff, function()
  eq(vim.fn.maparg("s", "n", false, true).buffer or 0, 0, "a diff has no s of its own: the code's s (flash) applies")
  eq(vim.fn.maparg("gs", "n", false, true).desc, "Inspect changed C++ symbol in working copy", "symdeps is gs in a diff")
end)
for _, id in ipairs({ "review.symdeps", "callgraph.symdeps" }) do
  eq(A.available(A.get(id), {}), "requires symdeps", id .. ": without symdeps, greyed with what it needs")
end
package.loaded["fox-symdeps"] = {}
eq({ A.available(A.get("review.symdeps"), {}), A.available(A.get("callgraph.symdeps"), {}) }, { true, true }, "with symdeps both can run")
local inspected
local symdeps = R.symdeps
R.symdeps = function(layout) inspected = layout end
api.nvim_buf_call(diff, function() vim.fn.maparg("gs", "n", false, true).callback() end)
eq(inspected, false, "gs in a diff inspects the changed symbol in symdeps")
R.symdeps, package.loaded["fox-symdeps"] = symdeps, nil

-- ─── the labels ─────────────────────────────────────────────────────────────────────────────────────────────────
local flash = vim.fn.expand("~/.local/share/nvim/lazy/flash.nvim")
if vim.fn.isdirectory(flash) == 0 then
  eq(N.labels_ready(), "requires flash.nvim", "without flash, s says what it needs")
  print("test_nav: flash.nvim is not installed here; the labels themselves were not drawn")
else
  vim.opt.rtp:append(flash)
  eq(N.labels_ready(), true, "flash is there")
  local Flash = require("flash")
  local function item(name) return { name = name, detail = "x.lua:1" } end

  -- The call graph: a label at each box's top-left corner; three labels for eight boxes need two letters each.
  Flash.setup({ labels = "asd", label = { uppercase = false } })
  local gbuf = api.nvim_create_buf(false, true)
  api.nvim_win_set_buf(0, gbuf)
  local laid = G.layout({ callers = { item("aaaa1"), item("aaaa2"), item("aaaa3"), item("aaaa4"), item("aaaa5") },
    center = { name = "the_middle_one", detail = "x.lua:9" }, callees = { item("leaf1"), item("leaf2") } }, 40, false)
  api.nvim_buf_set_lines(gbuf, 0, -1, false, laid.lines)
  local graph = { buf = gbuf, win = api.nvim_get_current_win(), drawn = laid }
  A.map("callgraph", { buffer = gbuf, nowait = true, ctx = { graph = graph } })
  G.select(graph, 1, true)
  api.nvim_feedkeys("sds", "x", false)
  local function where(list) return vim.tbl_map(function(l) return l.line .. ":" .. l.col end, list or {}) end
  local function labels(list) return vim.tbl_map(function(l) return l.label end, list or {}) end
  eq(where(N.drawn[1]), vim.tbl_map(function(b) return b.spans[1][1] .. ":" .. b.spans[1][2] end, laid.boxes),
    "a label on exactly every box, at its corner")
  eq(labels(N.drawn[1]), { "aa", "as", "ad", "sa", "ss", "sd", "da", "ds" }, "more boxes than labels: two letters, in reading order")
  eq(labels(N.drawn[2]), { "a", "s" }, "the first letter leaves its boxes, labelled by their second")
  eq(graph.index, 8, "typing ds selects the last box")
  eq(api.nvim_win_get_cursor(0), { laid.boxes[8].top + 1, laid.boxes[8].name_col }, "… its name under the cursor, as a move puts it")
  api.nvim_feedkeys("sz", "x", false)
  eq(graph.index, 8, "a key that is no label picks nothing")
  api.nvim_feedkeys("s" .. vim.keycode("<Esc>"), "x", false)
  eq(graph.index, 8, "nor does Esc")
  Flash.setup({ labels = "asdfghjkl", label = { uppercase = false } })
  api.nvim_feedkeys("sd", "x", false)
  eq({ graph.index, #N.drawn, labels(N.drawn[1]) }, { 3, 1, { "a", "s", "d", "f", "g", "h", "j", "k" } },
    "enough labels: one letter each, and d is the third box")

  -- The review's file list: a label on every row j and k stop on, at its first mark; none on headings or the strip.
  local rbuf = api.nvim_create_buf(false, true)
  api.nvim_win_set_buf(0, rbuf)
  api.nvim_buf_set_lines(rbuf, 0, -1, false, { " Review", "", " ── Working changes ───", "   ▸ ✓ a.lua", "       ƒ alpha",
    "   ▸ ○ b.lua", "", " ╭────╮", " │    │", " ╰────╯" })
  local review = { panel_buf = rbuf, panel_win = api.nvim_get_current_win(), entries = { [3] = {}, [4] = {}, [5] = {}, [6] = {} } }
  A.map("review-list", { buffer = rbuf, silent = true, ctx = { review = review } })
  api.nvim_win_set_cursor(0, { 4, 0 })
  api.nvim_feedkeys("sd", "x", false)
  eq(where(N.drawn[1]), { "3:1", "4:3", "5:7", "6:3" }, "labels on exactly the rows, at their first mark")
  -- The real list's strip and bar following it: tests/test_nvim_review.py.
  eq(api.nvim_win_get_cursor(0), { 5, 0 }, "typing d moves the cursor to the third row, as j and k move it")

  -- Esc while the labels show cancels them and nothing else: the list's own Esc (it hides the list) never runs, and the
  -- list stays with its cursor where it was (the VM tour's one FAIL, 2026-11-16).
  local hidden, hide = 0, R.hide_panel
  R.hide_panel = function() hidden = hidden + 1 end
  api.nvim_win_set_cursor(0, { 4, 0 })
  api.nvim_feedkeys("s" .. vim.keycode("<Esc>"), "x", false)
  vim.fn.getchar(1)                    -- a key left queued for the list comes into the typeahead …
  api.nvim_feedkeys("", "x", false)    -- … and runs there, as the editor's next key would
  R.hide_panel = hide
  eq({ hidden, api.nvim_win_get_cursor(0) }, { 0, { 4, 0 } }, "Esc on the list's labels: the labels go, the list and its cursor stay")
end

print(string.format("test_nav: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
