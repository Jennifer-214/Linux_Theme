-- nvim --headless --clean -l shared/nvim_lua/tests/test_popout_restart.lua : :restart with the pop-out open. The editor
-- runs as a terminal UI in a pty of this process (:restart attaches its UIs to the new server), with a pop-out
-- attached; :restart typed there must restart at once (an error during the exit makes Neovim wait for a key, which
-- looked like a stall), the pop-out say "Editor closed." and quit, and the new editor offer the pop-out's views
-- again. Sealed as test_popout.lua is: private HOME and XDG folders, stubs of kitty, hyprctl, desk-hl, desk-drawer and
-- desk-work first on PATH, no tmux, Hyprland or display of hers; only processes naming the sandbox are killed.
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*/)')
local uv = vim.uv
local ROOT = (vim.fn.fnamemodify(here .. '../../..', ':p'):gsub('/$', ''))
local passed, failed = 0, 0
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print('FAIL: ' .. what .. '\n  got:  ' .. vim.inspect(got) .. '\n  want: ' .. vim.inspect(want)) end
end
local function ok(cond, what) eq(not not cond, true, what) end

-- Under tests/: the stubs need a folder that may run programs (/tmp may not), and the sockets a short path.
local base = assert(uv.fs_mkdtemp(ROOT .. '/tests/poXXXXXX'))
local dir, bin = base .. '/r', base .. '/bin'
for _, folder in ipairs({ dir, bin, base .. '/home', base .. '/config/foxml', base .. '/state', base .. '/cache', base .. '/data' }) do
  vim.fn.mkdir(folder, 'p', tonumber('700', 8))
end
local function read(name)
  local f = io.open(name:sub(1, 1) == '/' and name or (dir .. '/' .. name), 'r')
  if not f then return '' end
  local text = f:read('*a')
  f:close()
  return text
end
local function write(path, text, mode)
  vim.fn.writefile(vim.split(text, '\n', { plain = true }), path, 'b')
  if mode then vim.fn.setfperm(path, mode) end
end
write(bin .. '/kitty', [[#!/bin/sh
# kitty, for the test: runs the command after -e headless, on a socket of the test's.
echo $$ > "$POPOUT_TEST/kitty.pid"
while [ $# -gt 0 ] && [ "$1" != -e ]; do shift; done
shift
[ "$1" = nvim ] && shift
exec nvim --headless --clean --listen "$POPOUT_TEST/p1" --cmd "luafile $POPOUT_TEST/loader.lua" "$@" 2>>"$POPOUT_TEST/popout.err"
]], 'rwxr-xr-x')
write(bin .. '/hyprctl', [[#!/bin/sh
case "$1 $2" in
  "-j monitors") cat "$POPOUT_TEST/monitors.json" ;;
  "-j clients") echo '[]' ;;
  *) echo ok ;;
esac
]], 'rwxr-xr-x')
write(bin .. '/desk-drawer', '#!/bin/sh\nexit 1\n', 'rwxr-xr-x')
write(bin .. '/desk-hl', '#!/bin/sh\nexit 1\n', 'rwxr-xr-x')
write(bin .. '/desk-work', [[#!/bin/sh
# desk-work, for the test: workspace keeps one record per client in the sandbox; anything else fails.
[ "$1" = workspace ] || exit 1
client= input=
while [ $# -gt 0 ]; do
  case "$1" in --client) client=$2; shift 2 ;; --input) input=$2; shift 2 ;; *) shift ;; esac
done
record="$POPOUT_TEST/workspace.$client.json"
if [ "$input" = - ]; then cat > "$record.new" && mv "$record.new" "$record" && echo '{"ok":true}'
elif [ -f "$record" ]; then cat "$record"
else echo null; fi
]], 'rwxr-xr-x')
write(dir .. '/loader.lua', [[
local lua = os.getenv('POPOUT_LUA')
package.path = lua .. '/?.lua;' .. package.path
table.insert(package.loaders, 2, function(name)
  local file = lua .. '/' .. name:gsub('%.', '/') .. '.lua'
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
vim.g.mapleader = ' '
vim.g.desk_style = 'paper'
]])
-- The editor: says which server it is (a restarted one is another), then sets up as test_popout.lua's does.
write(dir .. '/editor.lua', [[
local dir = os.getenv('POPOUT_TEST')
vim.fn.writefile({ vim.fn.getpid() .. ' ' .. vim.v.servername }, dir .. '/server.last')
dofile(os.getenv('POPOUT_LUA') .. '/tests/popout_host.lua')
]])
write(dir .. '/monitors.json', vim.json.encode({ { name = 'eDP-1', focused = true, activeWorkspace = { id = 1, name = '1' } },
  { name = 'DP-2', focused = false, activeWorkspace = { id = 5, name = '5' } } }))
write(base .. '/config/foxml/monitor-layout.conf', 'PRIMARY="eDP-1"\nPORTRAIT_OUTPUTS="DP-2"\nSECONDARY_OUTPUTS="DP-2"')
local env = vim.fn.environ()
for _, name in ipairs({ 'TMUX', 'TMUX_PANE', 'NVIM', 'NVIM_LISTEN_ADDRESS', 'HYPRLAND_INSTANCE_SIGNATURE', 'WAYLAND_DISPLAY',
  'DISPLAY', 'KITTY_WINDOW_ID', 'KITTY_LISTEN_ON', 'DBUS_SESSION_BUS_ADDRESS', 'SWAYSOCK' }) do env[name] = nil end
for name, value in pairs({ HOME = base .. '/home', XDG_RUNTIME_DIR = dir, XDG_CONFIG_HOME = base .. '/config', XDG_STATE_HOME = base .. '/state',
  XDG_CACHE_HOME = base .. '/cache', XDG_DATA_HOME = base .. '/data', NVIM_LOG_FILE = base .. '/nvim.log', TERM = 'xterm-256color',
  PATH = bin .. ':' .. (env.PATH or '/usr/bin:/bin'), POPOUT_TEST = dir, POPOUT_LUA = ROOT .. '/shared/nvim_lua', POPOUT_PING_MS = '1000',
  TMUX_TMPDIR = dir }) do
  env[name] = value
end
local found = vim.system({ 'sh', '-c', 'for t in kitty hyprctl desk-hl desk-drawer desk-work; do command -v "$t"; done' },
  { env = env, clear_env = true, text = true }):wait()
for _, path in ipairs(vim.split(vim.trim(found.stdout), '\n')) do
  if path ~= bin .. '/' .. vim.fs.basename(path) then
    print('FAIL: the stubs do not shadow the real tools:\n' .. found.stdout)
    vim.fn.delete(base, 'rf')
    os.exit(1)
  end
end

local function wait(ms, cond) return vim.wait(ms, function() local fine, value = pcall(cond); return fine and value end, 20) end
local function alive(pid) return type(pid) == 'number' and uv.kill(pid, 0) == 0 end
local function server() local pid, sock = read('server.last'):match('^(%d+) (%S+)'); return tonumber(pid), sock end
-- Asked with a deadline: an editor that stalls (waiting for a key, the regression this file is for) answers no request,
-- and a vim.rpcrequest to it would hold this file until the runner's timeout, saying nothing. A client Neovim asks
-- instead and is stopped after 5 s: nil then, as when the editor is gone.
local function ask(sock, code)
  if not sock then return nil end
  local expr = "json_encode(luaeval('(function() " .. (code:gsub("'", "''")) .. " end)()'))"
  local fine, job = pcall(vim.system, { 'nvim', '--clean', '--headless', '--server', sock, '--remote-expr', expr },
    { env = env, clear_env = true, text = true, timeout = 5000 })
  if not fine then return nil end
  local out = job:wait()
  local decoded, value = pcall(vim.json.decode, out.code == 0 and out.stdout or '')
  if not decoded or value == vim.NIL then return nil end
  return value
end

local tui
local function scenario()
  tui = vim.fn.jobstart({ 'nvim', '--clean', '--cmd', 'luafile ' .. dir .. '/loader.lua', '-c', 'luafile ' .. dir .. '/editor.lua' },
    { pty = true, width = 120, height = 40, env = env, clear_env = true, on_stdout = function() end })
  ok(tui > 0 and wait(10000, function() return server() ~= nil end), 'the editor runs, a terminal UI in a pty')
  local old, sock = server()
  ok(wait(10000, function() return ask(sock, 'return _G.popout_test and _G.popout_test.ready') == true end), '… set up')
  ask(sock, "local A = require('desk.actions'); A.get('popout.view.graph').run(A.context()); return true")
  ok(wait(10000, function() return ask(sock, "return require('desk.popout').host.chan ~= nil") == true end), 'the pop-out attaches to it')
  local popout = tonumber(vim.trim(read('kitty.pid')))
  ok(wait(10000, function() return ask(dir .. '/p1', "return require('desk.popout').client_state().title") == 'call graph · M.alpha' end),
    '… and shows the call graph')
  vim.fn.chansend(tui, ':restart\r')
  local restarted = wait(3000, function() return not alive(old) end)
  ok(restarted, ':restart with the pop-out open: the old editor exits at once, no key pressed')
  -- A stalled editor (waiting for a key) answers no request: the rest would only wait out the asks' deadlines.
  if not restarted then return end
  ok(wait(5000, function() return read('popout.err'):find('Editor closed.', 1, true) end), '… the pop-out says "Editor closed."')
  ok(wait(5000, function() return not alive(popout) end), '… and quits')
  ok(wait(10000, function() local pid = server(); return pid ~= old and alive(pid) end), 'the new editor runs')
  local _, sock2 = server()
  ok(wait(10000, function() return ask(sock2, "return require('desk.actions').get('popout.restore').name") == 'Restore 1 view' end),
    "… and offers the pop-out's view again: Restore 1 view")
  ask(sock2, "vim.schedule(function() vim.cmd('qa!') end); return true")
  ok(wait(5000, function() return not alive((server())) end), 'the new editor closes')
end

local ran, err = xpcall(scenario, debug.traceback)
if not ran then failed = failed + 1; print('FAIL: ' .. tostring(err)) end
if failed > 0 then print('--- the pop-out said ---\n' .. read('popout.err')) end
-- Whatever is left goes, and only it: a process is killed only when its command line names the sandbox.
if tui and tui > 0 then pcall(vim.fn.jobstop, tui) end
for _, entry in ipairs(vim.fn.readdir('/proc')) do
  local pid = tonumber(entry)
  if pid and pid ~= vim.fn.getpid() then
    local cmdline = read('/proc/' .. pid .. '/cmdline')
    if cmdline:find(base, 1, true) then pcall(uv.kill, pid, 'sigkill') end
  end
end
vim.wait(200)
vim.fn.delete(base, 'rf')
print(('popout restart: %d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
