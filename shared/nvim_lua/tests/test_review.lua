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

-- ─── a repository ───────────────────────────────────────────────────────────────────────────────────────────────
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

-- ─── one function compared with itself, never another of the same name ───────────────────────────────────────────
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

-- The language server is asked about the function the row names: at the first of two closures alike, when that is the
-- one the change is in.
local asked, cancels = {}, 0
local fake = { id = 91, name = "fakels", offset_encoding = "utf-16" }
local serving = {}   -- buffers the fake server is attached to
G.clients = function(buf) return serving[buf] and { fake } or {} end
G.busy = function() return false end
local function at(line) return { start = { line = line, character = 0 }, ["end"] = { line = line, character = 1 } } end
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
  end, 5)
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
C.close()

pcall(vim.fn.serverstop, vim.v.servername)
vim.fn.delete(sandbox, "rf")
print(string.format("test_review: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
