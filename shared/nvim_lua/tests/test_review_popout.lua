-- nvim --headless --clean -l shared/nvim_lua/tests/test_review_popout.lua : the review's file list in the pop-out (the
-- review navigator), end to end. A main editor with a review open (review_popout_host.lua) and its pop-out: two
-- headless Neovims on private sockets, driven from here over RPC, in a sandbox of their own. HOME, the XDG folders and
-- XDG_RUNTIME_DIR are private folders under tests/, the repository reviewed is one there, and kitty, hyprctl, desk-hl,
-- desk-drawer and desk-work are stubs first on PATH that log what they are asked (kitty runs the pop-out headless).
-- Nothing runs until every stub is proven to shadow the real tool: never her sockets, tmux, Hyprland, Neovim, mako
-- or Claude sessions.
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
local base = assert(uv.fs_mkdtemp(ROOT .. '/tests/rvXXXXXX'))
local dir, bin, repo = base .. '/run', base .. '/bin', base .. '/project'
for _, folder in ipairs({ dir, bin, repo, base .. '/home', base .. '/config/foxml', base .. '/state', base .. '/cache', base .. '/data' }) do
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
printf '%s\n' "$@" > "$REVIEW_TEST/kitty.argv"
echo $$ > "$REVIEW_TEST/kitty.pid"
n=$(( $(cat "$REVIEW_TEST/kitty.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$REVIEW_TEST/kitty.count"
echo "$REVIEW_TEST/p$n" > "$REVIEW_TEST/kitty.listen"
while [ $# -gt 0 ] && [ "$1" != -e ]; do shift; done
shift
[ "$1" = nvim ] && shift
exec nvim --headless --clean --listen "$REVIEW_TEST/p$n" --cmd "luafile $REVIEW_TEST/loader.lua" "$@" 2>>"$REVIEW_TEST/popout.err"
]], 'rwxr-xr-x')
write(bin .. '/hyprctl', [[#!/bin/sh
# hyprctl, for the test: logs every call; the screens and windows come from the test's files.
printf '%s\n' "$*" >> "$REVIEW_TEST/hyprctl.log"
case "$1 $2" in
  "-j monitors") cat "$REVIEW_TEST/monitors.json" ;;
  "-j clients")
    pop=$(cat "$REVIEW_TEST/kitty.pid" 2>/dev/null || echo 0)
    main=$(cat "$REVIEW_TEST/main.pid" 2>/dev/null || echo 0)
    printf '[{"address":"0xa1","pid":%s,"class":"kitty"},{"address":"0xb2","pid":%s,"class":"desk-popout"}]\n' "$main" "$pop" ;;
  "eval return 1") echo 1 ;;
  *) echo ok ;;
esac
]], 'rwxr-xr-x')
write(bin .. '/desk-drawer', '#!/bin/sh\nprintf "%s\\n" "desk-drawer $*" >> "$REVIEW_TEST/others.log"\nexit 1\n', 'rwxr-xr-x')
-- desk-work, for the test: the review's records answer as recorded (nothing is kept); anything else is refused.
write(bin .. '/desk-work', [[#!/bin/sh
printf '%s\n' "desk-work $*" >> "$REVIEW_TEST/work.log"
case "$1" in
  reviewed|review-mark|review-request) echo '{"ok":true}' ;;
  review-requests) echo '[]' ;;
  *) exit 1 ;;
esac
]], 'rwxr-xr-x')
vim.fn.writefile(vim.fn.readfile(ROOT .. '/shared/bin/desk-hl', 'b'), bin .. '/desk-hl', 'b')
vim.fn.setfperm(bin .. '/desk-hl', 'rwxr-xr-x')
-- The repo's desk modules, ahead of any installed copy, in both Neovims; flash.nvim (the jump labels) when the test
-- was given it, read only.
write(dir .. '/loader.lua', [[
local lua = os.getenv('REVIEW_LUA')
package.path = lua .. '/?.lua;' .. package.path
table.insert(package.loaders, 2, function(name)
  local file = lua .. '/' .. name:gsub('%.', '/') .. '.lua'
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
vim.g.mapleader = ' '
vim.g.desk_style = 'paper'
local flash = os.getenv('REVIEW_FLASH') or ''
if flash ~= '' then
  vim.opt.rtp:append(flash)
  require('flash').setup({ labels = 'asdfghjkl', label = { uppercase = false } })
end
]])
write(dir .. '/monitors.json', vim.json.encode({ { name = 'eDP-1', focused = true, activeWorkspace = { id = 1, name = '1' } },
  { name = 'DP-2', focused = false, activeWorkspace = { id = 5, name = '5' } } }))
local sidecar = base .. '/config/foxml/monitor-layout.conf'
local TWO = { 'PRIMARY="eDP-1"', 'PORTRAIT_OUTPUTS=""', 'SECONDARY_OUTPUTS="DP-2"' }
vim.fn.writefile({ 'PRIMARY="eDP-1"', 'PORTRAIT_OUTPUTS=""', 'SECONDARY_OUTPUTS=""' }, sidecar)
-- Nothing of her session reaches the two Neovims or git: no tmux, parent Neovim, Hyprland instance, display, kitty,
-- D-Bus or git configuration of hers.
local env = vim.fn.environ()
for _, name in ipairs({ 'TMUX', 'TMUX_PANE', 'NVIM', 'NVIM_LISTEN_ADDRESS', 'HYPRLAND_INSTANCE_SIGNATURE', 'WAYLAND_DISPLAY',
  'DISPLAY', 'KITTY_WINDOW_ID', 'KITTY_LISTEN_ON', 'DBUS_SESSION_BUS_ADDRESS', 'SWAYSOCK', 'GIT_DIR', 'GIT_WORK_TREE' }) do env[name] = nil end
for name, value in pairs({ HOME = base .. '/home', XDG_RUNTIME_DIR = dir, XDG_CONFIG_HOME = base .. '/config', XDG_STATE_HOME = base .. '/state',
  XDG_CACHE_HOME = base .. '/cache', XDG_DATA_HOME = base .. '/data', NVIM_LOG_FILE = base .. '/nvim.log', TERM = 'xterm-256color',
  PATH = bin .. ':' .. (env.PATH or '/usr/bin:/bin'), REVIEW_TEST = dir, REVIEW_LUA = ROOT .. '/shared/nvim_lua', TMUX_TMPDIR = dir,
  GIT_CONFIG_GLOBAL = '/dev/null', GIT_CONFIG_NOSYSTEM = '1', FOXML_WORK_NOTIFY = '0', REVIEW_FLASH = os.getenv('REVIEW_FLASH') or '' }) do
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

-- ─── the repository: one commit of three files, two changed blocks in one.lua ─────────────────────────────────────
local function git(...)
  local ran = vim.system({ 'git', '-c', 'user.name=Review Test', '-c', 'user.email=review@example.invalid', '-c', 'commit.gpgsign=false',
    '-c', 'core.hooksPath=/dev/null', ... }, { cwd = repo, env = env, clear_env = true, text = true }):wait()
  assert(ran.code == 0, 'git ' .. table.concat({ ... }, ' ') .. ': ' .. (ran.stderr or ''))
  return vim.trim(ran.stdout or '')
end
git('init', '-q')
write(repo .. '/one.lua', 'local M = {}\nfunction M.alpha()\n  return M.old()\nend\nfunction M.beta()\n  return 1\nend\nreturn M\n')
write(repo .. '/two.txt', 'first\n')
write(repo .. '/three.lua', 'return 1\n')
git('add', '.')
git('commit', '-qm', 'base')
local parent = git('rev-parse', 'HEAD')
write(repo .. '/one.lua', 'local M = {}\nfunction M.alpha()\n  return M.new()\nend\nfunction M.beta()\n  return 2\nend\nreturn M\n')
write(repo .. '/two.txt', 'second\n')
write(repo .. '/three.lua', 'return 3\n')
git('add', '.')
git('commit', '-qm', 'change')
local sha = git('rev-parse', 'HEAD')
env.REVIEW_ROOT, env.REVIEW_SHA, env.REVIEW_PARENT = repo, sha, parent

local function wait(ms, cond) return vim.wait(ms, function() local fine, value = pcall(cond); return fine and value end, 20) end
local function exists(path) return uv.fs_stat(path) ~= nil end
local function later(ms) local s, us = uv.gettimeofday(); return s * 1000 + math.floor(us / 1000) + ms end

local function scenario()
-- This process is the terminal the main editor runs in: hyprctl's stub lists it as that editor's window (0xa1).
vim.fn.writefile({ tostring(vim.fn.getpid()) }, dir .. '/main.pid')
local host_job = vim.system({ 'nvim', '--headless', '--clean', '--listen', dir .. '/h', '--cmd', 'luafile ' .. dir .. '/loader.lua',
  '-c', 'luafile ' .. here .. 'review_popout_host.lua' }, { text = true, env = env, clear_env = true })
assert(wait(10000, function() return exists(dir .. '/h') end), 'the main editor never listened')
local h = vim.fn.sockconnect('pipe', dir .. '/h', { rpc = true })
local function host(code, ...) return vim.rpcrequest(h, 'nvim_exec_lua', code, { ... }) end
ok(wait(10000, function() return host('return _G.review_test and _G.review_test.ready') == true end), 'the main editor has its review open')
-- The review as the main editor has it.
local function review()
  return host([[local R = require('desk.review'); local r = R.current
    if not r then return { open = false } end
    local api = vim.api
    local f = r.files[r.index]
    local marks = {}
    for rel in pairs(r.marks) do marks[#marks + 1] = rel end
    table.sort(marks)
    return { open = true, file = f and f.rel or '', panel = api.nvim_win_is_valid(r.panel_win or -1), popped = r.popout ~= nil,
      checked = marks, right = api.nvim_win_get_cursor(r.right_win)[1], footer = vim.wo[r.right_win].statusline,
      completed = r.completed == true, since = R.since_mode(),
      room = api.nvim_win_get_width(r.left_win) + api.nvim_win_get_width(r.right_win) + 1, columns = vim.o.columns,
      current = api.nvim_get_current_win() == r.panel_win and 'list' or (api.nvim_get_current_win() == r.right_win or api.nvim_get_current_win() == r.left_win) and 'diff' or 'other' }]])
end
local function to_list() host("vim.api.nvim_set_current_win(require('desk.review').current.panel_win)") end
local function host_keys(keys) vim.rpcrequest(h, 'nvim_input', keys) end
local function list_row(rel)
  return host([[local r = require('desk.review').current
    for line, e in pairs(r.entries) do
      local f = e.file and (e.set and e.set.files or r.files)[e.file]
      if f and f.rel == ... and not e.symbol then return line end
    end]], rel)
end
local function heard(text) return vim.tbl_contains(host('return _G.review_test.heard'), text) end

local p, psock
local function pop(code, ...) return vim.rpcrequest(p, 'nvim_exec_lua', code, { ... }) end
local function state()
  local fine, value = pcall(pop, "return require('desk.popout').client_state()")
  return fine and value or {}
end
local function popped() return table.concat(state().lines or {}, '\n') end
local function press(keys) vim.rpcrequest(p, 'nvim_input', keys) end
local function opened()
  ok(wait(10000, function() return exists(dir .. '/kitty.listen') end), 'the pop-out is started, in kitty')
  psock = vim.trim(read('kitty.listen'))
  ok(wait(10000, function() return exists(psock) end), '… and its Neovim listens')
  p = vim.fn.sockconnect('pipe', psock, { rpc = true })
end
local function strip()
  local lines = state().lines or {}
  for i = #lines, 1, -1 do if lines[i]:find('╭', 1, true) then return (lines[i + 1] or '') .. '\n' .. (lines[i + 2] or '') end end
  return ''
end
local function mark_of_hyprctl() return #read('hyprctl.log') end
local function hyprctl_since(mark) return read('hyprctl.log'):sub(mark + 1) end

-- Every key pressed there names the view as the pop-out drew it: it waits for each drawing, so a key never names one
-- the editor has drawn again since ("this view moved on" would make a key do nothing and a check pass for nothing).
local function settled()
  return wait(3000, function()
    local gen = host("local v = require('desk.popout').host.views.review; return v and not v.queued and v.gen or -1")
    return gen == state().gen
  end)
end
local function refused_there() return vim.tbl_filter(function(t) return tostring(t):find('moved on', 1, true) end, pop('return _G.heard')) end

-- ─── one screen: o says why, the list stays ──────────────────────────────────────────────────────────────────────
to_list()
host("vim.api.nvim_win_set_cursor(0, { ... , 0 })", list_row('two.txt'))
host_keys('o')
ok(wait(2000, function() return heard('Requires a second monitor.') end), 'one screen: o in the list says "Requires a second monitor."')
local r0 = review()
eq({ r0.panel, r0.popped, exists(dir .. '/kitty.argv') }, { true, false, false }, '… and the list stays; nothing is started')

-- ─── o: the list moves to the pop-out, the comparison takes the screen ─────────────────────────────────────────────
vim.fn.writefile(TWO, sidecar)
to_list()
host_keys('o')
opened()
ok(wait(10000, function() return state().kind == 'review' end), 'two screens: o in the list sends it to the pop-out')
pop("_G.heard = {}; vim.notify = function(text) table.insert(_G.heard, text) end")
local s = state()
eq({ s.shown, s.title, s.selected }, { 'review', 'review · ' .. sha:sub(1, 7), 'two.txt' }, '… titled with the commit, on the row the cursor was on')
ok(popped():find('one.lua', 1, true) and popped():find('two.txt', 1, true) and popped():find('three.lua', 1, true), "… its rows are the list's:\n" .. popped())
local r1 = review()
eq({ r1.panel, r1.popped, r1.room }, { false, true, r1.columns }, '… the list is gone from the editor, the comparison takes the whole width')
ok(r1.footer:find('list on the pop-out', 1, true), "… and the comparison's footer says where it went: " .. r1.footer)
local lines = state().lines
ok(lines[#lines - 2]:find('two.txt', 1, true) and lines[#lines]:find('╰', 1, true), "the view ends with the strip, about the row selected:\n" .. strip())
ok(wait(3000, function()
  local saved = host("return require('desk.popout').host.saved")
  local tab = type(saved) == 'table' and type(saved.tabs) == 'table' and saved.tabs[1] or {}
  return tab.kind == 'review' and type(tab.target) == 'table' and tab.target.name == 'commit:' .. sha and tab.target.file == 'one.lua'
end), "the pop-out's layout record names this review and the file the comparison shows")

-- ─── j and k move there; Enter shows the file here, the keyboard stays there ──────────────────────────────────────
local shown_before = review().file
press('k')
ok(wait(2000, function() return state().selected == 'three.lua' end), 'k: the row above, in the pop-out')
ok(strip():find('three.lua', 1, true), '… the strip follows it')
eq(review().file, shown_before, '… and the editor has not moved')
press('j')
ok(wait(2000, function() return state().selected == 'two.txt' end), 'j: back down')
local mark = mark_of_hyprctl()
-- Where the pop-out's history stands (desk.popout): an Enter is one step of it, whatever the kind records of its own.
local function history_at() return host("return require('desk.popout').host.history.at") end
local at_enter = history_at()
press('<CR>')
ok(wait(3000, function() return review().file == 'two.txt' end), 'Enter: the editor shows that file')
ok(wait(3000, function() return popped():find('lines 1', 1, true) end), '… opened, with its changed lines under it')
s = state()
eq({ s.mode, s.current_win == s.win, s.selected }, { 'n', true, 'two.txt' }, '… the keyboard stays in the pop-out, on that row')
ok(not wait(1000, function() return hyprctl_since(mark):find('hl.dsp.focus', 1, true) end), '… and nothing is focused')
settled()
vim.wait(200)
eq(history_at(), at_enter + 1, '… one step of the history: the file and the editor\'s spot together')

-- ─── H and L: the file shown before, and forward again ─────────────────────────────────────────────────────────
press('<C-o>')
ok(wait(3000, function() return review().file == 'one.lua' end), 'H in the pop-out: the editor shows the file it showed before')
eq(history_at(), at_enter, '… one H undoing the whole Enter')
press('<C-r>')
ok(wait(3000, function() return review().file == 'two.txt' end), '… and L shows that one again')
ok(wait(2000, function() return state().selected == 'two.txt' end), '… selected there')
settled()

-- ─── m checks the row's file here; the pop-out shows the check ─────────────────────────────────────────────────────
press('m')
ok(wait(3000, function() return vim.tbl_contains(review().checked, 'two.txt') end), 'm: the editor checks that file')
ok(wait(3000, function() return popped():find('✓ two.txt', 1, true) end), '… and the pop-out shows it checked')
ok(wait(3000, function() return strip():find('reviewed', 1, true) end), '… its strip says so')
settled()

-- ─── ]c and [c move the comparison here ──────────────────────────────────────────────────────────────────────────
press('kk')
ok(wait(2000, function() return state().selected == 'one.lua' end), 'k k: one.lua')
press('<CR>')
ok(wait(3000, function() return review().file == 'one.lua' end), 'Enter: one.lua in the comparison')
ok(wait(3000, function() return popped():find('M.alpha', 1, true) end), '… opened: its changed functions are rows there')
settled()
local first = review().right
press(']c')
ok(wait(3000, function() return review().right > first end), ']c: the next changed block, in the comparison here')
press('[c')
ok(wait(3000, function() return review().right == first end), '[c: back to the first')

-- ─── a part of a file: m checks it and never unchecks it; h folds it ─────────────────────────────────────────────
eq(state().selected, 'one.lua', 'the selection stays on the file it opened')
press('j')
ok(wait(2000, function() return state().selected == 'M.alpha' end), 'j: its first function')
ok(wait(3000, function() return strip():find('calls by name: +M.new −M.old', 1, true) end), "… its strip there says which calls its change made:\n" .. strip())
local one = vim.tbl_filter(function(l) return l:find('one.lua', 1, true) and not l:find('│', 1, true) end, state().lines)[1] or ''
ok(one:find('→', 1, true), 'and its file is marked → there too: ' .. one)
press('m')
ok(wait(3000, function() return vim.tbl_contains(review().checked, 'one.lua') end), 'm on a function: its file checked')
ok(wait(3000, function() return popped():find('✓ one.lua', 1, true) end), '… shown checked there')
settled()
press('m')
ok(wait(3000, function() return heard('one.lua is checked; m on its own row unchecks it.') end), 'm again on the function: run here, and it says why nothing changed')
ok(vim.tbl_contains(review().checked, 'one.lua'), '… the file still checked (a part never unchecks its file)')
press('jjjjjj')
ok(wait(2000, function() return state().selected == 'lines 1' end), "j to the bottom: two.txt's changed lines")
press('h')
ok(wait(3000, function() return not popped():find('lines 1', 1, true) end), 'h: its file folded, here and there')
ok(wait(2000, function() return state().selected == 'two.txt' end), '… the selection on the folded file, not the first row')
settled()

-- ─── u, n ──────────────────────────────────────────────────────────────────────────────────────────────────────
press('u')
ok(wait(3000, function() return review().file == 'three.lua' end), 'u: the editor goes to the first unread file')
ok(wait(3000, function() return state().selected == 'three.lua' end), '… and the pop-out selects it')
settled()
local since = review().since
press('n')
ok(wait(3000, function() return review().since == not since end), 'n: new since review / the whole change, switched here')
settled()

-- ─── c: the words asked in the pop-out, the request made here ─────────────────────────────────────────────────────
pop([[vim.ui.select = function(items, opts, done) _G.offered = vim.tbl_map(function(c) return c.name end, items); done(items[1]) end
  vim.ui.input = function(opts, done) _G.asked = opts.prompt; done('make it pink') end]])
press('c')
ok(wait(3000, function() return #vim.fn.glob(dir .. '/foxml-claude/inbox/sess1/*.json', false, true) == 1 end),
  "c: the session and the words are asked in the pop-out, and the note lands in that session's inbox")
local notes = vim.fn.glob(dir .. '/foxml-claude/inbox/sess1/*.json', false, true)
local note = notes[1] and vim.json.decode(read(notes[1])) or {}
eq({ note.text, note.file }, { 'make it pink', repo .. '/three.lua' }, '… about the row selected there')
eq({ pop('return _G.asked'), pop('return _G.offered') }, { 'Change request: ', { '○ A session · project · waiting' } },
  "… asked with the editor's question, offering its live sessions")
ok(wait(3000, function() return popped():find('✉ three.lua', 1, true) end), '… and the row waits on the request (✉)')
eq(host('return _G.review_test.asked_here'), 0, '… nothing was asked in the editor')
settled()

-- ─── R: what next is asked in the pop-out, the review finished here ─────────────────────────────────────────────
press('R')
ok(wait(3000, function() return vim.tbl_contains(pop('return _G.heard'), 'Check each file first (2 of 3 checked).') end),
  'R before every file is checked: the pop-out says why')
eq(review().completed, false, '… and nothing is finished')
-- p pins the review list, and the header says so: the review's state is its progress, so PINNED never showed (2026-11-16).
press('p')
ok(wait(3000, function() return (state().header or ''):find('review · PINNED', 1, true) end), 'p: pinned, the header says so: ' .. tostring(state().header))
press('p')
ok(wait(3000, function() return not (state().header or ''):find('PINNED', 1, true) end), '… p again: following, PINNED gone')
press('m')
ok(wait(3000, function() return #review().checked == 3 end), 'm: the last file checked')
ok(wait(3000, function() return popped():find('✓ three.lua', 1, true) end), '… shown there')
settled()
-- A click on a row's check box in the pop-out checks it, as in the editor: the review's zones go with its items
-- (2026-11-16: a single click there only moved the selection). The mouse is stood in for; the handler is the click's.
do
  pop([[vim.ui.select = function(items, opts, done)
    for i, item in ipairs(items) do if opts.format_item(item):find('three.lua', 1, true) then return done(item, i) end end
    done(nil, nil)
  end]])
  press('/')
  ok(wait(3000, function() return state().selected:find('three.lua', 1, true) end), 'three.lua selected: ' .. tostring(state().selected))
  local s = state()
  local box
  for _, z in ipairs(s.zones) do if z[3] == 'review.mark-list' then box = z end end
  ok(box ~= nil, '… its zones name the check box: ' .. vim.inspect(s.zones))
  local function click(column)
    pop("local w, l, c = ...; local real = vim.fn.getmousepos; vim.fn.getmousepos = function() return { winid = w, line = l, column = c } end; "
      .. "require('desk.popout').client_zone_click(); vim.fn.getmousepos = real", s.win, s.item_line, column)
  end
  click(box[1])
  ok(wait(3000, function() return #review().checked == 2 end), 'a click on its box unchecks it: ' .. #review().checked .. ' checked')
  click(box[2] + 3)
  vim.wait(300)
  eq(#review().checked, 2, '… a click past the box does nothing')
  click(box[2])
  ok(wait(3000, function() return #review().checked == 3 end), '… and on it again checks it')
  settled()
end
-- The question, asked in the pop-out as a menu (vim.ui.select) with the editor's letters as its keys.
pop([[vim.ui.select = function(items, opts, done)
  local keys = opts.desk_keys or {}
  local shown = {}
  for i, c in ipairs(items) do shown[i] = '&' .. (keys[i] or '?'):upper() .. tostring(c.name):sub(2) end
  _G.confirmed = table.concat(shown, '\n')
  for _, c in ipairs(items) do if c.name == 'Stay' then return done(c) end end
  done(nil)
end]])
local editor_labels = host([[local seen
  local real = vim.fn.confirm
  vim.fn.confirm = function(question, labels) seen = labels; return 0 end
  pcall(_G.review_test.ask_after_finish, 3, false)
  vim.fn.confirm = real
  return seen]])
press('R')
ok(wait(3000, function() return review().completed end), 'R: finished here')
eq({ pop('return _G.confirmed'), editor_labels }, { '&Close review\n&Stay', '&Close review\n&Stay' },
  "… what next asked in the pop-out with the editor's own keys, (C)lose review (S)tay (one commit: no next one)")
eq(host('return _G.review_test.asked_here'), 0, '… never in the editor')
settled()

-- ─── a: the review's actions here, and the keyboard with them ─────────────────────────────────────────────────────
mark = mark_of_hyprctl()
press('a')
ok(wait(3000, function() return host("local m = require('desk.menu')._last; return m ~= nil and vim.api.nvim_win_is_valid(m.win)") end),
  "a: the review's actions open in the editor")
ok(wait(3000, function() return hyprctl_since(mark):find("dispatch hl.dsp.focus({ window = 'address:0xa1' })", 1, true) end),
  '… and the keyboard goes there with them')
host("vim.api.nvim_win_close(require('desk.menu')._last.win, true)")

-- ─── s: labels on the rows there ─────────────────────────────────────────────────────────────────────────────────
if (env.REVIEW_FLASH or '') ~= '' then
  press('s')
  ok(wait(2000, function() return pop("return #require('desk.nav').drawn") > 0 end), 's: labels on the rows of the pop-out')
  local drawn = pop("return require('desk.nav').drawn[1]")
  -- The rows: the lines of the view's items, as the editor drew them for the pop-out's width.
  local rows = host([[local P = require('desk.popout'); local v = P.host.views.review
    return vim.tbl_map(function(i) return i.line end, require('desk.review').view_kind.render(v, P.host.width or 80).items)]])
  ok(#rows >= 4, 'the view has its rows: ' .. vim.inspect(rows))
  eq(vim.tbl_map(function(l) return l.line end, drawn), rows, '… one on each row, none on a heading or the strip')
  local target = drawn[1]
  press(target.label)
  ok(wait(2000, function() return state().selected == 'one.lua' end), '… typing one selects its row')
else
  print('test_review_popout: flash.nvim is not installed here; the labels were not drawn')
end

-- ─── ? lists the view's keys ─────────────────────────────────────────────────────────────────────────────────────
press('?')
ok(wait(2000, function() return pop("return vim.api.nvim_win_get_config(0).relative ~= ''") end), '? opens a list in the pop-out')
local keys = pop("return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')")
ok(keys:find('Enter/l%s+Expand commit') and keys:find('j/k%s+The row below') and keys:find('m%s+Mark selected file')
  and keys:find('c%s+Request changes') and keys:find('R%s+Finish review') and keys:find('%]c/%[c%s+Next / previous changed block'),
  "… the list's keys that run there or here:\n" .. keys)
ok(not keys:find('Follow selected live session', 1, true) and not keys:find('Hide review file list', 1, true)
  and not keys:find('Open the working file', 1, true), "… and none of the editor's own:\n" .. keys)
press('q')
ok(wait(2000, function() return state().current_win == state().win end), '… q closes it')

-- ─── what the pop-out may ask for ───────────────────────────────────────────────────────────────────────────────
eq(host("return require('desk.bridge').receive(...)", { version = 1, type = 'act', view = 'review', gen = state().gen, item = 1,
  action = 'review.follow', deadline = later(5000) }), { refused = 'review.follow is not one the pop-out may ask for' },
  "f, the editor's own row, is refused there")
eq(refused_there(), {}, 'no key pressed in the pop-out was refused for a view drawn again since')

-- ─── o there: the list back here, on the row selected there ───────────────────────────────────────────────────────
-- The list went out with its cursor on two.txt and the comparison shows three.lua: it comes back on the row selected
-- there now, one.lua, neither of those.
press('jjjjjj')
press('kkkk')
ok(wait(2000, function() return state().selected == 'one.lua' end), 'one.lua selected in the pop-out')
eq(review().file, 'three.lua', '… while the comparison shows three.lua')
press('o')
ok(wait(3000, function() return review().panel end), 'o in the pop-out: the list is back in the editor')
ok(wait(3000, function() return state().shown == '' end), '… and the pop-out shows nothing')
ok(wait(2000, function() return host("local r = require('desk.review').current; return vim.api.nvim_win_get_cursor(r.panel_win)[1]") == list_row('one.lua') end),
  '… its cursor on the row that was selected there')
eq(review().current, 'list', "… and the editor's cursor in it")
local views = host([[local A = require('desk.actions'); local r = require('desk.review').current
  local row = A.get('popout.view.review')
  return { A.available(row, A.context(r.right_win)), A.available(row, A.context(r.panel_win)) }]])
eq(views, { true, false }, 'Space Space › Review list to the pop-out from the comparison; in the list its own o (pins the Views row)')

-- ─── BS in the comparison takes the list back from the pop-out ────────────────────────────────────────────────────
to_list()
host_keys('o')
ok(wait(3000, function() return state().kind == 'review' end), 'o again: the list in the pop-out')
host("vim.api.nvim_set_current_win(require('desk.review').current.right_win)")
host_keys('<BS>')
ok(wait(3000, function() return review().panel and not review().popped end), 'BS in the comparison: the list comes back here')
ok(wait(3000, function() return state().shown == '' and not vim.tbl_contains(state().views or {}, 'review') end), '… and leaves the pop-out')

-- ─── the pop-out closing gives the list back ────────────────────────────────────────────────────────────────────
to_list()
host_keys('o')
ok(wait(3000, function() return state().kind == 'review' end), 'o again')
vim.rpcnotify(p, 'nvim_input', 'q')
ok(wait(5000, function() return not exists(psock) end), 'q there: the pop-out closes')
ok(wait(5000, function() return review().panel and not review().popped end), '… and the list comes back here')

-- ─── closing the review clears its view ─────────────────────────────────────────────────────────────────────────
os.remove(dir .. '/kitty.listen')
to_list()
host_keys('o')
opened()
ok(wait(10000, function() return state().kind == 'review' end), 'a pop-out again, the list in it')
host("vim.api.nvim_set_current_win(require('desk.review').current.right_win)")
host_keys('q')
ok(wait(3000, function() return not review().open end), 'q in the comparison closes the review')
ok(wait(3000, function() return state().shown == '' and not vim.tbl_contains(state().views or {}, 'review') end), '… and its view leaves the pop-out')

-- ─── Restore after a restart: the review the record names, opened again, its list there on the file it showed ──
-- The checkout has working changes now (an untracked file): the review comes back with them, as Space Cw shows it.
write(repo .. '/four.txt', 'not committed yet\n')
host(("require('desk.popout').host.saved = { version = 1, tabs = { { kind = 'review', pinned = false, target = { file = 'two.txt', line = 1, name = 'commit:%s' } } }, activeTab = 'review' }"):format(sha))
host("require('desk.popout').restore_layout()")
ok(wait(5000, function() return review().open and review().popped end), 'Restore: the review the record names opens again, its list in the pop-out')
ok(wait(3000, function() return review().file == 'two.txt' and state().kind == 'review' and state().selected == 'two.txt' end),
  '… on the file it showed')
local working = host([[local set = require('desk.review').current.sets and require('desk.review').current.sets[1]
  if not (set and set.row.kind == 'working') then return 'no working changes group' end
  local rels = {}
  for _, f in ipairs(set.files or {}) do rels[#rels + 1] = f.rel end
  return { open = set.expanded == true, files = rels }]])
eq(working, { open = true, files = { 'four.txt' } }, "… and the checkout's working changes listed in its tree, as Space Cw lists them")
ok(wait(3000, function() return popped():find('four.txt', 1, true) end), '… there too:\n' .. popped())
-- What changed asked from the pop-out (its menu, through the bridge): the review's file list comes to the pop-out and
-- the comparison stays here, as a view asked for there opens there (2026-11-16: it opened all of it in the editor).
do
  local s_, us = vim.uv.gettimeofday()
  eq(host("return require('desk.bridge').receive(...)", { version = 1, type = 'act', action = 'claude.changes',
    deadline = s_ * 1000 + math.floor(us / 1000) + 5000 }), { done = true }, 'What changed, asked from the pop-out: taken')
  ok(wait(5000, function() return state().kind == 'review' and review().popped end), "… the review's list in the pop-out")
end
-- With several pop-outs, asked from the second: the list goes there, not to the first (seen with the map's c in a VM,
-- 2026-11-17; the same path).
eq(host([[local P, A = require('desk.popout'), require('desk.actions')
  local R = require('desk.review')
  local real_show, real_changes, got = P.show, require('desk.claude').changes, nil
  P.show = function(name, ctx, opts) got = { name, opts and opts.pop } end
  require('desk.claude').changes = function() end
  local held = R.current and R.current.popout
  if R.current then R.current.popout = nil end
  A.get('claude.changes').run({ remote = true, pop = 2 })
  if R.current then R.current.popout = held end
  P.show, require('desk.claude').changes = real_show, real_changes
  return got]]), { 'review', 2 }, '… asked from a second pop-out: its list goes to that one')
vim.rpcnotify(p, 'nvim_input', 'q')
ok(wait(5000, function() return not exists(psock) end), 'the pop-out closes')

-- ─── Restore after its screen went: the list stays in the pop-out when its tab comes back to the front ─────────────
-- The pop-out went (its screen unplugged) while another tab was in front: the list was to come back to the editor
-- when its tab did. Restored to the pop-out first, it must stay there.
os.remove(dir .. '/kitty.listen')
ok(wait(3000, function() return review().panel end), 'the list back in the editor')
to_list()
host_keys('o')
opened()
ok(wait(10000, function() return state().kind == 'review' end), 'the list in a pop-out again')
ok(wait(3000, function()
  local saved = host("return require('desk.popout').host.saved")
  return type(saved) == 'table' and type(saved.tabs) == 'table' and #saved.tabs == 1
end), '… in the layout record')
host("vim.cmd('tabnew')")
host("require('desk.popout').fold('the screen went')")
ok(wait(5000, function() return not exists(psock) end), 'the pop-out goes on its own, another tab in front here')
os.remove(dir .. '/kitty.listen')
host("require('desk.popout').restore_layout()")
opened()
ok(wait(10000, function() return state().kind == 'review' and review().popped end), 'Restore: the list in the pop-out again')
host("vim.api.nvim_set_current_tabpage(require('desk.review').current.tab)")
ok(not wait(1500, function() return review().panel end), "… and the review's tab in front again does not take it back")
eq({ state().kind, review().popped }, { 'review', true }, '… it stays in the pop-out')
vim.rpcnotify(p, 'nvim_input', 'q')
ok(wait(5000, function() return not exists(psock) end), 'the pop-out closes')
host_job:kill(9)
end

local ran, err = xpcall(scenario, debug.traceback)
if not ran then failed = failed + 1; print('FAIL: ' .. tostring(err)) end
if failed > 0 then print('--- hyprctl.log ---\n' .. read('hyprctl.log') .. '--- desk-work.log ---\n' .. read('work.log') .. '--- the pop-out said ---\n' .. read('popout.err')) end
local asked = read('others.log')
if asked ~= '' then failed = failed + 1; print('FAIL: desk-drawer was asked for something:\n' .. asked) end
-- Whatever is left of the two Neovims goes, and only them: a process is killed only when its command line names the sandbox.
for _, name in ipairs({ 'host.pid', 'kitty.pid' }) do
  local pid = tonumber(vim.trim(read(name)))
  local cmdline = pid and read('/proc/' .. pid .. '/cmdline') or ''
  if pid and pid > 1 and cmdline:find(dir, 1, true) then pcall(uv.kill, pid, 'sigkill') end
end
vim.fn.delete(base, 'rf')
print(('review popout: %d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
