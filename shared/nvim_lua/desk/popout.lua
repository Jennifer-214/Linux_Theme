-- The pop-out: a second Neovim in a kitty window of its own, on another screen, that shows views the main editor sends
-- and whose keys act in the main editor. Enter there moves the main editor and the keyboard stays in the pop-out.
--
-- One module, two sides. The main editor (the host) opens it (M.open: kitty --class desk-popout -e nvim … --
-- desk-popout:<its socket>, the socket only ever in argv), keeps the views and draws each for the pop-out's width
-- through its view kind (M.kind; desk.callgraph's graph is the first). The pop-out (M.client, from its own argv) shows
-- each view in a tab page of its own (one window, one plain buffer), edits no file and runs no language server
-- (init.lua's desk-popout block). Its tab line is the header (each view, PINNED, ✱ for news, the keys that switch);
-- each window's status line is that view's key line.
--
-- An editor may have several pop-outs (M.pops, by id 1, 2, …; the first is M.host), each a kitty and a Neovim of its
-- own, started with g:desk_popout set to its id. Every view goes to the first unless she sends it to another.
--
-- Protocol 5. The editor sends each pop-out, on its own channel, rpcnotify of M.receive, { version = 5, type, … }:
--   view.set   { id, gen, kind, surface, title, state, lines, marks, hl, items, footer, strip, select, front, news, views }
--              (views: every view the editor has in that pop-out; it closes a tab of any other)
--   view.lines { id, gen, from, tick, first, last, lines, cursor, state, total } (code edits and snapshot chunks)
--   view.layout { tiled } (tile the code views in this pop-out)
--   view.clear { id } · ping { serial } (every 10 s; one that stops answering is sent nothing until it does) · bye { why }
--   answer { id, answer } (to an ask)
-- The pop-out's messages go through the editor's bridge (desk.bridge), every ask with its deadline (pong and leaving
-- need none), each naming the pop-out it comes from (pop: its id; the bridge cannot tell which channel called, and a
-- message without one is the first's): subscribe { pop, chan, pid, width, protocol = 5 } (a request: the handshake) ·
-- describe { pop, view, gen, item } → { rows } · act { pop, view, gen, item, action, text, choice } · leaving { pop, pid }
-- (q on its last view: it goes, whatever the editor is doing, and says so first) · pong { pop, serial } · front { pop,
-- view, quiet } (the view in front there now; quiet when it was not her own switch). describe, act and leaving are
-- asks: notifications of M.ask with an id, answered by an answer notification to the pop-out that asked, so it waits
-- for the editor only as long as it chooses (an editor held up, busy or at a prompt, answers late: by then the pop-out
-- has gone another way, and the deadline refuses what came late).
-- describe and act name the generation the pop-out drew: an older generation is refused ("this view moved on").
-- The pop-out's keys for a view are its in-editor surface's drawn rows (run there, on its copy) and remote rows (run in
-- the editor, by act), beside its own rows (surface 'popout'); a row the editor keeps (remote = false) is not there.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
local actions = require('desk.actions')
local bridge = require('desk.bridge')

M.CLASS = 'desk-popout'
M.PROTOCOL = 5
M.PING_MS, M.WATCH_MS, M.LINGER_MS, M.GAP_MS, M.START_MS = 10000, 2000, 1500, 50, 15000
-- MAX_LINES: a code mirror's chunk; MAX_DRAWN and MAX_ITEMS: a drawn view's lines and boxes (2026-11-19: the graph and
-- the map draw every box, no "+N more", so a big level is one long view: 2500 boxes read and drawn in about 1.3 s).
M.MAX_LINES, M.MAX_DRAWN, M.MAX_ITEMS = 2000, 20000, 5000
M.MIRROR_LINES, M.MIRROR_BYTES, M.LINE_BYTES = 50000, 8 * 1024 * 1024, 4000
local MAX_TILES = 4
-- The two doors: the editor's (desk.bridge, as desk-work uses it) and the pop-out's.
local HOST_DOOR = "return require('desk.bridge').receive(...)"
local ASK_DOOR = "return require('desk.popout').ask(...)"   -- the editor's, for an ask answered by notification
local POPOUT_DOOR = "return require('desk.popout').receive(...)"
local WARN = vim.log.levels.WARN
local ON = 'popout'

local function graphs() return require('desk.callgraph') end
local function now_ms() local s, us = uv.gettimeofday(); return s * 1000 + math.floor(us / 1000) end
local function tell(text, level) vim.notify(text, level or vim.log.levels.INFO, { title = 'Pop-out' }) end
local function refuse(why) return { refused = why } end
local function have(name) return vim.fn.executable(name) == 1 end
local function list(value) return type(value) == 'table' and value or { value } end
local function is_on(row, surface) return vim.tbl_contains(list(row.on), surface) end
-- 'requires kitty' → 'Requires kitty.'
local function sentence(text)
  text = tostring(text)
  return text:sub(1, 1):upper() .. text:sub(2) .. (text:match('[.!?…]$') and '' or '.')
end
function M.is_popout() local p = vim.g.desk_popout; return p ~= nil and p ~= 0 and p ~= false end
local function typed(id) return actions.spell(actions.key(id)) end

-- ─── screens ───────────────────────────────────────────────────────────────────────────────────────────────────
-- desk-monitor's sidecar, kept current on every hotplug (desk-pulse runs desk-monitor reconcile): PRIMARY,
-- SECONDARY_OUTPUTS and PORTRAIT_OUTPUTS as KEY="a b" lines.
function M.parse_layout(text)
  local out = { primary = '', secondary = {}, portrait = {} }
  for line in (text or ''):gmatch('[^\n]+') do
    local key, value = line:match('^%s*([%u_]+)%s*=%s*(.-)%s*$')
    if key then
      value = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
      local names = {}
      for name in value:gmatch('%S+') do if name:match('^[%w._:-]+$') then names[#names + 1] = name end end
      if key == 'PRIMARY' then out.primary = names[1] or ''
      elseif key == 'SECONDARY_OUTPUTS' then out.secondary = names
      elseif key == 'PORTRAIT_OUTPUTS' then out.portrait = names end
    end
  end
  return out
end

function M.layout_file()
  local config = vim.env.XDG_CONFIG_HOME
  if not config or config == '' then config = (vim.env.HOME or '') .. '/.config' end
  return config .. '/foxml/monitor-layout.conf'
end

-- The screens as desk-monitor last described them, or nil when it never did.
function M.screens()
  local f = io.open(M.layout_file(), 'r')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  return M.parse_layout(text)
end

-- A read of hyprctl -j: now (bounded, for a menu's question), or in the background.
function M.hyprctl_now(args)
  if not have('hyprctl') then return nil end
  local ok, out = pcall(function() return vim.system(vim.list_extend({ 'hyprctl', '-j' }, args), { text = true }):wait(500) end)
  local decoded, value = pcall(vim.json.decode, ok and out and out.code == 0 and out.stdout or '')
  return decoded and value or nil
end
local function hyprctl(args, done)
  if not have('hyprctl') then return done(nil) end
  local ok = pcall(vim.system, vim.list_extend({ 'hyprctl', '-j' }, args), { text = true, timeout = 2000 }, vim.schedule_wrap(function(out)
    local decoded, value = pcall(vim.json.decode, out.code == 0 and out.stdout or '')
    done(decoded and value or nil)
  end))
  if not ok then done(nil) end
end

-- true when there is a screen besides this one for the pop-out; else why not.
function M.second_screen()
  local layout = M.screens()
  if layout then return #layout.secondary > 0 or 'requires a second monitor' end
  local monitors = M.hyprctl_now({ 'monitors' })
  return (type(monitors) == 'table' and #monitors > 1) or 'requires a second monitor'
end

-- Where the pop-out goes: the workspace showing on the first screen desk-monitor lists as secondary (then portrait,
-- then the primary, then any other) that is not the screen with the focus, the editor's when it opens the pop-out.
-- prefer: a screen to try first (where a restored pop-out was). monitors: hyprctl -j monitors. { name, workspace } or nil.
function M.target_screen(monitors, layout, prefer)
  local live, focused, order = {}, nil, {}
  for _, m in ipairs(type(monitors) == 'table' and monitors or {}) do
    if type(m) == 'table' and type(m.name) == 'string' and not m.disabled then
      live[m.name] = m
      if m.focused then focused = m.name end
    end
  end
  layout = layout or {}
  if type(prefer) == 'string' then order[1] = prefer end
  for _, names in ipairs({ layout.secondary or {}, layout.portrait or {}, { layout.primary } }) do
    for _, name in ipairs(names) do order[#order + 1] = name end
  end
  for _, m in ipairs(type(monitors) == 'table' and monitors or {}) do if type(m) == 'table' then order[#order + 1] = m.name end end
  for _, name in ipairs(order) do
    local m = live[name]
    local workspace = m and type(m.activeWorkspace) == 'table' and tonumber(m.activeWorkspace.id)
    if m and name ~= focused and workspace and workspace > 0 then return { name = name, workspace = math.floor(workspace) } end
  end
end

-- Where the pop-out may go: the usual screen first (M.target_screen's), then the others, the editor's own last.
-- { name, workspace, label, here } each. Pure.
function M.screen_choices(monitors, layout, prefer)
  local usual = M.target_screen(monitors, layout, prefer)
  local out, here = {}, nil
  for _, m in ipairs(type(monitors) == 'table' and monitors or {}) do
    local workspace = type(m) == 'table' and not m.disabled and type(m.activeWorkspace) == 'table' and tonumber(m.activeWorkspace.id)
    if workspace and workspace > 0 and type(m.name) == 'string' then
      local about = type(m.description) == 'string' and m.description ~= '' and (' · ' .. m.description) or ''
      local size = (tonumber(m.width) and tonumber(m.height)) and (' · ' .. m.width .. '×' .. m.height) or ''
      local c = { name = m.name, workspace = math.floor(workspace), here = m.focused == true,
                  label = m.name .. about .. size .. (m.focused and ' (this screen)' or ''),
                  x = m.x, y = m.y, width = m.width, height = m.height, scale = m.scale, transform = m.transform }
      if c.here then here = c elseif usual and m.name == usual.name then table.insert(out, 1, c) else out[#out + 1] = c end
    end
  end
  if here then out[#out + 1] = here end
  return out
end

-- The screen she chose for a pop-out this session (the first's is M.chosen, another's its own chosen).
local function chosen_of(p) if p == M.host then return M.chosen end return p.chosen end
local function choose_for(p, name) if p == M.host then M.chosen = name else p.chosen = name end end
-- That screen while it is there: { name, workspace }, the editor's own screen allowed.
local function chosen_screen(monitors, p)
  local name = chosen_of(p)
  if not name then return nil end
  for _, c in ipairs(M.screen_choices(monitors, M.screens())) do
    if c.name == name then return { name = c.name, workspace = c.workspace } end
  end
end

-- Asks which screen; done(name), done(nil) when there was nothing to ask, done(false) when she chose none. all: every
-- screen, this one too (the move); else only when there is a real choice, two screens or more besides this one.
-- The screens as a row's choices ({ id = name, name = label }): every one when all, else only when there is a real
-- choice (two or more besides this one), else nil.
function M.screen_input_choices(all)
  local choices = M.screen_choices(M.hyprctl_now({ 'monitors' }), M.screens(), M.host and M.host.prefer)
  local others = #vim.tbl_filter(function(c) return not c.here end, choices)
  if #choices == 0 or (not all and others < 2) then return nil end
  -- With each screen's place, so the question can be drawn as a map of them (desk.screens).
  return vim.tbl_map(function(c) return { id = c.name, name = c.label, here = c.here, x = c.x, y = c.y, width = c.width,
    height = c.height, scale = c.scale, transform = c.transform } end, choices)
end

-- Asks which screen, the way every row asks (desk.actions: a letter each with a few, else a list): done(name), or
-- done(nil) at once when there was nothing to ask. Esc asks no more and calls nothing.
function M.choose_screen(done, all)
  local choices = M.screen_input_choices(all)
  if not choices then return done(nil) end
  actions.ask({ choices = choices, kind = 'desk_screens' }, actions.context(), function(_, choice) done(choice) end, 'Pop out on')
end

-- ─── windows ───────────────────────────────────────────────────────────────────────────────────────────────────
-- A process and its parents (her own processes; the walk stops at one it cannot read).
function M.lineage(pid)
  local out, seen = {}, {}
  while type(pid) == 'number' and pid > 1 and not seen[pid] and #out < 32 do
    seen[pid], out[#out + 1] = true, pid
    local f = io.open('/proc/' .. pid .. '/stat', 'r')
    if not f then break end
    local stat = f:read('*a') or ''
    f:close()
    pid = tonumber(stat:match('^.*%)%s+%S+%s+(%d+)'))
  end
  return out
end

-- The window of process pid: the Hyprland client nearest above it (a Neovim's kitty). clients: hyprctl -j clients.
function M.window_of(pid, clients)
  local depth, best, at = {}, nil, nil
  for i, p in ipairs(M.lineage(pid)) do depth[p] = i end
  for _, c in ipairs(type(clients) == 'table' and clients or {}) do
    local d = type(c) == 'table' and depth[c.pid]
    if d and type(c.address) == 'string' and c.address:match('^0x%x+$') and (not at or d < at) then best, at = c.address, d end
  end
  return best
end

-- One dispatcher in both of Hyprland's languages; desk-hl sends the one the running Hyprland takes (0.57: only Lua).
function M.dispatch(lua, legacy, done)
  local argv = have('desk-hl') and { 'desk-hl', 'dispatch', lua, legacy } or { 'hyprctl', 'dispatch', lua }
  local ok = pcall(vim.system, argv, { text = true, timeout = 2000 }, function(out)
    if done then vim.schedule(function() done(out.code == 0) end) end
  end)
  if not ok and done then done(false) end
end

-- Puts the keyboard in an editor's window: its tmux pane through the drawer (which brings forward the terminal showing
-- it), else, or when the drawer could not, the window above its process, on whichever screen that is. Each command is
-- waited for and its exit status read: done(true) only once the focus was given. who: { pid, pane }. done(ok, why).
function M.focus(who, done)
  done = done or function(ok, why) if not ok then tell(sentence(why), WARN) end end
  if type(who) ~= 'table' or type(who.pid) ~= 'number' then return done(false, 'there is no other window to go to') end
  -- failed: why the drawer could not, said with Hyprland's reason when that fails too.
  local function by_window(failed)
    local function fail(why) done(false, failed and (failed .. ', and ' .. why) or why) end
    if not have('hyprctl') then return fail('requires Hyprland') end
    hyprctl({ 'clients' }, function(clients)
      local address = M.window_of(who.pid, clients)
      if not address then return fail('its window was not found') end
      M.dispatch(("hl.dsp.focus({ window = 'address:%s' })"):format(address), 'focuswindow address:' .. address, function(focused)
        if focused then return done(true) end
        fail('Hyprland did not focus its window')
      end)
    end)
  end
  if type(who.pane) == 'string' and who.pane:match('^%%%d+$') and have('desk-drawer') then
    local started = pcall(vim.system, { 'desk-drawer', 'run', 'work-jump', who.pane }, { text = true, timeout = 5000 }, vim.schedule_wrap(function(out)
      if out.code == 0 then return done(true) end
      by_window('desk-drawer did not bring its pane forward')
    end))
    if not started then by_window('desk-drawer did not start') end
    return
  end
  by_window()
end

-- ─── the main editor's side ────────────────────────────────────────────────────────────────────────────────────
-- One state machine per pop-out (pops[id]), its transitions written once, below:
--   closed → opening (kitty started) → attached (subscribed) ⇄ stalled (a ping unanswered) → leaving (q on its last
--   view there) | gone (its kitty exited, its channel closed) → closed
-- A closed one is kept, empty, and its id used again for the next new one. Each one's fields: id; chan: its channel
-- once it subscribed; pid: its Neovim; kitty: the kitty it runs in; width: its window; opening: a kitty on its way;
-- views by id, and order: their ids in the order of its tabs; front: the view in front there; screen: the monitor it
-- was placed on (prefer: the one a restore asks for; chosen: the one she chose this session, the first's is M.chosen);
-- ping and heard: the pings sent and answered; timer: its pings; stalled: not answering; history: the steps Ctrl+o,
-- Backspace and Ctrl+r walk there; waiting: saved tabs whose kind has not loaded yet; folding: the view an Enter is
-- running in.
-- A view (pops[i].views[id]) names its pop-out (view.pop; one without it is the first's) and has an id of its own: its
-- kind's name for the first view of that kind, then kind.2, kind.3 (a kind may have a view in two pop-outs).
local function new_pop(id)
  return { id = id, views = {}, order = {}, ping = 0, heard = 0, width = 80, history = { steps = {}, at = 0 }, waiting = {} }
end
local pops = { new_pop(1) }
local H = pops[1]
M.host, M.pops = H, pops   -- the first pop-out (callers and the tests read it), and all of them
M.MAX_POPS = 9
-- The editor's own, one for all its pop-outs, kept on the first's table (where the tests read them): the layout
-- record's state (root, saved, records, wrote, writing, pending, save_timer, waiting_root), gen: the newest generation
-- sent, last: the pop-out last used (a view shown, pressed or put in front there), watch: the watch on desk-monitor's
-- sidecar while any is open, down: the editor is exiting and its pop-outs were told.
local L = H
L.gen = 0
local kinds = {}
M.kinds = kinds
M.MAX_STEPS = 50
local watch_screens, unwatch_screens, kind_failed

-- pops is a list (ids 1 to #pops, none ever removed). The pop-out a view names; whether one is open (attached, or on
-- its way); the words for one ('the pop-out' for the first, as there was only ever one, else 'pop-out 2').
local function pop_of(view) return view and pops[view.pop or 1] or nil end
local function is_open(p) return p ~= nil and (p.chan ~= nil or p.opening ~= nil) end
local function any_open() for _, p in ipairs(pops) do if is_open(p) then return true end end return false end
local function any_views() for _, p in ipairs(pops) do if next(p.views) ~= nil then return true end end return false end
local function named(p) return p.id == 1 and 'the pop-out' or ('pop-out ' .. p.id) end
-- The view called id, in whichever pop-out it is, and that pop-out.
local function find_view(id)
  for _, p in ipairs(pops) do if p.views[id] then return p.views[id], p end end
end
-- The view of kind `name` in pop-out p (its first), or nil.
local function kind_view(p, name)
  for _, id in ipairs(p.order) do
    local view = p.views[id]
    if view and view.kind == name then return view end
  end
end

-- Neovim is exiting (v:exiting is set before any exit autocommand runs) or the pop-out was told: nothing of the
-- pop-out runs then but its goodbye. An error in a callback during the exit makes Neovim wait for a key before it
-- quits, which :restart shows as a stall.
function M.exiting() return L.down == true or vim.v.exiting ~= vim.NIL end
local exiting = M.exiting

local function host_pane()
  local term, pane = vim.env.TERM or '', vim.env.TMUX_PANE or ''
  return ((term:match('^tmux') or term:match('^screen')) and pane:match('^%%%d+$')) and pane or ''
end

function M.focus_editor()
  M.focus({ pid = vim.fn.getpid(), pane = host_pane() })
end

-- The checkout a window shows (the current one by default): its file's, else its folder's.
local function checkout_of(win)
  win = (win and api.nvim_win_is_valid(win)) and win or api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local name = vim.bo[buf].buftype == '' and api.nvim_buf_get_name(buf) or ''
  local cwd = vim.fn.getcwd(win)
  if cwd == '' then cwd = vim.fn.getcwd() end
  local root = vim.fs.root(name ~= '' and name or cwd, '.git') or cwd
  return uv.fs_realpath(root) or root
end

local forget
local function send(p, msg)
  if not p.chan or p.stalled or exiting() then return false end
  msg.version = M.PROTOCOL
  local ok, err = pcall(vim.rpcnotify, p.chan, 'nvim_exec_lua', POPOUT_DOOR, { msg })
  if ok then return true end
  -- Not sent to a pop-out that is still there: the message could not be encoded. It is dropped and its view's kind
  -- named; the pop-out stays.
  if next(api.nvim_get_chan_info(p.chan)) ~= nil then
    local view = type(msg.id) == 'string' and p.views[msg.id]
    if view then kind_failed(view, err) else tell('Could not send ' .. named(p) .. ' a ' .. tostring(msg.type) .. ': ' .. tostring(err):sub(1, 200), WARN) end
    return false
  end
  forget(p, sentence(named(p) .. ' closed'), { back = true })
  return false
end

-- A pop-out still at the other end of chan is told why it goes (bye: it says so there, and quits) and its channel
-- closed: the editor never drops one that stays on screen with every key refused.
local function let_go(chan, why)
  if not chan or next(api.nvim_get_chan_info(chan)) == nil then return end
  pcall(vim.rpcnotify, chan, 'nvim_exec_lua', POPOUT_DOOR, { { version = M.PROTOCOL, type = 'bye', why = why or 'Closed.' } })
  pcall(vim.fn.chanclose, chan)
end

-- The highlight groups a view draws with, as this editor draws them (the pop-out may not define them): Desk* and the
-- FoxSymdeps* groups of the menus, never another plugin's.
local ATTRS = { fg = 'number', bg = 'number', sp = 'number', blend = 'number', bold = 'boolean', italic = 'boolean',
  underline = 'boolean', undercurl = 'boolean', underdouble = 'boolean', underdotted = 'boolean', underdashed = 'boolean',
  strikethrough = 'boolean', reverse = 'boolean', standout = 'boolean', nocombine = 'boolean' }
local function clean_hl(def)
  local out = {}
  for key, kind in pairs(ATTRS) do if type(def) == 'table' and type(def[key]) == kind then out[key] = def[key] end end
  return out
end
local function drawable(name) return type(name) == 'string' and (name:match('^Desk[%w_]+$') or name:match('^FoxSymdeps[%w_]+$')) ~= nil end
local function definitions(names)
  local out = {}
  for _, name in ipairs(type(names) == 'table' and names or {}) do
    if drawable(name) then out[name] = clean_hl(api.nvim_get_hl(0, { name = name, link = false })) end
  end
  return out
end

-- A footer's keys as she reads them, for a key line: { { ids = { row ids }, words } } → { { 'j/k/h/l', 'move' }, … },
-- each key spelled by the registry's one speller. rows: the rows a pop-out view binds, for an id the registry here does
-- not have (a stand-in for a row of the editor's: actions.popout_rows).
function M.key_pairs(footer, rows)
  local out, bound = {}, {}
  for _, row in ipairs(rows or {}) do bound[row.id] = row.key end
  for _, part in ipairs(footer or {}) do
    local keys = {}
    for _, id in ipairs(part.ids or {}) do
      local key = actions.key(id) or bound[id]
      if key then keys[#keys + 1] = actions.spell(key) end
    end
    if #keys > 0 then out[#out + 1] = { table.concat(keys, '/'), part.words } end
  end
  return out
end

-- ─── view kinds ────────────────────────────────────────────────────────────────────────────────────────────────
-- M.kind(spec) registers a kind of view, from its own module as that loads (desk.callgraph registers 'graph'), and
-- adds its row to the Views group of the home menu (in the editor; in the pop-out through describe). spec:
--   name, title, about   'graph' (the view's id and kind, its name in the pop-out's header), 'call graph' (its
--                        words), and its Views row's sentence; the row reads "Pop out the <title>", or spec.menu
--   surface      the in-editor surface whose keys the view has in the pop-out: there its drawn rows run on the
--                pop-out's copy (ctx.copy, desk.callgraph's selection model: { buf, win, drawn = { boxes }, index }),
--                its remote rows run in this editor with ctx_for's ctx, and a row with remote = false is not there.
--                Its remote row on Enter is what Enter, f and a double click do there. The pop-out's own keys win:
--                a surface row on one of them is left out there (actions.popout_rows). A plugin declares its
--                surface with actions.surface(name, words, module); with no module (fox-symdeps, which the pop-out
--                never loads) the pop-out has that surface's remote rows from describe, as stand-ins run here
--   render(view, width, style) → { title, state, lines, marks, hl, items, footer, strip, news }   pure: the view drawn
--                for the pop-out's width (style: vim.g.desk_style), with no keys and no state in its lines (the
--                header and the key line show them). state: its own words (progress, 'built 14:02'); PINNED and
--                following are drawn from the host's view.pinned and kind.follow, not from state; marks:
--                { line, from, to, group, priority }; hl: the Desk* and FoxSymdeps* groups it draws with (their
--                definitions go along); items: { key (≤ 120: the same item keeps it from one drawing to the next),
--                kind = 'box' or 'row', line (where the cursor goes), name_col, x, w, spans = { { line, from, to } }
--                (at most 8), centre (selected first), name, strip = { two lines }, ref (stays here; ctx_for gets
--                it) }; footer: { { ids = { row ids }, words } }, its key line (four or five keys); strip: the first of
--                the two lines that show the selected item's strip; news: something new is in it (an answer, a
--                failure): its name in the header is marked until she looks (view.news, cleared once sent)
--   available(ctx) → true | why | false   may it open from ctx (ctx.remote: asked from the pop-out)        (optional)
--   match(view, ctx) → boolean   kinds with several views reuse one only when it matches the request
--   mirror = true      render gives a snapshot with tick, lang and cursor. delta(view) gives a line range to
--                      replace, or nil, true to request a new snapshot.
--   open(view, ctx)        fills a view from where it was asked: the editor's ctx, a surface's with what it passed,
--                          or ctx.target (a function she named elsewhere: the notebook)
--   follow(view, event)    the editor moved: { type = 'moved' or 'unit', win } · { type = 'saved' or 'attached', buf } ·
--                          { type = 'pin' } (p flipped view.pinned). A kind with news of its own calls M.redraw(view)
--                          kind.follows = false: it has follow but does not follow the cursor (no ↻ in the header)
--                          view.follows = true: this view follows although its kind does not (the map, on a trace)
--   ctx_for(view, ref, index, line) → ctx   what a remote row runs with for that item; ctx.view, ctx.item (the ref),
--                          ctx.index, ctx.remote and ctx.also are added to it, and ctx.surface when it names none
--                          (the kind's surface: without it describe offers none of that surface's rows, and Enter, f
--                          and a double click find no Enter row; fox-symdeps' gives { win, origin, sel } — 2026-11-17,
--                          the board's keys did nothing in the pop-out); ctx.origin, when set, is the window
--                          its Enter moves (Ctrl+o takes the editor back there). An Enter row that only acted in the
--                          view (a zoom, a fold) sets ctx.stayed = true: f then keeps the keyboard in the pop-out
--   attach(view)           o in the pop-out, and each pinned view when the pop-out goes on its own: the view back in
--                          the editor as a split. Runs after the view is unlisted but before close releases it.
--   close(view)            the view left the pop-out: stop what it runs (timers, requests)
--   save(view) → saved, restore(view, saved)   the view's state and back. The history keeps what save gives (any
--                          table); the layout record keeps saved.pinned and saved.target as JSON, and restore gets
--                          { pinned, target } back after a restart. A kind that changes what its view shows (the
--                          graph's c) calls M.stepped(view, before), before = save(view) from just before, so Ctrl+o undoes it
-- A view (M.host.views[name]) is the kind's own table; id, kind, gen and pinned are the host's, and gone once it has
-- left the pop-out. select = an item's key and front = true go with the next M.redraw, once: the pop-out selects that
-- item, and shows that view.
local SPEC = { name = 'string', title = 'string', about = 'string', menu = 'string', surface = 'string', render = 'function',
  available = 'function', open = 'function', follow = 'function', ctx_for = 'function', attach = 'function', close = 'function',
  save = 'function', restore = 'function', follows = 'boolean', mirror = 'boolean', match = 'function',
  delta = 'function', place = 'function' }
local function kind_problem(spec)
  if type(spec) ~= 'table' then return 'a view kind is a table, not ' .. type(spec) end
  local name = type(spec.name) == 'string' and spec.name or '(no name)'
  for field, value in pairs(spec) do
    if not SPEC[field] then return name .. ': unknown field ' .. tostring(field) end
    if type(value) ~= SPEC[field] then return name .. ': ' .. field .. ' is a ' .. type(value) end
  end
  if #name > 24 or not name:match('^[%w_-]+$') then return name .. ': a name is one short word' end
  if (spec.title or '') == '' or (spec.about or '') == '' then return name .. ': needs a title and an about' end
  if not spec.render then return name .. ': has no render' end
  if not actions.SURFACES[spec.surface or ''] then return name .. ': no surface is called ' .. tostring(spec.surface) end
end

function M.kind(spec)
  local why = kind_problem(spec)
  if why then
    tell('A pop-out view was left out: ' .. why, vim.log.levels.ERROR)
    return nil, why
  end
  local name = spec.name
  kinds[name] = spec
  -- A view of this kind saved before it loaded (symdeps loads on its first C file): it comes back now.
  if M.restore_waiting then M.restore_waiting(name) end
  if M.restore_named then M.restore_named() end
  actions.add({ { id = 'popout.view.' .. name, group = 'Views', name = spec.menu or ('Pop out the ' .. spec.title), about = spec.about,
    on = 'editor', remote = true,
    available = function(ctx)
      local can = spec.available and spec.available(ctx)
      if can ~= nil and can ~= true then return can end
      return M.can_pop()
    end,
    run = function(ctx) M.show(name, ctx) end } })
  return spec
end

-- symdeps' board, a kind fox-symdeps registers when it is installed (its own module; this one never loads it): until
-- then its Views row is here, greyed with why, never hidden. M.kind from the plugin replaces it (the same id, added
-- from this file).
actions.add({ { id = 'popout.view.symdeps', group = 'Views', name = "Pop out symdeps' board", on = 'editor', remote = true,
  about = "symdeps' board, its cards at the pop-out's width. symdeps is an optional plugin",
  available = function()
    if not actions.symdeps() then return 'requires symdeps' end
    if not kinds.symdeps then return 'requires a symdeps with its board for the pop-out' end
    return M.can_pop()
  end,
  run = function(ctx) M.show('symdeps', ctx) end } })

-- A view as the pop-out draws it, from its kind: the message, and its items' refs and keys (kept here).
local function cut(value, cap) return type(value) == 'string' and value:sub(1, cap) or nil end
-- A kind's marks, spans and footer as plain numbers and strings, as the pop-out reads them: a table with named fields
-- among its list (a mark's priority written by name) or a function in it could not be sent at all.
local function num(value) return type(value) == 'number' and value or nil end
-- An item's click zones as sent: at most 4 { from, to, row id } (1-based columns; desk.review's zones_of).
local function plain_zones(zones)
  local out = {}
  for _, z in ipairs(type(zones) == 'table' and zones or {}) do
    if #out >= 4 then break end
    if type(z) == 'table' and type(z[1]) == 'number' and type(z[2]) == 'number' and type(z[3]) == 'string' and z[3]:match('^[%w_.-]+$') then
      out[#out + 1] = { z[1], z[2], z[3]:sub(1, 64) }
    end
  end
  return #out > 0 and out or nil
end
local function plain_marks(marks)
  local out = {}
  for _, m in ipairs(type(marks) == 'table' and marks or {}) do
    if type(m) == 'table' and num(m[1]) and num(m[2]) and num(m[3]) and type(m[4]) == 'string' then out[#out + 1] = { m[1], m[2], m[3], m[4], num(m[5]) } end
  end
  return out
end
local function plain_spans(spans)
  local out = {}
  for _, s in ipairs(type(spans) == 'table' and spans or {}) do
    if type(s) == 'table' and num(s[1]) and num(s[2]) and num(s[3]) then out[#out + 1] = { s[1], s[2], s[3] } end
  end
  return out
end
local function gauge_band(band, line)
  if type(band) ~= 'table' or type(line) ~= 'number' then return end
  local first, last = band[1], band[2]
  if type(first) == 'number' and type(last) == 'number' and first % 1 == 0 and last % 1 == 0
    and first >= 1 and first <= line and line <= last and line <= M.MAX_DRAWN then
    return { first, math.min(last, M.MAX_DRAWN) }
  end
end
local function plain_footer(footer)
  local out = {}
  for _, part in ipairs(type(footer) == 'table' and footer or {}) do
    if type(part) == 'table' and type(part.words) == 'string' then
      local ids = {}
      for _, id in ipairs(type(part.ids) == 'table' and part.ids or {}) do if type(id) == 'string' then ids[#ids + 1] = id end end
      out[#out + 1] = { ids = ids, words = part.words }
    end
  end
  return out
end
local function mirror_slice(lines, first, last)
  local out = {}
  for i = first, last do
    local line = lines[i]
    if #line > M.LINE_BYTES then
      local edge = M.LINE_BYTES - #'…' + 1
      while edge > 1 and line:byte(edge) >= 128 and line:byte(edge) < 192 do edge = edge - 1 end
      line = line:sub(1, edge - 1) .. '…'
    end
    out[#out + 1] = line
  end
  return out
end

-- A box's real neighbours (indexes of other items), for the dimming of a wide graph; nil when it has none.
local function plain_near(near)
  if type(near) ~= 'table' then return nil end
  local out = {}
  for _, j in ipairs(near) do if #out < M.MAX_ITEMS and type(j) == 'number' and j >= 1 and j <= M.MAX_ITEMS and j == math.floor(j) then out[#out + 1] = j end end
  return out
end
local function payload(view)
  local kind = kinds[view.kind]
  local ok, drawn = pcall(kind.render, view, pop_of(view).width or 80, vim.g.desk_style or 'paper')
  if not ok or type(drawn) ~= 'table' or type(drawn.lines) ~= 'table' then
    drawn = { lines = { '', '  This view could not be drawn: ' .. (tostring(ok and 'it gave no lines' or drawn):gsub('\n.*', '')):sub(1, 200) } }
  end
  local lines, marks = {}, plain_marks(drawn.marks)
  if kind.mirror then lines = mirror_slice(drawn.lines, 1, math.min(#drawn.lines, M.MAX_LINES))
  else for i, line in ipairs(drawn.lines) do lines[i] = tostring(line) end end
  if #lines > M.MAX_DRAWN then
    local more = #lines - (M.MAX_DRAWN - 1)
    lines = vim.list_slice(lines, 1, M.MAX_DRAWN - 1)
    lines[#lines + 1] = '… ' .. more .. ' more lines'
    marks = vim.tbl_filter(function(m) return m[1] < M.MAX_DRAWN end, marks)
  end
  local items, refs, keys = {}, {}, {}
  for i, item in ipairs(type(drawn.items) == 'table' and drawn.items or {}) do
    if i > M.MAX_ITEMS then break end
    refs[i], keys[i] = item.ref, tostring(item.key or i):sub(1, 120)
    items[i] = { key = keys[i], kind = item.kind == 'row' and 'row' or 'box', line = num(item.line), name_col = num(item.name_col), x = num(item.x),
      w = num(item.w), spans = plain_spans(item.spans), centre = item.centre == true, gauge = item.gauge == true,
      gauge_band = gauge_band(item.gauge_band, item.line), gauge_col = num(item.gauge_col),
      name = tostring(item.name or ''):sub(1, 200), where = cut(item.where, 120), mark = cut(item.mark, 16),
      strip = type(item.strip) == 'table' and { cut(item.strip[1], 400) or '', cut(item.strip[2], 400) or '' } or nil,
      keys = cut(item.keys, 300),
      near = plain_near(item.near),
      -- gj / gk's real calls (Codex's E7): the boxes it calls and that call it, and each call's place
      down = plain_near(item.down), up = plain_near(item.up), unrun = item.unrun == true or nil,
      down_sites = type(item.down_sites) == 'table' and vim.tbl_map(function(x) return cut(x, 120) or '' end, vim.list_slice(item.down_sites, 1, M.MAX_ITEMS)) or nil,
      up_sites = type(item.up_sites) == 'table' and vim.tbl_map(function(x) return cut(x, 120) or '' end, vim.list_slice(item.up_sites, 1, M.MAX_ITEMS)) or nil,
      zones = plain_zones(item.zones) }
  end
  -- headings, for the pop-out's own "where am I" once one has scrolled away (Codex's E8)
  local heads = {}
  for _, h in ipairs(type(drawn.heads) == 'table' and drawn.heads or {}) do
    if #heads >= 400 then break end
    if type(h) == 'table' and num(h.line) and h.text then
      heads[#heads + 1] = { line = num(h.line), last_line = num(h.last_line), first = num(h.first), last = num(h.last),
        text = tostring(h.text):sub(1, 200), of = cut(h.of, 12), count = h.count ~= false }
    end
  end
  view.named_as = cut(drawn.title, 200) or kind.title
  return { type = 'view.set', id = view.id, kind = view.kind, surface = kind.surface, title = cut(drawn.title, 200) or kind.title,
    tab = cut(drawn.tab, 24), subject = cut(drawn.subject, 60),
    -- another pop-out previews this one's selection (gp there): its selection is told as it moves
    previewed = kind.place ~= nil and M.preview_pop ~= nil and M.preview_pop ~= view.pop or nil,
    -- a gp pair names its partner (Codex's #6): the driving view says where its preview is, the preview what drives it
    partner = M.partner_of(view, kind),
    partner_line = view.previewing and M.preview_from and M.preview_from.line or nil,
    state = cut(drawn.state, 200) or '', lines = lines, marks = marks, hl = definitions(drawn.hl), items = items,
    heads = #heads > 0 and heads or nil,
    footer = plain_footer(drawn.footer), strip = num(drawn.strip), news = drawn.news == true,
    pinned = view.pinned == true, follows = kind.follow ~= nil and (kind.follows ~= false or view.follows == true),
    tick = kind.mirror and (drawn.tick or 0) or nil, total = kind.mirror and #drawn.lines or nil,
    lang = drawn.lang, cursor = drawn.cursor }, refs, keys, drawn.lines
end

M._payload = payload -- a view's view.set message, for tests

-- One queue per view. Send the rest of a snapshot first, then the edits that arrived while it was in flight.
function M.mirror_changed(view)
  if view.mirror_queued or not M.holds(view) then return end
  view.mirror_queued = true
  vim.defer_fn(function()
    view.mirror_queued = false
    local p = pop_of(view)
    if not M.holds(view) or not p.chan or p.stalled or exiting() or view.mirror_pop ~= p.id then return end
    local snapshot = view.snapshot
    local message
    if snapshot then
      local first = snapshot.sent
      local last = math.min(first + M.MAX_LINES, #snapshot.lines)
      message = { first = first, last = first, lines = mirror_slice(snapshot.lines, first + 1, last),
        tick = view.mirror_tick, total = #snapshot.lines, chunk = true }
      snapshot.sent = last
      if last == #snapshot.lines then view.snapshot = nil end
    else
      local kind = kinds[view.kind]
      local full
      message, full = kind.delta(view)
      if full then return M.redraw(view) end
      if not message then return end
      message.lines = mirror_slice(message.lines, 1, #message.lines)
    end
    message.type, message.id, message.gen, message.from = 'view.lines', view.id, view.gen, view.mirror_tick
    if send(p, message) then
      view.mirror_tick = message.tick
      if snapshot then M.mirror_changed(view) end
    end
  end, M.GAP_MS)
end

-- Sends a view as it is now, one per view every M.GAP_MS at most (the last state wins). A new generation only when its
-- lines or its items changed: the same drawing sent again (it answers again, a resize to the same width) keeps the
-- items it named.
function M.redraw(view)
  local p = pop_of(view)
  if not p or view.gone or p.views[view.id] ~= view or not p.chan or p.stalled or exiting() then return end
  local wait = (view.sent or -M.GAP_MS) + M.GAP_MS - uv.now()
  if wait > 0 then
    if not view.queued then
      view.queued = true
      vim.defer_fn(function() view.queued = false; M.redraw(view) end, wait)
    end
    return
  end
  view.sent = uv.now()
  local msg, refs, keys, full = payload(view)
  local drawing = not msg.tick and (table.concat(msg.lines, '\n') .. '\0' .. table.concat(keys, '\1')) or nil
  -- A resize or retry may resend the same code revision while a key for it is on its way.
  local changed = (msg.tick ~= nil and msg.tick ~= view.mirror_tick) or drawing ~= view.drawing
  if not view.gen or changed then
    L.gen = L.gen + 1
    view.gen, view.drawing = L.gen, drawing
  end
  view.refs, view.count = refs, #msg.items
  msg.gen, msg.select, msg.front = view.gen, cut(view.select, 120), view.front == true
  msg.behind = view.behind == true or nil
  view.behind = nil
  -- The views this editor has there: the pop-out closes a tab of any other (a view.clear it never got, made while it
  -- did not answer and so never sent).
  msg.views, msg.tiled = p.order, p.tiled == true
  if send(p, msg) then
    view.select, view.front, view.news = nil, nil, nil
    if msg.tick then
      view.mirror_tick, view.mirror_pop = msg.tick, p.id
      view.snapshot = #full > #msg.lines and { lines = full, sent = #msg.lines } or nil
      if view.snapshot then M.mirror_changed(view) end
    end
  end
end
-- Every view of pop-out p sent again in the order of its tabs (a pop-out makes a view's tab when it first arrives, so
-- this order is the tabs' order), then the one in front once more to bring it forward (a moment later: one send per
-- view every M.GAP_MS).
local function redraw_all(p, resized)
  local function needs_redraw(view)
    -- Code snapshots do not depend on width. Sending one again would allocate and transfer the whole file.
    return view and (not resized or not kinds[view.kind].mirror or view.mirror_pop ~= p.id)
  end
  local front = p.front and p.views[p.front]
  for _, id in ipairs(p.order) do
    local view = p.views[id]
    if needs_redraw(view) then view.sent = nil; M.redraw(view) end
  end
  if needs_redraw(front) then front.front = true; M.redraw(front) end
end

-- ─── the editor moving, for the views that follow it ───────────────────────────────────────────────────────────
-- One set of autocommands while any view is out, each event given to every view's kind (follow).
kind_failed = function(view, err)
  if view.failed then return end
  view.failed = true   -- said once, not on every cursor move
  tell('The ' .. (kinds[view.kind] and kinds[view.kind].title or tostring(view.kind)) .. ' view failed: ' .. tostring(err):sub(1, 200), WARN)
end
local function follow_one(view, event)
  local kind = kinds[view.kind]
  if view.gone or not (kind and kind.follow) then return end
  local ok, err = pcall(kind.follow, view, event)
  if not ok then kind_failed(view, err) end
end
local function dispatch(event)
  if exiting() then return end
  for _, p in ipairs(pops) do
    for _, view in pairs(p.views) do follow_one(view, event) end
  end
end
local function follow_start()
  local group = api.nvim_create_augroup('desk_popout_follow', { clear = true })
  api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter', 'InsertLeave' }, { group = group,
    callback = function() dispatch({ type = 'moved', win = api.nvim_get_current_win() }) end })
  -- symdeps' follow card moves on FoxUnitChanged, at once: a following view moves with it.
  api.nvim_create_autocmd('User', { group = group, pattern = 'FoxUnitChanged',
    callback = function() dispatch({ type = 'unit', win = api.nvim_get_current_win() }) end })
  api.nvim_create_autocmd('BufWritePost', { group = group, callback = function(a) dispatch({ type = 'saved', buf = a.buf }) end })
  api.nvim_create_autocmd('BufModifiedSet', { group = group, callback = function(a) dispatch({ type = 'modified', buf = a.buf }) end })
  api.nvim_create_autocmd({ 'BufFilePost', 'FileType' }, { group = group,
    callback = function(a) dispatch({ type = 'file', buf = a.buf }) end })
  api.nvim_create_autocmd('LspAttach', { group = group, callback = function(a) dispatch({ type = 'attached', buf = a.buf }) end })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = function()
    if not exiting() then for _, p in ipairs(pops) do redraw_all(p) end end
  end })
end
local function follow_stop() pcall(api.nvim_del_augroup_by_name, 'desk_popout_follow') end

local function leave(view, hand_back, line)
  view.gone = true
  local kind = kinds[view.kind]
  -- A stateful view may transfer resources to the editor during attach, before close releases any it still owns.
  local returned = false
  if hand_back and kind and kind.attach then
    local ok, err = pcall(kind.attach, view, line)
    if ok then returned = true
    else tell(sentence('it could not come back: ' .. tostring(err):sub(1, 200)), WARN) end
  end
  if kind and kind.close then
    local ok, err = pcall(kind.close, view)
    if not ok then kind_failed(view, err) end
  end
  return returned
end
local function unlist(p, id) for i, other in ipairs(p.order) do if other == id then table.remove(p.order, i); return end end end

-- Takes a view off its pop-out (it goes back to the editor, she closed it there, or its kind took it off: the review
-- closing), and writes the layout record so a view gone is never restored.
local function clear_view(id, hand_back, line)
  local view, p = find_view(id)
  if not view then return end
  p.views[id] = nil
  unlist(p, id)
  if p.front == id then p.front = nil end
  leave(view, hand_back, line)
  if not any_views() then follow_stop() end
  send(p, { type = 'view.clear', id = id })
  M.save_layout()
end

function M.clear(id) clear_view(id) end

-- Pop-out p is gone, or let go (→ closed): nothing more is sent to it and nothing follows the cursor for it; the other
-- pop-outs go on. One still running (q on what is its last view here, a fold) is told why and its channel closed, so
-- it never stays with every key refused; opts.leaving: it is quitting by itself (q on its last view there) and is told
-- nothing. opts.back: it went on its own (it closed or crashed, or its screen was unplugged): its pinned views come
-- back to the editor as splits (their kind's attach), the following ones stop, and one notice says so; opts.all: it
-- never showed them (it did not start), so every view comes back. Her q on its last view brings nothing back.
forget = function(p, why, opts)
  opts = opts or {}
  -- A write of the views still on its way is written now, while they are here: a fold right after a change keeps them.
  M.flush_layout()
  local chan = p.chan
  local had = chan ~= nil or next(p.views) ~= nil
  p.chan, p.pid, p.kitty, p.stalled, p.opening, p.front, p.screen, p.prefer = nil, nil, nil, false, nil, nil, nil, nil
  if p.timer then p.timer:stop() end
  if not any_open() then unwatch_screens() end
  if not opts.leaving then let_go(chan, why) end
  local views, order = p.views, p.order
  -- q on its last view there: what it showed, closed by her.
  if opts.leaving then
    for _, id in ipairs(order) do if views[id] then M.remember_closed(views[id], p) end end
  end
  p.views, p.order, p.history, p.tiled = {}, {}, { steps = {}, at = 0 }, nil
  local returned = 0
  for _, id in ipairs(order) do
    local view = views[id]
    if view and leave(view, opts.all or (opts.back and view.pinned)) then returned = returned + 1 end
  end
  if not any_views() then follow_stop() end
  if had and why and not opts.quiet then
    local its = opts.all and ' Its' or ' Its pinned'
    tell(why .. (returned == 0 and '' or returned == 1 and (its .. ' view is back here.') or (its .. ' views are back here.')),
      opts.all and WARN or nil)
  end
  return returned, had
end
-- The first pop-out, or the one named (p).
function M.forget(why, opts, p) return forget(p or H, why, opts) end

local function start_pings(p)
  p.timer = p.timer or uv.new_timer()
  p.timer:stop()
  p.timer:start(M.PING_MS, M.PING_MS, vim.schedule_wrap(function()
    if exiting() then return end
    if not p.chan then return p.timer:stop() end
    if next(api.nvim_get_chan_info(p.chan)) == nil then return forget(p, sentence(named(p) .. ' closed'), { back = true }) end
    if p.ping > p.heard and not p.stalled then
      p.stalled = true
      tell(sentence(named(p) .. ' stopped answering; nothing more is sent to it until it does'), WARN)
    end
    p.ping = p.ping + 1
    pcall(vim.rpcnotify, p.chan, 'nvim_exec_lua', POPOUT_DOOR, { { version = M.PROTOCOL, type = 'ping', serial = p.ping } })
  end))
end

-- The pop-out window appears floating at the side of the screen it opens on (the Hyprland rule, which also keeps the
-- focus here). Then it moves, tiled, to the workspace showing on `screen` ({ name, workspace }; by default the screen
-- M.target_screen picks, a restore's screen first), and p.screen says which (p: the pop-out, the first by default).
-- pid: its kitty's. Each time, Hyprland's own list of windows says whether it took: still elsewhere it is moved again,
-- still floating it is tiled again, up to M.PLACE_TRIES more times, then it says so (2026-11-16: moved to another
-- screen it stayed floating there, not tiled beside the windows already there). A window never found is said too.
M.PLACE_TRIES = 3
function M.place(pid, screen, p)
  p = p or H
  if type(pid) ~= 'number' or not have('hyprctl') then return end
  hyprctl({ 'monitors' }, function(monitors)
    screen = screen or chosen_screen(monitors, p) or M.target_screen(monitors, M.screens(), p.prefer)
    if not screen then return end
    local where, looked, tried = tostring(screen.workspace), 0, 0
    local function look()
      looked = looked + 1
      hyprctl({ 'clients' }, function(clients)
        local c
        for _, w in ipairs(type(clients) == 'table' and clients or {}) do
          if type(w) == 'table' and w.pid == pid and w.class == M.CLASS and type(w.address) == 'string' and w.address:match('^0x%x+$') then c = w end
        end
        if not c then
          if looked < 30 then return vim.defer_fn(look, 100) end
          if tried == 0 then tell(sentence(named(p) .. "'s window was not found, so it stays where it opened"), WARN) end
          return
        end
        p.screen = screen.name
        local ws = type(c.workspace) == 'table' and tonumber(c.workspace.id) or nil
        local there, floating = ws == screen.workspace, c.floating == true
        -- A list without these (another Hyprland) cannot say: it is placed once.
        if tried > 0 and (ws == nil or type(c.floating) ~= 'boolean' or (there and not floating)) then return end
        if tried > M.PLACE_TRIES then
          return tell(sentence(('%s is still %s: Hyprland did not tile it on %s'):format(named(p), there and 'floating' or 'on another workspace', screen.name)), WARN)
        end
        tried = tried + 1
        local address = c.address
        local function tile()
          M.dispatch(("hl.dsp.window.float({ action = 'unset', window = 'address:%s' })"):format(address), 'settiled address:' .. address,
            function() looked = 0; look() end)
        end
        if tried > 1 and there then return tile() end
        M.dispatch(("hl.dsp.window.move({ workspace = '%s', follow = false, window = 'address:%s' })"):format(where, address),
          ('movetoworkspacesilent %s,address:%s'):format(where, address), tile)
      end)
    end
    look()
  end)
end

-- kitty's exit is the pop-out's end. One that never subscribed did not start: every view it was to show comes back here
-- (none was seen there). One that did is gone: its pinned views come back, as when it crashed.
local function kitty_exited(p, opening)
  if exiting() then return end
  if p.opening == opening then return forget(p, sentence(named(p) .. ' did not start'), { all = true }) end
  if p.kitty == opening.pid then forget(p, sentence(named(p) .. ' closed'), { back = true }) end
end

-- Opens pop-out p (closed → opening) when it is not attached or on its way. true, or false and why. root: the
-- checkout the layout record is filed under (by default the one in front), when no other pop-out is open: one record
-- for them all, until the next opens with none open.
local function open_pop(p, root)
  -- One whose channel is already gone (its window closed a moment ago) is forgotten first, so a new one opens.
  if p.chan and next(api.nvim_get_chan_info(p.chan)) == nil then forget(p, sentence(named(p) .. ' closed'), { back = true }) end
  if p.chan or p.opening then return true end
  local server = vim.v.servername or ''
  if #server > 107 or not server:match('^/[%w%._/%-]+$') then return false, 'this editor has no socket the pop-out can reach' end
  if not have('kitty') then return false, 'requires kitty' end
  -- The socket travels in argv only. The pop-out's Neovim gets none of this editor's tmux (its footer is this
  -- editor's) and no $NVIM (it is not a terminal inside this editor). Not NVIM_NOTTYFAST: with it Neovim 0.12 never
  -- takes a resize, and the pop-out kept the size it opened at, floating at the side (2026-11-16, seen in a VM: 61
  -- columns in a 186-column window). A slow first answer from kitty may show E1568 once; that is the lesser cost.
  -- g:desk_popout is its id (1 for the first), which every message it sends names.
  local argv = { 'kitty', '--class', M.CLASS, '-e', 'nvim', '--cmd', 'let g:desk_popout=' .. p.id, '-c', "lua require('desk.popout').client()",
    '--', 'desk-popout:' .. server }
  local opening = {}
  local env = { TMUX = '', TMUX_PANE = '', NVIM = '' }
  local ok, job = pcall(vim.system, argv, { text = true, detach = true, env = env }, function()
    vim.schedule(function() kitty_exited(p, opening) end)
  end)
  if not ok then return false, 'kitty did not start (' .. tostring(job):sub(1, 120) .. ')' end
  opening.pid = job.pid
  if not any_open() then L.root = root or checkout_of() end
  p.opening, p.kitty = opening, job.pid
  M.place(job.pid, nil, p)
  vim.defer_fn(function()
    if p.opening == opening and not exiting() then forget(p, sentence(named(p) .. ' did not start'), { all = true }) end
  end, M.START_MS)
  return true
end
-- The first pop-out, or the one called id.
function M.open(root, id) return open_pop(id and pops[id] or H, root) end

-- A pop-out to open for a view she sends to a new one: the first closed one with nothing in it (its id used again),
-- else one more. Its id, or nil and why.
function M.new_pop()
  for _, p in ipairs(pops) do if not is_open(p) and next(p.views) == nil then return p.id end end
  if #pops >= M.MAX_POPS then return nil, ('%d pop-outs are open, the most there may be'):format(#pops) end
  pops[#pops + 1] = new_pop(#pops + 1)
  return #pops
end

-- Whether the pop-out can be opened from here: true, or why not; false where it does not apply (in a pop-out, or a
-- work viewer).
function M.can_pop()
  if M.is_popout() or vim.g.desk_work_view then return false end
  if not have('kitty') then return 'requires kitty' end
  return M.second_screen()
end
local function refused_here(why)
  if why == true then return false end
  tell(sentence(why == false and 'not here' or why), WARN)
  return true
end

-- ─── history: Ctrl+o and Backspace go back, Ctrl+r forward ─────────────────────────────────────────────────────
-- Each pop-out's own. Steps, each undone by Ctrl+o or Backspace and done again by Ctrl+r: a switch between views; an
-- Enter (the code spot the editor was at, and the view's state from before for a kind that keeps one: one step, so one Ctrl+o puts back both the file
-- the review showed and the spot); a view's content changing (its kind's save from before: a graph centred on another
-- function). What Ctrl+r brings back is what Ctrl+o left (taken when it undoes it), so a graph still being read when it was
-- centred comes back read. At most M.MAX_STEPS; a new step drops the ones ahead of it.
local function push_step(p, step)
  local h = p.history
  -- where Back goes, said (Codex's E14): the code spot an Enter left, the view a switch left, a view's title before it changed
  if not step.label then
    if step.type == 'enter' and step.before then
      local name = api.nvim_buf_is_valid(step.before.buf) and api.nvim_buf_get_name(step.before.buf) or ''
      step.label = (name ~= '' and vim.fs.basename(name) or 'the editor') .. ':' .. tostring(step.before.cursor and step.before.cursor[1] or '?')
    else
      local v = p.views[step.type == 'switch' and step.from or step.view]
      step.label = v and (v.named_as or v.kind) or nil
    end
  end
  for i = #h.steps, h.at + 1, -1 do h.steps[i] = nil end
  h.steps[#h.steps + 1] = step
  while #h.steps > M.MAX_STEPS do table.remove(h.steps, 1) end
  h.at = #h.steps
end

-- A kind changed what its view shows (before: its save from just before): a step Ctrl+o can undo.
-- During an Enter in that view (its pop-out's folding) the change is part of the Enter's own step, which keeps the view's state from
-- before it: one Ctrl+o undoes both.
function M.stepped(view, before)
  local kind, p = view and kinds[view.kind], pop_of(view)
  if not (kind and kind.save and kind.restore and p) or view.gone or p.views[view.id] ~= view or type(before) ~= 'table' then return end
  if p.folding == view.id then return end
  push_step(p, { type = 'state', view = view.id, before = before })
end

-- A view put in front of its pop-out. Any other view there that was to come forward with its next drawing (one held
-- back M.GAP_MS) no longer does: it never takes the window back from this one.
local function to_front(view)
  local p = pop_of(view)
  p.front, L.last = view.id, p.id
  for _, other in pairs(p.views) do if other ~= view then other.front = nil end end
  view.front = true
  M.redraw(view)
end

-- Where the editor is: the window an Enter moves (win, else the current one), its buffer and cursor.
local function main_spot(win)
  win = (win and api.nvim_win_is_valid(win)) and win or api.nvim_get_current_win()
  return { win = win, buf = api.nvim_win_get_buf(win), cursor = api.nvim_win_get_cursor(win) }
end
local function put_spot(spot)
  if not (spot and api.nvim_win_is_valid(spot.win)) then return false end
  if api.nvim_buf_is_valid(spot.buf) and api.nvim_win_get_buf(spot.win) ~= spot.buf then pcall(api.nvim_win_set_buf, spot.win, spot.buf) end
  pcall(api.nvim_win_set_cursor, spot.win, spot.cursor)
  pcall(api.nvim_set_current_win, spot.win)
  return true
end

-- A step undone (again: done again). false when what it names is gone, so the walk goes on past it.
local function apply(p, step, again)
  if step.type == 'switch' then
    local view = p.views[again and step.to or step.from]
    if not view then return false end
    to_front(view)
  elseif step.type == 'enter' then
    -- The view's state first (it may show another file in the editor), then the editor's exact spot.
    local view = p.views[step.view]
    local kind = view and kinds[view.kind]
    if not again then
      if not step.code_after then step.after = main_spot(step.before.win) end
      if step.saved and kind and kind.save then
        local fine, now = pcall(kind.save, view)
        step.after_saved = fine and type(now) == 'table' and now or nil
      end
    end
    local saved = again and step.after_saved or step.saved
    if saved and kind and kind.restore then
      local fine, err = pcall(kind.restore, view, saved)
      if not fine then kind_failed(view, err) end
    end
    if not put_spot(again and (step.code_after or step.after) or step.before) and not saved then return false end
    if view and (saved or p.front ~= view.id) then to_front(view) end
  elseif step.type == 'state' then
    local view = p.views[step.view]
    local kind = view and kinds[view.kind]
    if not (kind and kind.restore and kind.save) then return false end
    if not again then
      local ok, now = pcall(kind.save, view)
      step.after = ok and now or nil
    end
    local saved = again and step.after or step.before
    if type(saved) ~= 'table' then return false end
    local ok, err = pcall(kind.restore, view, saved)
    if not ok then kind_failed(view, err) end
    to_front(view)
  else return false end
  return true
end

-- In pop-out p (the first by default).
function M.history_back(p)
  p = p or H
  local h = p.history
  while h.at >= 1 do
    local step = h.steps[h.at]
    h.at = h.at - 1
    if apply(p, step, false) then return true end
  end
  tell('Nothing further back.')
  return false
end
--- Where Back goes next in pop-out p (the first by default): its step's label, or nil (Codex's E14).
function M.back_said(p)
  p = p or H
  local h = p and p.history
  local step = h and h.steps[h.at]
  return step and step.label or nil
end
--- The recent steps back, nearest first, at most 10: { { id = its place in the history, name = its label } }.
function M.back_steps(p)
  p = p or H
  local h, out = p and p.history, {}
  for i = (h and h.at or 0), math.max(1, (h and h.at or 0) - 9), -1 do
    out[#out + 1] = { id = tostring(i), name = h.steps[i].label or h.steps[i].type }
  end
  return out
end
--- Back to step k at once: every step from the nearest down to k undone (the editor too, as Back does each).
function M.history_back_to(p, k)
  p = p or H
  local h = p and p.history
  k = tonumber(k)
  if not (h and k and k >= 1 and k <= h.at) then return false end
  while h.at >= k do
    local step = h.steps[h.at]
    h.at = h.at - 1
    apply(p, step, false)
  end
  return true
end
function M.history_forward(p)
  p = p or H
  local h = p.history
  while h.at < #h.steps do
    h.at = h.at + 1
    if apply(p, h.steps[h.at], true) then return true end
  end
  tell('Nothing further forward.')
  return false
end

-- ─── the layout record: the pop-out's views in desk-work, offered again after a restart ────────────────────────
-- desk-work workspace --client popout, per checkout: { version, tabs = { { kind, pinned, target } }, activeTab = the
-- view in front, show = { screen, pops = { { id, tabs, activeTab, screen } } } } (keys its allow-list has): the first
-- pop-out's tabs, front and screen where they have always been, and every other pop-out that shows something in
-- show.pops, each with its own (desk-work keeps only the keys it allows at the top; a record from before several
-- pop-outs is the one-pop-out case of the same shape, and M.record_pops reads either as one list). Written when a view opens, closes, is pinned or centred,
-- and when the editor exits; read at start, so the Views group offers "Restore 2 views". The selection inside a view is
-- not kept: a restored graph selects its centre.
-- Each record belongs to a checkout. The open pop-out's is filed under the one it opened in (L.root), whatever is in
-- front when it is written; the one offered (L.saved) is the record of the checkout in front (L.saved_root), read again
-- whenever that changes. L.records: the records read or written, by checkout (false: there is none); L.wrote: writes
-- made, by checkout (a read that started before one is older than it).
local RESTORE   -- its row, named for what the record holds
L.records, L.wrote = {}, {}
local function layout_root() return L.root or checkout_of() end

-- Views she closed (q, or :q there), newest last, per checkout: gu in a pop-out (or the editor's menu) opens the last one
-- again, as a restart restores one (its kind's save and restore), in the pop-out it was in. A view that went back to
-- the editor (o) or a pop-out that crashed is not one she closed.
M.CLOSED_KEEP = 8
L.closed = {}   -- root → { { kind, pinned, target, pop, named } }
function M.remember_closed(view, p)
  local kind = view and kinds[view.kind]
  if not (kind and kind.save and kind.restore) then return end
  local ok, saved = pcall(kind.save, view)
  if not (ok and type(saved) == 'table') then return end
  local root = layout_root()
  local list = L.closed[root] or {}
  L.closed[root] = list
  list[#list + 1] = { kind = view.kind, pinned = view.pinned == true, target = type(saved.target) == 'table' and saved.target or nil,
    pop = p and p.id or 1, named = view.named_as or kind.title }
  while #list > M.CLOSED_KEEP do table.remove(list, 1) end
end
function M.closed_views() return L.closed[layout_root()] or {} end
local function restore_named()
  if not RESTORE then return end
  -- Only what can come back now: a tab whose kind has not loaded yet waits for it (its pop-out's waiting).
  local n = 0
  for _, saved in ipairs(M.record_pops(L.saved)) do
    for _, tab in ipairs(saved.tabs) do
      if type(tab) == 'table' and kinds[tab.kind] then n = n + 1 end
    end
  end
  RESTORE.name = n == 0 and "Restore the pop-out's views" or n == 1 and 'Restore 1 view' or ('Restore %d views'):format(n)
end
M.restore_named = restore_named   -- a kind registering changes what Restore can bring back (and the tests ask)
-- The record offered here: the one of the checkout in front.
local function offer(front)
  L.saved_root, L.saved = front, L.records[front] or nil
  restore_named()
end
-- A layout record's pop-outs, in either shape, as one list { { id, tabs, activeTab, screen } }: the first's from the
-- record's own tabs, activeTab and show.screen, the others from show.pops (ids 2 to M.MAX_POPS, each once).
function M.record_pops(record)
  if type(record) ~= 'table' then return {} end
  local show = type(record.show) == 'table' and record.show or {}
  local function text(value) return type(value) == 'string' and value or nil end
  local function tabs(value) return type(value) == 'table' and value or {} end
  local out, seen = { { id = 1, tabs = tabs(record.tabs), activeTab = text(record.activeTab), screen = text(show.screen),
    tiled = show.tiled == true or nil } }, { true }
  for _, saved in ipairs(type(show.pops) == 'table' and show.pops or {}) do
    local id = type(saved) == 'table' and tonumber(saved.id)
    if id and id == math.floor(id) and id >= 2 and id <= M.MAX_POPS and not seen[id] then
      seen[id] = true
      out[#out + 1] = { id = id, tabs = tabs(saved.tabs), activeTab = text(saved.activeTab), screen = text(saved.screen),
        tiled = saved.tiled == true or nil }
    end
  end
  return out
end
local function saved_views(record)
  for _, saved in ipairs(M.record_pops(record)) do if #saved.tabs > 0 then return true end end
  return false
end
-- Pop-out p's tabs, as the record keeps them.
local function tabs_of(p)
  local tabs = {}
  for _, id in ipairs(p.order) do
    local view = p.views[id]
    local kind = view and kinds[view.kind]
    if kind and kind.save then
      local ok, saved = pcall(kind.save, view)
      if ok and type(saved) == 'table' then
        tabs[#tabs + 1] = { kind = view.kind, pinned = view.pinned == true, id = kind.match and id or nil,
          target = type(saved.target) == 'table' and saved.target or nil }
      end
    end
  end
  -- Tabs of a kind not loaded yet are written back as they were, so the first write after a restart keeps them.
  if L.waiting_root == layout_root() then for _, saved in ipairs(p.waiting) do tabs[#tabs + 1] = saved end end
  return tabs
end
local function layout_record()
  local others = {}
  for _, p in ipairs(pops) do
    local tabs = p ~= H and tabs_of(p) or {}
    if #tabs > 0 then others[#others + 1] = { id = p.id, tabs = tabs, activeTab = p.front, screen = p.screen, tiled = p.tiled } end
  end
  return { version = 1, tabs = tabs_of(H), activeTab = H.front,
    show = { screen = H.screen, pops = #others > 0 and others or nil, tiled = H.tiled } }
end
-- A write that failed is said, in desk-work's own words when it gave some.
local function not_saved(out)
  local said = vim.trim(((out.stderr or '') ~= '' and out.stderr or (out.stdout or '')):match('^[^\n]*') or '')
  tell(sentence("the pop-out's views were not saved" .. (said ~= '' and (': ' .. said:sub(1, 160)) or (' (desk-work exited ' .. tostring(out.code) .. ')'))), WARN)
end
-- One write at a time, in the order asked: a change made while a write is on its way waits for it, and only the newest
-- of those goes after it (L.pending), so an older state never lands after a newer one. wait: the editor is exiting:
-- the write on its way is waited for (a second at most), then this one is written, now.
local function write_now(w, wait)
  local argv = { 'desk-work', 'workspace', '--root', w.root, '--client', 'popout', '--input', '-' }
  if wait then
    if L.writing then pcall(L.writing.wait, L.writing, 1000) end
    L.writing, L.pending = nil, nil
    local started, job = pcall(vim.system, argv, { stdin = w.json, text = true, timeout = 5000 })
    if started then pcall(job.wait, job, 1000) end
    return
  end
  local job
  local started = pcall(function()
    job = vim.system(argv, { stdin = w.json, text = true, timeout = 5000 }, vim.schedule_wrap(function(out)
      if L.writing == job then L.writing = nil end
      if exiting() then return end
      if out.code ~= 0 then not_saved(out) end
      local after = L.pending
      L.pending = nil
      if after then write_now(after) end
    end))
  end)
  if not started then return not_saved({ code = -1, stderr = 'desk-work did not start' }) end
  L.writing = job
end
local function write_layout(wait)
  local record = layout_record()
  local ok, json = pcall(vim.json.encode, record)
  if not ok then return end
  local root = layout_root()
  L.records[root], L.wrote[root] = record, (L.wrote[root] or 0) + 1
  if root == L.saved_root then offer(root) end
  local w = { root = root, json = json }
  if not wait and L.writing then L.pending = w; return end
  write_now(w, wait)
end
-- The writes of a moment (a view closing, then the one in front changing) go as one, M.SAVE_MS after the last. wait:
-- the editor is exiting, so the record is written now, before it goes (a second at most).
M.SAVE_MS = 300
-- The write still on its way, now (nothing when none is).
function M.flush_layout()
  if L.save_timer and L.save_timer:is_active() then
    L.save_timer:stop()
    write_layout(false)
  end
end
function M.save_layout(wait)
  if M.is_popout() or vim.g.desk_work_view or not have('desk-work') then return end
  L.save_timer = L.save_timer or uv.new_timer()
  L.save_timer:stop()
  if wait then return write_layout(true) end
  L.save_timer:start(M.SAVE_MS, 0, vim.schedule_wrap(function() if not exiting() then write_layout(false) end end))
end
-- The record of checkout root (by default the one in front), read; done(record or nil).
function M.read_layout(done, root)
  done = done or function() end
  if M.is_popout() or vim.g.desk_work_view or not have('desk-work') then return done(nil) end
  root = root or checkout_of()
  local seen = L.wrote[root] or 0
  local ok = pcall(vim.system, { 'desk-work', 'workspace', '--root', root, '--client', 'popout' }, { text = true, timeout = 5000 },
    vim.schedule_wrap(function(out)
      local decoded, record = pcall(vim.json.decode, out.code == 0 and out.stdout or '')
      -- A write made since it started is newer than what it read.
      if (L.wrote[root] or 0) == seen then
        L.records[root] = decoded and type(record) == 'table' and type(record.tabs) == 'table' and record or false
      end
      if root == L.saved_root then offer(root) end
      done(L.records[root] or nil)
    end))
  if not ok then done(nil) end
end
-- The checkout in front changed (another file, another folder): Restore offers that checkout's record, read again.
local function front_moved()
  if exiting() then return end
  local front = checkout_of()
  if front == L.saved_root then return end
  offer(front)
  M.read_layout(nil, front)
end

-- ─── views in and out ──────────────────────────────────────────────────────────────────────────────────────────
-- A new view's id: its kind's name while no view has it, else kind.2, kind.3, …
local function new_id(kind)
  if not find_view(kind) then return kind end
  for n = 2, 99 do if not find_view(kind .. '.' .. n) then return kind .. '.' .. n end end
end
local function add_view(p, kind)
  local id = new_id(kind)
  local view = { id = id, kind = kind, pop = p.id, gen = 0, pinned = false }
  p.views[id] = view
  p.order[#p.order + 1] = id
  follow_start()
  return view
end

-- The pop-out she last sent a view of each kind to (kind → id): the kind's views go there while it is open.
local homes = {}
-- Where a view of kind `name` goes: the pop-out asked for (want), else the one she sent a view of it to, while that
-- view is there, else the first that has a view of it, else that one while it is open, else the first. So every
-- view goes to the first pop-out unless she sends it elsewhere, and no other opens by itself.
local function pop_for(name, want)
  if want then return pops[want] end
  local home = homes[name] and pops[homes[name]]
  if home and kind_view(home, name) then return home end
  for _, p in ipairs(pops) do if kind_view(p, name) then return p end end
  if is_open(home) then return home end
  return H
end

-- A view of kind `name` in its pop-out (pop_for; opts.pop: that one), opening the window when it is not open. A new
-- view is filled by its kind from ctx; asked for again from the editor (o in another graph, its Views row) it is
-- filled again from there; asked for from the pop-out (ctx.remote) it only comes to the front. Either way, from
-- another view, it is a step Ctrl+o undoes. opts.asked: the screen was asked already. opts.behind: added and drawn,
-- leaving the front where it is (no step).
function M.show(name, ctx, opts)
  local kind = kinds[name]
  if not kind then return tell('No view is called ' .. tostring(name) .. '.', WARN) end
  if refused_here(M.can_pop()) then return end
  ctx = ctx or actions.context()
  if kind.match and kind.available and refused_here(kind.available(ctx)) then return end
  opts = type(opts) == 'table' and opts or {}
  local p = pop_for(name, opts.pop)
  if not p then return tell('There is no pop-out ' .. tostring(opts.pop) .. '.', WARN) end
  -- Opening it, with more than one other screen and none chosen for it this session: where to, first.
  if not opts.asked and not is_open(p) and not chosen_of(p) then
    return M.choose_screen(function(screen)
      if screen then choose_for(p, screen) end
      M.show(name, ctx, { asked = true, pop = p.id })
    end)
  end
  local ok, why = open_pop(p, checkout_of(ctx.win))
  if not ok then return tell(sentence(why), WARN) end
  local view, before = kind_view(p, name), p.front
  if kind.match then
    view = nil
    for _, id in ipairs(p.order) do
      local candidate = p.views[id]
      if candidate.kind == name and kind.match(candidate, ctx) then view = candidate; break end
    end
  end
  if not (view and (ctx.remote or kind.match)) then
    if not view and (#p.order >= 64 or not new_id(name)) then return tell('This pop-out has no room for another view.', WARN) end
    -- Sent again over what it showed (another graph's o, the map of another checkout): a step Ctrl+o undoes (2026-11-16).
    local was
    if view and kind.save and kind.restore then
      local fine, state = pcall(kind.save, view)
      was = fine and type(state) == 'table' and state or nil
    end
    view = view or add_view(p, name)
    if kind.open then
      local fine, err = pcall(kind.open, view, ctx)
      if not fine then kind_failed(view, err) end
    end
    if was then M.stepped(view, was) end
  end
  -- told as behind, so the pop-out does not bring it forward as a view it gets anew (it did, when it came after the one
  -- it was sent behind: a race the tests saw under load)
  if opts.behind and before and before ~= view.id then view.behind = true; M.redraw(view); M.save_layout(); return end
  if before and before ~= view.id and p.views[before] then push_step(p, { type = 'switch', from = before, to = view.id }) end
  to_front(view)
  M.save_layout()
end

-- A view sent to pop-out `id` (nil: a new one, opened on `screen` when one is named), opening it when it is not open:
-- it leaves the one it was in as it is (its kind keeps it; nothing closes or is read again), its tab closes there,
-- and its kind's views go to the new place from now on while it is open (homes). true, or false and why.
function M.send(view, id, screen)
  local from = pop_of(view)
  if not (from and from.views[view.id] == view and not view.gone) then return false, 'that view is not in a pop-out' end
  if id == nil then
    local why
    id, why = M.new_pop()
    if not id then return false, why end
  end
  local to = pops[id]
  if not to then return false, 'there is no pop-out ' .. tostring(id) end
  if to == from then return true end
  if screen and not is_open(to) then choose_for(to, screen) end
  local ok, why = open_pop(to)
  if not ok then return false, why end
  from.views[view.id] = nil
  unlist(from, view.id)
  if from.front == view.id then from.front = nil end
  send(from, { type = 'view.clear', id = view.id })
  view.pop, view.sent, view.front = to.id, nil, nil
  to.views[view.id] = view
  to.order[#to.order + 1] = view.id
  homes[view.kind] = to.id
  if to.front and to.views[to.front] then push_step(to, { type = 'switch', from = to.front, to = view.id }) end
  to_front(view)
  M.save_layout()
  return true
end

-- What the kinds' own modules ask: whether a view is in a pop-out still (out there, not gone), the view of a kind
-- (the first pop-out's first), whether the pop-out a view is in is attached, and whether the one a view of kind
-- `name` would go to is.
function M.holds(view)
  local p = pop_of(view)
  return p ~= nil and not view.gone and p.views[view.id] == view
end
-- The view of kind `name` (in pop-out `pop` when given: an answer goes to the pop-out it was asked from).
function M.view_of(name, pop)
  for _, p in ipairs(pops) do
    local view = (pop == nil or p.id == pop) and kind_view(p, name)
    if view then return view end
  end
end
function M.attached(view) local p = pop_of(view); return p ~= nil and p.chan ~= nil end
function M.is_open(name) return pop_for(name).chan ~= nil end

-- The pop-out's last views again (after a restart): it opens, on the screen it was on when that is there, with each
-- saved view its kind fills again from what was kept, and the one in front then in front.
local function restore_tab(p, saved)
  local kind = type(saved) == 'table' and kinds[saved.kind]
  if not (kind and kind.restore) or (not kind.match and kind_view(p, saved.kind)) then return end
  if #p.order >= 64 or not new_id(saved.kind) then return end
  if kind.match then
    for _, view in pairs(p.views) do
      if view.kind == saved.kind and kind.match(view, { target = saved.target }) then return view end
    end
  end
  local view = add_view(p, saved.kind)
  view.pinned = saved.pinned == true
  local fine, err = pcall(kind.restore, view, { pinned = view.pinned, target = type(saved.target) == 'table' and saved.target or nil })
  if not fine then kind_failed(view, err) end
  to_front(view)
  return view
end

-- gu: the view she closed last opens again in the pop-out it was in (opening that when it went with it). false, why.
function M.reopen_closed()
  local list = L.closed[layout_root()]
  local last = list and list[#list]
  if not last then return false, 'no view was closed here' end
  if not kinds[last.kind] then return false, 'its kind (' .. last.kind .. ') is not loaded' end
  if refused_here(M.can_pop()) then return false end
  for n = #pops + 1, last.pop do pops[n] = new_pop(n) end
  local p = pops[last.pop] or H
  if not is_open(p) then
    local ok, why = open_pop(p, layout_root())
    if not ok then return false, why end
  end
  table.remove(list)
  local view = restore_tab(p, last)
  if not view then return false, 'it is open already' end
  M.save_layout()
  tell(sentence((last.named or last.kind) .. ' opened again'))
  return true
end

-- Every pop-out the record has views for opens again (each its own state machine, on its own screen), in its order.
function M.restore_layout()
  local record = L.saved
  if not saved_views(record) then return tell('No views of the pop-out were saved here.') end
  if refused_here(M.can_pop()) then return end
  L.waiting_root = L.saved_root
  for _, saved in ipairs(M.record_pops(record)) do
    if #saved.tabs > 0 then
      for n = #pops + 1, saved.id do pops[n] = new_pop(n) end
      local p = pops[saved.id]
      p.prefer = saved.screen
      p.tiled = saved.tiled
      local ok, why = open_pop(p, L.saved_root)
      if not ok then return tell(sentence(why), WARN) end
      p.waiting = {}
      local active
      for _, tab in ipairs(saved.tabs) do
        if type(tab) == 'table' and type(tab.kind) == 'string' and not kinds[tab.kind] then p.waiting[#p.waiting + 1] = tab
        else
          local restored = restore_tab(p, tab)
          if restored and tab.id == saved.activeTab then active = restored end
          -- Its kind's views go to the pop-out it was in, as when she sent it there.
          if p ~= H and type(tab) == 'table' and kind_view(p, tab.kind) then homes[tab.kind] = p.id end
        end
      end
      -- The one in front, by its kind (a view's id is its kind's name, or kind.2 when another pop-out had one).
      active = active or (saved.activeTab and kind_view(p, (saved.activeTab:gsub('%.%d+$', ''))))
      if active then to_front(active) end
    end
  end
end

-- A kind just registered: its saved tabs come back into the open pop-outs they were in.
function M.restore_waiting(name)
  for _, p in ipairs(pops) do
    if #p.waiting > 0 and is_open(p) then
      local still = {}
      for _, saved in ipairs(p.waiting) do
        if saved.kind == name then restore_tab(p, saved) else still[#still + 1] = saved end
      end
      p.waiting = still
    end
  end
end

-- o in the pop-out: the view leaves it, and its kind puts it back in the editor.
function M.back(view, line)
  if view and M.holds(view) then clear_view(view.id, true, line) end
end

-- p in the pop-out: pinned, a view stays as it is while the editor moves; unpinned, its kind follows the editor again.
function M.pin(view)
  if not view then return end
  view.pinned = not view.pinned
  follow_one(view, { type = 'pin' })
  if not kinds[view.kind].mirror then M.redraw(view) end
  M.save_layout()
end

-- ─── its screen unplugged ──────────────────────────────────────────────────────────────────────────────────────
-- desk-monitor rewrites its sidecar on every hotplug (desk-pulse runs its reconcile). When the screen a pop-out was
-- placed on is no longer among Hyprland's monitors, it moves to another screen that is not the editor's, when one is
-- left; else it closes and its pinned views come back here as splits (one screen: no pop-out, as when it would not
-- open). Hyprland itself would only park it on a workspace nobody sees. Each pop-out is looked at on its own.
local function screen_gone(p, monitors, folded)
  if not (p.chan and p.screen) then return end
  for _, m in ipairs(monitors) do
    if type(m) == 'table' and m.name == p.screen and not m.disabled then return end
  end
  local gone, screen = p.screen, M.target_screen(monitors, M.screens())
  if screen and p.kitty then
    M.place(p.kitty, screen, p)
    return tell(sentence(('%s moved to %s: %s was unplugged'):format(named(p), screen.name, gone)))
  end
  -- Folded quietly: the notice is one per screen, below (two pop-outs on it said it twice, seen in a VM 2026-11-18).
  local returned, had = forget(p, sentence(gone .. ' was unplugged'), { back = true, quiet = true })
  local f = folded[gone] or { pops = 0, views = 0 }
  f.pops, f.views = f.pops + (had and 1 or 0), f.views + returned
  folded[gone] = f
end
function M.screens_changed()
  if exiting() or not any_open() then return end
  hyprctl({ 'monitors' }, function(monitors)
    if type(monitors) ~= 'table' then return end
    local folded = {}
    for _, p in ipairs(pops) do screen_gone(p, monitors, folded) end
    for gone, f in pairs(folded) do
      if f.pops > 0 then
        local closed = f.pops > 1 and (' ' .. f.pops .. ' pop-outs closed.') or ''
        local its = f.pops > 1 and ' Their pinned' or ' Its pinned'
        tell(sentence(gone .. ' was unplugged') .. closed
          .. (f.views == 0 and '' or f.views == 1 and (its .. ' view is back here.') or (its .. ' views are back here.')))
      end
    end
  end)
end
-- A pop-out closes (the first, or p), its pinned views back here as splits; why: the one notice, which the pop-out
-- shows too.
function M.fold(why, p) forget(p or H, sentence(why), { back = true }) end
watch_screens = function()
  if L.watch then return end
  local file = M.layout_file()
  local dir, name = vim.fs.dirname(file), vim.fs.basename(file)
  local watcher, timer = uv.new_fs_event(), uv.new_timer()
  if not (watcher and timer) then return end
  local ok = pcall(watcher.start, watcher, dir, {}, function(err, changed)
    if err or (changed and changed ~= name) then return end
    timer:stop()
    timer:start(300, 0, vim.schedule_wrap(M.screens_changed))
  end)
  if not ok then pcall(watcher.close, watcher); pcall(timer.close, timer); return end
  L.watch = { watcher = watcher, timer = timer }
end
unwatch_screens = function()
  local w = L.watch
  if not w then return end
  L.watch = nil
  pcall(w.watcher.stop, w.watcher)
  pcall(w.watcher.close, w.watcher)
  pcall(w.timer.stop, w.timer)
  pcall(w.timer.close, w.timer)
end

-- ─── the bridge messages the editor takes from its pop-out ─────────────────────────────────────────────────────
-- What Enter does in a view of `surface`: its remote row on Enter.
local function enter_row(surface)
  for _, row in ipairs(actions.rows()) do
    if row.remote and row.key and row.key:lower() == '<cr>' and is_on(row, surface) and not is_on(row, ON) then return row end
  end
end

-- The pop-out a message comes from: the one it names (pop), the first when it names none.
local function from_pop(msg) return pops[msg.pop or 1] end

-- The pop-out, view, generation and item an ask names, as a ctx for the action registry: its kind's ctx_for (what that
-- surface's rows read) on the view's surface (the kind's, where ctx_for names none), with ctx.pop (the pop-out's id),
-- ctx.view, ctx.item (the item's ref), ctx.index, ctx.remote and the window's own surface (ctx.also). A view drawn
-- again since refuses: its items are not the ones the pop-out saw.
local function remote_ctx(msg)
  if exiting() then return nil, 'this editor is closing' end
  local p = from_pop(msg)
  if not (p and p.chan) then return nil, 'no pop-out is subscribed to this editor' end
  local view, ref
  if msg.view ~= nil then
    view = p.views[msg.view]
    if not view then return nil, 'this view is no longer shown' end
    if msg.gen ~= view.gen then return nil, 'this view moved on' end
  end
  if msg.item ~= nil then
    if not view or msg.item < 1 or msg.item > (view.count or 0) then return nil, 'there is no such item in this view' end
    ref = view.refs[msg.item]
  end
  local kind = view and kinds[view.kind]
  local ctx
  if kind and kind.ctx_for then
    local ok, made = pcall(kind.ctx_for, view, ref, msg.item, msg.line)
    if not ok or type(made) ~= 'table' then return nil, "can't tell what is selected there: " .. tostring(made):sub(1, 160) end
    ctx = made
    ctx.surface = ctx.surface or kind.surface
  else
    ctx = actions.context(api.nvim_get_current_win())
    ctx.surface = kind and kind.surface or ON
  end
  ctx.pop, ctx.view, ctx.item, ctx.index, ctx.remote, ctx.also = p.id, view, ref, msg.item, true, { ON }
  ctx.line = msg.line
  L.last = p.id
  return ctx
end

-- Every message from the pop-out says when it stops waiting, so a late one is refused (desk.bridge) rather than run.
local function timed(handler)
  return function(msg)
    if type(msg.deadline) ~= 'number' then return refuse('a pop-out message says when it stops waiting (deadline)') end
    return handler(msg)
  end
end

-- symdeps' board open in the editor when a pop-out opens: it goes there too, behind the view she opened it for (her ask,
-- 2026-11-17: "move the symdeps menu to the out if it's open and a out opens later"); symdeps' kind takes the board out of
-- the editor's panel as it opens (its popout.lua M.open). Only a board shown here, with symdeps loaded already (this never
-- loads it) and in no pop-out yet: one already in a pop-out stays where it is.
local function bring_board(p)
  if not kinds.symdeps or not is_open(p) then return end
  local panel = package.loaded['fox-symdeps.panel']
  if type(panel) ~= 'table' or type(panel.is_open) ~= 'function' or not panel.is_open() then return end
  if type(panel.out) == 'function' and panel.out() ~= nil then return end
  for _, other in ipairs(pops) do if kind_view(other, 'symdeps') then return end end
  M.show('symdeps', actions.context(), { pop = p.id, asked = true, behind = true })
end

-- subscribe { pop, chan, pid, width, protocol }: chan is the pop-out's channel here (nvim_get_api_info gave it the
-- number), labelled with its pid through nvim_set_client_info, since code run by nvim_exec_lua cannot tell which
-- channel called; pop says which pop-out it is (opening → attached). Again from the same channel (a resize): the new
-- width, every view drawn again.
local function subscribe(msg)
  if M.is_popout() or vim.g.desk_work_view then return refuse('this editor keeps no pop-out') end
  if exiting() then return refuse('this editor is closing') end
  if msg.protocol ~= M.PROTOCOL then
    return refuse(('this editor speaks pop-out protocol %d and this pop-out %d: close it and open it again'):format(M.PROTOCOL, msg.protocol))
  end
  local info = api.nvim_get_chan_info(msg.chan)
  local client = type(info.client) == 'table' and info.client or {}
  local attributes = type(client.attributes) == 'table' and client.attributes or {}
  if info.mode ~= 'rpc' or client.name ~= M.CLASS or attributes.pid ~= tostring(msg.pid) then
    return refuse('a pop-out subscribes on its own channel, named with nvim_set_client_info first')
  end
  local id = msg.pop or 1
  if id < 1 or id > M.MAX_POPS then return refuse(('a pop-out is numbered 1 to %d'):format(M.MAX_POPS)) end
  -- One this editor did not open (it is numbered past the ones it has) gets the state of one closed until now.
  for n = #pops + 1, id do pops[n] = new_pop(n) end
  local p = pops[id]
  if p.chan and p.chan ~= msg.chan then let_go(p.chan, 'Another pop-out took over.') end
  local again = p.chan == msg.chan
  p.chan, p.pid, p.width, p.opening = msg.chan, msg.pid, msg.width or p.width, nil
  -- The kitty whose exit ends it is the one it runs in (one this editor did not start has none watched: the pings find
  -- it gone).
  if p.kitty and not vim.tbl_contains(M.lineage(msg.pid), p.kitty) then p.kitty = nil end
  if not again then
    p.stalled, p.ping, p.heard = false, 0, 0
    start_pings(p)
    watch_screens()
  end
  vim.schedule(function() redraw_all(p, again) end)
  if not again then vim.schedule(function() bring_board(p) end) end
  return { subscribed = true, pid = vim.fn.getpid(), pane = host_pane() }
end

-- describe { view, gen, item }: what the pop-out may offer there, as plain data (actions.describe): the remote rows of
-- the view's surface and the window's own, and the editor's that apply, each with why it cannot run and what it asks.
local function describe(msg)
  local ctx, why = remote_ctx(msg)
  if not ctx then return refuse(why) end
  return { rows = actions.describe(ctx) }
end

-- act { view, gen, item, action, text, choice }: runs a remote row after this answer, with the words and the pick its
-- input asked for there (only those it asks for). Not while she is typing here. An Enter (the view's, or f) is a step
-- Ctrl+o undoes: the code spot the editor was at, and the one it went to.
local function act(msg)
  if bridge.typing() then return refuse('typing in this editor') end
  local ctx, why = remote_ctx(msg)
  if not ctx then return refuse(why) end
  local row = actions.get(msg.action)
  if not row then return refuse('no action is called ' .. msg.action) end
  if not row.remote then return refuse(msg.action .. ' is not one the pop-out may ask for') end
  if msg.text ~= nil then ctx.text = vim.trim((msg.text:gsub('%c', ' '))) end
  ctx.choice = msg.choice
  local can = actions.available(row, ctx)
  if can ~= true then return refuse(can == false and (msg.action .. ' does not apply here') or tostring(can)) end
  local missing = actions.answered(row, ctx)
  if missing then return refuse(missing) end
  local kind = ctx.view and kinds[ctx.view.kind]
  local entering = kind and (row == enter_row(kind.surface) or row.id == 'popout.go-focus' or row.id == 'popout.go-focus-enter')
  local p = pops[ctx.pop]
  vim.schedule(function()
    local view = ctx.view
    local before = entering and main_spot(ctx.origin) or nil
    -- One step for the Enter: where the editor was and, for a kind that keeps its state, what the view was. A step the
    -- kind takes of its own for it (while it runs, or scheduled from it) is folded into this one.
    local saved
    if entering and not kind.mirror and kind.save and kind.restore then
      local fine, state = pcall(kind.save, view)
      saved = fine and type(state) == 'table' and state or nil
    end
    if entering then p.folding = view.id end
    -- What goes wrong while it runs is said where she pressed the key too: warnings and errors go to the pop-out as a
    -- notice (her choice, 2026-11-16). Said later, by a callback after this run, it stays in the editor only.
    local real = vim.notify
    vim.notify = function(text, level, opts)
      real(text, level, opts)
      if (level or vim.log.levels.INFO) >= WARN then send(p, { type = 'notice', text = tostring(text):sub(1, 400), level = level }) end
    end
    local ran, ok, err = pcall(actions.act, msg.action, ctx)
    if not ran then ok, err = false, ok end
    if not ok then
      p.folding = nil
      tell(sentence(err or (msg.action .. ' did not run')), WARN)
    end
    vim.notify = real
    if not ok then return end
    if before then
      local code_after = kind.mirror and main_spot() or nil
      push_step(p, { type = 'enter', view = view.id, before = before, saved = saved, code_after = code_after })
    end
    if entering then vim.schedule(function() if p.folding == view.id then p.folding = nil end end) end
  end)
  return { done = true }
end

-- pong { pop, serial }: a pop-out answered a ping; one that had stopped answering gets its views again (stalled →
-- attached).
local function pong(msg)
  local p = from_pop(msg)
  if not (p and p.chan) then return { heard = false } end
  p.heard = math.max(p.heard, msg.serial)
  if p.stalled and p.heard >= p.ping then
    p.stalled = false
    tell(sentence(named(p) .. ' answers again'))
    vim.schedule(function() redraw_all(p) end)
  end
  return { heard = true }
end

-- front { pop, view, quiet }: another view is in front in a pop-out. Her own switch there (gt, a click on its tab) is
-- a step Ctrl+o undoes; quiet: it came of something else (the editor showed it, a view closed), only noted.
local function front(msg)
  local p = from_pop(msg)
  if not (p and p.chan) or exiting() then return { heard = false } end
  local view = p.views[msg.view]
  if not view then return { heard = false } end
  if not msg.quiet then L.last = p.id end
  if not msg.quiet and p.front and p.front ~= view.id and p.views[p.front] then push_step(p, { type = 'switch', from = p.front, to = view.id }) end
  if p.front ~= view.id then
    p.front = view.id
    M.save_layout()
  end
  return { heard = true }
end

-- leaving { pop, pid }: a pop-out of this editor's is quitting (q on its last view there; → leaving → closed):
-- forgotten as she closed it (nothing comes back, nothing is said) and the keyboard back here. Never refused for what
-- this editor is doing: the pop-out goes all the same, and an act it was refused would have it taken for a crash.
local function on_leaving(msg)
  local p = from_pop(msg)
  if not (p and p.chan) or msg.pid ~= p.pid or exiting() then return { heard = false } end
  forget(p, nil, { leaving = true })
  M.focus({ pid = vim.fn.getpid(), pane = host_pane() })
  M.save_layout()
  return { heard = true }
end

local ID, NUMBER, POP = bridge.field('string', 32), bridge.field('integer', 2147483647), bridge.field('integer', M.MAX_POPS)
local LINE = bridge.field('integer', M.MIRROR_LINES)
bridge.register('subscribe', timed(subscribe), { pop = POP, chan = bridge.field('integer', 2147483647, true),
  pid = bridge.field('integer', 2147483647, true), width = bridge.field('integer', 1000), protocol = bridge.field('integer', 1000, true) })
bridge.register('describe', timed(describe), { pop = POP, view = ID, gen = NUMBER, item = bridge.field('integer', M.MAX_ITEMS), line = LINE })
bridge.register('act', timed(act), { pop = POP, view = ID, gen = NUMBER, item = bridge.field('integer', M.MAX_ITEMS), line = LINE,
  action = bridge.field('string', 64, true), text = bridge.field('string', 2000), choice = bridge.field('string', 64) })
bridge.register('pong', pong, { pop = POP, serial = bridge.field('integer', 2147483647, true) })
bridge.register('front', timed(front), { pop = POP, view = bridge.field('string', 32, true), quiet = bridge.field('boolean') })
-- Two pop-outs as a pair (her pick: "one pane previews the other's selection"): gp in a pop-out makes it the preview
-- pane; another pop-out's map or graph then tells its selection as it moves, and the preview pane shows that place's
-- source, pinned (it does not follow the editor), while her editor and keyboard stay where they are.
M.preview_pop = nil
M.preview_from = nil   -- { pop, name, line }: the selection the preview shows, and the pop-out it is in
--- pure-ish: the words a view of a gp pair says about its partner, or nil.
function M.partner_of(view, kind)
  if not M.preview_pop then return nil end
  if view.previewing then
    local from = M.preview_from
    return from and ('following ← ' .. from.pop .. (from.name and (': ' .. from.name) or '')) or ('preview of the other pop-outs')
  end
  if kind and kind.place and view.pop ~= M.preview_pop then return 'preview → ' .. M.preview_pop end
end
function M.preview_toggle(view)
  if not view then return end
  M.preview_pop = (M.preview_pop ~= view.pop) and view.pop or nil
  if not M.preview_pop then M.preview_from = nil end
  for _, p in ipairs(pops) do for _, v in pairs(p.views) do if v ~= view then M.redraw(v) end end end
  tell(M.preview_pop and 'This pop-out previews the other pop-outs\' selections (gp again stops).' or 'Previews stopped.')
end
function M.preview_show(file, line)
  local p = M.preview_pop and pops[M.preview_pop]
  if not (p and p.chan) then return nil, 'no pop-out previews selections (gp in one)' end
  local cv = package.loaded['desk.codeview']
  local view
  for _, v in pairs(p.views) do if v.previewing then view = v end end
  if view and cv and cv.retarget then cv.retarget(view, file, line)
  else
    view = restore_tab(p, { kind = 'code', pinned = true, target = { file = file, line = line } })
    if not view then return nil, 'the preview could not open' end
    view.previewing = true
    if cv and cv.retarget then cv.retarget(view, file, line) end
  end
  to_front(view)
  M.redraw(view)
  return view
end
local function selected(msg)
  local p = from_pop(msg)
  local view = p and p.views[msg.view]
  if not view or msg.gen ~= view.gen then return refuse('this view moved on') end
  local kind = kinds[view.kind]
  local ref = view.refs and view.refs[msg.item]
  if not (kind and kind.place and ref) then return { shown = false } end
  local ok, file, line = pcall(kind.place, view, ref)
  if not (ok and type(file) == 'string') then return { shown = false } end
  M.preview_from = { pop = p.id, name = type(ref) == 'table' and tostring(ref.name or ref.label or '') ~= '' and tostring(ref.name or ref.label):sub(1, 60) or nil,
    line = tonumber(line) or 1 }
  vim.schedule(function() M.preview_show(file, tonumber(line) or 1) end)
  return { shown = true }
end
M._selected = selected
bridge.register('selected', timed(selected), { pop = POP, view = ID, gen = NUMBER, item = bridge.field('integer', M.MAX_ITEMS, true) })
bridge.register('leaving', on_leaving, { pop = POP, pid = bridge.field('integer', 2147483647, true) })
bridge.register('resync', timed(function(msg)
  local p = from_pop(msg)
  local view = p and p.chan and p.views[msg.view]
  if not view or not kinds[view.kind].mirror then return refuse('there is no such code view') end
  -- The snapshot for a newer generation may be the one the pop-out missed.
  if not view.gen or msg.gen > view.gen then return refuse('this view moved on') end
  vim.schedule(function() M.redraw(view) end)
  return { queued = true }
end), { pop = POP, view = bridge.field('string', 32, true), gen = bridge.field('integer', 2147483647, true) })

-- An ask of a pop-out's, by notification (id: its number there): the message goes through the bridge as any other,
-- and its answer back as a notification, to the pop-out it came from (msg.pop; leaving forgets that pop-out, and is
-- still answered).
function M.ask(id, msg)
  if type(id) ~= 'number' or M.is_popout() then return end
  local p = type(msg) == 'table' and (msg.pop == nil or type(msg.pop) == 'number') and from_pop(msg)
  local chan = p and p.chan
  local answer = bridge.receive(msg)
  if chan and next(api.nvim_get_chan_info(chan)) ~= nil then
    pcall(vim.rpcnotify, chan, 'nvim_exec_lua', POPOUT_DOOR, { { version = M.PROTOCOL, type = 'answer', id = id, answer = answer } })
  end
end

-- ─── the pop-out's side ────────────────────────────────────────────────────────────────────────────────────────
-- chan: to the editor; me: that channel's number there; host: { pid, pane } of the editor; views by id, each in a
-- buffer and a window (view.win), normally in separate tabs; tiles: the code views sharing a tab;
-- empty: the buffer shown when there is no view; shown: the view in front; switching: a window change of our own;
-- asked: the asks sent so far; waiting and answers: the asks waited for, by id, and their answers once they came;
-- pop: which of the editor's pop-outs this is (g:desk_popout), named in every message it sends.
local C = { views = {}, order = {}, tiles = {}, asked = 0, waiting = {}, answers = {}, pop = 1 }
local ns = api.nvim_create_namespace('desk_popout')

local function say(text, level) vim.notify(sentence(text), level or vim.log.levels.INFO, { title = 'Pop-out' }) end
local function width() return api.nvim_win_get_width(0) end
local function shown() return C.shown and C.views[C.shown] or nil end
local function escape(s) return (tostring(s):gsub('%%', '%%%%')) end

-- An ask of the editor's: sent with its id, its answer waited for budget ms at most (2 s by default; this window keeps
-- drawing what comes meanwhile). keep: no deadline, so an editor held up still takes it when it gets there (leaving).
-- The answer, or { refused = why }.
-- C.busy: the last ask timed out (the editor at a prompt, or still working). Until anything comes from it, asks wait
-- M.BUSY_MS, not two seconds each, and the header says "editor busy" (2026-11-16: every key froze the pop-out 2 s).
M.BUSY_MS = 250
local function busy(on)
  if C.busy == on then return end
  C.busy = on
  vim.schedule(function() pcall(vim.cmd, 'redrawtabline') end)
end
local function request(msg, budget, keep)
  if not C.chan then return refuse('the pop-out is not connected to an editor') end
  budget = budget or 2000
  if C.busy then budget = math.min(budget, M.BUSY_MS) end
  C.asked = C.asked + 1
  local id = C.asked
  msg.version, msg.pop = 1, C.pop
  if not keep then msg.deadline = now_ms() + budget end
  C.waiting[id] = true
  local sent, err = pcall(vim.rpcnotify, C.chan, 'nvim_exec_lua', ASK_DOOR, { id, msg })
  if sent then vim.wait(budget, function() return C.answers[id] ~= nil end, 5) end
  local answer = C.answers[id]
  C.waiting[id], C.answers[id] = nil, nil
  if not sent then return refuse('the editor did not answer (' .. (tostring(err):gsub('\n.*', '')):sub(1, 160) .. ')') end
  if answer == nil then
    busy(true)
    return refuse('the editor is busy (at a prompt, or still working); try again in a moment')
  end
  busy(false)
  return type(answer) == 'table' and answer or refuse('the editor gave no answer')
end
M.request = request   -- the tests time it

-- What an ask names: a view (the one shown), the generation drawn here and its selected item.
local function naming(msg, view, index)
  view = view or shown()
  if view then msg.view, msg.gen, msg.item = view.id, view.gen, index or view.copy.index end
  if view and view.tick and view.win and api.nvim_win_is_valid(view.win) then msg.line = api.nvim_win_get_cursor(view.win)[1] end
  return msg
end

-- A remote row pressed here: the editor runs it for the item selected in the view generation drawn here.
local function client_act(id, extra, view, index)
  local msg = naming({ type = 'act', action = id }, view, index)
  for key, value in pairs(extra or {}) do msg[key] = value end
  local answer = request(msg)
  if answer.refused then say(answer.refused, WARN) end
  return answer
end

-- Tells the editor which view is in front now (quiet: not her own switch).
local function tell_front(view, quiet)
  if not (C.chan and view) then return end
  pcall(vim.rpcnotify, C.chan, 'nvim_exec_lua', HOST_DOOR, { { version = 1, type = 'front', pop = C.pop, view = view.id, quiet = quiet == true,
    deadline = now_ms() + 2000 } })
end

-- This pop-out is going (q on its last view): the editor is told first (a second at most is waited for its answer; with
-- no deadline, one held up still takes it later), so it never takes the quit for a crash (its pinned views back as
-- splits).
local function leaving()
  if C.chan then request({ type = 'leaving', pid = vim.fn.getpid() }, 1000, true) end
end

local function index_of(view, key)
  for i, item in ipairs(view.items) do if item.key == key then return i end end
end

-- A remote row that asks first (its input): what it asks and offers is the editor's to say (describe, unless the menu
-- just did), it is asked here, and the answer goes with the item selected when it was pressed, as that is drawn by then.
local function ask_then_act(row, offered)
  local view = shown()
  local index = view and view.copy.index
  local key = index and view.items[index] and view.items[index].key
  if not offered then
    local answer = request(naming({ type = 'describe' }, view, index))
    if answer.refused then return say(answer.refused, WARN) end
    for _, r in ipairs(type(answer.rows) == 'table' and answer.rows or {}) do if type(r) == 'table' and r.id == row.id then offered = r end end
    if not offered then return say(row.name .. ': not here', WARN) end
  end
  if offered.available ~= true then return say(tostring(offered.available), WARN) end
  local input = type(offered.input) == 'table' and offered.input or {}
  actions.ask({ prompt = type(input.prompt) == 'string' and input.prompt or nil, choices = type(input.choices) == 'table' and input.choices or nil,
    kind = type(input.kind) == 'string' and input.kind or nil },
    actions.context(), function(text, choice)
      -- A choice that is another row's question (a new pop-out, then its screen): that row asks next, here.
      for _, c in ipairs(type(input.choices) == 'table' and input.choices or {}) do
        local then_row = c.id == choice and type(c.row) == 'string' and actions.get(c.row)
        if then_row then return ask_then_act(then_row) end
      end
      local now = key and view and index_of(view, key)
      if view and (shown() ~= view or (key and not now)) then return say('what it was about is no longer shown', WARN) end
      client_act(row.id, { text = text, choice = choice }, view, now)
    end, type(offered.name) == 'string' and offered.name or row.name)
end

-- A key of a view pressed here: a row the editor runs (remote, and not the window's own) goes there, asking first when
-- it has an input (the window's own remote rows that ask too: what they offer is the editor's); any other runs here (a
-- drawn row on the view's copy, the window's own rows).
local function press(row, ctx)
  if row.remote and (row.input or not is_on(row, ON)) then
    if row.input then return ask_then_act(row) end
    return client_act(row.id)
  end
  actions.press(row, ctx)
end

local function item_at(view, lnum, col)
  for i, item in ipairs(view.items) do if item.kind == 'row' and item.line == lnum then return i end end
  return graphs().box_at(view.copy.drawn, lnum, col)
end

-- The two lines that say what the selected item is (a view's strip), written again when the selection moves.
-- The drawing in the middle of a wide window (2026-11-16: on a 4K screen it sat in the left corner): each line starts
-- with the same run of spaces, inline virtual text, so buffer columns, highlights, the selection and clicks stay as
-- they are. Measured on the drawing's own edges (a graph is already centred in the width it was drawn for).
local pad_ns = api.nvim_create_namespace('desk_popout_centre')
function M.gutter(lines, width)
  local left, right = math.huge, 0
  for _, line in ipairs(lines) do
    local text = line:gsub('%s+$', '')
    if text ~= '' then
      left = math.min(left, vim.fn.strdisplaywidth(text:match('^%s*')))
      right = math.max(right, vim.fn.strdisplaywidth(text))
    end
  end
  if right == 0 then return 0 end
  return math.max(0, math.floor((width - (right - left)) / 2) - left)
end
local function centre(view)
  if not api.nvim_buf_is_valid(view.buf) then return end
  api.nvim_buf_clear_namespace(view.buf, pad_ns, 0, -1)
  if view.tick then view.gutter = 0; return end
  local lines = api.nvim_buf_get_lines(view.buf, 0, -1, false)
  local width = view.win and api.nvim_win_is_valid(view.win) and api.nvim_win_get_width(view.win) or vim.o.columns
  -- The editor already centred the graph's boxes and anchored its gauge to the left edge.
  local n = view.copy.drawn and view.copy.drawn.gauge_range and 0 or M.gutter(lines, width)
  view.gutter = n
  -- From the left edge: a window that narrowed kept its sideways scroll, and cut the drawing's start (seen in a VM,
  -- 2026-11-17).
  if view.win and api.nvim_win_is_valid(view.win) then pcall(api.nvim_win_call, view.win, function() vim.fn.winrestview({ leftcol = 0 }) end) end
  if n == 0 then return end
  local pad = { { string.rep(' ', n), 'Normal' } }
  for i = 0, #lines - 1 do pcall(api.nvim_buf_set_extmark, view.buf, pad_ns, i, 0, { virt_text = pad, virt_text_pos = 'inline', right_gravity = false }) end
end

local set_keyline   -- below: the key line, which says the selected thing's own keys when it has some
-- A view another pop-out previews: its selection told to the editor once it rests (120 ms), never per keystroke.
local function tell_selected(view)
  if not (C.chan and view.previewed and view.copy and view.copy.index) then return end
  view.tell_timer = view.tell_timer or (vim.uv or vim.loop).new_timer()
  view.tell_timer:stop()
  view.tell_timer:start(120, 0, vim.schedule_wrap(function()
    if not (C.chan and view.copy and view.copy.index) then return end
    pcall(vim.rpcnotify, C.chan, 'nvim_exec_lua', HOST_DOOR, { { version = 1, type = 'selected', pop = C.pop, view = view.id, gen = view.gen,
      item = view.copy.index, deadline = now_ms() + 2000 } })
  end))
end
local function strip(view)
  if set_keyline then set_keyline(view) end
  tell_selected(view)
  local at, index = view.strip, view.copy.index
  local item = index and view.items[index]
  if not (at and item and item.strip) or view.strip_for == index or not api.nvim_buf_is_valid(view.buf) then return end
  if api.nvim_buf_line_count(view.buf) < at + 1 then return end
  view.strip_for = index
  vim.bo[view.buf].modifiable = true
  api.nvim_buf_set_lines(view.buf, at - 1, at + 1, false, { (item.strip[1]:gsub('[\r\n]', ' ')), (item.strip[2]:gsub('[\r\n]', ' ')) })
  vim.bo[view.buf].modifiable = false
  vim.bo[view.buf].modified = false
  api.nvim_buf_clear_namespace(view.buf, ns, at - 1, at + 1)
  centre(view)
  for _, m in ipairs(view.marks) do
    if m[1] == at or m[1] == at + 1 then
      pcall(api.nvim_buf_set_extmark, view.buf, ns, m[1] - 1, m[2], { end_col = m[3], hl_group = m[4], priority = 100 + (tonumber(m[5]) or 0) })
    end
  end
end

-- The cursor moved in a view: on an item, that item is the selection (elsewhere it stays). In a list of rows a cursor on
-- a heading or a blank line passes on to the next row the way it was going, so j and k go row to row.
local function moved(view)
  local s = view.copy
  if not s.drawn or api.nvim_get_current_buf() ~= view.buf then return end
  local cursor = api.nvim_win_get_cursor(0)
  local index = item_at(view, cursor[1], cursor[2])
  if not index and view.rows_only then
    local step = cursor[1] >= (view.cursor_line or cursor[1]) and 1 or -1
    for _, dir in ipairs({ step, -step }) do
      for i, item in ipairs(view.items) do
        local ahead = (item.line - cursor[1]) * dir
        if ahead > 0 and (not index or ahead < (view.items[index].line - cursor[1]) * dir) then index = i end
      end
      if index then break end
    end
    if index then pcall(api.nvim_win_set_cursor, 0, { view.items[index].line, view.items[index].name_col }) end
  end
  view.cursor_line = index and view.items[index].line or cursor[1]
  if index and index ~= s.index then graphs().select(s, index, false) end
  strip(view)
end

-- ─── the header (the tab line) and each view's key line (its window's status line) ──────────────────────────────
local function header_groups()
  graphs().highlights()
  api.nvim_set_hl(0, 'DeskPopoutTab', { link = 'TabLine', default = true })
  api.nvim_set_hl(0, 'DeskPopoutTabFill', { link = 'TabLineFill', default = true })
  api.nvim_set_hl(0, 'DeskPopoutTabSel', { link = 'DeskCallGraphSelected', default = true })
  api.nvim_set_hl(0, 'DeskPopoutKey', { link = 'DeskCallGraphKey', default = true })
  api.nvim_set_hl(0, 'DeskPopoutWords', { link = 'StatusLine', default = true })
end

-- A view's key line: its kind's footer, keys as typed here, words in the theme's voice.
local BOARD_MENU = { id = 'popout.board-menu', key = 'm', name = "Symdeps' action menu", group = 'symdeps',
  on = ON, menu = false, run = function() M.client_home() end }

local function keyline(view)
  local said, parts = actions.voice(graphs().retro()), {}
  -- The selected thing's own line (a map's function: what it is, Enter source · t trace …), its view's keys otherwise.
  local selected = view.copy and view.copy.index and view.items and view.items[view.copy.index]
  if selected and selected.keys and not vim.tbl_contains(C.tiles, view.id) then
    -- cut at the end in a narrow window, never before Enter's slot (the first of its parts)
    local first, rest = selected.keys:match('^(.-)( · .*)$')
    if not first then first, rest = selected.keys, '' end
    return '%#DeskPopoutWords# ' .. escape(first) .. '%<' .. escape(rest) .. ' · %#DeskPopoutKey#?%#DeskPopoutWords# ' .. escape(said('keys')) .. ' '
  end
  if vim.tbl_contains(C.tiles, view.id) then
    local label = view.title
    if view.loading then label = label .. ' · ' .. said('loading')
    elseif view.state ~= '' then label = label .. ' · ' .. view.state end
    if view.pinned then label = label .. ' · ' .. said('pinned') end
    parts[#parts + 1] = '%#DeskPopoutKey#' .. escape(label)
  end
  for _, pair in ipairs(M.key_pairs(view.footer or {}, view.rows)) do
    parts[#parts + 1] = '%#DeskPopoutKey#' .. escape(pair[1]) .. '%#DeskPopoutWords# ' .. escape(said(pair[2]))
  end
  if view.surface == 'symdeps' then
    parts[#parts + 1] = '%#DeskPopoutKey#' .. BOARD_MENU.key .. '%#DeskPopoutWords# ' .. said('menu')
  end
  return '%#DeskPopoutWords# ' .. table.concat(parts, '%#DeskPopoutWords# · ') .. '%#DeskPopoutWords# '
end
M._keyline = keyline -- a view's key line, for tests
set_keyline = function(view)
  if view.win and api.nvim_win_is_valid(view.win) then pcall(function() vim.wo[view.win].statusline = keyline(view) end) end
end
-- A status or tab line as Neovim draws it (opts: { use_tabline } or { winid }), its text only.
local function rendered(line, opts)
  local ok, out = pcall(api.nvim_eval_statusline, line or '', opts)
  return ok and out.str or ''
end

-- The tab page a view is in (nil: not in one).
local function tab_of(view)
  local win = view.win
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == view.buf then return api.nvim_win_get_tabpage(win) end
end
local function view_in_tab(tab)
  local win = api.nvim_tabpage_get_win(tab)
  local buf = api.nvim_win_get_buf(win)
  for _, view in pairs(C.views) do if view.win == win and view.buf == buf then return view end end
end

-- The header: each view by its tab number and what it is reading — its word in the theme's voice, then its subject as
-- typed ("trace · DrainEventsAndSubmit", "calls · WorkerLoop", "source · orders.cpp"; a kind that names none, its kind)
-- — PINNED or ↻, ✱ when something new is in it, the one in front in the selection colour; then the keys that switch
-- views and open the menu. Retro: capitals (the words, not the code), │ between views, * for new.
-- The preview's line the other pop-out has selected: ▶ at its end, so the two are seen together without the keyboard.
local partner_ns = api.nvim_create_namespace('desk_popout_partner')
function M.mark_partner(view)
  if not (view and api.nvim_buf_is_valid(view.buf)) then return end
  api.nvim_buf_clear_namespace(view.buf, partner_ns, 0, -1)
  local line = view.partner_line
  if line and line <= api.nvim_buf_line_count(view.buf) then
    -- a line of its own above it: never cut at the window's edge (an end-of-line mark was, in the VM pass)
    pcall(api.nvim_buf_set_extmark, view.buf, partner_ns, line - 1, 0,
      { virt_lines = { { { '▼ ' .. tostring(view.partner or ''):gsub('^following ← ', 'selected in '), 'DeskCallGraphKey' } } }, virt_lines_above = true, priority = 200 })
  end
end
-- The keyboard came here (true) or went elsewhere: the title filled or not, the selection full or dimmed.
local away_ns = api.nvim_create_namespace('desk_popout_away')
M.away_ns = away_ns
function M.client_focus(here)
  C.focused = here
  if next(api.nvim_get_hl(away_ns, { name = 'DeskCallGraphSelected' })) == nil then
    api.nvim_set_hl(away_ns, 'DeskCallGraphSelected', graphs().retro() and { underline = true, bold = true } or { link = 'CursorLine' })
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(win).relative == '' then pcall(api.nvim_win_set_hl_ns, win, here and 0 or away_ns) end
  end
  vim.cmd('redrawtabline')
end
--- pure: a gp pair's partner as the header says it: the words in the theme's voice, the function it names as typed.
function M.partner_text(partner, said)
  local words, name = tostring(partner):match('^(.-: )(.+)$')
  return words and (said(words) .. name) or said(partner)
end
local function tabline()
  local retro = graphs().retro()
  local said, current, out = actions.voice(retro), api.nvim_get_current_tabpage(), {}
  for n, tab in ipairs(api.nvim_list_tabpages()) do
    local view = view_in_tab(tab)
    if not view and tab == current then view = shown() end
    local label = view and (view.tab or (view.kind ~= '' and view.kind) or view.id) or 'pop-out'
    if view and vim.tbl_contains(C.tiles, view.id) then label = #C.tiles .. ' code panes' end
    local text = ' ' .. n .. ' ' .. said(label)
    if view and view.subject and not vim.tbl_contains(C.tiles, view.id) then text = text .. ' · ' .. view.subject
    elseif view and view.tick then
      text = text .. ' · ' .. view.title
      if view.loading then text = text .. ' · ' .. said('loading')
      elseif view.state ~= '' then text = text .. ' · ' .. view.state end
    end
    -- Pinned or following, from the editor's own flags (any kind: the review's state is its progress, 2026-11-16).
    if view and view.pinned then text = text .. (retro and '·' or ' · ') .. said('PINNED')
    elseif view and view.follows then text = text .. ' ' .. (retro and '»' or '↻') end
    if view and view.partner then text = text .. ' · ' .. M.partner_text(view.partner, said) end
    if view and view.news then text = text .. ' ' .. (retro and '*' or '✱') end
    -- filled only where the keyboard is (Codex's #7): in a pop-out without it, its tab reads as any other
    local filled = tab == current and C.focused ~= false
    out[#out + 1] = '%' .. n .. 'T' .. (filled and '%#DeskPopoutTabSel#' or '%#DeskPopoutTab#') .. escape(text .. ' ')
  end
  local view = shown()
  local next_key = view and view.displaced and view.displaced['popout.next-view']
  local right = ' ' .. typed('popout.prev-view') .. '/' .. (next_key and actions.spell(next_key) or typed('popout.next-view'))
    .. ' ' .. said('views') .. ' · ' .. typed('popout.home') .. ' ' .. said('menu') .. ' '
  if C.busy then right = ' ' .. said('editor busy') .. ' ·' .. right end
  return table.concat(out, retro and '%#DeskPopoutTab#│' or '%#DeskPopoutTab# ') .. '%#DeskPopoutTabFill#%T%=%#DeskPopoutTab#'
    .. (retro and '│' or '') .. escape(right)
end
function M.tabline()
  local ok, line = pcall(tabline)
  return ok and line or ' pop-out '
end
-- The header as the tab line draws it: what the tests read.
function M.header() return rendered(vim.o.tabline, { use_tabline = true }) end

local DRESS = { number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0', wrap = false, list = false, spell = false,
  cursorline = false, colorcolumn = '' }
local function dress(win) for opt, value in pairs(DRESS) do pcall(function() vim.wo[win][opt] = value end) end end

-- A view's keys: view.rows bound in its buffer, its Enter row (view.enter) the remote one on Enter.
local function bind(view, surface)
  if surface == 'symdeps' then
    -- The board's action menu, like Space dm, belongs in the window with the selected card.
    view.rows = vim.tbl_filter(function(row) return row.key ~= BOARD_MENU.key end, view.rows)
    table.insert(view.rows, 1, BOARD_MENU)
  end
  view.enter = nil
  for _, row in ipairs(view.rows) do if row.remote and row.key and row.key:lower() == '<cr>' and not is_on(row, ON) then view.enter = row end end
  actions.map(ON, { buffer = view.buf, rows = view.rows, every = true, nowait = true, silent = true, press = press,
    ctx = { copy = view.copy, also = surface and { surface } or nil } })
end

-- A view's buffer and its keys: the drawn and remote rows of its surface and the window's own (actions.popout_rows),
-- the module that adds that surface's rows loaded first. Its copy is the selection a drawn row moves (ctx.copy).
-- A surface with no module here, or one whose module does not load (a plugin's: this window never loads fox-symdeps),
-- has its keys from the editor once the view is drawn (view.standin: bind_standins).
local function client_view(id, surface)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].modifiable = 'hide', false
  if surface == 'code' then vim.bo[buf].undolevels = -1 end
  if surface ~= 'code' then vim.bo[buf].filetype = 'deskpopout' end
  local view = { id = id, buf = buf, gen = 0, kind = '', title = id, state = '', marks = {}, hl = {}, items = {}, footer = {} }
  view.copy = { buf = buf, view = view }
  local loaded = surface == nil
  if surface and actions.MODULES[surface] then loaded = pcall(require, actions.MODULES[surface]) end
  view.standin = not loaded and surface or nil
  view.rows = actions.popout_rows(surface)
  if surface == 'code' then view.rows = vim.tbl_filter(function(row) return row.id ~= 'popout.find' end, view.rows) end
  bind(view, surface)
  -- A click is Neovim's own (the cursor, tab and window it lands on), then its zone, if any (M.client_zone_click). An
  -- expression map, not a registry row: the click itself has to happen first.
  vim.keymap.set('n', '<LeftMouse>', function() vim.schedule(M.client_zone_click); return '<LeftMouse>' end,
    { buffer = buf, expr = true, silent = true, desc = 'Click: the cursor there, and what its zone does' })
  api.nvim_create_autocmd('CursorMoved', { buffer = buf, callback = function() moved(view) end })
  return view
end

-- Puts a view in a tab page of its own (the empty one's when nothing else has it), its window dressed and its key
-- line set.
local function place(view)
  if tab_of(view) then return end
  local switching = C.switching
  C.switching = true
  local reuse
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == C.empty.buf and api.nvim_win_get_config(win).relative == '' then reuse = win end
  end
  if reuse then
    pcall(api.nvim_set_current_win, reuse)
    api.nvim_win_set_buf(reuse, view.buf)
    view.win = reuse
  else
    vim.cmd('tab sbuffer ' .. view.buf)
    view.win = api.nvim_get_current_win()
  end
  C.switching = switching
  view.copy.win = view.win
  dress(view.win)
  set_keyline(view)
end

-- Move a code view to another window without changing its buffer or reading position.
local function move_code(view, target, split)
  local previous = view.win
  local scroll = api.nvim_win_call(previous, vim.fn.winsaveview)
  if target then
    view.win = api.nvim_open_win(view.buf, false, { win = target, split = split })
  else
    api.nvim_set_current_win(previous)
    vim.cmd('tab sbuffer ' .. view.buf)
    view.win = api.nvim_get_current_win()
  end
  view.copy.win = view.win
  api.nvim_win_close(previous, true)
  dress(view.win)
  api.nvim_win_call(view.win, function() vim.fn.winrestview(scroll) end)
end

local function layout_code()
  if C.closing or C.switching then return end
  local wanted = {}
  if C.tiled and vim.o.columns >= 64 and vim.o.lines >= 12 then
    local limit = vim.o.lines >= 18 and MAX_TILES or 2
    for _, id in ipairs(C.order) do
      local view = C.views[id]
      if view and view.kind == 'code' and tab_of(view) then wanted[#wanted + 1] = id end
      if #wanted == limit then break end
    end
  end
  if #wanted < 2 then wanted = {} end
  if vim.deep_equal(C.tiles, wanted) then return end
  local current = shown()
  C.switching = true
  local ok, err = pcall(function()
    -- Each tab opens just after the shared tab, so move the last pane out first.
    for index = #C.tiles, 1, -1 do
      local id = C.tiles[index]
      local view = C.views[id]
      if id ~= wanted[1] and view and tab_of(view) and #api.nvim_tabpage_list_wins(tab_of(view)) > 1 then move_code(view) end
    end
    C.tiles = {}
    for index, id in ipairs(wanted) do
      local view, left = C.views[id], C.views[wanted[1]]
      if index == 2 then move_code(view, left.win, 'right')
      elseif index == 3 then move_code(view, C.views[wanted[2]].win, 'below')
      elseif index == 4 then move_code(view, left.win, 'below') end
      C.tiles[#C.tiles + 1] = id
    end
  end)
  if current and tab_of(current) then api.nvim_set_current_win(current.win) end
  C.switching = false
  for _, view in pairs(C.views) do set_keyline(view) end
  vim.cmd('redrawtabline')
  if not ok then say('Could not arrange the code views: ' .. tostring(err), WARN) end
end

-- Puts a view in front (its tab), the cursor on its selection.
local function show(view)
  place(view)
  local tab = tab_of(view)
  local current = api.nvim_get_current_win()
  if tab and (tab ~= api.nvim_get_current_tabpage()
    or (view.win ~= current and api.nvim_win_get_config(current).relative == '')) then
    C.switching = true
    pcall(api.nvim_set_current_win, view.win)
    C.switching = false
  end
  C.shown, view.news = view.id, false
  tell_front(view, true)
  if view.copy.index then graphs().select(view.copy, view.copy.index, true) end
  vim.cmd('redrawtabline')
end

-- The empty buffer's words (its key line has the keys). force: put it in the current window even with views (the
-- pop-out is closing, and says why there).
local function show_empty(message, force)
  local e, G = C.empty, graphs()
  header_groups()
  local drawn = G.layout({ message = message }, math.max(16, width() - 2), G.retro())
  vim.bo[e.buf].modifiable = true
  api.nvim_buf_set_lines(e.buf, 0, -1, false, drawn.lines)
  vim.bo[e.buf].modifiable = false
  vim.bo[e.buf].modified = false
  api.nvim_buf_clear_namespace(e.buf, ns, 0, -1)
  for _, m in ipairs(drawn.marks) do
    pcall(api.nvim_buf_set_extmark, e.buf, ns, m[1] - 1, m[2], { end_col = m[3], hl_group = m[4], priority = 100 + (m[5] or 0) })
  end
  if force or next(C.views) == nil then
    local win = api.nvim_get_current_win()
    if api.nvim_win_get_buf(win) ~= e.buf then pcall(api.nvim_win_set_buf, win, e.buf) end
    e.win = win
    dress(win)
    set_keyline(e)
    C.shown = nil
  end
  vim.cmd('redrawtabline')
end
local function nothing_shown() return 'nothing is shown here: `' .. typed('popout.home') .. '` › views opens one' end

local function valid_spans(spans)
  if type(spans) ~= 'table' or #spans == 0 or #spans > 8 then return false end
  for _, span in ipairs(spans) do
    if type(span) ~= 'table' or type(span[1]) ~= 'number' or type(span[2]) ~= 'number' or type(span[3]) ~= 'number' then return false end
  end
  return true
end
local function short(value, cap) return type(value) == 'string' and #value <= cap and value or nil end
local function valid_zones(raw)
  local out = {}
  for _, z in ipairs(type(raw) == 'table' and raw or {}) do
    if #out >= 4 then break end
    if type(z) == 'table' and type(z[1]) == 'number' and type(z[2]) == 'number' and type(z[3]) == 'string' and z[3]:match('^[%w_.-]+$') then
      out[#out + 1] = { z[1], z[2], z[3] }
    end
  end
  return out
end
local function valid_heads(raw)
  local out = {}
  for _, h in ipairs(type(raw) == 'table' and raw or {}) do
    if #out >= 400 then break end
    if type(h) == 'table' and type(h.line) == 'number' and type(h.text) == 'string' and #h.text <= 200 then
      local function n(v) return type(v) == 'number' and v >= 0 and v <= M.MAX_DRAWN and math.floor(v) or nil end
      out[#out + 1] = { line = n(h.line), last_line = n(h.last_line), first = n(h.first), last = n(h.last), text = h.text,
        of = type(h.of) == 'string' and #h.of <= 12 and h.of or nil, count = h.count ~= false }
    end
  end
  return out
end
local function valid_sites(raw)
  if type(raw) ~= 'table' then return nil end
  local out = {}
  for i, x in ipairs(raw) do if i > M.MAX_ITEMS then break end; out[i] = type(x) == 'string' and x:sub(1, 120) or '' end
  return out
end
local function valid_near(raw)
  if type(raw) ~= 'table' then return nil end
  local out = {}
  for _, j in ipairs(raw) do if #out < M.MAX_ITEMS and type(j) == 'number' and j >= 1 and j <= M.MAX_ITEMS and j == math.floor(j) then out[#out + 1] = j end end
  return out
end
local function valid_items(raw)
  local items = {}
  for i, item in ipairs(type(raw) == 'table' and raw or {}) do
    if i > M.MAX_ITEMS or type(item) ~= 'table' or type(item.key) ~= 'string' or #item.key > 120 or type(item.line) ~= 'number'
      or not valid_spans(item.spans) then break end
    local lines = type(item.strip) == 'table' and item.strip or {}
    items[i] = { key = item.key, kind = item.kind == 'row' and 'row' or 'box', line = item.line, name_col = tonumber(item.name_col) or 0,
      x = tonumber(item.x) or 0, w = tonumber(item.w) or 1, spans = item.spans, centre = item.centre == true, gauge = item.gauge == true,
      gauge_band = gauge_band(item.gauge_band, item.line),
      gauge_col = type(item.gauge_col) == 'number' and item.gauge_col >= 0 and item.gauge_col <= M.LINE_BYTES and math.floor(item.gauge_col) or nil,
      name = type(item.name) == 'string' and item.name:sub(1, 200) or '', where = short(item.where, 120), mark = short(item.mark, 16),
      strip = type(lines[1]) == 'string' and type(lines[2]) == 'string' and { lines[1]:sub(1, 400), lines[2]:sub(1, 400) } or nil,
      keys = type(item.keys) == 'string' and item.keys:sub(1, 300) or nil,
      near = valid_near(item.near),
      down = valid_near(item.down), up = valid_near(item.up), unrun = item.unrun == true or nil,
      down_sites = valid_sites(item.down_sites), up_sites = valid_sites(item.up_sites),
      zones = valid_zones(item.zones) }
  end
  return items
end
M._valid_items = valid_items -- what the pop-out keeps of a view's items, for tests
local function valid_footer(raw)
  local out = {}
  for _, part in ipairs(type(raw) == 'table' and raw or {}) do
    if #out >= 8 or type(part) ~= 'table' or type(part.words) ~= 'string' or type(part.ids) ~= 'table' then break end
    local ids = {}
    for _, id in ipairs(part.ids) do if #ids < 6 and type(id) == 'string' and #id <= 64 and id:match('^[%w_.-]+$') then ids[#ids + 1] = id end end
    out[#out + 1] = { ids = ids, words = part.words:sub(1, 40) }
  end
  return out
end
-- A list of view ids, checked; nil when it is not one.
local function valid_ids(raw)
  if type(raw) ~= 'table' or #raw > 64 then return nil end
  local out = {}
  for _, id in ipairs(raw) do
    if type(id) ~= 'string' or #id > 32 or not id:match('^[%w_.-]+$') then return nil end
    out[#out + 1] = id
  end
  return out
end
-- A view.set, checked: whatever does not fit is left out, never drawn half.
local function integer(value, min, max)
  return type(value) == 'number' and value >= min and value <= max and value % 1 == 0
end
local function checked_lines(lines, mirror)
  if type(lines) ~= 'table' or #lines > (mirror and M.MAX_LINES or M.MAX_DRAWN) or (mirror and not vim.islist(lines)) then return nil end
  local out = {}
  for i, line in ipairs(lines) do
    if type(line) ~= 'string' or (mirror and #line > M.LINE_BYTES) then return nil end
    out[i] = line:gsub('[\r\n]', ' ')
  end
  return out
end
local function valid_view(msg)
  if type(msg.id) ~= 'string' or #msg.id > 32 or not msg.id:match('^[%w_.-]+$') or type(msg.gen) ~= 'number' then return nil end
  local mirror = msg.surface == 'code'
  local lines = checked_lines(msg.lines, mirror)
  if not lines then return nil end
  if mirror and (not integer(msg.tick, 0, 2147483647) or #lines == 0 or not integer(msg.total, #lines, M.MIRROR_LINES)) then return nil end
  local marks, hl = {}, {}
  for _, m in ipairs(type(msg.marks) == 'table' and msg.marks or {}) do
    if #marks < 20000 and type(m) == 'table' and type(m[1]) == 'number' and type(m[2]) == 'number' and type(m[3]) == 'number'
      and type(m[4]) == 'string' and m[4]:match('^[%w_]+$') then marks[#marks + 1] = m end
  end
  for name, def in pairs(type(msg.hl) == 'table' and msg.hl or {}) do
    if drawable(name) then hl[name] = clean_hl(def) end
  end
  local kind = short(msg.kind, 32)
  return { id = msg.id, gen = msg.gen, kind = kind and kind:match('^[%w_.-]+$') and kind or '',
    -- Any surface by its name, known here or not (a plugin's, whose module this window never loads: client_view).
    surface = type(msg.surface) == 'string' and #msg.surface <= 32 and msg.surface:match('^[%w_-]+$') and msg.surface or nil,
    title = type(msg.title) == 'string' and msg.title:sub(1, 200) or msg.id, state = type(msg.state) == 'string' and msg.state:sub(1, 200) or '',
    tab = short(msg.tab, 24), subject = short(msg.subject, 60), previewed = msg.previewed == true, partner = short(msg.partner, 80),
    partner_line = type(msg.partner_line) == 'number' and msg.partner_line >= 1 and math.floor(msg.partner_line) or nil,
    lines = lines, marks = marks, hl = hl, items = valid_items(msg.items), footer = valid_footer(msg.footer), heads = valid_heads(msg.heads),
    strip = type(msg.strip) == 'number' and msg.strip >= 1 and msg.strip < #lines and math.floor(msg.strip) or nil,
    select = short(msg.select, 120), front = msg.front == true, behind = msg.behind == true, news = msg.news == true, views = valid_ids(msg.views),
    pinned = msg.pinned == true, follows = msg.follows == true,
    tick = mirror and msg.tick or nil, total = mirror and msg.total or nil,
    lang = type(msg.lang) == 'string' and #msg.lang <= 32 and msg.lang:match('^[%w_]+$') and msg.lang or nil,
    cursor = mirror and integer(msg.cursor, 1, M.MIRROR_LINES) and msg.cursor or nil }
end

local function mirror_cursor(view)
  local win = view.win
  if view.cursor and not view.pinned and win and api.nvim_win_is_valid(win) then
    local row = math.min(view.cursor, api.nvim_buf_line_count(view.buf))
    api.nvim_win_set_cursor(win, { row, 0 })
  end
end

local function finish_snapshot(view)
  if view.loading then return end
  M.mark_partner(view)
  local place, drawn_at = view.saved_scroll, view.drawn_at
  view.saved_scroll, view.drawn_at = nil, nil
  local win = view.win and api.nvim_win_is_valid(view.win) and view.win
  -- a move made while the snapshot loaded is the reader's: the place from before it comes back only when there was none
  local moved = win and drawn_at and not vim.deep_equal(api.nvim_win_get_cursor(win), drawn_at)
  if moved then return end
  if view.pinned and place and win then
    api.nvim_win_call(view.win, function() vim.fn.winrestview(place) end)
  else
    mirror_cursor(view)
  end
end

local function resync(view)
  if view.resync or not C.chan then return end
  local waiting = {}
  view.resync = waiting
  pcall(vim.rpcnotify, C.chan, 'nvim_exec_lua', HOST_DOOR, { { type = 'resync', version = 1, pop = C.pop,
    view = view.id, gen = view.gen, deadline = now_ms() + 2000 } })
  vim.defer_fn(function()
    if C.views[view.id] ~= view or view.resync ~= waiting then return end
    view.resync = nil
    resync(view)
  end, 2200)
end

local function watch_chunk(view)
  if not view.loading then return end
  local snapshot, length = view.snapshot_id, view.length
  vim.defer_fn(function()
    if C.views[view.id] == view and view.snapshot_id == snapshot and view.loading and view.length == length then resync(view) end
  end, 1500)
end

local function receive_lines(msg)
  if type(msg.id) ~= 'string' then return end
  local view = C.views[msg.id]
  if not (view and view.tick) or view.resync or not integer(msg.gen, view.gen, 2147483647) then return end
  if msg.gen ~= view.gen then return resync(view) end
  local lines = checked_lines(msg.lines, true)
  local first, last = msg.first, msg.last
  if not lines or msg.from ~= view.tick or not integer(msg.tick, msg.from, 2147483647)
    or not integer(first, 0, view.length) or not integer(last, first, view.length)
    or not integer(msg.total, 1, M.MIRROR_LINES) then return resync(view) end
  local length = view.length + #lines - (last - first)
  if view.loading then
    if msg.chunk ~= true or first ~= view.length or last ~= first or #lines == 0
      or msg.total ~= view.total or length > view.total then return resync(view) end
  elseif msg.chunk or length ~= msg.total then return resync(view) end
  if first ~= last or #lines > 0 then
    vim.bo[view.buf].modifiable = true
    api.nvim_buf_set_lines(view.buf, first, last, true, lines)
    vim.bo[view.buf].modifiable = false
    vim.bo[view.buf].modified = false
  end
  view.length, view.total, view.tick = length, msg.total, msg.tick
  view.loading = length < msg.total
  view.state = short(msg.state, 200) or view.state
  if type(msg.pinned) == 'boolean' then view.pinned = msg.pinned end
  if integer(msg.cursor, 1, M.MIRROR_LINES) then view.cursor = msg.cursor end
  if msg.chunk then finish_snapshot(view)
  elseif msg.cursor then mirror_cursor(view) end
  watch_chunk(view)
  set_keyline(view)
  vim.cmd('redrawtabline')
end

-- Draws a view into its buffer. Its selection: the item the editor asks for (select), else the one selected before (by
-- its key), else its centre, else the first; the cursor goes there when the view has its window.
local function draw(view, lines, keep, held)
  local buf, G, s = view.buf, graphs(), view.copy
  if not api.nvim_buf_is_valid(buf) then return end
  for name, def in pairs(view.hl) do pcall(api.nvim_set_hl, 0, name, def) end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(view.marks) do
    pcall(api.nvim_buf_set_extmark, buf, ns, m[1] - 1, m[2], { end_col = m[3], hl_group = m[4], priority = 100 + (tonumber(m[5]) or 0) })
  end
  if not pcall(api.nvim_buf_set_name, buf, 'pop-out · ' .. view.title) then pcall(api.nvim_buf_set_name, buf, 'pop-out · ' .. view.title .. ' · ' .. view.id) end
  view.rows_only = #view.items > 0
  for _, item in ipairs(view.items) do if item.kind ~= 'row' then view.rows_only = false end end
  s.drawn, s.index, s.win, view.strip_for = { boxes = view.items, gauge_range = G.gauge_range(view.items), heads = view.heads }, nil, view.win, nil
  local first = keep and index_of(view, keep)
  for i, item in ipairs(view.items) do if not first and item.centre then first = i end end
  first = first or (view.items[1] and 1)
  api.nvim_buf_clear_namespace(buf, G.sel_ns, 0, -1)
  api.nvim_buf_clear_namespace(buf, G.gauge_ns, 0, -1)
  if first then G.select(s, first, true); view.cursor_line = view.items[first].line end
  -- the item kept where it was on the screen (a level expanded above it)
  if held and first and keep and view.items[first].key == keep then G.keep_row(view.win, held, view.items[first].line) end
  G.gauge_edges(s)
  centre(view)
  strip(view)
  set_keyline(view)
  M.mark_partner(view)
end

-- The keys of a view whose surface this window cannot load (view.standin): that surface's remote rows as the editor
-- describes them, bound as stand-ins that run there (actions.popout_rows). Asked once it is drawn, and again with each
-- drawing until the editor answers with rows of that surface (busy, the view drawn again meanwhile, or none of its rows
-- in the answer: they were not there yet, or the editor could not tell what was selected); Space Space's answer binds
-- them too.
local function bind_standins(view, described)
  if not view.standin or view.binding or C.views[view.id] ~= view then return end
  if not described then
    view.binding = true
    local answer = request(naming({ type = 'describe' }, view))
    view.binding = nil
    if answer.refused or C.views[view.id] ~= view then return end
    described = answer.rows
  end
  if type(described) ~= 'table' or not api.nvim_buf_is_valid(view.buf) then return end
  local surface, held = view.standin, false
  for _, d in ipairs(described) do
    held = held or (type(d) == 'table' and type(d.on) == 'table' and vim.tbl_contains(d.on, surface))
  end
  if not held then return end
  view.standin = nil
  local rows, _, displaced = actions.popout_rows(surface, described)
  view.rows, view.displaced = rows, displaced
  bind(view, surface)
  set_keyline(view)
end

-- The editor went away (it said bye, or its channel closed): say so, then quit.
function M.closing(why)
  if C.closing then return end
  C.closing = why
  if C.watch then C.watch:stop() end
  C.chan = nil
  say(why)
  show_empty(why, true)
  vim.defer_fn(function() vim.cmd('qa!') end, M.LINGER_MS)
end

local RECEIVES = { ['view.set'] = true, ['view.lines'] = true, ['view.layout'] = true, ['view.clear'] = true,
  ping = true, bye = true, answer = true, notice = true }
-- A view off this window: its tab closes (the empty view shown when it was the last), its buffer goes.
local function drop(id)
  local view = C.views[id]
  if not view then return end
  C.views[id] = nil
  if view.win and api.nvim_win_is_valid(view.win) and api.nvim_win_get_buf(view.win) == view.buf then
    if #api.nvim_list_tabpages() > 1 or #api.nvim_tabpage_list_wins(tab_of(view)) > 1 then
      C.switching = true
      pcall(api.nvim_win_close, view.win, true)
      C.switching = false
    else
      show_empty(nothing_shown(), true)
    end
  end
  pcall(api.nvim_buf_delete, view.buf, { force = true })
  local now = view_in_tab(api.nvim_get_current_tabpage())
  C.shown = now and now.id or nil
  if now then tell_front(now, true) elseif next(C.views) == nil then show_empty(nothing_shown()) end
  layout_code()
  vim.cmd('redrawtabline')
end
local function handle(msg)
  -- notice { text, level }: a warning the editor gave while running a key pressed here.
  if msg.type == 'notice' then
    if type(msg.text) == 'string' then say(msg.text, msg.level == vim.log.levels.ERROR and vim.log.levels.ERROR or WARN) end
    return
  end
  if msg.type == 'view.set' then
    local got = valid_view(msg)
    if not got then return end
    local view = C.views[got.id]
    local fresh = view == nil
    if fresh then
      view = client_view(got.id, got.surface)
      C.views[got.id] = view
    end
    local before = view.copy.index and view.items[view.copy.index]
    local held = before and view.win and api.nvim_win_is_valid(view.win) and api.nvim_win_get_buf(view.win) == view.buf
      and { line = before.line, top = vim.fn.line('w0', view.win) } or nil
    for _, field in ipairs({ 'gen', 'kind', 'surface', 'title', 'tab', 'subject', 'state', 'marks', 'hl', 'items', 'footer', 'strip', 'pinned',
      'follows', 'tick', 'total', 'cursor', 'previewed', 'partner', 'partner_line', 'heads' }) do view[field] = got[field] end
    M.mark_partner(view)
    if got.tick then
      if not view.loading and got.pinned and view.win and api.nvim_win_is_valid(view.win) then
        view.saved_scroll = api.nvim_win_call(view.win, vim.fn.winsaveview)
      end
      view.length, view.loading, view.resync = #got.lines, #got.lines < got.total, nil
      view.snapshot_id = (view.snapshot_id or 0) + 1
      if got.lang ~= view.lang then
        vim.treesitter.stop(view.buf)
        if got.lang then pcall(vim.treesitter.start, view.buf, got.lang) end
        view.lang = got.lang
      end
    end
    if got.news and C.shown ~= got.id then view.news = true end
    C.received = (C.received or 0) + 1
    draw(view, got.lines, got.select or (before and before.key), not got.select and held or nil)
    -- A view the editor sends anew, or asks to show, comes to the front; one drawn again behind another stays behind.
    if (fresh and not got.behind) or got.front or not shown() then show(view) else vim.cmd('redrawtabline') end
    if got.tick then
      view.drawn_at = view.saved_scroll and view.win and api.nvim_win_is_valid(view.win) and api.nvim_win_get_cursor(view.win) or nil
      finish_snapshot(view)
      watch_chunk(view)
    end
    bind_standins(view)
    -- The views the editor has: a tab here of any other is one whose view.clear never came, and it goes.
    if got.views then
      C.order = got.views
      local keep = { [got.id] = true }
      for _, id in ipairs(got.views) do keep[id] = true end
      for _, id in ipairs(vim.tbl_keys(C.views)) do if not keep[id] then drop(id) end end
    end
    C.tiled = msg.tiled == true
    layout_code()
  elseif msg.type == 'view.lines' then
    receive_lines(msg)
  elseif msg.type == 'view.layout' then
    if type(msg.tiled) == 'boolean' then C.tiled = msg.tiled; layout_code() end
  elseif msg.type == 'view.clear' then
    if type(msg.id) == 'string' then drop(msg.id) end
  elseif msg.type == 'ping' then
    if C.chan and type(msg.serial) == 'number' then
      pcall(vim.rpcnotify, C.chan, 'nvim_exec_lua', HOST_DOOR, { { version = 1, type = 'pong', pop = C.pop, serial = msg.serial } })
    end
  elseif msg.type == 'bye' then
    M.closing(type(msg.why) == 'string' and msg.why:sub(1, 200) or 'Editor closed.')
  end
end

-- The pop-out's door: what the editor sends, drawn on the next tick so the editor's rpcnotify returns at once.
function M.receive(msg)
  if not M.is_popout() or type(msg) ~= 'table' or msg.version ~= M.PROTOCOL or not RECEIVES[msg.type] then return false end
  busy(false)   -- the editor is answering again
  -- An answer is taken at once: its ask is waiting for it (one no longer waited for is dropped).
  if msg.type == 'answer' then
    if type(msg.id) == 'number' and C.waiting[msg.id] then C.answers[msg.id] = msg.answer == nil and vim.NIL or msg.answer end
    return true
  end
  vim.schedule(function()
    local ok, err = pcall(handle, msg)
    if not ok then say('could not draw what the editor sent: ' .. tostring(err):sub(1, 200), WARN) end
  end)
  return true
end

-- The handshake: a request, the one this pop-out waits for (it has nothing to show until the editor answers). again: a
-- resize, whose new width goes without waiting.
function M.subscribe(again)
  if not C.chan then return refuse('the pop-out is not connected to an editor') end
  local msg = { version = 1, type = 'subscribe', pop = C.pop, chan = C.me, pid = vim.fn.getpid(), width = math.min(1000, vim.o.columns), protocol = M.PROTOCOL,
    deadline = now_ms() + 2000 }
  if again then
    pcall(vim.rpcnotify, C.chan, 'nvim_exec_lua', HOST_DOOR, { msg })
    return {}
  end
  local ok, answer = pcall(vim.rpcrequest, C.chan, 'nvim_exec_lua', HOST_DOOR, { msg })
  if not ok then return refuse('the editor did not answer (' .. (tostring(answer):gsub('\n.*', '')):sub(1, 160) .. ')') end
  answer = type(answer) == 'table' and answer or refuse('the editor gave no answer')
  if not answer.refused then C.host = { pid = answer.pid, pane = answer.pane } end
  return answer
end

-- Space Space in the pop-out: what the editor offers for the view and its selected item (describe), the views first,
-- in the menu kit the review uses, and this window's own rows. A row asking for words or a pick asks here.
function M.client_home()
  local view = shown()
  local answer = request(naming({ type = 'describe' }, view))
  if answer.refused then return say(answer.refused, WARN) end
  if view and view.standin then bind_standins(view, answer.rows) end
  local ctx, keyed = actions.context(), {}
  for _, row in ipairs((view or C.empty).rows or {}) do keyed[row.id] = row.key end
  if view and view.displaced then
    for id, key in pairs(view.displaced) do keyed[id] = key end
  end
  local views, items, here = {}, {}, {}
  local function add(into, row, why, run)
    into[#into + 1] = { ident = row.id, name = row.name, label = row.name .. ' — ' .. tostring(row.about or ''):gsub('`', ''),
      group = tostring(row.group or 'more'):lower(), bind = keyed[row.id], right = why, run = function()
        if why then return say(why, WARN) end
        run()
      end }
  end
  for _, row in ipairs(type(answer.rows) == 'table' and answer.rows or {}) do
    if type(row) == 'table' and type(row.id) == 'string' and type(row.name) == 'string' and row.menu ~= false then
      here[row.id] = true
      local mine = actions.get(row.id)
      local run
      if type(row.input) == 'table' then run = function() ask_then_act(mine or row, row) end
      elseif mine and is_on(mine, ON) then run = function() mine.run(ctx) end
      else run = function() client_act(row.id) end end
      add(row.group == 'Views' and views or items, row, row.available ~= true and tostring(row.available) or nil, run)
    end
  end
  -- This window's own rows: not the editor's to give.
  for _, row in ipairs(actions.for_context(ctx)) do
    if not here[row.id] and not row.remote and row.menu ~= false and is_on(row, ON) then add(items, row, nil, function() row.run(ctx) end) end
  end
  local item = view and view.copy.index and view.items[view.copy.index]
  require('desk.review').show_menu(vim.list_extend(views, items), { title = 'Home · pop-out' .. (item and item.name ~= '' and (' · ' .. item.name) or ''),
    anchor_win = api.nvim_get_current_win(), memo = 'desk-popout-home' })
end

-- ? in the pop-out: the keys of the view in front, as bound here (actions.popout_rows), in the list every view's ?
-- draws. Whether a row can run is the editor's to say, so every key is listed and Enter on one presses it.
-- /: every box or row of the view in front by its whole name (a box shows it cut with …), filtered as she types in the
-- menu; Enter selects it here (2026-11-16: Vim's own / missed cut names, and its n is the review's own key).
--- pure: what / offers — the drawn items (every box is drawn), each by its whole name, and where it is when another
--- box has the same name ("push · q.cpp:10"); each keeps its box's key, the choice that holds when the view is read
--- again while the list is open (Codex's E13, 2026-11-19: it kept the place, and a reread put another box there).
function M.find_choices(items)
  local out, count = {}, {}
  for _, item in ipairs(items or {}) do count[item.name] = (count[item.name] or 0) + 1 end
  for i, item in ipairs(items or {}) do
    local label = item.name ~= '' and item.name or item.key
    if item.name ~= '' and count[item.name] > 1 and item.where then label = label .. ' · ' .. item.where end
    out[#out + 1] = { label = label, key = item.key, index = i }
  end
  return out
end

function M.client_find()
  local view = shown()
  local choices = view and M.find_choices(view.items) or {}
  if #choices == 0 then return say('nothing to find in this view') end
  vim.ui.select(choices, { prompt = 'Find in ' .. (view.title ~= '' and view.title or view.id),
    format_item = function(c) return c.label end }, function(choice)
    if not (choice and C.views[view.id] == view and api.nvim_buf_is_valid(view.buf)) then return end
    if view.win and api.nvim_win_is_valid(view.win) then pcall(api.nvim_set_current_win, view.win) end
    -- by its key in the items as they are now: the view may have been read again while the list was open
    local index
    for i, item in ipairs(view.items or {}) do if item.key == choice.key then index = i; break end end
    if not index then return say(choice.label .. ' is no longer in this view') end
    graphs().select(view.copy, index, true)
    strip(view)
  end)
end

-- Which pop-out a window is, and whose: its process, or the Neovim it runs, was started with g:desk_popout=N and
-- desk-popout:<the editor's socket>. Her own processes are readable under hidepid. → n, socket (or nil).
function M.popout_number(pid)
  local function in_cmdline(p)
    local f = io.open('/proc/' .. p .. '/cmdline', 'rb')
    if not f then return nil end
    local text = f:read('*a'); f:close()
    return tonumber(text:match('g:desk_popout=(%d+)')), text:match('%zdesk%-popout:(/[^%z]+)')
  end
  local n, socket = in_cmdline(pid)
  if n then return n, socket end
  local f = io.open(('/proc/%d/task/%d/children'):format(pid, pid), 'r')
  if not f then return nil end
  local children = f:read('*a'); f:close()
  for child in children:gmatch('%d+') do
    n, socket = in_cmdline(child)
    if n then return n, socket end
  end
end

--- pure: the pid of the next pop-out after number `mine` of the editor at `socket` (windows = { { pid, n, socket } });
--- another editor's pop-outs (another checkout's, numbered from 1 too) never count. nil: none after it.
function M.next_pop(windows, mine, socket)
  local best, best_pid
  for _, w in ipairs(windows) do
    if w.socket == socket and w.n > mine and (not best or w.n < best) then best, best_pid = w.n, w.pid end
  end
  return best_pid
end

-- Space Tab in a pop-out: this editor's next pop-out by number from Hyprland's own list of windows, else (the last)
-- the editor.
function M.client_swap()
  local mine = tonumber(vim.g.desk_popout) or 1
  hyprctl({ 'clients' }, function(clients)
    local windows = {}
    for _, c in ipairs(type(clients) == 'table' and clients or {}) do
      if type(c) == 'table' and c.class == M.CLASS and type(c.pid) == 'number' then
        local n, socket = M.popout_number(c.pid)
        if n then windows[#windows + 1] = { pid = c.pid, n = n, socket = socket } end
      end
    end
    local next_pid = C.server and M.next_pop(windows, mine, C.server)
    M.focus(next_pid and { pid = next_pid } or C.host)
  end)
end

function M.client_keys()
  local view = shown() or C.empty
  local said = actions.voice(graphs().retro())
  return actions.show_keys(actions.context(), { reasons = false, rows = view.rows, press = press,
    footer = ' ' .. typed('popout.focus') .. ' ' .. said('in the editor comes back here') })
end

-- A double click: the item under the mouse is selected, then it goes as Enter would.
-- A single click: the editor's own click moves the cursor (and with it the selection); on a zone of the item clicked
-- (the review's arrow and check box) its row is pressed, as in the editor (2026-11-16).
function M.client_zone_click()
  local view = shown()
  if not view then return end
  local pos = vim.fn.getmousepos()
  if pos.winid ~= view.win or (pos.line or 0) < 1 then return end
  local index = item_at(view, pos.line, math.max(0, (pos.column or 1) - 1))
  local item = index and view.items[index]
  if not (item and item.line == pos.line) then return end
  for _, zone in ipairs(item.zones or {}) do
    if pos.column >= zone[1] and pos.column <= zone[2] then return client_act(zone[3], nil, view, index) end
  end
end

function M.client_click()
  local view = shown()
  if not view then return end
  local pos = vim.fn.getmousepos()
  if pos.winid == view.win and (pos.line or 0) > 0 then
    local index = item_at(view, pos.line, math.max(0, (pos.column or 1) - 1))
    if index then graphs().select(view.copy, index, false); strip(view) end
  end
  if view.enter then press(view.enter, actions.context()) end
end

-- Started by the pop-out's argv: nvim --cmd 'let g:desk_popout=1' -c "lua require('desk.popout').client()" --
-- desk-popout:<the editor's socket>.
function M.client()
  if C.started then return end
  C.started = true
  vim.g.desk_popout = vim.g.desk_popout or 1
  local id = tonumber(vim.g.desk_popout)
  C.pop = id and id >= 1 and id <= M.MAX_POPS and math.floor(id) or 1
  vim.o.shadafile = 'NONE'   -- her history and marks are the editor's to keep
  local server
  for _, arg in ipairs(vim.fn.argv()) do server = server or arg:match('^desk%-popout:(/.+)$') end
  C.server = server
  local first = api.nvim_get_current_buf()
  pcall(vim.cmd, 'silent! argdelete *')
  C.empty = client_view('', nil)
  C.empty.footer = { { ids = { 'popout.home' }, words = 'menu' }, { ids = { 'popout.keys' }, words = 'keys' }, { ids = { 'popout.close' }, words = 'close' } }
  api.nvim_win_set_buf(0, C.empty.buf)
  -- The argument was a name, never a file: its buffer goes.
  if first ~= C.empty.buf and api.nvim_buf_is_valid(first) and api.nvim_buf_get_name(first):find('desk-popout:', 1, true) then
    pcall(api.nvim_buf_delete, first, { force = true })
  end
  -- The header is the tab line, always shown; each view's key line its window's status line.
  header_groups()
  vim.o.showtabline, vim.o.laststatus = 2, 2
  vim.o.tabline = "%!v:lua.require'desk.popout'.tabline()"
  local group = api.nvim_create_augroup('desk_popout_client', { clear = true })
  api.nvim_create_autocmd({ 'WinEnter', 'TabEnter' }, { group = group, callback = function()
    if C.switching then return end
    local view = view_in_tab(api.nvim_get_current_tabpage())
    if view and C.shown ~= view.id then
      C.shown = view.id
      view.news = false
      tell_front(view)
    elseif not view and api.nvim_win_get_config(0).relative == '' then
      C.shown = nil
    end
    vim.cmd('redrawtabline')
  end })
  -- Focus, selection, origin and pin each one look (Codex's #7): the filled title is where typing goes; in a pop-out
  -- without the keyboard the selection is drawn dimmer (its windows in a highlight namespace of their own).
  C.focused = true
  api.nvim_create_autocmd({ 'FocusGained', 'FocusLost' }, { group = group, callback = function(a) M.client_focus(a.event == 'FocusGained') end })
  api.nvim_create_autocmd('WinScrolled', { group = group, callback = function(a)
    local view = shown()
    if view and tonumber(a.match) == view.win then graphs().gauge_edges(view.copy) end
  end })
  -- A view's window closed some other way than q (:q there): the view closes as q would close it.
  api.nvim_create_autocmd('WinClosed', { group = group, callback = function(a)
    if C.switching or C.closing then return end
    local closed = tonumber(a.match)
    for id, view in pairs(C.views) do
      if view.win == closed then vim.schedule(function() if C.views[id] and C.chan then client_act('popout.close', nil, view) end end) end
    end
  end })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = header_groups })
  show_empty('connecting to the editor…')
  if not server then return M.closing('No editor was named for this pop-out.') end
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', server, { rpc = true })
  if not ok or type(chan) ~= 'number' or chan <= 0 then return M.closing('The editor is not reachable.') end
  C.chan = chan
  local got, info = pcall(vim.rpcrequest, chan, 'nvim_get_api_info')
  C.me = got and type(info) == 'table' and info[1] or 0
  pcall(vim.rpcrequest, chan, 'nvim_set_client_info', M.CLASS, { major = 1, minor = 0, patch = 0 }, 'remote', vim.empty_dict(),
    { pid = tostring(vim.fn.getpid()) })
  local answer = M.subscribe()
  if answer.refused then return M.closing(sentence(answer.refused)) end
  if not shown() then show_empty('nothing is shown here yet') end
  C.watch = uv.new_timer()
  C.watch:start(M.WATCH_MS, M.WATCH_MS, vim.schedule_wrap(function()
    if C.chan and next(api.nvim_get_chan_info(C.chan)) == nil then M.closing('Editor closed.') end
  end))
  local resized = uv.new_timer()
  api.nvim_create_autocmd('VimResized', { group = group, callback = function()
    layout_code()
    for _, view in pairs(C.views) do centre(view) end
    resized:stop()
    resized:start(100, 0, vim.schedule_wrap(function() if C.chan then M.subscribe(true) end end))
  end })
end

-- What the tests read of the pop-out.
function M.client_state()
  local view = shown()
  local s = view and view.copy or {}
  local item = s.index and view.items[s.index]
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  return { connected = C.chan ~= nil, host = C.host, shown = C.shown or '', gen = view and view.gen or 0, kind = view and view.kind or '',
    gutter = view and view.gutter or 0, zones = item and item.zones or {}, item_line = item and item.line or 0,
    title = view and view.title or '', state = view and view.state or '', index = s.index or 0, selected = item and item.name or '',
    selected_key = item and item.key or '', lines = api.nvim_buf_get_lines(buf, 0, -1, false), closing = C.closing or '',
    win = view and view.win or (C.empty and C.empty.win) or 0, current_win = win, buf = buf, mode = api.nvim_get_mode().mode,
    received = C.received or 0, pinned = view and view.pinned == true, views = vim.tbl_keys(C.views),
    tabs = #api.nvim_list_tabpages(), tab = vim.fn.tabpagenr(), tiles = vim.deepcopy(C.tiles),
    header = M.header(), keyline = rendered(vim.wo[win].statusline, { winid = win }) }
end

-- ─── the keys ──────────────────────────────────────────────────────────────────────────────────────────────────
-- Rows of the action registry (desk/actions.lua): the mappings, which-key's words, the home menus in both windows, the
-- keybinds reference and the pop-out's ? read them. These are the window's own (surface 'popout'), beside the keys of
-- the view it shows (its surface's drawn and remote rows). A remote one pressed in the pop-out asks the editor, which
-- runs `host` with the view and the item the pop-out had selected (ctx.view, ctx.item).
local function remote(row, host)
  row.remote = true
  row.run = function(ctx)
    if M.is_popout() then return client_act(row.id) end
    return host(ctx)
  end
  return row
end
local function showing(ctx) return ctx.view ~= nil or 'nothing is shown here' end
-- Space dd in the pop-out: why symdeps' card does not open here (symdeps never loads in a pop-out: init.lua's spec).
local function no_card_here()
  local view = shown()
  if view and view.kind == 'symdeps' then
    return "symdeps' card is the one drawn here: its keys work on it, and " .. typed('popout.home') .. ' lists them'
  end
  return 'symdeps runs in the editor, not in the pop-out: ' .. typed('popout.swap') .. ' goes there'
end
local function can_go(ctx)
  if not ctx.view then return 'nothing is shown here' end
  local row = enter_row(ctx.surface)
  if not row then return 'nothing here goes anywhere' end
  return actions.available(row, ctx)
end
-- f and Shift+Enter: what Enter does, then the keyboard to the editor.
local function go_focus(ctx)
  local row = enter_row(ctx.surface)
  if not row then return tell('Nothing here goes anywhere.', WARN) end
  local ok, err = actions.act(row.id, ctx)
  if not ok then return tell(sentence(err), WARN) end
  -- Its Enter went nowhere in the editor (a map's part zoomed, a commit unfolded): the keyboard stays (2026-11-16).
  if ctx.stayed then return end
  M.focus({ pid = vim.fn.getpid(), pane = host_pane() })
end
-- The pop-out a remote row was pressed in (ctx.pop), the first by default.
local function pressed_in(ctx) return pops[ctx.pop or 1] or H end
local function back_there(ctx) return pressed_in(ctx).history.at >= 1 or 'nothing further back' end
local function ahead_there(ctx)
  local h = pressed_in(ctx).history
  return h.at < #h.steps or 'nothing further forward'
end
-- The first pop-out that is attached; the next attached after pop-out `id` (nil: none).
local function first_attached() for _, p in ipairs(pops) do if p.chan then return p end end end
local function next_attached(id)
  for _, p in ipairs(pops) do if p.id > (id or 0) and p.chan then return p end end
end
-- The pop-out a row is about: the one it was pressed in (ctx.pop), else, in the editor, the one last used while it
-- is open, else the first open one, else the first.
local function in_front(ctx)
  if ctx.pop and pops[ctx.pop] then return pops[ctx.pop] end
  local last = L.last and pops[L.last]
  if is_open(last) then return last end
  for _, p in ipairs(pops) do if is_open(p) then return p end end
  return H
end
-- Where a view may be sent: every other open pop-out, then a new one (which asks its screen: popout.send-new).
local function send_choices(ctx)
  local here, out = ctx.view and pop_of(ctx.view), {}
  for _, p in ipairs(pops) do
    if p ~= here and is_open(p) then
      local names = {}
      for _, id in ipairs(p.order) do if p.views[id] then names[#names + 1] = p.views[id].kind end end
      out[#out + 1] = { id = tostring(p.id), name = ('Pop-out %d · %s · %s'):format(p.id, p.screen or 'opening',
        #names > 0 and table.concat(names, ', ') or 'nothing shown') }
    end
  end
  out[#out + 1] = { id = 'new', name = 'A new pop-out', row = 'popout.send-new' }
  return out
end
local function one_more()
  for _, p in ipairs(pops) do if not is_open(p) and next(p.views) == nil then return true end end
  return #pops < M.MAX_POPS or ('%d pop-outs are open, the most there may be'):format(#pops)
end

local ROWS = actions.add({
  { id = 'popout.focus', group = 'Pop-out', name = 'To the pop-out', key = '<leader><Tab>', on = 'editor',
    about = 'Put the keyboard in the pop-out window, on whichever screen it is (with several, the first); the same key there goes on to the next, and from the last back here',
    available = function() return (first_attached() ~= nil and not M.is_popout()) or false end,
    run = function()
      if M.is_popout() then return end
      local p = first_attached()
      if not p then return tell('No pop-out is open. ' .. sentence('Space Space › views opens one'), WARN) end
      M.focus({ pid = p.pid })
    end },
  { id = 'popout.restore', group = 'Views', name = "Restore the pop-out's views", on = 'editor', remote = true,
    about = 'Open the pop-outs again with the views they had when this editor last closed, pinned as they were, each on the screen it was on',
    available = function()
      if any_open() or not saved_views(L.saved) then return false end
      return M.can_pop()
    end,
    run = function() M.restore_layout() end },
  { id = 'popout.screen', group = 'Views', name = 'This pop-out to another screen', on = 'editor', remote = true,
    about = 'Asks which screen (every one, this one too); the pop-out (the one this is pressed in; in the editor the one last used) moves there now if it is open, and opens there from now on, this session',
    available = function() return M.second_screen() end,
    -- Asked by desk.actions before the row runs (after a menu has closed), not from inside run; in a pop-out, there.
    input = { choices = function() return M.screen_input_choices(true) end, kind = 'desk_screens' },
    run = function(ctx)
      if type(ctx.choice) ~= 'string' or ctx.choice == '' then return end
      local p = in_front(ctx)
      choose_for(p, ctx.choice)
      if p.kitty and p.chan then M.place(p.kitty, nil, p) end
    end },
  remote({ id = 'popout.tile-code', group = 'Pop-out', name = 'Toggle code panes', on = ON,
    about = 'Show up to four live code views side by side in one tab, or return them to separate tabs',
    available = function(ctx)
      if not ctx.remote then return true end
      local p, count = pressed_in(ctx), 0
      if p.tiled then return true end
      for _, view in pairs(p.views) do if view.kind == 'code' then count = count + 1 end end
      return count >= 2 or 'open at least two live code views'
    end },
    function(ctx)
      local p = pressed_in(ctx)
      p.tiled = not p.tiled or nil
      send(p, { type = 'view.layout', tiled = p.tiled == true })
      M.save_layout()
    end),
  remote({ id = 'popout.send', group = 'Pop-out', name = 'Send to another pop-out', on = ON,
    about = "Asks which: another open pop-out, or a new one (which asks its screen); the view moves there as it is, and this kind's views go there from now on while it is open",
    available = showing, input = { choices = send_choices } },
    function(ctx)
      if ctx.choice == 'new' then return M.send(ctx.view, nil) end
      local ok, why = M.send(ctx.view, tonumber(ctx.choice))
      if not ok then tell(sentence(why), WARN) end
    end),
  remote({ id = 'popout.send-new', group = 'Pop-out', name = 'Send to a new pop-out', on = ON,
    about = "Asks which screen it opens on (every one, this one too); the view moves to a new pop-out there, and this kind's views go there from now on while it is open",
    available = function(ctx)
      local can = showing(ctx)
      if can ~= true then return can end
      return one_more()
    end,
    input = { choices = function() return M.screen_input_choices(true) end, kind = 'desk_screens' } },
    function(ctx)
      local ok, why = M.send(ctx.view, nil, ctx.choice)
      if not ok then tell(sentence(why), WARN) end
    end),
  remote({ id = 'popout.go-focus', group = 'Pop-out', name = 'Go to it, in the editor', key = 'f', on = ON,
    fallback = 'popout.go-focus-enter',
    about = 'What `Enter` does (go to the selected box or row in the editor), and the keyboard goes to the editor too; where `Enter` only acts in the view (a zoom, a fold) the keyboard stays', available = can_go },
    go_focus),
  remote({ id = 'popout.go-focus-enter', group = 'Pop-out', name = 'Go to it, in the editor', key = '<S-CR>', on = ON, line = 'popout.go-focus',
    menu = false, available = can_go }, go_focus),
  { id = 'popout.go-mouse', group = 'Pop-out', name = 'Go to what is clicked', key = '<2-LeftMouse>', on = ON, menu = false, doc = false,
    run = function() M.client_click() end },
  remote({ id = 'popout.preview-here', group = 'Pop-out', name = "Preview the other pop-out's selection here", key = 'gp', on = ON,
    about = "This pop-out shows the source of what is selected in another pop-out's map or graph as it moves (pinned, so it does not follow the editor), while the editor and the keyboard stay where they are; `gp` again stops",
    available = showing }, function(ctx) M.preview_toggle(ctx.view) end),
  remote({ id = 'popout.pin', group = 'Pop-out', name = 'Pin, or follow the editor', key = 'p', on = ON,
    about = "Pin this view (PINNED: it stays as it is while the editor moves, and `Enter` visits its items one by one), or follow the editor's cursor again",
    available = showing }, function(ctx) M.pin(ctx.view) end),
  remote({ id = 'popout.back', group = 'Pop-out', name = 'Back to the editor', key = 'o', on = ON,
    about = 'This view back to the editor as a split (the call graph as the live panel), pinned if it is pinned here; the pop-out stays open',
    available = showing }, function(ctx) M.back(ctx.view, ctx.line) end),
  -- H and L as in the editor, where they go to the previous / next buffer (her ask, 2026-11-16); gt and gT too.
  { id = 'popout.prev-view', group = 'Pop-out', name = 'The previous view', key = 'H', on = ON, menu = false,
    doc = 'The previous / next tab (`2gt` goes to the second)',
    run = function() pcall(vim.cmd, 'tabprevious') end },
  { id = 'popout.next-view', group = 'Pop-out', name = 'The next view', key = 'L', on = ON, menu = false, line = 'popout.prev-view',
    fallback = 'popout.next-view-gt',
    run = function() pcall(vim.cmd, 'tabnext') end },
  { id = 'popout.next-view-gt', group = 'Pop-out', name = 'The next view', key = 'gt', on = ON, menu = false, line = 'popout.prev-view',
    run = function() local n = vim.v.count; pcall(vim.cmd, n > 0 and ('tabnext ' .. n) or 'tabnext') end },
  { id = 'popout.prev-view-gt', group = 'Pop-out', name = 'The previous view', key = 'gT', on = ON, menu = false, line = 'popout.prev-view',
    run = function() pcall(vim.cmd, 'tabprevious ' .. vim.v.count1) end },
  remote({ id = 'popout.history-back', group = 'Pop-out', name = 'Back', key = '<C-o>', on = ON,
    about = 'Back where you were: the view before, the graph before a centre, the code spot before `Enter` (the editor goes back too)',
    -- where it goes, said in the menus (E14)
    subject = function(ctx) local said = M.back_said(pressed_in(ctx)); return said and ('to ' .. said) or nil end,
    available = back_there }, function(ctx) M.history_back(pressed_in(ctx)) end),
  -- a pick of the recent steps (E14): one detour undone without counting Ctrl+o presses; no key of its own
  remote({ id = 'popout.history-pick', group = 'Pop-out', name = 'Back to an earlier step', on = ON,
    about = 'The last steps back, each by where it goes (a code spot, a view, a graph before a centre): the one picked, and everything since, undone at once',
    input = { choices = function(ctx) return M.back_steps(pressed_in(ctx)) end },
    available = back_there }, function(ctx) M.history_back_to(pressed_in(ctx), ctx.choice) end),
  remote({ id = 'popout.history-back-bs', group = 'Pop-out', name = 'Back', key = '<BS>', on = ON, line = 'popout.history-back', menu = false,
    fallback = 'popout.history-back', available = back_there }, function(ctx) M.history_back(pressed_in(ctx)) end),
  remote({ id = 'popout.history-forward', group = 'Pop-out', name = 'Forward', key = '<C-r>', on = ON,
    about = 'Forward again, after going back', available = ahead_there }, function(ctx) M.history_forward(pressed_in(ctx)) end),
  { id = 'popout.find', group = 'Pop-out', name = 'Find a box or row', key = '/', on = ON,
    about = 'Every box or row of this view by its whole name, filtered as you type; `Enter` selects it',
    available = function(ctx) return not (ctx.view and ctx.view.kind == 'code') end, run = function() M.client_find() end },
  { id = 'popout.reopen', group = 'Pop-out', name = 'Reopen the view closed last', key = 'gu', on = ON, remote = true,
    about = 'The view you closed last (`q`) opens again, as it was, in the pop-out it was in; up to ' .. M.CLOSED_KEEP .. ' are kept for this checkout, newest first',
    -- Pressed there it goes to the editor, which keeps the list.
    available = function() return M.is_popout() or #M.closed_views() > 0 or 'no view was closed here' end,
    run = function()
      if M.is_popout() then return client_act('popout.reopen') end
      local ok, why = M.reopen_closed()
      if not ok and why then tell(sentence(why), WARN) end
    end },
  { id = 'popout.reopen-editor', group = 'Pop-out', name = 'Reopen the pop-out view closed last', on = 'editor', remote = false,
    about = 'The pop-out view you closed last (`q` there) opens again, as it was, in the pop-out it was in',
    available = function() return #M.closed_views() > 0 or 'no pop-out view was closed here' end,
    run = function()
      local ok, why = M.reopen_closed()
      if not ok and why then tell(sentence(why), WARN) end
    end },
  { id = 'popout.keys', group = 'Pop-out', name = "The pop-out's keys", key = '?', on = ON, about = 'The keys of this view in the pop-out, in a list',
    run = function() M.client_keys() end },
  { id = 'popout.swap', group = 'Pop-out', name = 'To the editor, or next pop-out', key = '<leader><Tab>', on = ON, remote = true,
    about = 'Put the keyboard in the next pop-out, and from the last one in the editor (with one pop-out: the editor); the same key in the editor comes to the first',
    run = function(ctx)
      -- From a pop-out: worked out here, never asking the editor (a busy one held Space Tab up, 2026-11-17).
      if M.is_popout() then return M.client_swap() end
      local after = next_attached(ctx.pop)
      M.focus(after and { pid = after.pid } or { pid = vim.fn.getpid(), pane = host_pane() })
    end },
  { id = 'popout.close', group = 'Pop-out', name = 'Close this view', key = 'q', on = ON, remote = true,
    about = 'Close this view; closing the last one closes the pop-out, and the keyboard comes back to the editor',
    run = function(ctx)
      if not M.is_popout() then
        local p = pressed_in(ctx)
        if ctx.view then M.remember_closed(ctx.view, p) end
        if ctx.view and #p.order > 1 then M.clear(ctx.view.id)
        else
          -- The last one: the pop-out closes, and the keyboard comes here rather than stay on its empty screen.
          forget(p, nil)
          if ctx.remote then M.focus({ pid = vim.fn.getpid(), pane = host_pane() }) end
        end
        return M.save_layout()
      end
      if shown() and vim.tbl_count(C.views) > 1 then return client_act('popout.close') end
      leaving()
      C.closing = 'closed'
      vim.cmd('qa!')
    end },
  -- symdeps' two keys in the editor, here: each does what it does there, or says why not (her ask, 2026-11-17: "there
  -- needs to be like some consistency between what works in the popout, and wat works in the actual editor"). symdeps
  -- never loads in a pop-out (init.lua's spec), so its menu key is this window's menu, which has the board's rows.
  { id = 'popout.symdeps-menu', group = 'Pop-out', name = "The pop-out's menu", key = '<leader>dm', on = ON, menu = false,
    about = "symdeps' menu key: here, this window's menu for the view in front, as `Space Space` (on symdeps' board, its rows)",
    run = function() M.client_home() end },
  { id = 'popout.symdeps-card', group = 'Pop-out', name = "symdeps' card: not here", key = '<leader>dd', on = ON, menu = false,
    about = "symdeps' card key: here it says why not (on symdeps' board, the card is the one drawn; elsewhere symdeps runs in the editor, `Space Tab` away)",
    run = function() say(no_card_here(), WARN) end },
  { id = 'popout.home', group = 'Home', name = 'Home menu', key = '<leader><leader>', on = ON, menu = false,
    about = 'The home menu for the selected box or row: the views, what the editor can do with it, and this window', run = function() M.client_home() end },
})
for _, row in ipairs(ROWS) do if row.id == 'popout.restore' then RESTORE = row end end

-- The editor exiting: the layout is written, every pop-out told, and nothing of them left running to keep this editor
-- waiting (their channels and pings, the watch on the screens, the views' own timers).
local function close_timer(owner, name)
  local timer = owner[name]
  if timer then
    timer:stop()
    if not timer:is_closing() then timer:close() end
    owner[name] = nil
  end
end
local function shutdown()
  if L.down then return end
  if any_open() or (L.save_timer and L.save_timer:is_active()) then M.save_layout(true)
  elseif L.pending then write_now(L.pending, true) end   -- the newest state, behind a write still on its way
  L.down = true
  close_timer(L, 'save_timer')
  unwatch_screens()
  follow_stop()
  for _, p in ipairs(pops) do
    local chan = p.chan
    if chan then pcall(vim.rpcnotify, chan, 'nvim_exec_lua', POPOUT_DOOR, { { version = M.PROTOCOL, type = 'bye', why = 'Editor closed.' } }) end
    close_timer(p, 'timer')
    for _, view in pairs(p.views) do leave(view) end
    p.chan = nil
    if chan then pcall(vim.fn.chanclose, chan) end
  end
end

local set = false
function M.setup()
  if set or M.is_popout() then return end
  set = true
  require('desk.codeview').setup()
  actions.map('editor', { rows = ROWS })
  api.nvim_create_user_command('PopOut', function(opts) M.show(opts.args ~= '' and opts.args or 'graph', actions.context()) end,
    { nargs = '?', complete = function() return vim.tbl_keys(kinds) end, desc = 'A view in the pop-out window (the live call graph when none is named)' })
  local group = api.nvim_create_augroup('desk_popout', { clear = true })
  api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function() pcall(shutdown) end })
  api.nvim_create_autocmd({ 'BufEnter', 'DirChanged', 'TabEnter' }, { group = group, callback = front_moved })
  L.saved_root = checkout_of()
  M.read_layout()
end

return M
