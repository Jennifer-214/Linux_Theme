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
-- Protocol 2. The editor sends rpcnotify of M.receive, { version = 2, type, … }:
--   view.set   { id, gen, kind, surface, title, state, lines, marks, hl, items, footer, strip, select, front, news }
--   view.clear { id } · ping { serial } (every 10 s; one that stops answering is sent nothing until it does) · bye { why }
-- The pop-out asks through the editor's bridge (desk.bridge), every message with its deadline:
--   subscribe { chan, pid, width, protocol = 2 } · describe { view, gen, item } → { rows } ·
--   act { view, gen, item, action, text, choice } · pong { serial } · front { view, quiet } (the view in front there
--   now; quiet when it was not her own switch)
-- describe and act name the generation the pop-out drew: a view drawn again since is refused ("this view moved on").
-- The pop-out's keys for a view are its in-editor surface's drawn rows (run there, on its copy) and remote rows (run in
-- the editor, by act), beside its own rows (surface 'popout'); a row the editor keeps (remote = false) is not there.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
local actions = require('desk.actions')
local bridge = require('desk.bridge')

M.CLASS = 'desk-popout'
M.PROTOCOL = 2
M.PING_MS, M.WATCH_MS, M.LINGER_MS, M.GAP_MS, M.START_MS = 10000, 2000, 1500, 50, 15000
M.MAX_LINES, M.MAX_ITEMS = 2000, 500
-- The two doors: the editor's (desk.bridge, as desk-work uses it) and the pop-out's.
local HOST_DOOR = "return require('desk.bridge').receive(...)"
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
-- chan: the pop-out's channel once it subscribed; pid: its Neovim; kitty: the kitty it runs in; width: its window;
-- opening: a kitty on its way; views by id, and order: their ids in the order of the pop-out's tabs; front: the view in
-- front there; screen: the monitor it was placed on (prefer: the one a restore asks for); gen: the newest generation
-- sent; ping and heard: the pings sent and answered; stalled: not answering; history: the steps H, Backspace and L
-- walk; saved: the layout record last read or written; watch: the watch on desk-monitor's sidecar while it is open;
-- down: the editor is exiting and the pop-out was told.
local H = { views = {}, order = {}, gen = 0, ping = 0, heard = 0, width = 80, history = { steps = {}, at = 0 } }
M.host = H   -- the tests read it
local kinds = {}
M.kinds = kinds
M.MAX_STEPS = 50
local watch_screens, unwatch_screens

-- Neovim is exiting (v:exiting is set before any exit autocommand runs) or the pop-out was told: nothing of the
-- pop-out runs then but its goodbye. An error in a callback during the exit makes Neovim wait for a key before it
-- quits, which :restart shows as a stall.
function M.exiting() return H.down == true or vim.v.exiting ~= vim.NIL end
local exiting = M.exiting

local function host_pane()
  local term, pane = vim.env.TERM or '', vim.env.TMUX_PANE or ''
  return ((term:match('^tmux') or term:match('^screen')) and pane:match('^%%%d+$')) and pane or ''
end

local function send(msg)
  if not H.chan or H.stalled or exiting() then return false end
  msg.version = M.PROTOCOL
  local ok = pcall(vim.rpcnotify, H.chan, 'nvim_exec_lua', POPOUT_DOOR, { msg })
  if not ok then M.forget('The pop-out closed.', { back = true }) end
  return ok
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
-- each key spelled by the registry's one speller.
function M.key_pairs(footer)
  local out = {}
  for _, part in ipairs(footer or {}) do
    local keys = {}
    for _, id in ipairs(part.ids or {}) do
      local key = actions.key(id)
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
--                a surface row on one of them is left out there (actions.popout_rows)
--   render(view, width, style) → { title, state, lines, marks, hl, items, footer, strip, news }   pure: the view drawn
--                for the pop-out's width (style: vim.g.desk_style), with no keys and no state in its lines (the
--                header and the key line show them). state: following, PINNED, … (the header shows PINNED); marks:
--                { line, from, to, group, priority }; hl: the Desk* and FoxSymdeps* groups it draws with (their
--                definitions go along); items: { key (≤ 120: the same item keeps it from one drawing to the next),
--                kind = 'box' or 'row', line (where the cursor goes), name_col, x, w, spans = { { line, from, to } }
--                (at most 8), centre (selected first), name, strip = { two lines }, ref (stays here; ctx_for gets
--                it) }; footer: { { ids = { row ids }, words } }, its key line (four or five keys); strip: the first of
--                the two lines that show the selected item's strip; news: something new is in it (an answer, a
--                failure): its name in the header is marked until she looks (view.news, cleared once sent)
--   available(ctx) → true | why | false   may it open from ctx (ctx.remote: asked from the pop-out)        (optional)
--   open(view, ctx)        fills a view from where it was asked: the editor's ctx, a surface's with what it passed,
--                          or ctx.target (a function she named elsewhere: the notebook)
--   follow(view, event)    the editor moved: { type = 'moved' or 'unit', win } · { type = 'saved' or 'attached', buf } ·
--                          { type = 'pin' } (p flipped view.pinned). A kind with news of its own calls M.redraw(view)
--   ctx_for(view, ref, index) → ctx   what a remote row runs with for that item; ctx.view, ctx.item (the ref),
--                          ctx.index, ctx.remote and ctx.also are added to it; ctx.origin, when set, is the window
--                          its Enter moves (H takes the editor back there)
--   attach(view)           o in the pop-out, and each pinned view when the pop-out goes on its own: the view back in
--                          the editor as a split (it has left the pop-out)
--   close(view)            the view left the pop-out: stop what it runs (timers, requests)
--   save(view) → saved, restore(view, saved)   the view's state and back. The history keeps what save gives (any
--                          table); the layout record keeps saved.pinned and saved.target as JSON, and restore gets
--                          { pinned, target } back after a restart. A kind that changes what its view shows (the
--                          graph's c) calls M.stepped(view, before), before = save(view) from just before, so H undoes it
-- A view (M.host.views[name]) is the kind's own table; id, kind, gen and pinned are the host's, and gone once it has
-- left the pop-out. select = an item's key and front = true go with the next M.redraw, once: the pop-out selects that
-- item, and shows that view.
local SPEC = { name = 'string', title = 'string', about = 'string', menu = 'string', surface = 'string', render = 'function',
  available = 'function', open = 'function', follow = 'function', ctx_for = 'function', attach = 'function', close = 'function',
  save = 'function', restore = 'function' }
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

-- A view as the pop-out draws it, from its kind: the message, and its items' refs and keys (kept here).
local function cut(value, cap) return type(value) == 'string' and value:sub(1, cap) or nil end
local function payload(view)
  local kind = kinds[view.kind]
  local ok, drawn = pcall(kind.render, view, H.width or 80, vim.g.desk_style or 'paper')
  if not ok or type(drawn) ~= 'table' or type(drawn.lines) ~= 'table' then
    drawn = { lines = { '', '  This view could not be drawn: ' .. (tostring(ok and 'it gave no lines' or drawn):gsub('\n.*', '')):sub(1, 200) } }
  end
  local lines, marks = {}, type(drawn.marks) == 'table' and drawn.marks or {}
  for i, line in ipairs(drawn.lines) do lines[i] = tostring(line) end
  if #lines > M.MAX_LINES then
    local more = #lines - (M.MAX_LINES - 1)
    lines = vim.list_slice(lines, 1, M.MAX_LINES - 1)
    lines[#lines + 1] = '… ' .. more .. ' more lines'
    marks = vim.tbl_filter(function(m) return type(m) == 'table' and type(m[1]) == 'number' and m[1] < M.MAX_LINES end, marks)
  end
  local items, refs, keys = {}, {}, {}
  for i, item in ipairs(type(drawn.items) == 'table' and drawn.items or {}) do
    if i > M.MAX_ITEMS then break end
    refs[i], keys[i] = item.ref, tostring(item.key or i):sub(1, 120)
    items[i] = { key = keys[i], kind = item.kind == 'row' and 'row' or 'box', line = item.line, name_col = item.name_col, x = item.x,
      w = item.w, spans = item.spans, centre = item.centre == true, name = tostring(item.name or ''):sub(1, 200), mark = cut(item.mark, 16),
      strip = type(item.strip) == 'table' and { cut(item.strip[1], 400) or '', cut(item.strip[2], 400) or '' } or nil }
  end
  return { type = 'view.set', id = view.id, kind = view.kind, surface = kind.surface, title = cut(drawn.title, 200) or kind.title,
    state = cut(drawn.state, 200) or '', lines = lines, marks = marks, hl = definitions(drawn.hl), items = items,
    footer = type(drawn.footer) == 'table' and drawn.footer or {}, strip = type(drawn.strip) == 'number' and drawn.strip or nil,
    news = drawn.news == true }, refs, keys
end

-- Sends a view as it is now, one per view every M.GAP_MS at most (the last state wins). A new generation only when its
-- lines or its items changed: the same drawing sent again (it answers again, a resize to the same width) keeps the
-- items it named.
function M.redraw(view)
  if not view or view.gone or H.views[view.id] ~= view or not H.chan or H.stalled or exiting() then return end
  local wait = (view.sent or -M.GAP_MS) + M.GAP_MS - uv.now()
  if wait > 0 then
    if not view.queued then
      view.queued = true
      vim.defer_fn(function() view.queued = false; M.redraw(view) end, wait)
    end
    return
  end
  view.sent = uv.now()
  local msg, refs, keys = payload(view)
  local drawing = table.concat(msg.lines, '\n') .. '\0' .. table.concat(keys, '\1')
  if drawing ~= view.drawing then
    H.gen = H.gen + 1
    view.gen, view.drawing = H.gen, drawing
  end
  view.refs, view.count = refs, #msg.items
  msg.gen, msg.select, msg.front = view.gen, view.select, view.front == true
  if send(msg) then view.select, view.front, view.news = nil, nil, nil end
end
-- Every view sent again in the order of the pop-out's tabs (a pop-out makes a view's tab when it first arrives, so
-- this order is the tabs' order), then the one in front once more to bring it forward (a moment later: one send per
-- view every M.GAP_MS).
local function redraw_all()
  local front = H.front and H.views[H.front]
  for _, id in ipairs(H.order) do
    local view = H.views[id]
    if view then view.sent = nil; M.redraw(view) end
  end
  if front then front.front = true; M.redraw(front) end
end

-- ─── the editor moving, for the views that follow it ───────────────────────────────────────────────────────────
-- One set of autocommands while any view is out, each event given to every view's kind (follow).
local function kind_failed(view, err)
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
  for _, view in pairs(H.views) do follow_one(view, event) end
end
local function follow_start()
  local group = api.nvim_create_augroup('desk_popout_follow', { clear = true })
  api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter', 'InsertLeave' }, { group = group,
    callback = function() dispatch({ type = 'moved', win = api.nvim_get_current_win() }) end })
  -- symdeps' follow card moves on FoxUnitChanged, at once: a following view moves with it.
  api.nvim_create_autocmd('User', { group = group, pattern = 'FoxUnitChanged',
    callback = function() dispatch({ type = 'unit', win = api.nvim_get_current_win() }) end })
  api.nvim_create_autocmd('BufWritePost', { group = group, callback = function(a) dispatch({ type = 'saved', buf = a.buf }) end })
  api.nvim_create_autocmd('LspAttach', { group = group, callback = function(a) dispatch({ type = 'attached', buf = a.buf }) end })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = function() if not exiting() then redraw_all() end end })
end
local function follow_stop() pcall(api.nvim_del_augroup_by_name, 'desk_popout_follow') end

local function leave(view)
  view.gone = true
  local kind = kinds[view.kind]
  if kind and kind.close then
    local ok, err = pcall(kind.close, view)
    if not ok then kind_failed(view, err) end
  end
end
local function unlist(id) for i, other in ipairs(H.order) do if other == id then table.remove(H.order, i); return end end end

-- Takes a view off the pop-out (it goes back to the editor, or she closed it there).
function M.clear(id)
  local view = H.views[id]
  if not view then return end
  H.views[id] = nil
  unlist(id)
  if H.front == id then H.front = nil end
  leave(view)
  if next(H.views) == nil then follow_stop() end
  send({ type = 'view.clear', id = id })
end

-- The pop-out is gone: nothing more is sent and nothing follows the cursor for it. opts.back: it went on its own (it
-- closed or crashed, or its screen was unplugged): its pinned views come back to the editor as splits (their kind's
-- attach), the following ones stop, and one notice says so; opts.all: it never showed them (it did not start), so
-- every view comes back. Her q on its last view brings nothing back.
function M.forget(why, opts)
  opts = opts or {}
  -- A write of the views still on its way is written now, while they are here: a fold right after a change keeps them.
  M.flush_layout()
  local had = H.chan ~= nil or next(H.views) ~= nil
  H.chan, H.pid, H.kitty, H.stalled, H.opening, H.front, H.screen, H.prefer = nil, nil, nil, false, nil, nil, nil, nil
  if H.timer then H.timer:stop() end
  unwatch_screens()
  local views, order = H.views, H.order
  H.views, H.order, H.history = {}, {}, { steps = {}, at = 0 }
  local back = {}
  for _, id in ipairs(order) do
    local view = views[id]
    if view then
      leave(view)
      local kind = kinds[view.kind]
      if (opts.all or (opts.back and view.pinned)) and kind and kind.attach then back[#back + 1] = view end
    end
  end
  follow_stop()
  for _, view in ipairs(back) do
    local ok, err = pcall(kinds[view.kind].attach, view)
    if not ok then tell(sentence('it could not come back: ' .. tostring(err):sub(1, 200)), WARN) end
  end
  if had and why then
    local its = opts.all and ' Its' or ' Its pinned'
    tell(why .. (#back == 0 and '' or #back == 1 and (its .. ' view is back here.') or (its .. ' views are back here.')),
      opts.all and WARN or nil)
  end
end

local function start_pings()
  H.timer = H.timer or uv.new_timer()
  H.timer:stop()
  H.timer:start(M.PING_MS, M.PING_MS, vim.schedule_wrap(function()
    if exiting() then return end
    if not H.chan then return H.timer:stop() end
    if next(api.nvim_get_chan_info(H.chan)) == nil then return M.forget('The pop-out closed.', { back = true }) end
    if H.ping > H.heard and not H.stalled then
      H.stalled = true
      tell('The pop-out stopped answering; nothing more is sent to it until it does.', WARN)
    end
    H.ping = H.ping + 1
    pcall(vim.rpcnotify, H.chan, 'nvim_exec_lua', POPOUT_DOOR, { { version = M.PROTOCOL, type = 'ping', serial = H.ping } })
  end))
end

-- The pop-out window appears floating at the side of the screen it opens on (the Hyprland rule, which also keeps the
-- focus here). Then it moves, tiled, to the workspace showing on `screen` ({ name, workspace }; by default the screen
-- M.target_screen picks, a restore's screen first), and H.screen says which. pid: its kitty's.
function M.place(pid, screen)
  if type(pid) ~= 'number' or not have('hyprctl') then return end
  hyprctl({ 'monitors' }, function(monitors)
    screen = screen or M.target_screen(monitors, M.screens(), H.prefer)
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
        H.screen = screen.name
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

-- kitty's exit is the pop-out's end. One that never subscribed did not start: every view it was to show comes back here
-- (none was seen there). One that did is gone: its pinned views come back, as when it crashed.
local function kitty_exited(opening)
  if exiting() then return end
  if H.opening == opening then return M.forget('The pop-out did not start.', { all = true }) end
  if H.kitty == opening.pid then M.forget('The pop-out closed.', { back = true }) end
end

-- Opens the pop-out when none is attached or on its way. true, or false and why.
function M.open()
  -- One whose channel is already gone (its window closed a moment ago) is forgotten first, so a new one opens.
  if H.chan and next(api.nvim_get_chan_info(H.chan)) == nil then M.forget('The pop-out closed.', { back = true }) end
  if H.chan or H.opening then return true end
  local server = vim.v.servername or ''
  if #server > 107 or not server:match('^/[%w%._/%-]+$') then return false, 'this editor has no socket the pop-out can reach' end
  if not have('kitty') then return false, 'requires kitty' end
  -- The socket travels in argv only. The pop-out's Neovim gets none of this editor's tmux (its footer is this
  -- editor's) and no $NVIM (it is not a terminal inside this editor). NVIM_NOTTYFAST: it asks the new kitty nothing at
  -- start (its theme is set, not detected), so no E1568 when the terminal is slow to answer.
  local argv = { 'kitty', '--class', M.CLASS, '-e', 'nvim', '--cmd', 'let g:desk_popout=1', '-c', "lua require('desk.popout').client()",
    '--', 'desk-popout:' .. server }
  local opening = {}
  local env = { TMUX = '', TMUX_PANE = '', NVIM = '', NVIM_NOTTYFAST = '1' }
  local ok, job = pcall(vim.system, argv, { text = true, detach = true, env = env }, function()
    vim.schedule(function() kitty_exited(opening) end)
  end)
  if not ok then return false, 'kitty did not start (' .. tostring(job):sub(1, 120) .. ')' end
  opening.pid = job.pid
  H.opening, H.kitty = opening, job.pid
  M.place(job.pid)
  vim.defer_fn(function()
    if H.opening == opening and not exiting() then M.forget('The pop-out did not start.', { all = true }) end
  end, M.START_MS)
  return true
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

-- ─── history: H and Backspace go back, L forward ───────────────────────────────────────────────────────────────
-- Steps, each undone by H or Backspace and done again by L: a switch between views; an Enter (the code spot the editor
-- was at, and the view's state from before for a kind that keeps one: one step, so one H puts back both the file the
-- review showed and the spot); a view's content changing (its kind's save from before: a graph centred on another
-- function). What L brings back is what H left (taken when H undoes it), so a graph still being read when it was
-- centred comes back read. At most M.MAX_STEPS; a new step drops the ones ahead of it.
local function push_step(step)
  local h = H.history
  for i = #h.steps, h.at + 1, -1 do h.steps[i] = nil end
  h.steps[#h.steps + 1] = step
  while #h.steps > M.MAX_STEPS do table.remove(h.steps, 1) end
  h.at = #h.steps
end

-- A kind changed what its view shows (before: its save from just before): a step H can undo.
-- During an Enter in that view (H.folding) the change is part of the Enter's own step, which keeps the view's state from
-- before it: one H undoes both.
function M.stepped(view, before)
  local kind = view and kinds[view.kind]
  if not (kind and kind.save and kind.restore) or view.gone or H.views[view.id] ~= view or type(before) ~= 'table' then return end
  if H.folding == view.id then return end
  push_step({ type = 'state', view = view.id, before = before })
end

local function to_front(view)
  H.front = view.id
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
local function apply(step, again)
  if step.type == 'switch' then
    local view = H.views[again and step.to or step.from]
    if not view then return false end
    to_front(view)
  elseif step.type == 'enter' then
    -- The view's state first (it may show another file in the editor), then the editor's exact spot.
    local view = H.views[step.view]
    local kind = view and kinds[view.kind]
    if not again then
      step.after = main_spot(step.before.win)
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
    if not put_spot(again and step.after or step.before) and not saved then return false end
    if view and (saved or H.front ~= view.id) then to_front(view) end
  elseif step.type == 'state' then
    local view = H.views[step.view]
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

function M.history_back()
  local h = H.history
  while h.at >= 1 do
    local step = h.steps[h.at]
    h.at = h.at - 1
    if apply(step, false) then return true end
  end
  tell('Nothing further back.')
  return false
end
function M.history_forward()
  local h = H.history
  while h.at < #h.steps do
    h.at = h.at + 1
    if apply(h.steps[h.at], true) then return true end
  end
  tell('Nothing further forward.')
  return false
end

-- ─── the layout record: the pop-out's views in desk-work, offered again after a restart ────────────────────────
-- desk-work workspace --client popout, per checkout: { version, tabs = { { kind, pinned, target } }, activeTab = the
-- view in front, show = { screen } } (keys its allow-list has). Written when a view opens, closes, is pinned or centred,
-- and when the editor exits; read at start, so the Views group offers "Restore 2 views". The selection inside a view is
-- not kept: a restored graph selects its centre.
local RESTORE   -- its row, named for what the record holds
local function layout_root()
  local name = api.nvim_buf_get_name(0)
  local root = vim.fs.root(name ~= '' and name or vim.fn.getcwd(), '.git') or vim.fn.getcwd()
  return uv.fs_realpath(root) or root
end
local function restore_named()
  if not RESTORE then return end
  local n = H.saved and type(H.saved.tabs) == 'table' and #H.saved.tabs or 0
  RESTORE.name = n == 0 and "Restore the pop-out's views" or n == 1 and 'Restore 1 view' or ('Restore %d views'):format(n)
end
local function layout_record()
  local tabs = {}
  for _, id in ipairs(H.order) do
    local view = H.views[id]
    local kind = view and kinds[view.kind]
    if kind and kind.save then
      local ok, saved = pcall(kind.save, view)
      if ok and type(saved) == 'table' then
        tabs[#tabs + 1] = { kind = view.kind, pinned = view.pinned == true, target = type(saved.target) == 'table' and saved.target or nil }
      end
    end
  end
  return { version = 1, tabs = tabs, activeTab = H.front, show = { screen = H.screen } }
end
local function write_layout(wait)
  local record = layout_record()
  local ok, json = pcall(vim.json.encode, record)
  if not ok then return end
  H.saved = record
  restore_named()
  local argv = { 'desk-work', 'workspace', '--root', layout_root(), '--client', 'popout', '--input', '-' }
  local started, job = pcall(vim.system, argv, { stdin = json, text = true, timeout = 5000 }, (not wait) and function() end or nil)
  if started and wait then pcall(job.wait, job, 1000) end
end
-- The writes of a moment (a view closing, then the one in front changing) go as one, M.SAVE_MS after the last. wait:
-- the editor is exiting, so the record is written now, before it goes (a second at most).
M.SAVE_MS = 300
-- The write still on its way, now (nothing when none is).
function M.flush_layout()
  if H.save_timer and H.save_timer:is_active() then
    H.save_timer:stop()
    write_layout(false)
  end
end
function M.save_layout(wait)
  if M.is_popout() or vim.g.desk_work_view or not have('desk-work') then return end
  H.save_timer = H.save_timer or uv.new_timer()
  H.save_timer:stop()
  if wait then return write_layout(true) end
  H.save_timer:start(M.SAVE_MS, 0, vim.schedule_wrap(function() if not exiting() then write_layout(false) end end))
end
function M.read_layout(done)
  done = done or function() end
  if M.is_popout() or vim.g.desk_work_view or not have('desk-work') then return done(nil) end
  local ok = pcall(vim.system, { 'desk-work', 'workspace', '--root', layout_root(), '--client', 'popout' }, { text = true, timeout = 5000 },
    vim.schedule_wrap(function(out)
      local decoded, record = pcall(vim.json.decode, out.code == 0 and out.stdout or '')
      H.saved = decoded and type(record) == 'table' and type(record.tabs) == 'table' and record or nil
      restore_named()
      done(H.saved)
    end))
  if not ok then done(nil) end
end

-- ─── views in and out ──────────────────────────────────────────────────────────────────────────────────────────
local function add_view(name)
  local view = { id = name, kind = name, gen = 0, pinned = false }
  H.views[name] = view
  H.order[#H.order + 1] = name
  follow_start()
  return view
end

-- A view of kind `name` in the pop-out, opening the window when it is not open. A new view is filled by its kind from
-- ctx; asked for again from the editor (o in another graph, its Views row) it is filled again from there; asked for
-- from the pop-out (ctx.remote) it only comes to the front. Either way, from another view, it is a step H undoes.
function M.show(name, ctx)
  local kind = kinds[name]
  if not kind then return tell('No view is called ' .. tostring(name) .. '.', WARN) end
  if refused_here(M.can_pop()) then return end
  local ok, why = M.open()
  if not ok then return tell(sentence(why), WARN) end
  ctx = ctx or actions.context()
  local view, before = H.views[name], H.front
  if not (view and ctx.remote) then
    view = view or add_view(name)
    if kind.open then
      local fine, err = pcall(kind.open, view, ctx)
      if not fine then kind_failed(view, err) end
    end
  end
  if before and before ~= view.id and H.views[before] then push_step({ type = 'switch', from = before, to = view.id }) end
  to_front(view)
  M.save_layout()
end

-- The pop-out's last views again (after a restart): it opens, on the screen it was on when that is there, with each
-- saved view its kind fills again from what was kept, and the one in front then in front.
function M.restore_layout()
  local record = H.saved
  if not (record and type(record.tabs) == 'table' and #record.tabs > 0) then return tell('No views of the pop-out were saved here.') end
  if refused_here(M.can_pop()) then return end
  H.prefer = type(record.show) == 'table' and type(record.show.screen) == 'string' and record.show.screen or nil
  local ok, why = M.open()
  if not ok then return tell(sentence(why), WARN) end
  for _, saved in ipairs(record.tabs) do
    local kind = type(saved) == 'table' and kinds[saved.kind]
    if kind and kind.restore and not H.views[saved.kind] then
      local view = add_view(saved.kind)
      view.pinned = saved.pinned == true
      local fine, err = pcall(kind.restore, view, { pinned = view.pinned, target = type(saved.target) == 'table' and saved.target or nil })
      if not fine then kind_failed(view, err) end
      to_front(view)
    end
  end
  local active = type(record.activeTab) == 'string' and H.views[record.activeTab]
  if active then to_front(active) end
end

-- o in the pop-out: the view leaves it, and its kind puts it back in the editor.
function M.back(view)
  local kind = view and kinds[view.kind]
  if not kind then return end
  M.clear(view.id)
  if kind.attach then
    local ok, err = pcall(kind.attach, view)
    if not ok then tell(sentence('it could not come back: ' .. tostring(err):sub(1, 200)), WARN) end
  end
  M.save_layout()
end

-- p in the pop-out: pinned, a view stays as it is while the editor moves; unpinned, its kind follows the editor again.
function M.pin(view)
  if not view then return end
  view.pinned = not view.pinned
  follow_one(view, { type = 'pin' })
  M.redraw(view)
  M.save_layout()
end

-- ─── its screen unplugged ──────────────────────────────────────────────────────────────────────────────────────
-- desk-monitor rewrites its sidecar on every hotplug (desk-pulse runs its reconcile). When the screen the pop-out was
-- placed on is no longer among Hyprland's monitors, the pop-out moves to another screen that is not the editor's, when
-- one is left; else it closes and its pinned views come back here as splits (one screen: no pop-out, as when it would
-- not open). Hyprland itself would only park it on a workspace nobody sees.
function M.screens_changed()
  if exiting() or not (H.chan and H.screen) then return end
  hyprctl({ 'monitors' }, function(monitors)
    if not (H.chan and H.screen) or type(monitors) ~= 'table' then return end
    for _, m in ipairs(monitors) do
      if type(m) == 'table' and m.name == H.screen and not m.disabled then return end
    end
    local gone, screen = H.screen, M.target_screen(monitors, M.screens())
    if screen and H.kitty then
      M.place(H.kitty, screen)
      return tell(('The pop-out moved to %s: %s was unplugged.'):format(screen.name, gone))
    end
    M.fold(gone .. ' was unplugged')
  end)
end
-- The pop-out closes, its pinned views back here as splits; why: the one notice.
function M.fold(why)
  local chan = H.chan
  send({ type = 'bye', why = sentence(why) })
  M.forget(sentence(why), { back = true })
  if chan then pcall(vim.fn.chanclose, chan) end
end
watch_screens = function()
  if H.watch then return end
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
  H.watch = { watcher = watcher, timer = timer }
end
unwatch_screens = function()
  local w = H.watch
  if not w then return end
  H.watch = nil
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

-- The view, generation and item an ask names, as a ctx for the action registry: its kind's ctx_for (the view's
-- surface, and what that surface's rows read), with ctx.view, ctx.item (the item's ref), ctx.index, ctx.remote and the
-- window's own surface (ctx.also). A view drawn again since refuses: its items are not the ones the pop-out saw.
local function remote_ctx(msg)
  if exiting() then return nil, 'this editor is closing' end
  if not H.chan then return nil, 'no pop-out is subscribed to this editor' end
  local view, ref
  if msg.view ~= nil then
    view = H.views[msg.view]
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
    local ok, made = pcall(kind.ctx_for, view, ref, msg.item)
    if not ok or type(made) ~= 'table' then return nil, "can't tell what is selected there: " .. tostring(made):sub(1, 160) end
    ctx = made
  else
    ctx = actions.context(api.nvim_get_current_win())
    ctx.surface = kind and kind.surface or ON
  end
  ctx.view, ctx.item, ctx.index, ctx.remote, ctx.also = view, ref, msg.item, true, { ON }
  return ctx
end

-- Every message from the pop-out says when it stops waiting, so a late one is refused (desk.bridge) rather than run.
local function timed(handler)
  return function(msg)
    if type(msg.deadline) ~= 'number' then return refuse('a pop-out message says when it stops waiting (deadline)') end
    return handler(msg)
  end
end

-- subscribe { chan, pid, width, protocol }: chan is the pop-out's channel here (nvim_get_api_info gave it the number),
-- labelled with its pid through nvim_set_client_info, since code run by nvim_exec_lua cannot tell which channel called.
-- Again from the same channel (a resize): the new width, every view drawn again.
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
  if H.chan and H.chan ~= msg.chan then send({ type = 'bye', why = 'Another pop-out took over.' }) end
  local again = H.chan == msg.chan
  H.chan, H.pid, H.width, H.opening = msg.chan, msg.pid, msg.width or H.width, nil
  -- The kitty whose exit ends it is the one it runs in (one this editor did not start has none watched: the pings find
  -- it gone).
  if H.kitty and not vim.tbl_contains(M.lineage(msg.pid), H.kitty) then H.kitty = nil end
  if not again then
    H.stalled, H.ping, H.heard = false, 0, 0
    start_pings()
    watch_screens()
  end
  vim.schedule(redraw_all)
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
-- H undoes: the code spot the editor was at, and the one it went to.
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
  vim.schedule(function()
    local view = ctx.view
    local before = entering and main_spot(ctx.origin) or nil
    -- One step for the Enter: where the editor was and, for a kind that keeps its state, what the view was. A step the
    -- kind takes of its own for it (while it runs, or scheduled from it) is folded into this one.
    local saved
    if entering and kind.save and kind.restore then
      local fine, state = pcall(kind.save, view)
      saved = fine and type(state) == 'table' and state or nil
    end
    if entering then H.folding = view.id end
    local ok, err = actions.act(msg.action, ctx)
    if not ok then
      H.folding = nil
      return tell(sentence(err or (msg.action .. ' did not run')), WARN)
    end
    if before then push_step({ type = 'enter', view = view.id, before = before, saved = saved }) end
    if entering then vim.schedule(function() if H.folding == view.id then H.folding = nil end end) end
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
    vim.schedule(redraw_all)
  end
  return { heard = true }
end

-- front { view, quiet }: another view is in front in the pop-out. Her own switch there (gt, a click on its tab) is a
-- step H undoes; quiet: it came of something else (the editor showed it, a view closed), only noted.
local function front(msg)
  if not H.chan or exiting() then return { heard = false } end
  local view = H.views[msg.view]
  if not view then return { heard = false } end
  if not msg.quiet and H.front and H.front ~= view.id and H.views[H.front] then push_step({ type = 'switch', from = H.front, to = view.id }) end
  if H.front ~= view.id then
    H.front = view.id
    M.save_layout()
  end
  return { heard = true }
end

local ID, NUMBER = bridge.field('string', 32), bridge.field('integer', 2147483647)
bridge.register('subscribe', timed(subscribe), { chan = bridge.field('integer', 2147483647, true),
  pid = bridge.field('integer', 2147483647, true), width = bridge.field('integer', 1000), protocol = bridge.field('integer', 1000, true) })
bridge.register('describe', timed(describe), { view = ID, gen = NUMBER, item = bridge.field('integer', M.MAX_ITEMS) })
bridge.register('act', timed(act), { view = ID, gen = NUMBER, item = bridge.field('integer', M.MAX_ITEMS),
  action = bridge.field('string', 64, true), text = bridge.field('string', 2000), choice = bridge.field('string', 64) })
bridge.register('pong', pong, { serial = bridge.field('integer', 2147483647, true) })
bridge.register('front', timed(front), { view = bridge.field('string', 32, true), quiet = bridge.field('boolean') })

-- ─── the pop-out's side ────────────────────────────────────────────────────────────────────────────────────────
-- chan: to the editor; me: that channel's number there; host: { pid, pane } of the editor; views by id, each in a
-- buffer and a tab page of its own (view.win: its window); empty: the buffer that says nothing is shown, in the one tab
-- left when there is no view; shown: the view in front (nil: none); switching: a tab change of this module's own.
local C = { views = {} }
local ns = api.nvim_create_namespace('desk_popout')

local function say(text, level) vim.notify(sentence(text), level or vim.log.levels.INFO, { title = 'Pop-out' }) end
local function width() return api.nvim_win_get_width(0) end
local function shown() return C.shown and C.views[C.shown] or nil end
local function escape(s) return (tostring(s):gsub('%%', '%%%%')) end

local function request(msg, budget)
  if not C.chan then return refuse('the pop-out is not connected to an editor') end
  msg.version, msg.deadline = 1, now_ms() + (budget or 2000)
  local ok, answer = pcall(vim.rpcrequest, C.chan, 'nvim_exec_lua', HOST_DOOR, { msg })
  if not ok then return refuse('the editor did not answer (' .. (tostring(answer):gsub('\n.*', '')):sub(1, 160) .. ')') end
  return type(answer) == 'table' and answer or refuse('the editor gave no answer')
end

-- What an ask names: a view (the one shown), the generation drawn here and its selected item.
local function naming(msg, view, index)
  view = view or shown()
  if view then msg.view, msg.gen, msg.item = view.id, view.gen, index or view.copy.index end
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
  pcall(vim.rpcnotify, C.chan, 'nvim_exec_lua', HOST_DOOR, { { version = 1, type = 'front', view = view.id, quiet = quiet == true,
    deadline = now_ms() + 2000 } })
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
  actions.ask({ prompt = type(input.prompt) == 'string' and input.prompt or nil, choices = type(input.choices) == 'table' and input.choices or nil },
    actions.context(), function(text, choice)
      local now = key and view and index_of(view, key)
      if view and (shown() ~= view or (key and not now)) then return say('what it was about is no longer shown', WARN) end
      client_act(row.id, { text = text, choice = choice }, view, now)
    end, type(offered.name) == 'string' and offered.name or row.name)
end

-- A key of a view pressed here: a row the editor runs (remote, and not the window's own) goes there, asking first when
-- it has an input; any other runs here (a drawn row on the view's copy, the window's own rows).
local function press(row, ctx)
  if row.remote and not is_on(row, ON) then
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
local function strip(view)
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
local function keyline(view)
  local said, parts = actions.voice(graphs().retro()), {}
  for _, pair in ipairs(M.key_pairs(view.footer or {})) do
    parts[#parts + 1] = '%#DeskPopoutKey#' .. escape(pair[1]) .. '%#DeskPopoutWords# ' .. escape(said(pair[2]))
  end
  return '%#DeskPopoutWords# ' .. table.concat(parts, '%#DeskPopoutWords# · ') .. '%#DeskPopoutWords# '
end
local function set_keyline(view)
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
  for _, view in pairs(C.views) do if tab_of(view) == tab then return view end end
end

-- The header: each view by its tab number and kind, PINNED, ✱ when something new is in it, the one in front in the
-- selection colour; then the keys that switch views and open the menu. Retro: capitals, │ between views, * for new.
local function tabline()
  local retro = graphs().retro()
  local said, current, out = actions.voice(retro), api.nvim_get_current_tabpage(), {}
  for n, tab in ipairs(api.nvim_list_tabpages()) do
    local view = view_in_tab(tab)
    local text = ' ' .. n .. ' ' .. said(view and (view.kind ~= '' and view.kind or view.id) or 'pop-out')
    if view and view.state == 'PINNED' then text = text .. (retro and '·' or ' · ') .. 'PINNED' end
    if view and view.news then text = text .. ' ' .. (retro and '*' or '✱') end
    out[#out + 1] = '%' .. n .. 'T' .. (tab == current and '%#DeskPopoutTabSel#' or '%#DeskPopoutTab#') .. escape(text .. ' ')
  end
  local right = ' ' .. typed('popout.next-view') .. ' ' .. said('views') .. ' · ' .. typed('popout.home') .. ' ' .. said('menu') .. ' '
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

-- A view's buffer and its keys: the drawn and remote rows of its surface and the window's own (actions.popout_rows),
-- the module that adds that surface's rows loaded first. Its copy is the selection a drawn row moves (ctx.copy).
local function client_view(id, surface)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'hide', 'deskpopout'
  local view = { id = id, buf = buf, gen = 0, kind = '', title = id, state = '', lines = {}, marks = {}, hl = {}, items = {}, footer = {} }
  view.copy = { buf = buf, view = view }
  if surface and actions.MODULES[surface] then pcall(require, actions.MODULES[surface]) end
  view.rows = actions.popout_rows(surface)
  for _, row in ipairs(view.rows) do if row.remote and row.key and row.key:lower() == '<cr>' and not is_on(row, ON) then view.enter = row end end
  actions.map(ON, { buffer = buf, rows = view.rows, every = true, nowait = true, silent = true, press = press,
    ctx = { copy = view.copy, also = surface and { surface } or nil } })
  api.nvim_create_autocmd('CursorMoved', { buffer = buf, callback = function() moved(view) end })
  return view
end

-- Puts a view in a tab page of its own (the empty one's when nothing else has it), its window dressed and its key
-- line set.
local function place(view)
  if tab_of(view) then return end
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
  C.switching = false
  view.copy.win = view.win
  dress(view.win)
  set_keyline(view)
end

-- Puts a view in front (its tab), the cursor on its selection.
local function show(view)
  place(view)
  local tab = tab_of(view)
  if tab and tab ~= api.nvim_get_current_tabpage() then
    C.switching = true
    pcall(api.nvim_set_current_tabpage, tab)
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
local function valid_items(raw)
  local items = {}
  for i, item in ipairs(type(raw) == 'table' and raw or {}) do
    if i > M.MAX_ITEMS or type(item) ~= 'table' or type(item.key) ~= 'string' or #item.key > 120 or type(item.line) ~= 'number'
      or not valid_spans(item.spans) then break end
    local lines = type(item.strip) == 'table' and item.strip or {}
    items[i] = { key = item.key, kind = item.kind == 'row' and 'row' or 'box', line = item.line, name_col = tonumber(item.name_col) or 0,
      x = tonumber(item.x) or 0, w = tonumber(item.w) or 1, spans = item.spans, centre = item.centre == true,
      name = type(item.name) == 'string' and item.name:sub(1, 200) or '', mark = short(item.mark, 16),
      strip = type(lines[1]) == 'string' and type(lines[2]) == 'string' and { lines[1]:sub(1, 400), lines[2]:sub(1, 400) } or nil }
  end
  return items
end
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
-- A view.set, checked: whatever does not fit is left out, never drawn half.
local function valid_view(msg)
  if type(msg.id) ~= 'string' or #msg.id > 32 or not msg.id:match('^[%w_.-]+$') or type(msg.gen) ~= 'number' then return nil end
  if type(msg.lines) ~= 'table' or #msg.lines > M.MAX_LINES then return nil end
  local lines, marks, hl = {}, {}, {}
  for i, line in ipairs(msg.lines) do
    if type(line) ~= 'string' then return nil end
    lines[i] = line:gsub('[\r\n]', ' ')
  end
  for _, m in ipairs(type(msg.marks) == 'table' and msg.marks or {}) do
    if #marks < 20000 and type(m) == 'table' and type(m[1]) == 'number' and type(m[2]) == 'number' and type(m[3]) == 'number'
      and type(m[4]) == 'string' and m[4]:match('^[%w_]+$') then marks[#marks + 1] = m end
  end
  for name, def in pairs(type(msg.hl) == 'table' and msg.hl or {}) do
    if drawable(name) then hl[name] = clean_hl(def) end
  end
  local kind = short(msg.kind, 32)
  return { id = msg.id, gen = msg.gen, kind = kind and kind:match('^[%w_.-]+$') and kind or '',
    surface = type(msg.surface) == 'string' and actions.SURFACES[msg.surface] and msg.surface or nil,
    title = type(msg.title) == 'string' and msg.title:sub(1, 200) or msg.id, state = type(msg.state) == 'string' and msg.state:sub(1, 200) or '',
    lines = lines, marks = marks, hl = hl, items = valid_items(msg.items), footer = valid_footer(msg.footer),
    strip = type(msg.strip) == 'number' and msg.strip >= 1 and msg.strip < #lines and math.floor(msg.strip) or nil,
    select = short(msg.select, 120), front = msg.front == true, news = msg.news == true }
end

-- Draws a view into its buffer. Its selection: the item the editor asks for (select), else the one selected before (by
-- its key), else its centre, else the first; the cursor goes there when the view has its window.
local function draw(view, keep)
  local buf, G, s = view.buf, graphs(), view.copy
  if not api.nvim_buf_is_valid(buf) then return end
  for name, def in pairs(view.hl) do pcall(api.nvim_set_hl, 0, name, def) end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, view.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(view.marks) do
    pcall(api.nvim_buf_set_extmark, buf, ns, m[1] - 1, m[2], { end_col = m[3], hl_group = m[4], priority = 100 + (tonumber(m[5]) or 0) })
  end
  if not pcall(api.nvim_buf_set_name, buf, 'pop-out · ' .. view.title) then pcall(api.nvim_buf_set_name, buf, 'pop-out · ' .. view.title .. ' · ' .. view.id) end
  view.rows_only = #view.items > 0
  for _, item in ipairs(view.items) do if item.kind ~= 'row' then view.rows_only = false end end
  s.drawn, s.index, s.win, view.strip_for = { boxes = view.items }, nil, view.win, nil
  local first = keep and index_of(view, keep)
  for i, item in ipairs(view.items) do if not first and item.centre then first = i end end
  first = first or (view.items[1] and 1)
  api.nvim_buf_clear_namespace(buf, G.sel_ns, 0, -1)
  if first then G.select(s, first, true); view.cursor_line = view.items[first].line end
  strip(view)
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

local RECEIVES = { ['view.set'] = true, ['view.clear'] = true, ping = true, bye = true }
local function handle(msg)
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
    for _, field in ipairs({ 'gen', 'kind', 'surface', 'title', 'state', 'lines', 'marks', 'hl', 'items', 'footer', 'strip' }) do view[field] = got[field] end
    if got.news and C.shown ~= got.id then view.news = true end
    C.received = (C.received or 0) + 1
    draw(view, got.select or (before and before.key))
    -- A view the editor sends anew, or asks to show, comes to the front; one drawn again behind another stays behind.
    if fresh or got.front or not shown() then show(view) else vim.cmd('redrawtabline') end
  elseif msg.type == 'view.clear' then
    local view = type(msg.id) == 'string' and C.views[msg.id]
    if not view then return end
    C.views[msg.id] = nil
    if view.win and api.nvim_win_is_valid(view.win) and api.nvim_win_get_buf(view.win) == view.buf then
      if #api.nvim_list_tabpages() > 1 then
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
    vim.cmd('redrawtabline')
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
  if not M.is_popout() or type(msg) ~= 'table' or msg.version ~= M.PROTOCOL or not RECEIVES[msg.type] then return false end
  vim.schedule(function()
    local ok, err = pcall(handle, msg)
    if not ok then say('could not draw what the editor sent: ' .. tostring(err):sub(1, 200), WARN) end
  end)
  return true
end

function M.subscribe()
  local answer = request({ type = 'subscribe', chan = C.me, pid = vim.fn.getpid(), width = math.min(1000, width()), protocol = M.PROTOCOL })
  if not answer.refused then C.host = { pid = answer.pid, pane = answer.pane } end
  return answer
end

-- Space Space in the pop-out: what the editor offers for the view and its selected item (describe), the views first,
-- in the menu kit the review uses, and this window's own rows. A row asking for words or a pick asks here.
function M.client_home()
  local view = shown()
  local answer = request(naming({ type = 'describe' }, view))
  if answer.refused then return say(answer.refused, WARN) end
  local ctx, keyed = actions.context(), {}
  for _, row in ipairs((view or C.empty).rows or {}) do keyed[row.id] = true end
  local views, items, here = {}, {}, {}
  local function add(into, row, why, run)
    into[#into + 1] = { ident = row.id, name = row.name, label = row.name .. ' — ' .. tostring(row.about or ''):gsub('`', ''),
      group = tostring(row.group or 'more'):lower(), bind = keyed[row.id] and row.key or nil, right = why, run = function()
        if why then return say(why, WARN) end
        run()
      end }
  end
  for _, row in ipairs(type(answer.rows) == 'table' and answer.rows or {}) do
    if type(row) == 'table' and type(row.id) == 'string' and type(row.name) == 'string' then
      here[row.id] = true
      local mine = actions.get(row.id)
      local run
      if mine and is_on(mine, ON) then run = function() mine.run(ctx) end
      elseif type(row.input) == 'table' then run = function() ask_then_act(mine or row, row) end
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
function M.client_keys()
  local view = shown() or C.empty
  local said = actions.voice(graphs().retro())
  return actions.show_keys(actions.context(), { reasons = false, rows = view.rows, press = press,
    footer = ' ' .. typed('popout.focus') .. ' ' .. said('in the editor comes back here') })
end

-- A double click: the item under the mouse is selected, then it goes as Enter would.
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
  vim.o.shadafile = 'NONE'   -- her history and marks are the editor's to keep
  local server
  for _, arg in ipairs(vim.fn.argv()) do server = server or arg:match('^desk%-popout:(/.+)$') end
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
  api.nvim_create_autocmd('TabEnter', { group = group, callback = function()
    local view = view_in_tab(api.nvim_get_current_tabpage())
    C.shown = view and view.id or nil
    if view then
      view.news = false
      tell_front(view, C.switching)
    end
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
    resized:stop()
    resized:start(100, 0, vim.schedule_wrap(function() if C.chan then M.subscribe() end end))
  end })
end

-- What the tests read of the pop-out.
function M.client_state()
  local view = shown()
  local s = view and view.copy or {}
  local item = s.index and view.items[s.index]
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  return { connected = C.chan ~= nil, host = C.host, shown = C.shown or '', gen = view and view.gen or 0, kind = view and view.kind or '',
    title = view and view.title or '', state = view and view.state or '', index = s.index or 0, selected = item and item.name or '',
    selected_key = item and item.key or '', lines = api.nvim_buf_get_lines(buf, 0, -1, false), closing = C.closing or '',
    win = view and view.win or (C.empty and C.empty.win) or 0, current_win = win, buf = buf, mode = api.nvim_get_mode().mode,
    received = C.received or 0, views = vim.tbl_keys(C.views), tabs = #api.nvim_list_tabpages(), tab = vim.fn.tabpagenr(),
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
  M.focus({ pid = vim.fn.getpid(), pane = host_pane() })
end
local function back_there() return H.history.at >= 1 or 'nothing further back' end
local function ahead_there() return H.history.at < #H.history.steps or 'nothing further forward' end

local ROWS = actions.add({
  { id = 'popout.focus', group = 'Pop-out', name = 'To the pop-out', key = '<leader><Tab>', on = 'editor',
    about = 'Put the keyboard in the pop-out window, on whichever screen it is; the same key there comes back here',
    available = function() return (H.chan ~= nil and not M.is_popout()) or false end,
    run = function()
      if M.is_popout() then return end
      if not H.chan then return tell('No pop-out is open. ' .. sentence('Space Space › views opens one'), WARN) end
      M.focus({ pid = H.pid })
    end },
  { id = 'popout.restore', group = 'Views', name = "Restore the pop-out's views", on = 'editor', remote = true,
    about = 'Open the pop-out again with the views it had when this editor last closed, pinned as they were, on the screen it was on',
    available = function()
      if H.chan or H.opening or not (H.saved and type(H.saved.tabs) == 'table' and #H.saved.tabs > 0) then return false end
      return M.can_pop()
    end,
    run = function() M.restore_layout() end },
  remote({ id = 'popout.go-focus', group = 'Pop-out', name = 'Go to it, in the editor', key = 'f', on = ON,
    about = 'What `Enter` does (go to the selected box or row in the editor), and the keyboard goes to the editor too', available = can_go },
    go_focus),
  remote({ id = 'popout.go-focus-enter', group = 'Pop-out', name = 'Go to it, in the editor', key = '<S-CR>', on = ON, line = 'popout.go-focus',
    menu = false, available = can_go }, go_focus),
  { id = 'popout.go-mouse', group = 'Pop-out', name = 'Go to what is clicked', key = '<2-LeftMouse>', on = ON, menu = false, doc = false,
    run = function() M.client_click() end },
  remote({ id = 'popout.pin', group = 'Pop-out', name = 'Pin, or follow the editor', key = 'p', on = ON,
    about = "Pin this view (PINNED: it stays as it is while the editor moves, and `Enter` visits its items one by one), or follow the editor's cursor again",
    available = showing }, function(ctx) M.pin(ctx.view) end),
  remote({ id = 'popout.back', group = 'Pop-out', name = 'Back to the editor', key = 'o', on = ON,
    about = 'This view back to the editor as a split (the call graph as the live panel), pinned if it is pinned here; the pop-out stays open',
    available = showing }, function(ctx) M.back(ctx.view) end),
  { id = 'popout.next-view', group = 'Pop-out', name = 'The next view', key = 'gt', on = ON, menu = false,
    doc = 'The next / previous view (each view is a tab); a count first goes to that view: `2gt` the second',
    run = function() local n = vim.v.count; pcall(vim.cmd, n > 0 and ('tabnext ' .. n) or 'tabnext') end },
  { id = 'popout.prev-view', group = 'Pop-out', name = 'The previous view', key = 'gT', on = ON, menu = false, line = 'popout.next-view',
    run = function() pcall(vim.cmd, 'tabprevious ' .. vim.v.count1) end },
  remote({ id = 'popout.history-back', group = 'Pop-out', name = 'Back', key = 'H', on = ON,
    about = 'Back where you were: the view before, the graph before a centre, the code spot before `Enter` (the editor goes back too)',
    available = back_there }, function() M.history_back() end),
  remote({ id = 'popout.history-back-bs', group = 'Pop-out', name = 'Back', key = '<BS>', on = ON, line = 'popout.history-back', menu = false,
    available = back_there }, function() M.history_back() end),
  remote({ id = 'popout.history-forward', group = 'Pop-out', name = 'Forward', key = 'L', on = ON,
    about = 'Forward again, after going back', available = ahead_there }, function() M.history_forward() end),
  { id = 'popout.keys', group = 'Pop-out', name = "The pop-out's keys", key = '?', on = ON, about = 'The keys of this view in the pop-out, in a list',
    run = function() M.client_keys() end },
  { id = 'popout.swap', group = 'Pop-out', name = 'To the editor', key = '<leader><Tab>', on = ON,
    about = 'Put the keyboard in the editor; the same key there comes back here', run = function() M.focus(C.host) end },
  { id = 'popout.close', group = 'Pop-out', name = 'Close this view', key = 'q', on = ON, remote = true,
    about = 'Close this view; closing the last one closes the pop-out, and the keyboard comes back to the editor',
    run = function(ctx)
      if not M.is_popout() then
        if ctx.view and #H.order > 1 then M.clear(ctx.view.id)
        else
          -- The last one: the pop-out closes, and the keyboard comes here rather than stay on its empty screen.
          M.forget(nil)
          if ctx.remote then M.focus({ pid = vim.fn.getpid(), pane = host_pane() }) end
        end
        return M.save_layout()
      end
      if shown() and vim.tbl_count(C.views) > 1 then return client_act('popout.close') end
      if C.chan then pcall(client_act, 'popout.close') end
      C.closing = 'closed'
      vim.cmd('qa!')
    end },
  { id = 'popout.home', group = 'Home', name = 'Home menu', key = '<leader><leader>', on = ON, menu = false,
    about = 'The home menu for the selected box or row: the views, what the editor can do with it, and this window', run = function() M.client_home() end },
})
for _, row in ipairs(ROWS) do if row.id == 'popout.restore' then RESTORE = row end end

-- The editor exiting: the layout is written, the pop-out told, and nothing of it left running to keep this editor
-- waiting (its channel, the pings, the watch on the screens, the views' own timers).
local function shutdown()
  if H.down then return end
  local chan = H.chan
  if chan or (H.save_timer and H.save_timer:is_active()) then M.save_layout(true) end
  H.down = true
  if chan then pcall(vim.rpcnotify, chan, 'nvim_exec_lua', POPOUT_DOOR, { { version = M.PROTOCOL, type = 'bye', why = 'Editor closed.' } }) end
  for _, name in ipairs({ 'timer', 'save_timer' }) do
    local timer = H[name]
    if timer then
      timer:stop()
      if not timer:is_closing() then timer:close() end
      H[name] = nil
    end
  end
  unwatch_screens()
  follow_stop()
  for _, view in pairs(H.views) do leave(view) end
  H.chan = nil
  if chan then pcall(vim.fn.chanclose, chan) end
end

local set = false
function M.setup()
  if set or M.is_popout() then return end
  set = true
  actions.map('editor', { rows = ROWS })
  api.nvim_create_user_command('PopOut', function(opts) M.show(opts.args ~= '' and opts.args or 'graph', actions.context()) end,
    { nargs = '?', complete = function() return vim.tbl_keys(kinds) end, desc = 'A view in the pop-out window (the live call graph when none is named)' })
  api.nvim_create_autocmd('VimLeavePre', { group = api.nvim_create_augroup('desk_popout', { clear = true }),
    callback = function() pcall(shutdown) end })
  M.read_layout()
end

return M
