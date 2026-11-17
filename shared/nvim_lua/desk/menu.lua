-- A floating menu drawn to the symdeps plugin's menu rules (docs/ui-style.md), for when that plugin is not installed:
-- groups under rule lines, a letter and name per row, state and shortcut columns padded to line up, a two-line
-- description strip, one footer line, and the same keys (j/k, Enter or l, h or q or Esc, / to filter, a row's letter).
-- It takes the same items and options as require('fox-symdeps.menu').open, so a caller writes one list for both.
-- opts.keys draws a key list instead (the ? of a desk view): each row's keys in a column of their own, as typed.
-- The menu's own keys are rows of the action registry (desk/actions.lua, the 'menu' surface), so its ? lists them.
local M = {}
local api = vim.api
local actions = require('desk.actions')
local ns = api.nvim_create_namespace('foxml_menu')
local memory = {}

-- symdeps' group when it draws something, else the fallback: a group that only exists (cleared, or a link to one the
-- pop-out's Neovim lacks) drew no selection bar in the pop-out's menus (2026-11-16).
local function hl(name, fallback)
  local ok, def = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  return ok and type(def) == 'table' and next(def) ~= nil and name or fallback
end
local function width(s) return vim.fn.strdisplaywidth(s) end
local function fit(s, w)
  if width(s) <= w then return s end
  while width(s) > w - 1 and #s > 0 do s = vim.fn.strcharpart(s, 0, vim.fn.strchars(s) - 1) end
  return s .. '…'
end
local function pad(s, w) return s .. string.rep(' ', math.max(0, w - width(s))) end

-- A key as it is typed: <CR> is Enter, <leader>rw is Space rw (the registry's one speller); words in the theme's
-- voice (the registry's one voice: capitals in retro, keys and commands between backticks as typed).
M.typed = actions.spell
M.voice = actions.voice
local function retro() return vim.g.desk_style == 'retro' end

-- "Name — description" splits into the row's name and the strip's text; an item may also give both.
local function parts(item)
  if item.name then
    local about = item.label or item.name
    return item.name, about:match('^' .. vim.pesc(item.name) .. '%s+—%s+(.+)$') or about
  end
  local label = item.label or ''
  local name, rest = label:match('^(.-)%s+—%s+(.*)$')
  return name or label, rest or label
end
local function state_text(item)
  if type(item.state) ~= 'function' then return item.right or '' end
  local ok, value = pcall(item.state)
  if not ok then return '' end
  if value == true then return '● on' elseif value == false then return '○ off' end
  return value ~= nil and tostring(value) or ''
end
-- A row's key in the shortcut column, spelled as every key list spells it ("Space cc", "Enter").
local function bind_text(item) return item.bind and actions.spell(item.bind) or '' end
-- The left column: a row's letter, or in a key list its keys as typed ("]f/[f/Tab").
local function lead_text(item, keys)
  if keys then return table.concat(vim.tbl_map(M.typed, item.keys or {}), '/') end
  return item.key and tostring(item.key) or ' '
end
-- The footer of a key list: keys as typed, words in the theme's voice.
local function key_footer(said)
  return ' ' .. table.concat(vim.tbl_map(function(p) return p[1] .. ' ' .. said(p[2]) end,
    { { '⏎', 'run' }, { '/', 'filter' }, { 'q', 'close' } }), ' · ')
end

-- The strip's corners: square when the floats are the DOS box (vim.g.desk_border is a list of characters, retro),
-- rounded otherwise.
local function corners()
  if type(vim.g.desk_border) == 'table' then return '┌', '┐', '└', '┘' end
  return '╭', '╮', '╰', '╯'
end
-- A reason in the state column (why a row cannot run) is cut here, so the names keep their room.
M.MAX_STATE = 28

-- The lines to draw and which item each stands for. Pure, so a test can read it. opts.keys: a key list, its words
-- in opts.said (the theme's voice, M.voice); opts.heads: the voice of the group headings in any menu (retro: capitals);
-- opts.max_width: the widest it may be (92 unless the screen allows more).
function M.layout(items, opts)
  opts = opts or {}
  local keys, said = opts.keys, opts.said or function(s) return s end
  local heads = opts.heads or (keys and said) or function(s) return s end
  local shown = {}
  local filter = (opts.filter or ''):lower()
  for _, item in ipairs(items) do
    local name, about = parts(item)
    local typed = keys and (lead_text(item, true) .. ' ') or ''
    if filter == '' or (typed .. name .. ' ' .. about):lower():find(filter, 1, true) then shown[#shown + 1] = item end
  end
  local leads, names, states, binds = 1, 0, 0, 0
  for _, item in ipairs(shown) do
    leads = math.max(leads, width(lead_text(item, keys)))
    names = math.max(names, width(keys and said((parts(item))) or (parts(item))))
    states = math.min(M.MAX_STATE, math.max(states, width(state_text(item))))
    binds = math.max(binds, width(bind_text(item)))
  end
  local others = (states > 0 and states + 2 or 0) + (binds > 0 and binds + 2 or 0) + 1
  -- Names give way to the keys and states beside them: a long one ends in … rather than pushing them past the edge.
  names = math.min(names, math.max(12, (opts.max_width or 92) - 4 - leads - others))
  local body = 4 + leads + names + others
  local title = keys and said(opts.title or '') or opts.title or ''
  local w = math.max(44, math.min(body, opts.max_width or 92), width(title) + 6)
  local lines, rows, paints = {}, {}, {}
  local groups = {}
  for _, item in ipairs(shown) do if item.group and not vim.tbl_contains(groups, item.group) then groups[#groups + 1] = item.group end end
  local group
  for _, item in ipairs(shown) do
    if #groups > 1 and item.group ~= group then
      if group ~= nil then lines[#lines + 1] = '' end
      group = item.group
      local head = ' ── ' .. heads(tostring(group or 'more'):lower()) .. ' '
      lines[#lines + 1] = head .. string.rep('─', math.max(2, w - width(head) - 1))
      paints[#paints + 1] = { #lines, 0, -1, hl('FoxSymdepsHeader', 'Title') }
    end
    local name = keys and said((parts(item))) or parts(item)
    local letter = lead_text(item, keys)
    local state, bind = fit(state_text(item), M.MAX_STATE), bind_text(item)
    local line = '  ' .. pad(letter, leads) .. '  ' .. pad(fit(name, names), names)
    local from_state = #line + 2
    if states > 0 then line = line .. '  ' .. pad(state, states) end
    local from_bind = #line + 2
    if binds > 0 then line = line .. '  ' .. pad(bind, binds) end
    lines[#lines + 1] = line
    rows[#lines] = item
    paints[#paints + 1] = { #lines, 2, 2 + #letter, hl('FoxSymdepsHeader', 'Title') }
    if state ~= '' then
      paints[#paints + 1] = { #lines, from_state, from_state + #state,
        state:sub(1, #'●') == '●' and hl('FoxSymdepsOk', 'DiagnosticOk') or hl('FoxSymdepsDim', 'Comment') }
    end
    if bind ~= '' then paints[#paints + 1] = { #lines, from_bind, from_bind + #bind, hl('FoxSymdepsDim', 'Comment') } end
  end
  if #shown == 0 then lines[#lines + 1] = '  nothing matches'; paints[#paints + 1] = { #lines, 0, -1, hl('FoxSymdepsDim', 'Comment') } end
  lines[#lines + 1] = ''
  local strip = #lines + 2
  local tl, tr, bl, br = corners()
  lines[#lines + 1] = ' ' .. tl .. string.rep('─', w - 3) .. tr
  lines[#lines + 1] = ' │ ' .. string.rep(' ', w - 5) .. ' │'
  lines[#lines + 1] = ' │ ' .. string.rep(' ', w - 5) .. ' │'
  lines[#lines + 1] = ' ' .. bl .. string.rep('─', w - 3) .. br
  for line = strip - 1, strip + 2 do paints[#paints + 1] = { line, 0, -1, hl('FoxSymdepsDim', 'Comment') } end
  lines[#lines + 1] = fit(opts.footer or (keys and key_footer(said)) or ' / filter · ⏎ run · q close', w)
  paints[#paints + 1] = { #lines, 0, -1, hl('FoxSymdepsDim', 'Comment') }
  return { lines = lines, rows = rows, paints = paints, width = w, strip = strip }
end

local function ident(item) return (item.group or '') .. '\0' .. tostring(item.ident or item.id or item.label or item.name) end

-- vim.ui.select drawn as this menu (j/k, Enter or l, / to filter, Esc or q to cancel), so every "choose one" question
-- in the desktop looks and works the same: on_choice(item, index), or on_choice(nil, nil) when nothing was chosen.
-- opts.desk_keys: a letter per item (desk.actions.ask), pressed to choose it; the menu's own keys (j k l h q /) stay its.
function M.select(items, opts, on_choice)
  opts = opts or {}
  -- Which screen: drawn as a map of the screens when they have places (desk.screens), else this list.
  if opts.kind == 'desk_screens' and require('desk.screens').pick(items, opts, on_choice) then return end
  local format = opts.format_item or tostring
  local rows = {}
  for i, item in ipairs(items or {}) do
    local key = opts.desk_keys and opts.desk_keys[i]
    if key and ('jklhq/'):find(key, 1, true) then key = nil end
    rows[i] = { name = tostring(format(item)), key = key, run = function() on_choice(item, i) end }
  end
  return M.open(rows, { title = opts.prompt and vim.trim((opts.prompt:gsub(':%s*$', ''))) or 'Choose', memo = false,
                        cancelled = function() on_choice(nil, nil) end })
end

function M.open(items, opts)
  opts = opts or {}
  local said = opts.keys and M.voice(retro()) or nil
  local origin = api.nvim_get_current_win()
  local state = { filter = '' }
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'wipe', 'foxml-menu'
  vim.b[buf].foxml_menu = true
  local win, ran
  -- opts.cancelled: called when the menu closes with nothing chosen (Esc, q, h), as vim.ui.select's nil answer.
  local function close()
    if win and api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    if api.nvim_win_is_valid(origin) then pcall(api.nvim_set_current_win, origin) end
    if not ran and type(opts.cancelled) == 'function' then ran = true; opts.cancelled() end
  end
  local function row_lines() local out = {}; for line in pairs(state.layout.rows) do out[#out + 1] = line end; table.sort(out); return out end
  local function strip(line)
    local item = state.layout.rows[line]
    local _, about = parts(item or {})
    if said then about = said(about) end
    local w = state.layout.width - 5
    local words, first, second = vim.split(item and about or '', ' ', { plain = true }), '', ''
    for _, word in ipairs(words) do
      if width(first) + width(word) + 1 <= w and second == '' then first = first == '' and word or (first .. ' ' .. word)
      else second = second == '' and word or (second .. ' ' .. word) end
    end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, state.layout.strip - 1, state.layout.strip + 1, false,
      { ' │ ' .. pad(fit(first, w), w) .. ' │', ' │ ' .. pad(fit(second, w), w) .. ' │' })
    vim.bo[buf].modifiable = false
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, p in ipairs(state.layout.paints) do
      local text = api.nvim_buf_get_lines(buf, p[1] - 1, p[1], false)[1] or ''
      pcall(api.nvim_buf_set_extmark, buf, ns, p[1] - 1, math.min(p[2], #text), { end_row = p[1] - 1, end_col = p[3] < 0 and #text or math.min(p[3], #text), hl_group = p[4] })
    end
    if item then api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { line_hl_group = hl('FoxSymdepsSelection', 'Visual'), virt_text = { { '❯', hl('FoxSymdepsSelection', 'Visual') } }, virt_text_pos = 'overlay' }) end
  end
  local function draw(keep)
    -- As wide as its rows want, up to what the screen has (a wide screen keeps whole descriptions).
    state.layout = M.layout(items, { title = opts.title, filter = state.filter, footer = opts.footer, keys = opts.keys, said = said,
      heads = M.voice(retro()), max_width = math.max(60, math.min(160, vim.o.columns - 6)) })
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, state.layout.lines)
    vim.bo[buf].modifiable = false
    local height = math.min(#state.layout.lines, math.max(6, vim.o.lines - 6))
    local title = said and said(opts.title or 'Keys') or (opts.title or 'Actions')
    local config = { relative = 'editor', width = state.layout.width, height = height, style = 'minimal', border = vim.g.desk_border or 'rounded',
      title = ' ' .. title .. (state.filter ~= '' and (' · /' .. state.filter) or '') .. ' ', title_pos = 'center',
      row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1), col = math.max(0, math.floor((vim.o.columns - state.layout.width) / 2)) }
    if win and api.nvim_win_is_valid(win) then api.nvim_win_set_config(win, config) else
      win = api.nvim_open_win(buf, true, config)
      vim.wo[win].winhighlight = table.concat({ 'Normal:' .. hl('FoxSymdepsText', 'NormalFloat'), 'FloatBorder:' .. hl('FoxSymdepsBorder', 'FloatBorder'),
        'FloatTitle:' .. hl('FoxSymdepsTitle', 'Title') }, ',')
      vim.wo[win].cursorline, vim.wo[win].wrap = false, false
    end
    local rows = row_lines()
    local target = rows[1]
    local remembered = keep or memory[opts.memo or opts.title or '']
    for _, line in ipairs(rows) do if ident(state.layout.rows[line]) == remembered then target = line end end
    if target then api.nvim_win_set_cursor(win, { target, 0 }); strip(target) else strip(0) end
  end
  local function move(step)
    local rows, at = row_lines(), api.nvim_win_get_cursor(win)[1]
    local index = 1
    for i, line in ipairs(rows) do if line == at then index = i end end
    local next_line = rows[math.max(1, math.min(#rows, index + step))]
    if next_line then api.nvim_win_set_cursor(win, { next_line, 0 }); strip(next_line) end
  end
  local function run(item)
    if not item or type(item.run) ~= 'function' then return end
    if opts.memo ~= false then memory[opts.memo or opts.title or ''] = ident(item) end
    if item.stays then
      local ok, err = pcall(item.run)
      if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
      if win and api.nvim_win_is_valid(win) then draw(ident(item)) end
    else
      ran = true
      close(); item.run()
    end
  end
  -- What the menu's keys (the rows at the end of this file) do in this menu.
  local here = {
    move = move,
    run = function() run(state.layout.rows[api.nvim_win_get_cursor(win)[1]]) end,
    leave = function(lhs)
      if state.filter ~= '' and lhs ~= 'q' then state.filter = ''; draw() return end
      close()
      if lhs == 'h' and type(opts.back) == 'function' then opts.back() end
    end,
    filter = function()
      state.asking = true
      vim.ui.input({ prompt = 'Filter: ', default = state.filter }, function(text)
        state.asking = false
        if not api.nvim_win_is_valid(win) then return end
        api.nvim_set_current_win(win)
        if text ~= nil then state.filter = text; draw() end
      end)
    end,
    click = function()
      local mouse = vim.fn.getmousepos()
      if mouse.winid ~= win then close() return end
      if state.layout.rows[mouse.line] then api.nvim_win_set_cursor(win, { mouse.line, 0 }); run(state.layout.rows[mouse.line]) end
    end,
    -- A list opened from this menu (its ? keys) keeps the menu open beneath it; closing that list comes back here.
    child = function(open)
      state.asking = true
      local child = open()
      api.nvim_create_autocmd('WinClosed', { pattern = tostring(child), once = true, callback = function()
        vim.schedule(function()
          state.asking = false
          if win and api.nvim_win_is_valid(win) and api.nvim_get_current_win() ~= win then close() end
        end)
      end })
    end,
  }
  actions.map('menu', { buffer = buf, nowait = true, silent = true, ctx = { menu = here } })
  local function key(lhs, fn) vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true }) end
  -- A key list's ? closes it again, rather than listing the list's own keys.
  if opts.keys then key('?', close) end
  for _, item in ipairs(items) do
    if item.key and #tostring(item.key) == 1 and not ('jklhq/'):find(tostring(item.key), 1, true) then key(tostring(item.key), function() run(item) end) end
  end
  api.nvim_create_autocmd('CursorMoved', { buffer = buf, callback = function()
    if not (win and api.nvim_win_is_valid(win)) then return end
    local rows, at = row_lines(), api.nvim_win_get_cursor(win)[1]
    if #rows == 0 then return end
    local nearest = rows[1]
    for _, line in ipairs(rows) do if math.abs(line - at) < math.abs(nearest - at) then nearest = line end end
    if nearest ~= at then api.nvim_win_set_cursor(win, { nearest, 0 }) end
    strip(nearest)
  end })
  -- Focus leaving the menu closes it, except while its own filter prompt has the keyboard.
  api.nvim_create_autocmd('WinLeave', { buffer = buf, callback = function()
    vim.schedule(function()
      if state.asking or not (win and api.nvim_win_is_valid(win)) or api.nvim_get_current_win() == win then return end
      close()
    end)
  end })
  draw()
  M._last = { win = win, buf = buf }   -- test seam
  return win
end

-- ─── the menu's keys ─────────────────────────────────────────────────────────────────────────────────────────────
-- Rows of the action registry on the 'menu' surface: each runs ctx.menu, the menu it was pressed in. A row's own
-- letter (an item's key) is bound by M.open beside them, and wins over ? when an item takes it.
local function call(what, ...)
  local args = { ... }
  return function(ctx) ctx.menu[what](unpack(args)) end
end
local function key_row(name, key, row)
  row.id, row.group, row.key, row.on, row.menu = 'menu.' .. name, 'Menu', key, 'menu', false
  return row
end
M.rows = actions.add({
  key_row('down', 'j', { name = 'The next row', doc = 'The next / previous row', run = call('move', 1),
    about = 'Move to the next row, over headings and blank lines; `k` the previous one' }),
  key_row('down-arrow', '<Down>', { name = 'The next row', line = 'menu.down', run = call('move', 1) }),
  key_row('up', 'k', { name = 'The previous row', line = 'menu.down', run = call('move', -1) }),
  key_row('up-arrow', '<Up>', { name = 'The previous row', line = 'menu.down', run = call('move', -1) }),
  key_row('run', '<CR>', { name = 'Run the selected row', run = call('run'),
    about = 'Run the selected row; a row that cannot run here says why instead' }),
  key_row('run-l', 'l', { name = 'Run the selected row', line = 'menu.run', run = call('run') }),
  key_row('filter', '/', { name = 'Filter the rows', run = call('filter'),
    about = 'Keep only the rows with this text in their words; `Esc` or `h` shows them all again' }),
  key_row('back', 'h', { name = 'Back', run = call('leave', 'h'),
    about = 'Show every row again after a filter; else close, back to where this menu came from' }),
  key_row('close', 'q', { name = 'Close the menu', run = call('leave', 'q'), about = 'Close the menu' }),
  key_row('close-esc', '<Esc>', { name = 'Clear the filter, or close', run = call('leave', '<Esc>'),
    about = 'Show every row again after a filter; else close the menu' }),
  key_row('click', '<LeftMouse>', { name = 'Run the row clicked', doc = false, run = call('click') }),
})

return M
