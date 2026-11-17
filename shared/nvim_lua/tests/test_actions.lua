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

-- ─── where a row runs for the pop-out, and what it asks first ───────────────────────────────────────────────────
refused(row({ id = "t.both", drawn = true, remote = true }), "a row is one of them", "drawn in the pop-out and remote both")
eq(#T.add({ row({ id = "t.drawn", drawn = true, remote = false }) }), 1, "drawn, and said not to be remote, is fine")
refused(row({ id = "t.in1", input = "words" }), "input is a string", "an input that is not a table")
refused(row({ id = "t.in2", input = {} }), "asks for words (prompt), a pick (choices) or both", "an input that asks for nothing")
refused(row({ id = "t.in3", input = { prompt = "" } }), "input.prompt is its question", "an empty question")
refused(row({ id = "t.in4", input = { choices = { "a" } } }), "input.choices is function(ctx)", "choices that are not a function")
refused(row({ id = "t.in5", input = { prompt = "x", default = "y" } }), "input does not take default", "an input field it does not know")
-- A key with an input asks in the window it is pressed in: the pick, then the words; Esc or nothing typed runs nothing.
local got, prompts = nil, {}
local asking = T.add({ row({ id = "t.ask", key = "<leader>Za", run = function(c) got = { c.text, c.choice } end,
  input = { prompt = "Say: ", choices = function() return { { id = "a", name = "Alpha" }, { id = 2, name = "Another" } } end } }) })
eq(#asking, 1, "words and a pick are fine")
T.map("editor", { rows = asking })
local real_input, real_select = vim.ui.input, vim.ui.select
local typed, picked = "hello", 2
vim.ui.select = function(items, opts, done) prompts[#prompts + 1] = opts.prompt .. #items; done(picked and items[picked] or nil) end
vim.ui.input = function(opts, done) prompts[#prompts + 1] = opts.prompt; done(typed) end
local function press_ask() got = nil; vim.fn.maparg("<leader>Za", "n", false, true).callback(); return got end
eq({ press_ask(), prompts }, { { "hello", "2" }, { "X2", "Say: " } }, "a key with an input: the pick, the words, then it runs with both")
typed = nil
eq(press_ask(), nil, "Esc at the words runs nothing")
typed = "   "
eq(press_ask(), nil, "nothing typed runs nothing")
typed, picked = "hello", nil
eq(press_ask(), nil, "Esc at the pick runs nothing")
picked, typed = 1, "from the menu"
got = nil
T.run(T.get("t.ask"), { surface = "editor" })
eq(got, { "from the menu", "a" }, "chosen in a menu it asks the same")
vim.ui.input, vim.ui.select = real_input, real_select
-- The pop-out's door: a row's answers come with the act, and only the ones it asks for.
local acted_with
T.add({ row({ id = "t.remask", remote = true, run = function(c) acted_with = { c.text, c.choice } end,
    input = { prompt = "Say: ", choices = function(c) return c.none and {} or { { id = "a", name = "A" } } end } }),
  row({ id = "t.remplain", remote = true }),
  row({ id = "t.rempick", remote = true, input = { choices = function() return { { id = "a", name = "A" } } end } }) })
eq({ T.act("t.remask", { surface = "editor" }) }, { false, "X: needs its words" }, "an act without the words it asks for is refused")
eq({ T.act("t.remask", { surface = "editor", text = "hi" }) }, { false, "that choice is not offered here" }, "… without its pick")
eq({ T.act("t.remask", { surface = "editor", text = "hi", choice = "b" }) }, { false, "that choice is not offered here" },
  "… with a pick it does not offer")
eq({ T.act("t.remask", { surface = "editor", text = "hi", choice = "a", none = true }) }, { false, "that choice is not offered here" },
  "… or no longer offers")
eq({ T.act("t.remask", { surface = "editor", text = "hi", choice = "a" }), acted_with }, { true, { "hi", "a" } }, "with both it runs, with them")
eq({ T.act("t.remplain", { surface = "editor", text = "hi" }) }, { false, "t.remplain asks for nothing" }, "words for a row that asks none")
eq({ T.act("t.remplain", { surface = "editor", choice = "a" }) }, { false, "t.remplain asks for nothing" }, "… or a pick")
eq({ T.act("t.rempick", { surface = "editor", choice = "a", text = "x" }) }, { false, "t.rempick asks for no words" }, "words for a pick")
local described
for _, d in ipairs(T.describe({ surface = "editor" })) do if d.id == "t.remask" then described = d end end
eq(described and described.input, { prompt = "Say: ", choices = { { id = "a", name = "A" } } }, "describe sends what it asks, as data")
-- ctx.also: another surface's rows are the place's own too (the pop-out's, beside its view's).
T.add({ row({ id = "t.pop", group = "Work", key = "Q", on = "popout" }) })
eq({ vim.tbl_contains(ids(T.for_context({ surface = "since", also = { "popout" } })), "t.pop"),
  vim.tbl_contains(ids(T.for_context({ surface = "since" })), "t.pop") }, { true, false }, "ctx.also: that surface's rows apply too")
-- A key list of the rows given, run as its caller presses them.
local pressed
local listed = T.key_lines({ surface = "since" }, { rows = { T.get("t.s1"), T.get("t.global") }, press = function(r) pressed = r.id end })
eq(vim.tbl_map(function(l) return l.keys[1] end, listed), { "Q", "<leader>Zg" }, "a key list of the rows given, whatever surface they are on")
listed[2].run()
eq(pressed, "t.global", "… Enter on one runs it as the list's caller presses it")
-- The rows a pop-out view binds: its surface's drawn and remote ones, then the window's own; a view row on a key the
-- window takes is left out, and a row of the editor's only is never there.
T.add({ row({ id = "t.pq", group = "Work", key = "q", on = "popout" }), row({ id = "t.vd", key = "j", on = "since", drawn = true }),
  row({ id = "t.vr", key = "<CR>", on = "since", remote = true }), row({ id = "t.ve", key = "z", on = "since", remote = false }),
  row({ id = "t.vq", key = "q", on = "since", remote = true }) })
local bound, left = T.popout_rows("since")
eq({ ids(bound, "t."), left }, { { "t.vd", "t.vr", "t.pop", "t.pq" }, { "t.vq: q is t.pq in the pop-out" } },
  "a pop-out view's rows: the view's drawn and remote ones, then the window's own")
eq(ids(T.popout_rows(nil), "t."), { "t.pop", "t.pq" }, "no view: only the window's own")
-- What is here: one answer per surface.
eq({ T.provide("kitchen", function() end) }, { false, "no surface is called kitchen" }, "an answer for no surface is refused")
eq({ T.provide("since", "x") }, { false, "about is function(ctx)" }, "… and one that is no function")
eq({ T.about({ surface = "menu" }) }, { nil, "nothing here says what it is" }, "a surface with no answer says so")
T.provide("since", function(c)
  if c.empty then return nil, "no row here" end
  if c.broken then error("boom") end
  if c.nameless then return { title = "" } end
  return { title = "Row 3", refs = { { kind = "code", label = "a.lua:3", file = "a.lua", line = 3 }, "junk", { kind = 1 } }, excerpt = "x = 1" }
end)
eq(T.about({ surface = "since" }), { title = "Row 3", refs = { { kind = "code", label = "a.lua:3", file = "a.lua", line = 3 } }, excerpt = "x = 1" },
  "what is here: its title, its references (each a kind and a label), an excerpt")
eq({ T.about({ surface = "since", empty = true }) }, { nil, "no row here" }, "nothing there: why")
eq((select(2, T.about({ surface = "since", broken = true })) or ""):match("^can't tell"), "can't tell", "an answer that fails: can't tell")
eq({ T.about({ surface = "since", nameless = true }) }, { nil, "what is here has no name" }, "an answer without a name is none")

-- ─── the one speller ────────────────────────────────────────────────────────────────────────────────────────────
local spelled = {}
for _, key in ipairs({ "<CR>", "<cr>", "<S-CR>", "<BS>", "<Tab>", "<S-Tab>", "<Esc>", "<Down>", "<Up>", "<Space>", "<2-LeftMouse>",
  "<leader>cc", "<Leader>Cw", "<leader><leader>", "<leader><Tab>", "<leader><CR>", "<C-w>", "<c-a>", "j", "gs", "]f", "?" }) do
  spelled[#spelled + 1] = T.spell(key)
end
eq(spelled, { "Enter", "Enter", "Shift+Enter", "BS", "Tab", "Shift+Tab", "Esc", "↓", "↑", "Space", "double click", "Space cc",
  "Space Cw", "Space Space", "Space Tab", "Space Enter", "Ctrl+w", "Ctrl+a", "j", "gs", "]f", "?" }, "keys as she reads them")

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
ok(text:find("What changed", 1, true) and text:find("Space Cw", 1, true), "a row with its key, spelled as every key list spells it")
local home_width, cut = api.nvim_win_get_config(Menu._last.win).width, {}
for _, l in ipairs(api.nvim_buf_get_lines(Menu._last.buf, 0, -1, false)) do
  if vim.fn.strdisplaywidth(l) > home_width then cut[#cut + 1] = l end
end
eq(cut, {}, "every line of the home menu fits its window: no key cut off at the edge")
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

-- ─── the pop-out's view kinds: every row on a kind's surface says where it runs ─────────────────────────────────────
local P = require("desk.popout")
ok(P.kinds.graph and P.kinds.graph.surface == "callgraph", "the call graph registers its view kind, on the graph tab's surface")
for name, kind in pairs(P.kinds) do
  local unsaid = {}
  for _, r in ipairs(A.rows()) do
    local on = type(r.on) == "table" and r.on or { r.on }
    if vim.tbl_contains(on, kind.surface) and not r.drawn and r.remote == nil then unsaid[#unsaid + 1] = r.id end
  end
  eq(unsaid, {}, name .. ": every row on " .. kind.surface .. " is drawn, remote, or says remote = false")
  local bound, clashes = A.popout_rows(kind.surface)
  eq(clashes, {}, name .. ": no row of its surface is on a key the pop-out's own rows take")
  local stray = {}
  for _, r in ipairs(bound) do
    local on = type(r.on) == "table" and r.on or { r.on }
    if not (r.drawn or r.remote or vim.tbl_contains(on, "popout")) then stray[#stray + 1] = r.id end
  end
  eq(stray, {}, name .. ": in the pop-out only its drawn and remote rows, and the window's own")
end
-- Space Space in code: the project map's rows after this function's, before the review's; never after every group.
require("desk.map")
local home_rows = A.for_context({ surface = "editor" })
local function first_of(group) for i, r in ipairs(home_rows) do if r.group == group then return i end end end
ok(first_of("This function") < first_of("Project map") and first_of("Project map") < first_of("Review"),
  "the project map's rows come after this function's and before the review's in Space Space")
-- A row's name too long for the menu ends in … and its key stays inside the window.
local laid = Menu.layout({ { name = string.rep("very long words ", 10), label = "x", bind = "<leader>cc", group = "work" },
  { name = "Short", label = "y", bind = "<CR>", group = "work" } }, {})
local overflow = vim.tbl_filter(function(l) return vim.fn.strdisplaywidth(l) > laid.width end, laid.lines)
eq({ overflow, laid.lines[1]:find("…", 1, true) ~= nil, laid.lines[1]:find("Space cc", 1, true) ~= nil, laid.lines[2]:find("Enter", 1, true) ~= nil },
  { {}, true, true, true }, "a long name is cut with …, and every key is spelled and inside the window")
-- A key list's reasons (why a row cannot run) are cut short, so the descriptions keep their room; and on a wide screen
-- the list is wider than 92 columns, so a long description is whole.
local long_doc = "The next / previous view (each view is a tab); a count first goes to that view: 2gt the second"
local keyed = Menu.layout({ { keys = { "gt", "gT" }, name = long_doc, about = "x", group = "pop-out" },
  { keys = { "c" }, name = "Centre", about = "y", group = "pop-out", right = "this box is not from the language server yet, so wait" } },
  { keys = true, max_width = 160 })
local doc_line = keyed.lines[1]:find("gt/gT", 1, true) and keyed.lines[1] or keyed.lines[2]
eq({ doc_line:find(long_doc, 1, true) ~= nil, vim.fn.strdisplaywidth(vim.trim(keyed.lines[2]):match("this box.*$") or "") <= Menu.MAX_STATE },
  { true, true }, "a key list on a wide screen: the description whole, the reason cut to its column")
local fifty = "Go to the selected function in the code it came from"
local narrow = Menu.layout({ { keys = { "c" }, name = fifty, about = "x", group = "g" },
  { keys = { "r" }, name = "Read", about = "y", group = "g", right = "this box is not from the language server yet, so wait" } }, { keys = true })
ok(narrow.lines[1]:find(fifty, 1, true), "… and at the usual 92 columns a long reason leaves a 50-character description whole: " .. narrow.lines[1])
-- A row's choices are asked as the desk menu (vim.ui.select, desk.menu.select), a few with a letter each as their key
-- there; choices whose letters would clash are rows without one. (confirm() lost its list when asked as a menu closed.)
do
  local real_select, got, prompt = vim.ui.select, nil, nil
  vim.ui.select = function(items, opts, done) prompt = opts.prompt; return Menu.select(items, opts, done) end
  A.ask({ choices = function() return { { id = "next", name = "Next commit" }, { id = "close", name = "Close review" }, { id = "stay", name = "Stay" } } end },
    {}, function(_, choice) got = choice end, "Finish review")
  local asked = menu_text()
  ok(asked:find("Next commit", 1, true) and asked:find("Close review", 1, true) and asked:find("Stay", 1, true), "every choice a row:\n" .. asked)
  ok(asked:find("  c  Close review", 1, true), "… with its letter")
  vim.fn.maparg("c", "n", false, true).callback()
  eq({ prompt, got }, { "Finish review", "close" }, "its letter picks it")
  got = nil
  A.ask({ choices = function() return { { id = "one", name = "The first" }, { id = "two", name = "The second" } } end }, {},
    function(_, choice) got = choice end)
  ok(vim.fn.maparg("t", "n") == "", "… two whose letters clash: no letter")
  ok(press_on("The second"), "… picked from the rows")
  eq(got, "two", "… with Enter")
  vim.ui.select = real_select
end
local saved_columns = vim.o.columns
vim.o.columns = 200
local wide_win = Menu.open({ { keys = { "gt" }, name = long_doc, about = "x", group = "pop-out" } }, { keys = true, title = "Keys" })
eq(api.nvim_win_get_config(wide_win).width > 92, true, "… the list opens as wide as the screen lets it")
api.nvim_win_close(wide_win, true)
vim.o.columns = saved_columns
-- Retro: every menu's group headings in capitals (as the key lists'), and the strip a square box (the DOS frame's).
vim.g.desk_style, vim.g.desk_border = "retro", { "╔", "═", "╗", "║", "╝", "═", "╚", "║" }
local retro_win = Menu.open({ { name = "One", label = "One — first", group = "this function" }, { name = "Two", label = "Two — second", group = "work" } },
  { title = "Test" })
local retro_text = table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(retro_win), 0, -1, false), "\n")
eq({ retro_text:find(" ── THIS FUNCTION ", 1, true) ~= nil, retro_text:find(" ┌─", 1, true) ~= nil, retro_text:find("╭", 1, true) == nil },
  { true, true, true }, "retro: the home menu's headings in capitals, the strip square")
api.nvim_win_close(retro_win, true)
vim.g.desk_style, vim.g.desk_border = nil, nil
ok(Menu.layout({ { name = "One", label = "x", group = "a" }, { name = "Two", label = "y", group = "b" } }, {}).lines[1]:find(" ── a ", 1, true)
  and table.concat(Menu.layout({ { name = "One", label = "x" } }, {}).lines, "\n"):find("╭", 1, true), "… paper: as written, the strip rounded")
-- The one voice: capitals in retro for the words, never for a key or command between backticks.
eq(A.voice(true)("Move on; `k` the previous one, `desk-work map build`"), "MOVE ON; k THE PREVIOUS ONE, desk-work map build",
  "retro: capitals for the words; keys and commands between backticks as typed")
eq(A.voice(false)("`k` the previous one"), "k the previous one", "paper: as written, the backticks gone")
eq({ Menu.voice, require("desk.callgraph").glyphs(true).said("press `o` here") }, { A.voice, "PRESS o HERE" },
  "desk.menu and the call graph's drawing speak with it")
-- In every module's rows (the review's, the map's and the since page's too: retro shouted their r, c, Esc and Enter), a
-- key of the row's own surfaces named in its words is between backticks, so the retro voice leaves it alone ("K THE
-- PREVIOUS ONE" was another key).
local unquoted = {}
local named = { Enter = true, Esc = true, Tab = true, Space = true, Backspace = true }
for _, r in ipairs(A.rows()) do
  local own = {}
  local surfaces = type(r.on) == "table" and r.on or { r.on }
  for _, other in ipairs(A.rows()) do
    local their = type(other.on) == "table" and other.on or { other.on }
    for _, s in ipairs(surfaces) do
      -- (the article "a" is never read as the review's key a)
      if other.key and #other.key == 1 and other.key:match("%a") and other.key ~= "a" and vim.tbl_contains(their, s) and s ~= "editor" then
        own[other.key] = true
      end
    end
  end
  for _, words in ipairs({ r.about or "", type(r.doc) == "string" and r.doc or "" }) do
    local bare = words:gsub("`[^`]*`", " ")
    for word in bare:gmatch("%f[%w%+']([%w%+']+)%f[^%w%+']") do
      if own[word] or named[word] then unquoted[#unquoted + 1] = r.id .. ": " .. word end
    end
  end
end
eq(unquoted, {}, "a key named in a row's words is between backticks")
-- The one speller: the menus' key lists, the call graph's key lines and the pop-out spell with it.
eq(Menu.typed, A.spell, "desk.menu spells keys with actions.spell")
eq(require("desk.callgraph").typed("go", "back", "down"), "Enter/BS/j", "the call graph's key lines too")
eq(P.shown_key, nil, "the pop-out has no speller of its own")

-- vim.ui.select as the desk menu (2026-11-16: every "choose one" question was Neovim's numbered list): Enter on a row
-- answers with it and its number, Esc answers nil — exactly once either way.
do
  local answers = {}
  Menu.select({ "Trader", "Claude mods", "Linux_Theme" }, { prompt = "Review with API credits:" },
    function(item, i) answers[#answers + 1] = { item or false, i or false } end)
  ok(Menu._last and api.nvim_win_is_valid(Menu._last.win), "select opens the menu")
  ok(vim.inspect(api.nvim_win_get_config(Menu._last.win).title):find("Review with API credits", 1, true), "… titled with the question")
  ok(press_on("Claude mods"), "… a row per choice")
  eq(answers, { { "Claude mods", 2 } }, "Enter answers with the item and its number, once")
  answers = {}
  Menu.select({ "a", "b" }, { prompt = "Pick" }, function(item, i) answers[#answers + 1] = { item or false, i or false } end)
  vim.fn.maparg("<Esc>", "n", false, true).callback()
  eq(answers, { { false, false } }, "Esc answers nil, once")
end

-- The screen question as a map of the screens (desk.screens, her ask 2026-11-16): each in its place and shape, the
-- chosen one with the pop-out in it, h/j/k/l to the screen that way; screens without a place get the list.
do
  local Scr = require("desk.screens")
  local three = {
    { id = "eDP-1", name = "eDP-1 (this screen)", here = true, x = 0, y = 0, width = 1920, height = 1080, scale = 1, transform = 0 },
    { id = "DP-2", name = "DP-2 · Acer", x = 1920, y = 0, width = 3840, height = 2160, scale = 1.5, transform = 0 },
    { id = "HDMI-A-1", name = "HDMI-A-1 · Dell", x = 4480, y = 0, width = 1920, height = 1080, scale = 1, transform = 1 },
  }
  eq(Scr.geometry(three[2]), { x = 1920, y = 0, w = 2560, h = 1440 }, "a scaled screen: its size in the desktop's units")
  eq(Scr.geometry(three[3]), { x = 4480, y = 0, w = 1080, h = 1920 }, "a rotated one: on its side")
  eq(Scr.places({ three[1], { id = "X" } }), nil, "a screen without a place: no map")
  local places = Scr.places(three)
  local d = Scr.layout(three, places, 2, 64, 14, false)
  local b = d.boxes
  ok(b[1].x < b[2].x and b[2].x < b[3].x, "the boxes left to right, as the screens stand")
  ok(b[2].w > b[1].w and b[3].h * 2 > b[3].w and b[1].h * 2 < b[1].w, "… in their shapes: the big one wider, the rotated one tall")
  local text = table.concat(d.lines, "\n")
  ok(text:find("╔", 1, true) and text:find(" pop-out ", 1, true) and text:find("this editor", 1, true),
    "the chosen one doubled with the pop-out in it, the editor's own marked:\n" .. text)
  for _, line in ipairs(d.lines) do ok(vim.fn.strdisplaywidth(line) <= 64, "every line fits: " .. line) end
  eq({ Scr.nav(places, 1, "l"), Scr.nav(places, 2, "l"), Scr.nav(places, 3, "h"), Scr.nav(places, 1, "h"), Scr.nav(places, 1, "j") },
    { 2, 3, 2, 1, 1 }, "l and h go to the screen that way; where none is, it stays")
  local real_select, got = vim.ui.select, nil
  vim.ui.select = Menu.select
  local function key(lhs) vim.fn.maparg(lhs, "n", false, true).callback() end
  A.ask({ choices = function() return three end, kind = "desk_screens" }, {}, function(_, choice) got = choice end, "Pop out on")
  ok(Scr._last and api.nvim_win_is_valid(Scr._last.win), "the screen question opens as the map")
  ok(vim.inspect(api.nvim_win_get_config(Scr._last.win).title):find("Pop out on", 1, true), "… titled with the question")
  key("l"); key("l")
  eq(Scr._last.state.selected, 3, "l l: the third screen")
  key("<CR>")
  eq({ got, api.nvim_win_is_valid(Scr._last.win) }, { "HDMI-A-1", false }, "Enter: that screen, and the map closes")
  got = nil
  A.ask({ choices = function() return three end, kind = "desk_screens" }, {}, function(_, choice) got = choice or "none" end)
  key("<Esc>")
  vim.wait(100)
  eq(got, nil, "Esc: nothing chosen, nothing run")
  local listed = Menu._last and Menu._last.buf
  A.ask({ choices = function() return { { id = "a", name = "Screen A" }, { id = "b", name = "Screen B" } } end, kind = "desk_screens" },
    {}, function() end)
  ok(Menu._last.buf ~= listed and menu_text():find("Screen B", 1, true), "screens without places: the list")
  key("<Esc>")
  vim.ui.select = real_select
end

vim.fn.delete(dir, "rf")
print(string.format("test_actions: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
