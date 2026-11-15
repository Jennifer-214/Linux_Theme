-- nvim --headless --clean -l shared/nvim_lua/tests/test_planmarks.lua : the plan's references, found and marked.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
-- Neovim looks in the runtime path (the installed copy under ~/.config/nvim) before package.path: load the repo's.
table.insert(package.loaders, 2, function(name)
  local file = here .. "../" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
local P = require("desk.planmarks")
local passed, failed = 0, 0
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want)) end
end
local function pick(refs, key) local out = {} for _, r in ipairs(refs) do out[#out + 1] = r[key] or false end return out end

-- Reading a plan: steps, line ranges, a function beside its own file, and words that only look like files.
local refs = P.parse(table.concat({
  "# Plan: tidy the drawer",
  "## Notes",
  "See e.g. the drawer, and v1.2 of it.",
  "1. Fix `src/drawer.cpp:12` and `shell.qml`, then `menu.lua` open_menu() there",
  "2. `lib/util.lua:3-9` and ~/.config/foxml/x.conf",
  "```",
  "ignored.cpp:4",
  "```",
  "- [ ] 3. `docs/gone.md`",
}, "\n"))
eq(pick(refs, "path"), { "src/drawer.cpp", "shell.qml", "menu.lua", "lib/util.lua", "~/.config/foxml/x.conf", "docs/gone.md" },
   "references, without e.g., v1.2 or anything in a code fence")
eq(pick(refs, "step"), { "step 1", "step 1", "step 1", "step 2", "step 2", "step 3" }, "each under its numbered step")
eq(pick(refs, "symbol"), { false, false, "open_menu", false, false, false }, "a function belongs to the file just before it")
eq({ refs[4].line, refs[4].last }, { 3, 9 }, "a line range")
eq(pick(refs, "clear"), { true, false, false, true, true, true }, "only a folder or a line makes a reference clear")
eq(P.parse("## Drawer heading\nsee `a/b.cpp`")[1].step, "Drawer heading", "without numbers, the heading is the step")

-- Finding them in a small repo.
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p"); vim.fn.mkdir(root .. "/lib", "p")
local function write(path, text) local f = io.open(root .. "/" .. path, "w"); f:write(text); f:close() end
write("src/drawer.cpp", ("// line\n"):rep(20))
write("lib/menu.lua", "local M = {}\nlocal x = open_menu()\nfunction M.open_menu(a)\n  return a\nend\nreturn M\n")
write("lib/util.lua", "return 1\n")
vim.fn.system({ "git", "-C", root, "init", "-q" }); vim.fn.system({ "git", "-C", root, "add", "." })
eq(P.resolve(root, "menu.lua"), root .. "/lib/menu.lua", "a bare name finds its one tracked file")
eq(P.resolve(root, "nowhere.lua"), nil, "and nothing when there is none")
local marks = P.build(root, { text = "1. `src/drawer.cpp:12`\n2. `menu.lua` open_menu()\n3. `lib/util.lua:40`\n4. `docs/gone.md`\n5. `missing.lua`\n" })
local seen = {}
for _, m in ipairs(marks) do seen[#seen + 1] = { m.path, m.line, m.drifted and m.why or "ok" } end
eq(seen, {
  { "src/drawer.cpp", 12, "ok" },
  { "menu.lua", 3, "ok" },
  { "lib/util.lua", 40, "line 40 is past the end (2 lines)" },
  { "docs/gone.md", 1, "no such file" },
}, "a function's definition, not its call; drifted ones say why; a bare missing name is left out")

-- A resolver from elsewhere (symdeps) wins over the plain search.
vim.g.foxml_plan_symbol_resolver = function(_, name) return name == "open_menu" and 5 or nil end
eq(P.build(root, { text = "`lib/menu.lua` open_menu()" })[1].line, 5, "the resolver is asked first")
vim.g.foxml_plan_symbol_resolver = nil

-- Marked in a buffer: one sign with its step on the named line.
P.plan, P.marks = { title = "Plan: tidy the drawer" }, marks
vim.cmd("edit " .. root .. "/src/drawer.cpp")
P.paint(0)
local ext = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces().foxml_plan_marks, 0, -1, { details = true })
eq(#ext, 1, "one mark in this file")
eq(ext[1][2], 11, "on line 12")
eq(ext[1][4].virt_text[1][1], "  step 1 · tidy the drawer", "the step and the plan's short title")
P.enabled = false; P.paint(0)
eq(#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces().foxml_plan_marks, 0, -1, {}), 0, "hidden when turned off")

-- The half-minute refresh never waits on a command, and re-reads only what changed since the last one.
do
  P.enabled, P.plan, P.marks = true, nil, {}
  write("plan.md", "# Plan: tidy the drawer\n1. `src/drawer.cpp:12`\n2. `menu.lua` open_menu()\n")
  local reads, waits = {}, 0
  local real_open, real_system, real_fn_system, real_systemlist = io.open, vim.system, vim.fn.system, vim.fn.systemlist
  local real_executable = vim.fn.executable
  io.open = function(path, ...) reads[#reads + 1] = path; return real_open(path, ...) end
  vim.fn.system = function(...) waits = waits + 1; return real_fn_system(...) end
  vim.fn.systemlist = function(...) waits = waits + 1; return real_systemlist(...) end
  local pin
  vim.system = function(argv, opts, cb)
    if argv[1] == "desk-work" then
      vim.defer_fn(function() cb({ code = 0, stdout = vim.json.encode(pin) }) end, 10)
      return { wait = function() waits = waits + 1; return { code = 0, stdout = vim.json.encode(pin) } end, kill = function() end }
    end
    local job = real_system(argv, opts, cb)
    return setmetatable({ wait = function(_, t) waits = waits + 1; return job:wait(t) end }, { __index = job })
  end
  local function refresh()
    reads = {}
    local finished = false
    P.refresh(function() finished = true end)
    return vim.wait(5000, function() return finished end)
  end
  local function marked()
    local ext = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces().foxml_plan_marks, 0, -1, {})
    return #ext == 1 and ext[1][2] + 1 or #ext
  end

  P.chosen = root .. "/plan.md"
  eq(refresh(), true, "a refresh finishes")
  eq(P.plan and P.plan.title, "Plan: tidy the drawer", "the chosen plan")
  eq(#P.marks, 2, "its marks")
  eq(marked(), 12, "the open file is marked")
  eq(refresh(), true, "a second refresh finishes")
  eq(reads, {}, "an unchanged plan reads no file again")
  eq(marked(), 12, "and the mark stays")
  vim.uv.fs_utime(root .. "/src/drawer.cpp", 1, 1)
  refresh()
  eq(reads, { root .. "/plan.md", root .. "/src/drawer.cpp" }, "a changed file is read again, the others are not")

  -- A pin from a live session (desk-work plan), read in the background.
  write("plan2.md", "# Plan: second\n1. `lib/util.lua:1`\n")
  P.chosen = nil
  pin = { file = root .. "/plan2.md", at = 5 }
  local real_claude = package.loaded["desk.claude"]
  package.loaded["desk.claude"] = { live = {}, decode = function(t) return vim.json.decode(t) end,
                                    in_repo = function() return { { id = "s1", ledger = {} } } end }
  vim.fn.executable = function(name) return name == "desk-work" and 1 or real_executable(name) end
  eq(refresh(), true, "a refresh with a live session finishes")
  eq(P.plan and P.plan.file, root .. "/plan2.md", "the pinned plan")
  eq(P.marks[1] and P.marks[1].path, "lib/util.lua", "its mark")
  eq(marked(), 0, "the open file is not in it")
  refresh()
  eq(reads, {}, "the same pin again reads no file")
  eq(waits, 0, "nothing waited on a command")

  io.open, vim.system, vim.fn.system, vim.fn.systemlist = real_open, real_system, real_fn_system, real_systemlist
  vim.fn.executable, package.loaded["desk.claude"] = real_executable, real_claude
end

vim.fn.delete(root, "rf")
print(("planmarks: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
