-- One list of what can be done, where, and on which key. Each module adds its rows (M.add) and binds them (M.map). The
-- same rows make which-key's words (a mapping's description is its row's name; M.PREFIXES names the key groups), the
-- home menu (Space Space: M.home, the rows that apply where the cursor is), the reference tables in
-- shared/nvim_NVIM-KEYBINDS.md (python3 tests/test_nvim_keys.py --write), the ? key list of every view (M.keys,
-- M.show_keys) and the bridge's allow-list (M.act runs a row only when it says remote = true).
--
-- A row:
--   id         '<module>.<name>', unique: the bridge and the pop-out name rows by it
--   group      the home menu's group; M.GROUPS gives their order
--   name       a few words: the menu row, and the mapping's description that which-key shows
--   about      a sentence: the menu's description strip, and the keybinds reference's words for the key
--   key, mode  the key as typed ('<leader>Cw', ']f') and its mode ('n' when none; 'x', or a list). No key: menus only
--   on         the surface, or a list of them (M.SURFACES). 'editor' rows are global keys: they apply in every window
--              unless that window's surface binds the same key
--   run        function(ctx): what it does. ctx has surface, buf, win, filetype, file and what the surface passed
--              (the review, the page)
--   available  function(ctx): true (or nil) when it can run; why not ('requires symdeps'), shown greyed with that
--              reason; or false: it does not apply here and is left out (only where another row already says why)
--   remote     true: the pop-out may ask the main editor to run it (M.act)
--   menu       false: in no menu (another key for an action already listed, or plumbing such as clearing a search)
--   line, doc, also   the keybinds reference: line is the id of the row whose line this key joins (keys joined,
--              words from the first); doc is that line's words where they differ from about, or false to leave the
--              key out; also is words after the keys (a command, another key)
local M = {}
local api, uv = vim.api, vim.uv or vim.loop

M.SURFACES = {
  editor = 'any window (global keys)',
  ['review-list'] = "the review's file list",
  ['review-diff'] = "the review's comparison panes",
  callgraph = 'the call graph tab',
  ['callgraph-panel'] = 'the live call graph panel',
  since = 'the since-you-last-looked page',
  popout = 'the pop-out window',
  menu = 'a menu drawn by desk.menu (the home menu and the review actions when symdeps is absent; every ? key list)',
}
M.GROUPS = { 'Home', 'This function', 'Call graph', 'Review', 'Claude', 'Work', 'Jupyter', 'symdeps' }
-- which-key's name for a key prefix on a surface's buffers (the config's global <leader>r group is "refactor").
M.PREFIXES = { ['review-list'] = { { '<leader>r', 'review' } }, ['review-diff'] = { { '<leader>r', 'review' } } }

local KINDS = { id = 'string', group = 'string', name = 'string', about = 'string', key = 'string', mode = 'mode',
  on = 'surfaces', run = 'function', available = 'function', remote = 'boolean', menu = 'boolean', line = 'string',
  doc = 'doc', also = 'string' }
local MODES = { n = true, x = true, v = true, o = true, i = true }

local rows, by_id, source, bound = {}, {}, {}, {}
M.problems = {}   -- every row refused so far, with why (the tests read it)

local function tell(text, level) vim.notify(text, level or vim.log.levels.INFO, { title = 'Actions' }) end
local function list(value) return type(value) == 'table' and value or { value } end
local function modes(row) return row.key and list(row.mode or 'n') or {} end
local function is_on(row, surface) return vim.tbl_contains(list(row.on), surface) end
-- One spelling per key: <CR> and <cr>, <Leader> and <leader> are one key.
local function spelled(key) return (key:gsub('<([^>]+)>', function(k) return '<' .. k:lower() .. '>' end)) end
-- 'requires symdeps' → 'Requires symdeps.'
local function sentence(text) text = tostring(text); return text:sub(1, 1):upper() .. text:sub(2) .. (text:match('[.!?]$') and '' or '.') end

-- Why a row is refused, or nil when it is sound.
function M.check(row)
  if type(row) ~= 'table' then return 'a row must be a table, not ' .. type(row) end
  local id = type(row.id) == 'string' and row.id or '(no id)'
  for field, value in pairs(row) do
    local kind = KINDS[field]
    if not kind then return id .. ': unknown field ' .. tostring(field) end
    local fine
    if kind == 'mode' then
      fine = true
      for _, m in ipairs(list(value)) do fine = fine and MODES[m] == true end
    elseif kind == 'surfaces' then
      fine = (type(value) == 'string' or type(value) == 'table') and #list(value) > 0
      for _, s in ipairs(fine and list(value) or {}) do
        if not M.SURFACES[s] then return id .. ': no surface is called ' .. tostring(s) end
      end
    elseif kind == 'doc' then fine = type(value) == 'string' or value == false
    else fine = type(value) == kind end
    if not fine then return id .. ': ' .. field .. ' is a ' .. type(value) end
  end
  if type(row.id) ~= 'string' or not row.id:match('^[%w_-]+%.[%w_.-]+$') then return id .. ": an id is '<module>.<name>'" end
  if type(row.run) ~= 'function' then return id .. ': has no code (run)' end
  if not row.on then return id .. ': says no surface (on)' end
  if (row.name or '') == '' or (row.group or '') == '' then return id .. ': needs a name and a group' end
  if row.menu ~= false and (row.about or '') == '' then return id .. ': a row in the menus needs about, the words they show' end
  if row.key == '' then return id .. ': an empty key' end
  return nil
end

-- The file a row came from (adding it again from there replaces it, as a reload does).
local function caller()
  local info = debug.getinfo(3, 'S')
  local path = info and info.source or '?'
  if path:sub(1, 1) ~= '@' then return path end
  return uv.fs_realpath(path:sub(2)) or path:sub(2)
end

-- Adds rows; returns the ones taken. A refused row is said out loud and left out, so the rest still work.
function M.add(batch)
  local from, taken = caller(), {}
  for _, row in ipairs(batch) do
    local why = M.check(row)
    local old = not why and by_id[row.id]
    if old and source[old] ~= from then why = row.id .. ': the id is already a row of ' .. source[old] end
    for _, other in ipairs(why and {} or rows) do
      if other.id ~= row.id and row.key and other.key and spelled(other.key) == spelled(row.key) then
        for _, surface in ipairs(list(row.on)) do
          for _, mode in ipairs(modes(row)) do
            if not why and is_on(other, surface) and vim.tbl_contains(modes(other), mode) then
              why = row.id .. ': ' .. row.key .. ' (' .. mode .. ') on ' .. surface .. ' is already ' .. other.id
            end
          end
        end
      end
    end
    if why then
      M.problems[#M.problems + 1] = why
      tell('An action was left out: ' .. why, vim.log.levels.ERROR)
    else
      if old then for i, r in ipairs(rows) do if r == old then rows[i] = row end end else rows[#rows + 1] = row end
      by_id[row.id], source[row] = row, from
      taken[#taken + 1] = row
    end
  end
  return taken
end

function M.get(id) return by_id[id] end
function M.key(id) return by_id[id] and by_id[id].key end
function M.source(row) return source[row] end
function M.rows() return { unpack(rows) } end

-- Where the cursor is: the surface of the window's buffer (as M.map bound it; any other buffer is the editor) and what
-- that surface passed.
function M.context(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  local buf = api.nvim_win_get_buf(win)
  local here = bound[buf]
  local ctx = { surface = here and here.surface or 'editor', win = win, buf = buf, filetype = vim.bo[buf].filetype,
    file = vim.bo[buf].buftype == '' and api.nvim_buf_get_name(buf) or '' }
  for k, v in pairs(here and here.ctx or {}) do ctx[k] = v end
  return ctx
end

-- Binds a surface's keys: every row on it, or only opts.rows. With opts.buffer the keys are that buffer's, and the buffer
-- is that surface for the home menu; without, they are global. opts.ctx: what each run gets besides the place;
-- opts.silent and opts.nowait as the surface has always mapped its keys.
function M.map(surface, opts)
  opts = opts or {}
  local buf = opts.buffer
  if buf then
    if not bound[buf] then api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function() bound[buf] = nil end }) end
    bound[buf] = { surface = surface, ctx = opts.ctx }
    -- which-key is optional; a surface with key groups names them for its own buffers.
    if M.PREFIXES[surface] then
      local ok, wk = pcall(require, 'which-key')
      if ok and type(wk) == 'table' and type(wk.add) == 'function' then
        for _, prefix in ipairs(M.PREFIXES[surface]) do pcall(wk.add, { { prefix[1], group = prefix[2], buffer = buf } }) end
      end
    end
  end
  for _, row in ipairs(opts.rows or rows) do
    if row.key and is_on(row, surface) then
      for _, mode in ipairs(modes(row)) do
        vim.keymap.set(mode, row.key, function() row.run(M.context()) end,
          { buffer = buf, desc = row.name, silent = opts.silent, nowait = opts.nowait })
      end
    end
  end
end

-- true when the row can run at ctx; why not (a string); or false when it does not apply there.
function M.available(row, ctx)
  if not row.available then return true end
  local ok, value = pcall(row.available, ctx)
  if not ok then return "can't tell: " .. tostring(value) end
  if value == nil or value == true then return true end
  if value == false then return false end
  return tostring(value)
end

-- The rows that apply at ctx (default: where the cursor is), in menu order: by group, the surface's own rows first in
-- each, then as they were added. A surface's key hides the editor row on the same key; a row with a key in another
-- mode (a selection) is not one for ctx.mode ('n').
function M.for_context(ctx)
  ctx = ctx or M.context()
  local mode, own, order, picked = ctx.mode or 'n', {}, {}, {}
  for i, g in ipairs(M.GROUPS) do order[g] = i end
  for _, row in ipairs(rows) do
    if is_on(row, ctx.surface) then for _, m in ipairs(modes(row)) do own[m .. spelled(row.key)] = true end end
  end
  for i, row in ipairs(rows) do
    local mine = is_on(row, ctx.surface)
    local applies = mine or is_on(row, 'editor')
    if applies and row.key and not vim.tbl_contains(modes(row), mode) then applies = false end
    if applies and not mine and row.key and own[mode .. spelled(row.key)] then applies = false end
    if applies and M.available(row, ctx) ~= false then
      if not order[row.group] then order[row.group] = #M.GROUPS + i end
      picked[#picked + 1] = { row = row, group = order[row.group], mine = mine and 0 or 1, at = i }
    end
  end
  table.sort(picked, function(a, b)
    if a.group ~= b.group then return a.group < b.group end
    if a.mine ~= b.mine then return a.mine < b.mine end
    return a.at < b.at
  end)
  return vim.tbl_map(function(p) return p.row end, picked)
end

-- Runs a row from a menu: one that cannot run here says why instead.
function M.run(row, ctx)
  local why = M.available(row, ctx)
  if why ~= true then tell(why == false and (row.name .. ': not here.') or sentence(why), vim.log.levels.WARN); return false end
  row.run(ctx)
  return true
end

local PLACES = { ['review-list'] = 'review', ['review-diff'] = 'review', callgraph = 'call graph', ['callgraph-panel'] = 'call graph',
  since = 'since you last looked', popout = 'pop-out', menu = 'menu' }
function M.title(ctx)
  local place = PLACES[ctx.surface] or (ctx.file ~= '' and vim.fn.fnamemodify(ctx.file, ':t')) or nil
  return 'Home' .. (place and (' · ' .. place) or '')
end

-- The home menu: what applies where the cursor is, by group, in the menu kit the review uses (symdeps' when it is
-- installed, else desk.menu: the same look). A row that cannot run here is shown with why, never left out.
function M.home(win)
  local ctx = M.context(win)
  if vim.b[ctx.buf].foxml_menu or vim.b[ctx.buf].fox_symdeps_menu ~= nil then return end   -- Space Space inside a menu
  local items = {}
  for _, row in ipairs(M.for_context(ctx)) do
    if row.menu ~= false then
      local why = M.available(row, ctx)
      items[#items + 1] = { ident = row.id, name = row.name, label = row.name .. ' — ' .. row.about:gsub('`', ''),
        group = row.group:lower(), bind = row.key, right = why ~= true and why or nil, run = function() M.run(row, ctx) end }
    end
  end
  require('desk.review').show_menu(items, { title = M.title(ctx), anchor_win = ctx.win, memo = 'desk-home' })
end

-- A surface's keys in order, for a list of them (the ? of every view), as plain data.
function M.keys(surface)
  local out = {}
  for _, row in ipairs(rows) do
    if row.key and is_on(row, surface) and row.doc ~= false then
      out[#out + 1] = { id = row.id, key = row.key, mode = modes(row), name = row.name, about = row.about, group = row.group,
        line = row.line, doc = row.doc }
    end
  end
  return out
end

-- The ? list of a view, a line per reference line: the keys of rows that join one line together, as the keybinds
-- reference has them. A line's words are its first row's here: its name, or for keys joined on one line the doc that
-- gives that line its own words. Enter runs that row where ? was pressed. The ? row itself is left out: it closes
-- the list.
function M.key_lines(ctx)
  local out, at = {}, {}
  for _, k in ipairs(M.keys(ctx.surface)) do
    local row = by_id[k.id]
    local why = row.id ~= 'desk.keys' and M.available(row, ctx)
    if why ~= false then
      local owner = row.line or row.id
      local line = at[owner]
      if not line then
        local head = by_id[owner] and is_on(by_id[owner], ctx.surface) and by_id[owner] or row
        line = { ident = owner, group = head.group, keys = {}, head = head,
          about = head.about or (by_id[owner] and by_id[owner].about) or head.name, right = why ~= true and why or nil,
          run = function() M.run(head, ctx) end }
        at[owner] = line
        out[#out + 1] = line
      end
      if not vim.tbl_contains(line.keys, row.key) then line.keys[#line.keys + 1] = row.key end
    end
  end
  for _, line in ipairs(out) do
    line.name = #line.keys > 1 and type(line.head.doc) == 'string' and line.head.doc or line.head.name
    line.label, line.head = line.name .. ' — ' .. line.about, nil
  end
  return out
end

-- The ? key: this view's keys as a list, drawn by desk.menu (keys as typed, words in the theme's voice).
function M.show_keys(ctx)
  ctx = ctx or M.context()
  local function open()
    return require('desk.menu').open(M.key_lines(ctx), { title = 'Keys · ' .. (PLACES[ctx.surface] or ctx.surface), keys = true,
      memo = 'desk-keys-' .. ctx.surface })
  end
  -- From a menu, the list opens over it and q goes back to it, as symdeps' own ? does.
  if type(ctx.menu) == 'table' and type(ctx.menu.child) == 'function' then return ctx.menu.child(open) end
  return open()
end

-- What the pop-out may offer at ctx, as plain data (no code): the remote rows that apply, each with why it cannot run
-- (available = true or the reason).
function M.describe(ctx)
  local out = {}
  for _, row in ipairs(M.for_context(ctx)) do
    if row.remote and row.menu ~= false then
      out[#out + 1] = { id = row.id, group = row.group, name = row.name, about = row.about, key = row.key, available = M.available(row, ctx) }
    end
  end
  return out
end

-- The bridge's door: runs row `id` for the pop-out, only when it is a remote row that can run at ctx. true, or false
-- and why. It runs now: the caller schedules it when it must answer first.
function M.act(id, ctx)
  local row = by_id[id]
  if not row then return false, 'no action is called ' .. tostring(id) end
  if not row.remote then return false, id .. ' is not one the pop-out may ask for' end
  ctx = ctx or M.context()
  local why = M.available(row, ctx)
  if why ~= true then return false, why == false and (id .. ' does not apply here') or why end
  local ok, err = pcall(row.run, ctx)
  if not ok then return false, tostring(err) end
  return true
end

-- An Ex command as a <cmd> mapping runs it: a failure is an error message, not a Lua error.
function M.ex(command)
  local ok, err = pcall(vim.cmd, command)
  if not ok then api.nvim_echo({ { (tostring(err):gsub('^.-Vim%(%a+%):', '')), 'ErrorMsg' } }, true, {}) end
end

-- ─── its own rows: the home key, and symdeps ──────────────────────────────────────────────────────────────────────
-- symdeps (fox-symdeps.nvim) is optional. Asking for it loads it when it is installed, as the review's menus do.
function M.symdeps() return package.loaded['fox-symdeps'] ~= nil or (pcall(require, 'fox-symdeps')) end

local OWN = M.add({
  { id = 'desk.home', group = 'Home', name = 'Home menu', key = '<leader><leader>', on = 'editor', menu = false,
    about = 'Everything that applies where the cursor is, in one menu: this function, the review, Claude, work, symdeps',
    run = function(ctx) M.home(ctx.win) end },
  -- ? lists the keys of the view it is pressed in. Not in code: there ? searches backward.
  { id = 'desk.keys', group = 'Home', name = 'The keys here', key = '?', menu = false,
    on = { 'review-list', 'review-diff', 'callgraph', 'callgraph-panel', 'since', 'menu' },
    about = 'The keys of this view as a list: `Enter` runs the selected one, `?` or `q` closes the list',
    run = function(ctx) M.show_keys(ctx) end },
  -- The card of the unit at the cursor. Only in code: the review and the call graph have their own symdeps keys, and
  -- without symdeps its one row below says so.
  { id = 'symdeps.card', group = 'This function', name = 'This function in symdeps', on = 'editor',
    about = "symdeps' card for the unit at the cursor: its layout, uses, callers and calls",
    available = function(ctx)
      if ctx.surface ~= 'editor' or not M.symdeps() then return false end
      return (ctx.filetype == 'c' or ctx.filetype == 'cpp') or 'requires a C or C++ file'
    end,
    run = function()
      local found, card = pcall(require, 'fox-symdeps.card')
      local plugin = package.loaded['fox-symdeps']
      local inspect = found and type(card) == 'table' and type(card.inspect_cursor) == 'function' and card.inspect_cursor
        or type(plugin) == 'table' and type(plugin.inspect_cursor) == 'function' and plugin.inspect_cursor or nil
      if not inspect then tell('This symdeps version does not expose its card.'); return end
      inspect()
    end },
  -- symdeps' own home menu is its key, Space dm (its README: "the home menu is the root surface"). The key is pressed
  -- for it, so this works however the plugin was loaded (lazy.nvim maps that key before it loads the plugin).
  { id = 'symdeps.menu', group = 'symdeps', name = 'symdeps', on = 'editor',
    about = "symdeps' own menu (Space dm): its cards, lists and checks for C and C++ code. symdeps is an optional plugin",
    available = function() return M.symdeps() or 'requires symdeps' end,
    run = function()
      local keys = vim.keycode('<leader>dm')
      if vim.fn.maparg(keys, 'n') == '' then tell('symdeps is loaded, but nothing is on its menu key (Space dm).', vim.log.levels.WARN); return end
      api.nvim_feedkeys(keys, 'm', false)
    end },
})

local set = false
function M.setup()
  if set then return end
  set = true
  M.map('editor', { rows = OWN })
end

return M
