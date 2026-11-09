local M = {}
local function run(args)
  local argv = { "fox-work" }
  vim.list_extend(argv, args)
  local ok, p = pcall(vim.system, argv, { text = true })
  if not ok then return nil end
  local out = p:wait(15000)
  if out.code ~= 0 then vim.notify(out.stderr or "Work record unavailable", vim.log.levels.WARN); return nil end
  return out.stdout
end
local function data(args)
  local ok, j = pcall(vim.json.decode, run(args) or "null")
  return ok and j ~= vim.NIL and j or nil
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

-- API tasks (fox-claude-api): read-only reviews on API credits, with a model choice, live progress,
-- follow-ups and results whose path:line citations become a quickfix list.
local api_job
local function api_projects()
  local ok, out = pcall(function() return vim.system({'fox-claude-api', 'projects'}, {text=true}):wait(5000) end)
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

-- Called in a buffer holding a saved result (fox-claude-api open, or a finished :ClaudeApi run).
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
    local ok, out = pcall(function() return vim.system({'fox-claude-api', 'history'}, {text=true}):wait(5000) end)
    local parsed, rows = pcall(vim.json.decode, ok and out.stdout or '')
    for _, row in ipairs(parsed and type(rows) == 'table' and rows or {}) do if row.id == id then project_id = row.project end end
    local items = M.api_citations(vim.api.nvim_buf_get_lines(buf, 0, -1, false), folder)
    vim.fn.setqflist({}, ' ', {title='API answer citations', items=items})
    local function jump()
      local line = vim.api.nvim_get_current_line()
      local hit = M.api_citations({line}, folder)[1]
      if hit then vim.cmd('edit ' .. vim.fn.fnameescape(hit.filename)); vim.api.nvim_win_set_cursor(0, {hit.lnum, 0}) end
    end
    vim.keymap.set('n', '<CR>', jump, {buffer=buf, desc='Open the cited file and line'})
    if project_id then vim.keymap.set('n', 'f', function() api_follow(id, project_id) end, {buffer=buf, desc='Ask a follow-up'}) end
    vim.notify(#items .. ' cited lines in the quickfix list (:copen) · Enter opens one · f asks a follow-up · q closes')
  end
  vim.keymap.set('n', 'q', '<cmd>bwipeout<cr>', {buffer=buf, desc='Close API result'})
end

-- Starts fox-claude-api run; progress lines arrive on stderr, the result as JSON on stdout.
function M.api_run(project, question, extra, opts)
  opts = opts or {}
  if api_job then vim.notify('An API task is already running. :ClaudeApiStop cancels it.'); return end
  local argv = {'fox-claude-api', 'run', '--project', project.id, '--prompt-stdin', '--json'}
  if opts.model then vim.list_extend(argv, {'--model', opts.model}) end
  if opts.budget then vim.list_extend(argv, {'--budget', opts.budget}) end
  vim.list_extend(argv, extra or {})
  local progress = {title='API task', id='fox-claude-api'}
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
    local md = vim.system({'fox-claude-api', 'show', value.id}, {text=true}):wait(5000)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(md.stdout or value.result or '', '\n', {plain=true}))
    vim.bo[buf].bufhidden = 'wipe'
    vim.cmd('tab sbuffer ' .. buf)
    M.api_result_opened(buf)
  end))
  vim.notify(project.label .. ' API task started' .. (opts.model and (' · ' .. opts.model) or '') .. ' · :ClaudeApiStop cancels',
    vim.log.levels.INFO, progress)
end

local function api_choose_project(callback)
  if vim.fn.executable('fox-claude-api') ~= 1 then vim.notify('Install fox-claude-api first.', vim.log.levels.WARN); return end
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
    local C = require("foxml.claude")
    local dir = C.runtime()
    if not dir then vim.notify("No local Claude inbox is available."); return end
    local ok, p = pcall(vim.system, { "fox-drawer", "claude-peers" }, { text = true })
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

function M.open_args()
  local args = vim.fn.argv()
  local action = (args[1] or ""):match("^foxml%-work:(.+)$")
  local id, index = args[2] or "", args[3]
  if not action then return end
  vim.g.foxml_work_view = true
  vim.keymap.set("n", "<leader>Cq", function() require("foxml.claude").close() end, { desc = "Close work viewer" })
  if action == "file-diff" or action == "reviews" then
    vim.keymap.set("n", "q", function() require("foxml.claude").close() end, { desc = "Close Claude review" })
  end
  vim.cmd("silent! argdelete *")
  if action == "file" then vim.cmd("edit " .. vim.fn.fnameescape(id))
  elseif action == "file-diff" then
    local C = require("foxml.claude")
    local ledger = {}
    if type(index) == "string" and index:match("^[A-Za-z0-9_-]+$") and #index <= 80 and C.runtime() then
      ledger = C.decode(C.read(C.runtime() .. "/edits/" .. index .. ".json")) or {}
    end
    C.open_review({ kind = "live", sid = index or "", name = "notebook", short = "notebook",
      files = { id }, before = ledger.before or {}, label = "notebook change" }, root())
    C.diff(id)
  elseif action == "workspace" then vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd()))
  elseif action == "tests" then M.tests(id, index)
  elseif action == "compare" then M.compare(id)
  elseif action == "reviews" then
    local C = require("foxml.claude")
    if id ~= "" then
      for _, row in ipairs(C.rows(root())) do if row.kind == "commit" and row.sha == id then C.open_review(row, root()); return end end
    end
    C.changes(true)
  elseif action == "tasks" then M.tasks(root(), id)
  elseif action == "ask" then M.ask(id)
  elseif action == "ask-service" then M.ask(nil, id)
  elseif action == "service" then scratch(run({ "service-log", "--unit", id }), "service log", "text")
  elseif action == "log" then scratch(run({ "log", "--id", id }), "job output", "text") end
end

function M.setup()
  vim.api.nvim_create_user_command('ClaudeApi', function(opts)
    M.api_task(opts.range > 0 and {opts.line1, opts.line2} or nil)
  end, {range=true, desc='Ask a read-only question using API credits'})
  vim.api.nvim_create_user_command('ClaudeApiStop', function()
    if api_job then api_job:kill(2) else vim.notify('No API task is running.') end
  end, {desc='Stop the running API task'})
  vim.api.nvim_create_user_command('ClaudeApiReview', function() M.api_review() end,
    {desc='Review uncommitted changes using API credits'})
  vim.keymap.set('n','<leader>Ca',function() M.api_task() end,{desc='Ask using API credits'})
  vim.keymap.set('n','<leader>CR',function() M.api_review() end,{desc='Review changes using API credits'})
  vim.keymap.set('x','<leader>Ca',function()
    local a,b = vim.fn.line('v'),vim.fn.line('.')
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'),'nx',false)
    M.api_task({math.min(a,b),math.max(a,b)})
  end,{desc='Explain selection using API credits'})
  vim.api.nvim_create_user_command("WorkTests", function() M.tests() end, {})
  vim.api.nvim_create_user_command("WorkTasks", function() M.tasks() end, {})
  vim.keymap.set("n", "<leader>Ce", function() M.tests() end, { desc = "Claude test failures" })
  vim.keymap.set("n", "<leader>Ck", function() M.tasks() end, { desc = "Project next steps" })
end
return M
