-- nvim --headless --clean -l shared/nvim_lua/tests/test_popout.lua : desk.popout end to end. A main editor and its
-- pop-out, two headless Neovims on private sockets, driven from here over RPC, in a sandbox of their own: HOME, the XDG
-- folders and XDG_RUNTIME_DIR are private folders under tests/, and kitty, hyprctl, desk-hl, desk-drawer and desk-work
-- are stubs first on PATH that log what they are asked (kitty runs the pop-out headless). Nothing runs until every
-- stub is proven to shadow the real tool: never her sockets, tmux, Hyprland or terminal.
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*/)')
local uv = vim.uv
local ROOT = (vim.fn.fnamemodify(here .. '../../..', ':p'):gsub('/$', ''))
local passed, failed = 0, 0
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print('FAIL: ' .. what .. '\n  got:  ' .. vim.inspect(got) .. '\n  want: ' .. vim.inspect(want)) end
end
local function ok(cond, what) eq(not not cond, true, what) end

-- ─── the sandbox ────────────────────────────────────────────────────────────────────────────────────────────────
-- Under tests/: the stubs need a folder that may run programs (/tmp may not), and the sockets a short path.
local base = assert(uv.fs_mkdtemp(ROOT .. '/tests/poXXXXXX'))
local dir, bin = base .. '/run', base .. '/bin'
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
# kitty, for the test: records its argv, then runs the command after -e headless, on a socket of the test's.
printf '%s\n' "$@" > "$POPOUT_TEST/kitty.argv"
echo $$ > "$POPOUT_TEST/kitty.pid"
n=$(( $(cat "$POPOUT_TEST/kitty.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$POPOUT_TEST/kitty.count"
echo "$POPOUT_TEST/p$n" > "$POPOUT_TEST/kitty.listen"
while [ $# -gt 0 ] && [ "$1" != -e ]; do shift; done
shift
[ "$1" = nvim ] && shift
exec nvim --headless --clean --listen "$POPOUT_TEST/p$n" --cmd "luafile $POPOUT_TEST/loader.lua" "$@" 2>>"$POPOUT_TEST/popout.err"
]], 'rwxr-xr-x')
write(bin .. '/hyprctl', [[#!/bin/sh
# hyprctl, for the test: logs every call; the screens and windows come from the test's files.
printf '%s\n' "$*" >> "$POPOUT_TEST/hyprctl.log"
case "$1 $2" in
  "-j monitors") cat "$POPOUT_TEST/monitors.json" ;;
  "-j clients")
    pop=$(cat "$POPOUT_TEST/kitty.pid" 2>/dev/null || echo 0)
    main=$(cat "$POPOUT_TEST/main.pid" 2>/dev/null || echo 0)
    printf '[{"address":"0xa1","pid":%s,"class":"kitty"},{"address":"0xb2","pid":%s,"class":"desk-popout"}]\n' "$main" "$pop" ;;
  "eval return 1") echo 1 ;;
  *) echo ok ;;
esac
]], 'rwxr-xr-x')
for _, name in ipairs({ 'desk-drawer', 'desk-work' }) do
  write(bin .. '/' .. name, '#!/bin/sh\nprintf "%s\\n" "$(basename "$0") $*" >> "$POPOUT_TEST/others.log"\nexit 1\n', 'rwxr-xr-x')
end
vim.fn.writefile(vim.fn.readfile(ROOT .. '/shared/bin/desk-hl', 'b'), bin .. '/desk-hl', 'b')
vim.fn.setfperm(bin .. '/desk-hl', 'rwxr-xr-x')
-- The repo's desk modules, ahead of any installed copy, in both Neovims.
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
write(dir .. '/monitors.json', vim.json.encode({ { name = 'eDP-1', focused = true, activeWorkspace = { id = 1, name = '1' } },
  { name = 'DP-2', focused = false, activeWorkspace = { id = 5, name = '5' } } }))
local sidecar = base .. '/config/foxml/monitor-layout.conf'
write(sidecar, 'PRIMARY="eDP-1"\nPORTRAIT_OUTPUTS="DP-2"\nSECONDARY_OUTPUTS="DP-2"')
-- Nothing of her session reaches the two Neovims: no tmux, parent Neovim, Hyprland instance, display or kitty.
local env = vim.fn.environ()
for _, name in ipairs({ 'TMUX', 'TMUX_PANE', 'NVIM', 'NVIM_LISTEN_ADDRESS', 'HYPRLAND_INSTANCE_SIGNATURE', 'WAYLAND_DISPLAY',
  'DISPLAY', 'KITTY_WINDOW_ID', 'KITTY_LISTEN_ON' }) do env[name] = nil end
for name, value in pairs({ HOME = base .. '/home', XDG_RUNTIME_DIR = dir, XDG_CONFIG_HOME = base .. '/config', XDG_STATE_HOME = base .. '/state',
  XDG_CACHE_HOME = base .. '/cache', XDG_DATA_HOME = base .. '/data', NVIM_LOG_FILE = base .. '/nvim.log', TERM = 'xterm-256color',
  PATH = bin .. ':' .. (env.PATH or '/usr/bin:/bin'), POPOUT_TEST = dir, POPOUT_LUA = ROOT .. '/shared/nvim_lua', POPOUT_PING_MS = '300' }) do
  env[name] = value
end
local found = vim.system({ 'sh', '-c', 'for t in kitty hyprctl desk-hl desk-drawer desk-work; do command -v "$t"; done' },
  { env = env, clear_env = true, text = true }):wait()
local shadowed = vim.tbl_map(function(path) return path == bin .. '/' .. vim.fs.basename(path) end, vim.split(vim.trim(found.stdout), '\n'))
if #shadowed ~= 5 or vim.tbl_contains(shadowed, false) then
  print('FAIL: the stubs do not shadow the real tools:\n' .. found.stdout)
  vim.fn.delete(base, 'rf')
  os.exit(1)
end

local function wait(ms, cond) return vim.wait(ms, function() local fine, value = pcall(cond); return fine and value end, 20) end
local function exists(path) return uv.fs_stat(path) ~= nil end

local function scenario()
-- This process is the terminal the main editor runs in: hyprctl's stub lists it as that editor's window (0xa1).
vim.fn.writefile({ tostring(vim.fn.getpid()) }, dir .. '/main.pid')
local host_job = vim.system({ 'nvim', '--headless', '--clean', '--listen', dir .. '/h', '--cmd', 'luafile ' .. dir .. '/loader.lua',
  '-c', 'luafile ' .. here .. 'popout_host.lua' }, { text = true, env = env, clear_env = true })
assert(wait(10000, function() return exists(dir .. '/h') end), 'the main editor never listened')
local h = vim.fn.sockconnect('pipe', dir .. '/h', { rpc = true })
local function host(code, ...) return vim.rpcrequest(h, 'nvim_exec_lua', code, { ... }) end
ok(wait(10000, function() return host('return _G.popout_test and _G.popout_test.ready') == true end), 'the main editor is set up')

local p, psock
local function pop(code, ...) return vim.rpcrequest(p, 'nvim_exec_lua', code, { ... }) end
local function state()
  local fine, value = pcall(pop, "return require('desk.popout').client_state()")
  return fine and value or {}
end
local function popped() return table.concat(state().lines or {}, '\n') end
local function press(keys) vim.rpcrequest(p, 'nvim_input', keys) end
local function log_since(mark) return read('hyprctl.log'):sub(mark + 1) end
local function opened()
  ok(wait(10000, function() return exists(dir .. '/kitty.listen') end), 'the pop-out is started, in kitty')
  psock = vim.trim(read('kitty.listen'))
  ok(wait(10000, function() return exists(psock) end), '… and its Neovim listens')
  p = vim.fn.sockconnect('pipe', psock, { rpc = true })
end
local function open_row() host("local A = require('desk.actions'); A.get('popout.open').run(A.context())") end

-- ─── one screen: not offered, the views stay in the editor ───────────────────────────────────────────────────────
local two_screens = read(sidecar)
vim.fn.writefile({ 'PRIMARY="eDP-1"', 'PORTRAIT_OUTPUTS=""', 'SECONDARY_OUTPUTS=""' }, sidecar)
eq(host("return require('desk.popout').second_screen()"), 'requires a second monitor', 'one screen: the pop-out is not offered')
eq(host("local A = require('desk.actions'); return A.available(A.get('popout.open'), A.context())"), 'requires a second monitor',
  '… its row says why')
open_row()
vim.wait(300)
ok(not exists(dir .. '/kitty.argv'), '… and running it opens nothing')
vim.fn.writefile(vim.split(two_screens, '\n', { trimempty = true }), sidecar)
eq(host("return require('desk.popout').second_screen()"), true, 'a second screen in monitor-layout.conf: it is offered')

-- ─── open: subscribe, the view arrives and is drawn ─────────────────────────────────────────────────────────────
open_row()
opened()
eq(vim.split(read('kitty.argv'), '\n', { trimempty = true }), { '--class', 'desk-popout', '-e', 'nvim', '--cmd', 'let g:desk_popout=1',
  '-c', "lua require('desk.popout').client()", '--', 'desk-popout:' .. dir .. '/h' }, "kitty runs it with the editor's socket in argv only")
ok(wait(10000, function() return popped():find('callee_of_M.alpha', 1, true) end), 'subscribed: the graph of the function under the cursor arrives')
local s = state()
eq({ s.connected, s.title, s.selected }, { true, 'call graph · M.alpha', 'M.alpha' }, '… titled with it, its own box selected')
ok(popped():find('║ M.alpha', 1, true) and popped():find('caller_of_M.alpha', 1, true), '… drawn: the function in a double box, its caller above')
ok(pop("return #vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace('desk_popout'), 0, -1, {}) > 10"), '… with its marks')
ok(next(pop("return vim.api.nvim_get_hl(0, { name = 'DeskCallGraphCentre', link = false })")) ~= nil, "… and the editor's highlight groups")
eq(pop("return { vim.bo.buftype, vim.bo.modifiable, #vim.lsp.get_clients() }"), { 'nofile', false, 0 }, '… in a plain buffer, no language server')
eq(host("local H = require('desk.popout').host; return { H.chan ~= nil, H.pid }"), { true, s.host and pop('return vim.fn.getpid()') },
  "the editor keeps the pop-out's channel and pid")
ok(wait(5000, function()
  return read('hyprctl.log'):find("dispatch hl.dsp.window.move({ workspace = '5', follow = false, window = 'address:0xb2' })", 1, true)
end), 'placed on the workspace showing on the second screen (DP-2 shows 5), without following it')
ok(wait(5000, function() return read('hyprctl.log'):find("dispatch hl.dsp.window.float({ action = 'unset', window = 'address:0xb2' })", 1, true) end),
  '… tiled there')

-- ─── Enter: the editor goes there, the keyboard stays in the pop-out ─────────────────────────────────────────────
press('j')
ok(wait(2000, function() return state().selected == 'callee_of_M.alpha' end), 'j moves the selection, in the pop-out')
eq(host('return vim.api.nvim_win_get_cursor(0)'), { 3, 2 }, '… the editor has not moved')
local mark = #read('hyprctl.log')
press('<CR>')
ok(wait(3000, function() return host('return vim.api.nvim_win_get_cursor(0)[1]') == 5 end), "Enter: the editor goes to the selected box's function")
s = state()
eq({ s.mode, s.current_win == s.win }, { 'n', true }, '… and the keyboard stays in the pop-out (its window, normal mode)')
eq(log_since(mark):find('hl.dsp.focus', 1, true), nil, '… nothing is focused')
ok(wait(3000, function() return state().title == 'call graph · M.beta' end), 'following: the graph moves to where the editor went')

-- ─── what an act may name ───────────────────────────────────────────────────────────────────────────────────────
local gen = state().gen
local function act(fields) return host("return require('desk.bridge').receive(...)", vim.tbl_extend('force', { version = 1, type = 'act', view = 'callgraph', gen = gen, item = 1 }, fields)) end
eq(act({ gen = gen - 1, action = 'popout.go' }), { refused = 'this view moved on' }, 'a stale generation is refused')
eq(act({ action = 'callgraph.go' }), { refused = 'callgraph.go is not one the pop-out may ask for' }, 'a row that is not remote is refused')
eq(act({ action = 'popout.keys' }), { refused = 'popout.keys is not one the pop-out may ask for' }, '… a pop-out row that is not remote too')
eq(act({ action = 'popout.nothing' }), { refused = 'no action is called popout.nothing' }, '… and an id that is no row')
eq(act({ item = 400, action = 'popout.go' }), { refused = 'there is no such box in this view' }, '… and a box the view does not have')
-- Without symdeps (not installed here) its row is refused with why, and gs in the pop-out says so; nothing else happens.
eq(act({ action = 'popout.symdeps' }), { refused = 'requires symdeps' }, 'without symdeps: its row says "requires symdeps"')
pop('_G.heard = {}; vim.notify = function(text) table.insert(_G.heard, text) end')
local line_before = host('return vim.api.nvim_win_get_cursor(0)[1]')
press('gs')
ok(wait(2000, function() return vim.tbl_contains(pop('return _G.heard'), 'Requires symdeps.') end), '… gs in the pop-out says "Requires symdeps."')
eq({ host('return vim.api.nvim_win_get_cursor(0)[1]'), state().title }, { line_before, 'call graph · M.beta' }, '… and does nothing else')
eq(act({ action = 'popout.pin' }), { done = true }, 'a remote row runs')
ok(wait(2000, function() return (state().lines or {})[1]:find('PINNED', 1, true) end), '… pinned: the pop-out says so')

-- ─── pinned: the editor moving sends nothing; p follows again ───────────────────────────────────────────────────
local received = state().received
vim.rpcrequest(h, 'nvim_input', '8G')
vim.wait(800)
eq(host('return vim.api.nvim_win_get_cursor(0)[1]'), 8, 'the editor moves into gamma')
eq({ state().received, state().title }, { received, 'call graph · M.beta' }, '… and the pinned graph stays: nothing was sent')
press('p')
ok(wait(3000, function() return state().title == 'call graph · gamma' end), 'p: following again, from where the editor is')
ok(not (state().lines or {})[1]:find('PINNED', 1, true), '… no longer pinned')

-- ─── Space Space in the pop-out: the editor's rows for that box ─────────────────────────────────────────────────
press('<Space><Space>')
ok(wait(3000, function() return pop("local m = require('desk.menu')._last; return m ~= nil and vim.api.nvim_win_is_valid(m.win)") end),
  'Space Space opens the home menu in the pop-out')
local menu = pop("return table.concat(vim.api.nvim_buf_get_lines(require('desk.menu')._last.buf, 0, -1, false), '\\n')")
ok(menu:find('Go to it', 1, true) and menu:find('Pin, or follow the editor', 1, true) and menu:find('Back to the editor', 1, true),
  "its rows are the editor's (describe):\n" .. menu)
ok(menu:find('requires symdeps', 1, true), '… a row that cannot run says why')
ok(menu:find('Call graph of this function', 1, true), "… the editor's other remote rows are there")
ok(menu:find("The pop-out's keys", 1, true) and menu:find('To the editor', 1, true), "… and so are this window's own")
ok(not menu:find('Pop out the call graph', 1, true) and not menu:find('Home menu', 1, true), '… but no row the pop-out may not ask for')
ok(pop("return vim.inspect(vim.api.nvim_win_get_config(require('desk.menu')._last.win).title)"):find('Home · pop-out · gamma', 1, true),
  '… titled with the selected box')
pop([[local m = require('desk.menu')._last
  for i, line in ipairs(vim.api.nvim_buf_get_lines(m.buf, 0, -1, false)) do
    if line:find('Pin, or follow', 1, true) and line:sub(1, 2) == '  ' then vim.api.nvim_win_set_cursor(m.win, { i, 0 }) end
  end]])
press('<CR>')
ok(wait(3000, function() return (state().lines or {})[1]:find('PINNED', 1, true) end), 'a row run from that menu acts in the editor (pinned)')

-- ─── ? lists the pop-out's keys, from its rows ─────────────────────────────────────────────────────────────────
press('?')
ok(wait(2000, function() return pop("return vim.api.nvim_win_get_config(0).relative ~= ''") end), '? opens a list in the pop-out')
local keys = pop("return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')")
ok(keys:find('Enter%s+Go to it') and keys:find('Shift%+Enter%s+Go to it, in the editor') and keys:find('Space Tab%s+To the editor')
  and keys:find('Space Space%s+Home menu') and keys:find('q%s+Close the pop%-out'), "… its keys, as typed, with the rows' names:\n" .. keys)
ok(keys:find('Space Tab in the editor comes back here', 1, true), '… and the way back')
press('q')
ok(wait(2000, function() return state().current_win == state().win end), '… q closes it, back in the pop-out')

-- ─── the focus swap ─────────────────────────────────────────────────────────────────────────────────────────────
eq(pop("return vim.fn.maparg('<leader><Tab>', 'n', false, true).desc"), 'To the editor', 'Space Tab in the pop-out goes to the editor')
eq(host("return vim.fn.maparg('<leader><Tab>', 'n', false, true).desc"), 'To the pop-out', '… the same key in the editor comes here')
mark = #read('hyprctl.log')
press('<Space><Tab>')
ok(wait(3000, function() return log_since(mark):find("dispatch hl.dsp.focus({ window = 'address:0xa1' })", 1, true) end),
  "Space Tab in the pop-out: hyprctl focuses the editor's window (the kitty above its Neovim)")
mark = #read('hyprctl.log')
host("local A = require('desk.actions'); A.get('popout.focus').run(A.context())")
ok(wait(3000, function() return log_since(mark):find("dispatch hl.dsp.focus({ window = 'address:0xb2' })", 1, true) end),
  "Space Tab in the editor: the pop-out's window")
vim.rpcrequest(h, 'nvim_input', 'gg')
ok(wait(2000, function() return host('return vim.api.nvim_win_get_cursor(0)[1]') == 1 end), 'the editor moves away (pinned: the graph stays)')
mark = #read('hyprctl.log')
press('<S-CR>')
ok(wait(3000, function() return host('return vim.api.nvim_win_get_cursor(0)[1]') == 8 end), 'Shift+Enter: the editor goes to the box')
ok(wait(3000, function() return log_since(mark):find("dispatch hl.dsp.focus({ window = 'address:0xa1' })", 1, true) end), '… and gets the keyboard')

-- ─── a pop-out that stops answering ─────────────────────────────────────────────────────────────────────────────
eq(host("return require('desk.popout').host.stalled"), false, 'answering its pings')
pop('vim.defer_fn(function() vim.uv.sleep(1500) end, 10)')
ok(wait(3000, function() return host("return require('desk.popout').host.stalled") == true end), 'stuck: the editor stops sending to it')
ok(wait(6000, function() return host("return require('desk.popout').host.stalled") == false end), '… until it answers again')

-- ─── detach and attach ──────────────────────────────────────────────────────────────────────────────────────────
local panel_open = "local G = require('desk.callgraph'); return G.panel.win ~= nil and vim.api.nvim_win_is_valid(G.panel.win)"
press('o')
ok(wait(3000, function() return host(panel_open) end), 'o in the pop-out: the graph comes back as a split in the editor (the live panel)')
eq(host("local G = require('desk.callgraph'); return { G.panel.pinned, G.panel.graph and G.panel.graph.center.name }"), { true, 'gamma' },
  '… pinned to the same graph')
ok(wait(3000, function() return state().shown == '' and popped():find('o in a call graph sends it here', 1, true) end),
  '… and the pop-out shows nothing, saying how to send one')
host("vim.api.nvim_set_current_win(require('desk.callgraph').panel.win)")
vim.rpcrequest(h, 'nvim_input', 'o')
ok(wait(3000, function() return state().title == 'call graph · gamma' end), 'o in the panel: the graph goes to the pop-out again')
eq(host(panel_open), false, '… and leaves the editor')
ok((state().lines or {})[1]:find('PINNED', 1, true), '… still pinned')
host("vim.api.nvim_set_current_win(_G.popout_test.code_win); vim.api.nvim_win_set_cursor(0, { 3, 2 }); require('desk.callgraph').open_cursor()")
ok(wait(3000, function() return host("local v = require('desk.callgraph').view(); return v ~= nil and v.graph.callees ~= nil") end),
  'a graph tab of M.alpha')
vim.rpcrequest(h, 'nvim_input', 'o')
ok(wait(3000, function() return state().title == 'call graph · M.alpha' end), 'o in the graph tab: the graph moves to the pop-out')
eq(host("return require('desk.callgraph').view() == nil"), true, '… and the tab closes')
ok((state().lines or {})[1]:find('PINNED', 1, true), '… pinned: a tab shows one chosen function')

-- ─── q: the pop-out closes, the editor stops sending ────────────────────────────────────────────────────────────
vim.rpcnotify(p, 'nvim_input', 'q')
ok(wait(5000, function() return host("return require('desk.popout').host.chan") == vim.NIL end), 'q: the editor forgets the pop-out')
ok(wait(5000, function() return not exists(psock) end), '… which quits')
eq(host("return next(require('desk.popout').host.views) == nil"), true, '… and nothing is kept to send it')

-- ─── the editor closing: the pop-out says so and quits ──────────────────────────────────────────────────────────
os.remove(dir .. '/kitty.listen')
open_row()
opened()
ok(wait(10000, function() return state().connected and state().title:find('call graph', 1, true) end), 'opened again')
pop("require('desk.popout').LINGER_MS = 4000")
vim.rpcnotify(h, 'nvim_command', 'qa!')
ok(wait(6000, function() return state().closing == 'Editor closed.' end), 'the editor closing: the pop-out says "Editor closed."')
-- The pop-out is a detached child of the editor: the editor exits at once, never waiting for it.
ok(host_job:wait(3000).code == 0 and exists(psock), '… the editor exits while the pop-out is still open')
ok(wait(10000, function() return not exists(psock) end), '… which then quits')
end

local ran, err = xpcall(scenario, debug.traceback)
if not ran then failed = failed + 1; print('FAIL: ' .. tostring(err)) end
if failed > 0 then print('--- hyprctl.log ---\n' .. read('hyprctl.log') .. '--- the pop-out said ---\n' .. read('popout.err')) end
local asked = read('others.log')
if asked ~= '' then failed = failed + 1; print('FAIL: desk-work or desk-drawer was asked for something:\n' .. asked) end
-- Whatever is left of the two Neovims goes, and only them: a process is killed only when its command line names the sandbox.
for _, name in ipairs({ 'host.pid', 'kitty.pid' }) do
  local pid = tonumber(vim.trim(read(name)))
  local cmdline = pid and read('/proc/' .. pid .. '/cmdline') or ''
  if pid and pid > 1 and cmdline:find(dir, 1, true) then pcall(uv.kill, pid, 'sigkill') end
end
vim.fn.delete(base, 'rf')
print(('popout: %d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
