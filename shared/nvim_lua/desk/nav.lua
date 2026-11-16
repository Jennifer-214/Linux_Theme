-- ALT+h/j/k/l go that way through every layer: a Neovim split, then a tmux pane, then a window or monitor. Hyprland
-- runs shared/bin/desk-nav, which asks this Neovim first (M.go over its socket) and moves the tmux pane or the
-- desktop focus only when this has no split that way. No key passes through tmux or Neovim on the way, so nothing
-- here maps ALT keys. Inside tmux this Neovim names its socket on its pane (@desk-nvim): that is how desk-nav finds it.
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
