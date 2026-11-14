-- Project resume positions; editor persistence continues to own its full session layout.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
local function inside(path, root) return path:sub(1, #root + 1) == root .. '/' end
local function call(args, input)
  if vim.fn.executable('desk-work') ~= 1 then return nil end
  local out = vim.system(vim.list_extend({ 'desk-work' }, args), { text = true, stdin = input, timeout = 3000 }):wait()
  local ok, value = pcall(vim.json.decode, out.stdout or '')
  return out.code == 0 and ok and value or nil
end
function M.save(quiet)
  local root = vim.fs.root(0, '.git') or vim.fs.root(vim.fn.getcwd(), '.git')
  if not root then return end
  root = uv.fs_realpath(root) or root
  local tabs, active = {}, 1
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    local positions = {}
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      local buf = api.nvim_win_get_buf(win)
      local path = uv.fs_realpath(api.nvim_buf_get_name(buf))
      if path and inside(path, root) and vim.bo[buf].buftype == '' and not vim.b[buf].desk_review then
        positions[#positions + 1] = { file = path:sub(#root + 2), cursor = api.nvim_win_get_cursor(win) }
      end
    end
    if #positions > 0 then
      tabs[#tabs + 1] = positions
      if tab == api.nvim_get_current_tabpage() then active = #tabs end
    end
  end
  if #tabs == 0 then return end
  local result = call({ 'workspace', '--root', root, '--client', 'nvim', '--input', '-' },
    vim.json.encode({ version = 1, tabs = tabs, activeTab = active }))
  if not quiet then vim.notify(result and result.ok and 'Project place saved.' or 'Could not save this project place.') end
end
function M.resume(project)
  local root = project or vim.fs.root(0, '.git') or vim.fs.root(vim.fn.getcwd(), '.git')
  if not root then
    local projects = call({ 'workspace-list', '--client', 'nvim' }) or {}
    vim.ui.select(projects, { prompt = 'Resume project or worktree', format_item = function(item) return item.project .. ' · ' .. item.root end },
      function(item) if item then M.resume(item.root) end end)
    return false
  end
  root = uv.fs_realpath(root) or root
  local view = call({ 'workspace', '--root', root, '--client', 'nvim' })
  if type(view) ~= 'table' or view.version ~= 1 or type(view.tabs) ~= 'table' then vim.notify('No saved project place.'); return false end
  local restored = {}
  -- Open in new tabs. No existing editor, terminal or agent window is closed to make room.
  for _, positions in ipairs(view.tabs) do
    if type(positions) == 'table' and #restored < 30 then
      local tab
      for _, position in ipairs(positions) do
        local file = type(position) == 'table' and type(position.file) == 'string' and uv.fs_realpath(root .. '/' .. position.file) or nil
        if file and inside(file, root) and vim.fn.filereadable(file) == 1 then
          if tab then vim.cmd('vsplit') else vim.cmd('tabnew'); tab = api.nvim_get_current_tabpage(); restored[#restored + 1] = tab; vim.cmd('tcd ' .. vim.fn.fnameescape(root)) end
          vim.cmd('edit ' .. vim.fn.fnameescape(file))
          local cursor = position.cursor
          if type(cursor) == 'table' and tonumber(cursor[1]) then pcall(api.nvim_win_set_cursor, 0,
            { math.max(1, math.min(tonumber(cursor[1]), api.nvim_buf_line_count(0))), math.max(0, tonumber(cursor[2]) or 0) }) end
          if #api.nvim_tabpage_list_wins(tab) >= 8 then break end
        end
      end
    end
  end
  local tab = restored[tonumber(view.activeTab) or 1]
  if tab then api.nvim_set_current_tabpage(tab) end
  vim.notify(#restored > 0 and 'Project place restored. Existing windows were kept.' or 'The saved files are no longer available.')
  return #restored > 0
end
function M.setup()
  api.nvim_create_user_command('WorkSave', function() M.save() end, {})
  api.nvim_create_user_command('WorkResume', function() M.resume() end, {})
  api.nvim_create_autocmd('VimLeavePre', { group = api.nvim_create_augroup('foxml_workspace', { clear = true }), callback = function() pcall(M.save, true) end })
end
return M
