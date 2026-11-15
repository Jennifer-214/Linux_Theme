-- nvim --headless --clean -l shared/nvim_lua/tests/test_debug.lua : desk.debug finds the program and gdb stops where asked.
-- The program finder runs on a scratch project of its own. tests/test_nvim_debug.py adds a real session when it could
-- build a program somewhere it may run and nvim-dap is installed: DEBUG_TEST_DAP, DEBUG_TEST_PROGRAM, DEBUG_TEST_SOURCE.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
table.insert(package.loaders, 2, function(name)
  local file = here .. "../" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
local passed, failed = 0, 0
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want)) end
end

local D = require("desk.debug")
local scratch = vim.fn.tempname()
local root = scratch .. "/project"
D.state_path = scratch .. "/state/desk-debug.json"
-- The finder reads only the mode bits and the first four bytes, so a fake ELF stands in for a program.
local function put(rel, body, mode, mtime)
  local path = root .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "wb")); fd:write(body); fd:close()
  vim.uv.fs_chmod(path, mode)
  if mtime then vim.uv.fs_utime(path, mtime, mtime) end
end
local elf = "\127ELF" .. string.rep("\0", 60)
put("build/app", elf, 493)                                   -- 493 = 0755
put("build/sub/older", elf, 493, 1000000000)
put("build/libthing.so", elf, 493)
put("build/CMakeFiles/compiler-id", elf, 493)
put("build/run.sh", "#!/bin/sh\n", 493)
put("build/data.bin", elf, 420)                              -- 420 = 0644: not executable

-- Finding the program: ELF executables in the build folders, newest first; not libraries, scripts or CMake's own.
eq(D.candidates(root), { "build/app", "build/sub/older" }, "executables, newest first, without .so, scripts or CMakeFiles")
eq(D.choices(root), { "build/app", "build/sub/older", "another path…" }, "nothing remembered yet")
D.remember(root, "build/sub/older")
eq(D.last(root), "build/sub/older", "the last program is remembered")
eq(D.choices(root), { "build/sub/older", "build/app", "another path…" }, "the remembered one is offered first")

-- What is installed decides the adapters; gdb gets the launch first.
local fake = { adapters = {}, configurations = {} }
local count = D.configure(fake)
eq(fake.configurations.c == fake.configurations.cpp, true, "C and C++ share the launches")
if vim.fn.executable("gdb") == 1 then
  eq(fake.adapters.gdb and fake.adapters.gdb.args[1], "--interpreter=dap", "gdb speaks DAP itself")
  eq(fake.configurations.cpp[1].type, "gdb", "gdb is offered first")
end
eq(count, #fake.configurations.cpp, "the count is the launches set up")

-- A real session: a breakpoint on a line, the program run under gdb, and the stop on that line.
if vim.env.DEBUG_TEST_PROGRAM and vim.env.DEBUG_TEST_DAP then
  vim.opt.runtimepath:append(vim.env.DEBUG_TEST_DAP)
  local dap = require("dap")
  D.configure(dap)
  vim.cmd.edit(vim.env.DEBUG_TEST_SOURCE)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  dap.toggle_breakpoint()
  local stopped
  dap.listeners.after.event_stopped["test"] = function(session, body)
    vim.defer_fn(function()
      local frame = session.current_frame
      stopped = { reason = body.reason, line = frame and frame.line }
    end, 200)
  end
  dap.run({ type = "gdb", request = "launch", name = "test", program = vim.env.DEBUG_TEST_PROGRAM,
            cwd = vim.fs.dirname(vim.env.DEBUG_TEST_PROGRAM), stopAtBeginningOfMainSubprogram = false })
  vim.wait(20000, function() return stopped ~= nil and stopped.line ~= nil end, 50)
  eq(stopped, { reason = "breakpoint", line = 4 }, "gdb stops at the breakpoint on line 4")
  dap.terminate()
  vim.wait(5000, function() return dap.session() == nil end, 50)
  print("debug session: ran")
else
  print("debug session: skipped (" .. (vim.env.DEBUG_TEST_DAP and "no compiler or gdb 14+" or "nvim-dap not installed") .. ")")
end

vim.fn.delete(scratch, "rf")
print(("desk.debug: %d passed, %d failed"):format(passed, failed))
vim.cmd(failed == 0 and "qa!" or "cq")
