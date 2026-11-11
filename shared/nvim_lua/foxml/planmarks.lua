-- Plan marks: the places the current plan names, marked where they are.
--
-- The plan is the one pinned in a Claude session's notebook here (newest first), else the plan a session read
-- last (what :Plan opens). Its references — `path`, `path:42`, `path:42-60`, and a path beside `name()` — become
-- a pink ✎ in the sign column with a dim "step 3 · plan" note; ]n / [n jump between them, Space Cm lists them by
-- step, and a reference that no longer resolves (missing file, line past the end, function not found) is listed
-- as drifted. A function is found by vim.g.foxml_plan_symbol_resolver(file, name) when something (symdeps)
-- provides one, else by a plain search for its definition. Local and instant; nothing here asks a model.
local M = {}
local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace("foxml_plan_marks")

M.enabled = true
M.plan = nil      -- { file, title, at }
M.marks = {}      -- { file, line, last, step, label, drifted, why }

-- A bare name counts as a file only with one of these; a path with a folder counts with any extension.
local CODE = {}
for ext in ("c cc cpp cxx h hh hpp hxx inc def lua py pyi ts tsx js mjs cjs json jsonc md qml sh zsh bash conf toml yaml yml "
            .. "css scss html txt ini go rs cmake service timer rules tmpl kdl nix sql"):gmatch("%S+") do CODE[ext] = true end

local function read(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local text = fd:read("*a"); fd:close()
  return text
end

local function lines_of(path)
  local text = read(path)
  if not text then return nil end
  return vim.split(text, "\n", { plain = true })
end

-- ─── reading a plan ─────────────────────────────────────────────────────────────────────────────────────────────
-- Each reference with the step it sits under: a numbered item ("step 3") when the plan numbers its steps, else
-- the nearest heading. Code fences are skipped; a reference inside backticks or bare both count.
function M.parse(text)
  local refs, step, heading = {}, nil, nil
  local fence = false
  for raw in (text or ""):gmatch("[^\n]*") do
    local line = raw
    if line:match("^%s*```") or line:match("^%s*~~~") then fence = not fence
    elseif not fence then
      local h = line:match("^#+%s+(.-)%s*$")
      if h then heading = h; step = nil end
      local n = line:match("^(%d+)[.)]%s") or line:match("^%s*%- %[.%]%s+(%d+)[.)]%s")
      if n then step = "step " .. n end
      local where = step or (heading and heading:gsub("^%d+[.)]%s*", ""):sub(1, 40)) or "plan"
      -- Each path with the text up to the next one: a `name()` there belongs to this path, not to its neighbours.
      local found = {}
      for at, path, rest, stop in line:gmatch("()(~?[%w_%-%./]+%.[%a][%w]*)(:?[%d%-]*)()") do
        found[#found + 1] = { at = at, path = path, rest = rest, stop = stop }
      end
      for i, f in ipairs(found) do
        local path, rest = f.path, f.rest
        local ext = path:match("%.([%w]+)$")
        local folder = path:find("/") ~= nil
        if (folder or CODE[ext]) and not path:match("^%d") and not path:match("://") and not path:match("^%.%.?$") then
          local first, last = rest:match("^:(%d+)%-(%d+)$")
          if not first then first = rest:match("^:(%d+)$") end
          local after = line:sub(f.stop, (found[i + 1] and found[i + 1].at or #line + 1) - 1)
          local symbol = not first and (after:match("^[%s`]*([%w_:~]+)%(%)") or after:match("`([%w_:~]+)%(%)`")) or nil
          -- Only a clear reference (a folder, or a line) may be called drifted; a bare name that finds nothing is just a word.
          refs[#refs + 1] = { path = path, line = tonumber(first), last = tonumber(last), symbol = symbol,
                              step = where, clear = folder or first ~= nil }
        end
      end
    end
  end
  return refs
end

-- ─── finding things ─────────────────────────────────────────────────────────────────────────────────────────────
local tracked_cache = {}
local function tracked(root)
  if tracked_cache[root] then return tracked_cache[root] end
  local out = vim.fn.systemlist({ "git", "--no-optional-locks", "-C", root, "ls-files" })
  tracked_cache[root] = vim.v.shell_error == 0 and out or {}
  return tracked_cache[root]
end

-- "drawer.cpp" or "modules/drawer.cpp" to the one tracked file it names; nil when none or several match.
function M.resolve(root, path)
  if path:sub(1, 1) == "~" then path = vim.fn.expand(path) end
  local direct = root .. "/" .. path
  if uv.fs_stat(direct) then return direct end
  if path:sub(1, 1) == "/" and uv.fs_stat(path) then return path end
  local found
  for _, f in ipairs(tracked(root)) do
    if f == path or f:sub(-(#path + 1)) == "/" .. path then
      if found then return nil end
      found = root .. "/" .. f
    end
  end
  return found
end

function M.find_symbol(file, name, lines)
  local resolver = vim.g.foxml_plan_symbol_resolver
  if type(resolver) == "function" then
    local ok, line = pcall(resolver, file, name)
    if ok and type(line) == "number" then return line end
  end
  local short = name:match("([%w_~]+)$") or name
  local first
  for i, l in ipairs(lines) do
    if l:find(short .. "%s*%(") and not l:match("^%s*//") and not l:match("^%s*%-%-") and not l:match("^%s*#") then
      local before = l:sub(1, (l:find(short .. "%s*%(")) - 1)
      -- A definition: a Lua function, or a C-style line where the name follows only its type (no "=", no "return").
      if l:match("function[%s%w_.:]*" .. short .. "%s*%(")
        or (not before:find("[=(]") and not before:match("return") and not before:match("^%s*$") and not l:match(";%s*$")) then
        return i
      end
      first = first or i
    end
  end
  return first
end

-- ─── which plan ─────────────────────────────────────────────────────────────────────────────────────────────────
function M.current_plan(root)
  local ok, claude = pcall(require, "foxml.claude")
  local best
  if ok then
    for _, p in ipairs(claude.in_repo(root, claude.live) or {}) do
      local out = vim.fn.system({ "desk-work", "plan", "--root", root, "--session", p.id })
      local pin = vim.v.shell_error == 0 and claude.decode(out) or nil
      if type(pin) == "table" and type(pin.file) == "string" and uv.fs_stat(pin.file) then
        if not best or (pin.at or 0) > best.at then best = { file = pin.file, at = pin.at or 0 } end
      end
    end
    if not best then
      for _, p in ipairs(claude.in_repo(root, claude.live) or {}) do
        local plan = (p.ledger or {}).plan
        if type(plan) == "string" and uv.fs_stat(plan) and (not best or (p.ledger.plan_at or 0) > best.at) then
          best = { file = plan, at = p.ledger.plan_at or 0 }
        end
      end
    end
  end
  if M.chosen and uv.fs_stat(M.chosen) then best = { file = M.chosen, at = math.huge } end
  if not best then return nil end
  local text = read(best.file) or ""
  best.title = text:match("^#%s+(.-)%s*\n") or vim.fn.fnamemodify(best.file, ":t:r")
  best.text = text
  return best
end

-- ─── marks ──────────────────────────────────────────────────────────────────────────────────────────────────────
function M.build(root, plan)
  local marks, cache = {}, {}
  for _, ref in ipairs(M.parse(plan.text)) do
    local file = M.resolve(root, ref.path)
    local mark = { file = file or (root .. "/" .. ref.path), path = ref.path, step = ref.step, line = ref.line or 1, last = ref.last }
    if not file and not ref.clear then
      mark = nil
    elseif not file then
      mark.drifted, mark.why = true, "no such file"
    else
      cache[file] = cache[file] or lines_of(file) or {}
      local lines = cache[file]
      if ref.symbol then
        local at = M.find_symbol(file, ref.symbol, lines)
        if at then mark.line = at; mark.symbol = ref.symbol else mark.drifted, mark.why = true, ref.symbol .. "() not found" end
      elseif ref.line and ref.line > #lines then
        mark.drifted, mark.why = true, "line " .. ref.line .. " is past the end (" .. #lines .. " lines)"
      end
    end
    if mark then marks[#marks + 1] = mark end
  end
  return marks
end

local function short_title(plan)
  local t = (plan and plan.title or "plan"):gsub("^Plan:?%s*", "")
  return #t > 28 and (t:sub(1, 27) .. "…") or t
end

function M.paint(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not M.enabled or not M.plan then return end
  local name = uv.fs_realpath(vim.api.nvim_buf_get_name(buf)) or vim.api.nvim_buf_get_name(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local shown = {}
  for _, m in ipairs(M.marks) do
    if not m.drifted and (uv.fs_realpath(m.file) or m.file) == name and m.line <= count and not shown[m.line] then
      shown[m.line] = true
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.line - 1, 0, {
        sign_text = "✎", sign_hl_group = "FoxPlanSign",
        virt_text = { { "  " .. m.step .. " · " .. short_title(M.plan), "FoxPlanNote" } }, virt_text_pos = "eol",
        priority = 15,
      })
    end
  end
end

function M.refresh()
  local root = vim.fs.root(0, ".git") or vim.fn.getcwd()
  tracked_cache[root] = nil
  local plan = M.current_plan(root)
  M.plan, M.marks = plan, plan and M.build(root, plan) or {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_is_loaded(buf) then M.paint(buf) end end
end

-- The live marks in order (file, then line), for ]n / [n.
local function ordered()
  local live = {}
  for _, m in ipairs(M.marks) do if not m.drifted then live[#live + 1] = m end end
  table.sort(live, function(a, b) return a.file == b.file and a.line < b.line or a.file < b.file end)
  return live
end

function M.jump(direction)
  local list = ordered()
  if #list == 0 then vim.notify("no plan marks here", vim.log.levels.INFO, { title = "Plan" }); return end
  local here = uv.fs_realpath(vim.api.nvim_buf_get_name(0)) or ""
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local pick
  if direction > 0 then
    for _, m in ipairs(list) do
      local f = uv.fs_realpath(m.file) or m.file
      if f > here or (f == here and m.line > line) then pick = m; break end
    end
    pick = pick or list[1]
  else
    for i = #list, 1, -1 do
      local m = list[i]; local f = uv.fs_realpath(m.file) or m.file
      if f < here or (f == here and m.line < line) then pick = m; break end
    end
    pick = pick or list[#list]
  end
  if (uv.fs_realpath(pick.file) or pick.file) ~= here then vim.cmd("edit " .. vim.fn.fnameescape(pick.file)) end
  vim.api.nvim_win_set_cursor(0, { math.min(pick.line, vim.api.nvim_buf_line_count(0)), 0 })
  vim.cmd("normal! zz")
end

-- Every mark grouped by step, drifted ones saying why, in the quickfix list.
function M.list()
  if not M.plan then vim.notify("no plan to mark: pin one in the notebook, or :PlanMarks path/to/plan.md", vim.log.levels.INFO, { title = "Plan" }); return end
  local items = {}
  for _, m in ipairs(M.marks) do
    items[#items + 1] = { filename = m.file, lnum = m.line, col = 1, type = m.drifted and "W" or "I",
                          text = m.step .. (m.symbol and (" · " .. m.symbol .. "()") or "") .. (m.drifted and (" · drifted: " .. m.why) or "") }
  end
  vim.fn.setqflist({}, " ", { title = "plan · " .. short_title(M.plan), items = items })
  vim.cmd("botright copen")
end

function M.setup()
  vim.api.nvim_set_hl(0, "FoxPlanSign", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "FoxPlanNote", { default = true, link = "Comment" })
  local group = vim.api.nvim_create_augroup("foxml_plan_marks", { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", { group = group, callback = function(e) M.paint(e.buf) end })
  vim.api.nvim_create_autocmd("BufWritePost", { group = group, callback = function(e)
    if M.plan and (uv.fs_realpath(e.file) or e.file) == (uv.fs_realpath(M.plan.file) or M.plan.file) then M.refresh() end
  end })
  -- Sessions and pins change while she works; a calm re-read every half minute, and once Claude's poll has run.
  vim.defer_fn(M.refresh, 4000)
  local timer = uv.new_timer()
  if timer then timer:start(30000, 30000, vim.schedule_wrap(M.refresh)) end
  vim.api.nvim_create_user_command("PlanMarks", function(o)
    if o.args ~= "" then M.chosen = vim.fn.fnamemodify(o.args, ":p") end
    M.refresh(); M.list()
  end, { nargs = "?", complete = "file", desc = "Mark the places the plan names (optionally: this plan)" })
  vim.api.nvim_create_user_command("PlanMarksToggle", function()
    M.enabled = not M.enabled
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_is_loaded(buf) then M.paint(buf) end end
    vim.notify(M.enabled and "plan marks shown" or "plan marks hidden", vim.log.levels.INFO, { title = "Plan" })
  end, { desc = "Show or hide plan marks" })
  vim.keymap.set("n", "]n", function() M.jump(1) end, { desc = "Next plan mark" })
  vim.keymap.set("n", "[n", function() M.jump(-1) end, { desc = "Previous plan mark" })
  vim.keymap.set("n", "<leader>Cm", M.list, { desc = "Plan marks, by step" })
  vim.keymap.set("n", "<leader>tP", "<cmd>PlanMarksToggle<cr>", { desc = "Toggle plan marks" })
end

return M
