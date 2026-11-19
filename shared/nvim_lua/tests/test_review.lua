-- nvim --headless --clean -l shared/nvim_lua/tests/test_review.lua : desk.review's calls and callers. What a change
-- calls, compared per function, and who calls what it changed (a language server attached to the working file, else
-- the project map), read in the background without holding the editor up; and its list as the pop-out draws it. A git
-- repository of its own; the language server and the project map are fakes. It seals itself (its runner does too):
-- private state, cache, runtime and tmux folders, PATH holding git only, and no tmux, Neovim, Hyprland, display or
-- D-Bus address of the session that started it.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
-- Neovim looks in the runtime path (the installed copy under ~/.config/nvim) before package.path: load the repo's.
table.insert(package.loaders, 2, function(name)
  local file = here .. "../" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
local uv, api = vim.uv, vim.api
local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox .. "/bin", "p", tonumber("700", 8))
for _, name in ipairs({ "TMUX", "TMUX_PANE", "NVIM", "NVIM_LISTEN_ADDRESS", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY",
  "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "KITTY_LISTEN_ON", "KITTY_WINDOW_ID", "SWAYSOCK", "GIT_DIR", "GIT_WORK_TREE" }) do
  vim.env[name] = nil
end
for name, folder in pairs({ XDG_STATE_HOME = "state", XDG_CACHE_HOME = "cache", XDG_RUNTIME_DIR = "run", TMUX_TMPDIR = "tmux" }) do
  vim.env[name] = sandbox .. "/" .. folder
  vim.fn.mkdir(vim.env[name], "p", tonumber("700", 8))
end
local git_path = vim.fn.exepath("git")
assert(git_path ~= "", "test_review needs git")
uv.fs_symlink(git_path, sandbox .. "/bin/git")
vim.env.PATH = sandbox .. "/bin"
vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = "/dev/null", "1"
vim.g.mapleader = " "
vim.g.desk_style = "paper"

local passed, failed = 0, 0
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want)) end
end
local function ok(cond, what) eq(not not cond, true, what) end
local said = {}
vim.notify = function(text) said[#said + 1] = tostring(text) end

local R = require("desk.review")
local C = require("desk.claude")
local G = require("desk.callgraph")
local Map = require("desk.map")
eq(R.work_tool(), nil, "no desk-work on this PATH: the review keeps nothing outside the sandbox")

-- ─── a repository ──────────────────────────────────────────────────────────────────────────────────────────────
local root = sandbox .. "/project"
vim.fn.mkdir(root, "p")
local function git(...)
  local ran = vim.system({ "git", "-c", "user.name=Review Test", "-c", "user.email=review@example.invalid", "-c", "commit.gpgsign=false",
    "-c", "core.hooksPath=/dev/null", ... }, { cwd = root, text = true }):wait()
  assert(ran.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. (ran.stderr or ""))
  return vim.trim(ran.stdout or "")
end
local function write(rel, text)
  local f = assert(io.open(root .. "/" .. rel, "wb"))
  f:write(text)
  f:close()
end
git("init", "-q")
write("seed.txt", "seed\n")
git("add", ".")
git("commit", "-qm", "seed")
-- A commit that changes these files ({ rel = { before, after } }), as a review row.
local function commit(files)
  for rel, pair in pairs(files) do write(rel, pair[1]) end
  git("add", "-A")
  git("commit", "-qm", "before")
  local parent = git("rev-parse", "HEAD")
  for rel, pair in pairs(files) do write(rel, pair[2]) end
  git("add", "-A")
  git("commit", "-qm", "after")
  local sha = git("rev-parse", "HEAD")
  return { kind = "commit", sha = sha, parent = parent, short = sha:sub(1, 7), subject = "after", label = "test" }
end

-- The list's rows and their strips, as the pop-out's view draws them (wide enough to read each whole).
local function strips()
  local out = {}
  for _, item in ipairs(R.view_kind.render({ review = R.current }, 160).items) do out[item.name] = table.concat(item.strip, "\n") end
  return out
end
local function strip_of(name) return strips()[name] or ("no row called " .. name) end
local function row_of(want)
  local r = R.current
  for line, e in pairs(r.entries or {}) do
    local f = e.file and (e.set and e.set.files or r.files)[e.file]
    if f and want(f, e) then return line end
  end
end
local function file_row(rel) return row_of(function(f, e) return f.rel == rel and not e.symbol end) end
local function text_of(line) return line and api.nvim_buf_get_lines(R.current.panel_buf, line - 1, line, false)[1] or "" end
local function file_of(rel) for _, f in ipairs(R.current.files) do if f.rel == rel then return f end end end
-- Enter on a file's row in the list: the file opens, its changed functions under it.
local function enter(rel)
  api.nvim_set_current_win(R.current.panel_win)
  api.nvim_win_set_cursor(R.current.panel_win, { file_row(rel), 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
end

-- M.structure of a file outside a review: the calls each changed function adds (+) and removes (-), by name.
local function structure(rel, before, after)
  local diff = vim.text and vim.text.diff or vim.diff
  local file = { rel = rel, left = before, right = after, loaded = true, signature = vim.fn.sha256(before .. "\0" .. after),
    hunks = diff(before, after, { result_type = "indices", algorithm = "histogram", linematch = 60 }) }
  return R.structure(file)
end
local function calls(s, name)
  local c = s.calls[name]
  if not c then return "no row " .. name end
  local parts = {}
  for _, n in ipairs(c.added) do parts[#parts + 1] = "+" .. n end
  for _, n in ipairs(c.removed) do parts[#parts + 1] = "-" .. n end
  return #parts > 0 and table.concat(parts, " ") or "same"
end

-- ─── one function compared with itself, never another of the same name ─────────────────────────────────────────
-- Anonymous functions are named by their first line ("function()"); same-named methods, C's #ifdef twins and overloads
-- share a name too. Each changed one is found where the change is, and compared with itself in the other copy.
local TWO = "local M = {}\nM.x = function()\n  foo()\nend\nM.y = function()\n  bar()\nend\nreturn M\n"
eq(calls(structure("two.lua", TWO, (TWO:gsub("  foo%(%)\n", "  foo()\n  baz()\n"))), "function()"), "+baz",
  "two closures alike, the first gains a call: that closure's calls are compared")
eq(calls(structure("two.lua", TWO, (TWO:gsub("return M\n$", "M.z = function()\n  qux()\nend\nreturn M\n"))), "function()"), "+qux",
  "a closure added after others alike: only its own call is new, nothing of the others is removed")
local TWINS = "#ifdef A\nvoid f(void) { a(); }\n#else\nvoid f(void) { b(); }\n#endif\n"
eq(calls(structure("twins.c", TWINS, (TWINS:gsub("a%(%);", "a(); d();"))), "f"), "+d",
  "C: f under #ifdef and again under #else; the first gains d(): its own calls are compared")
local SAME = "local M = {}\nfunction M.alpha()\n  local x = 1\n  return old(x)\nend\nreturn M\n"
eq(calls(structure("same.lua", SAME, (SAME:gsub("  local x = 1\n", "  local x = 1\n  print(x)\n"))), "M.alpha"), "+print",
  "a line added inside a function: it is compared with itself in the copy before (found through the lines left alone)")
local NESTED = "local function outer()\n  local function save(item)\n    return write(item)\n  end\n  return save\nend\nreturn outer\n"
eq(calls(structure("nested.lua", NESTED, (NESTED:gsub("save%(item%)\n", "save(item, now)\n    check(item)\n"))), "save"), "+check",
  "an indented function whose first line the change rewrote: still compared with itself")

-- Same name, different parameters (#if branches, C++ overloads): a row each, named by its parameters, each with its
-- own calls; a function whose parameters the change edits stays one row.
local SENDS = "#if A\nvoid send(int order) { a(); }\n#else\nvoid send(long cancel) { b(); }\n#endif\n"
local sends = { rel = "sends.c", left = SENDS, right = (SENDS:gsub("a%(%);", "a(); d();"):gsub("b%(%);", "b(); e();")), loaded = true }
sends.signature = vim.fn.sha256(sends.left .. "\0" .. sends.right)
sends.hunks = (vim.text and vim.text.diff or vim.diff)(sends.left, sends.right, { result_type = "indices", algorithm = "histogram", linematch = 60 })
eq(vim.tbl_map(function(s) return s.name end, R.changed_symbols(sends)), { "send(int order)", "send(long cancel)" },
  "two changed send()s with different parameters: two rows, each named by what it takes")
local sent = R.structure(sends)
eq({ calls(sent, "send(int order)"), calls(sent, "send(long cancel)") }, { "+d", "+e" }, "… each compared with itself: its own calls")
eq(vim.tbl_map(function(s) return s.name end, R.changed_symbols({ rel = "one.c", left = "void f(int a) { x(); }\n", right = "void f(int a, int b) { x(); }\n",
  loaded = true, signature = "one", hunks = { { 1, 1, 1, 1 } } })), { "f" }, "a function whose parameters the change edits: one row, by its name alone")

-- The language server is asked about the function the row names: at the first of two closures alike, when that is the
-- one the change is in.
local asked, cancels = {}, 0
local fake = { id = 91, name = "fakels", offset_encoding = "utf-16" }
local serving = {}   -- buffers the fake server is attached to
G.clients = function(buf) return serving[buf] and { fake } or {} end
G.busy = function() return false end
local function at(line) return { start = { line = line, character = 0 }, ["end"] = { line = line, character = 1 } } end
local answer_ms = 5   -- how long the fake server takes to answer each request
G.transport = function(_, buf, method, params, handler)
  asked[#asked + 1] = { method = method, line = params.position and params.position.line }
  local uri = vim.uri_from_bufnr(buf)
  vim.defer_fn(function()
    if method == "textDocument/prepareCallHierarchy" then
      handler(nil, { { name = "f", kind = 12, uri = uri, range = at(params.position.line), selectionRange = at(params.position.line) } })
    elseif method == "callHierarchy/incomingCalls" then
      handler(nil, { { from = { name = "one", kind = 12, uri = uri, range = at(0), selectionRange = at(0) }, fromRanges = {} },
                     { from = { name = "two", kind = 12, uri = uri, range = at(0), selectionRange = at(0) }, fromRanges = {} } })
    else handler(nil, {}) end
  end, answer_ms)
  return function() cancels = cancels + 1 end
end
local function prepared()
  local n = 0
  for _, a in ipairs(asked) do if a.method == "textDocument/prepareCallHierarchy" then n = n + 1 end end
  return n
end
-- The lines (0-based) the server was asked about, each once.
local function asked_lines()
  local out, seen = {}, {}
  for _, a in ipairs(asked) do
    if a.method == "textDocument/prepareCallHierarchy" and not seen[a.line] then seen[a.line] = true; out[#out + 1] = a.line end
  end
  return out
end
local closures = commit({ ["closures.lua"] = { TWO, (TWO:gsub("  foo%(%)\n", "  foo()\n  baz()\n")) } })
vim.cmd.edit(root .. "/closures.lua")
local working = api.nvim_get_current_buf()
serving[working] = true
C.open_review(closures, root)
enter("closures.lua")
ok(vim.wait(3000, function() return strip_of("function()"):find("2 callers", 1, true) ~= nil end),
  "a closure's callers, from the language server on the working file:\n" .. strip_of("function()"))
eq(asked_lines(), { 1 }, "… asked about the first closure (line 2, where the change is), never the second")

-- ─── typing in the working file asks the server once, when she pauses ──────────────────────────────────────────
-- An answer is stamped with the buffer's version; while she typed, each one came back stale, the redraw it caused asked
-- again, and so on for as long as she typed. A buffer that moved on is asked again once it has been still a moment,
-- and the strip keeps the last answer meanwhile.
R.REACH_SETTLE_MS, answer_ms = 400, 50   -- a server's three round trips take longer than a keystroke
local before_typing = prepared()
api.nvim_buf_set_lines(working, 0, 0, false, { "-- typing" })
strips()   -- a redraw while she types (an answer for another function, a work event)
for i = 1, 30 do
  api.nvim_buf_set_lines(working, 0, 0, false, { "-- typing " .. i })
  vim.wait(40)
end
local during = prepared() - before_typing
ok(during <= 1, "typing in the working file: the server is not asked again while she types (" .. during .. " requests)")
ok(strip_of("function()"):find("2 callers", 1, true), "… the strip keeps the last answer meanwhile:\n" .. strip_of("function()"))
ok(vim.wait(3000, function() return prepared() > before_typing + during end), "once she stops, it is asked again")
vim.wait(800)
eq(prepared() - before_typing - during, 1, "… once")
eq(cancels, 0, "an answered request is never cancelled (only one still out when its time is up)")
C.close()

-- ─── reading a large file's calls never holds the editor up ────────────────────────────────────────────────────
-- Both copies were parsed on the main loop in one go (a string's parse runs to its end: about a second at 500 KiB).
-- They are parsed in buffers now, a few milliseconds at a time.
local big = {}
for i = 1, 3600 do big[#big + 1] = ("local function f%d(a, b)\n  local x = helper(a) + other.call(b, %d)\n  return x\nend\n"):format(i, i) end
local big_before = table.concat(big)
local big_after = big_before:gsub("  local x = helper%(a%) %+ other%.call%(b, 1%)\n", "  local x = fresh(a) + other.call(b, 1)\n", 1)
local big_row = commit({ ["big.lua"] = { big_before, big_after } })
-- Every callback the main loop runs from the review's opening on is timed (the review's own steps and treesitter's;
-- the review's git reads wait on the loop, so its first steps can run while it opens).
local real_schedule, real_defer, longest = vim.schedule, vim.defer_fn, 0
local function timed(fn)
  return function(...)
    local started = uv.hrtime()
    fn(...)
    longest = math.max(longest, uv.hrtime() - started)
  end
end
vim.schedule = function(fn) return real_schedule(timed(fn)) end
vim.defer_fn = function(fn, ms) return real_defer(timed(fn), ms) end
C.open_review(big_row, root)
local bf = file_of("big.lua")
local read_big = vim.wait(15000, function() return bf.structure ~= nil and bf.structure.signature == bf.signature end)
vim.schedule, vim.defer_fn = real_schedule, real_defer
ok(#bf.right > 256 * 1024 and #bf.right <= R.STRUCTURE_MAX, "a large file, under the size its calls are read up to")
ok(read_big, "its calls are read in the background")
eq(read_big and calls(bf.structure, "f1"), "+fresh -helper", "… rightly")
ok(longest < 150e6, ("… and no step of the read held the editor up for more than 150 ms (the longest: %.0f ms)"):format(longest / 1e6))
C.close()

-- ─── callers asked for every changed function, not only the first 24 ───────────────────────────────────────────
-- A drawing asks for at most 24 functions; it counted those already answered too, so the 25th onwards was never
-- asked and read "callers…" for good.
Map.desk_work = function(_, done) vim.schedule(function() done({ ok = true, q = "callers", nodes = { { depth = 0 } } }) end) end
local many_before, many_after = {}, {}
for i = 1, 30 do
  many_before[#many_before + 1] = ("local function f%d()\n  return %d\nend\n"):format(i, i)
  many_after[#many_after + 1] = ("local function f%d()\n  return %d\nend\n"):format(i, i + 100)
end
C.open_review(commit({ ["many.lua"] = { table.concat(many_before), table.concat(many_after) } }), root)
enter("many.lua")
local function waiting()
  local out = {}
  for name, text in pairs(strips()) do if text:find("callers…", 1, true) then out[#out + 1] = name end end
  table.sort(out)
  return out
end
ok(vim.wait(5000, function() return #waiting() == 0 end), "every one of 30 changed functions gets its callers asked")
eq(waiting(), {}, "… none is left reading callers…")
C.close()

-- ─── the project map's answer by name counts only this file's function ─────────────────────────────────────────
-- Without a language server the map is asked by the function's id, then by its bare name; by name it may know only
-- another file's function of that name, whose callers are not this one's.
local froms = {}
Map.desk_work = function(args, done)
  local from = args[#args - 2]
  froms[#froms + 1] = from
  vim.schedule(function()
    if from == "solo.lua::parse" then done({ ok = false, message = "Nothing in the map is named solo.lua::parse", candidates = {} })
    elseif from == "parse" then
      done({ ok = true, q = "callers", from = { id = "elsewhere.lua::parse", file = "elsewhere.lua", label = "parse" },
        nodes = { { depth = 0 }, { depth = 1 }, { depth = 1 }, { depth = 1 } } })
    else done({ ok = true, q = "callers", nodes = { { depth = 0 } } }) end
  end)
end
C.open_review(commit({ ["solo.lua"] = { "return 1\n", "local function parse()\n  return 1\nend\nreturn parse\n" } }), root)
enter("solo.lua")
ok(vim.wait(3000, function() return not strip_of("parse"):find("callers…", 1, true) end), "the map answered:\n" .. strip_of("parse"))
eq(froms, { "solo.lua::parse", "parse" }, "asked by its id, then by its bare name")
ok(strip_of("parse"):find("callers: not in the project map", 1, true),
  "the map's only parse is another file's, so these are not this one's callers:\n" .. strip_of("parse"))
C.close()

-- ─── staged apart from unstaged (Codex's C26): which calls the next commit adds, and what stays here ────────────
do
  write("sa.lua", "local function f()\n  return base()\nend\nreturn f\n")
  git("add", "sa.lua")
  git("commit", "-qm", "staged base")
  write("sa.lua", "local function f()\n  staged_call()\n  return base()\nend\nreturn f\n")
  git("add", "sa.lua")
  write("sa.lua", "local function f()\n  staged_call()\n  loose_call()\n  return base()\nend\nreturn f\n")
  write("loose.lua", "return 1\n")
  local function rels(list) return vim.tbl_map(function(f) return f.rel end, list or {}) end
  eq({ rels(R.staged_files(root)), vim.tbl_contains(rels(R.unstaged_files(root)), "sa.lua"), vim.tbl_contains(rels(R.unstaged_files(root)), "loose.lua") },
    { { "sa.lua" }, true, true }, "staged: sa.lua; not staged: sa.lua's rest and the untracked loose.lua")
  local kinds = vim.tbl_map(function(row) return row.kind end, C.rows(root))
  ok(vim.tbl_contains(kinds, "staged") and vim.tbl_contains(kinds, "unstaged"), "the changes list offers both halves when both have something: " .. table.concat(kinds, " "))
  local function calls_of(kind)
    C.open_review({ kind = kind, sid = kind, short = kind }, root)
    local f = file_of("sa.lua")
    for i, x in ipairs(R.current.files) do if x == f then R.select(i) end end
    vim.wait(3000, function() return f.structure ~= nil and f.structure.signature == f.signature end)
    local got = f.structure and f.structure.calls and f.structure.calls.f
    C.close()
    return got and got.added
  end
  eq(calls_of("staged"), { "staged_call" }, "staged: the call the next commit adds, and not the one left out of it")
  eq(calls_of("unstaged"), { "loose_call" }, "not staged: the call that stays on this machine")
  git("reset", "-q", "sa.lua")
  git("checkout", "--", "sa.lua")
  os.remove(root .. "/loose.lua")
end

-- ─── a review of the working changes: files edited in the background ───────────────────────────────────────────
vim.cmd("bwipeout! " .. working)   -- the typing test's draft: a review of the working changes lists unsaved drafts too
write("wa.lua", "local function one()\n  return 1\nend\nreturn one\n")
write("wb.lua", "local function two()\n  return 2\nend\nreturn two\n")
git("add", "-A")
git("commit", "-qm", "working base")
write("wa.lua", "local function one()\n  return helper(1)\nend\nreturn one\n")
write("wb.lua", "local function two()\n  return 3\nend\nreturn two\n")
C.open_review({ kind = "working", short = "working changes" }, root)
local wr = R.current
eq(vim.tbl_map(function(f) return f.rel end, wr.files), { "wa.lua", "wb.lua" }, "a review of the working changes, wa.lua shown")
ok(vim.wait(3000, function() local b = file_of("wb.lua"); return b.structure ~= nil and b.structure.signature == b.signature end),
  "their calls are read")

-- wb.lua (not the file shown) gains a function that calls something new; the refresh reads its calls again.
write("wb.lua", "local function two()\n  return 3\nend\nlocal function three()\n  return extra()\nend\nreturn two\n")
R.refresh_live()
ok(vim.wait(3000, function() return text_of(file_row("wb.lua")):find("→", 1, true) ~= nil end),
  "a file changed in the background: its calls are read again, its row marked →: " .. text_of(file_row("wb.lua")))
ok(strip_of("wb.lua"):find("→ calls changed in three", 1, true), "… and its strip says where:\n" .. strip_of("wb.lua"))

-- The list in the pop-out; the file shown changes on disk. The refresh draws the list again and leaves the pop-out's
-- selection on the row she put it on: moved to the file shown, her next m would check that one.
for i, f in ipairs(wr.files) do if f.rel == "wa.lua" then R.select(i) end end
eq(wr.files[wr.index].rel, "wa.lua", "wa.lua is the file shown")
local P = require("desk.popout")
local pv = { id = "review", kind = "review", gen = 0, pinned = false }
P.host.views, P.host.order = { review = pv }, { "review" }
R.view_kind.open(pv)
ok(wr.popout == pv, "the list is out in the pop-out (no pop-out is connected: nothing is sent)")
pv.select = nil
write("wa.lua", "local function one()\n  return helper(2)\nend\nreturn one\n")
R.refresh_live()
eq({ file_of("wa.lua").right:find("helper(2)", 1, true) ~= nil, pv.select }, { true, nil },
  "the file shown changed and was read again; the pop-out's selection is where she put it")
C.close()
P.host.views, P.host.order = {}, {}

-- ─── the list in the pop-out keeps its drawing while only a strip changes ──────────────────────────────────────
-- The pop-out names a key's row by the drawing's generation, which moves on when the drawing's lines change: a key
-- pressed as a caller answer redrew the strip box was refused "this view moved on". The box's two lines in the drawing
-- are a stand-in the pop-out writes the selected row's own strip over.
local shown = commit({ ["shown.lua"] = { "local M = {}\nfunction M.go()\n  return old()\nend\nreturn M\n",
  "local M = {}\nfunction M.go()\n  return new()\nend\nreturn M\n" } })
C.open_review(shown, root)
enter("shown.lua")
local sf = file_of("shown.lua")
for _, s in ipairs(R.changed_symbols(sf)) do if s.name == "M.go" then R.jump(s) end end
eq(R.current.symbol and R.current.symbol.name, "M.go", "the comparison shows the function: its row is the one shown")
local listed = { review = R.current }
R.reach_known[sf.path .. "\0M.go"] = { said = "1 caller", source = "map", at = os.time() }
local first = R.view_kind.render(listed, 120)
R.reach_known[sf.path .. "\0M.go"] = { said = "7 callers", source = "map", at = os.time() }
local second = R.view_kind.render(listed, 120)
eq(second.lines, first.lines, "a caller answer for the row shown leaves the drawing's lines as they were (its generation stays)")
local go_strip
for _, item in ipairs(second.items) do if item.name == "M.go" then go_strip = table.concat(item.strip, "\n") end end
ok(go_strip and go_strip:find("M.go · 7 callers", 1, true), "… and the row's own strip, the one the pop-out draws, has the answer:\n" .. tostring(go_strip))
C.close()

pcall(vim.fn.serverstop, vim.v.servername)
vim.fn.delete(sandbox, "rf")
print(string.format("test_review: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
