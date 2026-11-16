-- The pop-out: a second Neovim in a kitty window of its own, on another screen, that shows views the main editor sends
-- and whose keys act in the main editor. Enter there moves the main editor and the keyboard stays in the pop-out.
--
-- One module, two sides. The main editor (the host) opens it (M.open: kitty --class desk-popout -e nvim … --
-- desk-popout:<its socket>, the socket only ever in argv), keeps the views and lays them out for the pop-out's width
-- (the call graph: desk.callgraph's layout), and answers four bridge messages from it: subscribe, describe, act and
-- pong. It sends four back on the same channel, as rpcnotify of M.receive: view.set { id, gen, title, lines, marks, hl,
-- items }, view.clear, ping (every 10 s; a pop-out that stops answering is sent nothing until it answers again) and
-- bye. The pop-out (M.client, from its own argv) draws those in a plain buffer, edits no file and runs no language
-- server (init.lua's desk-popout block). Its keys are rows of the 'popout' surface; the ones that act in the editor are
-- remote rows, which the editor runs (actions.act) only for the view generation it sent.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
local actions = require('desk.actions')
local bridge = require('desk.bridge')

M.CLASS = 'desk-popout'
M.PING_MS, M.WATCH_MS, M.LINGER_MS, M.GAP_MS, M.START_MS = 10000, 2000, 1500, 50, 15000
M.MAX_LINES, M.MAX_ITEMS = 2000, 500
-- The two doors: the editor's (desk.bridge, as desk-work uses it) and the pop-out's.
local HOST_DOOR = "return require('desk.bridge').receive(...)"
local POPOUT_DOOR = "return require('desk.popout').receive(...)"
local WARN = vim.log.levels.WARN

local function graphs() return require('desk.callgraph') end
local function now_ms() local s, us = uv.gettimeofday(); return s * 1000 + math.floor(us / 1000) end
local function tell(text, level) vim.notify(text, level or vim.log.levels.INFO, { title = 'Pop-out' }) end
local function refuse(why) return { refused = why } end
local function have(name) return vim.fn.executable(name) == 1 end
local function list(value) return type(value) == 'table' and value or { value } end
-- 'requires kitty' → 'Requires kitty.'
local function sentence(text)
  text = tostring(text)
  return text:sub(1, 1):upper() .. text:sub(2) .. (text:match('[.!?…]$') and '' or '.')
end
function M.is_popout() local p = vim.g.desk_popout; return p ~= nil and p ~= 0 and p ~= false end

-- Keys as a person reads them: Enter, Shift+Enter, Space Tab.
local NAMES = { ['<CR>'] = 'Enter', ['<S-CR>'] = 'Shift+Enter', ['<Tab>'] = 'Tab', ['<S-Tab>'] = 'Shift+Tab', ['<Esc>'] = 'Esc',
  ['<2-LeftMouse>'] = 'double click' }
function M.shown_key(key)
  key = tostring(key or '')
  if NAMES[key] then return NAMES[key] end
  local rest = key:match('^<[lL]eader>(.*)$')
  if rest then return 'Space ' .. (rest:lower() == '<leader>' and 'Space' or NAMES[rest] or rest) end
  return key
end
local function typed(id) return M.shown_key(actions.key(id)) end

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
-- monitors: hyprctl -j monitors. { name, workspace } or nil.
function M.target_screen(monitors, layout)
  local live, focused, order = {}, nil, {}
  for _, m in ipairs(type(monitors) == 'table' and monitors or {}) do
    if type(m) == 'table' and type(m.name) == 'string' and not m.disabled then
      live[m.name] = m
      if m.focused then focused = m.name end
    end
  end
  layout = layout or {}
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
-- it), else the window above its process, on whichever screen that is. who: { pid, pane }. done(ok, why).
function M.focus(who, done)
  done = done or function(ok, why) if not ok then tell(sentence(why), WARN) end end
  if type(who) ~= 'table' or type(who.pid) ~= 'number' then return done(false, 'there is no other window to go to') end
  if type(who.pane) == 'string' and who.pane:match('^%%%d+$') and have('desk-drawer') then
    local ok = pcall(vim.system, { 'desk-drawer', 'run', 'work-jump', who.pane }, { text = true, timeout = 5000 })
    return done(ok, not ok and 'desk-drawer did not start' or nil)
  end
  if not have('hyprctl') then return done(false, 'requires Hyprland') end
  hyprctl({ 'clients' }, function(clients)
    local address = M.window_of(who.pid, clients)
    if not address then return done(false, 'its window was not found') end
    M.dispatch(("hl.dsp.focus({ window = 'address:%s' })"):format(address), 'focuswindow address:' .. address)
    done(true)
  end)
end

-- ─── the main editor's side ────────────────────────────────────────────────────────────────────────────────────
-- chan: the pop-out's channel once it subscribed; pid: its Neovim; width: its window; opening: a kitty on its way;
-- views by id; gen: the newest generation sent; ping and heard: the pings sent and answered; stalled: not answering.
local H = { views = {}, gen = 0, ping = 0, heard = 0, width = 80 }
M.host = H   -- the tests read it

local function host_pane()
  local term, pane = vim.env.TERM or '', vim.env.TMUX_PANE or ''
  return ((term:match('^tmux') or term:match('^screen')) and pane:match('^%%%d+$')) and pane or ''
end

local function send(msg)
  if not H.chan or H.stalled then return false end
  msg.version = 1
  local ok = pcall(vim.rpcnotify, H.chan, 'nvim_exec_lua', POPOUT_DOOR, { msg })
  if not ok then M.forget('The pop-out closed.') end
  return ok
end

-- The highlight groups a call graph uses, as this editor draws them: the pop-out may not define them.
local GROUPS = { 'DeskCallGraphCentre', 'DeskCallGraphBox', 'DeskCallGraphName', 'DeskCallGraphDim', 'DeskCallGraphHead',
  'DeskCallGraphKey', 'DeskCallGraphSelected' }
local ATTRS = { fg = 'number', bg = 'number', sp = 'number', blend = 'number', bold = 'boolean', italic = 'boolean',
  underline = 'boolean', undercurl = 'boolean', underdouble = 'boolean', underdotted = 'boolean', underdashed = 'boolean',
  strikethrough = 'boolean', reverse = 'boolean', standout = 'boolean', nocombine = 'boolean' }
local function clean_hl(def)
  local out = {}
  for key, kind in pairs(ATTRS) do if type(def) == 'table' and type(def[key]) == kind then out[key] = def[key] end end
  return out
end
local function definitions()
  graphs().highlights()
  local out = {}
  for _, name in ipairs(GROUPS) do out[name] = clean_hl(api.nvim_get_hl(0, { name = name, link = false })) end
  return out
end

local function key_line(pinned)
  return { { typed('popout.down') .. '/' .. typed('popout.up') .. '/' .. typed('popout.left') .. '/' .. typed('popout.right'), 'move' },
    { typed('popout.go'), 'go' }, { typed('popout.pin'), pinned and 'follow' or 'pin' }, { typed('popout.home'), 'menu' },
    { typed('popout.keys'), 'keys' }, { typed('popout.close'), 'close' } }
end

-- A view as the pop-out draws it, laid out for its width: lines, marks, the highlight definitions and the boxes to select
-- (view.items keeps each box's item here, for the generation this payload carries).
local function payload(view)
  local G = graphs()
  local graph = vim.tbl_extend('force', {}, view.graph or { message = 'move the cursor into a function' },
    { keys = key_line(view.pinned), header = view.pinned and 'PINNED' or nil })
  local drawn = G.layout(graph, math.max(16, (H.width or 80) - 2), G.retro())
  local lines, marks = drawn.lines, drawn.marks
  if #lines > M.MAX_LINES then
    lines = vim.list_slice(lines, 1, M.MAX_LINES - 1)
    lines[#lines + 1] = '… ' .. (#drawn.lines - #lines) .. ' more lines'
    marks = vim.tbl_filter(function(m) return m[1] < M.MAX_LINES end, marks)
  end
  local items = {}
  view.items = {}
  for i, box in ipairs(drawn.boxes) do
    if i > M.MAX_ITEMS then break end
    view.items[i] = box.item
    items[i] = { top = box.top, x = box.x, w = box.w, name_col = box.name_col, centre = box.centre == true, spans = box.spans,
      name = tostring(box.item.name or '') }
  end
  local center = graph.center
  return { type = 'view.set', id = view.id, gen = view.gen, title = 'call graph' .. (center and center.name and (' · ' .. center.name) or ''),
    lines = lines, marks = marks, hl = definitions(), items = items }
end

-- Sends a view as it is now, one per view every M.GAP_MS at most (the last state wins). A new generation only when the
-- drawing changed: the same one sent again (it answers again, a resize to the same width) keeps the boxes it named.
local function push(view)
  if not H.chan or H.stalled or H.views[view.id] ~= view then return end
  local wait = (view.sent or -M.GAP_MS) + M.GAP_MS - uv.now()
  if wait > 0 then
    if not view.queued then
      view.queued = true
      vim.defer_fn(function() view.queued = false; push(view) end, wait)
    end
    return
  end
  view.sent = uv.now()
  local msg = payload(view)
  local drawing = table.concat(msg.lines, '\n') .. '\0' .. #msg.items
  if drawing ~= view.drawing then
    H.gen = H.gen + 1
    view.gen, view.drawing = H.gen, drawing
  end
  msg.gen = view.gen
  send(msg)
end
local function push_all() for _, view in pairs(H.views) do push(view) end end

-- ─── following the editor's cursor ─────────────────────────────────────────────────────────────────────────────
-- As the live panel does: after the cursor rests M.DEBOUNCE_MS in another function, or at once on symdeps'
-- FoxUnitChanged (its follow card moves on it, so both move together); answers cached until that file is saved; one
-- request at a time.
local F = { cache = {} }
M.following = F
local function graph_view() return H.views.callgraph end

local function code_window(win)
  if not (win and api.nvim_win_is_valid(win)) or api.nvim_win_get_config(win).relative ~= '' then return false end
  local buf = api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == '' and vim.b[buf].desk_callgraph == nil
end
local function placeholder(target)
  if target.item then return target.item end
  return { name = target.name, detail = vim.fn.fnamemodify(api.nvim_buf_get_name(target.buf), ':t') .. ':' .. (target.row + 1),
           buf = target.buf, row = target.row, col = target.col }
end
local function cache_key(t) return vim.uri_from_bufnr(t.buf) .. '\0' .. tostring(t.name) .. '\0' .. tostring(t.row) end

-- The graph of target ({buf, row, col, name} or {buf, item}) from the language server: done(graph) always, with the
-- reason as its message when there is none. Returns a function that stops it.
local function fetch(target, done, waiting)
  local G = graphs()
  local stop_fetch
  local stop_wait = G.ready(target.buf, function(client, why)
    if not client then return done({ center = placeholder(target), message = why }) end
    stop_fetch = G.fetch(client, target, function(graph, err)
      if graph and why then graph.notes = { why } end
      done(graph or { center = placeholder(target), message = err })
    end)
  end, waiting)
  return function() stop_wait(); if stop_fetch then stop_fetch() end end
end

local function show_followed(graph, target)
  local view = graph_view()
  if not view or view.pinned then return end
  view.graph, view.target = graph, target or view.target
  push(view)
end

local function follow_request()
  if F.inflight or not F.wanted then return end
  local target = F.wanted
  F.wanted = nil
  local key = cache_key(target)
  if F.cache[key] then
    if F.key == target.key then show_followed(F.cache[key], target) end
    return follow_request()
  end
  F.inflight = target
  F.stop = fetch(target, function(graph)
    F.inflight, F.stop = nil, nil
    F.cache[key] = graph
    if F.key == target.key then show_followed(graph, target) end
    follow_request()
  end, function(message) if F.key == target.key then show_followed({ center = placeholder(target), message = message }, target) end end)
end

-- Where the cursor is now in the followed window: drawn from the cache, or asked. Pinned, the graph stays put.
function M.follow_update()
  local view = graph_view()
  if not view or view.pinned or not code_window(F.win) then return end
  local win = F.win
  local buf, cursor, G = api.nvim_win_get_buf(win), api.nvim_win_get_cursor(win), graphs()
  G.with_tree(buf, function(tree)
    if graph_view() ~= view or view.pinned or not api.nvim_buf_is_valid(buf) then return end
    local target, why = G.symbol_in(tree, buf, cursor[1] - 1, cursor[2])
    if not tree then target, why = nil, 'no treesitter parser for this file type' end
    local key = target and target.key or ('none:' .. buf .. ':' .. tostring(why))
    if key == F.key then return end
    F.key, view.win = key, win
    if not target then return show_followed({ message = why }, nil) end
    local cached = F.cache[cache_key(target)]
    if cached then F.wanted = nil; return show_followed(cached, target) end
    show_followed({ center = placeholder(target), message = 'reading the call hierarchy…' }, target)
    -- Back on the function already being asked about: its answer is on the way.
    if F.inflight and F.inflight.key == target.key then F.wanted = nil; return end
    F.wanted = target
    follow_request()
  end)
end

-- A cursor move in a window: the graph waits for the cursor to rest. Pinned, only the window Enter goes to is kept.
function M.follow_moved(win)
  local view = graph_view()
  if not view or not code_window(win) then return end
  F.win = win
  if view.pinned then return end
  F.timer = F.timer or uv.new_timer()
  F.timer:stop()
  F.timer:start(graphs().DEBOUNCE_MS, 0, vim.schedule_wrap(M.follow_update))
end

local function forget_file(buf)
  local uri = vim.uri_from_bufnr(buf)
  for key in pairs(F.cache) do if key:sub(1, #uri + 1) == uri .. '\0' then F.cache[key] = nil end end
  if F.key and (F.key:match('^' .. buf .. ':') or F.key:match('^none:' .. buf .. ':')) then F.key = nil end
end

-- A pinned graph is read again once its own file is saved (by the server's item when it has one: a save can move it).
local function refresh_pinned(buf)
  local view = graph_view()
  local target = view and view.pinned and view.target
  if not (target and target.buf == buf) then return end
  local center = view.graph and view.graph.center
  local again = center and center.raw and vim.tbl_extend('force', {}, target, { item = center }) or target
  if view.stop then view.stop() end
  view.stop = fetch(again, function(graph)
    view.stop = nil
    if graph_view() == view then view.graph = graph; push(view) end
  end)
end

local function follow_start()
  local group = api.nvim_create_augroup('desk_popout_follow', { clear = true })
  api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter', 'InsertLeave' }, { group = group,
    callback = function() M.follow_moved(api.nvim_get_current_win()) end })
  api.nvim_create_autocmd('User', { group = group, pattern = 'FoxUnitChanged', callback = function()
    local win = api.nvim_get_current_win()
    if not code_window(win) then return end
    F.win = win
    if F.timer then F.timer:stop() end
    M.follow_update()
  end })
  api.nvim_create_autocmd({ 'BufWritePost', 'LspAttach' }, { group = group, callback = function(a)
    forget_file(a.buf)
    refresh_pinned(a.buf)
    M.follow_moved(api.nvim_get_current_win())
  end })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = push_all })
end
local function follow_stop()
  pcall(api.nvim_del_augroup_by_name, 'desk_popout_follow')
  if F.timer then F.timer:stop() end
  if F.stop then F.stop() end
  F.inflight, F.wanted, F.stop, F.key = nil, nil, nil, nil
end

local function graph_view_new()
  local view = { id = 'callgraph', gen = 0, items = {}, pinned = false }
  H.views.callgraph = view
  follow_start()
  return view
end

-- Takes a view off the pop-out (it goes back to the editor, or the pop-out went).
function M.clear(id)
  local view = H.views[id]
  if not view then return end
  if view.stop then view.stop() end
  H.views[id] = nil
  if id == 'callgraph' then follow_stop() end
  send({ type = 'view.clear', id = id })
end

-- The pop-out is gone (it closed, or q there): nothing more is sent and nothing follows the cursor for it.
function M.forget(why)
  local had = H.chan ~= nil or next(H.views) ~= nil
  H.chan, H.pid, H.stalled, H.opening = nil, nil, false, nil
  if H.timer then H.timer:stop() end
  for _, view in pairs(H.views) do if view.stop then view.stop() end end
  H.views = {}
  follow_stop()
  if had and why then tell(why) end
end

local function start_pings()
  H.timer = H.timer or uv.new_timer()
  H.timer:stop()
  H.timer:start(M.PING_MS, M.PING_MS, vim.schedule_wrap(function()
    if not H.chan then return H.timer:stop() end
    if next(api.nvim_get_chan_info(H.chan)) == nil then return M.forget('The pop-out closed.') end
    if H.ping > H.heard and not H.stalled then
      H.stalled = true
      tell('The pop-out stopped answering; nothing more is sent to it until it does.', WARN)
    end
    H.ping = H.ping + 1
    pcall(vim.rpcnotify, H.chan, 'nvim_exec_lua', POPOUT_DOOR, { { version = 1, type = 'ping', serial = H.ping } })
  end))
end

-- The pop-out window appears floating at the side of the screen it opens on (the Hyprland rule, which also keeps the
-- focus here). With another screen it then moves, tiled, to the workspace showing there.
function M.place(pid)
  if type(pid) ~= 'number' or not have('hyprctl') then return end
  hyprctl({ 'monitors' }, function(monitors)
    local screen = M.target_screen(monitors, M.screens())
    if not screen then return end
    local tries = 0
    local function look()
      tries = tries + 1
      hyprctl({ 'clients' }, function(clients)
        local address
        for _, c in ipairs(type(clients) == 'table' and clients or {}) do
          if type(c) == 'table' and c.pid == pid and c.class == M.CLASS and type(c.address) == 'string' and c.address:match('^0x%x+$') then address = c.address end
        end
        if not address then
          if tries < 30 then vim.defer_fn(look, 100) end
          return
        end
        local where = tostring(screen.workspace)
        M.dispatch(("hl.dsp.window.move({ workspace = '%s', follow = false, window = 'address:%s' })"):format(where, address),
          ('movetoworkspacesilent %s,address:%s'):format(where, address), function()
            M.dispatch(("hl.dsp.window.float({ action = 'unset', window = 'address:%s' })"):format(address), 'settiled address:' .. address)
          end)
      end)
    end
    look()
  end)
end

-- Opens the pop-out when none is attached or on its way. true, or false and why.
function M.open()
  if H.chan or H.opening then return true end
  local server = vim.v.servername or ''
  if #server > 107 or not server:match('^/[%w%._/%-]+$') then return false, 'this editor has no socket the pop-out can reach' end
  if not have('kitty') then return false, 'requires kitty' end
  -- The socket travels in argv only. The pop-out's Neovim gets none of this editor's tmux (its footer is this
  -- editor's) and no $NVIM (it is not a terminal inside this editor).
  local argv = { 'kitty', '--class', M.CLASS, '-e', 'nvim', '--cmd', 'let g:desk_popout=1', '-c', "lua require('desk.popout').client()",
    '--', 'desk-popout:' .. server }
  local opening = {}
  local ok, job = pcall(vim.system, argv, { text = true, detach = true, env = { TMUX = '', TMUX_PANE = '', NVIM = '' } }, function()
    vim.schedule(function() if H.opening == opening then H.opening = nil end end)
  end)
  if not ok then return false, 'kitty did not start (' .. tostring(job):sub(1, 120) .. ')' end
  opening.pid = job.pid
  H.opening = opening
  M.place(job.pid)
  vim.defer_fn(function()
    if H.opening == opening then H.opening = nil; tell('The pop-out did not start.', WARN) end
  end, M.START_MS)
  return true
end

-- Whether the pop-out can be opened from here: true, or why not; false where it does not apply.
local function can_pop()
  if M.is_popout() or vim.g.desk_work_view then return false end
  if not have('kitty') then return 'requires kitty' end
  return M.second_screen()
end
local function refused_here(why)
  if why == true then return false end
  tell(sentence(why == false and 'not here' or why), WARN)
  return true
end

-- The live call graph on the pop-out, following the cursor from win ("Pop out the call graph").
function M.show_callgraph(win)
  if refused_here(can_pop()) then return end
  local ok, why = M.open()
  if not ok then return tell(sentence(why), WARN) end
  local view = graph_view() or graph_view_new()
  view.pinned, F.key = false, nil
  if code_window(win) then F.win, view.win = win, win; M.follow_update() end
  push(view)
end

-- Sends a graph tab or the live panel (s, as desk.callgraph passes it in ctx.graph) to the pop-out and closes it here.
function M.detach(s)
  if refused_here(can_pop()) or type(s) ~= 'table' then return end
  local G = graphs()
  local ok, why = M.open()
  if not ok then return tell(sentence(why), WARN) end
  local from_panel = s == G.panel
  local view = graph_view() or graph_view_new()
  view.graph, view.target = s.graph, s.target
  view.pinned = not from_panel or s.pinned == true   -- a tab shows one chosen function: it arrives pinned
  view.win = from_panel and s.source_win or s.origin
  F.key, F.win = nil, view.win
  if from_panel then G.panel_close() else G.close_view(s.buf) end
  local graph = view.graph or {}
  if view.pinned and view.target and not (graph.callers or graph.callees) then
    -- Still being read when it left: read again for the pop-out.
    view.stop = fetch(view.target, function(answer)
      view.stop = nil
      if graph_view() == view then view.graph = answer; push(view) end
    end)
  elseif not view.pinned then
    M.follow_update()
  end
  push(view)
end

-- Brings the pop-out's graph back to the editor as the live panel (a split beside the code), pinned to it when it was
-- pinned there. The pop-out stays open, empty, for the next one.
function M.attach(view)
  view = view or graph_view()
  if not view then return end
  local graph, target, pinned, win = view.graph, view.target, view.pinned, view.win
  M.clear(view.id)
  if code_window(win) then pcall(api.nvim_set_current_win, win) end
  graphs().panel_open_with(graph, target, pinned)
end

-- The code window a box is gone to in: the one the graph came from, else the current one, else the first in this tab.
local function target_window(view)
  if view and code_window(view.win) then return view.win end
  local here = api.nvim_get_current_win()
  if code_window(here) then return here end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do if code_window(win) then return win end end
end
local function go(ctx, focus)
  if not ctx.item then return end
  graphs().jump(ctx.item, target_window(ctx.view))
  if focus then M.focus({ pid = vim.fn.getpid(), pane = host_pane() }) end
end
local function centre(ctx)
  local view, item = ctx.view, ctx.item
  if not (view and item and item.raw) then return end
  local buf = view.target and view.target.buf
  if not (buf and api.nvim_buf_is_valid(buf)) then buf = api.nvim_win_get_buf(target_window(view) or 0) end
  local target = { buf = buf, item = item, name = item.name }
  view.pinned, view.target, view.graph = true, target, { center = item, message = 'reading the call hierarchy…' }
  if view.stop then view.stop() end
  push(view)
  view.stop = fetch(target, function(graph)
    view.stop = nil
    if graph_view() == view then view.graph = graph; push(view) end
  end, function(message) if graph_view() == view then view.graph = { center = item, message = message }; push(view) end end)
end
local function pin(ctx)
  local view = ctx.view or graph_view()
  if not view then return end
  view.pinned = not view.pinned
  if not view.pinned then
    F.key = nil
    if not code_window(F.win) then F.win = target_window(view) end
    M.follow_update()
  end
  push(view)
end
local function symdeps_card(ctx)
  if not ctx.item then return end
  go(ctx, false)
  local found, card = pcall(require, 'fox-symdeps.card')
  local plugin = package.loaded['fox-symdeps']
  local inspect = (found and type(card) == 'table' and type(card.inspect_cursor) == 'function' and card.inspect_cursor)
    or (type(plugin) == 'table' and type(plugin.inspect_cursor) == 'function' and plugin.inspect_cursor) or nil
  if not inspect then return tell('This symdeps version does not expose its card.') end
  inspect()
end

-- ─── the bridge messages the editor takes from its pop-out ─────────────────────────────────────────────────────
-- The view, generation and box an ask names, as a ctx for the action registry (surface 'popout'). A view that has
-- been drawn again since refuses: its boxes are not the ones the pop-out saw.
local function remote_ctx(msg)
  if not H.chan then return nil, 'no pop-out is subscribed to this editor' end
  local view, item
  if msg.view ~= nil then
    view = H.views[msg.view]
    if not view then return nil, 'this view is no longer shown' end
    if msg.gen ~= view.gen then return nil, 'this view moved on' end
  end
  if msg.item ~= nil then
    item = view and view.items[msg.item]
    if not item then return nil, 'there is no such box in this view' end
  end
  local ctx = actions.context(api.nvim_get_current_win())
  ctx.surface, ctx.view, ctx.item, ctx.remote = 'popout', view, item, true
  return ctx
end

-- subscribe { chan, pid, width }: chan is the pop-out's channel here (nvim_get_api_info gave it the number), labelled
-- with its pid through nvim_set_client_info, since code run by nvim_exec_lua cannot tell which channel called. Again
-- from the same channel (a resize): the new width, every view drawn again.
local function subscribe(msg)
  if M.is_popout() or vim.g.desk_work_view then return refuse('this editor keeps no pop-out') end
  local info = api.nvim_get_chan_info(msg.chan)
  local client = type(info.client) == 'table' and info.client or {}
  local attributes = type(client.attributes) == 'table' and client.attributes or {}
  if info.mode ~= 'rpc' or client.name ~= M.CLASS or attributes.pid ~= tostring(msg.pid) then
    return refuse('a pop-out subscribes on its own channel, named with nvim_set_client_info first')
  end
  if H.chan and H.chan ~= msg.chan then send({ type = 'bye', why = 'Another pop-out took over.' }) end
  local again = H.chan == msg.chan
  H.chan, H.pid, H.width, H.opening = msg.chan, msg.pid, msg.width or H.width, nil
  if not again then
    H.stalled, H.ping, H.heard = false, 0, 0
    start_pings()
  end
  vim.schedule(function() for _, view in pairs(H.views) do view.sent = nil; push(view) end end)
  return { subscribed = true, pid = vim.fn.getpid(), pane = host_pane() }
end

-- describe { view, gen, item }: what the pop-out may offer for that box, as plain data (actions.describe).
local function describe(msg)
  local ctx, why = remote_ctx(msg)
  if not ctx then return refuse(why) end
  return { rows = actions.describe(ctx) }
end

-- act { view, gen, item, action }: runs a remote row, after this answer.
local function act(msg)
  local ctx, why = remote_ctx(msg)
  if not ctx then return refuse(why) end
  local row = actions.get(msg.action)
  if not row then return refuse('no action is called ' .. msg.action) end
  if not row.remote then return refuse(msg.action .. ' is not one the pop-out may ask for') end
  local can = actions.available(row, ctx)
  if can ~= true then return refuse(can == false and (msg.action .. ' does not apply here') or tostring(can)) end
  vim.schedule(function()
    local ok, err = actions.act(msg.action, ctx)
    if not ok then tell(sentence(err or (msg.action .. ' did not run')), WARN) end
  end)
  return { done = true }
end

-- pong { serial }: the pop-out answered a ping; one that had stopped answering gets its views again.
local function pong(msg)
  if not H.chan then return { heard = false } end
  H.heard = math.max(H.heard, msg.serial)
  if H.stalled and H.heard >= H.ping then
    H.stalled = false
    tell('The pop-out answers again.')
    vim.schedule(function() for _, view in pairs(H.views) do view.sent = nil; push(view) end end)
  end
  return { heard = true }
end

local ID, NUMBER = bridge.field('string', 32), bridge.field('integer', 2147483647)
bridge.register('subscribe', subscribe, { chan = bridge.field('integer', 2147483647, true), pid = bridge.field('integer', 2147483647, true),
  width = bridge.field('integer', 1000) })
bridge.register('describe', describe, { view = ID, gen = NUMBER, item = bridge.field('integer', M.MAX_ITEMS) })
bridge.register('act', act, { view = ID, gen = NUMBER, item = bridge.field('integer', M.MAX_ITEMS), action = bridge.field('string', 64, true) })
bridge.register('pong', pong, { serial = bridge.field('integer', 2147483647, true) })

-- ─── the pop-out's side ────────────────────────────────────────────────────────────────────────────────────────
-- chan: to the editor; me: that channel's number there; host: { pid, pane } of the editor; views by id, shown: the one
-- drawn; surface: the selection over its boxes (desk.callgraph's model); closing: why it is closing.
local C = { views = {}, surface = {} }
local ns = api.nvim_create_namespace('desk_popout')

local function say(text, level) vim.notify(sentence(text), level or vim.log.levels.INFO, { title = 'Pop-out' }) end
local function width() return C.win and api.nvim_win_is_valid(C.win) and api.nvim_win_get_width(C.win) or vim.o.columns end

local function request(msg, budget)
  if not C.chan then return refuse('the pop-out is not connected to an editor') end
  msg.version, msg.deadline = 1, now_ms() + (budget or 2000)
  local ok, answer = pcall(vim.rpcrequest, C.chan, 'nvim_exec_lua', HOST_DOOR, { msg })
  if not ok then return refuse('the editor did not answer (' .. (tostring(answer):gsub('\n.*', '')):sub(1, 160) .. ')') end
  return type(answer) == 'table' and answer or refuse('the editor gave no answer')
end

-- A remote row pressed here: the editor runs it for the box selected in the view generation drawn here.
local function client_act(id)
  local view = C.shown and C.views[C.shown]
  local msg = { type = 'act', action = id }
  if view then msg.view, msg.gen, msg.item = view.id, view.gen, C.surface.index end
  local answer = request(msg)
  if answer.refused then say(answer.refused, WARN) end
  return answer
end

-- What the window shows with no view: a line saying where things are, and the keys.
local function empty(message)
  local G = graphs()
  G.highlights()
  local drawn = G.layout({ message = message, keys = { { typed('popout.home'), 'menu' }, { typed('popout.keys'), 'keys' },
    { typed('popout.close'), 'close' } } }, math.max(16, width() - 2), G.retro())
  return { id = '', gen = 0, title = 'pop-out', lines = drawn.lines, marks = drawn.marks, hl = {}, items = {} }
end

local function valid_spans(spans)
  if type(spans) ~= 'table' or #spans == 0 or #spans > 8 then return false end
  for _, span in ipairs(spans) do
    if type(span) ~= 'table' or type(span[1]) ~= 'number' or type(span[2]) ~= 'number' or type(span[3]) ~= 'number' then return false end
  end
  return true
end
-- A view.set, checked: whatever does not fit is left out, never drawn half.
local function valid_view(msg)
  if type(msg.id) ~= 'string' or #msg.id > 32 or not msg.id:match('^[%w_.-]+$') or type(msg.gen) ~= 'number' then return nil end
  if type(msg.lines) ~= 'table' or #msg.lines > M.MAX_LINES then return nil end
  local lines, marks, items, hl = {}, {}, {}, {}
  for i, line in ipairs(msg.lines) do
    if type(line) ~= 'string' then return nil end
    lines[i] = line:gsub('[\r\n]', ' ')
  end
  for _, m in ipairs(type(msg.marks) == 'table' and msg.marks or {}) do
    if #marks < 20000 and type(m) == 'table' and type(m[1]) == 'number' and type(m[2]) == 'number' and type(m[3]) == 'number'
      and type(m[4]) == 'string' and m[4]:match('^[%w_]+$') then marks[#marks + 1] = m end
  end
  for i, box in ipairs(type(msg.items) == 'table' and msg.items or {}) do
    if i > M.MAX_ITEMS or type(box) ~= 'table' or type(box.top) ~= 'number' or not valid_spans(box.spans) then break end
    items[i] = { top = box.top, x = tonumber(box.x) or 0, w = tonumber(box.w) or 1, name_col = tonumber(box.name_col) or 0,
      centre = box.centre == true, spans = box.spans, name = type(box.name) == 'string' and box.name:sub(1, 200) or '' }
  end
  for name, def in pairs(type(msg.hl) == 'table' and msg.hl or {}) do
    if type(name) == 'string' and (name:match('^Desk[%w_]+$') or name:match('^FoxSymdeps[%w_]+$')) then hl[name] = clean_hl(def) end
  end
  return { id = msg.id, gen = msg.gen, title = type(msg.title) == 'string' and msg.title:sub(1, 200) or msg.id, lines = lines,
    marks = marks, items = items, hl = hl }
end

-- Draws a view in the pop-out's buffer. The same view drawn again keeps its selected box; another one starts on its
-- centre box.
local function draw(view)
  local buf, G = C.buf, graphs()
  if not (buf and api.nvim_buf_is_valid(buf)) then return end
  if C.win and api.nvim_win_is_valid(C.win) and api.nvim_win_get_buf(C.win) ~= buf then pcall(api.nvim_win_set_buf, C.win, buf) end
  for name, def in pairs(view.hl) do pcall(api.nvim_set_hl, 0, name, def) end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, view.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(view.marks) do
    pcall(api.nvim_buf_set_extmark, buf, ns, m[1] - 1, m[2], { end_col = m[3], hl_group = m[4], priority = 100 + (tonumber(m[5]) or 0) })
  end
  pcall(api.nvim_buf_set_name, buf, 'pop-out · ' .. view.title)
  local s = C.surface
  local keep = s.title == view.title and s.count == #view.items and s.index or nil
  s.buf, s.win, s.drawn, s.index, s.title, s.count = buf, C.win, { boxes = view.items }, nil, view.title, #view.items
  local first = keep
  for i, box in ipairs(view.items) do if not first and box.centre then first = i end end
  first = first or (view.items[1] and 1)
  api.nvim_buf_clear_namespace(buf, G.sel_ns, 0, -1)
  if first then G.select(s, first, true) end
end

-- The editor went away (it said bye, or its channel closed): say so, then quit.
function M.closing(why)
  if C.closing then return end
  C.closing = why
  if C.watch then C.watch:stop() end
  C.chan = nil
  say(why)
  draw(empty(why))
  vim.defer_fn(function() vim.cmd('qa!') end, M.LINGER_MS)
end

local RECEIVES = { ['view.set'] = true, ['view.clear'] = true, ping = true, bye = true }
local function handle(msg)
  if msg.type == 'view.set' then
    local view = valid_view(msg)
    if not view then return end
    C.views[view.id], C.shown, C.received = view, view.id, (C.received or 0) + 1
    draw(view)
  elseif msg.type == 'view.clear' then
    if type(msg.id) ~= 'string' then return end
    C.views[msg.id] = nil
    if C.shown == msg.id then
      C.shown = next(C.views)
      draw(C.shown and C.views[C.shown] or empty('nothing is shown here: ' .. typed('popout.send') .. ' in a call graph sends it here'))
    end
  elseif msg.type == 'ping' then
    if C.chan and type(msg.serial) == 'number' then
      pcall(vim.rpcnotify, C.chan, 'nvim_exec_lua', HOST_DOOR, { { version = 1, type = 'pong', serial = msg.serial } })
    end
  elseif msg.type == 'bye' then
    M.closing(type(msg.why) == 'string' and msg.why:sub(1, 200) or 'Editor closed.')
  end
end

-- The pop-out's door: what the editor sends, drawn on the next tick so the editor's rpcnotify returns at once.
function M.receive(msg)
  if not M.is_popout() or type(msg) ~= 'table' or msg.version ~= 1 or not RECEIVES[msg.type] then return false end
  vim.schedule(function()
    local ok, err = pcall(handle, msg)
    if not ok then say('could not draw what the editor sent: ' .. tostring(err):sub(1, 200), WARN) end
  end)
  return true
end

function M.subscribe()
  local answer = request({ type = 'subscribe', chan = C.me, pid = vim.fn.getpid(), width = math.min(1000, width()) })
  if not answer.refused then C.host = { pid = answer.pid, pane = answer.pane } end
  return answer
end

-- Space Space in the pop-out: the editor's rows for the selected box (describe), in the menu kit the review uses, and
-- this window's own rows.
function M.client_home()
  local view = C.shown and C.views[C.shown]
  local msg = { type = 'describe' }
  if view then msg.view, msg.gen, msg.item = view.id, view.gen, C.surface.index end
  local answer = request(msg)
  if answer.refused then return say(answer.refused, WARN) end
  local items, here = {}, {}
  local function add(row, why, run)
    items[#items + 1] = { ident = row.id, name = row.name, label = row.name .. ' — ' .. tostring(row.about or ''):gsub('`', ''),
      group = tostring(row.group or 'more'):lower(), bind = run and row.key or nil, right = why, run = function()
        if why then return say(why, WARN) end
        if run then run() else client_act(row.id) end
      end }
  end
  for _, row in ipairs(type(answer.rows) == 'table' and answer.rows or {}) do
    if type(row) == 'table' and type(row.id) == 'string' and type(row.name) == 'string' then
      local mine = actions.get(row.id)
      local local_row = mine and vim.tbl_contains(list(mine.on), 'popout') and mine or nil
      here[row.id] = true
      add(row, row.available ~= true and tostring(row.available) or nil,
        local_row and function() local_row.run(actions.context(C.win)) end or nil)
    end
  end
  -- This window's own rows: not the editor's to give.
  for _, row in ipairs(actions.for_context(actions.context(C.win))) do
    if not here[row.id] and not row.remote and row.menu ~= false and vim.tbl_contains(list(row.on), 'popout') then
      add(row, nil, function() row.run(actions.context(C.win)) end)
    end
  end
  local box = C.surface.index and C.surface.drawn and C.surface.drawn.boxes[C.surface.index]
  require('desk.review').show_menu(items, { title = 'Home · pop-out' .. (box and box.name ~= '' and (' · ' .. box.name) or ''),
    anchor_win = C.win, memo = 'desk-popout-home' })
end

-- ? in the pop-out: its keys, from its rows.
function M.client_keys()
  local G = graphs()
  local said = G.glyphs(G.retro()).said
  local rows, wide = actions.keys('popout'), 0
  for _, row in ipairs(rows) do wide = math.max(wide, api.nvim_strwidth(M.shown_key(row.key))) end
  local lines, marks = {}, {}
  for _, row in ipairs(rows) do
    local key = M.shown_key(row.key)
    lines[#lines + 1] = '  ' .. key .. string.rep(' ', wide - api.nvim_strwidth(key)) .. '  ' .. said(row.name) .. '  '
    marks[#marks + 1] = { #lines, 2, 2 + #key }
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = '  ' .. typed('popout.focus') .. ' ' .. said('in the editor comes back here') .. '  '
  local w = 0
  for _, line in ipairs(lines) do w = math.max(w, api.nvim_strwidth(line)) end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].bufhidden = false, 'wipe'
  for _, m in ipairs(marks) do pcall(api.nvim_buf_set_extmark, buf, ns, m[1] - 1, m[2], { end_col = m[3], hl_group = 'DeskCallGraphKey' }) end
  local height = math.min(#lines, math.max(3, vim.o.lines - 4))
  local win = api.nvim_open_win(buf, true, { relative = 'editor', style = 'minimal', border = vim.g.desk_border or 'rounded',
    width = math.min(w, vim.o.columns - 2), height = height, row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - w) / 2)), title = ' ' .. said('pop-out keys') .. ' ', title_pos = 'center' })
  for _, lhs in ipairs({ 'q', '?', '<Esc>' }) do
    vim.keymap.set('n', lhs, function() pcall(api.nvim_win_close, win, true) end, { buffer = buf, nowait = true, silent = true })
  end
  return win
end

-- Started by the pop-out's argv: nvim --cmd 'let g:desk_popout=1' -c "lua require('desk.popout').client()" --
-- desk-popout:<the editor's socket>.
function M.client()
  if C.started then return end
  C.started = true
  vim.g.desk_popout = vim.g.desk_popout or 1
  vim.o.shadafile = 'NONE'   -- her history and marks are the editor's to keep
  local server
  for _, arg in ipairs(vim.fn.argv()) do server = server or arg:match('^desk%-popout:(/.+)$') end
  local first = api.nvim_get_current_buf()
  pcall(vim.cmd, 'silent! argdelete *')
  C.buf = api.nvim_create_buf(false, true)
  vim.bo[C.buf].bufhidden, vim.bo[C.buf].filetype = 'hide', 'deskpopout'
  C.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(C.win, C.buf)
  for opt, value in pairs({ number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0', wrap = false, list = false,
    spell = false, cursorline = false, colorcolumn = '' }) do
    pcall(function() vim.wo[C.win][opt] = value end)
  end
  -- The argument was a name, never a file: its buffer goes.
  if first ~= C.buf and api.nvim_buf_is_valid(first) and api.nvim_buf_get_name(first):find('desk-popout:', 1, true) then
    pcall(api.nvim_buf_delete, first, { force = true })
  end
  C.surface = { buf = C.buf, win = C.win }
  actions.map('popout', { buffer = C.buf, nowait = true, silent = true, ctx = { popout = C } })
  api.nvim_create_autocmd('CursorMoved', { buffer = C.buf, callback = function() graphs().follow_cursor(C.surface) end })
  draw(empty('connecting to the editor…'))
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
  draw(empty('nothing is shown here yet'))
  C.watch = uv.new_timer()
  C.watch:start(M.WATCH_MS, M.WATCH_MS, vim.schedule_wrap(function()
    if C.chan and next(api.nvim_get_chan_info(C.chan)) == nil then M.closing('Editor closed.') end
  end))
  local resized = uv.new_timer()
  api.nvim_create_autocmd('VimResized', { group = api.nvim_create_augroup('desk_popout_client', { clear = true }), callback = function()
    resized:stop()
    resized:start(100, 0, vim.schedule_wrap(function() if C.chan then M.subscribe() end end))
  end })
end

-- What the tests read of the pop-out.
function M.client_state()
  local view = C.shown and C.views[C.shown]
  local s = C.surface or {}
  local box = s.index and s.drawn and s.drawn.boxes[s.index]
  return { connected = C.chan ~= nil, host = C.host, shown = C.shown or '', gen = view and view.gen or 0, title = view and view.title or '',
    lines = C.buf and api.nvim_buf_is_valid(C.buf) and api.nvim_buf_get_lines(C.buf, 0, -1, false) or {}, index = s.index or 0,
    selected = box and box.name or '', closing = C.closing or '', win = C.win or 0, current_win = api.nvim_get_current_win(),
    mode = api.nvim_get_mode().mode, received = C.received or 0 }
end

-- ─── the keys ──────────────────────────────────────────────────────────────────────────────────────────────────
-- Rows of the action registry (desk/actions.lua): the mappings, which-key's words, the home menus in both windows, the
-- keybinds reference and the pop-out's ? read them. A remote row pressed in the pop-out asks the editor, which runs
-- `host` with the view and the box the pop-out had selected (ctx.view, ctx.item).
local ON = 'popout'
local function moving(how, key, name, about, line, doc)
  return { id = 'popout.' .. how, group = 'Call graph', name = name, about = about, key = key, on = ON, menu = false,
    line = line and ('popout.' .. line) or nil, doc = doc, run = function() graphs().move(C.surface, how) end }
end
local function remote(row, host)
  row.remote = true
  row.run = function(ctx)
    if M.is_popout() then return client_act(row.id) end
    return host(ctx)
  end
  return row
end
local function selected(ctx) return ctx.item ~= nil or 'no box is selected' end

local ROWS = actions.add({
  { id = 'popout.open', group = 'This function', name = 'Pop out the call graph', on = 'editor',
    about = 'The live call graph in the pop-out, a window of its own on the other screen: it follows the function under the cursor (p there pins it), and Enter there goes to a function here while the keyboard stays there',
    -- In a graph its own key sends it (popout.send).
    available = function(ctx) if ctx.surface == 'callgraph' or ctx.surface == 'callgraph-panel' then return false end; return can_pop() end,
    run = function(ctx) M.show_callgraph(ctx.win) end },
  { id = 'popout.focus', group = 'Pop-out', name = 'To the pop-out', key = '<leader><Tab>', on = 'editor',
    about = 'Put the keyboard in the pop-out window, on whichever screen it is; the same key there comes back here',
    available = function() return (H.chan ~= nil and not M.is_popout()) or false end,
    run = function()
      if M.is_popout() then return end
      if not H.chan then return tell('No pop-out is open. ' .. sentence("Space Space → 'Pop out the call graph' opens one"), WARN) end
      M.focus({ pid = H.pid })
    end },
  { id = 'popout.send', group = 'Call graph', name = 'Send this graph to the pop-out', key = 'o', on = { 'callgraph', 'callgraph-panel' },
    about = 'Move this graph to the pop-out on the other screen (opening it) and close it here; o there brings it back as a split',
    available = can_pop, run = function(ctx) M.detach(ctx.graph) end },
  moving('down', 'j', 'The box below', 'The box below, the nearest one in that row', nil, 'The box below / above (the nearest one in that row)'),
  moving('up', 'k', 'The box above', 'The box above, the nearest one in that row', 'down'),
  moving('left', 'h', 'The box to the left', 'The box to the left in the same row', nil, 'The box to the left / right in the same row'),
  moving('right', 'l', 'The box to the right', 'The box to the right in the same row', 'left'),
  moving('next', '<Tab>', 'The next box', 'The next box, every box in order, wrapping', nil, 'Every box in order, wrapping; the first / last box'),
  moving('prev', '<S-Tab>', 'The previous box', 'The previous box, wrapping', 'next'),
  moving('first', 'gg', 'The first box', 'The first box', 'next'),
  moving('last', 'G', 'The last box', 'The last box', 'next'),
  remote({ id = 'popout.go', group = 'Call graph', name = 'Go to it', key = '<CR>', on = ON, also = 'a double click',
    about = "Go to the selected box's function in the editor; the keyboard stays in the pop-out and the graph stays open",
    available = selected }, function(ctx) go(ctx, false) end),
  { id = 'popout.go-mouse', group = 'Call graph', name = 'Go to the box clicked', key = '<2-LeftMouse>', on = ON, line = 'popout.go',
    menu = false, doc = false,
    run = function()
      local s, pos = C.surface, vim.fn.getmousepos()
      if pos.winid == s.win and (pos.line or 0) > 0 then
        local index = graphs().box_at(s.drawn, pos.line, math.max(0, (pos.column or 1) - 1))
        if index then graphs().select(s, index, false) end
      end
      client_act('popout.go')
    end },
  remote({ id = 'popout.go-focus', group = 'Call graph', name = 'Go to it, in the editor', key = '<S-CR>', on = ON,
    about = "Go to the selected box's function and put the keyboard in the editor", available = selected },
    function(ctx) go(ctx, true) end),
  remote({ id = 'popout.centre', group = 'Call graph', name = 'Centre on it', key = 'c', on = ON,
    about = 'Centre the graph on the selected box: its own callers and callees (the graph is pinned there)',
    available = function(ctx)
      if not ctx.item then return 'no box is selected' end
      return ctx.item.raw ~= nil or 'this box is not from the language server yet'
    end }, centre),
  remote({ id = 'popout.pin', group = 'Call graph', name = 'Pin, or follow the editor', key = 'p', on = ON,
    about = "Pin the graph (PINNED: Enter visits its boxes one by one), or follow the editor's cursor again (each place Enter goes centres it)",
    available = function(ctx) return ctx.view ~= nil or 'nothing is shown here' end }, pin),
  remote({ id = 'popout.symdeps', group = 'Call graph', name = 'It in symdeps', key = 's', on = ON,
    about = "The selected box's function in symdeps' card, in the editor (C and C++; symdeps is an optional plugin)",
    available = function(ctx)
      if not ctx.item then return 'no box is selected' end
      if not actions.symdeps() then return 'requires symdeps' end
      local file = ctx.item.uri and vim.uri_to_fname(ctx.item.uri) or ''
      local ft = vim.filetype.match({ filename = file })
      return (ft == 'c' or ft == 'cpp') or 'requires a C or C++ function'
    end }, symdeps_card),
  remote({ id = 'popout.back', group = 'Call graph', name = 'Back to the editor', key = 'o', on = ON,
    about = 'Bring this graph back to the editor as the live panel, pinned if it is pinned here; the pop-out stays open',
    available = function(ctx) return ctx.view ~= nil or 'nothing is shown here' end }, function(ctx) M.attach(ctx.view) end),
  { id = 'popout.home', group = 'Home', name = 'Home menu', key = '<leader><leader>', on = ON, menu = false,
    about ='The home menu for the selected box: what the editor can do with it, and this window', run = function() M.client_home() end },
  { id = 'popout.keys', group = 'Pop-out', name = "The pop-out's keys", key = '?', on = ON, about = 'The keys of the pop-out, in a list',
    run = function() M.client_keys() end },
  { id = 'popout.swap', group = 'Pop-out', name = 'To the editor', key = '<leader><Tab>', on = ON,
    about = 'Put the keyboard in the editor; the same key there comes back here', run = function() M.focus(C.host) end },
  { id = 'popout.close', group = 'Pop-out', name = 'Close the pop-out', key = 'q', on = ON, remote = true,
    about = 'Close this window; the editor stops sending to it',
    run = function()
      if not M.is_popout() then return M.forget(nil) end
      if C.chan then pcall(client_act, 'popout.close') end
      C.closing = 'closed'
      vim.cmd('qa!')
    end },
})

local set = false
function M.setup()
  if set or M.is_popout() then return end
  set = true
  actions.map('editor', { rows = ROWS })
  api.nvim_create_user_command('PopOut', function() M.show_callgraph(api.nvim_get_current_win()) end,
    { desc = 'The live call graph in the pop-out window' })
  api.nvim_create_autocmd('VimLeavePre', { group = api.nvim_create_augroup('desk_popout', { clear = true }), callback = function()
    if H.chan then send({ type = 'bye', why = 'Editor closed.' }) end
  end })
end

return M
