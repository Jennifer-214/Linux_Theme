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

local api_job
function M.api_task(selection)
  if api_job then vim.notify('An API task is already running. :ClaudeApiStop cancels it.'); return end
  if vim.fn.executable('fox-claude-api') ~= 1 then vim.notify('Install fox-claude-api first.', vim.log.levels.WARN); return end
  local current_root = (vim.uv or vim.loop).fs_realpath(root()) or root()
  local file = vim.api.nvim_buf_get_name(0)
  local context = ''
  if selection then
    context = table.concat(vim.api.nvim_buf_get_lines(0, selection[1]-1, selection[2], false), '\n')
    if #context > 24000 then vim.notify('Select a smaller excerpt (up to 24 KB).', vim.log.levels.WARN); return end
  end
  local out = vim.system({'fox-claude-api', 'projects'}, {text=true}):wait(3000)
  local ok, projects = pcall(vim.json.decode, out.stdout or '')
  if not ok or type(projects) ~= 'table' then vim.notify('API task settings are unavailable.', vim.log.levels.WARN); return end
  local function choose(project)
    if not project then return end
    local local_project = current_root == project.root or current_root:sub(1, #project.root+1) == project.root .. '/'
    local left = type(project.credits) == 'string' and (' (' .. project.credits .. ')') or ''
    vim.ui.input({prompt=project.label .. left .. ' API task: '}, function(question)
      if not question or vim.trim(question) == '' then return end
      vim.ui.input({prompt='Run budget USD (Enter starts): ', default=project.budget_usd or '1.00'}, function(limit)
        if not limit or vim.trim(limit) == '' then return end
        if api_job then vim.notify('An API task is already running.'); return end
        local argv = {'fox-claude-api', 'run', '--project', project.id, '--budget', limit, '--prompt-stdin', '--json'}
        if local_project then
          vim.list_extend(argv, {'--root', current_root})
          if file ~= '' and vim.fn.filereadable(file) == 1 then vim.list_extend(argv, {'--context-file', file}) end
          if context ~= '' then question = question .. '\n\nSelected excerpt from ' .. file .. ':\n' .. context end
        end
        api_job = vim.system(argv, {text=true, stdin=question}, vim.schedule_wrap(function(result)
          api_job = nil
          local parsed, value = pcall(vim.json.decode, result.stdout or '')
          if not parsed or type(value) ~= 'table' then
            vim.notify(result.stderr or 'API task failed.', vim.log.levels.WARN); return
          end
          local price = value.cost_usd and ('$' .. value.cost_usd .. ' estimated') or 'cost unknown'
          local heading = '# ' .. project.label .. ' · ' .. value.status .. '\n\n' .. price
            .. ' · budget $' .. value.budget_usd .. '\n'
            .. (value.tracked and 'Added to the tracked-only meter.' or 'Cost not recorded in the meter.')
            .. '\n\nq / Esc / Space Cq closes this result.\n\n'
          local buf = vim.api.nvim_create_buf(false, true)
          vim.api.nvim_buf_set_lines(buf,0,-1,false,vim.split(heading .. (value.result or ''), '\n', {plain=true}))
          vim.bo[buf].filetype, vim.bo[buf].bufhidden, vim.bo[buf].modifiable = 'markdown', 'wipe', false
          local width, height = math.max(20, math.min(110, vim.o.columns-6)), math.max(3, vim.o.lines-8)
          local win = vim.api.nvim_open_win(buf,true,{relative='editor',width=width,height=height,
            col=math.max(0,math.floor((vim.o.columns-width)/2)),row=2,style='minimal',border='rounded',title=' API review '})
          vim.wo[win].wrap = true
          local function close() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win,false) end end
          for _, key in ipairs({'q','<Esc>','<leader>Cq'}) do vim.keymap.set('n',key,close,{buffer=buf,desc='Close API result'}) end
        end))
        vim.notify(project.label .. ' API task started · budget $' .. limit .. ' · :ClaudeApiStop cancels')
      end)
    end)
  end
  for _, project in ipairs(projects) do
    if current_root == project.root or current_root:sub(1, #project.root+1) == project.root .. '/' then choose(project); return end
  end
  local heading = projects[1] and type(projects[1].credits) == 'string' and (' · ' .. projects[1].credits) or ''
  vim.ui.select(projects,{prompt='Review with API credits' .. heading,format_item=function(p) return p.label end},choose)
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
  vim.keymap.set('n','<leader>Ca',function() M.api_task() end,{desc='Ask using API credits'})
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
