-- The screen question as a map of the screens: each one a box in its real place and shape (Hyprland's monitors:
-- position, size, scale, rotation), the chosen one drawn with the pop-out inside it where it will tile, the editor's own
-- marked. h/j/k/l go to the screen that way, Enter takes it, Esc or q asks no more. It answers vim.ui.select when its
-- kind is 'desk_screens' (desk.menu.select sends it here), so every screen question looks the same; items without a
-- place get the plain list. Its keys are rows of the action registry (the 'screens' surface, at the end of this file).
local M = {}
local api = vim.api
local actions = require('desk.actions')
local ns = api.nvim_create_namespace('desk_screens')

-- ─── pure: places, the drawing, the moves ──────────────────────────────────────────────────────────────────────
-- A screen's place in the desktop's own units: its size divided by its scale, turned on its side when rotated.
function M.geometry(item)
  local x, y, w, h = tonumber(item.x), tonumber(item.y), tonumber(item.width), tonumber(item.height)
  if not (x and y and w and h and w > 0 and h > 0) then return nil end
  local scale = tonumber(item.scale) or 1
  if scale <= 0 then scale = 1 end
  w, h = w / scale, h / scale
  if (tonumber(item.transform) or 0) % 2 == 1 then w, h = h, w end
  return { x = x, y = y, w = w, h = h }
end

-- Every item placed, or nil when one has no place (the list asks then).
function M.places(items)
  local out = {}
  for i, item in ipairs(items or {}) do
    out[i] = M.geometry(item)
    if not out[i] then return nil end
  end
  return #out > 0 and out or nil
end

local GLYPHS = {
  plain = { h = '─', v = '│', tl = '┌', tr = '┐', bl = '└', br = '┘', H = '═', V = '║', TL = '╔', TR = '╗', BL = '╚', BR = '╝', fill = '░', here = '◆' },
  retro = { h = '─', v = '│', tl = '┌', tr = '┐', bl = '└', br = '┘', H = '═', V = '║', TL = '╔', TR = '╗', BL = '╚', BR = '╝', fill = '▒', here = '♦' },
}

-- The drawing, `cols` by at most `rows` cells: { lines, marks = { { line, from, to (char columns), group } }, boxes =
-- { { x, y, w, h (cells) } } }. A terminal cell is about twice as tall as it is wide, so heights count half.
function M.layout(items, places, selected, cols, rows, retro)
  local G = retro and GLYPHS.retro or GLYPHS.plain
  local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs(places) do
    minx, miny = math.min(minx, p.x), math.min(miny, p.y)
    maxx, maxy = math.max(maxx, p.x + p.w), math.max(maxy, p.y + p.h)
  end
  local sx = (cols - 1) / math.max(1, maxx - minx)
  local sy = sx / 2
  if (maxy - miny) * sy > rows - 1 then sy = (rows - 1) / math.max(1, maxy - miny); sx = sy * 2 end
  local boxes, height = {}, 0
  for i, p in ipairs(places) do
    local x, y = math.floor((p.x - minx) * sx + 0.5), math.floor((p.y - miny) * sy + 0.5)
    -- One cell short of the next screen, so neighbours do not share a border (seen in a VM, 2026-11-16).
    local w, h = math.max(12, math.floor(p.w * sx + 0.5) - 1), math.max(5, math.floor(p.h * sy + 0.5) - 1)
    boxes[i] = { x = x, y = y, w = math.min(w, cols - x), h = h }
    height = math.max(height, y + h)
  end
  local grid = {}
  for r = 1, height do grid[r] = {}; for c = 1, cols do grid[r][c] = ' ' end end
  local marks = {}
  local function put(r, c, ch) if grid[r] and c >= 1 and c <= cols then grid[r][c] = ch end end
  local function text(r, c, s, w, group)
    local chars = vim.fn.split(s, '\\zs')
    local n = math.min(#chars, w)
    for k = 1, n do put(r, c + k - 1, chars[k]) end
    if group and n > 0 then marks[#marks + 1] = { r, c - 1, c - 1 + n, group } end
  end
  for i, b in ipairs(boxes) do
    local on = i == selected
    local h, v = on and G.H or G.h, on and G.V or G.v
    local top, bottom, left, right = b.y + 1, b.y + b.h, b.x + 1, b.x + b.w
    for c = left + 1, right - 1 do put(top, c, h); put(bottom, c, h) end
    for r = top + 1, bottom - 1 do put(r, left, v); put(r, right, v) end
    put(top, left, on and G.TL or G.tl); put(top, right, on and G.TR or G.tr)
    put(bottom, left, on and G.BL or G.bl); put(bottom, right, on and G.BR or G.br)
    marks[#marks + 1] = { top, left - 1, right, on and 'DeskScreensOn' or 'DeskScreensBox' }
    marks[#marks + 1] = { bottom, left - 1, right, on and 'DeskScreensOn' or 'DeskScreensBox' }
    local inner = b.w - 2
    local item = items[i]
    text(top + 1, left + 1, ' ' .. tostring(item.id or item.name or '?'), inner, on and 'DeskScreensOn' or 'DeskScreensName')
    -- Where the keyboard is: the editor's screen, or asked from a pop-out, that pop-out's ("this editor" was wrong there).
    if item.here then text(top + 2, left + 1, ' ' .. G.here .. ' here', inner, 'DeskScreensHere') end
    -- The pop-out where it will tile, drawn in the one chosen: the rest of the box shaded, its name in the middle.
    if on then
      local from = top + (item.here and 3 or 2)
      for r = from, bottom - 1 do for c = left + 1, right - 1 do put(r, c, G.fill) end end
      if bottom - 1 >= from then
        for r = from, bottom - 1 do marks[#marks + 1] = { r, left, right - 1, 'DeskScreensPopout' } end
        local label = ' pop-out '
        local mid = from + math.floor((bottom - 1 - from) / 2)
        text(mid, left + 1 + math.max(0, math.floor((inner - #label) / 2)), label, inner, 'DeskScreensLabel')
      end
    end
  end
  local lines = {}
  for r = 1, height do lines[r] = (table.concat(grid[r]):gsub('%s+$', '')) end
  return { lines = lines, marks = marks, boxes = boxes }
end

-- From screen `index`, the nearest one that way (h, j, k, l) by the boxes' centres, among those lying more that way than
-- across it; where none is, it stays.
function M.nav(places, index, dir)
  local here = places[index]
  if not here then return index end
  local cx, cy = here.x + here.w / 2, here.y + here.h / 2
  local best, score = index, math.huge
  for i, p in ipairs(places) do
    if i ~= index then
      local dx, dy = p.x + p.w / 2 - cx, p.y + p.h / 2 - cy
      local along, across = ({ h = -dx, l = dx, k = -dy, j = dy })[dir], (dir == 'h' or dir == 'l') and math.abs(dy) or math.abs(dx)
      -- Mostly that way, not a screen beside whose centre is a little lower ("below" went right, 2026-11-16).
      if along and along > 0 and along >= across / 2 and along + 2 * across < score then best, score = i, along + 2 * across end
    end
  end
  return best
end

-- ─── the float ─────────────────────────────────────────────────────────────────────────────────────────────────
local function highlights()
  local retro = vim.g.desk_style == 'retro'
  for name, link in pairs({ DeskScreensBox = 'FloatBorder', DeskScreensName = 'Function', DeskScreensHere = 'Comment',
    DeskScreensPopout = 'Comment', DeskScreensLabel = 'Title' }) do
    api.nvim_set_hl(0, name, { link = link, default = true })
  end
  api.nvim_set_hl(0, 'DeskScreensOn', retro and { reverse = true, default = true } or { link = 'Title', default = true })
end

-- The question, as a map; false when the items have no places (the caller asks with the list then).
function M.pick(items, opts, on_choice)
  local places = M.places(items)
  if not places then return false end
  highlights()
  opts = opts or {}
  local retro = vim.g.desk_style == 'retro'
  local cols = math.max(40, math.min(72, vim.o.columns - 8))
  local rows = math.max(8, math.min(18, vim.o.lines - 10))
  local state = { selected = 1, answered = false }
  local origin = api.nvim_get_current_win()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'wipe', 'desk-screens'
  local win
  local function answer(item, i)
    if state.answered then return end
    state.answered = true
    if win and api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    if api.nvim_win_is_valid(origin) then pcall(api.nvim_set_current_win, origin) end
    on_choice(item, i)
  end
  local function draw()
    local d = M.layout(items, places, state.selected, cols, rows, retro)
    local item = items[state.selected]
    local about = tostring(item.name or item.id or '')
    local foot = actions.voice(retro)('h/j/k/l choose · Enter pop out here · Esc')
    local lines = vim.list_extend(vim.deepcopy(d.lines), { '', ' ' .. about, ' ' .. foot })
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, m in ipairs(d.marks) do
      local line = lines[m[1]] or ''
      local from, to = vim.fn.byteidx(line, m[2]), vim.fn.byteidx(line, m[3])
      if from >= 0 then pcall(api.nvim_buf_set_extmark, buf, ns, m[1] - 1, from, { end_col = to >= 0 and to or #line, hl_group = m[4], priority = 120 }) end
    end
    pcall(api.nvim_buf_set_extmark, buf, ns, #lines - 1, 0, { end_col = #lines[#lines], hl_group = 'Comment' })
    local b = d.boxes[state.selected]
    if win and api.nvim_win_is_valid(win) then pcall(api.nvim_win_set_cursor, win, { b.y + 2, vim.fn.byteidx(lines[b.y + 2] or '', b.x + 2) }) end
    return #lines
  end
  local height = draw()
  local width = cols + 2
  win = api.nvim_open_win(buf, true, { relative = 'editor', row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)), width = width, height = height, style = 'minimal',
    border = vim.g.desk_border or 'rounded', title = ' ' .. (opts.prompt or 'Which screen') .. ' ', title_pos = 'center' })
  vim.wo[win].cursorline, vim.wo[win].wrap = false, false
  draw()
  local here = {
    move = function(dir) state.selected = M.nav(places, state.selected, dir); draw() end,
    take = function() answer(items[state.selected], state.selected) end,
    cancel = function() answer(nil, nil) end,
  }
  actions.map('screens', { buffer = buf, nowait = true, silent = true, ctx = { screens = here } })
  api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = function() vim.schedule(function() answer(nil, nil) end) end })
  M._last = { win = win, buf = buf, state = state }   -- test seam
  return true
end

-- ─── its keys ──────────────────────────────────────────────────────────────────────────────────────────────────
local function row(name, key, extra)
  extra.id, extra.group, extra.key, extra.on, extra.menu = 'screens.' .. name, 'Menu', key, 'screens', false
  return extra
end
local function move(dir) return function(ctx) ctx.screens.move(dir) end end
M.rows = actions.add({
  row('left', 'h', { name = 'The screen to the left', doc = 'The screen that way', about = 'The screen to the left; `j`, `k`, `l` the others', run = move('h') }),
  row('down', 'j', { name = 'The screen below', line = 'screens.left', run = move('j') }),
  row('up', 'k', { name = 'The screen above', line = 'screens.left', run = move('k') }),
  row('right', 'l', { name = 'The screen to the right', line = 'screens.left', run = move('l') }),
  row('left-arrow', '<Left>', { name = 'The screen to the left', line = 'screens.left', run = move('h') }),
  row('down-arrow', '<Down>', { name = 'The screen below', line = 'screens.left', run = move('j') }),
  row('up-arrow', '<Up>', { name = 'The screen above', line = 'screens.left', run = move('k') }),
  row('right-arrow', '<Right>', { name = 'The screen to the right', line = 'screens.left', run = move('l') }),
  row('take', '<CR>', { name = 'This screen', about = 'The pop-out goes on the screen chosen', run = function(ctx) ctx.screens.take() end }),
  row('take-space', '<Space>', { name = 'This screen', line = 'screens.take', run = function(ctx) ctx.screens.take() end }),
  row('cancel', '<Esc>', { name = 'Ask no more', about = 'Close the question; nothing moves', run = function(ctx) ctx.screens.cancel() end }),
  row('cancel-q', 'q', { name = 'Ask no more', line = 'screens.cancel', run = function(ctx) ctx.screens.cancel() end }),
})

return M
