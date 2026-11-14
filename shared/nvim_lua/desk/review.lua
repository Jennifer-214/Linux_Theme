-- One read-only comparison tab; the original editor and its quickfix list stay intact.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
local ns = api.nvim_create_namespace('desk_review')
local serial = 0

function M.work_tool()
  if vim.fn.executable('desk-work') == 1 then return 'desk-work' end
  if vim.fn.executable('fox-work') == 1 then return 'fox-work' end
end

local function tell(text, level) vim.notify(text, level or vim.log.levels.INFO, { title = 'Review' }) end
local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read('*a'); f:close(); return text
end
local function decode(text)
  local ok, value = pcall(vim.json.decode, text or '')
  return ok and type(value) == 'table' and value or {}
end
local function state_file(root, row)
  return vim.fn.stdpath('state') .. '/foxml-reviews/' .. vim.fn.sha256(root .. '\0' .. (row.sha or row.sid or 'working')) .. '.json'
end
-- "New since I looked": a checked file's reviewed copy is kept by content hash, so when it changes later the review
-- can show only what is new. The choice between that and the whole change is remembered across sessions.
local function reviews_dir() return vim.fn.stdpath('state') .. '/foxml-reviews' end
local function write_private(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), 'p', tonumber('700', 8))
  local temp = path .. '.' .. uv.os_getpid() .. '.tmp'
  local fd = uv.fs_open(temp, 'w', tonumber('600', 8))
  if not fd then return false end
  local written = uv.fs_write(fd, data, 0); uv.fs_close(fd)
  if written ~= #data or not uv.fs_rename(temp, path) then uv.fs_unlink(temp); return false end
  return true
end
function M.since_mode()
  local prefs = decode(read(reviews_dir() .. '/prefs.json'))
  return prefs.since ~= false
end
local function reviewed_copy(r, file)
  if r.row.kind == 'commit' or r.row.snapshots then return nil end
  local seen = decode(read(r.state_file)).seen
  local hash = type(seen) == 'table' and seen[file.rel]
  if type(hash) ~= 'string' or not hash:match('^%x+$') then return nil end
  return read(reviews_dir() .. '/seen/' .. hash)
end
local function git(root, args)
  local argv = { 'git', '--no-optional-locks', '-C', root }
  vim.list_extend(argv, args)
  local ok, job = pcall(vim.system, argv, { text = false })
  if not ok then return nil end
  local result = job:wait(3000)
  return result.code == 0 and result.stdout or nil
end
local function lines(text)
  return vim.split((text or ''):gsub('\n$', ''), '\n', { plain = true })
end
local function relative(root, path)
  return path:sub(1, #root + 1) == root .. '/' and path:sub(#root + 2) or nil
end
local function escaped(text) return text:gsub('[\r\n\t]', ' '):gsub('%%', '%%%%') end

function M.files(row, root)
  local files = {}
  if row.kind == 'working' then return M.working_files(root) end
  if row.kind == 'commit' then
    local data = git(root, { 'diff', '--name-status', '-z', '--find-renames', row.parent, row.sha, '--' })
    if not data then return nil, 'Could not read this commit; the review was left unopened.' end
    local parts, i = vim.split(data, '\0', { plain = true, trimempty = true }), 1
    while i <= #parts do
      local status, old, path = parts[i], parts[i + 1], parts[i + 1]
      if status:match('^[RC]') then path = parts[i + 2]; i = i + 1 end
      if path then files[#files + 1] = { path = root .. '/' .. path, rel = path, old = old, status = status:sub(1, 1) } end
      i = i + 2
    end
  else
    local seen = {}
    for _, path in ipairs(row.files or {}) do
      local rel = relative(root, path)
      if rel and not seen[rel] then
        files[#files + 1] = { path = path, rel = rel, old = rel, status = 'M' }; seen[rel] = true
      end
    end
  end
  return files
end

function M.working_files(root)
  local data = git(root, { 'status', '--porcelain=v1', '-z', '--untracked-files=all' })
  if not data then return nil end
  local parts, files, seen, i = vim.split(data, '\0', { plain = true, trimempty = true }), {}, {}, 1
  while i <= #parts do
    local entry = parts[i]
    local status, rel, old = entry:sub(1, 2), entry:sub(4), nil
    if status:find('[RC]') then old = parts[i + 1]; i = i + 1 end
    if rel ~= '' then
      local kind = status:find('R') and 'R' or status:find('D') and 'D' or status:find('[A?]') and 'A' or status:find('U') and 'U' or 'M'
      files[#files + 1] = { path = root .. '/' .. rel, rel = rel, old = old or rel, status = kind }
      seen[rel] = true
    end
    i = i + 1
  end
  -- Git sees saved files; include drafts that exist only in this editor too.
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and vim.bo[buf].buflisted and vim.bo[buf].modified then
      local path = api.nvim_buf_get_name(buf)
      local rel = relative(root, path)
      if rel and not seen[rel] then
        files[#files + 1] = { path = path, rel = rel, old = rel, status = 'M' }; seen[rel] = true
      end
    end
  end
  table.sort(files, function(a, b) return a.rel < b.rel end)
  return files
end

-- Risk marks, from what is already known: the red-zone paths and tools the notebook warns about (login, boot, mounts,
-- the kernel, the firewall) when the lines a change ADDS name one; the project's own list (.review-risk, one path
-- fragment per line); a file its plan never names; a file edited since the last test run. Reasons, never a score.
-- The list itself is ~/.config/foxml/redzone.json (shared/redzone.json), the same file the notebook's band reads; the
-- copy here only stands in when that file is missing, and tests/test_redzone.py keeps the two the same.
local RED_DEFAULT = { paths = { '/etc/pam.d', '/etc/fstab', '/etc/crypttab', '/etc/greetd', '/etc/sudoers', '/etc/mkinitcpio',
  '/etc/default/grub', '/etc/kernel/cmdline', '/etc/sysctl', '/etc/usbguard', '/etc/ufw', '/etc/security', '/boot/' },
  tools = { 'bootctl', 'efibootmgr', 'mkinitcpio', 'grub-mkconfig', 'ufw', 'usbguard', 'sysctl -w', 'cryptsetup', 'faillock' } }
local red
local function red_zone()
  if red then return red end
  local config = vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. '/.config')
  local listed = decode(read(config .. '/foxml/redzone.json'))
  local function strings(list) return type(list) == 'table' and #list > 0 and vim.tbl_filter(function(s) return type(s) == 'string' and s ~= '' end, list) or nil end
  red = { paths = strings(listed.paths) or RED_DEFAULT.paths, tools = strings(listed.tools) or RED_DEFAULT.tools }
  return red
end
function M.red_zone_reset() red = nil end
-- Plain-text search for a tool name with nothing word-like on either side.
local function names_tool(line, tool)
  local from = 1
  while true do
    local s, e = line:find(tool, from, true)
    if not s then return false end
    local before, after = line:sub(s - 1, s - 1), line:sub(e + 1, e + 1)
    if not before:match('[%w_-]') and not after:match('[%w_-]') then return true end
    from = e + 1
  end
end
local function plan_names(r)
  local path = r.row.plan
  if not path or path == '' then
    local ok, marks = pcall(require, 'desk.planmarks')
    path = ok and type(marks.plan) == 'table' and marks.plan.file or nil
  end
  if not path then return nil end
  r.plan_cache = r.plan_cache or {}
  if r.plan_cache[path] == nil then
    local names, any = {}, false
    local ok, marks = pcall(require, 'desk.planmarks')
    local text = read(path)
    if ok and text then
      for _, ref in ipairs(marks.parse(text)) do
        if ref.path then names[#names + 1] = ref.path:gsub('^~/', ''):gsub('^%./', ''); any = true end
      end
    end
    r.plan_cache[path] = any and names or false
  end
  return r.plan_cache[path] or nil
end
local function untested(r)
  if r.untested ~= nil then return r.untested or nil end
  r.untested = false
  local backend = M.work_tool()
  if backend and r.row.kind ~= 'commit' then
    local ok, job = pcall(vim.system, { backend, 'tests', '--root', r.root }, { text = true })
    local out = ok and job:wait(2000) or {}
    local changed = out.code == 0 and decode(out.stdout).changedFiles
    if type(changed) == 'table' then
      r.untested = {}
      for _, rel in ipairs(changed) do if type(rel) == 'string' then r.untested[rel] = true end end
    end
  end
  return r.untested or nil
end
function M.risks(r, file)
  local found = {}
  if file.error or file.binary then return found end
  local right = lines(file.right)
  local hit
  for _, h in ipairs(file.hunks or {}) do
    for n = h[3], h[3] + h[4] - 1 do
      local line = right[n] or ''
      for _, path in ipairs(red_zone().paths) do
        if line:find(path, 1, true) then hit = path; break end
      end
      if not hit then
        for _, tool in ipairs(red_zone().tools) do
          if names_tool(line, tool) then hit = tool; break end
        end
      end
      if hit then break end
    end
    if hit then break end
  end
  if hit then found[#found + 1] = 'touches ' .. hit end
  r.project_risk = r.project_risk or lines(read(r.root .. '/.review-risk') or '')
  for _, fragment in ipairs(r.project_risk) do
    fragment = vim.trim(fragment)
    if fragment ~= '' and fragment:sub(1, 1) ~= '#' and file.rel:find(fragment, 1, true) then found[#found + 1] = 'marked risky in this project'; break end
  end
  local names = plan_names(r)
  if names then
    local named = false
    for _, name in ipairs(names) do
      if file.rel == name or file.rel:sub(-#name - 1) == '/' .. name or name:sub(-#file.rel - 1) == '/' .. file.rel or file.path == name then named = true; break end
    end
    if not named then found[#found + 1] = 'outside the plan' end
  end
  local stale = untested(r)
  if stale and stale[file.rel] then found[#found + 1] = 'not tested since this edit' end
  return found
end
-- A committed copy never changes under the same commit, so each (commit, file) is read once however often the review
-- refreshes; HEAD is resolved to its commit first, one cheap call per refresh, so a commit made meanwhile is seen.
-- Without this, every work event re-read every loaded file with its own blocking git process.
local function head_of(r)
  local now = (vim.uv or vim.loop).now()
  if not r.head_at or now - r.head_at > 500 then
    local head = vim.trim(git(r.root, { 'rev-parse', '--verify', '-q', 'HEAD' }) or '')
    if head ~= r.head then r.blobs = {} end
    r.head, r.head_at = head, now
  end
  return r.head ~= '' and r.head or nil
end
local function blob(r, revision, rel, absent)
  if absent then return '' end
  local commit = revision == 'HEAD' and head_of(r) or revision
  if not commit then return nil end
  r.blobs = r.blobs or {}
  local key = commit .. ':' .. rel
  if r.blobs[key] == nil then r.blobs[key] = git(r.root, { 'show', key }) or false end
  return r.blobs[key] or nil
end
local function load_file(r, file, refresh)
  if file.loaded and not refresh then return end
  local left, right
  if r.row.snapshots then
    local pair = r.row.snapshots[file.path] or {}
    left, right = pair[1], pair[2]
  elseif r.row.kind == 'commit' then
    left = blob(r, r.row.parent, file.old, file.status == 'A')
    right = blob(r, r.row.sha, file.rel, file.status == 'D')
  else
    local dir = vim.env.XDG_RUNTIME_DIR
    local copy = (r.row.before or {})[file.path]
    if dir and copy and copy:match('^%d+%.txt$') and (r.row.sid or ''):match('^[%w_-]+$') then
      left = read(dir .. '/foxml-claude/edits/' .. r.row.sid .. '/before/' .. copy)
    end
    if not copy then
      left = blob(r, 'HEAD', r.row.kind == 'working' and file.old or file.rel, false)
      -- A new/untracked file (or an unborn repository) has no HEAD copy.
      if left == nil then
        -- New here, or no commit yet: the committed side is empty. Asked once per commit, like the copies.
        local head = head_of(r)
        local key = 'absent:' .. (head or '') .. ':' .. file.rel
        r.blobs = r.blobs or {}
        if r.blobs[key] == nil then
          local tree = head and git(r.root, { 'ls-tree', '-z', head, '--', ':(literal)' .. file.rel })
          r.blobs[key] = head == nil or tree == ''
        end
        if r.blobs[key] then left = '' end
      end
    end
    local buf = vim.fn.bufnr(file.path)
    if buf >= 0 and api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      right = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. (vim.bo[buf].endofline and '\n' or '')
    else right = read(file.path) end
    if right == nil and left ~= nil and uv.fs_stat(file.path) == nil then right = '' end
    if r.row.kind ~= 'working' then file.status = left == '' and 'A' or right == '' and 'D' or 'M' end
  end
  file.error = left == nil or right == nil
  file.binary = (left or ''):find('\0', 1, true) ~= nil or (right or ''):find('\0', 1, true) ~= nil
  file.signature = vim.fn.sha256((left or '') .. '\0' .. (right or ''))
  file.left, file.right, file.loaded = left or '', right or '', true
  file.hunks, file.added, file.deleted = {}, 0, 0
  file.symbols = nil
  if not file.error and not file.binary then
    local diff = vim.text and vim.text.diff or vim.diff
    local ok, hunks = pcall(diff, file.left, file.right, { result_type = 'indices', algorithm = 'histogram', linematch = 60 })
    if ok then file.hunks = hunks end
    for _, h in ipairs(file.hunks) do file.deleted = file.deleted + h[2]; file.added = file.added + h[4] end
  end
  file.risks = M.risks(r, file)
end

local unit_types = { function_declaration = true, function_definition = true, method_definition = true,
  method_declaration = true, function_item = true, class_definition = true, class_specifier = true,
  struct_specifier = true, struct_item = true, arrow_function = true }

function M.changed_symbols(file)
  if file.symbols then return file.symbols end
  local result, seen, roots = {}, {}, {}
  local ft = vim.filetype.match({ filename = file.rel })
  local lang = ft and vim.treesitter.language.get_lang(ft)
  local function collect(text, side, offset, hunk)
    if not lang or hunk[offset + 1] == 0 then return false end
    if roots[side] == nil then
      roots[side] = false
      local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
      if ok and parser then
        local parsed, trees = pcall(parser.parse, parser)
        if parsed and trees[1] then roots[side] = trees[1]:root() end
      end
    end
    if not roots[side] then return false end
    local root, found = roots[side], false
    for delta = 0, math.min(hunk[offset + 1], 128) - 1 do
      local row = math.max(0, hunk[offset] - 1 + delta)
      local node = root:named_descendant_for_range(row, 0, row, 0)
      while node and not unit_types[node:type()] do node = node:parent() end
      if node then
        found = true
        local name = node:field('name')[1] or node:field('declarator')[1]
        while name and name:field('declarator')[1] do name = name:field('declarator')[1] end
        local label = name and vim.treesitter.get_node_text(name, text) or vim.treesitter.get_node_text(node, text):match('[^\n]+')
        label = vim.trim((label or node:type()):gsub('%s+', ' ')):sub(1, 72)
        local key = label
        if not seen[key] then
          result[#result + 1] = { name = label, kind = node:type(), side = side, line = node:start() + 1, signature = file.signature }
          seen[key] = true
        end
      end
    end
    return found
  end
  for _, h in ipairs(file.hunks or {}) do
    local after = collect(file.right, 'after', 3, h)
    local before = collect(file.left, 'before', 1, h)
    if not after and not before then
      local side, start, count = h[4] > 0 and 'after' or 'before', h[4] > 0 and h[3] or h[1], h[4] > 0 and h[4] or h[2]
      local label = 'lines ' .. start .. (count > 1 and ('–' .. (start + count - 1)) or '')
      if not seen[label] then result[#result + 1] = { name = label, kind = 'hunk', side = side, line = math.max(1, start), signature = file.signature }; seen[label] = true end
    end
  end
  table.sort(result, function(a, b) return a.line < b.line end)
  file.symbols = result
  return result
end

local function progress(r)
  local count = 0
  for _, f in ipairs(r.files) do if f.loaded and r.marks[f.rel] == f.signature then count = count + 1 end end
  return count
end
-- The shared store (desk-work): the notebook and the drawer read the same progress. Best effort and never waited on;
-- a file on disk also sends its content hash, so a later edit shows there as "changed since review".
local function share(r, file, done)
  local backend = M.work_tool()
  if not backend or not r.root then return end
  local key = r.row.sha or r.row.sid or 'working'
  if not tostring(key):match('^[%w_-]+$') then return end
  local argv = { backend, 'review-mark', '--root', r.root, '--key', key, '--total', tostring(#r.files) }
  if file then
    vim.list_extend(argv, { '--file', file.rel, '--signature', r.marks[file.rel] or '' })
    if r.marks[file.rel] and r.row.kind ~= 'commit' and not r.row.snapshots and file.right then
      vim.list_extend(argv, { '--content', vim.fn.sha256(file.right) })
    end
  end
  if done ~= nil then vim.list_extend(argv, { '--done', done and 'yes' or 'no' }) end
  pcall(vim.system, argv, { text = true }, function() end)
end
-- The request thread is kept in the work tool too, so the notebook can show who was asked and whether it is ready.
local function share_request(r, file, request)
  -- A read begun before this write must not restore the request it just settled.
  r.requests_generation = (r.requests_generation or 0) + 1
  r.requests_pending = false
  local backend = M.work_tool()
  if not backend or not r.root or not file then return true end
  local argv = { backend, 'review-request', '--root', r.root, '--file', file.rel }
  if request then vim.list_extend(argv, { '--name', request.name or '', '--sid', (request.sid or ''):match('^[%w_-]+$') or '', '--text', request.text or '' })
  else vim.list_extend(argv, { '--clear', 'yes' }) end
  -- Waited for (a few milliseconds, on a deliberate act): the notebook must not show a thread that was just settled.
  local ok, out = pcall(function() return vim.system(argv, { text = true }):wait(1500) end)
  if not ok or out.code ~= 0 or decode(out.stdout).ok ~= true then
    tell('Could not save the change request. ' .. (ok and require('desk.work').refusal({ 'review-request' }, out) or 'desk-work did not start.'), vim.log.levels.WARN)
    return false
  end
  return true
end
local function save(r, file)
  local disk = decode(read(r.state_file))
  disk.files = type(disk.files) == 'table' and disk.files or {}
  if file then
    disk.files[file.rel] = r.marks[file.rel]
    if r.marks[file.rel] and ((type(disk.requests) == 'table' and disk.requests[file.rel]) or (r.shared_requests and r.shared_requests[file.rel])) then
      -- A request about an old commit belongs to that review, not the current working file.
      if r.row.kind ~= 'commit' and not share_request(r, file, nil) then return false end
      if type(disk.requests) == 'table' then disk.requests[file.rel] = nil end
      if r.shared_requests then r.shared_requests[file.rel] = nil end
    end
    disk.seen = type(disk.seen) == 'table' and disk.seen or {}
    if r.marks[file.rel] and r.row.kind ~= 'commit' and not r.row.snapshots and file.right and #file.right <= 4 * 1024 * 1024 then
      local hash = vim.fn.sha256(file.right)
      if write_private(reviews_dir() .. '/seen/' .. hash, file.right) then disk.seen[file.rel] = hash end
    end
  end
  disk.completed = r.completed or false
  vim.fn.mkdir(vim.fs.dirname(r.state_file), 'p', tonumber('700', 8))
  local temp = r.state_file .. '.' .. uv.os_getpid() .. '.tmp'
  local fd = uv.fs_open(temp, 'w', tonumber('600', 8))
  if not fd then tell('Could not save review progress.', vim.log.levels.ERROR); return false end
  local data = vim.json.encode(disk)
  local written = uv.fs_write(fd, data, 0); uv.fs_close(fd)
  if written ~= #data or not uv.fs_rename(temp, r.state_file) then
    uv.fs_unlink(temp); tell('Could not save review progress.', vim.log.levels.ERROR); return false
  end
  share(r, file, r.completed or false)
  return true
end

local function options(r)
  if not r or api.nvim_get_current_tabpage() ~= r.tab then return end
  local values = vim.split(r.original_diffopt, ',', { plain = true })
  values = vim.tbl_filter(function(v) return not v:match('^context:') and not v:match('^iwhite') end, values)
  values[#values + 1] = 'context:' .. (r.context and '999999' or '6')
  if r.whitespace then values[#values + 1] = 'iwhiteall' end
  r.applied_diffopt = table.concat(values, ','); vim.o.diffopt = r.applied_diffopt
end
local function restore_options(r)
  if r.applied_diffopt and vim.o.diffopt == r.applied_diffopt then vim.o.diffopt = r.original_diffopt end
end
-- The side panel, drawn to symdeps' menu rules (its STYLE V4-V14): a title line with the count on the right, a rule
-- per group (Working changes, each plan, Other changes), rows with their mark and aligned counts, a description strip
-- for the selected row and one footer line. r.entries maps a line to what it stands for; r.hits maps it to the
-- byte ranges a click means (the mark, the fold arrow).
local function hl(name, fallback) return vim.fn.hlexists(name) == 1 and name or fallback end
-- Before and after read as removed and added. Vim marks a line found in one pane only as DiffAdd in that pane, which
-- painted lines gone from the after copy green on the before side; filler rows (the gap opposite such a line) were red
-- on both. Defaults only, so a theme can set its own; set again after a colour scheme clears them.
local function review_groups()
  api.nvim_set_hl(0, 'FoxReviewRemoved', { link = 'DiffDelete', default = true })
  api.nvim_set_hl(0, 'FoxReviewFiller', { link = 'NonText', default = true })
end
review_groups()
api.nvim_create_autocmd('ColorScheme', { group = api.nvim_create_augroup('foxml_review_groups', { clear = true }), callback = review_groups })
local draw_notes   -- defined with the margin notes, below
local function width_of(s) return vim.fn.strdisplaywidth(s) end
local function fit(s, w)
  if w <= 1 then return '' end
  if width_of(s) <= w then return s end
  while width_of(s) > w - 1 and #s > 0 do s = vim.fn.strcharpart(s, 0, vim.fn.strchars(s) - 1) end
  return s .. '…'
end
local function spread(left, right, w)
  left = fit(left, math.max(4, w - width_of(right) - 1))
  return left .. string.rep(' ', math.max(1, w - width_of(left) - width_of(right))) .. right
end
local function rule(label, right, w)
  local head = ' ── ' .. label .. ' '
  local tail = right ~= '' and (' ' .. right .. ' ──') or ''
  return head .. string.rep('─', math.max(2, w - width_of(head) - width_of(tail))) .. tail
end
local function set_progress(r, set)
  local files, marks, n = set.files or {}, set.marks or {}, 0
  for _, f in ipairs(files) do if f.loaded and marks[f.rel] == f.signature then n = n + 1 end end
  return n, #files
end
local function describe(r, entry)
  if not entry then return { 'Pick a change to read it side by side.' } end
  local set = entry.set
  local files = set and set.files or r.files
  if entry.symbol then return { entry.symbol.name, 'Enter jumps to it in the comparison.' } end
  if entry.file and files[entry.file] then
    local f = files[entry.file]
    local marks = set and set.marks or r.marks
    local state = f.error and 'this snapshot is unavailable' or (marks and marks[f.rel] == f.signature and f.loaded) and 'reviewed'
      or (marks and marks[f.rel] and f.loaded) and 'changed since you reviewed it' or 'not reviewed yet'
    local what = ({ A = 'added', D = 'deleted', R = 'renamed', M = 'modified' })[f.status] or 'changed'
    local name = f.rel:match('[^/]+$') or f.rel
    local request = (not set or set == r.active_set) and M.request_of(r, f) or nil
    if request and not (marks and marks[f.rel] == f.signature) then
      return { name .. ' · ' .. (request.ready and 'changed since you asked · ready for re-review' or ('waiting on ' .. request.name)),
        '✉ ' .. request.name .. ': ' .. request.text }
    end
    local reviewed = (not set or set == r.active_set) and M.api_of(r, f) or nil
    local api_note = reviewed and (reviewed.current and 'API reviewed this version' or 'API reviewed an earlier version') or nil
    if f.risks and #f.risks > 0 then return { name .. ' · ' .. what .. ' · ' .. state, '⚠ ' .. table.concat(f.risks, ' · ') .. (api_note and (' · ' .. api_note) or '') } end
    if api_note and not f.since then return { name .. ' · ' .. what .. ' · ' .. state, '◇ ' .. api_note .. ' · A opens it' } end
    if f.since then return { name .. ' · ' .. what .. ' · ' .. state, 'showing only what is new · n shows the whole change' } end
    local mine = r.notes and r.notes[f.rel] or nil
    if mine and #mine > 0 then return { name .. ' · ' .. what .. ' · ' .. state, '✎ ' .. (#mine == 1 and mine[1].text or (#mine .. ' notes of yours · N on a line edits one')) } end
    return { f.rel .. ' · ' .. what, state }
  end
  if set then
    local row = set.row
    if row.kind == 'working' then return { 'Working changes · everything not committed yet', 'staged, unstaged, untracked and unsaved drafts' } end
    if row.kind == 'live' then return { (row.name or 'a live session') .. ' · edits it has made', 'f follows that session' } end
    local tested = row.tests == 'passed' and 'tests passed at this commit' or row.tests == 'failed' and 'tests FAILED at this commit' or 'no test run on exactly this commit'
    return { (row.short or '') .. ' · ' .. (row.subject or ''),
      tested .. (row.step and row.step ~= '' and (' · ' .. row.step) or '') .. ((row.label or '') ~= '' and (' · ' .. row.label) or '') }
  end
  return { '' }
end
-- A key hint from the key table: the keys of these ids as typed, then what they do (" ]f/[f file").
local function hint(word, ...)
  local keys = {}
  for _, id in ipairs({ ... }) do
    local lhs = M.bind(id)
    if lhs then keys[#keys + 1] = lhs == '<CR>' and '⏎' or (lhs:gsub('^<leader>', 'Space ')) end
  end
  return table.concat(keys, '/') .. ' ' .. word
end
local function panel(r, select_row)
  if not api.nvim_buf_is_valid(r.panel_buf) then return end
  if not api.nvim_win_is_valid(r.panel_win) then r.panel_dirty = true; return end
  r.panel_dirty = false
  local w = api.nvim_win_is_valid(r.panel_win) and math.max(24, api.nvim_win_get_width(r.panel_win) - 1) or 40
  local external = r.row.kind == 'external'
  local text, marks_hl, selected_line = {}, {}, nil
  r.entries, r.hits = {}, {}
  local function paint(line, from, to, group) marks_hl[#marks_hl + 1] = { line, from, to, group } end
  local function push(s) text[#text + 1] = (s:gsub('[\r\n\t]', ' ')); return #text end
  local done, total = progress(r), #r.files
  local mode = (r.row.kind == 'commit' or external) and '' or (M.since_mode() and ' · new' or ' · all')
  push(spread(external and ' Outside edits' or ' Review', external and 'both copies kept ' or (done .. ' of ' .. total .. mode .. ' '), w))
  paint(1, 0, -1, hl('FoxSymdepsTitle', 'Title'))
  push('')
  local function file_row(i, f, indent, set)
    local marks = set and set.marks or r.marks
    local checked = marks and marks[f.rel] == f.signature and f.loaded
    local stale = not checked and marks and marks[f.rel] ~= nil and f.loaded
    local request = (not set or set == r.active_set) and not checked and M.request_of(r, f) or nil
    if request and request.ready then stale = true end
    local mark = checked and '✓' or stale and '↻' or request and '✉' or '○'
    local stats = not f.loaded and '' or f.error and 'unavailable' or f.binary and 'binary' or ('+' .. f.added .. ' −' .. f.deleted)
    local arrow = f.expanded and '▾' or '▸'
    local left = indent .. arrow .. ' ' .. mark .. ' ' .. f.rel:gsub('[\r\n\t]', ' ')
    local risky = f.loaded and f.risks and #f.risks > 0
    r.notes = r.notes or M.notes(r.root)
    local noted = r.notes[f.rel] and #r.notes[f.rel] or 0
    local ln = push(spread(left, (noted > 0 and '✎ ' or '') .. (risky and '⚠ ' or '') .. stats .. ' ', w))
    local active = (not set or set == r.active_set) and i == r.index
    if active then selected_line = ln end
    r.entries[ln] = { set = set, file = i }
    local a = #indent
    r.hits[ln] = { fold = { a + 1, a + #arrow }, mark = { a + #arrow + 2, a + #arrow + 1 + #mark } }
    paint(ln, a + #arrow + 1, a + #arrow + 1 + #mark, checked and hl('FoxSymdepsOk', 'DiagnosticOk') or stale and hl('FoxSymdepsWarn', 'DiagnosticWarn') or hl('FoxSymdepsDim', 'Comment'))
    if stats ~= '' then paint(ln, #text[ln] - #stats - 1, -1, hl('FoxSymdepsDim', 'Comment')) end
    if risky then paint(ln, #text[ln] - #stats - 1 - #'⚠ ', #text[ln] - #stats - 1, hl('FoxSymdepsWarn', 'DiagnosticWarn')) end
    if f.expanded and f.loaded and not f.error and not f.binary then
      for _, symbol in ipairs(M.changed_symbols(f)) do
        local icon = symbol.side == 'before' and '− ' or symbol.kind == 'hunk' and '↳ ' or symbol.kind:match('struct') and '◇ ' or 'ƒ '
        local sl = push(fit(indent .. '      ' .. icon .. symbol.name, w))
        r.entries[sl] = { set = set, file = i, symbol = symbol }
        paint(sl, 0, -1, hl('FoxSymdepsDim', 'Comment'))
        if active and r.symbol and r.symbol.name == symbol.name then selected_line = sl end
      end
    end
  end
  if r.sets then
    local group
    for _, set in ipairs(r.sets) do
      local row = set.row
      local own = row.kind == 'working' or row.kind == 'live' or row.kind == 'external'
      local label = row.kind == 'working' and 'Working changes' or row.kind == 'live' and 'Live sessions' or (row.task or 'Other changes')
      if label ~= group then
        if group then push('') end
        group = label
        local right = ''
        if not own then
          local n, of = 0, 0
          for _, other in ipairs(r.sets) do
            if (other.row.task or 'Other changes') == label and other.row.kind == 'commit' then
              of = of + 1; if other.completed then n = n + 1 end
            end
          end
          right = n .. ' of ' .. of
        end
        local rl = push(rule(label, right, w))
        paint(rl, 0, -1, hl('FoxSymdepsHeader', 'Title'))
        if row.kind == 'working' then r.entries[rl] = { set = set } end
      end
      if row.kind == 'working' then
        if set.expanded then
          for i, f in ipairs(set.files or {}) do file_row(i, f, '   ', set) end
          if #(set.files or {}) == 0 then paint(push('     the working tree is clean'), 0, -1, hl('FoxSymdepsDim', 'Comment')) end
        end
      else
        local n, of = set_progress(r, set)
        if not set.files then of = #(row.files or {}) end
        -- Three separate facts, never merged: tests at this commit (t✓ / t✗), reviewed by you (✓ or n of m).
        local tested = row.tests == 'passed' and 't✓ ' or row.tests == 'failed' and 't✗ ' or ''
        local right = tested .. (set.completed and '✓ ' or (of > 0 and (n .. ' of ' .. of .. ' ') or ''))
        local title = row.kind == 'live' and ('✎ ' .. (row.name or 'live session')) or ((row.short or 'commit') .. '  ' .. (row.subject or ''))
        local arrow = set.expanded and '▾' or '▸'
        local ln = push(spread('   ' .. arrow .. ' ' .. title:gsub('[\r\n\t]', ' '), right, w))
        r.entries[ln] = { set = set }
        r.hits[ln] = { fold = { 4, 3 + #arrow } }
        if set.completed then paint(ln, #text[ln] - #right, -1, hl('FoxSymdepsOk', 'DiagnosticOk')) elseif right ~= '' then paint(ln, #text[ln] - #right, -1, hl('FoxSymdepsDim', 'Comment')) end
        if tested ~= '' then paint(ln, #text[ln] - #right, #text[ln] - #right + #tested, row.tests == 'passed' and hl('FoxSymdepsOk', 'DiagnosticOk') or hl('FoxSymdepsAlarm', 'DiagnosticError')) end
        if set.expanded then
          for i, f in ipairs(set.files or {}) do file_row(i, f, '       ', set) end
          if #(set.files or {}) == 0 then paint(push('         no changed files'), 0, -1, hl('FoxSymdepsDim', 'Comment')) end
        end
      end
    end
  else
    local rl = push(rule(r.row.short or 'Changes', '', w)); paint(rl, 0, -1, hl('FoxSymdepsHeader', 'Title'))
    for i, f in ipairs(r.files) do file_row(i, f, '   ') end
  end
  -- The description strip: what the selected row is and where it stands; then the one footer line.
  local cursor_line = (select_row and selected_line) or (api.nvim_win_is_valid(r.panel_win) and api.nvim_win_get_cursor(r.panel_win)[1]) or selected_line
  local about = describe(r, r.entries[cursor_line] or (selected_line and r.entries[selected_line]))
  for i = 1, 2 do about[i] = ((about[i] or ''):gsub('[\r\n\t]', ' ')) end
  push('')
  local top = push(' ╭' .. string.rep('─', w - 3) .. '╮')
  for i = 1, 2 do push(' │ ' .. fit(about[i] or '', w - 5) .. string.rep(' ', math.max(0, w - 5 - width_of(fit(about[i] or '', w - 5)))) .. ' │') end
  local bottom = push(' ╰' .. string.rep('─', w - 3) .. '╯')
  for ln = top, bottom do paint(ln, 0, -1, hl('FoxSymdepsDim', 'Comment')) end
  r.strip = { top + 1, top + 2 }
  local open, check, actions, hide = hint('open', 'enter'), hint('check', 'mark-list'), hint('actions', 'actions-list'), hint('hide', 'hide')
  local keys = ' ' .. table.concat(external and { open, actions, hide } or (w >= 44 and { open, check, actions, hide } or { open, check, hide }), ' · ')
  r.footer_line = push(fit(keys, w)); paint(r.footer_line, 0, -1, hl('FoxSymdepsDim', 'Comment'))
  vim.bo[r.panel_buf].modifiable = true
  api.nvim_buf_set_lines(r.panel_buf, 0, -1, false, text)
  vim.bo[r.panel_buf].modifiable = false
  api.nvim_buf_clear_namespace(r.panel_buf, ns, 0, -1)
  for _, m in ipairs(marks_hl) do
    pcall(api.nvim_buf_set_extmark, r.panel_buf, ns, m[1] - 1, math.max(0, m[2]), { end_row = m[1] - 1, end_col = m[3] < 0 and #text[m[1]] or math.min(m[3], #text[m[1]]), hl_group = m[4] })
  end
  -- The bar follows the row under the cursor, as in every menu here; the file open in the comparison keeps a quieter
  -- band, so moving through the list never hides which file is shown.
  local bar = (cursor_line and r.entries[cursor_line]) and cursor_line or selected_line
  if selected_line and selected_line ~= bar then
    api.nvim_buf_set_extmark(r.panel_buf, ns, selected_line - 1, 0, { line_hl_group = hl('CursorLine', 'CursorLine') })
  end
  if bar then api.nvim_buf_set_extmark(r.panel_buf, ns, bar - 1, 0, { line_hl_group = hl('FoxSymdepsSelection', 'Visual') }) end
  if select_row and api.nvim_win_is_valid(r.panel_win) and selected_line then api.nvim_win_set_cursor(r.panel_win, { selected_line, 0 }) end
  local footer = ' ' .. table.concat({ hint('file', 'next-file', 'previous-file'), hint('change', 'next-change', 'previous-change'),
    hint('check', 'mark'), hint('unread', 'unread'), hint('finish', 'finish'), hint('help', 'actions'), hint('close', 'close') }, ' · ') .. ' '
  for _, win in ipairs({ r.left_win, r.right_win }) do
    if api.nvim_win_is_valid(win) then vim.wo[win].statusline = '%#StatusLine#' .. footer end
  end
end

local function scratch(r, file, side, text)
  local buf = api.nvim_create_buf(false, true)
  r.buffers[#r.buffers + 1] = buf
  local name = 'review://' .. r.id .. '/' .. r.generation .. '/' .. side .. '/' .. file.rel
  api.nvim_buf_set_name(buf, name)
  vim.b[buf].desk_review = { file = file.path, side = side }
  vim.b[buf].desk_review_root = r.root
  api.nvim_buf_set_lines(buf, 0, -1, false, lines(text))
  vim.bo[buf].modifiable, vim.bo[buf].readonly, vim.bo[buf].bufhidden = false, true, 'hide'
  local ft = vim.filetype.match({ filename = file.rel })
  if ft and not file.error and not file.binary then vim.bo[buf].filetype = ft end
  return buf
end

-- Every key the review sets, in the order its reference lists them. This one table makes the mappings, the key hints
-- in the actions menu and the review table in NVIM-KEYBINDS.md (python3 tests/test_nvim_keys.py --write rewrites it).
-- on: 'list' (the file list), 'diff' (the comparison panes) or 'both'. row: keys that share one line of the reference,
-- whose words are the row's first doc; doc = false leaves a key out (mouse handling). also: words for that line beyond
-- these keys (a command, a global key). act(r) returns what the key does.
local function next_file(r) return function() M.select(r.index % #r.files + 1) end end
local function previous_file(r) return function() M.select((r.index - 2) % #r.files + 1) end end
local function to_diff(r, fn) return function() if api.nvim_get_current_win() == r.panel_win then api.nvim_set_current_win(r.right_win) end; fn() end end
-- Pressed in the list, a key that checks or refreshes leaves focus in the list, so "m, j, m" checks files in a row.
local function in_list(r, fn) return function()
  local from = api.nvim_get_current_win()
  fn()
  if from == r.panel_win and api.nvim_win_is_valid(from) then api.nvim_set_current_win(from) end
end end
M.keymap = {
  { id = 'enter', lhs = '<CR>', on = 'list', desc = 'Expand commit / open review file', row = 'enter',
    doc = 'Open the selected file in the comparison panes; on a commit, expand or collapse its changed files', act = function() return M.enter end },
  { id = 'enter-l', lhs = 'l', on = 'list', desc = 'Expand commit / open review file', row = 'enter', act = function() return M.enter end },
  { id = 'enter-mouse', lhs = '<2-LeftMouse>', on = 'list', desc = 'Expand commit / open review file', doc = false, act = function() return M.enter end },
  { id = 'fold', lhs = 'h', on = 'list', desc = 'Collapse review commit', doc = 'Collapse changed functions first, then the selected commit', act = function() return M.fold end },
  { id = 'next-file', lhs = ']f', on = 'both', desc = 'Next review file', row = 'files', doc = 'Next / previous file', act = next_file },
  { id = 'previous-file', lhs = '[f', on = 'both', desc = 'Previous review file', row = 'files', act = previous_file },
  { id = 'next-file-tab', lhs = '<Tab>', on = 'both', desc = 'Next review file', row = 'files', act = next_file },
  { id = 'previous-file-tab', lhs = '<S-Tab>', on = 'both', desc = 'Previous review file', row = 'files', act = previous_file },
  { id = 'next-change', lhs = ']c', on = 'diff', desc = 'Next review change', row = 'changes', doc = 'Next / previous changed block',
    act = function() return function() vim.cmd('normal! ]c') end end },
  { id = 'previous-change', lhs = '[c', on = 'diff', desc = 'Previous review change', row = 'changes', act = function() return function() vim.cmd('normal! [c') end end },
  { id = 'mark', lhs = 'm', on = 'diff', desc = 'Mark/unmark file reviewed', row = 'mark', doc = 'Check or uncheck the file as reviewed',
    act = function() return function() M.mark() end end },
  { id = 'mark-list', lhs = 'm', on = 'list', desc = 'Mark selected file reviewed', row = 'mark',
    act = function(r) return in_list(r, function() if M.enter(true) then M.mark() end end) end },
  { id = 'unread', lhs = 'u', on = 'both', desc = 'First unread review file',
    doc = 'Resume at the first unchecked file (files with a risk mark or ready for re-review first)', act = function() return function() M.unread() end end },
  { id = 'since-list', lhs = 'n', on = 'list', desc = 'New since review / the whole change', row = 'since',
    doc = 'Only what is new since you reviewed a file / the whole change (remembered)', act = function(r) return in_list(r, M.toggle_since) end },
  { id = 'since', lhs = '<leader>rn', on = 'diff', desc = 'New since review / the whole change', row = 'since', act = function() return M.toggle_since end },
  { id = 'request', lhs = 'c', on = 'both', desc = 'Request changes from a Claude session',
    doc = 'Request changes: a note about this file or the selected lines to a Claude session; the file waits on it',
    act = function(r) return function() if api.nvim_get_current_win() ~= r.panel_win or M.enter(true) then api.nvim_set_current_win(r.right_win); require('desk.claude').send() end end end },
  { id = 'actions-list', lhs = 'a', on = 'list', desc = 'Review actions', row = 'actions', doc = 'Actions: everything below, with what each needs', act = function() return M.actions end },
  { id = 'actions', lhs = '?', on = 'both', desc = 'Review actions', row = 'actions', act = function() return M.actions end },
  { id = 'api', lhs = 'A', on = 'both', desc = 'Open the API review of this file',
    doc = 'Open the saved API review of this file (Actions has "API review: file / change" and "Explain this hunk")', act = function() return function() M.api_open() end end },
  { id = 'plan', lhs = 'P', on = 'both', desc = 'Plan coverage',
    doc = 'Plan coverage: each plan step with the commits that touched it, steps not started, files outside the plan', act = function() return function() M.plan_coverage() end end },
  { id = 'note', lhs = 'N', on = 'both', desc = 'Note to self on this line',
    doc = 'Note to self on this line; it stays with the file in every later review (`:ReviewNotes` lists them)', act = function(r) return to_diff(r, function() M.note_here() end) end },
  { id = 'finish', lhs = 'R', on = 'both', desc = 'Finish review and open next commit',
    doc = 'Finish after every file is checked and open the next unchecked commit; this clears the finished commit from pending reviews', act = function() return function() M.finish_next() end end },
  { id = 'whitespace', lhs = '<leader>rw', on = 'both', desc = 'Toggle review whitespace', doc = 'Show / hide whitespace differences',
    act = function(r) return function() r.whitespace = not r.whitespace; options(r); tell('Whitespace changes: ' .. (r.whitespace and 'hidden' or 'shown')) end end },
  { id = 'context', lhs = '<leader>rc', on = 'both', desc = 'Toggle review context', doc = 'Six context lines / full-file context',
    act = function(r) return function() r.context = not r.context; options(r); tell('Context: ' .. (r.context and 'full file' or 'six lines')) end end },
  { id = 'file-list', lhs = '<leader>re', on = 'both', desc = 'Toggle review file list', also = '`:ReviewFiles`',
    doc = 'Toggle the review file list, keeping the comparison open; `Space e` keeps its normal Neo-tree binding', act = function() return M.toggle_panel end },
  { id = 'symdeps', lhs = 's', on = 'both', desc = 'Inspect changed C++ symbol in working copy',
    doc = 'Inspect the changed C/C++ file in symdeps (current working copy near the reviewed line)', act = function() return function() M.symdeps(false) end end },
  { id = 'source', lhs = 'gf', on = 'both', desc = 'Open the working file for this change', doc = 'Open the editable working file in a separate tab',
    act = function() return function() M.open_source() end end },
  { id = 'layout', lhs = 'S', on = 'both', desc = 'Compare struct layout with review base', doc = "Compare the current struct's layout with the selected commit's parent",
    act = function() return function() M.symdeps(true) end end },
  { id = 'refresh', lhs = 'r', on = 'both', desc = 'Refresh this comparison', doc = 'Refresh the comparison',
    act = function(r) return in_list(r, function() M.refresh_live(); if M.current == r then M.select(r.index, true) end end) end },
  { id = 'follow', lhs = 'f', on = 'list', desc = 'Follow selected live session', doc = 'Follow the selected live session\'s edits in a separate tab (`:ClaudeFollow` stops)',
    act = function(r) return function()
      local entry = r.entries and r.entries[api.nvim_win_get_cursor(0)[1]]
      local row = entry and entry.set and entry.set.row or r.row
      if row.kind == 'live' then require('desk.claude').follow(row)
      else tell('Follow works on a live session row; this one is ' .. (row.kind == 'commit' and 'a commit.' or 'not a live session.')) end
    end end },
  { id = 'hide', lhs = 'q', on = 'list', desc = 'Hide review file list', row = 'hide', also = '`:q` there',
    doc = 'Hide the file list; the diff keeps its file, cursor and folds', act = function() return M.hide_panel end },
  { id = 'hide-esc', lhs = '<Esc>', on = 'list', desc = 'Hide review file list', row = 'hide', act = function() return M.hide_panel end },
  { id = 'clear', lhs = '<Esc>', on = 'diff', desc = 'Clear search highlight', doc = 'Clear search highlighting', act = function() return function() vim.cmd.nohlsearch() end end },
  { id = 'close', lhs = 'q', on = 'diff', desc = 'Close review', row = 'close', also = '`:q` in a diff, `Space Cq`',
    doc = 'Close the whole review and return to your editor', act = function(r) return r.close end },
  { id = 'close-bd', lhs = '<leader>bd', on = 'both', desc = 'Close Changes', row = 'close', act = function(r) return r.close end },
}
-- The key a menu row names for one of these, as typed ("m", "<leader>re").
function M.bind(id)
  for _, entry in ipairs(M.keymap) do if entry.id == id then return entry.lhs end end
end
local function maps(r, buf, sidebar)
  for _, entry in ipairs(M.keymap) do
    if entry.on == 'both' or entry.on == (sidebar and 'list' or 'diff') then
      vim.keymap.set('n', entry.lhs, entry.act(r), { buffer = buf, desc = entry.desc, silent = true })
    end
  end
  if not sidebar then return end
  vim.keymap.set('n', '<LeftMouse>', function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid ~= r.panel_win or mouse.line < 1 or mouse.line > api.nvim_buf_line_count(r.panel_buf) then return end
    api.nvim_set_current_win(r.panel_win)
    api.nvim_win_set_cursor(r.panel_win, { mouse.line, 0 })
    if mouse.line == 1 or mouse.line == r.footer_line then M.actions(); return end
    local entry = r.entries and r.entries[mouse.line]
    local hit = r.hits and r.hits[mouse.line] or {}
    local within = function(range) return range and mouse.column >= range[1] and mouse.column <= range[2] end
    local file_row = entry and entry.file and not entry.symbol
    local expanded = file_row and (entry.set and entry.set.files or r.files)[entry.file].expanded
    if M.enter() and file_row then
      if within(hit.mark) then M.mark()
      elseif within(hit.fold) then
        (entry.set and entry.set.files or r.files)[entry.file].expanded = not expanded
        panel(r)
      end
    end
    if api.nvim_win_is_valid(r.panel_win) then api.nvim_set_current_win(r.panel_win) end
  end, { buffer = buf, desc = 'Click commit, file or review checkbox', silent = true })
end

local function entry_key(r, entry)
  if not entry then return nil end
  local row = entry.set and entry.set.row or r.row
  local key = (row.kind or '') .. ':' .. (row.sha or row.sid or '')
  if entry.file then
    local file = (entry.set and entry.set.files or r.files)[entry.file]
    key = key .. ':' .. (file and file.rel or '')
  end
  if entry.symbol then key = key .. ':' .. entry.symbol.name .. ':' .. entry.symbol.side end
  return key
end
local function remember_panel(r)
  if not api.nvim_win_is_valid(r.panel_win) or not api.nvim_buf_is_valid(r.panel_buf) or api.nvim_win_get_buf(r.panel_win) ~= r.panel_buf then return end
  r.panel_view = api.nvim_win_call(r.panel_win, vim.fn.winsaveview)
  r.panel_width = api.nvim_win_get_width(r.panel_win)
  r.panel_selection = entry_key(r, r.entries and r.entries[r.panel_view.lnum])
  r.panel_active_file = r.files[r.index]
end
local function diff_views(r)
  local saved = {}
  for _, win in ipairs({ r.left_win, r.right_win }) do
    if api.nvim_win_is_valid(win) then saved[win] = api.nvim_win_call(win, vim.fn.winsaveview) end
  end
  return saved
end
local function restore_views(saved)
  for win, view in pairs(saved) do if api.nvim_win_is_valid(win) then api.nvim_win_call(win, function() vim.fn.winrestview(view) end) end end
end
local function panel_buffer(r)
  if api.nvim_buf_is_valid(r.panel_buf or -1) and api.nvim_buf_is_loaded(r.panel_buf) then return end
  r.panel_buf = api.nvim_create_buf(false, true); r.buffers[#r.buffers + 1] = r.panel_buf
  vim.b[r.panel_buf].desk_review_panel = true
  vim.bo[r.panel_buf].filetype, vim.bo[r.panel_buf].bufhidden = 'foxml-review', 'hide'
  api.nvim_create_autocmd('CursorMoved', { buffer = r.panel_buf, callback = function()
    if M.current ~= r or not api.nvim_win_is_valid(r.panel_win) then return end
    local line = api.nvim_win_get_cursor(r.panel_win)[1]
    if line ~= r.strip_for then r.strip_for = line; panel(r) end
    remember_panel(r)
  end })
  maps(r, r.panel_buf, true)
end
local function configure_panel(r)
  api.nvim_win_set_buf(r.panel_win, r.panel_buf)
  api.nvim_win_call(r.panel_win, function() vim.cmd.diffoff() end)
  local options = { number = false, relativenumber = false, signcolumn = 'no', wrap = false, winfixwidth = true,
    winbar = '', statusline = ' ', cursorline = false, list = false, foldcolumn = '0', scrollbind = false, cursorbind = false }
  for key, value in pairs(options) do vim.wo[r.panel_win][key] = value end
end

function M.hide_panel()
  local r = M.current
  if not r or not api.nvim_win_is_valid(r.panel_win) then return false end
  remember_panel(r)
  local saved, win, previous_diff = diff_views(r), r.panel_win, r.last_diff_win
  local focused = api.nvim_get_current_win() == win
  r.owned[win] = nil; r.panel_hidden = true
  local ok, error = pcall(api.nvim_win_close, win, false)
  if not ok then r.owned[win] = true; r.panel_hidden = false; tell(tostring(error)); return false end
  M.layout(); restore_views(saved)
  if focused then
    local target = previous_diff
    if target ~= r.left_win and target ~= r.right_win or not api.nvim_win_is_valid(target or -1) then target = r.right_win end
    if api.nvim_win_is_valid(target) then api.nvim_set_current_win(target) end
  end
  return true
end

function M.show_panel(focus)
  local r = M.current
  if not r or not api.nvim_tabpage_is_valid(r.tab) then return false end
  if focus then api.nvim_set_current_tabpage(r.tab) end
  if api.nvim_get_current_tabpage() ~= r.tab then return false end
  if api.nvim_win_is_valid(r.panel_win) then if focus then api.nvim_set_current_win(r.panel_win) end; return true end
  if not api.nvim_win_is_valid(r.left_win) or not api.nvim_win_is_valid(r.right_win) then return false end
  local saved, current, previous_diff = diff_views(r), api.nvim_get_current_win(), r.last_diff_win
  api.nvim_set_current_win(r.left_win)
  if not pcall(vim.cmd, 'leftabove vsplit') then
    if api.nvim_win_is_valid(current) then api.nvim_set_current_win(current) end
    tell('There is not enough room for the file list at this width.'); return false
  end
  r.panel_win = api.nvim_get_current_win()
  panel_buffer(r); configure_panel(r); r.owned[r.panel_win] = true; r.panel_hidden = false
  M.layout()
  if r.panel_active_file and r.panel_active_file ~= r.files[r.index] then panel(r, true)
  elseif r.panel_view then
    local view = vim.deepcopy(r.panel_view)
    for line, entry in pairs(r.entries or {}) do if entry_key(r, entry) == r.panel_selection then view.lnum = line; break end end
    api.nvim_win_call(r.panel_win, function() vim.fn.winrestview(view) end)
  end
  restore_views(saved)
  r.last_diff_win = previous_diff
  if focus then api.nvim_set_current_win(r.panel_win)
  elseif api.nvim_win_is_valid(current) then api.nvim_set_current_win(current) end
  return true
end

function M.toggle_panel()
  local r = M.current
  if not r then tell('Open a review first.'); return false end
  if api.nvim_get_current_tabpage() ~= r.tab then return M.show_panel(true) end
  if api.nvim_win_is_valid(r.panel_win) then return M.hide_panel() end
  return M.show_panel(true)
end

function M.refresh_requests(wait)
  local r = M.current
  local backend = M.work_tool()
  if not r or r.closing or r.row.kind == 'commit' or not backend then return end
  if not wait and r.requests_pending then return end
  r.requests_generation = (r.requests_generation or 0) + 1
  local generation = r.requests_generation
  local function apply(out)
    if M.current ~= r or r.closing or generation ~= r.requests_generation then return end
    r.requests_pending = false
    local ok, list = pcall(vim.json.decode, out and out.stdout or '')
    if not out or out.code ~= 0 or not ok or type(list) ~= 'table' or not vim.islist(list) then
      if wait then tell('Could not refresh change requests; showing their last known status.', vim.log.levels.WARN) end
      return
    end
    local standing = {}
    for _, request in ipairs(list) do
      if type(request) == 'table' and type(request.file) == 'string' then standing[request.file] = request end
    end
    r.shared_requests = standing
    if api.nvim_buf_is_valid(r.panel_buf) then panel(r) end
  end
  local argv = { backend, 'review-requests', '--root', r.root }
  if wait then
    local ok, job = pcall(vim.system, argv, { text = true })
    apply(ok and job:wait(1500) or nil)
  else
    r.requests_pending = true
    local ok = pcall(vim.system, argv, { text = true, timeout = 3000 }, vim.schedule_wrap(apply))
    if not ok then r.requests_pending = false end
  end
end

function M.select(index, refresh)
  local r = M.current
  if not r or not r.files[index] then return end
  if not api.nvim_tabpage_is_valid(r.tab) or not api.nvim_win_is_valid(r.left_win) or not api.nvim_win_is_valid(r.right_win) then
    tell('The comparison was closed; reopen What changed.'); return
  end
  api.nvim_set_current_tabpage(r.tab)
  local old_file = r.displayed_file
  if old_file then old_file.views = diff_views(r) end
  r.index = index
  M.refresh_requests(refresh)
  r.symbol = nil
  local file = r.files[index]
  load_file(r, file, refresh or r.row.kind ~= 'commit')
  local old = { r.left_buf, r.right_buf }
  local left, right = file.left, file.right
  file.since = nil
  if M.since_mode() and not file.error and not file.binary and r.marks[file.rel] and r.marks[file.rel] ~= file.signature then
    local copy = reviewed_copy(r, file)
    if copy and copy ~= right then left, file.since = copy, true end
  end
  if file.error then left, right = 'Snapshot unavailable. Refresh to retry.', 'Snapshot unavailable. This file cannot be marked reviewed.'
  elseif file.binary then left, right = 'Binary file — text comparison unavailable.', 'Binary file — inspect externally before marking reviewed.' end
  if r.displayed_file == file and r.displayed_row == r.row and r.displayed_left == left and r.displayed_right == right
      and r.displayed_since == file.since and api.nvim_buf_is_valid(r.left_buf or -1) and api.nvim_buf_is_valid(r.right_buf or -1) then
    r.notes = M.notes(r.root)
    options(r); panel(r, true); draw_notes(r)
    local target = r.last_diff_win
    if target ~= r.left_win and target ~= r.right_win or not api.nvim_win_is_valid(target or -1) then target = r.right_win end
    api.nvim_set_current_win(target)
    return
  end
  r.generation = (r.generation or 0) + 1
  r.left_buf, r.right_buf = scratch(r, file, 'before', left), scratch(r, file, 'after', right)
  local before = file.since and 'What you reviewed' or r.row.before_label or (r.row.kind == 'commit' and ('Before · ' .. r.row.parent:sub(1, 8))
    or r.row.kind == 'working' and 'HEAD · last commit' or 'Before session · captured baseline')
  local after = file.since and 'Now · only what is new since then' or r.row.after_label or (r.row.kind == 'commit' and ('After · ' .. r.row.sha:sub(1, 8))
    or r.row.kind == 'working' and 'Working copy · includes drafts' or 'Working copy · captured now')
  for _, pair in ipairs({ { r.left_win, r.left_buf, before }, { r.right_win, r.right_buf, after } }) do
    local win, buf, label = unpack(pair)
    api.nvim_win_set_buf(win, buf)
    api.nvim_win_call(win, function() vim.cmd('diffthis'); vim.wo.foldmethod = 'diff'; vim.wo.foldlevel = 0 end)
    vim.wo[win].number, vim.wo[win].relativenumber = true, false
    vim.wo[win].cursorline, vim.wo[win].wrap = false, false
    vim.wo[win].signcolumn, vim.wo[win].foldcolumn = 'no', '1'
    vim.wo[win].winbar = '%#Title# ' .. escaped(label) .. ' · %<%#Normal#' .. escaped(file.rel) .. '%*'
    vim.wo[win].winhighlight = win == r.left_win and 'DiffAdd:FoxReviewRemoved,DiffDelete:FoxReviewFiller' or 'DiffDelete:FoxReviewFiller'
    maps(r, buf, false)
  end
  for _, buf in ipairs(old) do if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end end
  r.notes = M.notes(r.root)
  options(r); panel(r, true)
  local target = r.last_diff_win
  if target ~= r.left_win and target ~= r.right_win or not api.nvim_win_is_valid(target or -1) then target = r.right_win end
  api.nvim_set_current_win(target)
  local h = file.hunks[1]
  if h then
    api.nvim_win_set_cursor(r.left_win, { math.max(1, math.min(h[1], api.nvim_buf_line_count(r.left_buf))), 0 })
    api.nvim_win_set_cursor(r.right_win, { math.max(1, math.min(h[3], api.nvim_buf_line_count(r.right_buf))), 0 })
  end
  vim.cmd('diffupdate')
  if file.views then restore_views(file.views) end
  r.displayed_file, r.displayed_row, r.displayed_left, r.displayed_right, r.displayed_since = file, r.row, left, right, file.since
  draw_notes(r)
end

-- The working list follows the working tree: a file changed after the review opened joins it, a file back to its
-- committed state leaves it, and files already read keep their place and checks. The table is filled in place: the
-- tree's group holds the same one.
local function resync_working(r)
  if r.row.kind ~= 'working' then return false end
  local now = M.working_files(r.root)
  if not now then return false end
  local same = #now == #r.files
  for i, f in ipairs(now) do if not (r.files[i] and r.files[i].rel == f.rel) then same = false end end
  if same then return false end
  local by_rel, open = {}, r.files[r.index] and r.files[r.index].rel
  for _, f in ipairs(r.files) do by_rel[f.rel] = f end
  local merged = {}
  for _, f in ipairs(now) do
    local kept = by_rel[f.rel]
    if kept then kept.status, kept.old = f.status, f.old end
    merged[#merged + 1] = kept or f
  end
  for i = #r.files, 1, -1 do r.files[i] = nil end
  for i, f in ipairs(merged) do r.files[i] = f end
  r.index = 1
  for i, f in ipairs(r.files) do if f.rel == open then r.index = i end end
  return true, open
end
function M.refresh_live()
  local r = M.current
  if not r or r.closing then return end
  M.refresh_requests()
  if r.row.kind == 'commit' or r.row.snapshots then return end
  -- Hidden comparisons catch up when their tab returns, without taking focus from ordinary editing.
  if api.nvim_get_current_tabpage() ~= r.tab then r.live_dirty = true; return end
  r.live_dirty = false
  local moved, open = resync_working(r)
  if moved then
    if #r.files == 0 then panel(r); return end
    if r.files[r.index].rel ~= open then M.select(r.index); return end
  end
  local selected = r.files[r.index]
  if not selected then return end
  local signature, failed, binary = selected.signature, selected.error, selected.binary
  for _, file in ipairs(r.files) do if file.loaded or file == selected then load_file(r, file, true) end end
  if signature == selected.signature and failed == selected.error and binary == selected.binary then panel(r); return end
  local win, views = api.nvim_get_current_win(), {}
  for _, target in ipairs({ r.left_win, r.right_win, r.panel_win }) do
    if api.nvim_win_is_valid(target) then views[target] = api.nvim_win_call(target, vim.fn.winsaveview) end
  end
  M.select(r.index)
  for target, view in pairs(views) do
    if api.nvim_win_is_valid(target) then api.nvim_win_call(target, function() vim.fn.winrestview(view) end) end
  end
  if api.nvim_win_is_valid(win) then api.nvim_set_current_win(win) end
end

function M.toggle_since()
  local on = not M.since_mode()
  write_private(reviews_dir() .. '/prefs.json', vim.json.encode({ since = on }))
  local r = M.current
  if r then M.select(r.index, true) end
  tell(on and 'Showing only what is new since you reviewed a file.' or 'Showing the whole change.')
end

function M.unread()
  local r = M.current
  if not r then return end
  M.refresh_requests(true)
  for _, f in ipairs(r.files) do load_file(r, f, r.row.kind ~= 'commit') end
  -- What needs the most care comes first: an unread file with a risk mark, then the rest in order.
  for pass = 1, 2 do
    for i, f in ipairs(r.files) do
      local risky = f.risks and #f.risks > 0
      local request = M.request_of(r, f)
      local waiting = request and not request.ready       -- still with the session: nothing to read yet
      if r.marks[f.rel] ~= f.signature and not waiting and (pass == 2 or risky or (request and request.ready)) then M.select(i); return end
    end
  end
  local waiting = 0
  for _, f in ipairs(r.files) do
    if r.marks[f.rel] ~= f.signature then waiting = waiting + 1 end
  end
  panel(r)
  tell(waiting > 0 and ('Waiting on ' .. waiting .. (waiting == 1 and ' change request.' or ' change requests.'))
    or 'Every file is checked. R finishes the review.')
end

function M.mark()
  local r = M.current
  if not r then return end
  local file = r.files[r.index]
  if file.error then tell('An unavailable snapshot cannot be marked reviewed.', vim.log.levels.WARN); return end
  local previous = r.marks[file.rel]
  if previous == file.signature then r.marks[file.rel] = nil else r.marks[file.rel] = file.signature end
  r.completed = false
  if r.active_set then r.active_set.completed = false end
  if not save(r, file) then r.marks[file.rel] = previous end
  panel(r)
end

function M.finish()
  local r = M.current
  if not r then return end
  if r.row.kind ~= 'commit' then
    for _, f in ipairs(r.files) do load_file(r, f, true) end
  end
  if progress(r) ~= #r.files then panel(r); tell('Check each file first. Check & next opens the next unread file.'); return false end
  local backend = M.work_tool()
  if r.row.kind == 'commit' and backend then
    local ok, job = pcall(vim.system, { backend, 'reviewed', '--root', r.root, '--sha', r.row.sha }, { text = true })
    local out = ok and job:wait(3000) or {}
    if out.code ~= 0 or decode(out.stdout).ok ~= true then
      tell('Could not record this review; it remains pending. ' .. require('desk.work').refusal({ 'reviewed' }, out), vim.log.levels.ERROR); return false
    end
  end
  r.completed = true
  if r.active_set then r.active_set.completed = true end
  if not save(r) then return false end
  tell('Review complete · ' .. #r.files .. ' files checked'); return true
end

function M.finish_next()
  local r = M.current
  if not r or not M.finish() then return false end
  if r.row.kind ~= 'commit' or not r.sets then return true end
  local at = 1
  for i, set in ipairs(r.sets) do if set == r.active_set then at = i; break end end
  for offset = 1, #r.sets - 1 do
    local set = r.sets[(at + offset - 1) % #r.sets + 1]
    if set.row.kind == 'commit' and not set.completed then
      if not set.files then set.files = M.files(set.row, r.root) end
      if set.files and #set.files > 0 then M.switch(set); M.unread(); return true end
    end
  end
  tell('Review saved. No next commit with changed files.'); return true
end

function M.jump(symbol)
  local r = M.current
  if not r then return end
  local file = r.files[r.index]
  if symbol.signature ~= file.signature then
    for _, fresh in ipairs(M.changed_symbols(file)) do if fresh.name == symbol.name then symbol = fresh; break end end
    if symbol.signature ~= file.signature then tell('This change moved; its comparison was refreshed.'); return end
  end
  r.symbol = symbol
  local win = symbol.side == 'before' and r.left_win or r.right_win
  local buf = api.nvim_win_get_buf(win)
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { math.max(1, math.min(symbol.line, api.nvim_buf_line_count(buf))), 0 })
  vim.cmd('normal! zvzz')
  panel(r, true)
end

function M.switch(set, index)
  local r = M.current
  if not r then return end
  if set == r.active_set then M.select(index or r.index); return end
  if r.active_set then r.active_set.marks = r.marks end
  if not set.files then set.files = M.files(set.row, r.root) end
  if not set.files or #set.files == 0 then tell('This commit has no changed files.'); return end
  r.row, r.files, r.label, r.active_set = set.row, set.files, set.row.short, set
  r.state_file = state_file(r.root, r.row)
  local stored = decode(read(r.state_file))
  r.marks = type(stored.files) == 'table' and stored.files or {}
  set.marks, set.expanded = r.marks, true
  r.completed = stored.completed == true
  M.select(index or 1)
end

function M.enter(marking)
  local r = M.current
  if not r or not api.nvim_win_is_valid(r.panel_win) then return false end
  local line = api.nvim_win_get_cursor(r.panel_win)[1]
  local entry = r.entries[line]
  if entry and entry.file then
    if entry.set then M.switch(entry.set, entry.file) else M.select(entry.file) end
    if not marking then r.files[r.index].expanded = true end
    if entry.symbol then M.jump(entry.symbol) else panel(r, true) end
    return true
  end
  if r.sets then
    if not entry then return false end
    if marking then return false end
    local set = entry.set
    if not set.files then set.files = M.files(set.row, r.root) or {} end
    set.expanded = not set.expanded
    panel(r); return false
  end
  return false
end

function M.primary()
  local r = M.current
  if not r then return end
  if r.row.kind == 'external' then
    require('desk.claude').close(); require('desk.sync').merge(); return
  end
  if progress(r) == #r.files then M.finish_next(); return end
  local file = r.files[r.index]
  if r.marks[file.rel] ~= file.signature then M.mark() end
  M.unread()
end

-- Clicks for the plugin's menu, through its public surface only: the menu marks its buffer (b:fox_symdeps_menu), and
-- its own j / k / Enter mappings move and run, so its remembered row and cursor restoration stay its own.
local function menu_window()
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_win_get_config(win).relative ~= '' and vim.b[buf].fox_symdeps_menu ~= nil then return win, buf end
  end
end
local function menu_mouse()
  local win, buf = menu_window()
  if not win then return end
  vim.keymap.set('n', '<LeftMouse>', function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid ~= win or not api.nvim_win_is_valid(win) or mouse.line < 1 then return end
    local start = api.nvim_win_get_cursor(win)[1]
    local key = start < mouse.line and 'j' or 'k'
    local move = vim.fn.maparg(key, 'n', false, true)
    -- A rule or blank line is not a row: the menu's own movement never lands there, so the click does nothing.
    for _ = 1, api.nvim_buf_line_count(buf) do
      local at = api.nvim_win_get_cursor(win)[1]
      if at == mouse.line then break end
      if type(move.callback) ~= 'function' then return end
      move.callback()
      if api.nvim_win_get_cursor(win)[1] == at then break end
    end
    if api.nvim_win_get_cursor(win)[1] ~= mouse.line then
      -- Put the selection back where it was rather than leave it part-way.
      local back = vim.fn.maparg(key == 'j' and 'k' or 'j', 'n', false, true)
      for _ = 1, api.nvim_buf_line_count(buf) do
        if api.nvim_win_get_cursor(win)[1] == start or type(back.callback) ~= 'function' then break end
        local at = api.nvim_win_get_cursor(win)[1]; back.callback()
        if api.nvim_win_get_cursor(win)[1] == at then break end
      end
      return
    end
    local submit = vim.fn.maparg('<CR>', 'n', false, true)
    if type(submit.callback) == 'function' then submit.callback() end
  end, { buffer = buf, silent = true, nowait = true, desc = 'Choose this action' })
end

-- Use the optional plugin's menu kit so its selection, detail strip and navigation stay identical.
function M.show_menu(items, opts)
  opts = opts or {}
  local ok, menu = pcall(require, 'fox-symdeps.menu')
  if not ok then
    -- Without the plugin: the same list in the built-in menu, drawn to the same rules (foxml/menu.lua).
    local found, fallback = pcall(require, 'desk.menu')
    if found then fallback.open(items, { title = opts.title, memo = opts.memo, back = false }); return end
    vim.ui.select(items, { prompt = opts.title or 'Actions', format_item = function(item) return item.name or item.label end },
      function(item) if item then item.run() end end)
    return
  end
  for _, item in ipairs(items) do
    if item.stays then
      item.run_stays = function()
        item.run()
        -- The renderer reopens toggles itself; bind clicks on the replacement buffer too.
        vim.schedule(menu_mouse)
      end
    end
  end
  menu.open(items, { title = opts.title, anchor_win = opts.anchor_win, memo = opts.memo, back = false })
  menu_mouse()
end

function M.actions()
  local r = M.current
  if not r then return end
  local actions = {}
  local function add(name, detail, fn, metadata)
    local item = vim.tbl_extend('force', metadata or {}, { name = name, label = name .. ' — ' .. detail, run = fn })
    actions[#actions + 1] = item
  end
  if r.row.kind == 'external' then
    add('Merge separate edits', 'Combine non-overlapping edits into your buffer, without saving. Overlaps keep both copies.', M.primary,
      { group = 'review', writes = 'code', bind = '<leader>Cl' })
    add('Keep my buffer', 'Keep your version for the next save; the disk copy is replaced only when you save.',
      function() require('desk.claude').close(); require('desk.sync').keep() end, { group = 'review' })
  else
    add('Check & next', 'Mark this file reviewed and open the next unread file.', M.primary, { group = 'review' })
    add('File reviewed', 'Toggle this file’s review checkmark. Your place is saved.', M.mark, { group = 'review', bind = M.bind('mark'), stays = true,
      state = function() local f = r.files[r.index]; return r.marks[f.rel] == f.signature end })
    add('Finish & next commit', 'Finish this review and open the next unchecked commit in this list.', M.finish_next,
      { group = 'review', bind = M.bind('finish'), right = progress(r) .. '/' .. #r.files .. ' checked' })
    add('First unread file', 'Return to the first file you have not checked in this change.', M.unread, { group = 'review', bind = M.bind('unread') })
    add('Tests for this file', 'Choose a captured test command, inspect why it was suggested, then explicitly run it on saved files.',
      function() require('desk.claude').close(); require('desk.work').suggested_tests(r.files[r.index].path) end, { group = 'review' })
    add('Plan coverage', 'Each step of the plan with its matching edits or recorded commits, and the changed files no step names.',
      M.plan_coverage, { group = 'review', bind = M.bind('plan') })
    add('Note to self', 'Leave yourself a note on this line. It stays with the file in every later review; an empty note removes it.',
      function() api.nvim_set_current_win(r.right_win); M.note_here() end, { group = 'review', bind = M.bind('note') })
    add('My notes', 'Every note of yours in this project, by file. Enter goes to its line.', function() M.notes_list() end, { group = 'review' })
    add('Request changes', 'Write a note about this file (or the selected lines) to a Claude session. The file then waits on it and reads ready for re-review once it changes.',
      function() api.nvim_set_current_win(r.right_win); require('desk.claude').send() end, { group = 'review', bind = M.bind('request') })
    add('Only what is new', 'A file edited after you checked it opens against the copy you reviewed. Off shows the whole change. Remembered.',
      M.toggle_since, { group = 'review', bind = M.bind('since-list'), state = function() return M.since_mode() end, stays = true })
  end
  local file = r.files[r.index]
  local ft = vim.filetype.match({ filename = file.path })
  if r.row.kind ~= 'external' then
    -- API review spends credits: it needs the API setup, and says so when that is missing.
    local found, work = pcall(require, 'desk.work')
    local ready = found and type(work.api_available) == 'function' and work.api_available()
    local needs = (not ready) and 'needs API' or nil
    add('API review: file', 'Requires the API setup (a key and a budget). Send exactly this file’s displayed change for review on API credits. You choose the model and a budget first.',
      function() M.api_review('file') end, { group = 'api', right = needs })
    add('API review: change', 'Requires the API setup (a key and a budget). Send every file of this change (as far as one request holds) for review on API credits.',
      function() M.api_review('commit') end, { group = 'api', right = needs })
    add('Explain this hunk', 'Requires the API setup (a key and a budget). Ask what the change under the cursor does and what it affects, on API credits.',
      function() M.api_review('hunk') end, { group = 'api', right = needs })
    if M.api_of(r, file) then
      add('Open API review', 'Open the saved API review of this file; its path:line citations become a jump list.', M.api_open, { group = 'api', bind = M.bind('api') })
    end
  end
  if vim.fn.filereadable(file.path) == 1 or vim.fn.bufnr(file.path) >= 0 then
    add('Open working file', 'Open the editable working file at this change; keep the review available in its own tab.',
      function() api.nvim_set_current_win(r.right_win); M.open_source() end, { group = 'inspect', bind = M.bind('source') })
  end
  if ft == 'cpp' or ft == 'c' then
    -- Symbol context is symdeps' job. Without it the rows stay, saying what they need (docs/ui-style.md).
    local has = pcall(require, 'fox-symdeps')
    local needs = (not has) and 'requires symdeps' or nil
    add('Inspect symbol', has and 'Open the current working C++ file near this change and inspect it in symdeps.'
        or 'Callers, uses and layout of the symbol at this change. Requires symdeps, an optional plugin.',
      function() api.nvim_set_current_win(r.right_win); M.symdeps(false) end, { group = 'inspect', bind = M.bind('symdeps'), right = needs })
    if r.row.kind == 'commit' then
      add('Compare struct layout', has and 'Compare the current struct with this commit’s base, using the current project headers.'
          or 'The struct’s layout before and after this commit. Requires symdeps, an optional plugin.',
        function() api.nvim_set_current_win(r.right_win); M.symdeps(true) end, { group = 'inspect', bind = M.bind('layout'), right = needs })
    end
  end
  add('Ignore whitespace', 'Hide whitespace-only differences while reviewing this change.',
    function() r.whitespace = not r.whitespace; options(r) end,
    { group = 'comparison', bind = M.bind('whitespace'), stays = true, state = function() return r.whitespace == true end })
  add('Full-file context', 'Show the entire file instead of six context lines around each changed block.',
    function() r.context = not r.context; options(r) end,
    { group = 'comparison', bind = M.bind('context'), stays = true, state = function() return r.context == true end })
  add('Refresh comparison', 'Read the snapshots again; live reviews capture the current working copy.',
    function() M.select(r.index, true) end, { group = 'comparison', bind = M.bind('refresh') })
  add('Return to editor', 'Close Changes and return to your original editor and unsaved work.', r.close, { group = 'comparison', bind = M.bind('close') })
  add('File list', 'Show or hide the sidebar while keeping the comparison open.', M.toggle_panel, { group = 'comparison', bind = M.bind('file-list') })
  M.show_menu(actions, { title = 'Changes', anchor_win = api.nvim_win_is_valid(r.panel_win) and r.panel_win or r.right_win, memo = 'foxml-review-actions' })
end

function M.layout()
  local r = M.current
  if not r or not api.nvim_tabpage_is_valid(r.tab) or api.nvim_get_current_tabpage() ~= r.tab then return end
  for _, win in ipairs({r.left_win, r.right_win}) do if not api.nvim_win_is_valid(win) then return end end
  local shown = api.nvim_win_is_valid(r.panel_win)
  local room = api.nvim_win_get_width(r.left_win) + api.nvim_win_get_width(r.right_win) + (shown and api.nvim_win_get_width(r.panel_win) or 0)
  local width = shown and math.min(math.max(16, room - 36), r.panel_width or math.min(52, math.max(30, math.floor(room * .30)))) or 0
  if shown then api.nvim_win_set_width(r.panel_win, width); panel(r) end
  local left, right = api.nvim_win_get_position(r.left_win), api.nvim_win_get_position(r.right_win)
  if left[1] == right[1] and right[2] == left[2] + api.nvim_win_get_width(r.left_win) + 1 then
    local available = api.nvim_win_get_width(r.left_win) + api.nvim_win_get_width(r.right_win)
    api.nvim_win_set_width(r.left_win, math.max(1, math.floor(available / 2)))
  end
end

function M.fold()
  local r = M.current
  if not r or not api.nvim_win_is_valid(r.panel_win) then return end
  local entry = r.entries[api.nvim_win_get_cursor(r.panel_win)[1]]
  if not entry then return end
  if entry.file then
    local file = (entry.set and entry.set.files or r.files)[entry.file]
    if file.expanded then
      file.expanded = false; panel(r)
      for line, e in pairs(r.entries) do
        if e.set == entry.set and e.file == entry.file and not e.symbol then api.nvim_win_set_cursor(r.panel_win, {line, 0}); break end
      end
      return
    end
  end
  if not entry.set then return end
  entry.set.expanded = false
  panel(r)
  for line, e in pairs(r.entries) do
    if e.set == entry.set and not e.file then api.nvim_win_set_cursor(r.panel_win, { line, 0 }); break end
  end
end

-- The tree: Working changes, live sessions, then commits oldest first under their task (the plan desk-work recorded
-- for them, else its "branch · day"); commits it does not list (not Claude's) come last as Other changes.
function M.tree(rows)
  local r = M.current
  if not r then return end
  local tasks, order = {}, {}
  local backend = M.work_tool()
  if backend then
    local ok, job = pcall(vim.system, { backend, 'review-tree', '--root', r.root, '--all', 'yes' }, { text = true })
    local out = ok and job:wait(3000) or {}
    for index, task in ipairs(out.code == 0 and decode(out.stdout) or {}) do
      for _, c in ipairs(type(task.commits) == 'table' and task.commits or {}) do
        tasks[c.sha] = { title = task.title, step = c.step, index = index, plan = task.plan, tests = c.tests }
      end
    end
  end
  local head, commits = {}, {}
  for position, row in ipairs(rows) do
    if row.kind == 'commit' then
      local task = tasks[row.sha]
      row.task, row.step, row.plan = task and task.title or nil, task and task.step or nil, task and task.plan or nil
      row.tests = task and task.tests or nil
      commits[#commits + 1] = { row = row, group = task and task.index or math.huge, position = position }
    else head[#head + 1] = row end
  end
  -- rows arrive newest first; within a group the oldest comes first.
  table.sort(commits, function(a, b)
    if a.group ~= b.group then return a.group < b.group end
    return a.position > b.position
  end)
  for _, c in ipairs(commits) do head[#head + 1] = c.row end
  r.sets = {}
  for _, row in ipairs(head) do
    local stored = decode(read(state_file(r.root, row)))
    local set = { row = row, completed = row.kind == 'commit' and stored.completed == true }
    if row == r.row then
      set.expanded, set.files, set.marks, r.active_set = true, r.files, r.marks, set
    end
    r.sets[#r.sets + 1] = set
  end
  M.show_panel(true); panel(r, true)
end

function M.open_source()
  local r = M.current
  if not r then return false end
  if api.nvim_get_current_win() == r.panel_win and not M.enter(true) then return end
  local file = r.files[r.index]
  if vim.fn.filereadable(file.path) ~= 1 and vim.fn.bufnr(file.path) < 0 then tell('This historical file is absent from the working copy.'); return false end
  local current = api.nvim_get_current_win()
  local line = r.symbol and r.symbol.line or (current == r.left_win or current == r.right_win) and api.nvim_win_get_cursor(current)[1]
    or (file.hunks[1] and file.hunks[1][3]) or 1
  local automatic, all = vim.o.autowrite, vim.o.autowriteall
  vim.o.autowrite, vim.o.autowriteall = false, false
  local ok, err = pcall(function()
    if r.source_tab and api.nvim_tabpage_is_valid(r.source_tab) then api.nvim_set_current_tabpage(r.source_tab)
    else vim.cmd('tabnew'); r.source_tab = api.nvim_get_current_tabpage() end
    vim.cmd.edit(vim.fn.fnameescape(file.path))
    api.nvim_win_set_cursor(0, { math.min(line, api.nvim_buf_line_count(0)), 0 })
  end)
  vim.o.autowrite, vim.o.autowriteall = automatic, all
  if not ok then tell(tostring(err), vim.log.levels.WARN); return false end
  return true
end

function M.symdeps(compare)
  local r = M.current
  if not r then return end
  if api.nvim_get_current_win() == r.panel_win and not M.enter(true) then return end
  local ft = vim.filetype.match({ filename = r.files[r.index].path })
  if ft ~= 'cpp' and ft ~= 'c' then tell('Symdeps analyzes C and C++ files.'); return end
  local loaded, plugin = pcall(require, 'fox-symdeps')
  if not loaded then tell('Requires symdeps (an optional plugin for C and C++ symbols).'); return end
  if compare and r.row.kind ~= 'commit' then tell('Layout compare needs a commit: it compares with the commit\'s parent.'); return end
  if not M.open_source() then return end
  if compare and r.row.kind == 'commit' then
    local available, rev = pcall(require, 'fox-symdeps.revcompare')
    local found, context = pcall(require, 'fox-symdeps.context')
    local ctx = found and type(context.under_cursor) == 'function' and context.under_cursor() or nil
    if available and ctx then rev.open(ctx, r.row.parent)
    elseif available then tell('Put the cursor on a struct to compare its layout with the commit.')
    else tell('This symdeps version does not expose revision comparison.') end
  else
    -- The card's own module is where this lives; the plugin's top-level view of it is marked for removal there.
    local has_card, card = pcall(require, 'fox-symdeps.card')
    local inspect = has_card and type(card) == 'table' and type(card.inspect_cursor) == 'function' and card.inspect_cursor
      or type(plugin.inspect_cursor) == 'function' and plugin.inspect_cursor or nil
    if not inspect then tell('This symdeps version does not expose its card.'); return end
    tell('Symdeps · current working copy near the reviewed line')
    inspect()
  end
end

-- Request changes: a note sent to a session about the file under review is kept beside that file (who, what, and
-- the file's signature then). While the file is as it was, the row waits (✉); once it changes it is ready for
-- re-review (↻). Checking the file settles the request.
function M.requested(path, peer, text)
  local r = M.current
  if not r or not path then return false end
  local file
  for _, f in ipairs(r.files) do if f.path == path then file = f; break end end
  if not file then return false end
  local disk = decode(read(r.state_file))
  disk.requests = type(disk.requests) == 'table' and disk.requests or {}
  disk.requests[file.rel] = { sid = peer and peer.id or '', name = peer and peer.name or 'a session',
    text = tostring(text or ''):gsub('[\r\n\t]', ' '):sub(1, 300), at = os.time(), signature = file.signature or '' }
  if not write_private(r.state_file, vim.json.encode(disk)) then return false end
  if r.row.kind ~= 'commit' then
    if not share_request(r, file, disk.requests[file.rel]) then return false end
    if r.shared_requests then r.shared_requests[file.rel] = vim.tbl_extend('force', disk.requests[file.rel], { state = 'waiting' }) end
  end
  r.completed = false
  panel(r)
  return true
end
-- The review's own state file, decoded once and read again only when it changes on disk: every row asks it.
function M.state_of(r)
  local stat = uv.fs_stat(r.state_file or '')
  local stamp = stat and (stat.mtime.sec .. ':' .. stat.mtime.nsec .. ':' .. stat.size) or ''
  if not r.state_cache or r.state_cache.stamp ~= stamp then r.state_cache = { stamp = stamp, data = decode(read(r.state_file)) } end
  return r.state_cache.data
end
function M.request_of(r, file)
  if r.shared_requests and r.row.kind ~= 'commit' then
    local shared = r.shared_requests[file.rel]
    if type(shared) ~= 'table' then return nil end
    return vim.tbl_extend('force', shared, { ready = shared.state == 'ready' })
  end
  local requests = M.state_of(r).requests
  local request = type(requests) == 'table' and requests[file.rel] or nil
  if type(request) ~= 'table' then return nil end
  request.ready = file.loaded and request.signature ~= '' and request.signature ~= file.signature
  return request
end

-- API review of exactly what is displayed: this file, every file of this change, or the hunk under the cursor. It goes
-- through the existing API task flow (model and budget are asked, progress shows, :ClaudeApiStop cancels); the result
-- is remembered beside each file for the version that was sent, so an older review never covers a newer edit.
local API_LIMIT = 22000
local function unified(file)
  if file.error or file.binary then return nil end
  local diff = vim.text and vim.text.diff or vim.diff
  local ok, text = pcall(diff, file.left, file.right, { result_type = 'unified', ctxlen = 4, algorithm = 'histogram' })
  if not ok or not text or text == '' then return nil end
  return '--- a/' .. (file.old or file.rel) .. '\n+++ b/' .. file.rel .. '\n' .. text
end
function M.api_review(scope)
  local r = M.current
  if not r then return end
  local ok, work = pcall(require, 'desk.work')
  if not ok or type(work.api_question) ~= 'function' or not work.api_available() then
    tell('Requires API setup: add a key and a budget under API in the drawer, or with claude-api configure.'); return
  end
  local what = r.row.kind == 'commit' and ('commit ' .. (r.row.short or '') .. ' "' .. (r.row.subject or '') .. '"') or 'uncommitted changes'
  local files, body, ask = {}, '', nil
  if scope == 'hunk' then
    local context = M.note_context(nil, api.nvim_win_get_buf(r.right_win))
    if api.nvim_get_current_win() == r.left_win then context = M.note_context(nil, api.nvim_win_get_buf(r.left_win)) end
    if not context then tell('Put the cursor in the comparison first.'); return end
    files, body = { r.files[r.index] }, context.code
    ask = 'Explain this change: what it does, what it affects and anything risky about it. Cite path:line.'
  else
    local list = scope == 'file' and { r.files[r.index] } or r.files
    for _, f in ipairs(list) do
      load_file(r, f, false)
      local text = unified(f)
      if text and #body + #text <= API_LIMIT then body = body .. text .. '\n'; files[#files + 1] = f
      elseif text then body = body .. '[' .. f.rel .. ' left out: over the size for one request]\n' end
    end
    if #files == 0 then tell('Nothing here can be sent as text.'); return end
    ask = 'Review this change (' .. what .. '): likely bugs, risky edits and missing tests. Cite path:line. Only these lines are under review.'
  end
  local sent = {}
  for _, f in ipairs(files) do sent[f.rel] = f.signature end
  local state_path = r.state_file
  -- The text each file had when it was sent: the answer's path:line citations are about THIS version, so it is kept
  -- beside the answer and a citation opens it when the file has moved on.
  local versions = {}
  for _, f in ipairs(files) do if type(f.right) == 'string' and #f.right <= 512 * 1024 then versions[f.rel] = f.right end end
  work.api_question(ask .. '\n\n' .. body, function(task)
    if type(task.id) == 'string' and task.id:match('^[%w_-]+$') then
      for rel, text in pairs(versions) do write_private(M.api_snapshot(task.id, rel), text) end
    end
    local disk = decode(read(state_path))
    disk.api = type(disk.api) == 'table' and disk.api or {}
    for rel, signature in pairs(sent) do disk.api[rel] = { id = task.id, at = os.time(), signature = signature, scope = scope } end
    write_private(state_path, vim.json.encode(disk))
    if M.current == r and api.nvim_buf_is_valid(r.panel_buf) then panel(r) end
  end)
end
function M.api_of(r, file)
  local records = M.state_of(r).api
  local record = type(records) == 'table' and records[file.rel] or nil
  if type(record) ~= 'table' or type(record.id) ~= 'string' then return nil end
  record.current = file.loaded and record.signature == file.signature
  return record
end
function M.api_snapshot(id, rel) return reviews_dir() .. '/api/' .. id .. '/' .. vim.fn.sha256(rel) .. '.txt' end
-- Where a citation of rel:line in answer `id` should open: the working file while it still reads as it was sent,
-- else the kept copy of the version the answer is about.
function M.api_target(root, id, rel)
  local kept = read(M.api_snapshot(id, rel))
  local now = read(root .. '/' .. rel)
  if not kept or kept == now then return { current = true, path = root .. '/' .. rel } end
  return { current = false, text = kept, path = root .. '/' .. rel }
end
function M.api_jump(root, id, rel, lnum)
  local target = M.api_target(root, id, rel)
  if target.current then
    vim.cmd('edit ' .. vim.fn.fnameescape(target.path))
  else
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines(target.text))
    vim.bo[buf].bufhidden, vim.bo[buf].modifiable = 'wipe', false
    pcall(api.nvim_buf_set_name, buf, rel .. ' · as the API reviewed it')
    local kind = vim.filetype.match({ filename = rel })
    if kind then vim.bo[buf].filetype = kind end
    vim.b[buf].foxml_api_snapshot = id
    vim.cmd('sbuffer ' .. buf)
    vim.keymap.set('n', 'q', '<cmd>bwipeout<cr>', { buffer = buf, desc = 'Close the reviewed version' })
    vim.keymap.set('n', 'gf', function() vim.cmd('edit ' .. vim.fn.fnameescape(target.path)) end, { buffer = buf, desc = 'Open the file as it is now' })
    tell(rel .. ' has changed since this review: showing the version it is about. gf opens the file as it is now.')
  end
  pcall(api.nvim_win_set_cursor, 0, { math.max(1, math.min(lnum or 1, api.nvim_buf_line_count(0))), 0 })
end
-- The saved answer, opened here so its citations can lead to the version it reviewed.
function M.api_open()
  local r = M.current
  local record = r and M.api_of(r, r.files[r.index])
  if not record then tell('No API review of this file yet.'); return end
  local ok, shown = pcall(function() return vim.system({ 'claude-api', 'show', record.id }, { text = true }):wait(5000) end)
  if not ok or not shown or shown.code ~= 0 or (shown.stdout or '') == '' then
    pcall(vim.system, { 'claude-api', 'open', record.id }, { detach = true }); return
  end
  local root, id = r.root, record.id
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(shown.stdout, '\n', { plain = true }))
  vim.bo[buf].bufhidden, vim.bo[buf].modifiable, vim.bo[buf].filetype = 'wipe', false, 'markdown'
  pcall(api.nvim_buf_set_name, buf, 'API review · ' .. (r.files[r.index].rel or ''))
  vim.cmd('tab sbuffer ' .. buf)
  vim.wo.wrap = true
  vim.keymap.set('n', 'q', '<cmd>bwipeout<cr>', { buffer = buf, desc = 'Close the API review' })
  vim.keymap.set('n', '<CR>', function()
    for path, lnum in api.nvim_get_current_line():gmatch('([%w%._%-/~]+%.[%w]+):(%d+)') do
      local rel = path:sub(1, #root + 1) == root .. '/' and path:sub(#root + 2) or path
      if read(root .. '/' .. rel) or read(M.api_snapshot(id, rel)) then M.api_jump(root, id, rel, tonumber(lnum)); return end
    end
    tell('No path:line on this line.')
  end, { buffer = buf, desc = 'Open the cited line in the version reviewed' })
  tell(record.current and 'Enter on a path:line opens it.' or 'This file has changed since the review: Enter on a path:line opens the version it is about.')
end

-- Priority and eligibility belong to desk-work; review navigation takes its review-only projection.
function M.next_item(root)
  local backend = M.work_tool()
  if not backend then return nil, 'requires the work tool (desk-work)' end
  local ok, out = pcall(function() return vim.system({ backend, 'attention', '--root', root, '--scope', 'review' }, { text = true }):wait(5000) end)
  if not ok or out.code ~= 0 then return nil, 'Work status is unavailable; refresh and try again.' end
  return decode(out.stdout)[1]
end
function M.open_item(item, root)
  local C = require('desk.claude')
  local rows = C.rows(root)
  if item.kind == 'commit' then
    for _, row in ipairs(rows) do if row.kind == 'commit' and row.sha == item.sha then C.open_review(row, root); M.tree(rows); return end end
    tell('That commit is no longer in this branch.'); return
  end
  for _, row in ipairs(rows) do
    if row.kind == 'working' then
      C.open_review(row, root); M.tree(rows)
      local r = M.current
      for i, f in ipairs(r and r.files or {}) do if f.rel == item.file then M.select(i); tell(item.file .. ': ' .. item.why); return end end
    end
  end
  C.open_review({ kind = 'live', sid = '', name = 'needs you', short = 'needs you', files = { root .. '/' .. item.file }, label = item.why }, root)
end
function M.next()
  local root = (M.current and M.current.root) or vim.fs.root(0, '.git') or vim.fs.root(vim.fn.getcwd(), '.git')
  if not root then tell('Not in a git repository.'); return end
  local item, why = M.next_item(root)
  if not item then tell(why or 'Nothing needs you here right now.'); return end
  M.open_item(item, root)
end

-- Plan coverage: each step of the plan this change was made under, with the commits that touched a file it names;
-- a step with none has "no matching edits", and a changed file no step names is listed as outside the plan. By files, so it
-- is a fact about what changed, not a guess about intent.
local function names_file(name, rel, path)
  name = name:gsub('^~/', ''):gsub('^%./', '')
  return rel == name or rel:sub(-#name - 1) == '/' .. name or name:sub(-#rel - 1) == '/' .. rel or path == name
end
function M.plan_coverage_data(r)
  local plan = r.row.plan
  if not plan or plan == '' then
    local ok, marks = pcall(require, 'desk.planmarks')
    plan = ok and type(marks.plan) == 'table' and marks.plan.file or nil
  end
  -- Working changes carry no plan of their own: they are checked against the plan of the newest commit that has one.
  if not plan or plan == '' then
    for _, set in ipairs(r.sets or {}) do if (set.row.plan or '') ~= '' then plan = set.row.plan end end
  end
  local ok, marks = pcall(require, 'desk.planmarks')
  local text = plan and read(plan)
  if not ok or not text then return nil end
  local steps, at = {}, {}
  -- "step 2" reads better with its own words: "2 · Move the workers onto the new queue".
  local words = {}
  for line in text:gmatch('[^\n]+') do
    local n, rest = line:match('^(%d+)[.)]%s+(.-)%s*$')
    if not n then n, rest = line:match('^%s*%- %[.%]%s+(%d+)[.)]%s+(.-)%s*$') end
    if n and not words['step ' .. n] then words['step ' .. n] = n .. ' · ' .. rest:gsub('`', ''):gsub('%s*:.*$', '') end
  end
  for _, ref in ipairs(marks.parse(text)) do
    if not at[ref.step] then at[ref.step] = #steps + 1; steps[#steps + 1] = { label = words[ref.step] or ref.step, files = {}, commits = {} } end
    local step = steps[at[ref.step]]
    if not vim.tbl_contains(step.files, ref.path) then step.files[#step.files + 1] = ref.path end
  end
  local outside, seen = {}, {}
  local sets = r.sets or { { row = r.row, files = r.files } }
  -- A plan whose steps name no files: go by the step recorded on each commit when it was made ("step 2 · …").
  if #steps == 0 then
    local numbers = {}
    for key, label in pairs(words) do numbers[#numbers + 1] = { n = tonumber(key:match('%d+')), label = label } end
    table.sort(numbers, function(a, b) return a.n < b.n end)
    for _, s in ipairs(numbers) do at[s.n] = #steps + 1; steps[#steps + 1] = { label = s.label, files = {}, commits = {}, recorded = true } end
    for _, set in ipairs(sets) do
      local row = set.row
      if row.kind == 'commit' and row.plan == plan then
        local said = tostring(row.step or '')
        local n = tonumber(said:match('[Ss]tep%s*(%d+)') or said:match('^%s*(%d+)%s*[.)·:]'))
        if not n then
          for _, s in ipairs(numbers) do
            local words_only = s.label:gsub('^%d+ · ', ''):lower()
            if said ~= '' and (words_only:find(said:lower(), 1, true) or said:lower():find(words_only, 1, true)) then n = s.n; break end
          end
        end
        if n and at[n] then table.insert(steps[at[n]].commits, row.short or 'commit')
        else outside[#outside + 1] = { rel = (row.short or 'commit') .. ' ' .. (row.subject or ''), where = said ~= '' and ('recorded as "' .. said .. '"') or 'no step recorded', commit = true } end
      end
    end
    return { plan = plan, title = (text:match('^#%s+([^\n]+)') or vim.fs.basename(plan)), steps = steps, outside = outside, recorded = true }
  end
  for _, set in ipairs(sets) do
    local row = set.row
    local mine = row.kind == 'working' or row.kind == 'live' or row.plan == plan or (not row.plan and r.row == row)
    if mine then
      local files = set.files or M.files(row, r.root) or {}
      local label = row.kind == 'commit' and (row.short or 'commit') or (row.kind == 'working' and 'working changes' or (row.name or 'live'))
      for _, f in ipairs(files) do
        local named = false
        for _, step in ipairs(steps) do
          for _, name in ipairs(step.files) do
            if names_file(name, f.rel, f.path) then
              named = true
              if not vim.tbl_contains(step.commits, label) then step.commits[#step.commits + 1] = label end
              break
            end
          end
        end
        if not named and not seen[f.rel] and f.path ~= plan then seen[f.rel] = true; outside[#outside + 1] = { rel = f.rel, where = label } end
      end
    end
  end
  return { plan = plan, title = (text:match('^#%s+([^\n]+)') or vim.fs.basename(plan)), steps = steps, outside = outside }
end
function M.plan_coverage()
  local r = M.current
  if not r then return end
  local data = M.plan_coverage_data(r)
  if not data then tell('This change was not made under a plan, so there is nothing to check it against.'); return end
  if #data.steps == 0 then tell('The plan has no numbered steps and names no files, so there is nothing to measure against.'); return end
  local items = {}
  for _, step in ipairs(data.steps) do
    local done = #step.commits
    items[#items + 1] = { name = step.label, group = 'steps', right = done > 0 and table.concat(step.commits, ', ')
        or (step.recorded and 'no commit recorded' or 'no matching edits'),
      label = step.recorded
        and (step.label .. (done > 0 and (' — recorded on ' .. table.concat(step.commits, ', ') .. ' when it was committed.') or ' — no commit was recorded under this step. (The plan names no files, so this goes by the step noted at each commit.)'))
        or (step.label .. ' — names ' .. table.concat(step.files, ', ') .. (done > 0 and ('. Touched by ' .. table.concat(step.commits, ', ') .. '.') or '. Nothing has changed a file it names yet.')),
      run = function() vim.cmd('botright vsplit ' .. vim.fn.fnameescape(data.plan)) end }
  end
  for _, file in ipairs(data.outside) do
    items[#items + 1] = { name = file.rel, group = file.commit and 'no step matched' or 'outside the plan', right = file.where,
      label = file.commit and (file.rel .. ' — made under this plan, but ' .. file.where .. ' matches none of its steps.')
        or (file.rel .. ' — changed in ' .. file.where .. ', and no step of the plan names it.'),
      run = function()
        for i, f in ipairs(r.files) do if f.rel == file.rel then M.select(i); return end end
        tell(file.rel .. ' is in ' .. file.where .. '; open that change to read it.')
      end }
  end
  M.show_menu(items, { title = 'Plan coverage · ' .. data.title, memo = 'foxml-plan-coverage', anchor_win = r.right_win })
end

-- Margin notes: the reader's own notes on a line, for themselves ("check this again after the refactor"). Kept per
-- project by path, so they show in every later review of that file; each keeps its line's text, and follows the
-- line when the file shifts around it. Separate from change requests, which go to a session.
local ns_notes = api.nvim_create_namespace('foxml_review_notes')
local function notes_file(root) return reviews_dir() .. '/notes/' .. vim.fn.sha256(root) .. '.json' end
function M.notes(root)
  local all = decode(read(notes_file(root)))
  for rel, list in pairs(all) do if type(list) ~= 'table' or #list == 0 then all[rel] = nil end end
  return all
end
-- Where a note sits now: its own line while that still reads the same, else the nearest line that does.
function M.note_line(note, text_lines)
  local at = tonumber(note.line) or 1
  if (note.context or '') == '' or text_lines[at] == note.context then return math.max(1, math.min(at, math.max(1, #text_lines))), true end
  local best
  for i, line in ipairs(text_lines) do
    if line == note.context and (not best or math.abs(i - at) < math.abs(best - at)) then best = i end
  end
  return best or math.max(1, math.min(at, math.max(1, #text_lines))), best ~= nil
end
-- Empty text removes the note on that line.
function M.note_set(root, rel, line, text, context)
  local all = M.notes(root)
  local kept = {}
  for _, note in ipairs(all[rel] or {}) do if tonumber(note.line) ~= line then kept[#kept + 1] = note end end
  text = vim.trim(tostring(text or ''):gsub('[\r\n\t]', ' ')):sub(1, 300)
  if text ~= '' then kept[#kept + 1] = { line = line, text = text, context = context or '', at = os.time() } end
  table.sort(kept, function(a, b) return a.line < b.line end)
  all[rel] = #kept > 0 and kept or nil
  return write_private(notes_file(root), vim.json.encode(vim.tbl_isempty(all) and vim.empty_dict() or all))
end
draw_notes = function(r)
  local buf, f = r.right_buf, r.files[r.index]
  if not buf or not api.nvim_buf_is_valid(buf) or not f then return end
  api.nvim_buf_clear_namespace(buf, ns_notes, 0, -1)
  r.notes = M.notes(r.root)
  local text_lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, note in ipairs(r.notes[f.rel] or {}) do
    local at, found = M.note_line(note, text_lines)
    pcall(api.nvim_buf_set_extmark, buf, ns_notes, at - 1, 0, { sign_text = '✎', sign_hl_group = hl('FoxSymdepsWarn', 'DiagnosticWarn'),
      virt_text = { { '  ✎ ' .. note.text .. (found and '' or '  (its line is gone)'), hl('FoxSymdepsWarn', 'DiagnosticWarn') } }, virt_text_pos = 'eol' })
  end
end
function M.note_here()
  local r = M.current
  if not r then return end
  local f = r.files[r.index]
  if not f or api.nvim_get_current_buf() ~= r.right_buf then tell('Your notes go on the right side: the file as it is now.'); return end
  local line = api.nvim_win_get_cursor(0)[1]
  local context = api.nvim_buf_get_lines(r.right_buf, line - 1, line, false)[1] or ''
  local existing = ''
  local text_lines = api.nvim_buf_get_lines(r.right_buf, 0, -1, false)
  for _, note in ipairs(M.notes(r.root)[f.rel] or {}) do if M.note_line(note, text_lines) == line then existing = note.text; line = tonumber(note.line) or line end end
  vim.ui.input({ prompt = existing ~= '' and 'Note to self (empty removes it): ' or 'Note to self: ', default = existing }, function(text)
    if text == nil then return end
    if not M.note_set(r.root, f.rel, line, text, context) then tell('The note could not be saved.', vim.log.levels.WARN); return end
    draw_notes(r); panel(r)
  end)
end
-- Every note in the project, by file; Enter goes to its line.
function M.notes_list(root)
  local r = M.current
  root = root or (r and r.root) or vim.fs.root(0, '.git') or vim.fn.getcwd()
  local all, items = M.notes(root), {}
  local files = vim.tbl_keys(all); table.sort(files)
  for _, rel in ipairs(files) do
    for _, note in ipairs(all[rel]) do
      items[#items + 1] = { name = note.text, group = rel, right = 'line ' .. note.line, ident = rel .. ':' .. note.line,
        label = rel .. ':' .. note.line .. ' — ' .. note.text .. ' · written ' .. os.date('%d %b', tonumber(note.at) or 0),
        run = function()
          local now = M.current
          if now and now.root == root then
            for i, f in ipairs(now.files) do
              if f.rel == rel then
                M.select(i)
                local at = M.note_line(note, api.nvim_buf_get_lines(now.right_buf, 0, -1, false))
                api.nvim_set_current_win(now.right_win); api.nvim_win_set_cursor(now.right_win, { at, 0 }); return
              end
            end
            tell(rel .. ' is not part of this change; close the review to open the file itself.'); return
          end
          vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. rel))
          pcall(api.nvim_win_set_cursor, 0, { M.note_line(note, api.nvim_buf_get_lines(0, 0, -1, false)), 0 })
        end }
    end
  end
  if #items == 0 then tell('No notes of yours in this project yet. In a review, N on a line writes one.'); return end
  M.show_menu(items, { title = 'My notes · ' .. #items, memo = 'foxml-review-notes', anchor_win = r and r.right_win or nil })
end

function M.note_context(range, buf)
  local r = M.current
  buf = buf or api.nvim_get_current_buf()
  local meta = vim.b[buf].desk_review
  if not r or not meta then return nil end
  local f, side = r.files[r.index], meta.side
  local first, last = range and range[1] or api.nvim_win_get_cursor(0)[1], range and range[2] or api.nvim_win_get_cursor(0)[1]
  local offset = side == 'before' and 1 or 3
  local hunk
  for _, h in ipairs(f.hunks) do
    if h[offset] <= last and h[offset] + math.max(1, h[offset + 1]) - 1 >= first then hunk = h; break end
  end
  local function excerpt(text, start, count)
    if count == 0 then return '(no lines)' end
    local value = table.concat(vim.list_slice(lines(text), math.max(1, start), math.max(1, start) + count - 1), '\n')
    return #value > 2200 and (value:sub(1, 2200) .. '\n[excerpt truncated]') or value
  end
  local code = 'Comparison: ' .. (r.row.kind == 'commit' and r.row.sha or ('session ' .. (r.row.name or 'working copy')))
    .. '\nSelected ' .. side .. ' lines ' .. first .. '-' .. last .. ':\n' .. excerpt(side == 'before' and f.left or f.right, first, last - first + 1)
  if hunk then code = code .. '\n--- Before (' .. f.old .. ':' .. hunk[1] .. ')\n' .. excerpt(f.left, hunk[1], hunk[2])
    .. '\n+++ After (' .. f.rel .. ':' .. hunk[3] .. ')\n' .. excerpt(f.right, hunk[3], hunk[4]) end
  return { file = f.path, first = first, last = last, code = code }
end

function M.close()
  local r = M.current
  if not r then return true end
  if r.closing then return false end
  r.closing = true
  if r.unsubscribe then r.unsubscribe(); r.unsubscribe = nil end
  -- Remember the place: the next open of this change starts on this file and line.
  pcall(function()
    local f = r.files[r.index]
    if not f or not api.nvim_win_is_valid(r.right_win) then return end
    local disk = decode(read(r.state_file))
    disk.last = { rel = f.rel, line = api.nvim_win_get_cursor(r.right_win)[1] }
    write_private(r.state_file, vim.json.encode(disk))
  end)
  restore_options(r)
  if api.nvim_tabpage_is_valid(r.tab) then
    if #api.nvim_list_tabpages() == 1 then vim.cmd('tabnew') end
    api.nvim_set_current_tabpage(r.tab)
    local ok, err = pcall(vim.cmd, 'tabclose')
    if not ok then
      r.closing = false
      tell(tostring(err):match('E%d+:%s*(.*)') or 'Changes could not close. Save any edited files and try again.', vim.log.levels.WARN)
      options(r); return false
    end
  end
  M.current = nil
  if r.group then api.nvim_del_augroup_by_id(r.group) end
  for _, buf in ipairs(r.buffers) do if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end end
  if api.nvim_win_is_valid(r.origin) then api.nvim_set_current_win(r.origin) end
  if r.on_close then r.on_close() end
  return true
end

function M.open(row, root, callbacks)
  local files, err = M.files(row, root)
  if not files or #files == 0 then tell(err or 'No files to review.', vim.log.levels.WARN); return nil end
  if not M.close() then return nil end
  serial = serial + 1
  local state_path = state_file(root, row)
  local stored = decode(read(state_path))
  local r = { row = row, root = root, files = files, label = row.short, origin = api.nvim_get_current_win(), buffers = {}, id = serial,
    marks = type(stored.files) == 'table' and stored.files or {}, state_file = state_path,
    original_diffopt = vim.o.diffopt, close = callbacks.close, on_close = callbacks.on_close }
  M.current = r
  vim.cmd('tabnew'); r.tab = api.nvim_get_current_tabpage(); r.right_win = api.nvim_get_current_win()
  local empty = api.nvim_get_current_buf()
  vim.bo[empty].buflisted, vim.bo[empty].bufhidden = false, 'wipe'
  vim.cmd('leftabove vsplit'); r.left_win = api.nvim_get_current_win()
  vim.cmd('topleft vsplit'); r.panel_win = api.nvim_get_current_win()
  panel_buffer(r); configure_panel(r)
  r.group = api.nvim_create_augroup('foxml_review_view', { clear = true })
  r.owned = { [r.left_win] = true, [r.right_win] = true, [r.panel_win] = true }
  api.nvim_create_autocmd({ 'WinEnter', 'BufWinEnter' }, { group = r.group, callback = function(event)
    if M.current ~= r or r.closing or api.nvim_get_current_tabpage() ~= r.tab then return end
    local win = api.nvim_get_current_win()
    if event.event == 'WinEnter' and (win == r.left_win or win == r.right_win) then r.last_diff_win = win end
  end })
  api.nvim_create_autocmd('WinLeave', { group = r.group, callback = function()
    if M.current == r and not r.closing and api.nvim_get_current_win() == r.panel_win then remember_panel(r) end
  end })
  api.nvim_create_autocmd('WinClosed', { group = r.group, callback = function(a)
    if not r.closing and tonumber(a.match) == r.panel_win then
      r.owned[r.panel_win] = nil; r.panel_hidden = true
      vim.schedule(function() if M.current == r and not r.closing then M.layout() end end)
      return
    end
    if not r.closing and r.owned[tonumber(a.match)] then
      -- Let :q finish on its original window before closing the remaining review panes.
      vim.schedule(function() if M.current == r and not r.closing then r.close() end end)
    end
  end })
  api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, { group = r.group, callback = function(a)
    if not r.closing and a.buf == r.panel_buf then
      vim.schedule(function() if M.current == r and not r.closing then M.hide_panel() end end)
    elseif not r.closing and (a.buf == r.left_buf or a.buf == r.right_buf) then
      vim.schedule(function() if M.current == r and not r.closing then r.close() end end)
    end
  end })
  api.nvim_create_autocmd('TabLeave', { group = r.group, callback = function() restore_options(r) end })
  api.nvim_create_autocmd({ 'TabEnter', 'FocusGained' }, { group = r.group, callback = function()
    if M.current == r and not r.closing and api.nvim_get_current_tabpage() == r.tab then options(r); M.layout(); M.refresh_live() end
  end })
  api.nvim_create_autocmd('VimResized', { group = r.group, callback = function() if M.current == r then M.layout() end end })
  api.nvim_create_autocmd('TabClosed', { group = r.group, callback = function()
    vim.schedule(function() if M.current == r and not api.nvim_tabpage_is_valid(r.tab) then M.close() end end)
  end })
  M.refresh_requests()
  -- Validate persisted checkmarks against actual content before resuming.
  local first = 1
  for i, f in ipairs(files) do
    load_file(r, f)
    if r.marks[f.rel] ~= f.signature then first = i; break end
  end
  -- Where you left this change, while that file is still part of it and still needs reading; a file you finished
  -- gives way to the first one you have not.
  local last = type(stored.last) == 'table' and stored.last or nil
  local resumed = false
  if last then
    for i, f in ipairs(files) do
      if f.rel == last.rel then
        load_file(r, f)
        if r.marks[f.rel] ~= f.signature then first, resumed = i, true end
        break
      end
    end
  end
  M.layout(); M.select(first)
  r.unsubscribe = require('desk.work_events').subscribe(root, function()
    if M.current == r then M.refresh_live() end
  end)
  if resumed and tonumber(last.line) and api.nvim_win_is_valid(r.right_win) then
    pcall(api.nvim_win_set_cursor, r.right_win, { math.max(1, math.min(tonumber(last.line), api.nvim_buf_line_count(r.right_buf))), 0 })
  end
  -- Yield between files so a large commit does not block navigation while counts arrive.
  local function next_count()
    if M.current ~= r or r.row ~= row then return end
    local started, more = uv.hrtime(), false
    for _, f in ipairs(files) do
      if not f.loaded then
        if uv.hrtime() - started > 12e6 then more = true; break end
        load_file(r, f)
      end
    end
    panel(r)
    if more then vim.defer_fn(next_count, 10) end
  end
  vim.defer_fn(next_count, 10)
  return r
end

return M
