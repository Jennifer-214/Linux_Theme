-- ALT+h/j/k/l go that way through every layer: a Neovim split, then a tmux pane, then a window or monitor. Hyprland
-- runs shared/bin/desk-nav, which asks this Neovim first (M.go over its socket) and moves the tmux pane or the
-- desktop focus only when this has no split that way. No key passes through tmux or Neovim on the way, so nothing
-- here maps ALT keys. Inside tmux this Neovim names its socket on its pane (@desk-nvim): that is how desk-nav finds it.
-- Moving within a view is here too: the jump labels (s) of the review's file list and the call graph (M.jump).
local M = {}
local api = vim.api

-- Moves to the split that way (h, j, k or l) when there is one: 1 when it moved, 0 when the key goes on to tmux and
-- the desktop. A float (a picker, a menu) has no split beside it: the key goes on from there too.
function M.go(dir)
  if dir ~= 'h' and dir ~= 'j' and dir ~= 'k' and dir ~= 'l' then return 0 end
  if api.nvim_win_get_config(0).relative ~= '' then return 0 end
  if vim.fn.winnr(dir) == vim.fn.winnr() then return 0 end
  vim.cmd('wincmd ' .. dir)
  return 1
end

-- The pane and socket desk-nav reads: nil outside tmux, or with no socket to name.
function M.pane()
  local pane, server, term = vim.env.TMUX_PANE or '', vim.v.servername or '', vim.env.TERM or ''
  if (vim.env.TMUX or '') == '' or not pane:match('^%%%d+$') or server:sub(1, 1) ~= '/' then return nil end
  if not (term:match('^tmux') or term:match('^screen')) then return nil end   -- a kitty of its own, started from tmux
  return pane, server
end

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
function M.setup()
  if set then return end
  set = true
  local pane, server = M.pane()
  if not pane or vim.fn.executable('tmux') ~= 1 then return end
  pcall(vim.system, { 'tmux', 'set-option', '-p', '-t', pane, '@desk-nvim', server }, { text = true })
  api.nvim_create_autocmd('VimLeavePre', { callback = function()
    pcall(vim.system, { 'tmux', 'set-option', '-p', '-u', '-t', pane, '@desk-nvim' }, { detach = true })
  end })
end

return M
