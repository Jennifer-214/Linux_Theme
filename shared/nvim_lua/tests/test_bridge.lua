-- nvim --headless --clean -l shared/nvim_lua/tests/test_bridge.lua : desk.bridge, the messages other programs send this
-- editor, checked in process (desk-work's own tests send them over a socket).
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
-- Neovim looks in the runtime path (the installed copy under ~/.config/nvim) before package.path: load the repo's.
table.insert(package.loaders, 2, function(name)
  local file = here .. "../" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
local api, uv = vim.api, vim.uv
local passed, failed = 0, 0
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want)) end
end
local function ok(cond, what) eq(not not cond, true, what) end
local function has(text, part, what) ok(type(text) == "string" and text:find(part, 1, true), what .. " (" .. tostring(text) .. ")") end

-- Disposable checkouts, and no desk-work: nothing here may reach the real work records.
local scratch = vim.fn.tempname()
local repo, other = scratch .. "/repo", scratch .. "/other"
for _, dir in ipairs({ repo .. "/.git", other .. "/.git", scratch .. "/bin" }) do vim.fn.mkdir(dir, "p") end
repo, other = uv.fs_realpath(repo), uv.fs_realpath(other)
vim.env.XDG_STATE_HOME, vim.env.PATH = scratch .. "/state", scratch .. "/bin"
local source = repo .. "/a.cpp"
vim.fn.writefile({ "int a = 1;", "int b = 2;", "int c = 3;" }, source)
vim.fn.writefile({ "elsewhere" }, other .. "/b.cpp")

local B = require("desk.bridge")
local function send(msg) return B.receive(vim.tbl_extend("force", { version = 1 }, msg)) end

-- ─── the envelope and the closed set ─────────────────────────────────────────────────────────────────────────────
eq(B.receive("ping"), { refused = "a message is a table of named fields" }, "a message is a table")
has(B.receive({ type = "ping" }).refused, "version 1", "a message without its version is refused")
has(B.receive({ version = 2, type = "ping" }).refused, "version 1", "another version is refused")
has(send({ type = "edit" }).refused, '"edit"', "a type nobody registered is refused by name")
has(send({ type = "view", root = repo, line = 3 }).refused, '"line"', "a field its type does not list is refused by name")
has(send({ type = "view" }).refused, 'needs "root"', "a field it must have")
has(send({ type = "view", root = "relative/path" }).refused, "absolute path", "a path is absolute")
has(send({ type = "view", root = 7 }).refused, "is text", "a field of the wrong kind")
has(send({ type = "view", root = "/" .. ("x"):rep(5000) }).refused, "limited to 4096", "a field over its cap")
has(send({ type = "ping", deadline = (uv.gettimeofday()) * 1000 - 5 }).refused, "stopped waiting", "a message its sender gave up on")
has(send({ type = "ping", deadline = "soon" }).refused, "milliseconds", "a deadline is a time")
eq(send({ type = "ping", root = vim.NIL }).role, "main", "a null field is an absent one")
ok(send({ type = "ping", deadline = (uv.gettimeofday()) * 1000 + 60000 }).role, "a message in time is answered")

-- A later module adds its own type, with its fields; that registration is the allow-list.
B.register("echo", function(msg) return { said = msg.text, times = msg.times } end,
  { text = B.field("string", 8, true), times = B.field("integer", 3), loud = B.field("boolean") })
eq(send({ type = "echo", text = "hi", times = 2 }), { said = "hi", times = 2 }, "a registered type answers")
has(send({ type = "echo", text = "much too long" }).refused, "limited to 8", "its caps hold")
has(send({ type = "echo", text = "hi", times = 4 }).refused, "up to 3", "a number over its cap")
has(send({ type = "echo", text = "hi", times = 1.5 }).refused, "whole number", "a whole number is whole")
has(send({ type = "echo", text = "hi", loud = "yes" }).refused, "true or false", "a boolean is true or false")
has(send({ type = "echo", text = "a\0b" }).refused, "zero byte", "text has no zero byte")
B.register("broken", function() error("it broke") end)
has(send({ type = "broken" }).refused, "it broke", "a handler that fails is a refusal, not an RPC error")
B.register("silent", function() end)
has(send({ type = "silent" }).refused, "no answer", "a handler that answers nothing is a refusal")

-- ─── ping ─────────────────────────────────────────────────────────────────────────────────────────────────────────
vim.cmd.edit(vim.fn.fnameescape(source))
local pong = send({ type = "ping" })
eq({ pong.role, pong.roots, pong.mode, pong.last_focus }, { "main", { repo }, "n", 0 }, "who this editor is, before setup")
B.setup()
local started = send({ type = "ping" }).last_focus
ok(started > 0, "after setup its start counts as focus until the terminal says")
vim.wait(5)
api.nvim_exec_autocmds("FocusGained", {})
ok(send({ type = "ping" }).last_focus > started and B.state.focused == true, "FocusGained moves the last focus")
api.nvim_exec_autocmds("FocusLost", {})
eq(B.state.focused, false, "FocusLost says it has not")
vim.g.desk_work_view = true
eq(send({ type = "ping" }).role, "viewer", "a work viewer says so")
vim.g.desk_work_view = nil

-- ─── view ─────────────────────────────────────────────────────────────────────────────────────────────────────────
api.nvim_win_set_cursor(0, { 2, 4 })
local ns = api.nvim_create_namespace("test_bridge")
local diagnostics = { { lnum = 2, col = 0, message = "third", severity = vim.diagnostic.severity.WARN } }
for i = 1, 40 do diagnostics[#diagnostics + 1] = { lnum = 0, col = i, message = "first " .. i, severity = vim.diagnostic.severity.ERROR } end
vim.diagnostic.set(ns, 0, diagnostics)
local seen = send({ type = "view", root = repo })
eq({ seen.root, seen.file, seen.cursor, seen.visible.first, seen.modified }, { repo, source, { line = 2, col = 5 }, 1, false },
  "the file in front, the cursor and the lines on screen")
ok(type(seen.changedtick) == "number" and type(seen.at) == "number", "with its changedtick and when")
eq(#seen.diagnostics, 30, "at most 30 diagnostics")
eq(seen.more_diagnostics, 11, "and how many more there are")
eq(seen.diagnostics[1].severity, "error", "errors first")
eq(seen.selection, nil, "no selection outside visual mode")
api.nvim_buf_set_lines(0, 0, 1, false, { "int a = 10;" })
eq(send({ type = "view", root = repo }).modified, true, "an unsaved change shows")
eq(send({ type = "view", root = other }), { refused = "another project" }, "another checkout: nothing about this one")
eq(send({ type = "view", root = scratch .. "/gone" }), { refused = "that checkout is not on disk" }, "a checkout that is gone")
vim.cmd("enew")
eq(send({ type = "view", root = repo }), { refused = "no file in view" }, "a buffer that is no file")

-- ─── open: a work item in a new tab, and the guards ──────────────────────────────────────────────────────────────
vim.cmd("silent! %bwipeout!")
vim.cmd.edit(vim.fn.fnameescape(source))
local hers, her_tab = api.nvim_get_current_buf(), api.nvim_get_current_tabpage()
local notices = {}
vim.notify = function(text) notices[#notices + 1] = text end
local function open(fields) return send(vim.tbl_extend("force", { type = "open", root = repo }, fields)) end
local function tabs() return #api.nvim_list_tabpages() end
local function settled(count) return vim.wait(2000, function() return tabs() == count end, 10) end

has(open({ action = "workspace" }).refused, '"workspace"', "the workspace is an editor of its own")
has(open({ action = "nonsense" }).refused, '"nonsense"', "an item it does not know")
eq(open({ action = "file", id = other .. "/b.cpp" }), { refused = "another project" }, "a file of another checkout")
eq(open({ action = "file", id = "" }), { refused = "another project" }, "a file it does not name")
has(open({ action = "file", id = ("x"):rep(5000) }).refused, "limited to 4096", "an id over its cap")
vim.g.desk_work_view = true
has(open({ action = "log", id = "x" }).refused, "shows one item", "a work viewer opens nothing else")
vim.g.desk_work_view = nil

-- Guard: she is typing there (it has the focus, or has not said; insert or command-line). Refused, with a notice.
local real_mode = api.nvim_get_mode
for _, case in ipairs({ { "i", true }, { "c", nil }, { "R", true }, { "t", nil } }) do
  api.nvim_get_mode = function() return { mode = case[1], blocking = false } end
  B.state.focused = case[2]
  eq(open({ action = "log", id = "x" }), { refused = "typing in this editor" }, "not while typing in mode " .. case[1])
end
api.nvim_get_mode = real_mode
ok(vim.wait(500, function() return #notices > 0 end), "it says so where she types")
has(notices[1], "while you type", "the notice")
eq(tabs(), 1, "nothing opened while she typed")

-- Guard: a review is open. Opening another would close hers.
local R = require("desk.review")
local review = { stand_in = true }
R.current = review
for _, action in ipairs({ "file-diff", "reviews" }) do
  eq(open({ action = action, id = action == "file-diff" and source or "" }), { refused = "a review is open" }, action .. " waits for her review")
end
ok(R.current == review, "her review is still the one open")
R.current = nil

-- Opened: always a new tab, the checkout its folder; her window keeps her file; never a work viewer.
B.state.focused = false
api.nvim_get_mode = function() return { mode = "i", blocking = false } end
eq(open({ action = "compare", id = "0123" }), { opened = true }, "in insert mode, but the focus is elsewhere")
api.nvim_get_mode = real_mode
ok(settled(2), "a new tab")
eq(api.nvim_tabpage_get_win(her_tab) and api.nvim_win_get_buf(api.nvim_tabpage_get_win(her_tab)), hers, "her tab still shows her file")
eq(api.nvim_buf_get_lines(0, 0, 1, false)[1], "Comparison unavailable.", "the item is in the new tab (no desk-work here)")
eq(vim.fn.haslocaldir(-1, 0), 1, "the tab has its own folder")
eq(uv.fs_realpath(vim.fn.getcwd(-1, 0)), repo, "the checkout")
eq(vim.g.desk_work_view, nil, "her editor is never made a work viewer (its close would quit everything)")
local unnamed = vim.tbl_filter(function(b) return vim.bo[b].buflisted and api.nvim_buf_get_name(b) == "" end, api.nvim_list_bufs())
eq(unnamed, {}, "the tab's first buffer did not stay behind")
-- An item that makes its own tab: the empty one goes.
eq(open({ action = "health" }), { opened = true }, "health")
ok(settled(3), "one tab more, not two")
ok(api.nvim_buf_get_name(0):find("Work health", 1, true), "the health page is in front")
-- A file of the checkout.
eq(open({ action = "file", id = repo .. "/a.cpp" }), { opened = true }, "a file")
ok(settled(4), "in a tab of its own")
eq(api.nvim_buf_get_name(0), source, "the file")
eq(api.nvim_win_get_buf(api.nvim_tabpage_get_win(her_tab)), hers, "her window is as she left it")

-- The argv path is still a work viewer: the item takes the window it starts in, and closing it closes Neovim.
local real_argv = vim.fn.argv
vim.fn.argv = function() return { "desk-work:compare", "0123", "" } end
require("desk.work").open_args()
vim.fn.argv = real_argv
eq({ tabs(), vim.g.desk_work_view }, { 4, true }, "open_args: no new tab, and a viewer")
vim.g.desk_work_view = nil

print(("bridge: %d passed, %d failed"):format(passed, failed))
vim.fn.delete(scratch, "rf")
os.exit(failed == 0 and 0 or 1)
