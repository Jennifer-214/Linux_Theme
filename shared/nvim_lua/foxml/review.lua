-- One read-only comparison tab; the original editor and its quickfix list stay intact.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
local ns = api.nvim_create_namespace('foxml_review')
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
    local ok, marks = pcall(require, 'foxml.planmarks')
    path = ok and type(marks.plan) == 'table' and marks.plan.file or nil
  end
  if not path then return nil end
  r.plan_cache = r.plan_cache or {}
  if r.plan_cache[path] == nil then
    local names, any = {}, false
    local ok, marks = pcall(require, 'foxml.planmarks')
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
local function blob(r, revision, rel, absent)
  if absent then return '' end
  return git(r.root, { 'show', revision .. ':' .. rel })
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
        local tree = git(r.root, { 'ls-tree', '-z', 'HEAD', '--', ':(literal)' .. file.rel })
        if tree == '' or (tree == nil and git(r.root, { 'rev-parse', '--verify', 'HEAD' }) == nil) then left = '' end
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
local function save(r, file)
  local disk = decode(read(r.state_file))
  disk.files = type(disk.files) == 'table' and disk.files or {}
  if file then
    disk.files[file.rel] = r.marks[file.rel]
    if r.marks[file.rel] and type(disk.requests) == 'table' then disk.requests[file.rel] = nil end
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
local function panel(r, select_row)
  if not api.nvim_buf_is_valid(r.panel_buf) then return end
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
    local ln = push(spread(left, (risky and '⚠ ' or '') .. stats .. ' ', w))
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
  local keys = external and ' ⏎ open · a actions · q close' or (w >= 44 and ' ⏎ open · m check · a actions · q close' or ' ⏎ open · m check · a more')
  r.footer_line = push(fit(keys, w)); paint(r.footer_line, 0, -1, hl('FoxSymdepsDim', 'Comment'))
  vim.bo[r.panel_buf].modifiable = true
  api.nvim_buf_set_lines(r.panel_buf, 0, -1, false, text)
  vim.bo[r.panel_buf].modifiable = false
  api.nvim_buf_clear_namespace(r.panel_buf, ns, 0, -1)
  for _, m in ipairs(marks_hl) do
    pcall(api.nvim_buf_set_extmark, r.panel_buf, ns, m[1] - 1, math.max(0, m[2]), { end_row = m[1] - 1, end_col = m[3] < 0 and #text[m[1]] or math.min(m[3], #text[m[1]]), hl_group = m[4] })
  end
  if selected_line then api.nvim_buf_set_extmark(r.panel_buf, ns, selected_line - 1, 0, { line_hl_group = hl('FoxSymdepsSelection', 'Visual') }) end
  if select_row and api.nvim_win_is_valid(r.panel_win) and selected_line then api.nvim_win_set_cursor(r.panel_win, { selected_line, 0 }) end
  local footer = ' ]f/[f file · ]c/[c change · m check · u unread · R finish · ? help · q close '
  for _, win in ipairs({ r.left_win, r.right_win }) do
    if api.nvim_win_is_valid(win) then vim.wo[win].statusline = '%#StatusLine#' .. footer end
  end
end

local function scratch(r, file, side, text)
  local buf = api.nvim_create_buf(false, true)
  r.buffers[#r.buffers + 1] = buf
  local name = 'review://' .. r.id .. '/' .. r.generation .. '/' .. side .. '/' .. file.rel
  api.nvim_buf_set_name(buf, name)
  vim.b[buf].foxml_review = { file = file.path, side = side }
  vim.b[buf].foxml_review_root = r.root
  api.nvim_buf_set_lines(buf, 0, -1, false, lines(text))
  vim.bo[buf].modifiable, vim.bo[buf].readonly, vim.bo[buf].bufhidden = false, true, 'hide'
  local ft = vim.filetype.match({ filename = file.rel })
  if ft and not file.error and not file.binary then vim.bo[buf].filetype = ft end
  return buf
end

local function maps(r, buf, sidebar)
  local function key(lhs, fn, desc) vim.keymap.set('n', lhs, fn, { buffer = buf, desc = desc, silent = true }) end
  key('q', r.close, 'Close review'); key('<Esc>', r.close, 'Close review')
  key(']f', function() M.select(r.index % #r.files + 1) end, 'Next review file')
  key('[f', function() M.select((r.index - 2) % #r.files + 1) end, 'Previous review file')
  key('<Tab>', function() M.select(r.index % #r.files + 1) end, 'Next review file')
  key('<S-Tab>', function() M.select((r.index - 2) % #r.files + 1) end, 'Previous review file')
  key('m', function() M.mark() end, 'Mark/unmark file reviewed')
  key('u', function() M.unread() end, 'First unread review file')
  key('R', function() M.finish_next() end, 'Finish review and open next commit')
  key('<leader>rw', function() r.whitespace = not r.whitespace; options(r); tell('Whitespace changes: ' .. (r.whitespace and 'hidden' or 'shown')) end, 'Toggle review whitespace')
  key('<leader>rc', function() r.context = not r.context; options(r); tell('Context: ' .. (r.context and 'full file' or 'six lines')) end, 'Toggle review context')
  key('r', function() M.select(r.index, true) end, 'Refresh this comparison')
  key('A', function() M.api_open() end, 'Open the API review of this file')
  key('c', function() if not sidebar or M.enter(true) then api.nvim_set_current_win(r.right_win); require('foxml.claude').send() end end, 'Request changes from a Claude session')
  if not sidebar then key('<leader>rn', M.toggle_since, 'New since review / the whole change') end
  key('?', M.actions, 'Review actions')
  key('<leader>e', function() api.nvim_set_current_win(r.panel_win) end, 'Review file list')
  key('s', function() M.symdeps(false) end, 'Inspect changed C++ symbol in working copy')
  key('S', function() M.symdeps(true) end, 'Compare struct layout with review base')
  key('gf', function() M.open_source() end, 'Open the working file for this change')
  key('<leader>bd', r.close, 'Close Changes')
  if sidebar then
    key('<CR>', M.enter, 'Expand commit / open review file')
    key('l', M.enter, 'Expand commit / open review file')
    key('<2-LeftMouse>', M.enter, 'Expand commit / open review file')
    key('h', M.fold, 'Collapse review commit')
    key('a', M.actions, 'Review actions')
    key('n', M.toggle_since, 'New since review / the whole change')
    key('<Space>', function() if M.enter(true) then M.mark() end end, 'Mark selected file reviewed')
    key('<LeftMouse>', function()
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
    end, 'Click commit, file or review checkbox')
    key('m', function() if M.enter(true) then M.mark() end end, 'Mark selected file reviewed')
    key('f', function()
      local entry = r.entries and r.entries[api.nvim_win_get_cursor(0)[1]]
      local row = entry and entry.set.row or r.row
      if row.kind == 'live' then require('foxml.claude').follow(row) end
    end, 'Follow selected live session')
  else
    key(']c', function() vim.cmd('normal! ]c') end, 'Next review change')
    key('[c', function() vim.cmd('normal! [c') end, 'Previous review change')
  end
end

function M.select(index, refresh)
  local r = M.current
  if not r or not r.files[index] then return end
  if not api.nvim_tabpage_is_valid(r.tab) or not api.nvim_win_is_valid(r.left_win) or not api.nvim_win_is_valid(r.right_win) then
    tell('The comparison was closed; reopen What changed.'); return
  end
  api.nvim_set_current_tabpage(r.tab)
  r.generation = (r.generation or 0) + 1
  r.index = index
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
    maps(r, buf, false)
  end
  for _, buf in ipairs(old) do if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end end
  options(r); panel(r, true)
  api.nvim_set_current_win(r.left_win)
  local h = file.hunks[1]
  if h then
    api.nvim_win_set_cursor(r.left_win, { math.max(1, math.min(h[1], api.nvim_buf_line_count(r.left_buf))), 0 })
    api.nvim_win_set_cursor(r.right_win, { math.max(1, math.min(h[3], api.nvim_buf_line_count(r.right_buf))), 0 })
  end
  vim.cmd('diffupdate')
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
  for _, f in ipairs(r.files) do load_file(r, f, r.row.kind ~= 'commit') end
  -- What needs the most care comes first: an unread file with a risk mark, then the rest in order.
  for pass = 1, 2 do
    for i, f in ipairs(r.files) do
      local risky = f.risks and #f.risks > 0
      local request = M.request_of(r, f)
      local waiting = request and not request.ready       -- still with the session: nothing to read yet
      if r.marks[f.rel] ~= f.signature and ((pass == 1 and (risky or (request and request.ready))) or (pass == 2 and not waiting)) then M.select(i); return end
    end
  end
  panel(r); tell('Every file is checked. R finishes the review.')
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
    if out.code ~= 0 or decode(out.stdout).ok ~= true then tell('Could not record this review; it remains pending.', vim.log.levels.ERROR); return false end
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
  if not r then return false end
  local line = api.nvim_win_get_cursor(r.panel_win)[1]
  if line == 3 then if not marking then M.actions() end; return false end
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
  local i = line - 3
  if r.files[i] then M.select(i); return true end
  return false
end

function M.primary()
  local r = M.current
  if not r then return end
  if r.row.kind == 'external' then
    require('foxml.claude').close(); require('foxml.sync').merge(); return
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
    local found, fallback = pcall(require, 'foxml.menu')
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
      function() require('foxml.claude').close(); require('foxml.sync').keep() end, { group = 'review' })
  else
    add('Check & next', 'Mark this file reviewed and open the next unread file.', M.primary, { group = 'review' })
    add('File reviewed', 'Toggle this file’s review checkmark. Your place is saved.', M.mark, { group = 'review', bind = 'm', stays = true,
      state = function() local f = r.files[r.index]; return r.marks[f.rel] == f.signature end })
    add('Finish & next commit', 'Finish this review and open the next unchecked commit in this list.', M.finish_next,
      { group = 'review', bind = 'R', right = progress(r) .. '/' .. #r.files .. ' checked' })
    add('First unread file', 'Return to the first file you have not checked in this change.', M.unread, { group = 'review', bind = 'u' })
    add('Request changes', 'Write a note about this file (or the selected lines) to a Claude session. The file then waits on it and reads ready for re-review once it changes.',
      function() api.nvim_set_current_win(r.right_win); require('foxml.claude').send() end, { group = 'review', bind = 'c' })
    add('Only what is new', 'A file edited after you checked it opens against the copy you reviewed. Off shows the whole change. Remembered.',
      M.toggle_since, { group = 'review', bind = 'n', state = function() return M.since_mode() end, stays = true })
  end
  local file = r.files[r.index]
  local ft = vim.filetype.match({ filename = file.path })
  if r.row.kind ~= 'external' then
    -- API review spends credits: it needs the API setup, and says so when that is missing.
    local found, work = pcall(require, 'foxml.work')
    local ready = found and type(work.api_available) == 'function' and work.api_available()
    local needs = (not ready) and 'needs API' or nil
    add('API review: file', 'Requires the API setup (a key and a budget). Send exactly this file’s displayed change for review on API credits. You choose the model and a budget first.',
      function() M.api_review('file') end, { group = 'api', right = needs })
    add('API review: change', 'Requires the API setup (a key and a budget). Send every file of this change (as far as one request holds) for review on API credits.',
      function() M.api_review('commit') end, { group = 'api', right = needs })
    add('Explain this hunk', 'Requires the API setup (a key and a budget). Ask what the change under the cursor does and what it affects, on API credits.',
      function() M.api_review('hunk') end, { group = 'api', right = needs })
    if M.api_of(r, file) then
      add('Open API review', 'Open the saved API review of this file; its path:line citations become a jump list.', M.api_open, { group = 'api', bind = 'A' })
    end
  end
  if vim.fn.filereadable(file.path) == 1 or vim.fn.bufnr(file.path) >= 0 then
    add('Open working file', 'Open the editable working file at this change; keep the review available in its own tab.',
      function() api.nvim_set_current_win(r.right_win); M.open_source() end, { group = 'inspect', bind = 'gf' })
  end
  if ft == 'cpp' or ft == 'c' then
    -- Symbol context is symdeps' job. Without it the rows stay, saying what they need (docs/ui-style.md).
    local has = pcall(require, 'fox-symdeps')
    local needs = (not has) and 'requires symdeps' or nil
    add('Inspect symbol', has and 'Open the current working C++ file near this change and inspect it in symdeps.'
        or 'Callers, uses and layout of the symbol at this change. Requires symdeps, an optional plugin.',
      function() api.nvim_set_current_win(r.right_win); M.symdeps(false) end, { group = 'inspect', bind = 's', right = needs })
    if r.row.kind == 'commit' then
      add('Compare struct layout', has and 'Compare the current struct with this commit’s base, using the current project headers.'
          or 'The struct’s layout before and after this commit. Requires symdeps, an optional plugin.',
        function() api.nvim_set_current_win(r.right_win); M.symdeps(true) end, { group = 'inspect', bind = 'S', right = needs })
    end
  end
  add('Ignore whitespace', 'Hide whitespace-only differences while reviewing this change.',
    function() r.whitespace = not r.whitespace; options(r) end,
    { group = 'comparison', bind = '<leader>rw', stays = true, state = function() return r.whitespace == true end })
  add('Full-file context', 'Show the entire file instead of six context lines around each changed block.',
    function() r.context = not r.context; options(r) end,
    { group = 'comparison', bind = '<leader>rc', stays = true, state = function() return r.context == true end })
  add('Refresh comparison', 'Read the snapshots again; live reviews capture the current working copy.',
    function() M.select(r.index, true) end, { group = 'comparison', bind = 'r' })
  add('Return to editor', 'Close Changes and return to your original editor and unsaved work.', r.close, { group = 'comparison', bind = 'q' })
  M.show_menu(actions, { title = 'Changes', anchor_win = r.panel_win, memo = 'foxml-review-actions' })
end

function M.layout()
  local r = M.current
  if not r or not api.nvim_tabpage_is_valid(r.tab) or api.nvim_get_current_tabpage() ~= r.tab then return end
  for _, win in ipairs({r.panel_win, r.left_win, r.right_win}) do if not api.nvim_win_is_valid(win) then return end end
  local width = math.min(52, math.max(30, math.floor(vim.o.columns * .30)))
  api.nvim_win_set_width(r.panel_win, width)
  panel(r)
  local available = vim.o.columns - width - 2
  api.nvim_win_set_width(r.left_win, math.max(1, math.floor(available / 2)))
end

function M.fold()
  local r = M.current
  if not r then return end
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
  panel(r, true)
  api.nvim_set_current_win(r.panel_win)
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
  if not M.open_source() then return end
  local loaded, plugin = pcall(require, 'fox-symdeps')
  if not loaded then tell('Requires symdeps (an optional plugin for C and C++ symbols).'); return end
  if compare and r.row.kind == 'commit' then
    local available, rev = pcall(require, 'fox-symdeps.revcompare')
    local found, context = pcall(require, 'fox-symdeps.context')
    local ctx = found and type(context.under_cursor) == 'function' and context.under_cursor() or nil
    if available and ctx then rev.open(ctx, r.row.parent)
    elseif available then tell('Put the cursor on a struct to compare its layout with the commit.')
    else tell('This symdeps version does not expose revision comparison.') end
  else
    tell('Symdeps · current working copy near the reviewed line')
    plugin.inspect_cursor()
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
  r.completed = false
  panel(r)
  return true
end
function M.request_of(r, file)
  local requests = decode(read(r.state_file)).requests
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
  local ok, work = pcall(require, 'foxml.work')
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
  work.api_question(ask .. '\n\n' .. body, function(task)
    local disk = decode(read(state_path))
    disk.api = type(disk.api) == 'table' and disk.api or {}
    for rel, signature in pairs(sent) do disk.api[rel] = { id = task.id, at = os.time(), signature = signature, scope = scope } end
    write_private(state_path, vim.json.encode(disk))
    if M.current == r and api.nvim_buf_is_valid(r.panel_buf) then panel(r) end
  end)
end
function M.api_of(r, file)
  local records = decode(read(r.state_file)).api
  local record = type(records) == 'table' and records[file.rel] or nil
  if type(record) ~= 'table' or type(record.id) ~= 'string' then return nil end
  record.current = file.loaded and record.signature == file.signature
  return record
end
function M.api_open()
  local r = M.current
  local record = r and M.api_of(r, r.files[r.index])
  if not record then tell('No API review of this file yet.'); return end
  pcall(vim.system, { 'claude-api', 'open', record.id }, { detach = true })
end

function M.note_context(range, buf)
  local r = M.current
  buf = buf or api.nvim_get_current_buf()
  local meta = vim.b[buf].foxml_review
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
  r.panel_buf = api.nvim_create_buf(false, true); r.buffers[#r.buffers + 1] = r.panel_buf
  vim.b[r.panel_buf].foxml_review_panel = true
  api.nvim_win_set_buf(r.panel_win, r.panel_buf)
  vim.bo[r.panel_buf].filetype, vim.bo[r.panel_buf].bufhidden = 'foxml-review', 'hide'
  vim.wo[r.panel_win].number, vim.wo[r.panel_win].relativenumber = false, false
  vim.wo[r.panel_win].signcolumn, vim.wo[r.panel_win].wrap = 'no', false
  vim.wo[r.panel_win].winfixwidth = true
  api.nvim_win_set_width(r.panel_win, math.min(52, math.max(30, math.floor(vim.o.columns * .30))))
  -- The panel carries its own title line, strip and footer; no winbar, a quiet statusline, no cursor column noise.
  vim.wo[r.panel_win].winbar = ''
  vim.wo[r.panel_win].statusline = ' '
  vim.wo[r.panel_win].cursorline, vim.wo[r.panel_win].list, vim.wo[r.panel_win].foldcolumn = false, false, '0'
  -- The strip follows the cursor: redraw only when the row under it changes.
  api.nvim_create_autocmd('CursorMoved', { buffer = r.panel_buf, callback = function()
    if M.current ~= r or not api.nvim_win_is_valid(r.panel_win) then return end
    local line = api.nvim_win_get_cursor(r.panel_win)[1]
    if line ~= r.strip_for then r.strip_for = line; panel(r) end
  end })
  maps(r, r.panel_buf, true)
  r.group = api.nvim_create_augroup('foxml_review_view', { clear = true })
  r.owned = { [r.left_win] = true, [r.right_win] = true, [r.panel_win] = true }
  api.nvim_create_autocmd({ 'WinEnter', 'BufWinEnter' }, { group = r.group, callback = function()
    if M.current ~= r or r.closing or api.nvim_get_current_tabpage() ~= r.tab then return end
    local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    if api.nvim_win_get_config(win).relative == '' and (vim.b[buf].foxml_review or vim.b[buf].foxml_review_panel) then r.owned[win] = true end
  end })
  api.nvim_create_autocmd('WinClosed', { group = r.group, callback = function(a)
    if not r.closing and r.owned[tonumber(a.match)] then
      -- Let :q finish on its original window before closing the remaining review panes.
      vim.schedule(function() if M.current == r and not r.closing then r.close() end end)
    end
  end })
  api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, { group = r.group, callback = function(a)
    if not r.closing and (a.buf == r.panel_buf or a.buf == r.left_buf or a.buf == r.right_buf) then
      vim.schedule(function() if M.current == r and not r.closing then r.close() end end)
    end
  end })
  api.nvim_create_autocmd('TabLeave', { group = r.group, callback = function() restore_options(r) end })
  api.nvim_create_autocmd('TabEnter', { group = r.group, callback = function() if M.current == r and not r.closing then options(r); M.layout() end end })
  api.nvim_create_autocmd('VimResized', { group = r.group, callback = function() if M.current == r then M.layout() end end })
  api.nvim_create_autocmd('TabClosed', { group = r.group, callback = function()
    vim.schedule(function() if M.current == r and not api.nvim_tabpage_is_valid(r.tab) then M.close() end end)
  end })
  -- Validate persisted checkmarks against actual content before resuming.
  local first = 1
  for i, f in ipairs(files) do
    load_file(r, f)
    if r.marks[f.rel] ~= f.signature then first = i; break end
  end
  M.layout(); M.select(first)
  -- Yield between files so a large commit does not block navigation while counts arrive.
  local function next_count()
    if M.current ~= r or r.row ~= row then return end
    for _, f in ipairs(files) do
      if not f.loaded then load_file(r, f); panel(r); vim.defer_fn(next_count, 10); return end
    end
  end
  vim.defer_fn(next_count, 10)
  return r
end

return M
