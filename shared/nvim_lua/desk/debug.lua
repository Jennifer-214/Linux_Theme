-- desk.debug: C and C++ debugging through nvim-dap with the debugger the system already has: gdb (14 and later speak
-- the debug adapter protocol themselves) or lldb-dap. Nothing is downloaded. F5 starts or continues; the first start in
-- a project asks which program, offering the executables its build folders hold, newest first, and remembers the
-- answer. Attaching to a running program is left out: kernel.yama.ptrace_scope = 1 (the security step) allows a
-- debugger only on programs it starts.
local M = {}
local uv = vim.uv or vim.loop

local BUILD_DIRS = { "build", "out", "bin", "cmake-build-debug", "cmake-build-release", "." }
local SKIP = { CMakeFiles = true, [".git"] = true, node_modules = true, _deps = true }

-- The project the current file belongs to, else the working directory.
function M.root(buf)
  local found = vim.fs.root and vim.fs.root(buf or 0, { ".git", "CMakeLists.txt", "Makefile", "meson.build", "compile_commands.json" })
  return found or uv.cwd()
end

local function is_program(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" or bit.band(stat.mode, 73) == 0 then return nil end   -- 73 = 0111, any x bit
  if path:match("%.so[%.%d]*$") or path:match("%.a$") or path:match("%.o$") then return nil end
  local fd = uv.fs_open(path, "r", 0)
  if not fd then return nil end
  local magic = uv.fs_read(fd, 4, 0)
  uv.fs_close(fd)
  return magic == "\127ELF" and stat or nil
end

-- Executables under the build folders (three levels deep; "." only its top level), newest first, relative to root.
function M.candidates(root, limit)
  local found, seen = {}, {}
  local function scan(dir, depth)
    local handle = uv.fs_scandir(dir)
    while handle do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then break end
      local path = dir .. "/" .. name
      if kind == "directory" then
        if depth > 0 and not SKIP[name] and name:sub(1, 1) ~= "." then scan(path, depth - 1) end
      elseif not seen[path] then
        local stat = is_program(path)
        if stat then
          seen[path] = true
          found[#found + 1] = { path = path, mtime = stat.mtime.sec * 1e9 + stat.mtime.nsec }
        end
      end
    end
  end
  for _, dir in ipairs(BUILD_DIRS) do
    local full = dir == "." and root or root .. "/" .. dir
    if uv.fs_stat(full) then scan(full, dir == "." and 0 or 3) end
  end
  table.sort(found, function(a, b) return a.mtime > b.mtime end)
  local out = {}
  for i = 1, math.min(#found, limit or 20) do out[i] = found[i].path:sub(#root + 2) end
  return out
end

-- The last program run per project, kept across sessions (M.state_path: the tests' own file).
M.state_path = nil
local function state_file() return M.state_path or vim.fn.stdpath("state") .. "/desk-debug.json" end
local function load_state()
  local fd = io.open(state_file(), "r")
  if not fd then return {} end
  local ok, data = pcall(vim.json.decode, fd:read("*a"))
  fd:close()
  return ok and type(data) == "table" and data or {}
end
function M.remember(root, program)
  local data = load_state()
  data[root] = program
  vim.fn.mkdir(vim.fs.dirname(state_file()), "p")
  local fd = io.open(state_file(), "w")
  if fd then fd:write(vim.json.encode(data)); fd:close() end
end
function M.last(root) return load_state()[root] end

-- The choices, in the order they are offered: the last program first, then the build's newest.
function M.choices(root)
  local items, last = {}, M.last(root)
  if last and is_program(root .. "/" .. last) then items[1] = last end
  for _, rel in ipairs(M.candidates(root)) do if rel ~= last then items[#items + 1] = rel end end
  items[#items + 1] = "another path…"
  return items
end

-- nvim-dap waits for a coroutine returned here, so the picker can ask without blocking.
function M.pick_program()
  local dap = require("dap")
  local root = M.root()
  return coroutine.create(function(co)
    vim.ui.select(M.choices(root), { prompt = "Debug which program?" }, function(choice)
      if choice == "another path…" then
        choice = vim.fn.input({ prompt = "Program: ", default = root .. "/", completion = "file" })
        if choice ~= "" and choice:sub(1, #root + 1) == root .. "/" then choice = choice:sub(#root + 2) end
      end
      if not choice or choice == "" then return coroutine.resume(co, dap.ABORT) end
      M.remember(root, choice)
      coroutine.resume(co, choice:sub(1, 1) == "/" and choice or root .. "/" .. choice)
    end)
  end)
end

local function gdb_speaks_dap()
  if vim.fn.executable("gdb") ~= 1 then return false end
  local major = tonumber((vim.fn.system({ "gdb", "--version" }):match("GNU gdb [^%d]*(%d+)%.")))
  return major ~= nil and major >= 14
end

-- Adapters and launch settings for what is installed: gdb first, lldb-dap as the alternative.
function M.configure(dap)
  local launches = {}
  if gdb_speaks_dap() then
    dap.adapters.gdb = { type = "executable", command = "gdb", args = { "--interpreter=dap", "--eval-command", "set print pretty on" } }
    launches[#launches + 1] = { name = "Run a program (gdb)", type = "gdb", request = "launch", program = M.pick_program,
                                cwd = "${workspaceFolder}", stopAtBeginningOfMainSubprogram = false }
  end
  if vim.fn.executable("lldb-dap") == 1 then
    dap.adapters.lldb = { type = "executable", command = "lldb-dap", name = "lldb" }
    launches[#launches + 1] = { name = "Run a program (lldb)", type = "lldb", request = "launch", program = M.pick_program,
                                cwd = "${workspaceFolder}", stopOnEntry = false }
  end
  for _, ft in ipairs({ "c", "cpp" }) do dap.configurations[ft] = launches end
  return #launches
end

-- Marks in the sign column; a theme that defined its own (Paper's current line) keeps them.
local SIGNS = {
  DapBreakpoint = "●", DapBreakpointCondition = "◆", DapLogPoint = "◇", DapBreakpointRejected = "○", DapStopped = "→",
}

function M.setup()
  local ok, dap = pcall(require, "dap")
  if not ok then return end
  if M.configure(dap) == 0 then
    vim.notify("debugging: install gdb 14 or later (or lldb) to debug C and C++", vim.log.levels.WARN)
  end
  for name, text in pairs(SIGNS) do
    if vim.tbl_isempty(vim.fn.sign_getdefined(name)) then vim.fn.sign_define(name, { text = text, texthl = name }) end
  end
  local has_ui, dapui = pcall(require, "dapui")
  if has_ui then
    dapui.setup({ floating = { border = "single" } })
    dap.listeners.after.event_initialized["desk.debug"] = function() dapui.open() end
    dap.listeners.before.event_terminated["desk.debug"] = function() dapui.close() end
    dap.listeners.before.event_exited["desk.debug"] = function() dapui.close() end
  end
end

return M
