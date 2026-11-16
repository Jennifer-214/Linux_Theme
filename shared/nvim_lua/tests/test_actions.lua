-- nvim --headless --clean -l shared/nvim_lua/tests/test_actions.lua : desk.actions, the one list of actions, and the home
-- menu drawn from it (desk.menu here: symdeps is absent, or a fake of it).
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
-- Neovim looks in the runtime path (the installed copy under ~/.config/nvim) before package.path: load the repo's.
table.insert(package.loaders, 2, function(name)
  local file = here .. "../" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
vim.g.mapleader = " "
local api = vim.api
local passed, failed = 0, 0
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want)) end
end
local function ok(cond, what) eq(not not cond, true, what) end
local said = {}
vim.notify = function(text) said[#said + 1] = tostring(text) end
local function heard(pattern) for _, s in ipairs(said) do if s:find(pattern, 1, true) then return true end end end
local function ids(list, prefix)
  local out = {}
  for _, row in ipairs(list) do if not prefix or row.id:sub(1, #prefix) == prefix then out[#out + 1] = row.id end end
  return out
end

-- ─── the guards: a throwaway registry, so the real one stays as the modules filled it ──────────────────────────
local T = dofile(here .. "../desk/actions.lua")
local function row(extra)
  local r = { id = "t.x", group = "Test", name = "X", about = "x", on = "editor", run = function() end }
  for k, v in pairs(extra) do r[k] = v end
  return r
end
local function refused(r, pattern, what)
  local n = #T.problems
  eq(#T.add({ r }), 0, what .. ": not taken")
  ok((T.problems[n + 1] or ""):find(pattern, 1, true), what .. ", and why: " .. tostring(T.problems[n + 1]))
end
refused(row({ id = "t.colour", colour = "pink" }), "unknown field colour", "an unknown field")
refused({ id = "t.nocode", group = "Test", name = "No code", about = "x", on = "editor" }, "has no code", "a row without code")
refused(row({ id = "t.string", run = "echo" }), "run is a string", "code that is not a function")
refused(row({ id = "t.nowhere", on = "kitchen" }), "no surface is called kitchen", "a surface that does not exist")
refused({ id = "t.mute", group = "Test", name = "Mute", on = "editor", run = function() end }, "needs about", "a menu row without words")
refused(row({ id = "noprefix" }), "'<module>.<name>'", "an id without its module")
eq(#T.add({ row({ id = "t.one", key = "<leader>Zz" }) }), 1, "a row is taken")
refused(row({ id = "t.two", key = "<Leader>Zz" }), "<Leader>Zz (n) on editor is already t.one", "two rows with one key on one surface")
eq(#T.add({ row({ id = "t.three", key = "<leader>Zz", on = "since" }) }), 1, "one key on two surfaces is fine")
eq(#T.add({ row({ id = "t.four", key = "<leader>Zz", mode = "x" }) }), 1, "one key in two modes is fine")
eq(#T.add({ { id = "t.alt", group = "Test", name = "Alt", key = "q", on = "editor", menu = false, run = function() end } }), 1,
  "a row in no menu needs no words")
-- Another module, adding as modules do (a tail call `return T.add(...)` would hide which file it is).
local other = load("local T, r = ...; local taken = T.add({ r }); return taken", "@/nonexistent/other.lua")
eq(#other(T, row({ id = "t.one" })), 0, "another file cannot take an id")
ok(T.problems[#T.problems]:find("already a row of", 1, true), "… and says whose it is")
local count = #T.rows()
eq(#T.add({ row({ id = "t.one", key = "<leader>Zz", name = "X again" }) }), 1, "the same file adding again (a reload) replaces")
eq({ #T.rows(), T.get("t.one").name }, { count, "X again" }, "… in place")
ok(heard("An action was left out"), "a refusal is said out loud")

-- ─── binding: global keys, a surface's buffer, and what a run gets ─────────────────────────────────────────────
local seen
local global = T.add({ row({ id = "t.global", key = "<leader>Zg", name = "Global test key", run = function(ctx) seen = ctx end }) })
T.map("editor", { rows = global })
local m = vim.fn.maparg("<leader>Zg", "n", false, true)
eq({ m.desc, m.buffer }, { "Global test key", 0 }, "a global key, described by its row's name")
m.callback()
eq({ seen.surface, seen.win }, { "editor", api.nvim_get_current_win() }, "its run gets where it was pressed")
T.add({ row({ id = "t.page", key = "x", on = "since", run = function(ctx) seen = ctx end }) })
local page = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(page)
T.map("since", { buffer = page, nowait = true, ctx = { page = "the page" } })
m = vim.fn.maparg("x", "n", false, true)
eq({ m.buffer, m.nowait }, { 1, 1 }, "a surface's keys are its buffer's, mapped as it asks")
m.callback()
eq({ seen.surface, seen.page, seen.buf }, { "since", "the page", page }, "a run gets the surface and what it passed")
eq(T.context().surface, "since", "the buffer is that surface for the home menu too")
vim.cmd("enew")
eq(T.context().surface, "editor", "any other buffer is the editor")
ok(vim.fn.maparg("<leader>Zz", "n") == "", "rows on a surface are bound only where it is mapped")

-- ─── what applies where ─────────────────────────────────────────────────────────────────────────────────────────
T.add({
  row({ id = "t.e1", group = "Review", key = "<leader>Zr" }),
  row({ id = "t.e2", group = "Claude", key = "Q" }),
  row({ id = "t.e3", group = "Work", available = function() return false end }),
  row({ id = "t.e4", group = "Work", available = function() return "requires the moon" end }),
  row({ id = "t.e5", group = "Claude", key = "<leader>Zs", mode = "x" }),
  row({ id = "t.s1", group = "Work", key = "Q", on = "since" }),
  row({ id = "t.odd", group = "Odd one", key = "<leader>Zo" }),
})
eq(ids(T.for_context({ surface = "editor" }), "t.e"), { "t.e1", "t.e2", "t.e4" }, "the editor: groups in order; does-not-apply left out, a reason kept")
eq(ids(T.for_context({ surface = "since" }), "t.e"), { "t.e1", "t.e4" }, "a surface's key hides the editor row on the same key")
local on_since = ids(T.for_context({ surface = "since" }), "t.")
ok(vim.fn.index(on_since, "t.s1") < vim.fn.index(on_since, "t.e4"), "the surface's own rows come first in their group")
ok(on_since[#on_since] == "t.odd", "a group M.GROUPS does not name comes last")
eq(ids(T.for_context({ surface = "editor", mode = "x" }), "t.e"), { "t.e5", "t.e4" }, "a selection's menu has the selection's rows")
eq(T.available(row({ available = function() error("boom") end }), {}):match("^can't tell"), "can't tell", "a check that fails says it can't tell")

-- ─── the real registry: every module's rows ─────────────────────────────────────────────────────────────────────
local A = require("desk.actions")
for _, name in ipairs({ "claude", "work", "since", "review" }) do require("desk." .. name) end
eq(A.problems, {}, "every module's rows were taken")
local known = {}
for _, r in ipairs(A.rows()) do known[r.id] = true end
for _, r in ipairs(A.rows()) do
  local why = A.check(r)
  if why then eq(why, nil, "a sound row") end
  if r.line and not known[r.line] then eq(r.line, "a row id", r.id .. " joins the reference line of a row that exists") end
end
local R = require("desk.review")
eq({ R.bind("mark"), R.bind("finish"), R.bind("file-list"), R.bind("list-back"), R.bind("enter") }, { "m", "R", "<leader>re", "<BS>", "<CR>" },
  "the review's keys are where they were")
eq(vim.tbl_map(function(k) return k.key end, A.keys("since")), { "?", "<CR>", "q" }, "the since page's keys, for a ? list")
local diff_keys = vim.tbl_map(function(k) return k.key end, A.keys("review-diff"))
ok(vim.tbl_contains(diff_keys, "m") and vim.tbl_contains(diff_keys, "<BS>") and not vim.tbl_contains(diff_keys, "h"), "the comparison's keys, not the list's")
ok(not vim.tbl_contains(vim.tbl_map(function(k) return k.key end, A.keys("review-list")), "<2-LeftMouse>"), "a mouse key is in no ? list")
A.setup()
eq(vim.fn.maparg("<leader><leader>", "n", false, true).desc, "Home menu", "Space Space is the home menu")

-- ─── the home menu (desk.menu: symdeps is absent) ──────────────────────────────────────────────────────────────
local Menu = require("desk.menu")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "local x = 1" }, dir .. "/sample.lua")
vim.cmd.edit(dir .. "/sample.lua")
local origin = api.nvim_get_current_win()
local pinged
A.add({ { id = "test.ping", group = "Work", name = "Ping the test", about = "Says pong", on = "editor", run = function(ctx) pinged = ctx end } })
local function menu_text() return table.concat(api.nvim_buf_get_lines(Menu._last.buf, 0, -1, false), "\n") end
local function press_on(pattern)
  local lines = api.nvim_buf_get_lines(Menu._last.buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:find(pattern, 1, true) and l:sub(1, 2) == "  " then
      api.nvim_win_set_cursor(Menu._last.win, { i, 0 })
      vim.fn.maparg("<CR>", "n", false, true).callback()
      return true
    end
  end
end
vim.fn.maparg("<leader><leader>", "n", false, true).callback()
ok(Menu._last and api.nvim_win_is_valid(Menu._last.win), "Space Space opens the menu")
local text = menu_text()
ok(text:find(" ── review ", 1, true) and text:find(" ── claude ", 1, true) and text:find(" ── work ", 1, true) and text:find(" ── symdeps ", 1, true),
  "its groups:\n" .. text)
ok(text:find(" ── review ", 1, true) < text:find(" ── claude ", 1, true) and text:find(" ── work ", 1, true) < text:find(" ── symdeps ", 1, true),
  "in order")
ok(text:find("What changed", 1, true) and text:find("<ldr>Cw", 1, true), "a row with its key")
ok(text:find("requires symdeps", 1, true), "symdeps absent: its one row, with the reason")
ok(not text:find("This function in symdeps", 1, true), "… and no second symdeps row")
ok(not text:find("Home menu", 1, true) and not text:find("Selection to a Claude", 1, true), "the home key and a selection's row are not in it")
ok(vim.inspect(api.nvim_win_get_config(Menu._last.win).title):find("Home · sample.lua", 1, true), "titled with the place")
local menu_win = Menu._last.win
A.home()
eq(Menu._last.win, menu_win, "Space Space inside the menu opens no second one")
press_on("requires symdeps")
ok(heard("Requires symdeps."), "a row that cannot run says why instead")
ok(not api.nvim_win_is_valid(menu_win), "… and the menu closes")
vim.fn.maparg("<leader><leader>", "n", false, true).callback()
press_on("Ping the test")
eq({ pinged and pinged.surface, pinged and pinged.win, api.nvim_get_current_win() }, { "editor", origin, origin },
  "a row runs in the window the menu was opened from")

-- symdeps installed (a fake): its menu on its own key, and its card in C and C++.
local carded
package.loaded["fox-symdeps"] = { inspect_cursor = function() carded = "plugin" end }
package.loaded["fox-symdeps.card"] = { inspect_cursor = function() carded = "card" end }
local ctx = A.context()
local symdeps_rows = vim.tbl_filter(function(r) return r.group == "symdeps" or r.group == "This function" end, A.for_context(ctx))
eq(ids(symdeps_rows), { "symdeps.card", "symdeps.menu" }, "with symdeps: the card in This function, its menu in symdeps")
eq(A.available(A.get("symdeps.card"), ctx), "requires a C or C++ file", "the card outside C and C++ says why")
vim.bo.filetype = "cpp"
ctx = A.context()
eq(A.available(A.get("symdeps.card"), ctx), true, "in C++ it can run")
A.run(A.get("symdeps.card"), ctx)
eq(carded, "card", "it opens symdeps' card")
local opened = 0
vim.keymap.set("n", "<leader>dm", function() opened = opened + 1 end)
A.run(A.get("symdeps.menu"), ctx)
api.nvim_feedkeys("", "x", false)
eq(opened, 1, "symdeps' row presses symdeps' own menu key")
vim.keymap.del("n", "<leader>dm")
A.run(A.get("symdeps.menu"), ctx)
ok(heard("nothing is on its menu key"), "a symdeps with no menu key says so")
eq(A.available(A.get("symdeps.card"), { surface = "review-diff", filetype = "cpp" }), false, "the review has its own symdeps keys")

-- A review's comparison: its rows first in Review, the editor's after; the plumbing keys in no menu.
local cmp = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(cmp)
A.map("review-diff", { buffer = cmp, silent = true, ctx = { review = { id = "fake" } } })
eq({ vim.fn.maparg("m", "n", false, true).desc, vim.fn.maparg("m", "n", false, true).silent }, { "Mark/unmark file reviewed", 1 },
  "the review's keys on its buffer")
ctx = A.context()
eq({ ctx.surface, ctx.review.id }, { "review-diff", "fake" }, "the comparison is its surface, with its review")
local review_ids = ids(vim.tbl_filter(function(r) return r.group == "Review" end, A.for_context(ctx)))
eq(review_ids[1], "review.next-file", "the review's own rows lead its group")
ok(vim.fn.index(review_ids, "claude.changes") > vim.fn.index(review_ids, "review.close"), "… the editor's review rows after them")
ok(not vim.tbl_contains(review_ids, "review.mark-list"), "the list's rows are not the comparison's")
ok(vim.tbl_contains(review_ids, "review.clear"), "plumbing applies…")
vim.fn.maparg("<leader><leader>", "n", false, true).callback()
ok(not menu_text():find("Clear search highlight", 1, true), "… but is in no menu")
ok(vim.inspect(api.nvim_win_get_config(Menu._last.win).title):find("Home · review", 1, true), "titled with the review")
vim.fn.maparg("q", "n", false, true).callback()

-- ─── ? : the keys of a view, from its rows ───────────────────────────────────────────────────────────────────────
package.loaded["fox-symdeps"], package.loaded["fox-symdeps.card"] = nil, nil
require("desk.callgraph")
-- A buffer of its own: :enew would reuse the empty comparison buffer and wipe what it is.
api.nvim_set_current_buf(api.nvim_create_buf(true, false))
for _, surface in ipairs({ "review-list", "review-diff", "callgraph", "callgraph-panel", "since", "menu" }) do
  local b = api.nvim_create_buf(false, true)
  A.map(surface, { buffer = b, ctx = { review = { id = "fake" }, graph = {}, page = { actions = {} } } })
  eq(vim.api.nvim_buf_call(b, function() return vim.fn.maparg("?", "n", false, true).desc end), "The keys here", "? on " .. surface)
end
ok(vim.fn.maparg("?", "n") == "", "? stays backward search in code")
eq(A.get("review.actions").key, nil, "the review's actions left ?…")
eq({ A.key("review.actions-list"), A.get("review.actions").menu }, { "a", nil }, "… and stay on a and in the home menu")
local lines = A.key_lines({ surface = "review-list", filetype = "lua" })
local function line_of(word) for _, l in ipairs(lines) do if l.name:find(word, 1, true) then return l end end end
eq(line_of("Expand commit").keys, { "<CR>", "l" }, "rows that share a reference line share a list line (the mouse key left out)")
eq(line_of("Next / previous file").keys, { "]f", "[f", "<Tab>", "<S-Tab>" }, "… in its words when the line has its own")
eq(line_of("Inspect changed C++ symbol").right, "requires symdeps", "a key that cannot run here says why")
ok(not line_of("The keys here"), "? is not in its own list")
eq(line_of("Mark selected file").keys, { "m" }, "the list's own m, not the comparison's")
-- Pressed in the since page: a list in the menu kit's key form; Enter runs a row where ? was pressed.
local ran
A.add({ { id = "test.since-row", group = "Work", name = "Test the page", key = "T", on = "since", menu = false,
  about = "Says where it ran, `T` as typed", run = function(c) ran = c end } })
local page_buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(page_buf)
local page_win = api.nvim_get_current_win()
A.map("since", { buffer = page_buf, ctx = { page = { actions = {} } } })
vim.g.desk_border = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" }
vim.fn.maparg("?", "n", false, true).callback()
local list = Menu._last
local shown = menu_text()
ok(shown:find("  Enter  Open what this line names", 1, true) and shown:find("  T      Test the page", 1, true), "keys first, as typed, lined up:\n" .. shown)
ok(shown:find("⏎ run · / filter · q close", 1, true), "its footer")
local config = api.nvim_win_get_config(list.win)
ok(vim.inspect(config.title):find("Keys · since you last looked", 1, true), "titled with the place")
eq(type(config.border[1]) == "table" and config.border[1][1] or config.border[1], "╔", "drawn with the theme's border (vim.g.desk_border)")
press_on("Test the page")
eq({ ran and ran.surface, api.nvim_get_current_win() }, { "since", page_win }, "Enter runs the row in the view ? was pressed in")
vim.fn.maparg("?", "n", false, true).callback()
vim.fn.maparg("?", "n", false, true).callback()
eq(api.nvim_get_current_win(), page_win, "? again closes the list")
-- Retro: the words in capitals, the keys as typed (backticks mark a key in the words).
vim.g.desk_style = "retro"
vim.fn.maparg("?", "n", false, true).callback()
shown = menu_text()
ok(shown:find("  Enter  OPEN WHAT THIS LINE NAMES", 1, true) and shown:find("⏎ RUN · / FILTER · q CLOSE", 1, true), "retro words:\n" .. shown)
ok(vim.inspect(api.nvim_win_get_config(Menu._last.win).title):find("KEYS · SINCE YOU LAST LOOKED", 1, true), "… and its title")
api.nvim_win_set_cursor(Menu._last.win, { 3, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = Menu._last.buf })
ok(menu_text():find("SAYS WHERE IT RAN, T AS TYPED", 1, true), "the strip in capitals, its key as typed:\n" .. menu_text())
vim.fn.maparg("q", "n", false, true).callback()
eq(Menu.voice(true)("a `Space rw` b"), "A Space rw B", "the voice keeps what is between backticks")
vim.g.desk_style, vim.g.desk_border = nil, nil
-- In a menu: ? lists the menu's own keys over it, and q comes back to the menu.
vim.cmd.edit(dir .. "/sample.lua")
vim.fn.maparg("<leader><leader>", "n", false, true).callback()
local home_win = Menu._last.win
vim.fn.maparg("?", "n", false, true).callback()
shown = menu_text()
ok(shown:find("j/↓/k/↑", 1, true) and shown:find("Enter/l", 1, true) and shown:find("Filter the rows", 1, true), "the menu's keys:\n" .. shown)
vim.wait(50)
ok(api.nvim_win_is_valid(home_win), "the menu stays open beneath its key list")
vim.fn.maparg("q", "n", false, true).callback()
vim.wait(50)
eq({ api.nvim_get_current_win(), api.nvim_win_is_valid(home_win) }, { home_win, true }, "q goes back to the menu")
vim.fn.maparg("q", "n", false, true).callback()
-- The review: its actions are a row of Space Space, and the diff footer names ? keys.
api.nvim_set_current_buf(cmp)
vim.fn.maparg("<leader><leader>", "n", false, true).callback()
ok(menu_text():find("Review actions", 1, true), "Space Space in a review lists Review actions:\n" .. menu_text())
vim.fn.maparg("q", "n", false, true).callback()

-- ─── the pop-out's door: only remote rows, only where they can run ───────────────────────────────────────────────
local acted
A.add({ { id = "test.remote", group = "Work", name = "Remote test", about = "x", on = "editor", remote = true,
  available = function(c) return c.ready or "requires ready" end, run = function(c) acted = c.item end },
  { id = "test.broken", group = "Work", name = "Broken", about = "x", on = "editor", remote = true, run = function() error("it broke") end } })
eq({ A.act("test.nope") }, { false, "no action is called test.nope" }, "an unknown id is refused")
eq({ A.act("claude.note", { surface = "editor" }) }, { false, "claude.note is not one the pop-out may ask for" }, "a row that is not remote is refused")
eq({ A.act("test.remote", { surface = "editor" }) }, { false, "requires ready" }, "one that cannot run says why")
eq({ A.act("test.remote", { surface = "editor", ready = true, item = "box 3" }), acted }, { true, "box 3" }, "a remote row runs, with the item it was asked for")
local refusal = select(2, A.act("test.broken", { surface = "editor" }))
ok(refusal and refusal:find("it broke", 1, true), "a failing run is an answer, not an error")
local offered = A.describe({ surface = "editor" })
ok(#offered > 0, "the pop-out is offered rows")
for _, d in ipairs(offered) do
  ok(A.get(d.id).remote, d.id .. " is a remote row")
  for k, v in pairs(d) do if type(v) == "function" then eq(k, "plain data", "what the pop-out is sent has no code") end end
end

vim.fn.delete(dir, "rf")
print(string.format("test_actions: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
