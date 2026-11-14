-- One subscription per checkout; source buffers and review panes share its lifetime and attention snapshot.
local M = { roots = {}, serial = 0 }
local api, uv = vim.api, vim.uv or vim.loop
local function tool() return vim.fn.executable('desk-work') == 1 and 'desk-work' or nil end
local function report(root, fields)
  if not tool() then return end
  local ok, build = pcall(require, 'foxml.build')
  local argv = { tool(), 'client-report', '--client', 'nvim', '--build', ok and build.id or 'development', '--pid', 'parent', '--root', root }
  for key, value in pairs(fields) do vim.list_extend(argv, { '--' .. key, tostring(value) }) end
  pcall(vim.system, argv, { text = true, timeout = 2000 }, function() end)
end

local function refresh(root, state)
  if M.roots[root] ~= state or state.reading then return end
  state.reading = true
  state.request = vim.system({ tool(), 'attention', '--root', root }, { text = true, timeout = 5000 }, vim.schedule_wrap(function(out)
    if M.roots[root] ~= state then return end
    state.reading = false
    local ok, items = pcall(vim.json.decode, out.stdout or '')
    if out.code == 0 and ok and type(items) == 'table' and vim.islist(items) then state.items, state.error = items, false
    else state.error = true end
    report(root, state.error and { error = 'Could not refresh work records' } or { ['refresh-at'] = os.time(), error = '' })
    for _, callback in pairs(state.callbacks) do pcall(callback, state.items, state.error) end
    api.nvim_exec_autocmds('User', { pattern = 'FoxWorkChanged', data = { root = root, revision = state.revision or '' } })
    pcall(vim.cmd.redrawstatus)
    if state.again then state.again = false; refresh(root, state) end
  end))
end

local function watch(root, state)
  if M.roots[root] ~= state then return end
  state.pending = ''
  local function ended()
    vim.schedule(function()
      if M.roots[root] ~= state then return end
      state.watch_failed = true
      report(root, { stream = 'retrying', ['retry-at'] = os.time() + math.ceil(state.delay / 1000) })
      state.retry:start(state.delay, 0, vim.schedule_wrap(function() watch(root, state) end))
      state.delay = math.min(state.delay * 2, 30000)
      pcall(vim.cmd.redrawstatus)
    end)
  end
  local ok, build = pcall(require, 'foxml.build')
  local loaded = ok and build.id or 'development'
  local ok, job = pcall(vim.system, { tool(), 'watch', '--root', root, '--client', 'nvim', '--build', loaded }, { text = true, stdout = vim.schedule_wrap(function(_, data)
    if M.roots[root] ~= state or not data then return end
    state.pending = state.pending .. data
    if #state.pending > 65536 then state.pending = ''; return end
    while state.pending:find('\n', 1, true) do
      local line, rest = state.pending:match('^(.-)\n(.*)$'); state.pending = rest
      local valid, event = pcall(vim.json.decode, line)
      if valid and type(event) == 'table' and event.version == 1 then
        state.revision, state.watch_failed, state.delay = event.revision, false, 1000
        report(root, { stream = 'connected', ['event-at'] = os.time(), ['retry-at'] = 0 })
        if state.reading then state.again = true else refresh(root, state) end
      end
    end
  end) }, ended)
  if ok then state.job = job else ended() end
end

function M.subscribe(root, callback)
  if not tool() or not root or root == '' then return function() end end
  root = uv.fs_realpath(root) or root
  local state = M.roots[root]
  if not state then
    state = { callbacks = {}, items = {}, pending = '', timer = uv.new_timer(), retry = uv.new_timer(), delay = 1000 }
    M.roots[root] = state
    watch(root, state)
    -- Git commands and older agent integrations may not publish yet; polling remains a recovery path.
    state.timer:start(20000, 20000, vim.schedule_wrap(function() refresh(root, state) end))
  end
  M.serial = M.serial + 1
  local id = M.serial
  state.callbacks[id] = callback or function() end
  return function()
    if M.roots[root] ~= state then return end
    state.callbacks[id] = nil
    if next(state.callbacks) then return end
    M.roots[root] = nil
    report(root, { stream = 'stopped', ['retry-at'] = 0 })
    state.timer:stop(); state.timer:close()
    state.retry:stop(); state.retry:close()
    if state.job then pcall(state.job.kill, state.job, 15) end
    if state.request and state.reading then pcall(state.request.kill, state.request, 15) end
  end
end

function M.signal(root)
  if tool() and root then vim.system({ tool(), 'signal', '--root', root }, { text = true, timeout = 2000 }, function() end) end
end

function M.status()
  local root = vim.fs.root(0, '.git')
  local state = root and M.roots[uv.fs_realpath(root) or root]
  if not state then return '' end
  if state.watch_failed then return 'work updates delayed' end
  if state.error then return 'work status unavailable' end
  return #state.items > 0 and (#state.items .. (#state.items == 1 and ' needs you' or ' need you')) or ''
end

return M
