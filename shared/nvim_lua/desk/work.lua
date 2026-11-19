local M = {}
-- What a refused call says: desk-work's own message (it answers JSON on stdout), else its error output, else which
-- command refused. A blank notice tells nobody anything.
function M.refusal(args, out)
  local ok, value = pcall(vim.json.decode, out.stdout or '')
  if ok and type(value) == 'table' and type(value.message) == 'string' and vim.trim(value.message) ~= '' then return vim.trim(value.message) end
  local said = vim.trim(out.stderr or ''):match('([^\n]*)$') or ''
  if said ~= '' then return said end
  return 'desk-work ' .. (args[1] or '') .. ' did not answer (exit ' .. tostring(out.code) .. ')'
end
-- Quick reads and writes (a task, a log): short enough to wait for.
local function run(args)
  local argv = { "desk-work" }
  vim.list_extend(argv, args)
  local ok, p = pcall(vim.system, argv, { text = true })
  if not ok then vim.notify('desk-work did not start; is it installed?', vim.log.levels.WARN); return nil end
  local out = p:wait(15000)
  if out.code ~= 0 then vim.notify(M.refusal(args, out), vim.log.levels.WARN); return nil end
  return out.stdout
end
local function data(args)
  local ok, j = pcall(vim.json.decode, run(args) or "null")
  return ok and j ~= vim.NIL and j or nil
end
-- Slow calls (health, backups, recovery, repair) run in the background. `done` gets the decoded answer (nil after a
-- refusal, which is shown) only while its call is the newest of its kind: a refresh pressed twice shows the second
-- answer, never the first arriving late.
local newest = {}
local function call(kind, args, done)
  newest[kind] = (newest[kind] or 0) + 1
  local mine = newest[kind]
  local ok = pcall(vim.system, vim.list_extend({ 'desk-work' }, args), { text = true, timeout = 120000 }, vim.schedule_wrap(function(out)
    if newest[kind] ~= mine then return end
    local parsed, value = pcall(vim.json.decode, out.stdout or '')
    if out.code ~= 0 or not parsed or value == vim.NIL then
      vim.notify(M.refusal(args, out), vim.log.levels.WARN); return done(nil)
    end
    done(value)
  end))
  if not ok then vim.notify('desk-work did not start; is it installed?', vim.log.levels.WARN); done(nil) end
end
local function fill(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end
local function root() return vim.fs.root(0, ".git") or vim.fn.getcwd() end
local function scratch(text, name, ft, editable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, name .. " · " .. buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split((text or ""):gsub("\n$", ""), "\n", { plain = true }))
  vim.bo[buf].filetype = ft or "text"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = editable or false
  return buf
end
-- A view in a new tab: the tab's own empty buffer goes, so closing the view leaves no [No Name] behind.
local function tab_scratch(text, name, ft)
  vim.cmd.tabnew()
  local empty = vim.api.nvim_get_current_buf()
  local buf = scratch(text, name, ft)
  if empty ~= buf and vim.api.nvim_buf_get_name(empty) == '' and not vim.bo[empty].modified then pcall(vim.api.nvim_buf_delete, empty, { force = true }) end
  return buf
end

-- API tasks (claude-api): read-only reviews on API credits, with a model choice, live progress,
-- follow-ups and results whose path:line citations become a quickfix list.
local api_job
local function api_projects()
  local ok, out = pcall(function() return vim.system({'claude-api', 'projects'}, {text=true}):wait(5000) end)
  local parsed, projects = pcall(vim.json.decode, ok and out.stdout or '')
  return parsed and type(projects) == 'table' and projects or nil
end
local function inside(dir, project) return dir == project.root or dir:sub(1, #project.root+1) == project.root .. '/' end

-- path:line citations in an answer → quickfix items, resolved against the task's folder.
function M.api_citations(lines, folder)
  local items, seen = {}, {}
  for _, line in ipairs(lines) do
    for path, lnum in line:gmatch('([%w%._%-/~]+%.[%w]+):(%d+)') do
      local full = path:sub(1, 1) == '/' and path or (folder .. '/' .. path)
      local key = full .. ':' .. lnum
      if not seen[key] and vim.fn.filereadable(full) == 1 then
        seen[key] = true
        items[#items+1] = {filename=full, lnum=tonumber(lnum), text=vim.trim(line):sub(1, 160)}
      end
    end
  end
  return items
end

local function api_follow(id, project_id)
  vim.ui.input({prompt='Follow-up question: '}, function(question)
    if not question or vim.trim(question) == '' then return end
    M.api_run({id=project_id, label='Follow-up'}, question, {'--follow', id})
  end)
end

-- Called in a buffer holding a saved result (claude-api open, or a finished :ClaudeApi run).
function M.api_result_opened(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 12, false)
  local folder, id, project_id
  for _, line in ipairs(lines) do
    folder = folder or line:match('folder: (.+)$')
    id = id or line:match('Task ID: (%x+)')
  end
  vim.bo[buf].filetype, vim.bo[buf].modifiable = 'markdown', false
  vim.wo.wrap = true
  if folder and id then
    local ok, out = pcall(function() return vim.system({'claude-api', 'history'}, {text=true}):wait(5000) end)
    local parsed, rows = pcall(vim.json.decode, ok and out.stdout or '')
    for _, row in ipairs(parsed and type(rows) == 'table' and rows or {}) do if row.id == id then project_id = row.project end end
    local items = M.api_citations(vim.api.nvim_buf_get_lines(buf, 0, -1, false), folder)
    vim.fn.setqflist({}, ' ', {title='API answer citations', items=items})
    local function jump()
      local line = vim.api.nvim_get_current_line()
      local hit = M.api_citations({line}, folder)[1]
      if hit then require('desk.nav').open_code(hit.filename, hit.lnum, 0) end
    end
    vim.keymap.set('n', '<CR>', jump, {buffer=buf, desc='Open the cited file and line'})
    if project_id then vim.keymap.set('n', 'f', function() api_follow(id, project_id) end, {buffer=buf, desc='Ask a follow-up'}) end
    vim.notify(#items .. ' cited lines in the quickfix list (:copen) · Enter opens one · f asks a follow-up · q closes')
  end
  vim.keymap.set('n', 'q', '<cmd>bwipeout<cr>', {buffer=buf, desc='Close API result'})
end

-- Starts claude-api run; progress lines arrive on stderr, the result as JSON on stdout.
function M.api_run(project, question, extra, opts)
  opts = opts or {}
  if api_job then vim.notify('An API task is already running. :ClaudeApiStop cancels it.'); return end
  local argv = {'claude-api', 'run', '--project', project.id, '--prompt-stdin', '--json'}
  if opts.model then vim.list_extend(argv, {'--model', opts.model}) end
  if opts.budget then vim.list_extend(argv, {'--budget', opts.budget}) end
  vim.list_extend(argv, extra or {})
  local progress = {title='API task', id='claude-api'}
  api_job = vim.system(argv, {text=true, stdin=question, stderr=vim.schedule_wrap(function(_, data)
    if not data then return end
    local last = vim.trim(data):match('([^\n]*)$')
    if last and last ~= '' then vim.notify(project.label .. ' · ' .. last, vim.log.levels.INFO, progress) end
  end)}, vim.schedule_wrap(function(result)
    api_job = nil
    local parsed, value = pcall(vim.json.decode, result.stdout or '')
    if not parsed or type(value) ~= 'table' or not value.id then
      vim.notify(vim.trim(result.stderr or '') ~= '' and result.stderr or 'API task failed.', vim.log.levels.WARN); return
    end
    local md = vim.system({'claude-api', 'show', value.id}, {text=true}):wait(5000)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(md.stdout or value.result or '', '\n', {plain=true}))
    vim.bo[buf].bufhidden = 'wipe'
    vim.cmd('tab sbuffer ' .. buf)
    M.api_result_opened(buf)
    if type(opts.on_done) == 'function' then pcall(opts.on_done, value) end
  end))
  vim.notify(project.label .. ' API task started' .. (opts.model and (' · ' .. opts.model) or '') .. ' · :ClaudeApiStop cancels',
    vim.log.levels.INFO, progress)
end

local function api_choose_project(callback)
  if vim.fn.executable('claude-api') ~= 1 then vim.notify('Install claude-api first.', vim.log.levels.WARN); return end
  local projects = api_projects()
  if not projects then vim.notify('API task settings are unavailable.', vim.log.levels.WARN); return end
  local here = (vim.uv or vim.loop).fs_realpath(root()) or root()
  for _, project in ipairs(projects) do if inside(here, project) then return callback(project, here) end end
  local heading = projects[1] and type(projects[1].credits) == 'string' and (' · ' .. projects[1].credits) or ''
  vim.ui.select(projects, {prompt='Review with API credits' .. heading, format_item=function(p) return p.label end},
    function(project) if project then callback(project, here) end end)
end

local function api_model_and_budget(project, callback)
  local models = project.models or {project.model}
  vim.ui.select(models, {prompt='Model (' .. (project.credits or '') .. ')',
    format_item=function(m) return m == project.model and (m .. '  · default') or m end}, function(model)
    if not model then return end
    vim.ui.input({prompt='Run budget USD (Enter starts): ', default=project.budget_usd or '1.00'}, function(limit)
      if limit and vim.trim(limit) ~= '' then callback(model, vim.trim(limit)) end
    end)
  end)
end

-- Is the API setup there (the tool, and its settings readable)? Asked by menus that offer API rows; kept a minute.
local api_seen = { at = 0, ok = false }
function M.api_available()
  local now = os.time()
  if now - api_seen.at > 60 then api_seen = { at = now, ok = vim.fn.executable('claude-api') == 1 and api_projects() ~= nil } end
  return api_seen.ok
end
-- A question about text the caller already holds (the review's displayed change): same project, model and budget
-- choices as any API task; `done` gets the finished task.
function M.api_question(question, done)
  if api_job then vim.notify('An API task is already running. :ClaudeApiStop cancels it.'); return end
  api_choose_project(function(project, here)
    api_model_and_budget(project, function(model, limit)
      local extra = {}
      if inside(here, project) then vim.list_extend(extra, {'--root', here}) end
      M.api_run(project, question, extra, {model=model, budget=limit, on_done=done})
    end)
  end)
end

function M.api_task(selection)
  if api_job then vim.notify('An API task is already running. :ClaudeApiStop cancels it.'); return end
  local file = vim.api.nvim_buf_get_name(0)
  local context = ''
  if selection then
    context = table.concat(vim.api.nvim_buf_get_lines(0, selection[1]-1, selection[2], false), '\n')
    if #context > 24000 then vim.notify('Select a smaller excerpt (up to 24 KB).', vim.log.levels.WARN); return end
  end
  api_choose_project(function(project, here)
    vim.ui.input({prompt=project.label .. ' API task: '}, function(question)
      if not question or vim.trim(question) == '' then return end
      api_model_and_budget(project, function(model, limit)
        local extra = {}
        if inside(here, project) then
          vim.list_extend(extra, {'--root', here})
          if file ~= '' and vim.fn.filereadable(file) == 1 then vim.list_extend(extra, {'--context-file', file}) end
          if context ~= '' then question = question .. '\n\nSelected excerpt from ' .. file .. ':\n' .. context end
        end
        M.api_run(project, question, extra, {model=model, budget=limit})
      end)
    end)
  end)
end

function M.api_review()
  api_choose_project(function(project, here)
    vim.ui.input({prompt='Review uncommitted changes in ' .. project.label .. ' — look for (Enter: bugs, risky edits, missing tests): '},
      function(focus)
        if focus == nil then return end
        api_model_and_budget(project, function(model, limit)
          local extra = {'--review-changes'}
          if inside(here, project) then vim.list_extend(extra, {'--root', here}) end
          M.api_run(project, focus, extra, {model=model, budget=limit})
        end)
      end)
  end)
end

function M.tests(id, index)
  local args = { "tests", "--root", root() }
  if id and id ~= "" then vim.list_extend(args, { "--id", id }) end
  local job = data(args)
  if not job or not job.tests then vim.notify("No captured test results yet. Use fjob to capture a test run."); return end
  local items = job.tests.failures or {}
  local state = job.stale and " · stale" or ""
  vim.fn.setqflist({}, " ", { title = "test results · " .. (job.command or "") .. state, items = items, idx = tonumber(index) or 1 })
  if #items == 0 then
    scratch(run({ "log", "--id", job.id }), "test output", "text")
    vim.notify("No source locations in the captured output; showing its log.")
    return
  end
  local ok, trouble = pcall(require, "trouble")
  if ok then trouble.open({ mode = "quickfix", focus = false }) else vim.cmd("copen"); vim.cmd("wincmd p") end
  pcall(vim.cmd, "cc " .. math.max(1, math.min(#items, tonumber(index) or 1)))
end

function M.compare(id)
  scratch(run({ "compare", "--id", id }) or "Comparison unavailable.", "since last pass", "diff")
end

function M.draft(text)
  local buf = scratch(text, "a note for Claude", "markdown", true)
  vim.keymap.set("n", "<leader>ws", function()
    local draft = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if vim.trim(draft) == "" then return end
    if #draft > 8000 then vim.notify("Keep the note within 8000 bytes.", vim.log.levels.WARN); return end
    local C = require("desk.claude")
    local dir = C.runtime()
    if not dir then vim.notify("No local Claude inbox is available."); return end
    local ok, p = pcall(vim.system, { "desk-drawer", "claude-peers" }, { text = true })
    local out = ok and p:wait(5000) or nil
    local peers = out and out.code == 0 and C.decode(out.stdout) or {}
    if #peers == 0 then vim.notify("No Claude sessions are available. The draft stays here."); return end
    vim.ui.select(peers, { prompt = "Send this draft to", format_item = function(peer)
      return peer.name .. " · " .. peer.project .. " · " .. peer.state
    end }, function(peer)
      if not peer then return end
      local boundary = math.min(2000, #draft)
      while draft:byte(boundary + 1) and draft:byte(boundary + 1) >= 128 and draft:byte(boundary + 1) < 192 do boundary = boundary - 1 end
      local note = { from = "work", text = draft:sub(1, boundary) }
      if #draft > boundary then note.code = draft:sub(boundary + 1) end
      if C.write_note(dir, peer.id, note) then vim.notify("Note left for " .. peer.name)
      else vim.notify("Could not send the note. The draft stays here.", vim.log.levels.WARN) end
    end)
  end, { buffer = buf, desc = "Choose Claude and send this draft" })
  vim.notify("Edit this draft, then Space ws to choose a Claude. Closing the draft sends nothing.")
end

function M.ask(id, service)
  local text
  if service then
    text = "Please help diagnose this failed user service: " .. service .. "\n\n"
      .. (run({ "service-log", "--unit", service }) or "No journal excerpt available."):sub(-5000)
  else
    local job = data({ "tests", "--id", id })
    if not job then vim.notify("That job is no longer available."); return end
    local log = run({ "log", "--id", id }) or "No captured output; inspect the originating terminal."
    text = "Please help diagnose this failed command.\nProject: " .. job.root .. "\nCommand: " .. job.command
      .. "\nExit: " .. tostring(job.exit or "unknown") .. "\n\n" .. log:sub(-5000)
  end
  M.draft(text)
end

function M.tasks(project, selected)
  project = project or root()
  local tasks = data({ "tasks", "--root", project }) or {}
  if selected and selected ~= "" then
    for _, task in ipairs(tasks) do if task.id == selected then M.draft(task.text); return end end
  end
  local rows = { { add = true, text = "+ Pin a next step" } }
  for _, task in ipairs(tasks) do rows[#rows + 1] = task end
  vim.ui.select(rows, { prompt = "Next steps", format_item = function(t)
    return t.add and t.text or ((t.done and "✓ " or "◇ ") .. t.text)
  end }, function(task)
    if not task then return end
    if task.add then
      vim.ui.input({ prompt = "Next step: " }, function(text)
        if text and vim.trim(text) ~= "" then run({ "task-add", "--root", project, "--text", text }); M.tasks(project) end
      end)
    else
      vim.ui.select({ task.done and "Reopen" or "Mark done", "Prepare a note for Claude" }, { prompt = task.text }, function(action)
        if action == "Prepare a note for Claude" then M.draft(task.text)
        elseif action then run({ "task-toggle", "--root", project, "--id", task.id }); M.tasks(project) end
      end)
    end
  end)
end

-- The before side of a session's diff of one file: the copy kept at its first edit, unless that copy no longer says
-- what the session changed. A copy the file now equals (the session's part was undone, others' edits remain) would
-- open an empty review of a file the notebook counts as changed; a copy older than the file's last commit predates
-- what is now HEAD (the session's part is committed). Either way the review compares with HEAD, which is what the
-- notebook's counts are measured against.
function M.session_base(before, path, sid, C)
  local copy = before[path]
  if type(copy) ~= "string" or not copy:match("^%d+%.txt$") or not C.runtime() or not (sid or ""):match("^[%w_-]+$") then return before end
  local kept = C.runtime() .. "/edits/" .. sid .. "/before/" .. copy
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(kept)
  local superseded = C.read(kept) == C.read(path)
  if not superseded and stat then
    local out = vim.system({ "git", "--no-optional-locks", "-C", vim.fs.dirname(path), "log", "-1", "--format=%ct", "--", path }, { text = true }):wait(3000)
    local committed = out.code == 0 and tonumber(vim.trim(out.stdout or "")) or nil
    superseded = committed ~= nil and committed > stat.mtime.sec
  end
  if not superseded then return before end
  local rest = vim.deepcopy(before)
  rest[path] = nil
  return rest
end

-- A Neovim desk-work started for one item (kitty … nvim +lua require('desk.work').open_args() -- desk-work:ACTION ID
-- INDEX): a work viewer, which closing the item closes.
function M.open_args()
  local args = vim.fn.argv()
  local action = (args[1] or ""):match("^desk%-work:(.+)$")
  if not action then return end
  vim.g.desk_work_view = true
  vim.keymap.set("n", "<leader>Cq", function() require("desk.claude").close() end, { desc = "Close work viewer" })
  if action == "file-diff" or action == "reviews" then
    vim.keymap.set("n", "q", function() require("desk.claude").close() end, { desc = "Close Claude review" })
  end
  vim.cmd("silent! argdelete *")
  M.open_action(action, args[2] or "", args[3])
  -- Neovim opened the "desk-work:ACTION" argument as a buffer of its own: an empty tab beside the item. It goes.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= vim.api.nvim_get_current_buf() and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t") == args[1]
      and not vim.bo[buf].modified then pcall(vim.api.nvim_buf_delete, buf, { force = false }) end
  end
end

-- One work item in the current window: from open_args, or from desk.bridge in her running editor, which gives it a
-- new tab first. opts.root: the checkout it belongs to (else the one of the buffer in front).
function M.open_action(action, id, index, opts)
  local project = (opts or {}).root or root()
  if action == "file" then vim.cmd("edit " .. vim.fn.fnameescape(id))
  elseif action == "file-diff" then
    local C = require("desk.claude")
    local ledger = {}
    if type(index) == "string" and index:match("^[A-Za-z0-9_-]+$") and #index <= 80 and C.runtime() then
      ledger = C.decode(C.read(C.runtime() .. "/edits/" .. index .. ".json")) or {}
    end
    local before = M.session_base(ledger.before or {}, id, index, C)
    C.open_review({ kind = "live", sid = index or "", name = "notebook", short = "notebook",
      files = { id }, before = before, label = "notebook change" }, project)
    C.diff(id)
  elseif action == "callgraph" then require("desk.callgraph").open_at(id, index)
  elseif action == "workspace" then if not require('desk.workspace').resume() then vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd())) end
  elseif action == "suggested-tests" then M.suggested_tests(id)
  elseif action == "timeline" then M.history(false)
  elseif action == "digest" then M.history(true)
  elseif action == "since" then require("desk.since").open(project)
  elseif action == "snoozed" then M.snooze(true)
  elseif action == "health" then M.health()
  elseif action == "backups" then M.backups()
  elseif action == "tests" then M.tests(id, index)
  elseif action == "compare" then M.compare(id)
  elseif action == "reviews" then
    local C = require("desk.claude")
    if id ~= "" then
      for _, row in ipairs(C.rows(project)) do if row.kind == "commit" and row.sha == id then C.open_review(row, project); return end end
      vim.notify('That commit is no longer listed on this branch.'); return
    end
    C.changes(true)
  elseif action == "tasks" then M.tasks(project, id)
  elseif action == "ask" then M.ask(id)
  elseif action == "ask-service" then M.ask(nil, id)
  elseif action == "service" then scratch(run({ "service-log", "--unit", id }), "service log", "text")
  elseif action == "log" then scratch(run({ "log", "--id", id }), "job output", "text") end
end

function M.attention(next_only)
  local project = root()
  local items = data({ 'attention', '--root', project })
  if not items then return end
  local aside = data({ 'set-aside', '--root', project, '--show', 'yes' })
  if #items == 0 and not (aside and aside.count) then vim.notify('Nothing needs you in this project.'); return end
  local function open(item)
    local resolved = data({ 'resolve', '--root', project, '--action', 'attention', '--id', item.id })
    if not resolved then vim.notify('That item is settled; refresh the list.'); return end
    local action = resolved.action or {}
    if item.kind == 'request' or item.kind == 'changed' or item.kind == 'commit' then
      require('desk.review').open_item(item, project)
    elseif action.kind == 'tests' then M.tests(action.id)
    elseif action.kind == 'log' then scratch(run({ 'log', '--id', action.id }), 'job output', 'text')
    elseif action.kind == 'agent' then
      run({ 'open', '--root', project, '--action', 'attention', '--id', item.id })
    elseif action.kind == 'health' then M.health()
    end
  end
  if next_only then if items[1] then open(items[1]) end; return end
  local rows = {}
  for _, item in ipairs(items) do
    local selected = item
    rows[#rows + 1] = { name = item.label, label = item.why, group = item.kind,
      ident = item.id, run = function() open(selected) end }
  end
  -- The review backlog: set aside to catch up later (it stays unreviewed in the review), or brought back.
  local commits = #vim.tbl_filter(function(item) return item.kind == 'commit' end, items)
  if commits > 0 then rows[#rows + 1] = { name = 'Set aside ' .. commits .. (commits == 1 and ' commit' or ' commits') .. ' to review',
    label = 'catch up later', group = 'backlog', run = function()
      if vim.fn.confirm('Set aside ' .. commits .. ' commits to review? They stay unreviewed in the review; bringing them back undoes it.', '&Set aside\n&Cancel', 2) ~= 1 then return end
      local done = data({ 'set-aside', '--root', project })
      if done then vim.notify(done.message) end
    end } end
  if aside and aside.count then rows[#rows + 1] = { name = 'Bring back ' .. aside.count .. ' set-aside commits', label = 'back into this list',
    group = 'backlog', run = function()
      local done = data({ 'set-aside', '--root', project, '--undo', 'yes' })
      if done then vim.notify(done.message) end
    end } end
  require('desk.review').show_menu(rows, { title = 'Needs you', memo = 'foxml-attention' })
end

function M.history(digest_only)
  local project = root()
  local digest = digest_only and data({ 'digest', '--root', project, '--consumer', 'nvim' }) or nil
  local events = digest_only and digest and digest.events or data({ 'timeline', '--root', project })
  if not events then return end
  if digest and (digest.greeting or digest.summary) then vim.notify(digest.greeting or digest.summary) end
  local rows = {}
  for _, event in ipairs(events) do
    local selected = event
    rows[#rows + 1] = { name = event.label, label = os.date('%H:%M', event.at), group = event.kind, ident = event.id,
      run = function()
        local resolved = data({ 'resolve', '--root', project, '--action', 'event', '--id', selected.id })
        if not resolved then return end
        local action = resolved.action or {}
        if action.kind == 'file-diff' then require('desk.review').open_item({ kind = 'changed', file = action.file, why = selected.label }, project)
        elseif action.kind == 'reviews' then require('desk.review').open_item({ kind = 'commit', sha = action.id }, project)
        elseif action.kind == 'tests' then M.tests(action.id)
        elseif action.kind == 'log' then scratch(run({ 'log', '--id', action.id }), 'job output', 'text')
        elseif action.kind == 'health' then M.health()
        elseif action.kind == 'agent' then run({ 'open', '--root', project, '--action', 'event', '--id', selected.id })
        else vim.notify('That event has nothing to open.') end
      end }
  end
  if digest and digest.total > 0 then rows[#rows + 1] = { name = 'Mark these events caught up', group = 'digest', run = function()
    data({ 'digest', '--root', project, '--consumer', 'nvim', '--through', tostring(digest.through) })
  end } end
  if #rows == 0 then vim.notify('No new project events.'); return end
  require('desk.review').show_menu(rows, { title = digest_only and 'Since you last looked' or 'Project timeline', memo = 'foxml-history' })
end

local function health_lines(state)
  local lines = { '# Work health', '' }
  for _, check in ipairs(state.checks or {}) do
    lines[#lines + 1] = '## ' .. check.label
    for line in ((check.detail or '') .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = line end
    lines[#lines + 1] = ''
  end
  lines[#lines + 1] = 'r refresh · R recover an interrupted update · b preview backup cleanup · F repair records · q close'
  return lines
end

local function recover(buf, state)
  local choices = vim.tbl_filter(function(item) return not item.active end, state.pending or {})
  if #choices == 0 then vim.notify('No interrupted update needs recovery.'); return end
  vim.ui.select(choices, { prompt = 'Recover interrupted update', format_item = function(item) return item.transaction .. ' · ' .. item.phase end }, function(item)
    if not item then return end
    if vim.fn.confirm('Recover update ' .. item.transaction .. ' by restoring its guarded backup?', '&Recover\n&Cancel', 2) ~= 1 then return end
    vim.notify('Recovering update ' .. item.transaction .. '…')
    call('recover:' .. buf, { 'integrations', 'recover', '--transaction', item.transaction }, function(result)
      if result then vim.notify(result.message or ('Update ' .. item.transaction .. ' recovered.')) end
      M.health(buf)
    end)
  end)
end

function M.health(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = tab_scratch('# Work health\n\nReading the work records…', 'Work health', 'markdown')
    vim.keymap.set('n', 'r', function() M.health(buf) end, { buffer = buf, desc = 'Refresh work health' })
    vim.keymap.set('n', 'b', function() M.backups() end, { buffer = buf, desc = 'Preview backup cleanup' })
    vim.keymap.set('n', 'q', '<cmd>tabclose<CR>', { buffer = buf, desc = 'Close work health' })
  else
    -- What is shown stays readable while the new reading arrives.
    local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
    if not first:find('refreshing', 1, true) then
      vim.bo[buf].modifiable = true; vim.api.nvim_buf_set_lines(buf, 0, 1, false, { first .. ' · refreshing…' }); vim.bo[buf].modifiable = false
    end
  end
  call('health:' .. buf, { 'health' }, function(state)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if not state then fill(buf, { '# Work health', '', 'The work records could not be read; r tries again.' }); return end
    fill(buf, health_lines(state))
    vim.keymap.set('n', 'R', function() recover(buf, state) end, { buffer = buf, desc = 'Recover an interrupted update' })
    -- F repairs the project with an unreadable record (asking which, if several), else this project.
    local broken = {}
    for _, check in ipairs(state.checks or {}) do
      if check.repairable and check.root and not vim.tbl_contains(broken, check.root) then broken[#broken + 1] = check.root end
    end
    vim.keymap.set('n', 'F', function()
      if #broken <= 1 then return M.repair(broken[1]) end
      vim.ui.select(broken, { prompt = 'Repair records in' }, function(choice) if choice then M.repair(choice) end end)
    end, { buffer = buf, desc = 'Repair unreadable project records' })
  end)
end

function M.backups()
  local buf = tab_scratch('# Update backup cleanup preview\n\nReading the update backups…', 'Update backups', 'markdown')
  vim.keymap.set('n', 'q', '<cmd>tabclose<CR>', { buffer = buf })
  call('backups:' .. buf, { 'integrations', 'cleanup-plan' }, function(plan)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if not plan then fill(buf, { '# Update backup cleanup preview', '', 'The backups could not be inspected; nothing was changed.' }); return end
    local lines = { '# Update backup cleanup preview', '', tostring(math.floor((plan.bytes or 0) / 1024)) .. ' KiB total',
      tostring(math.floor((plan.reclaimableBytes or 0) / 1024)) .. ' KiB selected for cleanup', '', 'Current rollback chains and unfinished updates are retained.', '' }
    for _, item in ipairs(plan.transactions or {}) do
      lines[#lines + 1] = item.transaction .. ' · ' .. item.phase .. ' · ' .. math.floor(item.bytes / 1024) .. ' KiB'
      lines[#lines + 1] = item.protected and ('  Retain: ' .. item.reason) or '  Selected for cleanup'
    end
    lines[#lines + 1] = ''; lines[#lines + 1] = 'D confirm this cleanup preview · q close'
    fill(buf, lines)
    vim.keymap.set('n', 'D', function()
      if #(plan.selected or {}) == 0 then vim.notify('No backups are eligible for cleanup.'); return end
      if vim.fn.confirm('Remove the ' .. #plan.selected .. ' backup transactions selected in this preview?', '&Remove\n&Cancel', 2) ~= 1 then return end
      call('cleanup:' .. buf, { 'integrations', 'cleanup', '--expected', plan.plan, '--keep', tostring(plan.keep), '--older-than', tostring(plan.olderDays) }, function(result)
        if not (result and result.ok) then return end
        vim.notify('Removed ' .. result.removed .. ' backup transactions.')
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modifiable = true; vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'Cleanup completed. Preview again before another cleanup.' }); vim.bo[buf].modifiable = false
        end
      end)
    end, { buffer = buf })
  end)
end

-- A record desk-work cannot read refuses every write until it is set aside. The preview lists exactly what would
-- happen; D does it; originals are kept beside the records under dated names.
local function repair_into(buf, project)
  call('repair:' .. buf, { 'records-repair', '--root', project }, function(preview)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if not preview then fill(buf, { '# Repair project records', '', 'The records could not be read; q closes.' }); return end
    local actions = preview.actions or {}
    local lines = { '# Repair project records', '', project, '' }
    if #actions == 0 then lines[#lines + 1] = 'Every record here is readable, and nothing needs tidying.' end
    for _, action in ipairs(actions) do lines[#lines + 1] = '- ' .. action.says end
    for _, stale in ipairs((preview.report or {}).stale or {}) do
      if not stale.tidy then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'Kept as history: ' .. #stale.entries .. ' ' .. stale.reason .. ' (' .. stale.file .. ').'
      end
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = (#actions > 0 and 'D make these repairs · ' or '') .. 'q close'
    fill(buf, lines)
    pcall(vim.keymap.del, 'n', 'D', { buffer = buf })
    if #actions == 0 then return end
    vim.keymap.set('n', 'D', function()
      if vim.fn.confirm('Make ' .. (#actions == 1 and 'this repair' or ('these ' .. #actions .. ' repairs')) .. '? The originals are kept.', '&Repair\n&Cancel', 2) ~= 1 then return end
      call('repair-apply:' .. buf, { 'records-repair', '--root', project, '--expected', preview.plan }, function(result)
        if result then vim.notify(result.message or 'Records repaired.') end
        repair_into(buf, project)
      end)
    end, { buffer = buf, desc = 'Make the previewed repairs' })
  end)
end
function M.repair(project)
  project = project or root()
  local buf = tab_scratch('# Repair project records\n\nReading the records…', 'Repair records', 'markdown')
  vim.keymap.set('n', 'q', '<cmd>tabclose<CR>', { buffer = buf, desc = 'Close record repair' })
  repair_into(buf, project)
end

function M.snooze(resume)
  local project = root()
  local items = data({ 'attention', '--root', project, '--include-snoozed', 'yes' }) or {}
  items = vim.tbl_filter(function(item) return resume and item.snoozed or not resume and not item.snoozed end, items)
  if #items == 0 then vim.notify(resume and 'Nothing is snoozed here.' or 'Nothing here needs you, so there is nothing to snooze.'); return end
  vim.ui.select(items, { prompt = resume and 'Bring back attention item' or 'Snooze attention item', format_item = function(item) return item.label end }, function(item)
    if not item then return end
    if resume then data({ 'snooze', '--root', project, '--id', item.id, '--clear', 'yes' }); return end
    vim.ui.select({ 'One hour', 'Until this item changes' }, { prompt = item.label }, function(choice)
      if choice then data({ 'snooze', '--root', project, '--id', item.id, choice == 'One hour' and '--seconds' or '--until-change', choice == 'One hour' and '3600' or 'yes' }) end
    end)
  end)
end

function M.suggested_tests(file)
  local project = vim.fs.root(file or 0, '.git') or root()
  file = file or vim.api.nvim_buf_get_name(0)
  if file:sub(1, #project + 1) == project .. '/' then file = file:sub(#project + 2) end
  local items = data({ 'suggest-tests', '--root', project, '--file', file }) or {}
  if #items == 0 then vim.notify('No captured test commands for this project yet.'); return end
  vim.ui.select(items, { prompt = 'Known tests for ' .. file, format_item = function(item)
    return item.label .. ' · ' .. item.reason .. (item.stale and ' · result is stale' or '')
  end }, function(item)
    if not item then return end
    vim.ui.select({ 'Run on saved files', 'Cancel' }, { prompt = item.command .. ' · in ' .. item.cwd }, function(choice)
      if choice ~= 'Run on saved files' then return end
      vim.notify('Running ' .. item.label .. '…')
      vim.system({ 'desk-work', 'run-suggested', '--root', project, '--id', item.id }, { text = true }, vim.schedule_wrap(function(out)
        vim.notify(out.code == 0 and 'Test run passed.' or out.code == 2 and M.refusal({ 'run-suggested' }, out) or 'Test run did not pass; see :WorkTests.')
        M.tests()
      end))
    end)
  end)
end

-- The keys are rows of the action registry (desk/actions.lua): the mappings, which-key's words, the home menu and the
-- keybinds reference all read them.
local actions = require('desk.actions')
local function desk_work() return vim.fn.executable('desk-work') == 1 or 'requires desk-work' end
local function claude_api() return vim.fn.executable('claude-api') == 1 or 'requires claude-api' end
-- ─── coverage of one run (Codex's #16) ────────────────────────────────────────────────────────────────────────────
-- The lines and functions a chosen test run covered, marked in this file: covered lines one colour, missed ones
-- another, each function's count beside it; the run, its command, executable and commit said with it. Another run's
-- coverage replaces it (does that test take another branch?); chosen again with the same run, it goes.
local cover_ns = vim.api.nvim_create_namespace('desk_coverage')
M.cover_ns = cover_ns
--- pure-ish: the marks a run's coverage of one file puts in buffer `buf` → how many lines covered / missed.
function M.coverage_marks(buf, cov)
  vim.api.nvim_buf_clear_namespace(buf, cover_ns, 0, -1)
  if vim.fn.hlexists('DeskCoverRan') == 0 or next(vim.api.nvim_get_hl(0, { name = 'DeskCoverRan' })) == nil then
    vim.api.nvim_set_hl(0, 'DeskCoverRan', { link = 'DiffAdd', default = true })
    vim.api.nvim_set_hl(0, 'DeskCoverNot', { link = 'DiffDelete', default = true })
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local ran, missed = 0, 0
  for n, c in pairs(cov.lines or {}) do
    local line = tonumber(n)
    if line and line >= 1 and line <= count then
      if (tonumber(c) or 0) > 0 then ran = ran + 1 else missed = missed + 1 end
      pcall(vim.api.nvim_buf_set_extmark, buf, cover_ns, line - 1, 0, { sign_text = '▎', sign_hl_group = (tonumber(c) or 0) > 0 and 'DeskCoverRan' or 'DeskCoverNot', priority = 15 })
    end
  end
  for _, f in ipairs(cov.functions or {}) do
    local line = tonumber(f.line)
    if line and line >= 1 and line <= count then
      local c = tonumber(f.count) or 0
      pcall(vim.api.nvim_buf_set_extmark, buf, cover_ns, line - 1, 0, { virt_text = { { c > 0 and ('  ran ' .. c .. '×') or '  not run', c > 0 and 'DeskCoverRan' or 'DeskCoverNot' } },
        virt_text_pos = 'eol', priority = 15 })
    end
  end
  return ran, missed
end
--- pure: where each line of `before` is in `after` when it is unchanged (a diff's hunks left out) → { [old] = new }.
function M.map_lines(before, after)
  local a, b = table.concat(before, '\n') .. '\n', table.concat(after, '\n') .. '\n'
  local hunks = (vim.text and vim.text.diff or vim.diff)(a, b, { result_type = 'indices' }) or {}
  local map, old, new = {}, 1, 1
  local function same_until(stop)   -- unchanged lines up to old line `stop` (exclusive)
    while old < stop do map[old] = new; old, new = old + 1, new + 1 end
  end
  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    -- a hunk that only adds lines says the line it comes after; one that removes or changes, its first line
    same_until(count_a == 0 and start_a + 1 or start_a)
    old, new = old + count_a, (count_b == 0 and start_b + 1 or start_b) + count_b
  end
  same_until(#before + 1)
  return map
end

-- The run whose marks a buffer shows (its coverage as it ran, its commit, its name), for a second run to be compared
-- with it (Codex's E3); a comparison keeps both.
local shown = {}
M.coverage_shown = shown

-- A run's lines moved onto today's text through the version it ran (read at its commit; today's own when that cannot be
-- read) → { [today's line] = count }, its functions on today's lines, how many lines could not be placed.
local function moved_onto(root, rel, run, today)
  local then_lines = today
  if run.head and run.head ~= '' then
    local got = vim.system({ 'git', '-C', root, 'show', run.head .. ':' .. rel }, { text = true }):wait()
    if got.code == 0 then then_lines = vim.split(got.stdout:gsub('\n$', ''), '\n', { plain = true }) end
  end
  local map, lines, functions, lost = M.map_lines(then_lines, today), {}, {}, 0
  for n, c in pairs(run.cov.lines or {}) do
    local to = map[tonumber(n)]
    if to then lines[to] = tonumber(c) or 0 else lost = lost + 1 end
  end
  for _, f in ipairs(run.cov.functions or {}) do
    local to = map[tonumber(f.line)]
    if to then functions[#functions + 1] = { name = f.name, line = to, count = tonumber(f.count) or 0 } end
  end
  return lines, functions, lost
end

--- pure-ish: two runs' lines (already on this buffer's lines) in one gutter → { both, a, b, neither }. A line one run
--- has no count for is not run by it. Glyphs distinct without colour (monochrome retro), all in code page 437.
function M.compare_marks(buf, a, b, names, functions)
  vim.api.nvim_buf_clear_namespace(buf, cover_ns, 0, -1)
  for name, link in pairs({ DeskCoverBoth = 'DiffAdd', DeskCoverA = 'DiffChange', DeskCoverB = 'DiffText', DeskCoverNot = 'DiffDelete' }) do
    if vim.fn.hlexists(name) == 0 or next(vim.api.nvim_get_hl(0, { name = name })) == nil then vim.api.nvim_set_hl(0, name, { link = link, default = true }) end
  end
  local counts, seen, count = { both = 0, a = 0, b = 0, neither = 0 }, {}, vim.api.nvim_buf_line_count(buf)
  for _, side in ipairs({ a, b }) do for line in pairs(side) do seen[line] = true end end
  for line in pairs(seen) do
    if line >= 1 and line <= count then
      local ra, rb = (a[line] or 0) > 0, (b[line] or 0) > 0
      local glyph, group, key = '·', 'DeskCoverNot', 'neither'
      if ra and rb then glyph, group, key = '█', 'DeskCoverBoth', 'both'
      elseif ra then glyph, group, key = '▌', 'DeskCoverA', 'a'
      elseif rb then glyph, group, key = '▐', 'DeskCoverB', 'b' end
      counts[key] = counts[key] + 1
      pcall(vim.api.nvim_buf_set_extmark, buf, cover_ns, line - 1, 0, { sign_text = glyph, sign_hl_group = group, priority = 15 })
    end
  end
  -- each function's line: both counts ("reconnect 3× · startup 0")
  local by_line = {}
  for side, list in ipairs(functions or {}) do
    for _, f in ipairs(list) do by_line[f.line] = by_line[f.line] or {}; by_line[f.line][side] = f.count end
  end
  for line, pair in pairs(by_line) do
    if line >= 1 and line <= count then
      local function said(i) return names[i] .. ' ' .. ((pair[i] or 0) > 0 and (pair[i] .. '×') or '0') end
      pcall(vim.api.nvim_buf_set_extmark, buf, cover_ns, line - 1, 0, { virt_text = { { '  ' .. said(1) .. ' · ' .. said(2), 'DeskCoverBoth' } },
        virt_text_pos = 'eol', priority = 15 })
    end
  end
  return counts
end

--- Two runs (each { id, name, head, cov }) compared on this buffer, each moved onto it through its own commit → the summary.
function M.compare_coverage(buf, root, rel, A, B)
  local today = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local la, fa, lost_a = moved_onto(root, rel, A, today)
  local lb, fb, lost_b = moved_onto(root, rel, B, today)
  local c = M.compare_marks(buf, la, lb, { A.name, B.name }, { fa, fb })
  vim.b[buf].desk_coverage = A.id .. '+' .. B.id
  shown[buf] = { compare = true, a = A, b = B }
  local function n(k) return c[k] .. (c[k] == 1 and ' line' or ' lines') end
  local lost = lost_a + lost_b
  return ('Comparing %s (▌) with %s (▐): both ran %s · only %s %d · only %s %d · neither %d%s.'):format(A.name, B.name, n('both'),
    A.name, c.a, B.name, c.b, c.neither, lost > 0 and (' · ' .. lost .. (lost == 1 and ' line' or ' lines') .. ' changed since could not be placed') or '')
end

--- A run chosen for this buffer (its coverage fetched: { id, name, head, cov, said, clean }): the shown one again takes
--- the marks off; with another's marks shown, compare or replace (pick: vim.ui.select's shape); else shown as E2 does.
function M.place_run(buf, root, rel, run, pick)
  pick = pick or function(choices, done)
    vim.ui.select(choices, { prompt = 'Coverage of ' .. run.name, format_item = function(c) return c.label end }, done)
  end
  local s = shown[buf]
  local current = vim.b[buf].desk_coverage
  if current and (current == run.id or (s and s.compare and (s.a.id == run.id or s.b.id == run.id))) then
    vim.api.nvim_buf_clear_namespace(buf, cover_ns, 0, -1)
    vim.b[buf].desk_coverage, shown[buf] = nil, nil
    return vim.notify('Coverage marks taken off.')
  end
  local function replace()
    M.show_coverage(buf, root, rel, run.cov, { head = run.head, id = run.id, said = run.said or run.name, name = run.name, clean = run.clean,
      tested = run.tested }, pick)
  end
  if not (current and s and not s.compare) then return replace() end
  pick({ { label = 'Compare with the marks shown (' .. s.name .. ')', how = 'compare' }, { label = 'Replace them', how = 'replace' } }, function(choice)
    if not choice then return end
    if choice.how == 'replace' then return replace() end
    vim.notify(M.compare_coverage(buf, root, rel, s, run))
  end)
end

-- Coverage on the version that ran (Codex's E2, 2026-11-19; the marks were put at the recorded line numbers in the open
-- file whatever had changed since). The file read at the run's commit: the same as this buffer, marks here; changed,
-- the version that ran in a read-only split by default (gf there to today's file, as the review's kept versions), or
-- today's file with the lines unchanged since only. info: { head, id, said, clean, name? (the run, short),
-- tested? (the split's title: the run and its commit) }; pick(choices, done) is
-- vim.ui.select's shape (tests give their own).
function M.show_coverage(buf, root, rel, cov, info, pick)
  pick = pick or function(choices, done)
    vim.ui.select(choices, { prompt = rel .. ' changed since that run', format_item = function(c) return c.label end }, done)
  end
  local short = tostring(info.head or ''):sub(1, 7)
  local edits = info.clean == false and (' (the run had uncommitted edits: shown at ' .. short .. ', edited lines may differ)') or ''
  local function marked(target, c, extra)
    local ran, missed = M.coverage_marks(target, c)
    vim.b[target].desk_coverage = info.id
    shown[target] = { id = info.id, head = info.head, cov = cov, name = info.name or info.said, said = info.said }
    vim.notify('Coverage of ' .. info.said .. ': ' .. ran .. ' lines ran, ' .. missed .. ' did not' .. (extra or '') .. edits .. '.')
  end
  local then_lines
  if (info.head or '') ~= '' then
    local got = vim.system({ 'git', '-C', root, 'show', info.head .. ':' .. rel }, { text = true }):wait()
    if got.code == 0 then then_lines = vim.split(got.stdout:gsub('\n$', ''), '\n', { plain = true }) end
  end
  if not then_lines then
    return marked(buf, cov, ' (' .. (short ~= '' and short or 'its commit') .. ' is not in this checkout: where the file changed since, the marks may be off)')
  end
  local now = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if vim.deep_equal(then_lines, now) then return marked(buf, cov) end
  pick({ { label = 'The version that ran (' .. short .. ')', how = 'then' }, { label = 'This file, the lines unchanged since', how = 'map' } }, function(choice)
    if not choice then return end
    if choice.how == 'map' then
      local map, shifted, lost = M.map_lines(then_lines, now), { lines = {}, functions = {} }, 0
      for n, c in pairs(cov.lines or {}) do
        local to = map[tonumber(n)]
        if to then shifted.lines[tostring(to)] = c else lost = lost + 1 end
      end
      for _, f in ipairs(cov.functions or {}) do
        local to = map[tonumber(f.line)]
        if to then shifted.functions[#shifted.functions + 1] = vim.tbl_extend('force', f, { line = to }) end
      end
      return marked(buf, shifted, lost > 0 and (' · ' .. lost .. (lost == 1 and ' line' or ' lines') .. ' changed since, not marked') or '')
    end
    local view = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(view, 0, -1, false, then_lines)
    vim.bo[view].bufhidden, vim.bo[view].modifiable = 'wipe', false
    pcall(vim.api.nvim_buf_set_name, view, rel .. ' · as ' .. (info.tested or info.name or info.said) .. ' tested it')
    local kind = vim.filetype.match({ filename = rel })
    if kind then vim.bo[view].filetype = kind end
    vim.cmd('sbuffer ' .. view)
    local path = root .. '/' .. rel
    vim.keymap.set('n', 'q', '<cmd>bwipeout<cr>', { buffer = view, desc = 'Close the tested version' })
    vim.keymap.set('n', 'gf', function() vim.cmd('edit ' .. vim.fn.fnameescape(path)) end, { buffer = view, desc = 'Open the file as it is now' })
    marked(view, cov, ' (the version that ran: gf opens the file as it is now)')
  end)
end

-- ─── which test ran a changed function (Codex's E1, 2026-11-19) ──────────────────────────────────────────────────
-- A run: { name, id, head, label, cov (as it ran), lines = { [today's line] = count }, mapped = { [today's line] = true } }
-- (each line it ran at, moved onto today's file; mapped: today's lines that were there when it ran).
--- pure: a run's executable lines in today's lines a..b, how many ran, and how many of a..b are new since it ran.
function M.function_hits(run, a, b)
  local ran, total, new = 0, 0, 0
  for line = a, b do
    local c = run.lines[line]
    if c ~= nil then total = total + 1; if (tonumber(c) or 0) > 0 then ran = ran + 1 end end
    if not run.mapped[line] then new = new + 1 end
  end
  return { ran = ran, total = total, new = new }
end
--- pure: the review's words for today's lines a..b: "ran by test_most.py 8 of 11 · startup 3 of 11 · 2 lines new since",
--- the run that ran most first; nil when no run has an executable line there.
function M.ran_by_said(runs, a, b)
  local counted = {}
  for _, run in ipairs(runs or {}) do
    local h = M.function_hits(run, a, b)
    if h.total > 0 then counted[#counted + 1] = { run = run, h = h } end
  end
  if #counted == 0 then return nil end
  table.sort(counted, function(x, y) return x.h.ran > y.h.ran end)
  local parts = vim.tbl_map(function(c) return c.run.name .. ' ' .. c.h.ran .. ' of ' .. c.h.total end, counted)
  if counted[1].h.ran == 0 then return 'no test run with coverage ran it (' .. table.concat(parts, ' · ') .. ')' end
  local new = counted[1].h.new
  return 'ran by ' .. table.concat(parts, ' · ') .. (new > 0 and (' · ' .. new .. (new == 1 and ' line' or ' lines') .. ' new since') or '')
end
local function run_name(label)
  local last = tostring(label or ''):match('(%S+)%s*$') or tostring(label or '')
  return (vim.fs.basename((last:gsub('^[\'"]', ''):gsub('[\'"]$', ''))))
end
--- The runs that kept coverage of `rel` (desk-work's suggestions, the one that ran most of the file first, at most 3),
--- each read at its commit and moved onto `today` (the working copy's text). Quiet: a refusal is no runs. → done(runs)
--- bin: desk-work's path, or a command to run it ({ 'sh', script } in a test: /tmp is noexec here).
function M.coverage_runs(root, rel, today, done, bin)
  local prefix = type(bin) == 'table' and bin or { bin or 'desk-work' }
  local function ask(args, cb)
    local ok = pcall(vim.system, vim.list_extend(vim.list_slice(prefix), args), { text = true, timeout = 20000 }, vim.schedule_wrap(function(out)
      local parsed, value = pcall(vim.json.decode, out.stdout or '')
      cb(out.code == 0 and parsed and type(value) == 'table' and value or nil)
    end))
    if not ok then vim.schedule(function() cb(nil) end) end
  end
  local now_lines = vim.split((today or ''):gsub('\n$', ''), '\n', { plain = true })
  ask({ 'suggest-tests', '--root', root, '--file', rel }, function(list)
    local with = vim.tbl_filter(function(s) return type(s) == 'table' and (tonumber(s.lines) or 0) > 0 end, list or {})
    with = vim.list_slice(with, 1, 3)
    local runs, left = {}, #with
    if left == 0 then return done({}) end
    for i, s in ipairs(with) do
      ask({ 'coverage', '--root', root, '--run', s.id, '--file', rel }, function(doc)
        local cov = doc and doc.files and doc.files[rel]
        if cov then
          local head = doc.head ~= vim.NIL and doc.head or nil
          local then_lines = head and vim.system({ 'git', '-C', root, 'show', head .. ':' .. rel }, { text = true }):wait()
          then_lines = then_lines and then_lines.code == 0 and vim.split(then_lines.stdout:gsub('\n$', ''), '\n', { plain = true }) or now_lines
          local map, lines, mapped = M.map_lines(then_lines, now_lines), {}, {}
          for _, to in pairs(map) do mapped[to] = true end
          for n, c in pairs(cov.lines or {}) do
            local to = map[tonumber(n)]
            if to then lines[to] = c end
          end
          runs[i] = { name = run_name(s.label), label = s.label, id = s.id, head = head, cov = cov, lines = lines, mapped = mapped,
            said = 'run ' .. tostring(s.id):sub(1, 8) .. ' · ' .. tostring(doc.command or s.label) }
        end
        left = left - 1
        if left == 0 then
          local out = {}
          for k = 1, #with do if runs[k] then out[#out + 1] = runs[k] end end
          done(out)
        end
      end)
    end
  end)
end

function M.coverage(root)
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  root = root or vim.fs.root(path ~= '' and path or 0, '.git') or vim.fn.getcwd()
  local real_root = vim.uv.fs_realpath(root) or root
  local rel = (vim.uv.fs_realpath(path) or path):sub(#real_root + 2)
  call('coverage-jobs', { 'jobs', '--root', real_root }, function(runs)
    local with = vim.tbl_filter(function(r) return type(r) == 'table' and type(r.coverage) == 'table' end, runs or {})
    if #with == 0 then return vim.notify('No run in this checkout kept coverage (a run that writes lcov.info, or desk-work coverage add).') end
    vim.ui.select(with, { prompt = 'Coverage of which run', format_item = function(r)
      return os.date('%m-%d %H:%M', r.ended or 0) .. '  ' .. tostring((r.title or '') ~= '' and r.title or r.command) .. '  ' .. tostring(r.head or ''):sub(1, 7)
    end }, function(r)
      if not r then return end
      call('coverage', { 'coverage', '--root', real_root, '--run', r.id, '--file', rel }, function(doc)
        if not (doc and doc.ok ~= false) then return vim.notify('That run kept no coverage.', vim.log.levels.WARN) end
        local cov = (doc.files or {})[rel]
        local said = 'run ' .. tostring(r.id):sub(1, 8) .. ' · ' .. tostring(doc.command or r.command) .. ' · ' .. (doc.executable ~= vim.NIL and doc.executable or 'executable not named')
          .. ' · at ' .. tostring(doc.head or ''):sub(1, 7)
        if not cov then return vim.notify(rel .. ' is not in the coverage of ' .. said .. '.') end
        local head = doc.head ~= vim.NIL and doc.head or r.head
        M.place_run(buf, real_root, rel, { id = r.id, head = head, cov = cov, said = said, clean = r.clean,
          name = run_name((r.title or '') ~= '' and r.title or r.command),
          tested = 'run ' .. tostring(r.id):sub(1, 8) .. ' (' .. tostring(head or ''):sub(1, 7) .. ')' })
      end)
    end)
  end)
end

local ROWS = actions.add({
  { id = 'work.api-review', group = 'Review', name = 'Review changes using API credits', key = '<leader>CR', on = 'editor', available = claude_api,
    about = 'Review the uncommitted changes on API credits, read-only; you choose the model and a budget first', run = function() M.api_review() end },
  { id = 'work.api-ask', group = 'Claude', name = 'Ask using API credits', key = '<leader>Ca', on = 'editor', available = claude_api,
    about = 'Ask about this project on API credits, read-only (a visual selection goes along as an excerpt)', run = function() M.api_task() end },
  { id = 'work.api-ask-selection', group = 'Claude', name = 'Explain selection using API credits', key = '<leader>Ca', mode = 'x', on = 'editor',
    line = 'work.api-ask', menu = false,
    run = function()
      local a,b = vim.fn.line('v'),vim.fn.line('.')
      vim.api.nvim_feedkeys(vim.keycode('<Esc>'),'nx',false)
      M.api_task({math.min(a,b),math.max(a,b)})
    end },
  { id = 'work.tests', group = 'Work', name = 'Claude test failures', key = '<leader>Ce', on = 'editor', remote = true, also = '`:WorkTests`',
    available = desk_work, about = "The last test run's failures as a jump list (its log when it has no locations)", run = function() M.tests() end },
  { id = 'work.coverage', group = 'Work', name = "A test run's coverage in this file", on = 'editor', available = desk_work,
    about = "The lines and functions one test run covered, marked in this file (a run that wrote lcov.info, or one desk-work coverage add gave); the run, its command, executable and commit said with it. When the file changed since that run, the version that ran opens beside it with the marks (gf: the file as it is now), or this file gets them on the lines unchanged since. A second run chosen is compared with the first (both ran █, only the first ▌, only the second ▐, neither ·) or replaces it; the shown run again takes the marks off",
    run = function() M.coverage() end },
  { id = 'work.tasks', group = 'Work', name = 'Project next steps', key = '<leader>Ck', on = 'editor', available = desk_work,
    about = 'Pinned next steps for this project: pin one, mark it done, or turn it into a note for Claude', run = function() M.tasks() end },
})

function M.setup()
  require('desk.workspace').setup()
  pcall(function() require('desk.since').setup() end)
  pcall(function() require('desk.callgraph').setup() end)
  pcall(function() require('desk.bridge').setup() end)   -- messages from other programs, over this editor's socket
  pcall(function() require('desk.popout').setup() end)   -- the pop-out window, on the other screen
  pcall(function() require('desk.map').setup() end)
  vim.api.nvim_create_user_command('ClaudeApi', function(opts)
    M.api_task(opts.range > 0 and {opts.line1, opts.line2} or nil)
  end, {range=true, desc='Ask a read-only question using API credits'})
  vim.api.nvim_create_user_command('ClaudeApiStop', function()
    if api_job then api_job:kill(2) else vim.notify('No API task is running.') end
  end, {desc='Stop the running API task'})
  vim.api.nvim_create_user_command('ClaudeApiReview', function() M.api_review() end,
    {desc='Review uncommitted changes using API credits'})
  actions.map('editor', { rows = ROWS })
  vim.api.nvim_create_user_command("WorkTests", function() M.tests() end, {})
  vim.api.nvim_create_user_command("WorkTasks", function() M.tasks() end, {})
  vim.api.nvim_create_user_command('WorkAttention', function() M.attention() end, {})
  vim.api.nvim_create_user_command('WorkNext', function() M.attention(true) end, {})
  vim.api.nvim_create_user_command('WorkTimeline', function() M.history(false) end, {})
  vim.api.nvim_create_user_command('WorkDigest', function() M.history(true) end, {})
  vim.api.nvim_create_user_command('WorkSnooze', function() M.snooze(false) end, {})
  vim.api.nvim_create_user_command('WorkUnsnooze', function() M.snooze(true) end, {})
  vim.api.nvim_create_user_command('WorkSuggestedTests', function() M.suggested_tests() end, {})
  vim.api.nvim_create_user_command('WorkHealth', function() M.health() end, {})
  vim.api.nvim_create_user_command('WorkBackups', function() M.backups() end, {})
  vim.api.nvim_create_user_command('WorkRepair', function() M.repair() end, {})
  vim.api.nvim_create_user_command('ReviewFiles', function() require('desk.review').toggle_panel() end, {})
end
return M
