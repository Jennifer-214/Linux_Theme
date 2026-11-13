-- foxml.claude — nvim knows the other Claudes on this machine.
--
-- Reads what the paper mod and desk-drawer already keep ($XDG_RUNTIME_DIR/foxml-claude: <sid>.state/.json, the
-- edits ledgers and before-copies; $XDG_STATE_HOME/foxml/claude-sessions.jsonl, the commit names) and git. Writes
-- only notes into a session's inbox. Shows: footprints (who edited this buffer lately), the plan gate and who needs
-- you, a "what changed" list of live sessions and commits in a read-only comparison, following a session,
-- and blame that names the Claude session behind a line. Colours come from the caller (the template's palette).
local M = {}
local uv = vim.uv or vim.loop

M.window_s = 15 * 60
M.live = {}          -- the other live sessions, refreshed every few seconds
M.review = nil       -- the change set under review
M.following = nil    -- the session being followed
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
local SID = "^[%w_-]+$"
local function drawer_tool()
  return vim.fn.executable("desk-drawer") == 1 and "desk-drawer" or "fox-drawer"
end

-- ─── small helpers ────────────────────────────────────────────────────────────────────────────────────────────
function M.read(path)
  local f = path and io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

function M.decode(text)
  if not text or text == "" then return nil end
  local ok, value = pcall(vim.json.decode, text)
  return ok and type(value) == "table" and value or nil
end

function M.runtime()
  local base = os.getenv("XDG_RUNTIME_DIR")
  return base and base ~= "" and (base .. "/foxml-claude") or nil
end

function M.names_file()
  local state = os.getenv("XDG_STATE_HOME")
  if not state or state == "" then state = (os.getenv("HOME") or "") .. "/.local/state" end
  return state .. "/foxml/claude-sessions.jsonl"
end

-- "just now", "3m", "2h", "yesterday", "4d", "Oct 3"
function M.ago(seconds, at)
  if seconds < 60 then return "just now" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
  if seconds < 2 * 86400 then return "yesterday" end
  if seconds < 30 * 86400 then return math.floor(seconds / 86400) .. "d" end
  return os.date("%b %-d", at or (os.time() - seconds))
end

local function system(argv, timeout)
  local ok, job = pcall(vim.system, argv, { text = true })
  if not ok then return nil end
  local out = job:wait(timeout or 3000)
  return out.code == 0 and out.stdout or nil
end

-- ─── who is live ──────────────────────────────────────────────────────────────────────────────────────────────
-- A session as the drawer lists it, plus its ledger and the folder it works in.
function M.with_ledgers(peers, dir, read)
  read = read or M.read
  local live = {}
  for _, p in ipairs(peers or {}) do
    if type(p) == "table" and type(p.id) == "string" and p.id:match(SID) then
      local look = M.decode(read(dir .. "/" .. p.id .. ".json")) or {}
      p.ledger = M.decode(read(dir .. "/edits/" .. p.id .. ".json")) or { edits = {} }
      p.root = look.project or look.cwd or p.ledger.root
      live[#live + 1] = p
    end
  end
  return live
end

-- The live session that edited `path` within the window, newest first.
function M.footprint(path, now_ms, live)
  local best
  for _, p in ipairs(live or {}) do
    for _, e in ipairs((p.ledger or {}).edits or {}) do
      if e.path == path and now_ms - e.at <= M.window_s * 1000 and (not best or e.at > best.at) then
        best = { sid = p.id, name = p.name, pane = p.pane, at = e.at }
      end
    end
  end
  return best
end

-- Neo-tree's mark for a file the live sessions edited within the window: ✎ for one, ✎2 (warning colour) when two
-- or more share it, so the overlap shows before the file is opened. nil when none did.
function M.tree_mark(path, now_ms, live)
  local names = {}
  for _, p in ipairs(live or M.live or {}) do
    for _, e in ipairs((p.ledger or {}).edits or {}) do
      if e.path == path and now_ms - e.at <= M.window_s * 1000 then names[#names + 1] = p.name; break end
    end
  end
  if #names == 0 then return nil end
  if #names == 1 then return { text = "✎", hl = "FoxTreeClaude", who = names[1] } end
  return { text = "✎" .. #names, hl = "FoxTreeClaudeShared", who = table.concat(names, ", ") }
end

-- The files with a mark right now, as one string: Neo-tree redraws only when this changes.
function M.tree_signature(now_ms, live)
  local marked = {}
  for _, p in ipairs(live or M.live or {}) do
    for _, e in ipairs((p.ledger or {}).edits or {}) do
      if now_ms - e.at <= M.window_s * 1000 then marked[#marked + 1] = p.id .. "\0" .. e.path end
    end
  end
  table.sort(marked)
  return table.concat(marked, "\n")
end

function M.footprint_text(fp, now_ms)
  if not fp then return "" end
  return "✎ " .. fp.name .. " · " .. M.ago(math.max(0, (now_ms - fp.at) / 1000))
end

-- Sessions working in this repo.
function M.in_repo(root, live)
  local found = {}
  for _, p in ipairs(live or {}) do
    if root and p.root and (p.root == root or p.root:sub(1, #root + 1) == root .. "/") then found[#found + 1] = p end
  end
  return found
end

-- "gate open ✓" when every session in this repo is approved, "plan first ✎" when one is not; "" without a gate.
function M.gate_text(root, live, approved_text)
  if not approved_text then return "" end
  local here = M.in_repo(root, live)
  if #here == 0 then return "" end
  local approved = {}
  for line in approved_text:gmatch("[^\n]+") do approved[line:match("^(%S+)") or ""] = true end
  for _, p in ipairs(here) do
    if not approved[p.id] then return "plan first ✎" end
  end
  return "gate open ✓"
end

function M.needs_text(live)
  local waiting = {}
  for _, p in ipairs(live or {}) do if p.state == "needs you" then waiting[#waiting + 1] = p.name end end
  if #waiting == 0 then return "" end
  return "● " .. waiting[1] .. (#waiting > 1 and (" +" .. (#waiting - 1)) or "")
end

-- ─── notes ────────────────────────────────────────────────────────────────────────────────────────────────────
function M.note(text, file, first, last, code)
  local note = { from = "nvim", text = vim.trim(text):sub(1, 2000) }
  if file then note.file = file end
  if first then note.lines = first == last and tostring(first) or (first .. "-" .. last) end
  if code and code ~= "" then note.code = code:sub(1, 8000) end
  return note
end

function M.write_note(dir, sid, note)
  if not sid:match(SID) or note.text == "" then return false end
  local box = dir .. "/inbox/" .. sid
  vim.fn.mkdir(box, "p", tonumber("700", 8))
  local name = string.format("%d-%04x", math.floor(uv.hrtime() / 1000), math.random(0, 65535))
  local tmp = box .. "/." .. name .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(vim.json.encode(note))
  f:close()
  return uv.fs_rename(tmp, box .. "/" .. name .. ".json") == true
end

-- ─── commits ──────────────────────────────────────────────────────────────────────────────────────────────────
M.LOG_FORMAT = "%x1e%H%x1f%h%x1f%P%x1f%ct%x1f%an%x1f%s%x1f%(trailers:key=Claude-Session,valueonly,separator=%x2C)"
  .. "%x1f%(trailers:key=Co-Authored-By,valueonly,separator=%x2C)"

function M.parse_log(text)
  local commits = {}
  for record in (text or ""):gmatch("\30([^\30]*)") do
    local head, rest = record:match("^([^\n]*)\n?(.*)$")
    local f = vim.split(head or "", "\31", { plain = true })
    if #f >= 8 then
      local files = {}
      for line in rest:gmatch("[^\n]+") do files[#files + 1] = line end
      commits[#commits + 1] = {
        sha = f[1], short = f[2], parent = (f[3] or ""):match("^(%S+)"), at = tonumber(f[4]) or 0, author = f[5],
        subject = f[6], url = f[7]:match("(https://%S+)"), claude = f[7] ~= "" or (f[8] or ""):find("Claude") ~= nil,
        files = files,
      }
    end
  end
  return commits
end

function M.parse_names(text)
  local names = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local n = M.decode(line)
    if n and type(n.url) == "string" and type(n.title) == "string" then names[n.url] = n.title end
  end
  return names
end

function M.who(c, names, me)
  if c.claude then return "✿", (c.url and names[c.url]) or "Claude" end
  if c.author == me then return "●", "you" end
  return "·", c.author
end

function M.commit_label(c, names, me, now_s)
  local mark, who = M.who(c, names, me)
  local count = #c.files == 1 and "1 file" or (#c.files .. " files")
  return string.format("%s %s  %s · %s · %s  %s", mark, c.short, who, M.ago(now_s - c.at, c.at), c.subject, count)
end

function M.live_label(p, files)
  return string.format("✎ %s · %s · %d %s, not committed", p.name, p.state or "working", #files, #files == 1 and "file" or "files")
end

-- The files a live session edited that still differ from HEAD (absolute paths).
function M.live_files(p, dirty)
  local files = {}
  for _, e in ipairs((p.ledger or {}).all or (p.ledger or {}).edits or {}) do
    if dirty[e.path] then files[#files + 1] = e.path end
  end
  return files
end

function M.blame_text(info, trailer, names, me, now_s)
  if info.author == "Not Committed Yet" or (info.sha or ""):match("^0+$") then return "  ○ not committed yet" end
  local mark, who = M.who({ claude = trailer.claude, url = trailer.url, author = info.author }, names, me)
  local when = M.ago(now_s - (tonumber(info.author_time) or now_s), tonumber(info.author_time))
  return string.format("  %s %s · %s · %s", mark, who, when, info.summary or "")
end

-- ─── the live parts (timers, gitsigns, windows) ───────────────────────────────────────────────────────────────
local names_cache = { mtime = -1, names = {} }
function M.names()
  local file = M.names_file()
  local stat = uv.fs_stat(file)
  local mtime = stat and stat.mtime.sec or 0
  if mtime ~= names_cache.mtime then names_cache = { mtime = mtime, names = M.parse_names(M.read(file)) } end
  return names_cache.names
end

local me_cache
local function me()
  if me_cache == nil then me_cache = vim.trim(system({ "git", "config", "user.name" }, 1000) or "") end
  return me_cache
end

local function realpath(buf)
  local meta = vim.b[buf or 0].foxml_review
  if meta then return meta.file end
  local name = vim.api.nvim_buf_get_name(buf or 0)
  if name == "" then return nil end
  return uv.fs_realpath(name) or name
end

local function repo_root(buf)
  return vim.b[buf or 0].foxml_review_root or vim.fs.root(buf or 0, ".git")
end

local function poll()
  local dir = M.runtime()
  if not dir or not uv.fs_stat(dir) then M.live = {}; return end
  local ok = pcall(vim.system, { drawer_tool(), "claude-peers" }, { text = true }, function(out)
    vim.schedule(function()
      M.live = M.with_ledgers(out.code == 0 and M.decode(out.stdout) or {}, dir)
      pcall(vim.cmd.redrawstatus)
      pcall(vim.cmd.redrawtabline)
      local signature = M.tree_signature(vim.uv.now and (os.time() * 1000) or 0)
      if signature ~= M.tree_seen and package.loaded["neo-tree"] then
        M.tree_seen = signature
        pcall(function() require("neo-tree.sources.manager").refresh("filesystem") end)
      end
    end)
  end)
  if not ok then M.live = {} end
end

function M.status_footprint()
  local path = realpath(0)
  return path and M.footprint_text(M.footprint(path, os.time() * 1000, M.live), os.time() * 1000) or ""
end

function M.status_gate()
  local root = repo_root(0)
  if not root then return "" end
  return M.gate_text(root, M.live, M.read(root .. "/.claude/.plan-approved"))
end

function M.status_needs() return M.needs_text(M.live) end

function M.status_mode()
  if M.following then return "following " .. M.following.name end
  if M.review then return "reviewing " .. M.review.label end
  return ""
end

-- bufferline: a ✎ after the name of a buffer a live Claude edited lately.
function M.bufferline_name(buf)
  local path = buf.path and (uv.fs_realpath(buf.path) or buf.path)
  local fp = path and M.footprint(path, os.time() * 1000, M.live)
  return fp and (buf.name .. " ✎") or buf.name
end

-- The first change you make in a buffer a Claude edited lately: say so once per session.
local function warn_once(buf)
  local path = realpath(buf)
  local fp = path and M.footprint(path, os.time() * 1000, M.live)
  if not fp then return end
  local told = vim.b[buf].foxml_claude_told or {}
  if told[fp.sid] then return end
  told[fp.sid] = true
  vim.b[buf].foxml_claude_told = told
  vim.notify(string.format("coordinate with %s, it edited this %s ago (<leader>Cj goes there)", fp.name,
    M.ago(os.time() - fp.at / 1000)), vim.log.levels.WARN, { title = "Claude" })
end

function M.jump()
  local path = realpath(0)
  local fp = path and M.footprint(path, os.time() * 1000, M.live)
  if not fp or not fp.pane or fp.pane == "" then
    vim.notify("no Claude edited this file lately", vim.log.levels.INFO, { title = "Claude" })
    return
  end
  vim.system({ drawer_tool(), "run", "claude-jump", fp.pane })
end

local function peer_item(p)
  local mark = p.state == "needs you" and "●" or (p.busy and "✎" or "○")
  return string.format("%s %s · %s · %s", mark, p.name, p.project or "", p.state or "")
end

-- <leader>Cn: the file (or the selection) and a line of text, to any live Claude.
function M.send(range)
  local dir = M.runtime()
  if not dir or #M.live == 0 then
    vim.notify("no other Claude is open", vim.log.levels.INFO, { title = "Claude" })
    return
  end
  local context = require("foxml.review").note_context(range)
  local path, code = realpath(0), nil
  if range then code = table.concat(vim.api.nvim_buf_get_lines(0, range[1] - 1, range[2], false), "\n") end
  local first, last = range and range[1], range and range[2]
  if context then path, code, first, last = context.file, context.code, context.first, context.last end
  vim.ui.select(M.live, { prompt = "Note for", format_item = peer_item }, function(p)
    if not p then return end
    vim.ui.input({ prompt = "note for " .. p.name .. ": " }, function(text)
      if not text or vim.trim(text) == "" then return end
      local note = M.note(text, path, first, last, code)
      if M.write_note(dir, p.id, note) then
        vim.notify("note left for " .. p.name, vim.log.levels.INFO, { title = "Claude" })
      else
        vim.notify("could not leave the note", vim.log.levels.ERROR, { title = "Claude" })
      end
    end)
  end)
end

-- :Plan — the plan the sessions in this repo read last.
function M.plan()
  local root = repo_root(0)
  local best
  for _, p in ipairs(M.in_repo(root, M.live)) do
    local plan = (p.ledger or {}).plan
    if type(plan) == "string" and uv.fs_stat(plan) then
      local at = (p.ledger.plan_at or 0)
      if not best or at > best.at then best = { path = plan, at = at } end
    end
  end
  if not best then
    vim.notify("no session here has read a plan yet", vim.log.levels.INFO, { title = "Claude" })
    return
  end
  vim.cmd("botright vsplit " .. vim.fn.fnameescape(best.path))
end

-- ─── what changed ─────────────────────────────────────────────────────────────────────────────────────────────
function M.rows(root)
  local rows = {}
  local working = require("foxml.review").working_files(root) or {}
  local dirty = {}
  local working_paths = {}
  for _, file in ipairs(working) do
    dirty[uv.fs_realpath(file.path) or file.path] = true
    working_paths[#working_paths + 1] = file.path
  end
  rows[#rows + 1] = { kind = "working", sid = "working", name = "Working changes", short = "Working changes",
    files = working_paths, label = "Working changes · " .. #working_paths .. " files" }
  for _, p in ipairs(M.in_repo(root, M.live)) do
    local files = M.live_files(p, dirty)
    if #files > 0 then
      rows[#rows + 1] = { kind = "live", sid = p.id, name = p.name, files = files, before = (p.ledger or {}).before or {},
                          label = M.live_label(p, files), short = p.name }
    end
  end
  local log = system({ "git", "--no-optional-locks", "-C", root, "log", "-80", "--name-only", "--format=" .. M.LOG_FORMAT })
  local names, now_s = M.names(), os.time()
  for _, c in ipairs(M.parse_log(log)) do
    local files = {}
    for _, rel in ipairs(c.files) do files[#files + 1] = root .. "/" .. rel end
    rows[#rows + 1] = { kind = "commit", sha = c.sha, parent = c.parent or EMPTY_TREE, short = c.short,
                        files = files, subject = c.subject, label = M.commit_label(c, names, me(), now_s) }
  end
  return rows
end

function M.done()
  return require("foxml.review").close()
end

function M.close()
  if vim.g.foxml_work_view then vim.cmd("confirm qall"); return end
  if not M.done() then return end
  if M.following then
    local follow = M.following
    M.follow()
    if vim.api.nvim_tabpage_is_valid(follow.tab) then
      vim.api.nvim_set_current_tabpage(follow.tab)
      local ok, err = pcall(vim.cmd, "tabclose")
      if not ok then vim.notify(tostring(err), vim.log.levels.WARN, { title = "Claude review" }) end
    end
    if follow.origin and vim.api.nvim_win_is_valid(follow.origin) then vim.api.nvim_set_current_win(follow.origin) end
  end
end

function M.open_review(row, root)
  if not M.done() then return end
  M.review = require("foxml.review").open(row, root, {
    close = M.close,
    on_close = function() M.review = nil; pcall(vim.cmd.redrawstatus) end,
  })
end

function M.diff(path)
  local r = M.review
  path = path or realpath(0)
  if not r then
    vim.notify("pick a change first (<leader>Cw)", vim.log.levels.INFO, { title = "Claude" })
    return
  end
  for i, file in ipairs(r.files) do
    if file.path == path then require("foxml.review").select(i); return end
  end
  vim.notify("This file is not part of the selected change.", vim.log.levels.INFO, { title = "Claude" })
end

-- Follow: a tab of its own shows each file the session edits, at its newest change; your cursor stays put.
local follow_timer
function M.follow(row)
  if follow_timer then follow_timer:stop(); follow_timer:close(); follow_timer = nil end
  if M.following and (not row or M.following.sid == row.sid) then
    M.following = nil
    pcall(vim.cmd.redrawstatus)
    return
  end
  if not row or row.kind ~= "live" then return end
  local here = vim.api.nvim_get_current_tabpage()
  local origin = vim.api.nvim_get_current_win()
  vim.cmd("tabnew")
  M.following = { sid = row.sid, name = row.name, tab = vim.api.nvim_get_current_tabpage(), win = vim.api.nvim_get_current_win(), origin = origin }
  vim.api.nvim_set_current_tabpage(here)
  follow_timer = uv.new_timer()
  follow_timer:start(0, 2000, vim.schedule_wrap(function()
    local f = M.following
    if not f or not vim.api.nvim_win_is_valid(f.win) then return M.follow() end
    local ledger = M.decode(M.read(M.runtime() .. "/edits/" .. f.sid .. ".json"))
    local newest = ledger and ledger.edits and ledger.edits[1]
    if not newest or (f.last and f.last.path == newest.path and f.last.at == newest.at) then return end
    f.last = newest
    local buf = vim.fn.bufadd(newest.path)
    vim.fn.bufload(buf)
    pcall(vim.cmd, "checktime " .. buf)
    vim.api.nvim_win_set_buf(f.win, buf)
    local diff = system({ "git", "--no-optional-locks", "-C", vim.fs.dirname(newest.path), "diff", "-U0", "--", newest.path }, 1500) or ""
    local line
    for start in diff:gmatch("\n@@ %-%d+,?%d* %+(%d+)") do line = tonumber(start) end
    if line then pcall(vim.api.nvim_win_set_cursor, f.win, { math.max(1, line), 0 }) end
  end))
  pcall(vim.cmd.redrawstatus)
end

function M.changes(unreviewed)
  local root = repo_root(0) or vim.fs.root(vim.fn.getcwd(), ".git")
  if not root then
    vim.notify("not in a git repository", vim.log.levels.INFO, { title = "Claude" })
    return
  end
  local rows = M.rows(root)
  local backend = require("foxml.review").work_tool()
  if unreviewed == true and backend then
    local wanted = M.decode(system({ backend, "reviews", "--root", root })) or {}
    local pending = {}
    for _, c in ipairs(wanted) do pending[c.sha] = true end
    rows = vim.tbl_filter(function(r) return r.kind == "commit" and pending[r.sha] end, rows)
    if #rows == 0 then vim.notify("No Claude changes left to look over today."); return end
  end
  if #rows == 0 then vim.notify("No changes in this repository."); return end
  for _, row in ipairs(rows) do
    local files = require("foxml.review").files(row, root)
    if files and #files > 0 then
      M.open_review(row, root)
      require("foxml.review").tree(rows)
      return
    end
  end
  vim.notify("These commits have no changed files.")
end

-- ─── blame ────────────────────────────────────────────────────────────────────────────────────────────────────
local trailer_cache = {}
local function trailer(sha, dir)
  if trailer_cache[sha] then return trailer_cache[sha] end
  local out = system({ "git", "-C", dir, "show", "-s", "--format=%(trailers:key=Claude-Session,valueonly,separator=%x2C)%x1f%(trailers:key=Co-Authored-By,valueonly,separator=%x2C)", sha }, 800) or ""
  local session, coauthor = out:match("^([^\31]*)\31(.*)$")
  local t = { url = (session or ""):match("(https://%S+)"), claude = (session or "") ~= "" or (coauthor or ""):find("Claude") ~= nil }
  trailer_cache[sha] = t
  return t
end

function M.blame_formatter(_, info)
  local dir = vim.fn.expand("%:p:h")
  local text = M.blame_text(info, info.sha and trailer(info.sha, dir) or {}, M.names(), me(), os.time())
  return { { text, "GitSignsCurrentLineBlame" } }
end

-- ─── setup ────────────────────────────────────────────────────────────────────────────────────────────────────
local timer
function M.setup()
  if timer then return end
  pcall(function() require("foxml.work").setup() end)
  math.randomseed(uv.hrtime())
  timer = uv.new_timer()
  timer:start(0, 5000, vim.schedule_wrap(poll))
  local group = vim.api.nvim_create_augroup("foxml_claude", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = group, callback = function(a) warn_once(a.buf) end })
  vim.api.nvim_create_user_command("ClaudeChanges", M.changes, { desc = "What changed: live sessions and commits" })
  vim.api.nvim_create_user_command("ChangedDone", M.close, { desc = "Close Claude review" })
  vim.api.nvim_create_user_command("ClaudeReviewClose", M.close, { desc = "Close all Claude review views" })
  vim.api.nvim_create_user_command("Plan", M.plan, { desc = "The plan the sessions here read last" })
  vim.api.nvim_create_user_command("ClaudeFollow", function() M.follow() end, { desc = "Stop following a session" })
  local map = vim.keymap.set
  map("n", "<leader>Cw", M.changes, { desc = "What changed" })
  map("n", "<leader>Cq", M.close, { desc = "Close all Claude review views" })
  map("n", "<leader>Cn", function() M.send() end, { desc = "Note to a Claude" })
  map("x", "<leader>Cn", function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    M.send({ math.min(a, b), math.max(a, b) })
  end, { desc = "Selection to a Claude" })
  map("n", "<leader>Cj", M.jump, { desc = "Go to the Claude that edited this" })
  map("n", "<leader>Cd", function() M.diff() end, { desc = "This change side by side" })
  map("n", "<leader>Cp", M.plan, { desc = "The plan" })
end

return M
