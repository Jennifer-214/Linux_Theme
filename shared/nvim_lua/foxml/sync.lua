-- Watch only directories of loaded files; never replace an unsaved buffer on a disk event.
local M = { buffers = {}, watchers = {} }
local api, uv = vim.api, vim.uv or vim.loop
local limit = 2 * 1024 * 1024
local function notify(text, level) vim.notify(text, level or vim.log.levels.INFO, { title = 'Outside edits' }) end
local function read(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= 'file' or stat.size > limit then return nil end
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read('*a'); f:close()
  if text:find('\0', 1, true) then return nil end
  return text
end
local function contents(buf)
  local separator = vim.bo[buf].fileformat == 'dos' and '\r\n' or '\n'
  return (vim.bo[buf].bomb and '\239\187\191' or '')
    .. table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), separator)
    .. (vim.bo[buf].endofline and separator or '')
end
local function refresh_time(buf) pcall(vim.cmd, 'silent checktime ' .. buf) end
local function waiting(state, disk)
  local changed = not state.pending or state.pending.text ~= disk
  state.pending = { text = disk }
  if changed then notify(vim.fs.basename(state.path) .. ': outside edits waiting · click the status to review', vim.log.levels.WARN) end
end

function M.check(buf)
  local state = M.buffers[buf]
  if not state or not api.nvim_buf_is_loaded(buf) then return end
  if vim.fn.getcmdwintype() ~= '' or vim.fn.mode():match('^c') then return end
  local disk = read(state.path)
  if disk == state.base then
    state.pending = nil; return
  end
  if disk and disk == contents(buf) then
    state.base, state.pending = disk, nil; refresh_time(buf); return
  end
  if disk and not vim.bo[buf].modified then
    local views = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      views[win] = api.nvim_win_call(win, vim.fn.winsaveview)
    end
    refresh_time(buf)
    local current = M.buffers[buf]
    if current then
      if contents(buf) == disk then current.base, current.pending, current.updated = disk, nil, uv.now()
      else waiting(current, disk) end
    end
    for win, view in pairs(views) do
      if api.nvim_win_is_valid(win) then api.nvim_win_call(win, function() vim.fn.winrestview(view) end) end
    end
  else
    waiting(state, disk)
  end
  pcall(vim.cmd.redrawstatus)
end

function M.detach(buf)
  local state = M.buffers[buf]
  if not state then return end
  M.buffers[buf] = nil
  local watch = M.watchers[state.dir]
  if not watch then return end
  watch.buffers[buf] = nil
  if next(watch.buffers) == nil then
    watch.handle:stop(); watch.handle:close()
    watch.timer:stop(); watch.timer:close()
    M.watchers[state.dir] = nil
  end
end

function M.track(buf, reset)
  if not api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= '' or not vim.bo[buf].buflisted then return end
  local path = api.nvim_buf_get_name(buf)
  if path == '' or path:match('^%a[%w+.-]*://') then return end
  local old = M.buffers[buf]
  if old and old.path == path and not reset then return M.check(buf) end
  M.detach(buf)
  local dir = vim.fs.dirname(path)
  local state = { path = path, dir = dir, base = read(path) }
  M.buffers[buf] = state
  local watch = M.watchers[dir]
  if not watch then
    watch = { handle = uv.new_fs_event(), timer = uv.new_timer(), buffers = {} }
    M.watchers[dir] = watch
    local ok = watch.handle:start(dir, {}, function(err)
      if err or watch.timer:is_closing() then return end
      watch.timer:stop()
      watch.timer:start(150, 0, vim.schedule_wrap(function()
        if M.watchers[dir] ~= watch then return end
        for target in pairs(watch.buffers) do M.check(target) end
      end))
    end)
    if not ok then watch.handle:close(); watch.timer:close(); M.watchers[dir] = nil; return end
  end
  watch.buffers[buf] = true
end

function M.status()
  local state = M.buffers[api.nvim_get_current_buf()]
  if not state then return '' end
  if state.pending then return 'outside edits · click to review' end
  return state.updated and uv.now() - state.updated < 5000 and 'updated externally' or ''
end

function M.compare()
  local buf = api.nvim_get_current_buf()
  M.check(buf)
  local state = M.buffers[buf]
  if not state or not state.pending then notify('No outside edits are waiting for this file.'); return end
  if not state.pending.text then notify('The disk file was removed, unreadable, binary or too large. Your buffer was kept.'); return end
  local root = vim.fs.root(state.path, '.git') or state.dir
  require('foxml.claude').open_review({ kind = 'external', short = 'outside edits', name = 'outside edits',
    sid = 'external-' .. vim.fn.sha256(state.path), files = { state.path },
    before_label = 'Your unsaved buffer', after_label = 'Current disk copy',
    snapshots = { [state.path] = { contents(buf), state.pending.text } } }, root)
end

function M.merge()
  local buf = api.nvim_get_current_buf()
  M.check(buf)
  local state = M.buffers[buf]
  if not state or not state.pending then notify('No outside edits are waiting for this file.'); return end
  local disk, mine = state.pending.text, contents(buf)
  if not disk or not state.base then notify('A shared text baseline is unavailable; Space Cu compares the copies.'); return end
  local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p', tonumber('700', 8))
  for name, text in pairs({ mine = mine, base = state.base, disk = disk }) do
    local f = assert(io.open(dir .. '/' .. name, 'wb')); f:write(text); f:close()
  end
  local ok, job = pcall(vim.system, { 'git', 'merge-file', '-p', dir .. '/mine', dir .. '/base', dir .. '/disk' }, { text = false })
  local result = ok and job:wait(3000) or {}
  for _, name in ipairs({ 'mine', 'base', 'disk' }) do uv.fs_unlink(dir .. '/' .. name) end
  uv.fs_rmdir(dir)
  if result.code ~= 0 then notify('The edits overlap. Both copies were kept; Space Cu opens the comparison.', vim.log.levels.WARN); return end
  if contents(buf) ~= mine or read(state.path) ~= disk then notify('The file changed again; retry the merge.'); return end
  refresh_time(buf)
  local merged = result.stdout or ''
  local separator = vim.bo[buf].fileformat == 'dos' and '\r\n' or '\n'
  if vim.bo[buf].bomb then merged = merged:gsub('^\239\187\191', '') end
  local eol = merged:sub(-#separator) == separator
  if eol then merged = merged:sub(1, -#separator - 1) end
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(merged, separator, { plain = true }))
  vim.bo[buf].endofline = eol
  state.base, state.pending, state.updated = disk, nil, uv.now()
  notify('Outside changes merged with your edits · buffer is unsaved · u undoes the merge')
end

function M.keep()
  local buf = api.nvim_get_current_buf()
  local state = M.buffers[buf]
  if not state or not state.pending then return end
  refresh_time(buf)
  state.base, state.pending = read(state.path), nil
  notify('Your buffer was kept. Its next save will replace the disk copy.')
end

function M.menu()
  local choices = {
    { name = 'Compare copies', label = 'Compare copies — See your unsaved buffer beside the current disk copy.', bind = '<leader>Cu', run = M.compare },
    { name = 'Merge separate edits', label = 'Merge separate edits — Combine non-overlapping edits without saving. Overlaps keep both copies.',
      bind = '<leader>Cl', writes = 'code', run = M.merge },
    { name = 'Keep my buffer', label = 'Keep my buffer — Your next save will replace the disk copy with your version.', run = M.keep },
  }
  require('foxml.review').show_menu(choices, { title = 'Outside edits', anchor_win = api.nvim_get_current_win(), memo = 'foxml-outside-edits' })
end

function M.setup()
  local group = api.nvim_create_augroup('foxml_live_files', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost' }, { group = group, callback = function(a) M.track(a.buf, true) end })
  api.nvim_create_autocmd({ 'BufEnter', 'BufFilePost' }, { group = group, callback = function(a) M.track(a.buf) end })
  api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, { group = group, callback = function(a) M.detach(a.buf) end })
  api.nvim_create_autocmd({ 'FocusGained', 'CursorHold', 'CmdlineLeave' }, { group = group, callback = function()
    for buf in pairs(M.buffers) do M.check(buf) end
  end })
  api.nvim_create_autocmd('FileChangedShell', { group = group, callback = function(a)
    if M.buffers[a.buf] then
      vim.v.fcs_choice = ''
      vim.schedule(function() M.check(a.buf) end)
    else vim.v.fcs_choice = 'ask' end
  end })
  api.nvim_create_autocmd('BufWritePre', { group = group, callback = function(a)
    M.check(a.buf)
    local state = M.buffers[a.buf]
    if state and state.pending then error('Outside edits are waiting. Space Cu compares, Space Cl merges, :AgentKeepMine explicitly keeps yours.') end
  end })
  api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function()
    local buffers = vim.tbl_keys(M.buffers)
    for _, buf in ipairs(buffers) do M.detach(buf) end
  end })
  for _, buf in ipairs(api.nvim_list_bufs()) do M.track(buf) end
  api.nvim_create_user_command('AgentChanges', M.compare, { desc = 'Compare your buffer with outside edits' })
  api.nvim_create_user_command('AgentMerge', M.merge, { desc = 'Merge non-overlapping outside edits without saving' })
  api.nvim_create_user_command('AgentKeepMine', M.keep, { desc = 'Keep your buffer; the next save replaces the disk copy' })
  vim.keymap.set('n', '<leader>Cu', M.compare, { desc = 'Compare waiting outside edits' })
  vim.keymap.set('n', '<leader>Cl', M.merge, { desc = 'Merge non-overlapping outside edits' })
end

return M
