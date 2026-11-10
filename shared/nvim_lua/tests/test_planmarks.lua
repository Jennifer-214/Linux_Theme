-- nvim --headless -u NONE -l shared/nvim_lua/tests/test_planmarks.lua : the plan's references, found and marked.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
local P = require("foxml.planmarks")
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

vim.fn.delete(root, "rf")
print(("planmarks: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
