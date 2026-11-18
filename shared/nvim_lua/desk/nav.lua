-- Jump labels and navigation to the working code window from desk views.
local M = {}
local api = vim.api

-- ─── jump labels on a view ─────────────────────────────────────────────────────────────────────────────────────
-- s in the review's file list and in the call graph: flash.nvim's labels on the rows or boxes on screen, drawn as
-- the code's s draws its labels; typing one picks it. Flash is optional: without it the key says what it needs.
function M.flash() return package.loaded.flash ~= nil or (pcall(require, 'flash')) end
function M.labels_ready() return M.flash() or 'requires flash.nvim' end

-- Labels for n targets from flash's label characters: one each while they last, else two, the first picking a group
-- and the second its target. Past two letters' worth a target gets none. Pure.
function M.label_list(n, chars)
  local out, k = {}, #chars
  for i = 1, n do
    if n <= k then out[i] = { chars[i] }
    else
      local first, second = chars[math.floor((i - 1) / k) + 1], chars[(i - 1) % k + 1]
      out[i] = first and { first, second } or false
    end
  end
  return out
end

M.drawn = {}   -- the labels of the last jump, a list per letter typed ({ line, col, label }), for the tests

-- Labels on targets ({ line (1-based), col (0-based byte) } in win, any order); pick(target) for the one typed. Esc,
-- or a key that is no label, picks nothing. false when flash is not there.
function M.jump(win, targets, pick)
  local found, Flash = pcall(require, 'flash')
  if not found then
    vim.notify('Requires flash.nvim (an optional plugin): its labels are the ones s draws in code.', vim.log.levels.WARN, { title = 'Jump labels' })
    return false
  end
  M.drawn = {}
  local function draw(matches)
    local stage = {}
    for _, m in ipairs(matches) do
      if m.label then stage[#stage + 1] = { line = m.pos[1], col = m.pos[2], label = m.label .. (m.second or '') } end
    end
    M.drawn[#M.drawn + 1] = stage
  end
  local function run(items, labeler)
    Flash.jump({
      search = { multi_window = false, max_length = false, incremental = false },
      jump = { pos = 'range' },   -- a label shows on the cursor's own row too
      label = { before = { 0, 0 }, after = false, style = 'overlay', format = function(o)
        local text = { { o.match.label, o.hl_group } }
        if o.match.second then text[2] = { o.match.second, 'FlashMatch' } end
        return text
      end },
      highlight = { matches = false },
      matcher = function(w, state)
        if w ~= win or state.pattern() ~= '' then return {} end   -- a key that is no label: nothing left, it ends
        return vim.tbl_map(function(item)
          return { pos = { item.target.line, item.target.col }, end_pos = { item.target.line, item.target.col }, item = item }
        end, items)
      end,
      labeler = labeler,
      action = function(match, state)
        if not match.second then pick(match.item.target); return end
        -- The first of two letters: the targets it labelled, each by its second letter.
        state:hide()
        local group = {}
        for _, m in ipairs(state.results) do
          if m.label == match.label then group[#group + 1] = { target = m.item.target, label = m.second } end
        end
        run(group, function(matches)
          for _, m in ipairs(matches) do m.label, m.second = m.item.label, nil end
          draw(matches)
        end)
      end,
    })
  end
  -- Esc ends the labels and nothing else. Flash hands the Esc that ended them on to the view (vim.api.nvim_input),
  -- where Esc can mean more: the review's list hides on it. While the labels show, that Esc is not passed on.
  local input = api.nvim_input
  api.nvim_input = function(keys)
    if type(keys) == 'string' and keys:lower() == '<esc>' then return #keys end
    return input(keys)
  end
  local ok, err = pcall(run, vim.tbl_map(function(t) return { target = t } end, targets), function(matches, state)
    local labels = M.label_list(#matches, state:labels())
    for i, m in ipairs(matches) do
      m.label, m.second = labels[i] and labels[i][1] or false, labels[i] and labels[i][2] or nil
    end
    draw(matches)
  end)
  api.nvim_input = input
  if not ok then error(err, 0) end
  return true
end

local set = false
-- ─── where code opens (one home: the map, the call graph, plan marks and answer pages all go through here) ────────
-- A code window: a plain file window, not a float, not in a view's tab (the review marks its tab, vim.t.desk_view) and
-- not a view's own window (vim.w.desk_view).
function M.code_window(win)
  if not (win and api.nvim_win_is_valid(win)) or api.nvim_win_get_config(win).relative ~= '' then return false end
  if vim.w[win].desk_view ~= nil then return false end
  if vim.t[api.nvim_win_get_tabpage(win)].desk_view ~= nil then return false end
  return vim.bo[api.nvim_win_get_buf(win)].buftype == ''
end

-- The code windows she was in, newest last, any tab (kept by M.setup's WinEnter). A list, not one: a view's new tab
-- is a plain window for a moment before it is marked, and must not push her code window out.
M.recent = {}
function M.remember_code()
  local win = api.nvim_get_current_win()
  if not M.code_window(win) then return end
  for i = #M.recent, 1, -1 do if M.recent[i] == win or not api.nvim_win_is_valid(M.recent[i]) then table.remove(M.recent, i) end end
  M.recent[#M.recent + 1] = win
  while #M.recent > 16 do table.remove(M.recent, 1) end
end
function M.last_code()
  for i = #M.recent, 1, -1 do if M.code_window(M.recent[i]) then return M.recent[i] end end
end

-- The window code opens in: prefer when it is a code window, else this one, else the first in this tab, else the last
-- one she was in (its tab comes forward), else a new tab. Never a view's window: opening there replaced the review's
-- list (2026-11-16). Makes it the current window and returns it.
function M.code_target(prefer)
  local pick
  if M.code_window(prefer) then pick = prefer
  elseif M.code_window(api.nvim_get_current_win()) then pick = api.nvim_get_current_win()
  else
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do if not pick and M.code_window(win) then pick = win end end
    pick = pick or M.last_code()
  end
  if pick then api.nvim_set_current_win(pick) else vim.cmd('tabnew'); pick = api.nvim_get_current_win() end
  return pick
end

-- Opens path (or buffer buf) at line (1-based) and col (0-based; default: the line's first text) in M.code_target.
-- true, or false and why.
function M.open_code(where, line, col, prefer)
  M.code_target(prefer)
  if type(where) == 'number' then
    if not api.nvim_buf_is_valid(where) then return false, 'that buffer is gone' end
    api.nvim_win_set_buf(0, where)
  elseif api.nvim_buf_get_name(0) ~= vim.fn.fnamemodify(where, ':p') then
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(where))
    if not ok then return false, tostring(err) end
  end
  if line then
    line = math.max(1, math.min(tonumber(line) or 1, api.nvim_buf_line_count(0)))
    local text = api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ''
    pcall(api.nvim_win_set_cursor, 0, { line, col or math.max(0, (text:find('%S') or 1) - 1) })
  end
  return true
end

function M.setup()
  if set then return end
  set = true
  api.nvim_create_autocmd({ 'WinEnter', 'BufWinEnter' }, { group = api.nvim_create_augroup('desk_nav_code', { clear = true }),
    callback = M.remember_code })
end

return M
