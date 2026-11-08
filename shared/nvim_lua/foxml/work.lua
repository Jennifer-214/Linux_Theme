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
  vim.cmd("silent! argdelete *")
  if action == "tests" then M.tests(id, index)
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
  vim.api.nvim_create_user_command("WorkTests", function() M.tests() end, {})
  vim.api.nvim_create_user_command("WorkTasks", function() M.tasks() end, {})
  vim.keymap.set("n", "<leader>Ce", function() M.tests() end, { desc = "Claude test failures" })
  vim.keymap.set("n", "<leader>Ck", function() M.tasks() end, { desc = "Project next steps" })
end
return M
