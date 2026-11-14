-- A floating menu drawn to the symdeps plugin's menu rules (docs/ui-style.md), for when that plugin is not installed:
-- groups under rule lines, a letter and name per row, state and shortcut columns padded to line up, a two-line
-- description strip, one footer line, and the same keys (j/k, Enter or l, h or q or Esc, / to filter, a row's letter).
-- It takes the same items and options as require('fox-symdeps.menu').open, so a caller writes one list for both.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('foxml_menu')
local memory = {}

local function hl(name, fallback) return vim.fn.hlexists(name) == 1 and name or fallback end
local function width(s) return vim.fn.strdisplaywidth(s) end
local function fit(s, w)
  if width(s) <= w then return s end
  while width(s) > w - 1 and #s > 0 do s = vim.fn.strcharpart(s, 0, vim.fn.strchars(s) - 1) end
  return s .. '…'
end
local function pad(s, w) return s .. string.rep(' ', math.max(0, w - width(s))) end

-- "Name — description" splits into the row's name and the strip's text; an item may also give both.
local function parts(item)
  if item.name then return item.name, item.label or item.name end
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
local function bind_text(item) return item.bind and tostring(item.bind):gsub('<[lL]eader>', '<ldr>') or '' end

-- The lines to draw and which item each stands for. Pure, so a test can read it.
function M.layout(items, opts)
  opts = opts or {}
  local shown = {}
  local filter = (opts.filter or ''):lower()
  for _, item in ipairs(items) do
    local name, about = parts(item)
    if filter == '' or (name .. ' ' .. about):lower():find(filter, 1, true) then shown[#shown + 1] = item end
  end
  local names, states, binds = 0, 0, 0
  for _, item in ipairs(shown) do
    names = math.max(names, width((parts(item))))
    states = math.max(states, width(state_text(item)))
    binds = math.max(binds, width(bind_text(item)))
  end
  local body = 5 + names + (states > 0 and states + 2 or 0) + (binds > 0 and binds + 2 or 0) + 1
  local w = math.max(44, math.min(body, opts.max_width or 92), width(opts.title or '') + 6)
  local lines, rows, paints = {}, {}, {}
  local groups = {}
  for _, item in ipairs(shown) do if item.group and not vim.tbl_contains(groups, item.group) then groups[#groups + 1] = item.group end end
  local group
  for _, item in ipairs(shown) do
    if #groups > 1 and item.group ~= group then
      if group ~= nil then lines[#lines + 1] = '' end
      group = item.group
      local head = ' ── ' .. tostring(group or 'more'):lower() .. ' '
      lines[#lines + 1] = head .. string.rep('─', math.max(2, w - width(head) - 1))
      paints[#paints + 1] = { #lines, 0, -1, hl('FoxSymdepsHeader', 'Title') }
    end
    local name = parts(item)
    local letter = item.key and tostring(item.key) or ' '
    local state, bind = state_text(item), bind_text(item)
    local line = '  ' .. letter .. '  ' .. pad(fit(name, names), names)
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
  lines[#lines + 1] = ' ╭' .. string.rep('─', w - 3) .. '╮'
  lines[#lines + 1] = ' │ ' .. string.rep(' ', w - 5) .. ' │'
  lines[#lines + 1] = ' │ ' .. string.rep(' ', w - 5) .. ' │'
  lines[#lines + 1] = ' ╰' .. string.rep('─', w - 3) .. '╯'
  for line = strip - 1, strip + 2 do paints[#paints + 1] = { line, 0, -1, hl('FoxSymdepsDim', 'Comment') } end
  lines[#lines + 1] = fit(opts.footer or ' / filter · ⏎ run · q close', w)
  paints[#paints + 1] = { #lines, 0, -1, hl('FoxSymdepsDim', 'Comment') }
  return { lines = lines, rows = rows, paints = paints, width = w, strip = strip }
end

local function ident(item) return (item.group or '') .. '\0' .. tostring(item.ident or item.id or item.label or item.name) end

function M.open(items, opts)
  opts = opts or {}
  local origin = api.nvim_get_current_win()
  local state = { filter = '' }
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'wipe', 'foxml-menu'
  vim.b[buf].foxml_menu = true
  local win
  local function close()
    if win and api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    if api.nvim_win_is_valid(origin) then pcall(api.nvim_set_current_win, origin) end
  end
  local function row_lines() local out = {}; for line in pairs(state.layout.rows) do out[#out + 1] = line end; table.sort(out); return out end
  local function strip(line)
    local item = state.layout.rows[line]
    local _, about = parts(item or {})
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
    state.layout = M.layout(items, { title = opts.title, filter = state.filter, footer = opts.footer })
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, state.layout.lines)
    vim.bo[buf].modifiable = false
    local height = math.min(#state.layout.lines, math.max(6, vim.o.lines - 6))
    local config = { relative = 'editor', width = state.layout.width, height = height, style = 'minimal', border = 'rounded',
      title = ' ' .. (opts.title or 'Actions') .. (state.filter ~= '' and (' · /' .. state.filter) or '') .. ' ', title_pos = 'center',
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
      close(); item.run()
    end
  end
  local function key(lhs, fn) vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true }) end
  key('j', function() move(1) end); key('<Down>', function() move(1) end)
  key('k', function() move(-1) end); key('<Up>', function() move(-1) end)
  key('<CR>', function() run(state.layout.rows[api.nvim_win_get_cursor(win)[1]]) end)
  key('l', function() run(state.layout.rows[api.nvim_win_get_cursor(win)[1]]) end)
  for _, lhs in ipairs({ 'q', '<Esc>', 'h' }) do
    key(lhs, function()
      if state.filter ~= '' and lhs ~= 'q' then state.filter = ''; draw() return end
      close()
      if lhs == 'h' and type(opts.back) == 'function' then opts.back() end
    end)
  end
  key('/', function()
    state.asking = true
    vim.ui.input({ prompt = 'Filter: ', default = state.filter }, function(text)
      state.asking = false
      if not api.nvim_win_is_valid(win) then return end
      api.nvim_set_current_win(win)
      if text ~= nil then state.filter = text; draw() end
    end)
  end)
  key('<LeftMouse>', function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid ~= win then close() return end
    if state.layout.rows[mouse.line] then api.nvim_win_set_cursor(win, { mouse.line, 0 }); run(state.layout.rows[mouse.line]) end
  end)
  for _, item in ipairs(items) do
    if item.key and #tostring(item.key) == 1 and not ('jklhq/'):find(tostring(item.key), 1, true) then key(tostring(item.key), function() run(item) end) end
  end
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

return M
