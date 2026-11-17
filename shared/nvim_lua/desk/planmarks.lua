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

local function stamp(path)
  local st = path and uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec .. ":" .. st.size) or nil
end

-- A file is read again only when its mtime or size changed.
local lines_cache = {}
local function lines_of(path)
  local now = stamp(path)
  if not now then return nil end
  local hit = lines_cache[path]
  if hit and hit.stamp == now then return hit.lines end
  local text = read(path)
  if not text then return nil end
  lines_cache[path] = { stamp = now, lines = vim.split(text, "\n", { plain = true }) }
  return lines_cache[path].lines
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
local function ls_files(root, done)
  local function back(out)
    vim.schedule(function()
      tracked_cache[root] = out and out.code == 0 and vim.split(out.stdout or "", "\n", { trimempty = true }) or {}
      done()
    end)
  end
  if not pcall(vim.system, { "git", "--no-optional-locks", "-C", root, "ls-files" }, { text = true, timeout = 5000 }, back) then
    back(nil)
  end
end

local function tracked(root)
  if tracked_cache[root] then return tracked_cache[root] end
  -- refresh() fills the list in the background first; only a direct caller of resolve() waits here.
  local ok, job = pcall(vim.system, { "git", "--no-optional-locks", "-C", root, "ls-files" }, { text = true })
  local out = ok and job:wait(5000) or {}
  tracked_cache[root] = out.code == 0 and vim.split(out.stdout or "", "\n", { trimempty = true }) or {}
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
-- Each live session here with the plan pinned in its notebook (desk-work plan), read in the background.
function M.pins(root, done)
  local ok, claude = pcall(require, "desk.claude")
  local sessions = ok and claude.in_repo(root, claude.live) or {}
  local entries, left = {}, #sessions
  for i, p in ipairs(sessions) do entries[i] = { session = p } end
  if left == 0 or vim.fn.executable("desk-work") ~= 1 then return done(entries) end
  for i, p in ipairs(sessions) do
    local function back(out)
      vim.schedule(function()
        entries[i].pin = out and out.code == 0 and claude.decode(out.stdout) or nil
        left = left - 1
        if left == 0 then done(entries) end
      end)
    end
    if not pcall(vim.system, { "desk-work", "plan", "--root", root, "--session", p.id }, { text = true, timeout = 3000 }, back) then
      back(nil)
    end
  end
end

-- The newest pin, else the plan a session read last; a plan chosen with :PlanMarks wins over both.
function M.choose(entries)
  local best
  for _, e in ipairs(entries or {}) do
    local pin = e.pin
    if type(pin) == "table" and type(pin.file) == "string" and uv.fs_stat(pin.file) then
      if not best or (pin.at or 0) > best.at then best = { file = pin.file, at = pin.at or 0 } end
    end
  end
  if not best then
    for _, e in ipairs(entries or {}) do
      local ledger = e.session.ledger or {}
      if type(ledger.plan) == "string" and uv.fs_stat(ledger.plan) and (not best or (ledger.plan_at or 0) > best.at) then
        best = { file = ledger.plan, at = ledger.plan_at or 0 }
      end
    end
  end
  if M.chosen and uv.fs_stat(M.chosen) then best = { file = M.chosen, at = math.huge } end
  return best
end

-- ─── marks ──────────────────────────────────────────────────────────────────────────────────────────────────────
function M.build(root, plan)
  local marks, cache = {}, {}
  for _, ref in ipairs(M.parse(plan.text)) do
    local file = M.resolve(root, ref.path)
    local mark = { file = file or (root .. "/" .. ref.path), path = ref.path, step = ref.step, line = ref.line or 1, last = ref.last }
    mark.real = uv.fs_realpath(mark.file) or mark.file
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
    if not m.drifted and (m.real or m.file) == name and m.line <= count and not shown[m.line] then
      shown[m.line] = true
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.line - 1, 0, {
        sign_text = "✎", sign_hl_group = "FoxPlanSign",
        virt_text = { { "  " .. m.step .. " · " .. short_title(M.plan), "FoxPlanNote" } }, virt_text_pos = "eol",
        priority = 15,
      })
    end
  end
end

-- Buffers in a window; a hidden one is painted when it is shown (BufWinEnter).
local function paint_shown()
  local done = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not done[buf] then done[buf] = true; M.paint(buf) end
  end
end

-- What the marks were built from besides the plan: each file they point at (or that was missing).
local function files_key(marks)
  local seen, parts = {}, {}
  for _, m in ipairs(marks or {}) do
    if not seen[m.file] then seen[m.file] = true; parts[#parts + 1] = m.file .. "=" .. (stamp(m.file) or "-") end
  end
  table.sort(parts)
  return table.concat(parts, "\n")
end

-- Nothing here waits on a command. The marks are built again only when the chosen plan, its file, the git index
-- (files added or removed) or a file a mark points at changed. done() runs once the marks are current.
local refreshing, queued = false, nil
function M.refresh(done)
  if refreshing then
    queued = queued or {}
    queued[#queued + 1] = done or false
    return
  end
  refreshing = true
  local root = vim.fs.root(0, ".git") or vim.fn.getcwd()
  local function finish()
    refreshing = false
    local waiting = queued
    queued = nil
    if waiting then M.refresh(function() for _, d in ipairs(waiting) do if d then d() end end end) end
    if done then done() end
  end
  -- An error part way must not leave refreshing set, or the marks would never be read again.
  local function guarded(fn)
    return function(...)
      local ok, err = pcall(fn, ...)
      if not ok then refreshing, queued = false, nil; error(err, 0) end
    end
  end
  M.pins(root, guarded(function(entries)
    local best = M.choose(entries)
    local key = best and table.concat({ root, best.file, tostring(best.at), stamp(best.file) or "",
                                        stamp(root .. "/.git/index") or "" }, "\0")
    if key == M.key and (not key or files_key(M.marks) == M.files_key) then return finish() end
    if not best then
      M.plan, M.marks, M.key, M.files_key = nil, {}, nil, nil
      paint_shown()
      return finish()
    end
    ls_files(root, guarded(function()
      local text = read(best.file) or ""
      best.title = text:match("^#%s+(.-)%s*\n") or vim.fn.fnamemodify(best.file, ":t:r")
      best.text = text
      M.plan, M.marks = best, M.build(root, best)
      M.key, M.files_key = key, files_key(M.marks)
      paint_shown()
      finish()
    end))
  end))
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
      local f = m.real or m.file
      if f > here or (f == here and m.line > line) then pick = m; break end
    end
    pick = pick or list[1]
  else
    for i = #list, 1, -1 do
      local m = list[i]; local f = m.real or m.file
      if f < here or (f == here and m.line < line) then pick = m; break end
    end
    pick = pick or list[#list]
  end
  if (pick.real or pick.file) ~= here or not require("desk.nav").code_window(vim.api.nvim_get_current_win()) then
    require("desk.nav").open_code(pick.file)
  end
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
  if vim.g.desk_popout then return end   -- a pop-out (desk.popout) shows no code to mark
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
    M.refresh(M.list)
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
