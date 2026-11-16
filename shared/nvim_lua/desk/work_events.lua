-- One subscription per checkout; source buffers and review panes share its lifetime and attention snapshot.
local M = { roots = {}, serial = 0 }
local api, uv = vim.api, vim.uv or vim.loop
local function tool() return vim.fn.executable('desk-work') == 1 and 'desk-work' or nil end

-- What this editor is to the desk: a viewer is a Neovim desk-work started for one item (desk.work open_args; its argv
-- says so before open_args runs), a pop-out draws views another editor sends, anything else is a main editor.
function M.role()
  if vim.g.desk_popout then return 'popout' end
  if vim.g.desk_work_view then return 'viewer' end
  for _, arg in ipairs(vim.v.argv) do if arg:match('^desk%-work:') then return 'viewer' end end
  return 'main'
end
-- How it is reached, in every record it writes (desk-work editors): its own socket and its tmux pane. Inside tmux TERM
-- is tmux's or screen's; a Neovim in a kitty of its own may have inherited the pane of whatever started that kitty.
local function identity()
  local server, term, pane = vim.v.servername or '', vim.env.TERM or '', vim.env.TMUX_PANE or ''
  if server:sub(1, 1) ~= '/' or #server > 107 then server = '' end
  if not (term:match('^tmux') or term:match('^screen')) or not pane:match('^%%%d+$') then pane = '' end
  return { '--server', server, '--pane', pane, '--role', M.role() }
end

local function report(root, fields)
  if not tool() then return end
  local ok, build = pcall(require, 'desk.build')
  local argv = { tool(), 'client-report', '--client', 'nvim', '--build', ok and build.id or 'development', '--pid', 'parent', '--root', root }
  for key, value in pairs(fields) do vim.list_extend(argv, { '--' .. key, tostring(value) }) end
  vim.list_extend(argv, identity())
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
    -- One report per change of state, or a minute apart while all is well: a burst of edits is many refreshes, and
    -- each report is a locked write of the client record.
    local failed = state.error and true or false
    if failed ~= state.reported_error or os.time() - (state.reported_at or 0) >= 60 then
      state.reported_error, state.reported_at = failed, os.time()
      report(root, failed and { error = 'Could not refresh work records' } or { ['refresh-at'] = os.time(), error = '' })
    end
    for _, callback in pairs(state.callbacks) do pcall(callback, state.items, state.error) end
    api.nvim_exec_autocmds('User', { pattern = 'FoxWorkChanged', data = { root = root, revision = state.revision or '' } })
    pcall(vim.cmd.redrawstatus)
    if state.again then state.again = false; refresh(root, state) end
  end))
end

-- A burst of events (an agent saving file after file) is one refresh a second at most, and the last event is always
-- read: the first refreshes at once; any within the next second share one refresh at its end.
local function soon(root, state)
  if state.queued then return end
  local function go()
    state.refreshed_at = uv.now()
    if state.reading then state.again = true else refresh(root, state) end
  end
  local wait = (state.refreshed_at or 0) + 1000 - uv.now()
  if wait <= 0 then return go() end
  state.queued = true
  state.pace:start(wait, 0, vim.schedule_wrap(function()
    state.queued = false
    if M.roots[root] == state then go() end
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
  local ok, build = pcall(require, 'desk.build')
  local loaded = ok and build.id or 'development'
  local argv = vim.list_extend({ tool(), 'watch', '--root', root, '--client', 'nvim', '--build', loaded }, identity())
  local ok, job = pcall(vim.system, argv, { text = true, stdout = vim.schedule_wrap(function(_, data)
    if M.roots[root] ~= state or not data then return end
    state.pending = state.pending .. data
    if #state.pending > 65536 then state.pending = ''; return end
    while state.pending:find('\n', 1, true) do
      local line, rest = state.pending:match('^(.-)\n(.*)$'); state.pending = rest
      local valid, event = pcall(vim.json.decode, line)
      if valid and type(event) == 'table' and event.version == 1 then
        -- The watcher itself reports the connection and event times (no second report per event from here).
        state.revision, state.watch_failed, state.delay = event.revision, false, 1000
        soon(root, state)
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
    state = { callbacks = {}, items = {}, pending = '', timer = uv.new_timer(), retry = uv.new_timer(), pace = uv.new_timer(), delay = 1000 }
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
    state.pace:stop(); state.pace:close()
    if state.job then pcall(state.job.kill, state.job, 15) end
    if state.request and state.reading then pcall(state.request.kill, state.request, 15) end
  end
end

function M.signal(root)
  if tool() and root then vim.system({ tool(), 'signal', '--root', root }, { text = true, timeout = 2000 }, function() end) end
end

-- The newest test run of each checkout, for the status line. desk-work is asked in the background only (BufEnter,
-- FocusGained, a work change, every 10 s while focused); drawing the status line reads the copy kept per root.
local tests = { runs = {}, focused = true }
-- Every label of a style is padded to that style's widest one, so a run starting or ending does not move the line.
local LABELS = {
  retro = { passed = '√ %3d', failed = '%3d FAILED', running = '☼ RUNNING', interrupted = '! STOPPED',
            any_passed = '√ PASSED', any_failed = '! FAILED', width = 10 },
  shapes = { passed = '✓ %3d', failed = '✗ %3d failed', running = '◷ running', interrupted = '! stopped',
             any_passed = '✓ passed', any_failed = '✗ failed', width = 12 },
}

-- run: what `desk-work tests` printed (decoded); retro: the DOS marks and capitals.
function M.test_label(run, retro)
  if type(run) ~= 'table' then return '' end
  local marks = LABELS[retro and 'retro' or 'shapes']
  local counts = type(run.tests) == 'table' and run.tests or {}
  local passed = type(counts.passed) == 'number' and counts.passed or nil
  local failed = type(counts.failed) == 'number' and counts.failed > 0 and counts.failed or nil
  local text
  if run.state == 'running' then text = marks.running
  elseif run.state == 'passed' then text = passed and marks.passed:format(passed) or marks.any_passed
  elseif run.state == 'failed' then text = failed and marks.failed:format(failed) or marks.any_failed
  elseif run.state == 'interrupted' then text = marks.interrupted
  else return '' end
  return string.rep(' ', marks.width - api.nvim_strwidth(text)) .. text
end

local function current_root()
  local root = vim.fs.root(0, '.git')
  return root and (uv.fs_realpath(root) or root)
end

local function read_tests(root, min_age)
  local entry = tests.runs[root]
  if not entry then entry = {}; tests.runs[root] = entry end
  if entry.reading then entry.again = entry.again or min_age == 0; return end   -- a change during a read: once more
  if (entry.at and uv.now() - entry.at < (min_age or 0)) or not tool() then return end
  entry.reading, entry.at = true, uv.now()
  local ok = pcall(vim.system, { tool(), 'tests', '--root', root }, { text = true, timeout = 3000 }, vim.schedule_wrap(function(out)
    entry.reading = false
    local valid, run = pcall(vim.json.decode, out.stdout or '')
    if out.code == 0 and valid then   -- a slow or failed read keeps what was shown
      run = type(run) == 'table' and run or false
      if not vim.deep_equal(run, entry.run) then entry.run = run; pcall(vim.cmd.redrawstatus) end
    end
    if entry.again then entry.again = false; read_tests(root, 0) end
  end))
  if not ok then entry.reading = false end
end

local function start_tests()
  if not tool() then return end   -- without desk-work nothing is ever started
  local group = api.nvim_create_augroup('DeskTestStatus', { clear = true })
  local function front(min_age) local root = current_root(); if root then read_tests(root, min_age) end end
  api.nvim_create_autocmd('BufEnter', { group = group, callback = function() front(2000) end })
  api.nvim_create_autocmd('FocusGained', { group = group, callback = function() tests.focused = true; front(0) end })
  api.nvim_create_autocmd('FocusLost', { group = group, callback = function() tests.focused = false end })
  api.nvim_create_autocmd('User', { group = group, pattern = 'FoxWorkChanged', callback = function(event)
    local root = type(event.data) == 'table' and event.data.root
    if type(root) == 'string' and tests.runs[root] then read_tests(root, 0) end
  end })
  tests.timer = uv.new_timer()
  tests.timer:start(10000, 10000, vim.schedule_wrap(function() if tests.focused then front(9000) end end))
  front(0)
end

-- The status line part: '' until a run is known (and always without desk-work, outside a checkout, or in the pop-out,
-- which watches nothing of its own).
function M.tests_status(retro)
  if vim.g.desk_popout then return '' end
  if not tests.started then tests.started = true; vim.schedule(start_tests) end
  local root = current_root()
  local entry = root and tests.runs[root]
  return entry and entry.run and M.test_label(entry.run, retro) or ''
end

-- The newest run's state for the buffer in front (colours the status line part), or nil.
function M.tests_state()
  local root = current_root()
  local entry = root and tests.runs[root]
  return entry and entry.run and entry.run.state or nil
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
