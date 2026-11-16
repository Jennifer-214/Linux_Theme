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

-- ─── a public repo: the modules name none of the private workflow (its plans, the folder they are kept in) ──────
local naming = {}
for _, file in ipairs(vim.fn.glob(ROOT .. '/shared/nvim_lua/desk/*.lua', false, true)) do
  local text = table.concat(vim.fn.readfile(file), '\n')
  if text:find('plans/%d%d%d%d%-%d%d%-%d%d') or text:find('linux%-theme%-workspace') then naming[#naming + 1] = vim.fs.basename(file) end
end
eq(naming, {}, 'no desk module names a private plan or the workspace it is kept in')

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
# kitty, for the test: records its argv and what it was given of the editor's tmux and socket, then runs the command
# after -e headless, on a socket of the test's. With kitty.fail in the test's folder it fails at once, as a kitty that
# cannot start; with protocol there, the pop-out speaks that protocol.
[ -f "$POPOUT_TEST/kitty.fail" ] && exit 1
[ -f "$POPOUT_TEST/protocol" ] && export POPOUT_PROTOCOL="$(cat "$POPOUT_TEST/protocol")"
printf '%s\n' "$@" > "$POPOUT_TEST/kitty.argv"
printf 'NVIM=%s TMUX=%s TMUX_PANE=%s NVIM_NOTTYFAST=%s\n' "${NVIM:-}" "${TMUX:-}" "${TMUX_PANE:-}" "${NVIM_NOTTYFAST:-}" > "$POPOUT_TEST/kitty.env"
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
# hyprctl, for the test: logs every call; the screens and windows come from the test's files. With focus.fail in the
# test's folder a focus fails (exit 17).
printf '%s\n' "$*" >> "$POPOUT_TEST/hyprctl.log"
if [ "$1" = dispatch ] && [ -f "$POPOUT_TEST/focus.fail" ]; then case "$2" in *focus*) exit 17 ;; esac; fi
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
write(bin .. '/desk-drawer', '#!/bin/sh\nprintf "%s\\n" "$(basename "$0") $*" >> "$POPOUT_TEST/others.log"\nexit 1\n', 'rwxr-xr-x')
write(bin .. '/desk-work', [[#!/bin/sh
# desk-work, for the test: workspace keeps one record per checkout and client in the sandbox (the pop-out's layout), and
# a line in workspace.written once each write is done; anything else is logged as asked for, and fails. With
# workspace.slow in the test's folder the next write is held up 1.5 s (and says it started); with workspace.fail there,
# writes fail.
if [ "$1" = workspace ]; then
  printf '%s\n' "$*" >> "$POPOUT_TEST/workspace.log"
  client= input= root=
  while [ $# -gt 0 ]; do
    case "$1" in --client) client=$2; shift 2 ;; --input) input=$2; shift 2 ;; --root) root=$2; shift 2 ;; *) shift ;; esac
  done
  record="$POPOUT_TEST/workspace.$(printf '%s' "$root" | tr / _).$client.json"
  if [ "$input" = - ]; then
    if [ -f "$POPOUT_TEST/workspace.fail" ]; then echo 'cannot write the record' >&2; exit 3; fi
    if [ -f "$POPOUT_TEST/workspace.slow" ]; then rm -f "$POPOUT_TEST/workspace.slow"; : > "$POPOUT_TEST/workspace.started"; sleep 1.5; fi
    cat > "$record.$$" && mv "$record.$$" "$record" && echo '{"ok":true}'
    echo "$client" >> "$POPOUT_TEST/workspace.written"
  elif [ -f "$record" ]; then cat "$record"
  else echo null; fi
  exit 0
fi
printf '%s\n' "desk-work $*" >> "$POPOUT_TEST/others.log"
exit 1
]], 'rwxr-xr-x')
vim.fn.writefile(vim.fn.readfile(ROOT .. '/shared/bin/desk-hl', 'b'), bin .. '/desk-hl', 'b')
vim.fn.setfperm(bin .. '/desk-hl', 'rwxr-xr-x')
-- The repo's desk modules, ahead of any installed copy, in both Neovims; and a second view kind, a list of rows
-- (tests/popout_rows.lua), in both as a kind's module is.
write(dir .. '/loader.lua', [[
local lua = os.getenv('POPOUT_LUA')
package.path = lua .. '/?.lua;' .. package.path
table.insert(package.loaders, 2, function(name)
  local file = lua .. '/' .. name:gsub('%.', '/') .. '.lua'
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
vim.g.mapleader = ' '
vim.g.desk_style = 'paper'
require('tests.popout_rows')
if os.getenv('POPOUT_PROTOCOL') then require('desk.popout').PROTOCOL = tonumber(os.getenv('POPOUT_PROTOCOL')) end
]])
write(dir .. '/monitors.json', vim.json.encode({ { name = 'eDP-1', focused = true, activeWorkspace = { id = 1, name = '1' } },
  { name = 'DP-2', focused = false, activeWorkspace = { id = 5, name = '5' } } }))
local sidecar = base .. '/config/foxml/monitor-layout.conf'
write(sidecar, 'PRIMARY="eDP-1"\nPORTRAIT_OUTPUTS="DP-2"\nSECONDARY_OUTPUTS="DP-2"')
-- Nothing of her session reaches the two Neovims: no tmux, parent Neovim, Hyprland instance, display or kitty. The
-- editor gets a tmux of its own that is no server (a socket path in the sandbox, and tmux's folder there too), so a
-- pop-out that inherited the editor's tmux would show it. The editor pings its pop-out every second (10 s in use): a
-- pong later than one ping marks it stalled, and a shorter ping read a busy machine as a stalled pop-out.
local env = vim.fn.environ()
for _, name in ipairs({ 'TMUX', 'TMUX_PANE', 'NVIM', 'NVIM_LISTEN_ADDRESS', 'HYPRLAND_INSTANCE_SIGNATURE', 'WAYLAND_DISPLAY',
  'DISPLAY', 'KITTY_WINDOW_ID', 'KITTY_LISTEN_ON', 'DBUS_SESSION_BUS_ADDRESS', 'SWAYSOCK' }) do env[name] = nil end
for name, value in pairs({ HOME = base .. '/home', XDG_RUNTIME_DIR = dir, XDG_CONFIG_HOME = base .. '/config', XDG_STATE_HOME = base .. '/state',
  XDG_CACHE_HOME = base .. '/cache', XDG_DATA_HOME = base .. '/data', NVIM_LOG_FILE = base .. '/nvim.log', TERM = 'xterm-256color',
  PATH = bin .. ':' .. (env.PATH or '/usr/bin:/bin'), POPOUT_TEST = dir, POPOUT_LUA = ROOT .. '/shared/nvim_lua', POPOUT_PING_MS = '1000',
  TMUX = dir .. '/no-tmux,1,0', TMUX_PANE = '%77', TMUX_TMPDIR = dir }) do
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
local function later(ms) local s, us = uv.gettimeofday(); return s * 1000 + math.floor(us / 1000) + ms end
-- A Neovim's socket, connected to once it accepts: its file is there a moment before it listens (a long moment on a
-- busy machine). A plain loop: connects that fail inside vim.wait's condition hang this Neovim. nil after 10 s.
local function connect(path)
  for _ = 1, 100 do
    if path ~= '' and exists(path) then
      local fine, chan = pcall(vim.fn.sockconnect, 'pipe', path, { rpc = true })
      if fine and chan > 0 then return chan end
    end
    vim.wait(100)
  end
end

local function scenario()
-- This process is the terminal the main editor runs in: hyprctl's stub lists it as that editor's window (0xa1).
vim.fn.writefile({ tostring(vim.fn.getpid()) }, dir .. '/main.pid')
local host_job = vim.system({ 'nvim', '--headless', '--clean', '--listen', dir .. '/h', '--cmd', 'luafile ' .. dir .. '/loader.lua',
  '-c', 'luafile ' .. here .. 'popout_host.lua' }, { text = true, env = env, clear_env = true })
local h = assert(connect(dir .. '/h'), 'the main editor never listened')
local function host(code, ...) return vim.rpcrequest(h, 'nvim_exec_lua', code, { ... }) end
ok(wait(10000, function() return host('return _G.popout_test and _G.popout_test.ready') == true end), 'the main editor is set up')
-- "Nothing happened" is checked once the work is done, never after a fixed wait (a late regression would pass one):
-- the editor counts the layout writes it starts (the stub, those it finished), and settled() says its views have
-- nothing left to send: no graph waiting for the cursor to rest, none being read, and the pop-out has had everything
-- sent before (it answers a request only after what came before it on the channel).
host([[
  local real = vim.system
  _G.popout_test.writes = 0
  vim.system = function(argv, ...)
    if argv[1] == 'desk-work' and vim.tbl_contains(argv, '--input') then _G.popout_test.writes = _G.popout_test.writes + 1 end
    return real(argv, ...)
  end
]])
-- Writes go one at a time: none on its way (writing) and none waiting behind it (pending) either.
local function writes_landed()
  local finished = select(2, read('workspace.written'):gsub('\n', ''))
  return host([[local H = require('desk.popout').host; local t = H.save_timer
    return not (t and t:is_active()) and not H.writing and not H.pending and _G.popout_test.writes]]) == finished
end
local function settled()
  return host([[
    local H = require('desk.popout').host
    for _, view in pairs(H.views) do
      if (view.timer and view.timer:is_active()) or view.inflight or view.stop or view.wanted then return false end
    end
    return not H.chan or vim.rpcrequest(H.chan, 'nvim_eval', '1') == 1
  ]])
end

local p, psock
local function pop(code, ...) return vim.rpcrequest(p, 'nvim_exec_lua', code, { ... }) end
local function state()
  local fine, value = pcall(pop, "return require('desk.popout').client_state()")
  return fine and value or {}
end
local function popped() return table.concat(state().lines or {}, '\n') end
local function press(keys) vim.rpcrequest(p, 'nvim_input', keys) end
local function log_since(mark) return read('hyprctl.log'):sub(mark + 1) end
-- The layout record the editor keeps in desk-work for a checkout (this repository's by default: the sample file is in
-- it), as its stub writes it in the sandbox.
local REPO = uv.fs_realpath(ROOT)
local function record_file(root) local name = (root or REPO):gsub('/', '_'); return dir .. '/workspace.' .. name .. '.popout.json' end
local function record(root) local ok_, r = pcall(vim.json.decode, read(record_file(root))); return ok_ and type(r) == 'table' and r or {} end
local function opened()
  ok(wait(10000, function() return exists(dir .. '/kitty.listen') end), 'the pop-out is started, in kitty')
  psock = vim.trim(read('kitty.listen'))
  p = connect(psock)
  ok(p ~= nil, '… and its Neovim listens')
end
local function open_row() host("local A = require('desk.actions'); A.get('popout.view.graph').run(A.context())") end

-- ─── one screen: not offered, the views stay in the editor ───────────────────────────────────────────────────────
local two_screens = read(sidecar)
vim.fn.writefile({ 'PRIMARY="eDP-1"', 'PORTRAIT_OUTPUTS=""', 'SECONDARY_OUTPUTS=""' }, sidecar)
eq(host("return require('desk.popout').second_screen()"), 'requires a second monitor', 'one screen: the pop-out is not offered')
eq(host("local A = require('desk.actions'); return A.available(A.get('popout.view.graph'), A.context())"), 'requires a second monitor',
  '… its row says why')
eq(host("local A = require('desk.actions'); local ctx = A.context(); local r = A.for_context(ctx)[1]; return { r.group, A.available(r, ctx) }"),
  { 'Views', 'requires a second monitor' }, "Space Space in the editor: the views first, greyed with why they cannot open")
open_row()
-- The row's run decides before it returns: a pop-out it started would be on its way now.
eq(host("local H = require('desk.popout').host; return { H.opening == nil, H.kitty == nil, H.chan == nil }"), { true, true, true },
  '… and running it starts nothing')
ok(not exists(dir .. '/kitty.argv'), '… no kitty')
vim.fn.writefile(vim.split(two_screens, '\n', { trimempty = true }), sidecar)
eq(host("return require('desk.popout').second_screen()"), true, 'a second screen in monitor-layout.conf: it is offered')
-- Where it goes: never the screen with the focus (the editor's), even when that is the one listed as secondary.
local function target(monitors) return host("return require('desk.popout').target_screen(...)", monitors, { primary = 'eDP-1', secondary = { 'DP-2' }, portrait = { 'DP-2' } }) end
eq(target({ { name = 'eDP-1', focused = true, activeWorkspace = { id = 1 } }, { name = 'DP-2', focused = false, activeWorkspace = { id = 5 } } }),
  { name = 'DP-2', workspace = 5 }, 'the editor on the laptop: the pop-out goes to the second screen, on the workspace it shows')
eq(target({ { name = 'eDP-1', focused = false, activeWorkspace = { id = 1 } }, { name = 'DP-2', focused = true, activeWorkspace = { id = 5 } } }),
  { name = 'eDP-1', workspace = 1 }, '… the editor on the second screen: to the laptop, never the focused screen')
eq(target({ { name = 'DP-2', focused = true, activeWorkspace = { id = 5 } } }), vim.NIL, '… and with only the focused screen, nowhere')

-- ─── open: subscribe, the view arrives and is drawn ─────────────────────────────────────────────────────────────
open_row()
opened()
eq(vim.split(read('kitty.argv'), '\n', { trimempty = true }), { '--class', 'desk-popout', '-e', 'nvim', '--cmd', 'let g:desk_popout=1',
  '-c', "lua require('desk.popout').client()", '--', 'desk-popout:' .. dir .. '/h' }, "kitty runs it with the editor's socket in argv only")
eq(vim.trim(read('kitty.env')), 'NVIM= TMUX= TMUX_PANE= NVIM_NOTTYFAST=1', "… none of the editor's tmux, nor its socket as $NVIM; and it asks the terminal nothing at start (no E1568)")
ok(wait(10000, function() return popped():find('callee_of_M.alpha', 1, true) end), 'subscribed: the graph of the function under the cursor arrives')
local s = state()
eq({ s.connected, s.title, s.selected }, { true, 'call graph · M.alpha', 'M.alpha' }, '… titled with it, its own box selected')
eq({ s.shown, s.kind, s.state }, { 'graph', 'graph', 'following' }, '… a view of kind graph, following the editor')
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
-- The header is the tab line and the key line the window's status line; the drawing holds neither.
s = state()
eq({ s.tabs, s.tab, s.header:find('^ 1 graph ') ~= nil, s.header:find('gt views · Space Space menu $') ~= nil }, { 1, 1, true, true },
  "one view, one tab page; the header names it by its tab's number and kind, then the keys that switch: " .. s.header)
eq(s.keyline, ' j/k/h/l move · Enter go · f go+focus · p pin · ? keys ', "the key line: the graph's five keys, as typed")
ok(not popped():find('Enter go', 1, true) and not popped():find('PINNED', 1, true), '… and neither is in the drawing')
eq(pop("return { vim.o.showtabline, vim.o.laststatus }"), { 2, 2 }, '… the tab line always shown, a status line per window')

-- ─── Enter: the editor goes there, the keyboard stays in the pop-out ─────────────────────────────────────────────
press('j')
ok(wait(2000, function() return state().selected == 'callee_of_M.alpha' end), 'j moves the selection, in the pop-out')
eq(host('return vim.api.nvim_win_get_cursor(0)'), { 3, 2 }, '… the editor has not moved')
local mark = #read('hyprctl.log')
local function history_at() return host("return require('desk.popout').host.history.at") end
local at_enter = history_at()
press('<CR>')
ok(wait(3000, function() return host('return vim.api.nvim_win_get_cursor(0)[1]') == 5 end), "Enter: the editor goes to the selected box's function")
s = state()
eq({ s.mode, s.current_win == s.win }, { 'n', true }, '… and the keyboard stays in the pop-out (its window, normal mode)')
-- A focus would come a moment later (hyprctl runs in the background): wait long enough for one to land.
ok(not wait(1500, function() return log_since(mark):find('hl.dsp.focus', 1, true) end), '… and nothing is focused, then or a moment later')
ok(wait(3000, function() return state().title == 'call graph · M.beta' end), 'following: the graph moves to where the editor went')
eq(history_at(), at_enter + 1, '… the Enter one step of the history')
-- H: back to where Enter left from, the editor too; L: there again.
press('H')
ok(wait(3000, function() return vim.deep_equal(host('return vim.api.nvim_win_get_cursor(0)'), { 3, 2 }) end),
  'H in the pop-out: the editor goes back to where Enter left it')
ok(wait(3000, function() return state().title == 'call graph · M.alpha' end), '… and the following graph with it')
eq(history_at(), at_enter, '… one H for the whole Enter')
press('L')
ok(wait(3000, function() return host('return vim.api.nvim_win_get_cursor(0)[1]') == 5 end), 'L: forward again, where Enter went')
ok(wait(3000, function() return state().title == 'call graph · M.beta' end), '… the graph too')

-- ─── what an act may name ───────────────────────────────────────────────────────────────────────────────────────
local gen = state().gen
local function door(msg) return host("return require('desk.bridge').receive(...)", msg) end
local function act(fields) return door(vim.tbl_extend('force', { version = 1, type = 'act', view = 'graph', gen = gen, item = 1, deadline = later(5000) }, fields)) end
eq(act({ gen = gen - 1, action = 'callgraph.go' }), { refused = 'this view moved on' }, 'a stale generation is refused')
eq(act({ action = 'callgraph.back' }), { refused = 'callgraph.back is not one the pop-out may ask for' }, "a row the editor keeps (remote = false) is refused")
eq(act({ action = 'popout.keys' }), { refused = 'popout.keys is not one the pop-out may ask for' }, '… a pop-out row that is not remote too')
eq(act({ action = 'popout.nothing' }), { refused = 'no action is called popout.nothing' }, '… and an id that is no row')
eq(act({ item = 400, action = 'callgraph.go' }), { refused = 'there is no such item in this view' }, '… and an item the view does not have')
eq(act({ action = 'callgraph.go', text = 'hello' }), { refused = 'callgraph.go asks for nothing' }, '… and words for a row that asks none')
eq(door({ version = 1, type = 'act', view = 'graph', gen = gen, item = 1, action = 'callgraph.go' }),
  { refused = 'a pop-out message says when it stops waiting (deadline)' }, 'a message with no deadline is refused')
eq(act({ action = 'callgraph.go', deadline = later(-1000) }), { refused = 'this message came after its sender stopped waiting' },
  '… and one past it')
eq(door({ version = 1, type = 'subscribe', chan = 1, pid = 1, width = 80, protocol = 1, deadline = later(5000) }),
  { refused = 'this editor speaks pop-out protocol 3 and this pop-out 1: close it and open it again' }, 'a pop-out of another protocol is refused')
-- This test's own channel to the editor is not a pop-out's: it never named itself with nvim_set_client_info.
local subscribed = host("return require('desk.popout').host.chan")
eq(door({ version = 1, type = 'subscribe', chan = vim.rpcrequest(h, 'nvim_get_api_info')[1], pid = vim.fn.getpid(), width = 80, protocol = 3,
  deadline = later(5000) }), { refused = 'a pop-out subscribes on its own channel, named with nvim_set_client_info first' },
  'a subscribe on a channel that is no named pop-out is refused')
eq(host("return require('desk.popout').host.chan"), subscribed, '… and the pop-out it has stays')
eq(pop("return require('desk.bridge').receive(...)", { version = 1, type = 'subscribe', chan = 1, pid = 1, width = 80, protocol = 3, deadline = later(5000) }),
  { refused = 'this editor keeps no pop-out' }, 'a pop-out takes no pop-out of its own')
eq(pop("return require('desk.popout').receive({ version = 1, type = 'view.set', id = 'old', gen = 1, lines = { 'x' } })"), false,
  '… and the pop-out takes nothing of another protocol')
vim.rpcrequest(h, 'nvim_input', 'i')
ok(wait(2000, function() return host('return vim.api.nvim_get_mode().mode') == 'i' end), 'the editor in insert mode')
eq(act({ action = 'callgraph.go' }), { refused = 'typing in this editor' }, 'while she types in the editor an act is refused')
vim.rpcrequest(h, 'nvim_input', '<Esc>')
ok(wait(2000, function() return host('return vim.api.nvim_get_mode().mode') == 'n' end), '… normal mode again')
-- Without symdeps (not installed here) its row is refused with why, and gs in the pop-out says so; nothing else happens.
eq(act({ action = 'callgraph.symdeps' }), { refused = 'requires symdeps' }, 'without symdeps: its row says "requires symdeps"')
pop('_G.heard = {}; vim.notify = function(text) table.insert(_G.heard, text) end')
local line_before = host('return vim.api.nvim_win_get_cursor(0)[1]')
press('gs')
ok(wait(2000, function() return vim.tbl_contains(pop('return _G.heard'), 'Requires symdeps.') end), '… gs in the pop-out says "Requires symdeps."')
eq({ host('return vim.api.nvim_win_get_cursor(0)[1]'), state().title }, { line_before, 'call graph · M.beta' }, '… and does nothing else')
eq(act({ action = 'popout.pin' }), { done = true }, 'a remote row runs')
ok(wait(2000, function() return (state().header or ''):find('graph · PINNED', 1, true) end), '… pinned: the header says so')

-- ─── pinned: the editor moving sends nothing; p follows again ───────────────────────────────────────────────────
local received = state().received
vim.rpcrequest(h, 'nvim_input', '8G')
ok(wait(3000, function() return host('return vim.api.nvim_win_get_cursor(0)[1]') == 8 end), 'the editor moves into gamma')
ok(wait(5000, settled), '… and the move has nothing left to send')
eq({ state().received, state().title }, { received, 'call graph · M.beta' }, '… and the pinned graph stays: nothing was sent')
press('p')
ok(wait(3000, function() return state().title == 'call graph · gamma' end), 'p: following again, from where the editor is')
ok(not (state().header or ''):find('graph · PINNED', 1, true), '… no longer pinned')

-- ─── c: the graph of a box, pinned there (the graph tab's c, run in the editor for the pop-out's view) ────────────
press('j')
ok(wait(2000, function() return state().selected == 'callee_of_gamma' end), 'j: the callee')
press('c')
ok(wait(3000, function() return state().title == 'call graph · callee_of_gamma' and popped():find('caller_of_callee_of_gamma', 1, true) end),
  'c: the graph of the selected box, pinned there')
ok((state().header or ''):find('graph · PINNED', 1, true), '… pinned')
-- H: the graph before the centre, following as it was; L: the centred one again, read, pinned.
press('H')
ok(wait(3000, function() return state().title == 'call graph · gamma' and not state().header:find('PINNED', 1, true) end),
  'H: the graph before the centre, following again')
press('L')
ok(wait(3000, function()
  return state().title == 'call graph · callee_of_gamma' and popped():find('caller_of_callee_of_gamma', 1, true) and state().header:find('graph · PINNED', 1, true)
end), 'L: the centred graph again, as it was read, pinned')
press('p')
ok(wait(3000, function() return state().title == 'call graph · gamma' end), 'p: following the editor again')

-- ─── Space Space in the pop-out: the editor's rows for that box ─────────────────────────────────────────────────
press('<Space><Space>')
ok(wait(3000, function() return pop("local m = require('desk.menu')._last; return m ~= nil and vim.api.nvim_win_is_valid(m.win)") end),
  'Space Space opens the home menu in the pop-out')
local menu = pop("return table.concat(vim.api.nvim_buf_get_lines(require('desk.menu')._last.buf, 0, -1, false), '\\n')")
ok(menu:find('Go to the selected function', 1, true) and menu:find('Pin, or follow the editor', 1, true) and menu:find('Back to the editor', 1, true),
  "its rows are the editor's (describe):\n" .. menu)
ok(menu:find('requires symdeps', 1, true), '… a row that cannot run says why')
ok(not menu:find('Live call graph panel', 1, true) and not menu:find('Call graph of this function', 1, true),
  "… but none of the editor's rows that act on its own current window (the panel, a graph of its cursor's function)")
ok(menu:find("The pop-out's keys", 1, true) and menu:find('To the editor', 1, true), "… and so are this window's own")
ok(menu:find(' ── views ', 1, true) == menu:find(' ── ', 1, true) and menu:find('Pop out the call graph', 1, true) and menu:find('Pop out the rows', 1, true),
  '… the views first: every kind')
ok(not menu:find('Back to the code, the graph left open', 1, true) and not menu:find('Home menu', 1, true) and not menu:find('To the pop-out', 1, true),
  '… but no row the pop-out may not ask for')
ok(pop("return vim.inspect(vim.api.nvim_win_get_config(require('desk.menu')._last.win).title)"):find('Home · pop-out · gamma', 1, true),
  '… titled with the selected box')
pop([[local m = require('desk.menu')._last
  for i, line in ipairs(vim.api.nvim_buf_get_lines(m.buf, 0, -1, false)) do
    if line:find('Pin, or follow', 1, true) and line:sub(1, 2) == '  ' then vim.api.nvim_win_set_cursor(m.win, { i, 0 }) end
  end]])
press('<CR>')
ok(wait(3000, function() return (state().header or ''):find('graph · PINNED', 1, true) end), 'a row run from that menu acts in the editor (pinned)')

-- ─── ? lists the pop-out's keys, from its rows ─────────────────────────────────────────────────────────────────
press('?')
ok(wait(2000, function() return pop("return vim.api.nvim_win_get_config(0).relative ~= ''") end), '? opens a list in the pop-out')
local keys = pop("return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')")
ok(keys:find('j/k%s+The box below / above') and keys:find('Enter%s+Go to the selected function') and keys:find('f/Shift%+Enter%s+Go to it, in the editor')
  and keys:find('Space Tab%s+To the editor') and keys:find('Space Space%s+Home menu') and keys:find('q%s+Close this view')
  and keys:find('gt/gT%s+The next / previous view') and keys:find('H/BS%s+Back') and keys:find('L%s+Forward'),
  "… the graph's keys and the window's, as typed, with the rows' names:\n" .. keys)
ok(not keys:find('Back to the code', 1, true) and not keys:find('Read the graph again', 1, true), "… and none of the editor's own")
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
vim.rpcrequest(h, 'nvim_input', 'gg')
ok(wait(2000, function() return host('return vim.api.nvim_win_get_cursor(0)[1]') == 1 end), 'the editor moves away again')
mark = #read('hyprctl.log')
press('f')
ok(wait(3000, function() return host('return vim.api.nvim_win_get_cursor(0)[1]') == 8 end), 'f, as Shift+Enter: the editor goes to the box')
ok(wait(3000, function() return log_since(mark):find("dispatch hl.dsp.focus({ window = 'address:0xa1' })", 1, true) end), '… and gets the keyboard')

-- ─── a pop-out that stops answering ─────────────────────────────────────────────────────────────────────────────
ok(wait(3000, function() return host("return require('desk.popout').host.stalled") == false end), 'answering its pings')
-- Asleep for longer than two pings (1 s here), so one of them goes unanswered for a whole ping whenever it was sent.
pop('vim.defer_fn(function() vim.uv.sleep(2500) end, 10)')
ok(wait(5000, function() return host("return require('desk.popout').host.stalled") == true end), 'stuck: the editor stops sending to it')
ok(wait(8000, function() return host("return require('desk.popout').host.stalled") == false end), '… until it answers again')

-- ─── detach and attach ──────────────────────────────────────────────────────────────────────────────────────────
local panel_open = "local G = require('desk.callgraph'); return G.panel.win ~= nil and vim.api.nvim_win_is_valid(G.panel.win)"
press('o')
ok(wait(3000, function() return host(panel_open) end), 'o in the pop-out: the graph comes back as a split in the editor (the live panel)')
eq(host("local G = require('desk.callgraph'); return { G.panel.pinned, G.panel.graph and G.panel.graph.center.name }"), { true, 'gamma' },
  '… pinned to the same graph')
ok(wait(3000, function() return state().shown == '' and popped():find('Space Space › views opens one', 1, true) end),
  '… and the pop-out shows nothing, saying how to open one')
host("vim.api.nvim_set_current_win(require('desk.callgraph').panel.win)")
vim.rpcrequest(h, 'nvim_input', 'o')
ok(wait(3000, function() return state().title == 'call graph · gamma' end), 'o in the panel: the graph goes to the pop-out again')
eq(host(panel_open), false, '… and leaves the editor')
ok((state().header or ''):find('graph · PINNED', 1, true), '… still pinned')
host("vim.api.nvim_set_current_win(_G.popout_test.code_win); vim.api.nvim_win_set_cursor(0, { 3, 2 }); require('desk.callgraph').open_cursor()")
ok(wait(3000, function() return host("local v = require('desk.callgraph').view(); return v ~= nil and v.graph.callees ~= nil") end),
  'a graph tab of M.alpha')
vim.rpcrequest(h, 'nvim_input', 'o')
ok(wait(3000, function() return state().title == 'call graph · M.alpha' end), 'o in the graph tab: the graph moves to the pop-out')
eq(host("return require('desk.callgraph').view() == nil"), true, '… and the tab closes')
ok((state().header or ''):find('graph · PINNED', 1, true), '… pinned: a tab shows one chosen function')

-- ─── a second kind: a list of rows (tests/popout_rows.lua), built from the kind interface alone ──────────────────
host("require('desk.popout').show('rows', require('desk.actions').context())")
ok(wait(3000, function() return state().kind == 'rows' end), 'a view of another kind comes to the front')
s = state()
eq({ s.shown, s.selected, s.title, host('return _G.rows_test.opens') }, { 'rows', 'alpha', 'rows', 1 }, '… opened by its kind, its first row selected')
eq({ s.tabs, s.tab, s.keyline }, { 2, 2, ' Enter open ' }, '… in a tab page of its own, the second, with its own key line')
ok(s.header:find(' 1 graph · PINNED   2 rows ', 1, true), '… the header names both, the graph PINNED: ' .. s.header)
-- Saved a moment later (the writes of a moment go as one), the rows in front.
ok(wait(3000, function() return record().activeTab == 'rows' end), '… and the layout record has the rows in front')
local function strip_lines() local l = state().lines; return { l[11], l[12] } end
eq(strip_lines(), { ' │ alpha', ' │ about alpha' }, '… its strip says what the selected row is')
press('j')
ok(wait(2000, function() return state().selected == 'beta' end), 'j: the next row (here, not in the editor)')
eq(strip_lines(), { ' │ beta', ' │ about beta' }, '… and the strip follows')
press('j')
ok(wait(2000, function() return state().selected == 'gamma' end), 'j again: over the blank line and the heading, to the next row')
eq(pop('return vim.api.nvim_win_get_cursor(0)'), { 8, 3 }, '… the cursor on it')
press('k')
ok(wait(2000, function() return state().selected == 'beta' end), 'k: back over them')
press('<CR>')
ok(wait(2000, function() return host('return _G.rows_test.opened') == 'beta' end), 'Enter: its row runs in the editor, for the row selected here')
pop("vim.ui.input = function(opts, done) _G.asked = opts.prompt; done('make it pink') end")
press('c')
ok(wait(2000, function() return vim.deep_equal(host('return _G.rows_test.said'), { 'beta', 'make it pink' }) end),
  'c: its words are asked for here, and go with the row')
eq(pop('return _G.asked'), 'About it: ', "… asked with the editor's question")
pop("vim.ui.select = function(items, opts, done) _G.offered = vim.tbl_map(function(c) return c.id .. '=' .. c.name end, items); done(items[2]) end")
press('x')
ok(wait(2000, function() return vim.deep_equal(host('return _G.rows_test.picked'), { 'beta', 'two', 'make it pink' }) end),
  'x: a pick, then words, asked here')
eq(pop('return _G.offered'), { 'one=The first', 'two=The second' }, '… from the choices the editor offers')
local rows_gen = state().gen
local function rows_act(fields) return act(vim.tbl_extend('force', { view = 'rows', gen = rows_gen, item = 2 }, fields)) end
eq(rows_act({ action = 'rowstest.here' }), { refused = 'rowstest.here is not one the pop-out may ask for' }, "the row the editor keeps is refused")
eq({ rows_act({ action = 'callgraph.open' }), rows_act({ action = 'callgraph.panel' }) },
  { { refused = 'callgraph.open is not one the pop-out may ask for' }, { refused = 'callgraph.panel is not one the pop-out may ask for' } },
  "… and so are the editor's rows that read its current window: they would act there, not on the row selected here")
eq(rows_act({ action = 'rowstest.say' }), { refused = 'Say something about the row: needs its words' }, '… one without the words it asks for')
eq(rows_act({ action = 'rowstest.pick', text = 'why not', choice = 'three' }), { refused = 'that choice is not offered here' },
  '… and a pick it does not offer')
eq(pop("return { vim.fn.maparg('z', 'n'), vim.fn.maparg('c', 'n', false, true).desc }"), { '', 'Say something about the row' },
  "the editor's own row has no key here; the others do")
-- The editor moves the selection (select); drawn again with a row above, the selection stays on its row.
host("_G.rows_test.names = { 'alpha', 'new', 'beta', 'gamma' }; local P = require('desk.popout'); local v = P.host.views.rows; v.select = 'row:gamma'; P.redraw(v)")
ok(wait(2000, function() return state().selected == 'gamma' end), 'the editor selects a row: the pop-out goes there')
host("_G.rows_test.names = { 'zero', 'alpha', 'new', 'beta', 'gamma' }; local P = require('desk.popout'); P.redraw(P.host.views.rows)")
ok(wait(2000, function() return popped():find('○ zero', 1, true) end), 'drawn again with a row above')
eq(state().selected, 'gamma', '… the selection stays on its row')
-- Two views: one drawn again behind the other stays behind.
local behind = state().received
host("local P = require('desk.popout'); local v = P.host.views.graph; v.sent = nil; P.redraw(v)")
ok(wait(2000, function() return state().received > behind end), 'the graph is drawn again')
eq(state().shown, 'rows', '… behind: the rows keep the window')
-- gt, gT and a count switch views; H goes back to the view before, L forward.
press('gT')
ok(wait(2000, function() return state().shown == 'graph' and state().tab == 1 end), 'gT: the previous view, the graph')
press('gt')
ok(wait(2000, function() return state().shown == 'rows' and state().tab == 2 end), 'gt: the next, the rows')
press('1gt')
ok(wait(2000, function() return state().shown == 'graph' end), '1gt: the first view')
ok(wait(2000, function() return host("return require('desk.popout').host.front") == 'graph' end), '… and the editor knows which is in front')
ok(wait(3000, function() return record().activeTab == 'graph' end), '… and so does the layout record')
press('H')
ok(wait(2000, function() return state().shown == 'rows' end), 'H: back to the view before')
press('L')
ok(wait(2000, function() return state().shown == 'graph' end), 'L: forward again')
press('gt')
ok(wait(2000, function() return state().shown == 'rows' end), 'gt: the rows again')
-- Something new in a view behind: the pinned graph's file saved, so it is read again; its name is marked until she looks.
host("vim.api.nvim_set_current_win(_G.popout_test.code_win); vim.cmd('silent write')")
ok(wait(3000, function() return state().header:find('graph · PINNED ✱', 1, true) end), 'the graph read again behind: ✱ after its name')
pop("vim.g.desk_style = 'retro'; vim.cmd('redrawtabline')")
s = state()
ok(s.header:find(' 1 GRAPH·PINNED %* │ 2 ROWS ') and s.header:find('│ gt VIEWS · Space Space MENU ', 1, true),
  'retro: capitals, │ between views, * for news; the keys as typed: ' .. s.header)
pop("vim.g.desk_style = 'paper'; vim.cmd('redrawtabline')")
press('gT')
ok(wait(2000, function() return state().shown == 'graph' and not state().header:find('✱', 1, true) end), 'looked at: the mark goes')
press('gt')
ok(wait(2000, function() return state().shown == 'rows' end), 'and back to the rows')
press('?')
ok(wait(2000, function() return pop("return vim.api.nvim_win_get_config(0).relative ~= ''") end), '? lists the keys of the rows')
keys = pop("return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')")
ok(keys:find('Enter%s+Open the row') and keys:find('c%s+Say something about the row') and keys:find('x%s+Pick for the row')
  and keys:find('Space Space%s+Home menu') and not keys:find("The editor's own", 1, true), "… its own and the window's:\n" .. keys)
press('q')
ok(wait(2000, function() return state().current_win == state().win end), '… q closes the list')
press('o')
ok(wait(2000, function() return host('return _G.rows_test.attached') == 'rows' end), 'o: its kind takes it back to the editor')
ok(wait(2000, function() return state().shown == 'graph' end), '… and the pop-out shows the other view')
eq(host("return { _G.rows_test.closed, require('desk.popout').host.views.rows == nil }"), { 'rows', true }, '… the rows view is gone from the editor')
eq(state().tabs, 1, '… and its tab from the pop-out')
-- q closes the view it is pressed in; the others stay.
host("require('desk.popout').show('rows', require('desk.actions').context())")
ok(wait(3000, function() return state().shown == 'rows' and state().tabs == 2 end), 'the rows again, in a second tab')
press('q')
ok(wait(3000, function() return state().tabs == 1 and state().shown == 'graph' end), 'q: this view closes, its tab with it')
eq(host("return require('desk.popout').host.order"), { 'graph' }, '… and the editor keeps the other')
-- The layout record (desk-work workspace, client popout): the views, pins, functions and the screen, written a moment
-- after the last change (the writes of a moment go as one).
ok(wait(3000, function()
  local r = record()
  return #(r.tabs or {}) == 1 and r.tabs[1].target ~= nil and r.tabs[1].target.name == 'M.alpha'
end), 'the layout record follows the views: ' .. read(record_file()))
local saved = record()
eq({ saved.tabs[1].kind, saved.tabs[1].pinned, saved.tabs[1].target, saved.activeTab, saved.show.screen },
  { 'graph', true, { file = dir .. '/sample.lua', line = 2, name = 'M.alpha' }, 'graph', 'DP-2' },
  '… the pinned graph by its function, the view in front, the screen it is on')

-- ─── q on the last view: the pop-out closes, the editor stops sending ─────────────────────────────────────────────
mark = #read('hyprctl.log')
vim.rpcnotify(p, 'nvim_input', 'q')
ok(wait(5000, function() return host("return require('desk.popout').host.chan") == vim.NIL end), 'q on the last view: the editor forgets the pop-out')
ok(wait(3000, function() return log_since(mark):find("dispatch hl.dsp.focus({ window = 'address:0xa1' })", 1, true) end),
  "… and the keyboard comes back to the editor's window, not the pop-out's empty screen")
ok(wait(5000, function() return not exists(psock) end), '… which quits')
eq(host("return next(require('desk.popout').host.views) == nil"), true, '… and nothing is kept to send it')
eq(host(panel_open), false, '… nor brought back: she closed it')

-- ─── the notebook's call graph: desk-work editor's callgraph { root, file, line, name } ──────────────────────────
local function notebook(fields)
  return door(vim.tbl_extend('force', { version = 1, type = 'callgraph', root = dir, file = dir .. '/sample.lua', line = 8, name = 'gamma',
    deadline = later(5000) }, fields or {}))
end
vim.fn.mkdir(dir .. '/elsewhere', 'p')
eq(notebook({ root = dir .. '/elsewhere' }), { refused = 'another project' }, 'the notebook names a function outside the checkout: refused')
eq(notebook({ file = dir .. '/gone.lua' }), { refused = 'that file is not on disk' }, '… and one in a file that is not there')
host("package.loaded['desk.review'] = { current = true }")
eq(notebook(), { refused = 'a review is open' }, '… and into the panel while a review is open')
host("package.loaded['desk.review'] = nil")
vim.rpcrequest(h, 'nvim_input', 'i')
ok(wait(2000, function() return host('return vim.api.nvim_get_mode().mode') == 'i' end), 'the editor in insert mode')
eq(notebook(), { refused = 'typing in this editor' }, '… and while she types')
vim.rpcrequest(h, 'nvim_input', '<Esc>')
ok(wait(2000, function() return host('return vim.api.nvim_get_mode().mode') == 'n' end), '… normal mode again')
eq(notebook(), { shown = 'panel' }, 'with no pop-out, the function it names opens in the panel beside the code')
ok(wait(3000, function()
  return host("local G = require('desk.callgraph'); return G.panel.pinned and G.panel.graph and G.panel.graph.center and G.panel.graph.center.name") == 'gamma'
end), '… pinned on it')
host("require('desk.callgraph').panel_close()")

-- ─── its screen unplugged: to another screen, else back here ─────────────────────────────────────────────────────
local three = { { name = 'eDP-1', focused = true, activeWorkspace = { id = 1 } }, { name = 'DP-2', focused = false, activeWorkspace = { id = 5 } },
  { name = 'HDMI-A-1', focused = false, activeWorkspace = { id = 7 } } }
write(dir .. '/monitors.json', vim.json.encode(three))
vim.fn.writefile({ 'PRIMARY="eDP-1"', 'PORTRAIT_OUTPUTS=""', 'SECONDARY_OUTPUTS="DP-2 HDMI-A-1"' }, sidecar)
os.remove(dir .. '/kitty.listen')
open_row()
opened()
ok(wait(10000, function() return state().connected and state().title:find('call graph', 1, true) end), 'opened again, with three screens')
ok(wait(5000, function() return host("return require('desk.popout').host.screen") == 'DP-2' end), '… placed on DP-2')
host("_G.heard = {}; vim.notify = function(text) table.insert(_G.heard, text) end")
mark = #read('hyprctl.log')
write(dir .. '/monitors.json', vim.json.encode({ three[1], three[3] }))
vim.fn.writefile({ 'PRIMARY="eDP-1"', 'PORTRAIT_OUTPUTS=""', 'SECONDARY_OUTPUTS="HDMI-A-1"' }, sidecar)
ok(wait(5000, function()
  return log_since(mark):find("dispatch hl.dsp.window.move({ workspace = '7', follow = false, window = 'address:0xb2' })", 1, true)
end), "DP-2 unplugged (desk-monitor rewrote its sidecar): the pop-out moves to the screen left that is not the editor's")
ok(wait(3000, function() return vim.tbl_contains(host('return _G.heard'), 'The pop-out moved to HDMI-A-1: DP-2 was unplugged.') end), '… and says so')
eq({ host("return require('desk.popout').host.screen"), state().connected }, { 'HDMI-A-1', true }, '… still open, now on HDMI-A-1')
press('p')
ok(wait(3000, function() return state().header:find('graph · PINNED', 1, true) end), 'pinned there')
-- A second view beside it, the graph in front: the layout record keeps both.
host("require('desk.popout').show('rows', require('desk.actions').context())")
ok(wait(3000, function() return state().tabs == 2 end), 'the rows beside it')
press('gT')
ok(wait(3000, function() return state().shown == 'graph' end), '… the graph in front')
ok(wait(3000, function() local r = record(); return #(r.tabs or {}) == 2 and r.activeTab == 'graph' end), '… both in the layout record')
write(dir .. '/monitors.json', vim.json.encode({ three[1] }))
vim.fn.writefile({ 'PRIMARY="eDP-1"', 'PORTRAIT_OUTPUTS=""', 'SECONDARY_OUTPUTS=""' }, sidecar)
ok(wait(5000, function() return host("return require('desk.popout').host.chan") == vim.NIL end), 'HDMI-A-1 unplugged too, one screen left: the pop-out closes')
ok(wait(3000, function() return host(panel_open) end), '… its pinned graph back in the editor, as the panel')
ok(vim.tbl_contains(host('return _G.heard'), 'HDMI-A-1 was unplugged. Its pinned view is back here.'), '… one notice says why: '
  .. vim.inspect(host('return _G.heard')))
ok(wait(5000, function() return not exists(psock) end), '… and the pop-out quits')
host("require('desk.callgraph').panel_close()")
write(dir .. '/monitors.json', vim.json.encode({ three[1], three[2] }))
vim.fn.writefile(vim.split(two_screens, '\n', { trimempty = true }), sidecar)
-- Plugged in again: Restore brings back both views it had, in their order, the graph in front as it was.
ok(wait(5000, function() return host("return require('desk.actions').get('popout.restore').name") == 'Restore 2 views' end),
  'plugged in again, the Views group offers Restore 2 views')
os.remove(dir .. '/kitty.listen')
host("_G.rows_test.restored = 0; local A = require('desk.actions'); A.get('popout.restore').run(A.context())")
opened()
ok(wait(10000, function() return state().tabs == 2 and state().shown == 'graph' end), '… both views come back, the graph in front: '
  .. tostring(state().tabs) .. ' tabs')
ok(wait(5000, function() return state().header:find(' 1 graph · PINNED   2 rows ', 1, true) end), '… in their order: ' .. tostring(state().header))
eq(host('return _G.rows_test.restored'), 1, '… the rows restored by their kind')
-- Gone on its own right after a change (a write of the views still on its way): the record keeps both views.
host("local P = require('desk.popout'); P.save_layout(); P.fold('the screen went')")
ok(wait(5000, function() return not exists(psock) end), 'folded right after a change: the pop-out closes')
ok(wait(5000, writes_landed), '… the write that was on its way has landed')
eq(#(record().tabs or {}), 2, '… and the layout record still holds both views for the next Restore')
host("require('desk.callgraph').panel_close()")

-- ─── the notebook's call graph with the pop-out open ─────────────────────────────────────────────────────────────
os.remove(dir .. '/kitty.listen')
open_row()
opened()
ok(wait(10000, function() return state().connected and state().title:find('call graph', 1, true) end), 'opened again')
eq(notebook(), { shown = 'popout' }, 'the notebook names a function while the pop-out is open: it shows there')
ok(wait(3000, function() return state().title == 'call graph · gamma' and state().header:find('graph · PINNED', 1, true) end), '… pinned on it')
press('p')
ok(wait(3000, function() return not state().header:find('PINNED', 1, true) end), 'p: following the editor again')

-- ─── the editor closing: the pop-out says so and quits; nothing else of it runs while the editor exits ────────────
-- A cursor moved during the exit (BufUnload comes before VimLeavePre) asks the language server nothing for it.
host([[
  local dir = os.getenv('POPOUT_TEST')
  local done = false
  vim.api.nvim_create_autocmd('BufUnload', { callback = function()
    if done then return end
    done = true
    local before = #_G.popout_test.requests
    pcall(vim.api.nvim_win_set_cursor, _G.popout_test.code_win, { 8, 2 })
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    vim.wait(800)
    vim.fn.writefile({ tostring(#_G.popout_test.requests - before) }, dir .. '/exiting.txt')
  end })
]])
host("vim.api.nvim_set_current_win(_G.popout_test.code_win); vim.api.nvim_win_set_cursor(0, { 3, 2 })")
ok(wait(3000, function() return state().title == 'call graph · M.alpha' end), 'following M.alpha')
pop("require('desk.popout').LINGER_MS = 4000")
vim.rpcnotify(h, 'nvim_command', 'qa!')
ok(wait(6000, function() return state().closing == 'Editor closed.' end), 'the editor closing: the pop-out says "Editor closed."')
-- The pop-out is a detached child of the editor: the editor exits at once, never waiting for it.
ok(host_job:wait(3000).code == 0 and exists(psock), '… the editor exits while the pop-out is still open')
eq(vim.trim(read('exiting.txt')), '0', '… and the cursor moved while it exited asked nothing for the pop-out')
ok(wait(10000, function() return not exists(psock) end), '… which then quits')

-- ─── after a restart: the pop-out's views offered again ──────────────────────────────────────────────────────────
saved = record()
eq({ #(saved.tabs or {}), saved.tabs and saved.tabs[1].kind, saved.tabs and saved.tabs[1].pinned, saved.show and saved.show.screen },
  { 1, 'graph', false, 'DP-2' }, 'the editor closing wrote the layout: its view and its screen')
-- Three screens now, HDMI-A-1 listed first: a new pop-out would go there, a restored one goes back to DP-2.
write(dir .. '/monitors.json', vim.json.encode(three))
vim.fn.writefile({ 'PRIMARY="eDP-1"', 'PORTRAIT_OUTPUTS=""', 'SECONDARY_OUTPUTS="HDMI-A-1 DP-2"' }, sidecar)
local again = vim.system({ 'nvim', '--headless', '--clean', '--listen', dir .. '/h2', '--cmd', 'luafile ' .. dir .. '/loader.lua',
  '-c', 'luafile ' .. here .. 'popout_host.lua' }, { text = true, env = env, clear_env = true })
h = assert(connect(dir .. '/h2'), 'the second editor never listened')
ok(wait(10000, function() return host('return _G.popout_test and _G.popout_test.ready') == true end), 'an editor starts again')
ok(wait(5000, function() return host("return require('desk.actions').get('popout.restore').name") == 'Restore 1 view' end),
  "… its Views group offers the pop-out's last view: Restore 1 view")
eq(host("local A = require('desk.actions'); return A.available(A.get('popout.restore'), A.context())"), true, '… which it can')
os.remove(dir .. '/kitty.listen')
host("local A = require('desk.actions'); A.get('popout.restore').run(A.context())")
opened()
ok(wait(10000, function() return state().connected and state().title == 'call graph · M.alpha' and state().state == 'following' end),
  '… restored: the graph, following this editor')
ok(wait(5000, function() return host("return require('desk.popout').host.screen") == 'DP-2' end), '… on the screen it was on')
eq(host("local A = require('desk.actions'); return A.available(A.get('popout.restore'), A.context())"), false, '… and not offered while it is open')
vim.rpcnotify(h, 'nvim_command', 'qa!')
ok(again:wait(5000).code == 0, 'the second editor closes')
ok(wait(10000, function() return not exists(psock) end), '… and its pop-out quits')

-- ─── kitty's exit is the pop-out's end ───────────────────────────────────────────────────────────────────────────
-- A third editor. kitty.fail in the test's folder makes the kitty stub fail at once; protocol makes the pop-out speak
-- another protocol (the editor refuses it; it says why there, and quits).
local third = vim.system({ 'nvim', '--headless', '--clean', '--listen', dir .. '/h3', '--cmd', 'luafile ' .. dir .. '/loader.lua',
  '-c', 'luafile ' .. here .. 'popout_host.lua' }, { text = true, env = env, clear_env = true })
h = assert(connect(dir .. '/h3'), 'the third editor never listened')
ok(wait(10000, function() return host('return _G.popout_test and _G.popout_test.ready') == true end), 'a third editor')
host("_G.heard = {}; vim.notify = function(text) table.insert(_G.heard, text) end")
local function heard() return host('return _G.heard') end
do
  -- kitty does not start: the graph o took from its tab comes back, and the editor says so.
  write(dir .. '/kitty.fail', '1')
  host("vim.api.nvim_set_current_win(_G.popout_test.code_win); vim.api.nvim_win_set_cursor(0, { 3, 2 }); require('desk.callgraph').open_cursor()")
  ok(wait(3000, function() return host("local v = require('desk.callgraph').view(); return v ~= nil and v.graph.callees ~= nil") end),
    'a graph tab of M.alpha')
  vim.rpcrequest(h, 'nvim_input', 'o')
  ok(wait(5000, function() return vim.tbl_contains(heard(), 'The pop-out did not start. Its view is back here.') end),
    'o in the graph tab, and kitty does not start: the editor says the pop-out did not start: ' .. vim.inspect(heard()))
  eq(host("local P = require('desk.popout'); return { next(P.host.views) == nil, P.host.opening == nil }"), { true, true },
    '… keeps no view for it, and no pop-out on its way')
  eq(host("local G = require('desk.callgraph'); return { G.panel.win ~= nil and vim.api.nvim_win_is_valid(G.panel.win), G.panel.pinned, G.panel.graph and G.panel.graph.center.name }"),
    { true, true, 'M.alpha' }, '… and the graph the tab sent is back here: the panel, pinned on M.alpha')
  host("require('desk.callgraph').panel_close()")
  os.remove(dir .. '/kitty.fail')
  -- A pop-out the editor refuses (another protocol) says why there and quits: the same here.
  write(dir .. '/protocol', '2')
  host("_G.heard = {}")
  open_row()
  ok(wait(10000, function() return vim.tbl_contains(heard(), 'The pop-out did not start. Its view is back here.') end),
    'a pop-out of another protocol, refused: the editor says it did not start: ' .. vim.inspect(heard()))
  eq(host("return next(require('desk.popout').host.views) == nil"), true, '… keeps no view for it')
  eq(host(panel_open), true, '… and the graph it asked for is here instead, as the live panel')
  host("require('desk.callgraph').panel_close()")
  os.remove(dir .. '/protocol')
  -- Its window closed from outside (its kitty gone), then a view asked for at once, before any ping: a new pop-out.
  os.remove(dir .. '/kitty.listen')
  open_row()
  opened()
  ok(wait(10000, function() return state().connected and (state().title or ''):find('call graph', 1, true) end), 'a pop-out again')
  press('p')
  ok(wait(3000, function() return (state().header or ''):find('graph · PINNED', 1, true) end), '… its graph pinned')
  local count = tonumber(vim.trim(read('kitty.count')))
  host("_G.heard = {}")
  os.remove(dir .. '/kitty.listen')
  host([[local P = require('desk.popout')
    P.host.timer:stop()
    vim.uv.kill(P.host.kitty, 'sigterm')
    vim.wait(3000, function() return P.host.chan == nil end)
    P.show('rows', require('desk.actions').context())]])
  ok(wait(5000, function() return tonumber(vim.trim(read('kitty.count'))) == count + 1 end),
    'its window closed from outside, and a view asked for at once: a new pop-out starts')
  opened()
  ok(wait(10000, function() return state().connected and state().kind == 'rows' end), '… and shows it')
  ok(vim.tbl_contains(heard(), 'The pop-out closed. Its pinned view is back here.'),
    '… the old one closed: its pinned graph back here: ' .. vim.inspect(heard()))
  eq(host(panel_open), true, '… as the panel')
  host("require('desk.callgraph').panel_close()")
end

-- ─── the editor never drops a pop-out that is still there ────────────────────────────────────────────────────────
do
  -- A kind's mark with a field written by name could not be sent as it was: it goes as plain data, and the pop-out is
  -- never taken for closed.
  host("_G.heard = {}; _G.rows_test.named_mark = true; require('desk.popout').show('rows', require('desk.actions').context())")
  -- One drawing per view every 50 ms: this one may go a moment later.
  wait(3000, function() return host("local v = require('desk.popout').host.views.rows; return not (v and v.queued)") end)
  eq({ host("return require('desk.popout').host.chan ~= nil"), heard() }, { true, {} },
    'a kind with a mark written by name: the pop-out is kept, nothing said')
  ok(wait(3000, function()
    return pop("return #vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace('desk_popout'), { 3, 0 }, { 3, -1 }, {})") > 0
  end), '… and that mark is drawn there')
  host("_G.rows_test.named_mark = nil")
  -- The editor counts one view, the pop-out two (a clear still on its way): q there on the one the editor has is its
  -- last, and the pop-out is told so: never left on screen with every key refused.
  host("require('desk.popout').show('graph', require('desk.actions').context())")
  ok(wait(3000, function() return state().tabs == 2 and state().shown == 'graph' end), 'two views there, the graph in front')
  host([[local P = require('desk.popout'); P.host.views.rows = nil
    for i, id in ipairs(P.host.order) do if id == 'rows' then table.remove(P.host.order, i) end end]])
  press('q')
  ok(wait(5000, function() return host("return require('desk.popout').host.chan") == vim.NIL end),
    'q on the view the editor counts last: the editor forgets the pop-out')
  ok(wait(5000, function() return not exists(psock) end), '… and the pop-out, told so, quits')
end

-- ─── a pop-out that stops answering misses nothing for good ─────────────────────────────────────────────────────
do
  os.remove(dir .. '/kitty.listen')
  open_row()
  opened()
  ok(wait(10000, function() return state().connected and (state().title or ''):find('call graph', 1, true) end), 'a pop-out again')
  host("require('desk.popout').show('rows', require('desk.actions').context())")
  ok(wait(3000, function() return state().tabs == 2 end), '… with two views')
  pop('vim.defer_fn(function() vim.uv.sleep(4000) end, 10)')
  ok(wait(5000, function() return host("return require('desk.popout').host.stalled") == true end), 'it stops answering')
  host("require('desk.popout').clear('rows')")
  ok(wait(8000, function() return host("return require('desk.popout').host.stalled") == false end),
    '… a view is taken off meanwhile, and it answers again')
  ok(wait(3000, function() return state().tabs == 1 and vim.deep_equal(state().views, { 'graph' }) end),
    '… and that view is gone there too')
end

-- ─── q on its last view, while the editor refuses its acts ───────────────────────────────────────────────────────
do
  press('p')
  ok(wait(3000, function() return (state().header or ''):find('graph · PINNED', 1, true) end), 'the graph pinned')
  host("_G.heard = {}")
  vim.rpcrequest(h, 'nvim_input', 'i')
  ok(wait(2000, function() return host('return vim.api.nvim_get_mode().mode') == 'i' end), 'the editor in insert mode: it refuses acts')
  local mark = #read('hyprctl.log')
  vim.rpcnotify(p, 'nvim_input', 'q')
  ok(wait(5000, function() return not exists(psock) end), 'q on its last view: the pop-out goes all the same')
  ok(wait(3000, function() return host("return require('desk.popout').host.chan") == vim.NIL end), '… and the editor knows')
  vim.wait(500)
  eq({ heard(), host(panel_open) }, { {}, false }, '… as her closing it: nothing said, nothing brought back')
  ok(wait(3000, function() return log_since(mark):find("dispatch hl.dsp.focus({ window = 'address:0xa1' })", 1, true) end),
    '… and the keyboard is back here')
  vim.rpcrequest(h, 'nvim_input', '<Esc>')
  ok(wait(2000, function() return host('return vim.api.nvim_get_mode().mode') == 'n' end), '… normal mode again')
end

-- ─── a layout record belongs to the checkout its pop-out opened in ──────────────────────────────────────────────
do
  local roots = {}
  for _, name in ipairs({ 'A', 'B' }) do
    vim.fn.mkdir(dir .. '/' .. name .. '/.git', 'p')
    vim.fn.writefile({ 'notes' }, dir .. '/' .. name .. '/notes.txt')
    roots[name] = uv.fs_realpath(dir .. '/' .. name)
  end
  -- B has a record of its own, from before.
  write(record_file(roots.B), vim.json.encode({ version = 1, tabs = { { kind = 'rows', pinned = true, target = { file = 'rows', line = 1, name = 'rows' } },
    { kind = 'graph', pinned = false } } }))
  local function offered() return host("return require('desk.actions').get('popout.restore').name") end
  host("vim.api.nvim_set_current_win(_G.popout_test.code_win); vim.cmd.edit(vim.fn.fnameescape(...))", dir .. '/A/notes.txt')
  ok(wait(3000, function() return offered() == "Restore the pop-out's views" end), 'a file of checkout A in front: A has no views to restore')
  local logged = #read('workspace.log')
  os.remove(dir .. '/kitty.listen')
  host("require('desk.popout').show('rows', require('desk.actions').context())")
  opened()
  ok(wait(10000, function() return state().connected and state().kind == 'rows' end), 'a pop-out opened from A')
  host("vim.cmd.edit(vim.fn.fnameescape(...))", dir .. '/B/notes.txt')
  ok(wait(3000, function() return offered() == 'Restore 2 views' end), "B's file in front: B's record is read")
  press('p')
  ok(wait(3000, function() local r = record(roots.A); return r.tabs and r.tabs[1] and r.tabs[1].pinned == true end),
    "… the pop-out's view pinned: written under A, the pop-out's checkout")
  local writes = read('workspace.log'):sub(logged + 1)
  ok(not writes:find('--root ' .. roots.B .. ' --client popout --input', 1, true), '… never under B:\n' .. writes)
  eq(#(record(roots.B).tabs or {}), 2, "… and B's own record is as it was")
  vim.rpcnotify(p, 'nvim_input', 'q')
  ok(wait(5000, function() return not exists(psock) end), 'closed with B in front')
  vim.wait(500)
  eq({ offered(), #(record(roots.B).tabs or {}) }, { 'Restore 2 views', 2 }, "… Restore offers B's views, still B's own")
  host("vim.cmd.edit(vim.fn.fnameescape(...))", dir .. '/A/notes.txt')
  ok(wait(3000, function() return offered() == "Restore the pop-out's views" end), "back in A: A's record, none (its last view was closed)")
end

-- ─── the layout record: one write at a time, the newest last; a write that fails is said ────────────────────────
do
  host("vim.api.nvim_set_current_win(_G.popout_test.code_win); vim.cmd.edit(vim.fn.fnameescape(...))", dir .. '/sample.lua')
  os.remove(dir .. '/kitty.listen')
  host("require('desk.popout').show('rows', require('desk.actions').context())")
  opened()
  ok(wait(10000, function() return state().connected and state().kind == 'rows' end), 'a pop-out with a view, following')
  ok(wait(3000, function() local r = record(); return r.tabs and r.tabs[1] and r.tabs[1].pinned == false end), '… in the record')
  -- A write held up (the stub sleeps), and the view pinned meanwhile: the record ends pinned, never the older state.
  write(dir .. '/workspace.slow', '1')
  host("require('desk.popout').save_layout()")
  ok(wait(3000, function() return exists(dir .. '/workspace.started') end), 'a write of the layout is held up')
  press('p')
  vim.wait(2500)
  ok(wait(3000, function() local r = record(); return r.tabs and r.tabs[1] and r.tabs[1].pinned == true end),
    '… the view pinned meanwhile: the record ends pinned, not the older state written after it: ' .. read(record_file()))
  -- A write that fails is said.
  write(dir .. '/workspace.fail', '1')
  host("_G.heard = {}")
  press('p')
  ok(wait(3000, function() return vim.tbl_contains(heard(), "The pop-out's views were not saved: cannot write the record.") end),
    'a write that fails is said: ' .. vim.inspect(heard()))
  os.remove(dir .. '/workspace.fail')
end

-- ─── an ask of the pop-out's never waits on an editor held up ───────────────────────────────────────────────────
do
  -- The editor busy 1.5 s: an ask of 100 ms comes back "did not answer in time" after about that, not once the editor is
  -- free again (what it reads then, past the deadline, it refuses).
  host("vim.defer_fn(function() vim.uv.sleep(1500) end, 20)")
  vim.wait(200)
  local took = pop("local t = vim.uv.hrtime(); local a = require('desk.popout').request({ type = 'describe' }, 100); return { math.floor((vim.uv.hrtime() - t) / 1e6), a.refused }")
  ok(type(took) == 'table' and took[1] < 700 and took[2] == 'the editor did not answer in time',
    'the editor busy 1.5 s, an ask of 100 ms: answered on its own time: ' .. vim.inspect(took))
  vim.wait(1600)
  ok(state().connected, '… and the pop-out goes on')
end

-- ─── a focus that did not happen is said ─────────────────────────────────────────────────────────────────────────
do
  write(dir .. '/focus.fail', '1')
  host("_G.heard = {}; local A = require('desk.actions'); A.get('popout.focus').run(A.context())")
  ok(wait(3000, function() return vim.tbl_contains(heard(), 'Hyprland did not focus its window.') end),
    "Space Tab, and Hyprland's focus command fails (exit 17): the editor says so: " .. vim.inspect(heard()))
  -- Through the drawer first (an editor in a tmux pane): it fails (its stub exits 1), the window is tried instead, and
  -- that failing too, both are said. The drawer's stub logs the ask as one not expected; that line goes again.
  local others = read('others.log')
  host("_G.focused = nil; require('desk.popout').focus({ pid = vim.fn.getpid(), pane = '%77' }, function(fine, why) _G.focused = { fine, why } end)")
  ok(wait(5000, function() return host('return _G.focused') ~= vim.NIL end), 'a focus through the drawer')
  eq(host('return _G.focused'), { false, 'desk-drawer did not bring its pane forward, and Hyprland did not focus its window' },
    '… the drawer failing, then Hyprland: both said, never done')
  ok(read('others.log'):sub(#others + 1):find('desk-drawer run work-jump %77', 1, true), '… the drawer asked first')
  write(dir .. '/others.log', others)
  os.remove(dir .. '/focus.fail')
end

-- ─── a view its kind takes off is written out ────────────────────────────────────────────────────────────────────
do
  host("require('desk.popout').show('graph', require('desk.actions').context())")
  ok(wait(3000, function() return state().tabs == 2 and state().shown == 'graph' end), 'two views, the graph in front')
  ok(wait(3000, function() return #(record().tabs or {}) == 2 end), '… both in the record')
  host("require('desk.popout').clear('rows')")
  ok(wait(3000, function() return state().tabs == 1 end), 'the rows taken off by their kind (as the review closing does), behind the graph')
  ok(wait(3000, function() return #(record().tabs or {}) == 1 end), '… and the record drops them: ' .. read(record_file()))
end

vim.rpcnotify(h, 'nvim_command', 'qa!')
ok(third:wait(5000).code == 0, 'the third editor closes')
ok(wait(10000, function() return not exists(psock) end), '… and its pop-out quits')
end

local ran, err = xpcall(scenario, debug.traceback)
if not ran then failed = failed + 1; print('FAIL: ' .. tostring(err)) end
if failed > 0 then print('--- hyprctl.log ---\n' .. read('hyprctl.log') .. '--- the pop-out said ---\n' .. read('popout.err')) end
local asked = read('others.log')
if asked ~= '' then failed = failed + 1; print('FAIL: desk-work or desk-drawer was asked for something else than the layout:\n' .. asked) end
-- Whatever is left of its Neovims goes, and only them: a process is killed only when its command line names the
-- sandbox (an editor whose run stopped before it wrote its pid too).
for _, entry in ipairs(vim.fn.readdir('/proc')) do
  local pid = tonumber(entry)
  if pid and pid > 1 and pid ~= vim.fn.getpid() and read('/proc/' .. pid .. '/cmdline'):find(base, 1, true) then pcall(uv.kill, pid, 'sigkill') end
end
vim.wait(200)
vim.fn.delete(base, 'rf')
print(('popout: %d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
