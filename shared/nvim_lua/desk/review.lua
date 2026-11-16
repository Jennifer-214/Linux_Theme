-- One read-only comparison tab; the original editor and its quickfix list stay intact.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
local actions = require('desk.actions')
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
-- A private folder and its parents. Another program making one of them at the same moment (desk-work's watcher, as a
-- review opens on a fresh state folder) makes Neovim's mkdir() fail with "file already exists": it is made again.
local function make_dir(dir)
  for _ = 1, 3 do
    if vim.fn.isdirectory(dir) == 1 then return true end
    pcall(vim.fn.mkdir, dir, 'p', tonumber('700', 8))
  end
  return vim.fn.isdirectory(dir) == 1
end
local function write_private(path, data)
  if not make_dir(vim.fs.dirname(path)) then return false end
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

local STATUS = { 'status', '--porcelain=v1', '-z', '--untracked-files=all' }
-- data: git status output already read (a background refresh reads it without waiting).
function M.working_files(root, data)
  data = data or git(root, STATUS)
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
local function set_head(r, head)
  if head ~= r.head then r.blobs = {} end
  r.head, r.head_at = head, (vim.uv or vim.loop).now()
end
local function head_of(r)
  local now = (vim.uv or vim.loop).now()
  if not r.head_at or now - r.head_at > 500 then set_head(r, vim.trim(git(r.root, { 'rev-parse', '--verify', '-q', 'HEAD' }) or '')) end
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
-- What a working or live file was read from: its size and modification time on disk, an unsaved draft's change count,
-- the commit its before side came from. A refresh skips a file whose stamp is unchanged (every work event and focus
-- used to re-read and re-diff every loaded file). A file modified in the last second gets no stamp: a second write
-- within the clock's resolution could leave the same time and size behind.
local function stamp_of(r, file)
  if r.row.snapshots or r.row.kind == 'commit' then return nil end
  local stat = uv.fs_stat(file.path)
  if stat and stat.mtime.sec >= os.time() - 1 then return nil end
  local buf = vim.fn.bufnr(file.path)
  local draft = buf >= 0 and api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and api.nvim_buf_get_changedtick(buf) or 0
  local head = (r.row.before or {})[file.path] and '' or (head_of(r) or '')
  if not stat then return table.concat({ 'absent', draft, head, file.old or '' }, ':') end
  return table.concat({ stat.mtime.sec, stat.mtime.nsec, stat.size, stat.ino, draft, head, file.old or '' }, ':')
end
local function load_file(r, file, refresh)
  if file.loaded and not refresh then return end
  local stamp = stamp_of(r, file)
  if file.loaded and refresh ~= 'force' and stamp and stamp == file.stamp and not file.error then return end
  file.stamp = stamp
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
M.unit_types = unit_types

-- The unit (function, method, class) a node is inside, and the node that names it. The call graph shares this.
function M.unit_of(node)
  while node and not unit_types[node:type()] do node = node:parent() end
  if not node then return nil end
  local name = node:field('name')[1] or node:field('declarator')[1]
  while name and name:field('declarator')[1] do name = name:field('declarator')[1] end
  return node, name
end

-- A file's type: by its name, else by its first lines (a script with no extension is told by its #! line).
local function filetype_of(rel, text)
  local head = {}
  for line in ((text or ''):sub(1, 16384) .. '\n'):gmatch('([^\n]*)\n') do
    head[#head + 1] = line
    if #head >= 50 then break end
  end
  return vim.filetype.match({ filename = rel, contents = head })
end

-- What a unit is called in the review's rows: its name as written, else its first line (src: the text, or a buffer).
local function label_of(node, name, src)
  local label = name and vim.treesitter.get_node_text(name, src) or vim.treesitter.get_node_text(node, src):match('[^\n]+')
  return vim.trim((label or node:type()):gsub('%s+', ' ')):sub(1, 72)
end

function M.changed_symbols(file)
  if file.symbols then return file.symbols end
  local result, seen, roots = {}, {}, {}
  local ft = filetype_of(file.rel, (file.right or '') ~= '' and file.right or file.left)
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
      local node, name = M.unit_of(root:named_descendant_for_range(row, 0, row, 0))
      if node then
        found = true
        local label = label_of(node, name, text)
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
  -- The trees it read go to M.structure (when it asks first), which reads each copy once.
  return result, roots
end

-- ─── structure: the calls a change adds and removes, and who calls what it changed ──────────────────────────────
-- Each changed function's calls before and after, compared by name ("+memcpy" in Engine::step): read with treesitter
-- from the two copies the review already holds, in any language with a parser, for any commit, a session's edits
-- (a Claude turn's) or working changes. By name: overloads, macros and virtual dispatch are not told apart. A file
-- whose change does that reaches further than its lines: its row is marked →, and its functions' strips say which
-- calls, with who calls them (M.reach). Read in the background, a file at a time, the one shown first.
-- What names a call in each language (desk.map's syntax reader reads them the same way).
local CALLS = { call_expression = 'function', function_call = 'name', call = 'function', command = 'name', method_invocation = 'name' }
-- The callee as written (M.new, self.helper, q.push), or nil for a call through an expression (a pointer, a call's
-- result, "$cmd"), which names nothing.
local function callee(node, src)
  if not node then return nil end
  local full = vim.trim((vim.treesitter.get_node_text(node, src):gsub('%s+', ' ')))
  if full == '' or #full > 160 then return nil end
  local inner = node
  for _ = 1, 8 do
    local nested = inner:field('name')[1] or inner:field('field')[1] or inner:field('attribute')[1] or inner:field('method')[1]
      or inner:field('property')[1]
    if not nested then break end
    inner = nested
  end
  if not vim.treesitter.get_node_text(inner, src):match('^[%a_~][%w_]*$') then return nil end
  return (full:gsub('%->', '.'))
end
-- The calls under a node, in reading order, each name once; and the same as a set.
local function calls_in(node, src)
  local out, seen, stack = {}, {}, { node }
  while #stack > 0 do
    local n = table.remove(stack)
    local field = CALLS[n:type()]
    if field then
      local name = callee(n:field(field)[1], src)
      if name and not seen[name] then seen[name], out[#out + 1] = true, name end
    end
    local children = {}
    for child in n:iter_children() do if child:named() then children[#children + 1] = child end end
    for i = #children, 1, -1 do stack[#stack + 1] = children[i] end
  end
  return out, seen
end
-- Every unit of a tree by the name changed_symbols gives it (the first, when a name repeats).
local function units_by_label(root, src)
  local out, stack = {}, { root }
  while #stack > 0 do
    local node = table.remove(stack)
    if unit_types[node:type()] then
      local _, name = M.unit_of(node)
      local label = label_of(node, name, src)
      out[label] = out[label] or node
    end
    for child in node:iter_children() do if child:named() then stack[#stack + 1] = child end end
  end
  return out
end
-- file.structure, read once per version of the file (its signature): calls = { [function] = { added, removed } },
-- changed = the functions whose calls changed, why = what is missing when nothing could be read. A copy over
-- M.STRUCTURE_MAX is not read: one parse of it would hold the editor up, even in the background.
M.STRUCTURE_MAX = 512 * 1024
function M.structure(file)
  if file.structure and file.structure.signature == file.signature then return file.structure end
  local s = { signature = file.signature, calls = {}, changed = {} }
  file.structure = s
  if not file.loaded or file.error or file.binary then return s end
  if #file.left > M.STRUCTURE_MAX or #file.right > M.STRUCTURE_MAX then
    s.why = 'calls: not read, the file is over ' .. math.floor(M.STRUCTURE_MAX / 1024) .. ' KiB'
    return s
  end
  local ft = filetype_of(file.rel, file.right ~= '' and file.right or file.left)
  local lang = ft and vim.treesitter.language.get_lang(ft)
  local found, added = false, false
  if lang then found, added = pcall(vim.treesitter.language.add, lang) end
  if not (found and added) then
    s.why = 'calls: requires a treesitter parser for ' .. (ft or file.rel:match('%.([^./]+)$') or 'this file')
    return s
  end
  -- The trees changed_symbols just read, when it read them now (false: that copy did not parse); else each is read here.
  local symbols, roots = M.changed_symbols(file)
  local units = {}
  for side, text in pairs({ before = file.left, after = file.right }) do
    local root = roots and roots[side]
    if root == nil then
      local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
      local parsed, trees = false, nil
      if ok and parser then parsed, trees = pcall(parser.parse, parser) end
      root = parsed and trees and trees[1] and trees[1]:root() or false
    end
    units[side] = root and units_by_label(root, text) or {}
  end
  for _, symbol in ipairs(symbols) do
    if symbol.kind ~= 'hunk' then
      local was, had, now, has = {}, {}, {}, {}
      if units.before[symbol.name] then was, had = calls_in(units.before[symbol.name], file.left) end
      if units.after[symbol.name] then now, has = calls_in(units.after[symbol.name], file.right) end
      local c = { added = vim.tbl_filter(function(n) return not had[n] end, now), removed = vim.tbl_filter(function(n) return not has[n] end, was) }
      s.calls[symbol.name] = c
      if #c.added + #c.removed > 0 then s.changed[#s.changed + 1] = symbol.name end
    end
  end
  return s
end
-- The same check for a file outside a review (a turn's receipt in the notebook): its calls per changed function.
function M.call_changes(rel, before, after)
  local diff = vim.text and vim.text.diff or vim.diff
  local ok, hunks = pcall(diff, before, after, { result_type = 'indices', algorithm = 'histogram', linematch = 60 })
  local s = M.structure({ rel = rel, left = before, right = after, hunks = ok and hunks or {}, loaded = true,
    signature = vim.fn.sha256(before .. '\0' .. after) })
  return s.calls, s.why
end
local function structure_of(f) local s = f and f.structure; return s and s.signature == f.signature and s or nil end

-- Who calls a changed function, from what already knows without being started for it: the language server attached
-- to the working file's buffer; else the project map, when one is built (by name); else what would. Asked in the
-- background, one function at a time, kept per function until its buffer changes (a server's answer) or for ten
-- minutes (the map's); "requires …" is asked again after half a minute.
local reach = {}   -- path NUL name → { said, source, buf, tick, at, pending }
M.reach_known = reach
local function reach_key(f, s) return f.path .. '\0' .. s.name end
local function reach_said(f, s)
  if s.side == 'before' then return 'removed by this change' end
  local got = f and reach[reach_key(f, s)]
  if not got or got.pending then return 'callers…' end
  return got.said
end
local function calls_said(f, s)
  local st = structure_of(f)
  if not st then return 'calls: reading…' end
  local c = st.calls[s.name]
  if not c then return st.why or 'calls: not read' end
  local parts = {}
  for _, n in ipairs(c.added) do parts[#parts + 1] = '+' .. n end
  for _, n in ipairs(c.removed) do parts[#parts + 1] = '−' .. n end
  if #parts == 0 then return 'no call added or removed (by name)' end
  return 'calls by name: ' .. table.concat(parts, ' ')
end

local function progress(r)
  local count = 0
  for _, f in ipairs(r.files) do if f.loaded and r.marks[f.rel] == f.signature then count = count + 1 end end
  return count
end
-- The shared store (desk-work): the notebook and the drawer read the same progress. Best effort and never waited on;
-- a file on disk also sends its content hash, so a later edit shows there as "changed since review".
local sharing = 0
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
  -- This write comes back as a work event a moment later; refresh_live takes that one as an echo.
  r.shared_at = uv.now()
  sharing = sharing + 1
  local ok = pcall(vim.system, argv, { text = true }, function() sharing = sharing - 1 end)
  if not ok then sharing = sharing - 1 end
end
-- Marks still on their way to desk-work. Leaving Neovim waits a moment for them: the last file checked before :q
-- would otherwise never count, and the notebook would keep the commit on its list.
function M.sharing() return sharing end
api.nvim_create_autocmd('VimLeavePre', { group = api.nvim_create_augroup('desk_review_share', { clear = true }), callback = function()
  if sharing > 0 then vim.wait(2000, function() return sharing == 0 end, 10) end
end })
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
  make_dir(vim.fs.dirname(r.state_file))
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
  -- A theme can draw the old side as removed and the new side as added; by default both sides look as plain diff mode.
  api.nvim_set_hl(0, 'FoxReviewOldLine', { link = 'DiffChange', default = true })
  api.nvim_set_hl(0, 'FoxReviewOldWord', { link = 'DiffText', default = true })
  api.nvim_set_hl(0, 'FoxReviewOldAdd', { link = 'DiffTextAdd', default = true })
  api.nvim_set_hl(0, 'FoxReviewNewLine', { link = 'DiffChange', default = true })
  api.nvim_set_hl(0, 'FoxReviewNewWord', { link = 'DiffText', default = true })
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
-- What a file row is and where it stands: the reason that matters most on the second line.
local function describe_file(r, set, f)
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
-- A file row's second line, with the functions whose calls its change adds or removes (its → mark's reason).
local function with_calls(lines, f)
  local st = structure_of(f)
  if st and #st.changed > 0 then lines[2] = (lines[2] or '') .. ' · → calls changed in ' .. table.concat(st.changed, ', ') end
  return lines
end
local function describe(r, entry)
  if not entry then return { 'Pick a change to read it side by side.' } end
  local set = entry.set
  local files = set and set.files or r.files
  if entry.symbol then
    local s, f = entry.symbol, files[entry.file]
    if s.kind == 'hunk' then
      local st = structure_of(f)
      return { s.name, st and st.why or 'Enter jumps to it in the comparison.' }
    end
    return { s.name .. ' · ' .. reach_said(f, s), calls_said(f, s) }
  end
  if entry.file and files[entry.file] then return with_calls(describe_file(r, set, files[entry.file]), files[entry.file]) end
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
    if lhs then keys[#keys + 1] = lhs == '<CR>' and '⏎' or lhs == '<BS>' and 'BS' or (lhs:gsub('^<leader>', 'Space ')) end
  end
  return table.concat(keys, '/') .. ' ' .. word
end
-- The comparison panes' footer. With the file list hidden it leads with the way back to it, which nothing else shows;
-- with the list in the pop-out, with where it is and the way back here.
local function set_footer(r)
  local hidden = not api.nvim_win_is_valid(r.panel_win or -1)
  local parts = { hint('file', 'next-file', 'previous-file'), hint('change', 'next-change', 'previous-change'),
    hint('check', 'mark'), hint('unread', 'unread'), hint('finish', 'finish'), (actions.key('desk.keys') or '?') .. ' keys', hint('close', 'close') }
  if r.popout then table.insert(parts, 1, 'list on the pop-out · ' .. hint('back here', 'list-back', 'file-list'))
  elseif hidden then table.insert(parts, 1, hint('file list', 'list-back', 'file-list')) end
  -- Every file of a commit checked: say so first, with the one key that stamps it as reviewed.
  if r.row.kind == 'commit' and #r.files > 0 and progress(r) == #r.files and not r.completed then
    table.insert(parts, 1, 'all checked · ' .. hint('stamps it', 'finish'))
  end
  local footer = ' ' .. table.concat(parts, ' · ') .. ' '
  for _, win in ipairs({ r.left_win, r.right_win }) do
    if api.nvim_win_is_valid(win or -1) then vim.wo[win].statusline = '%#StatusLine#' .. footer end
  end
end
-- The description strip and the bar are all that change when only the cursor moves; they live in their own namespace,
-- so moving the cursor rewrites two lines instead of rebuilding every row (a long review lagged on each j/k).
local ns_cursor = api.nvim_create_namespace('desk_review_cursor')
-- What a row says in the strip: its two lines, boxed for width w.
-- The strip's box: the theme's float border (vim.g.desk_border; retro's is the DOS box, in double lines), else rounded.
local function strip_box()
  local b = vim.g.desk_border
  local function ch(x) return type(x) == 'table' and tostring(x[1] or '') or tostring(x or '') end
  if type(b) == 'table' and #b == 8 then
    return { tl = ch(b[1]), top = ch(b[2]), tr = ch(b[3]), right = ch(b[4]), br = ch(b[5]), bottom = ch(b[6]), bl = ch(b[7]), left = ch(b[8]) }
  end
  return { tl = '╭', top = '─', tr = '╮', right = '│', br = '╯', bottom = '─', bl = '╰', left = '│' }
end
local function strip_of(r, entry, w)
  local about, box = describe(r, entry), strip_box()
  local lines = {}
  for i = 1, 2 do
    local s = fit(((about[i] or ''):gsub('[\r\n\t]', ' ')), w - 5)
    lines[i] = ' ' .. box.left .. ' ' .. s .. string.rep(' ', math.max(0, w - 5 - width_of(s))) .. ' ' .. box.right
  end
  return lines
end
local function strip_lines(r, cursor_line)
  return strip_of(r, r.entries[cursor_line] or (r.selected_line and r.entries[r.selected_line]), r.panel_w)
end
local function mark_cursor(r, cursor_line)
  local buf = r.panel_buf
  api.nvim_buf_clear_namespace(buf, ns_cursor, 0, -1)
  for _, ln in ipairs(r.strip or {}) do
    local t = api.nvim_buf_get_lines(buf, ln - 1, ln, false)[1] or ''
    pcall(api.nvim_buf_set_extmark, buf, ns_cursor, ln - 1, 0, { end_col = #t, hl_group = hl('FoxSymdepsDim', 'Comment') })
  end
  -- The bar follows the row under the cursor, as in every menu here; the file open in the comparison keeps a quieter
  -- band, so moving through the list never hides which file is shown.
  local bar = (cursor_line and r.entries[cursor_line]) and cursor_line or r.selected_line
  if r.selected_line and r.selected_line ~= bar then
    api.nvim_buf_set_extmark(buf, ns_cursor, r.selected_line - 1, 0, { line_hl_group = hl('CursorLine', 'CursorLine') })
  end
  if bar then api.nvim_buf_set_extmark(buf, ns_cursor, bar - 1, 0, { line_hl_group = hl('FoxSymdepsSelection', 'Visual') }) end
end
-- The groups a mark's role is drawn in: symdeps' where it is installed, the theme's own otherwise.
local ROLES = { title = { 'FoxSymdepsTitle', 'Title' }, head = { 'FoxSymdepsHeader', 'Title' }, ok = { 'FoxSymdepsOk', 'DiagnosticOk' },
  warn = { 'FoxSymdepsWarn', 'DiagnosticWarn' }, dim = { 'FoxSymdepsDim', 'Comment' }, alarm = { 'FoxSymdepsAlarm', 'DiagnosticError' } }
local function group_of(role) return hl(ROLES[role][1], ROLES[role][2]) end

-- The file list for width w, as data: its lines, its marks ({ line, from, to, role }; to -1 is the line's end), what
-- each row stands for (entries, by line), the byte ranges a click on a row means (hits), the row of what the
-- comparison shows (selected) and the title line's count (progress). It reads the review and draws nothing: the panel
-- and the pop-out's view both draw from it, each with the strip under it.
local function build(r, w)
  local external = r.row.kind == 'external'
  local text, marks, entries, hits, selected_line = {}, {}, {}, {}, nil
  local function paint(line, from, to, role) marks[#marks + 1] = { line, from, to, role } end
  local function push(s) text[#text + 1] = (s:gsub('[\r\n\t]', ' ')); return #text end
  local done, total = progress(r), #r.files
  local mode = (r.row.kind == 'commit' or external) and '' or (M.since_mode() and ' · new' or ' · all')
  local count = external and 'both copies kept' or (done .. ' of ' .. total .. mode)
  push(spread(external and ' Outside edits' or ' Review', count .. ' ', w))
  paint(1, 0, -1, 'title')
  push('')
  local function file_row(i, f, indent, set)
    local checks = set and set.marks or r.marks
    local checked = checks and checks[f.rel] == f.signature and f.loaded
    local stale = not checked and checks and checks[f.rel] ~= nil and f.loaded
    local request = (not set or set == r.active_set) and not checked and M.request_of(r, f) or nil
    if request and request.ready then stale = true end
    local mark = checked and '✓' or stale and '↻' or request and '✉' or '○'
    local stats = not f.loaded and '' or f.error and 'unavailable' or f.binary and 'binary' or ('+' .. f.added .. ' −' .. f.deleted)
    local arrow = f.expanded and '▾' or '▸'
    local left = indent .. arrow .. ' ' .. mark .. ' ' .. f.rel:gsub('[\r\n\t]', ' ')
    local risky = f.loaded and f.risks and #f.risks > 0
    r.notes = r.notes or M.notes(r.root)
    local noted = r.notes[f.rel] and #r.notes[f.rel] or 0
    -- → its change adds or removes a call: it reaches further than its lines (the strip says where).
    local st = f.loaded and structure_of(f)
    local tail = ((st and #st.changed > 0) and '→ ' or '') .. stats .. ' '
    local ln = push(spread(left, (noted > 0 and '✎ ' or '') .. (risky and '⚠ ' or '') .. tail, w))
    local active = (not set or set == r.active_set) and i == r.index
    if active then selected_line = ln end
    entries[ln] = { set = set, file = i }
    local a = #indent
    hits[ln] = { fold = { a + 1, a + #arrow }, mark = { a + #arrow + 2, a + #arrow + 1 + #mark } }
    paint(ln, a + #arrow + 1, a + #arrow + 1 + #mark, checked and 'ok' or stale and 'warn' or 'dim')
    if stats ~= '' then paint(ln, #text[ln] - #stats - 1, -1, 'dim') end
    if risky then paint(ln, #text[ln] - #tail - #'⚠ ', #text[ln] - #tail, 'warn') end
    if f.expanded and f.loaded and not f.error and not f.binary then
      for _, symbol in ipairs(M.changed_symbols(f)) do
        local icon = symbol.side == 'before' and '− ' or symbol.kind == 'hunk' and '↳ ' or symbol.kind:match('struct') and '◇ ' or 'ƒ '
        local calls = st and st.calls[symbol.name]
        local label = indent .. '      ' .. icon .. symbol.name
        local sl = push((calls and #calls.added + #calls.removed > 0) and spread(label, '→ ', w) or fit(label, w))
        entries[sl] = { set = set, file = i, symbol = symbol }
        paint(sl, 0, -1, 'dim')
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
        paint(rl, 0, -1, 'head')
        if row.kind == 'working' then entries[rl] = { set = set } end
      end
      if row.kind == 'working' then
        if set.expanded then
          for i, f in ipairs(set.files or {}) do file_row(i, f, '   ', set) end
          if #(set.files or {}) == 0 then paint(push('     the working tree is clean'), 0, -1, 'dim') end
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
        entries[ln] = { set = set }
        hits[ln] = { fold = { 4, 3 + #arrow } }
        if set.completed then paint(ln, #text[ln] - #right, -1, 'ok') elseif right ~= '' then paint(ln, #text[ln] - #right, -1, 'dim') end
        if tested ~= '' then paint(ln, #text[ln] - #right, #text[ln] - #right + #tested, row.tests == 'passed' and 'ok' or 'alarm') end
        if set.expanded then
          for i, f in ipairs(set.files or {}) do file_row(i, f, '       ', set) end
          if #(set.files or {}) == 0 then paint(push('         no changed files'), 0, -1, 'dim') end
        end
      end
    end
  else
    local rl = push(rule(r.row.short or 'Changes', '', w)); paint(rl, 0, -1, 'head')
    for i, f in ipairs(r.files) do file_row(i, f, '   ') end
  end
  return { lines = text, marks = marks, entries = entries, hits = hits, selected = selected_line, external = external, progress = count }
end

-- The description strip's box under a built list, holding its two lines; returns the line of the first.
local function add_strip(built, lines, w)
  local text, marks = built.lines, built.marks
  text[#text + 1] = ''
  local top = #text + 1
  local box = strip_box()
  text[top], text[top + 1], text[top + 2], text[top + 3] = ' ' .. box.tl .. string.rep(box.top, w - 3) .. box.tr, lines[1], lines[2],
    ' ' .. box.bl .. string.rep(box.bottom, w - 3) .. box.br
  marks[#marks + 1] = { top, 0, -1, 'dim' }
  marks[#marks + 1] = { top + 3, 0, -1, 'dim' }
  return top + 1
end

local popout_redraw   -- while the list is in the pop-out, it is drawn there instead (the end of this file)
local save_view       -- the view's state for the pop-out's history and layout record (the end of this file)
local ask_reach      -- who calls the changed functions a drawing shows (below)
local function panel(r, select_row)
  if r.popout then return popout_redraw(r, select_row) end
  if not api.nvim_buf_is_valid(r.panel_buf) then return end
  if not api.nvim_win_is_valid(r.panel_win) then r.panel_dirty = true; return end
  r.panel_dirty = false
  local w = math.max(24, api.nvim_win_get_width(r.panel_win) - 1)
  r.panel_w = w
  local built = build(r, w)
  local text = built.lines
  r.entries, r.hits = built.entries, built.hits
  -- The description strip: what the selected row is and where it stands; then the one footer line.
  local cursor_line = (select_row and built.selected) or api.nvim_win_get_cursor(r.panel_win)[1] or built.selected
  r.selected_line = built.selected
  local first = add_strip(built, strip_lines(r, cursor_line), w)
  r.strip = { first, first + 1 }
  local open, check, acts, hide = hint('open', 'enter'), hint('check', 'mark-list'), hint('actions', 'actions-list'), hint('hide', 'hide')
  local keys = ' ' .. table.concat(built.external and { open, acts, hide } or (w >= 44 and { open, check, acts, hide } or { open, check, hide }), ' · ')
  text[#text + 1] = fit(keys, w)
  r.footer_line = #text
  built.marks[#built.marks + 1] = { r.footer_line, 0, -1, 'dim' }
  vim.bo[r.panel_buf].modifiable = true
  api.nvim_buf_set_lines(r.panel_buf, 0, -1, false, text)
  vim.bo[r.panel_buf].modifiable = false
  api.nvim_buf_clear_namespace(r.panel_buf, ns, 0, -1)
  for _, m in ipairs(built.marks) do
    pcall(api.nvim_buf_set_extmark, r.panel_buf, ns, m[1] - 1, math.max(0, m[2]), { end_row = m[1] - 1, end_col = m[3] < 0 and #text[m[1]] or math.min(m[3], #text[m[1]]), hl_group = group_of(m[4]) })
  end
  mark_cursor(r, cursor_line)
  if select_row and built.selected then api.nvim_win_set_cursor(r.panel_win, { built.selected, 0 }) end
  set_footer(r)
  ask_reach(r, built)
end

-- ─── structure, read in the background ──────────────────────────────────────────────────────────────────────────
-- The calls of each loaded file (M.structure), the file shown first, a few milliseconds at a time. The list is drawn
-- again only when what was read shows there: a → mark, or the rows of an open file.
local function read_structure(r)
  if r.structure_busy then return end
  r.structure_busy = true
  local function step()
    if M.current ~= r or r.closing then r.structure_busy = false; return end
    local started, read_any, shows, more = uv.hrtime(), false, false, false
    local order = { r.files[r.index] }
    for _, f in ipairs(r.files) do if f ~= order[1] then order[#order + 1] = f end end
    for _, f in ipairs(order) do
      if f.loaded and not structure_of(f) then
        if read_any and uv.hrtime() - started > 8e6 then more = true; break end
        local had = f.structure and #f.structure.changed or 0   -- a mark that goes away shows too
        local s = M.structure(f)
        read_any, shows = true, shows or had + #s.changed > 0 or f.expanded == true
      end
    end
    r.structure_busy = more
    if shows then panel(r) end
    if more then vim.defer_fn(step, 15) end
  end
  vim.defer_fn(step, 15)
end

-- Callers, asked one function at a time; each answer draws the list again (the strips say it).
local NO_REACH = 'callers: requires a language server or the project map'
M.REACH_WAIT_S, M.REACH_AGAIN_S = 5, 30
local map_missing = {}   -- root → when to ask again whether it has a map built
local run_reach
-- The language server attached to the working file's buffer, when it is loaded and has one; false otherwise.
local function ask_server(job, done)
  local buf = vim.fn.bufnr(job.f.path)
  if buf < 0 or not api.nvim_buf_is_loaded(buf) then return false end
  local G = require('desk.callgraph')
  local client = G.clients(buf)[1]
  if not client then return false end
  local stamp, over, cancel = { source = 'lsp', buf = buf, tick = api.nvim_buf_get_changedtick(buf) }, false, nil
  local function answer(said)
    if over then return end
    over = true
    if cancel then pcall(cancel) end
    done(said, stamp)
  end
  vim.defer_fn(function() answer('callers: the language server did not answer in ' .. M.REACH_WAIT_S .. ' s') end, M.REACH_WAIT_S * 1000)
  G.with_tree(buf, function(tree)
    if over then return end
    local node = tree and units_by_label(tree:root(), buf)[job.s.name]
    local target = node and G.symbol_in(tree, buf, node:start())
    if not target then return answer('not in the working file now') end
    local indexing = G.busy(client)
    cancel = G.fetch(client, target, function(graph, err)
      if not graph then return answer('callers: ' .. tostring(err or 'the language server gave none')) end
      local n = #(graph.callers or {}) + ((graph.more or {}).callers or 0)
      stamp.count = n
      answer((n == 1 and '1 caller' or n == 0 and 'no callers' or (n .. ' callers')) .. (indexing and ' (it is still indexing)' or ''))
    end)
  end)
  return true
end
-- The project map (desk-work map), by name: the function's id in it, else its name, then the one of that name in
-- this file; false when this checkout has no map built (asked again after half a minute).
local function ask_map(r, job, done)
  local ok, map = pcall(require, 'desk.map')
  if not ok or type(map) ~= 'table' or type(map.desk_work) ~= 'function' or (map_missing[r.root] or 0) > os.time() then return false end
  local function count(answer)
    local n = 0
    for _, node in ipairs(type(answer.nodes) == 'table' and answer.nodes or {}) do if type(node) == 'table' and node.depth == 1 then n = n + 1 end end
    return n
  end
  local function ask(from, step)
    map.desk_work({ 'map', 'query', '--root', r.root, '--q', 'callers', '--from', from, '--depth', '1' }, function(answer, out)
      if type(answer) == 'table' and answer.ok ~= false then
        local n = count(answer)
        return done((n == 1 and '1 caller' or n == 0 and 'no callers' or (n .. ' callers')) .. ' in the project map (by name)', { source = 'map', count = n })
      end
      local message = type(answer) == 'table' and tostring(answer.message or '') or ''
      if (out and out.missing) or message:find('No project map', 1, true) then
        map_missing[r.root] = os.time() + M.REACH_AGAIN_S
        return done(NO_REACH, { source = 'none' })
      end
      if type(answer) ~= 'table' then return done('callers: the project map did not answer', { source = 'none' }) end
      local mine = vim.tbl_filter(function(c) return type(c) == 'table' and c.file == job.f.rel and type(c.id) == 'string' end,
        type(answer.candidates) == 'table' and answer.candidates or {})
      if #mine == 1 and step < 3 then return ask(mine[1].id, 3) end
      if step == 1 then return ask(job.s.name, 2) end
      done('callers: not in the project map', { source = 'map' })
    end, 5000)
  end
  ask(job.f.rel .. '::' .. job.s.name, 1)
  return true
end
run_reach = function(r)
  if r.reach_busy or M.current ~= r or r.closing then return end
  local job = table.remove(r.reach_queue or {}, 1)
  if not job then return end
  r.reach_busy = true
  local function done(said, extra)
    reach[job.key] = vim.tbl_extend('force', { said = said, at = os.time() }, extra or {})
    r.reach_busy = false
    if M.current == r and not r.closing then panel(r) end
    vim.schedule(function() run_reach(r) end)
  end
  if not ask_server(job, done) and not ask_map(r, job, done) then vim.schedule(function() done(NO_REACH, { source = 'none' }) end) end
end
-- Who calls function s of file f: asked when nothing current is known (a server's answer is current until its buffer
-- changes, a map's for ten minutes; a server attached since answers instead).
function M.reach(r, f, s)
  if s.side == 'before' or s.kind == 'hunk' then return end
  local key = reach_key(f, s)
  local got = reach[key]
  if got and got.pending == r then return end
  if got and not got.pending then
    local buf = vim.fn.bufnr(f.path)
    local loaded = buf >= 0 and api.nvim_buf_is_loaded(buf)
    local fresh
    if got.source == 'lsp' then fresh = loaded and got.buf == buf and got.tick == api.nvim_buf_get_changedtick(buf)
    else
      local server = loaded and #require('desk.callgraph').clients(buf) > 0
      fresh = not server and os.time() - (got.at or 0) < (got.source == 'map' and 600 or M.REACH_AGAIN_S)
    end
    if fresh then return end
  end
  reach[key] = { pending = r }
  r.reach_queue = r.reach_queue or {}
  table.insert(r.reach_queue, { f = f, s = s, key = key })
  vim.schedule(function() run_reach(r) end)
end
-- The changed functions a drawing of the list shows: their callers asked (at most 24 at a time).
ask_reach = function(r, built)
  local n = 0
  for _, entry in pairs(built.entries) do
    local s = entry.symbol
    if s and s.kind ~= 'hunk' and s.side ~= 'before' and n < 24 then
      local f = (entry.set and entry.set.files or r.files)[entry.file]
      if f then n = n + 1; M.reach(r, f, s) end
    end
  end
end

-- One buffer per side for the whole review; a file change replaces its lines. A new pair per file re-ran every FileType
-- hook and the diff setup (20-40 ms a key). Pairs are not kept per file: Vim diffs at most 8 buffers (E96).
local maps
local function side_buffer(r, side, file, text)
  local key = side == 'before' and 'left_buf' or 'right_buf'
  local buf = r[key]
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(false, true)
    r.buffers[#r.buffers + 1] = buf
    vim.b[buf].desk_review_root = r.root
    vim.bo[buf].readonly, vim.bo[buf].bufhidden = true, 'hide'
    maps(r, buf, false)
    r[key] = buf
  end
  local name, old = 'review://' .. r.id .. '/' .. side .. '/' .. file.rel, api.nvim_buf_get_name(buf)
  if name ~= old then
    pcall(api.nvim_buf_set_name, buf, name)
    -- A rename leaves an unlisted, unloaded buffer holding the old name (Vim's alternate file); one per file visited.
    for _, b in ipairs(old ~= '' and api.nvim_list_bufs() or {}) do
      if b ~= buf and not api.nvim_buf_is_loaded(b) and api.nvim_buf_get_name(b) == old then pcall(api.nvim_buf_delete, b, { force = true }) end
    end
  end
  vim.b[buf].desk_review = { file = file.path, side = side }
  -- As a new buffer would be: no marks from the last file, and no undo step back into it.
  for _, id in pairs(api.nvim_get_namespaces()) do api.nvim_buf_clear_namespace(buf, id, 0, -1) end
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].modifiable, vim.bo[buf].readonly, vim.bo[buf].undolevels = true, false, -1
  api.nvim_buf_set_lines(buf, 0, -1, false, lines(text))
  vim.bo[buf].modifiable, vim.bo[buf].readonly, vim.bo[buf].undolevels = false, true, undolevels
  local ft = (not file.error and not file.binary) and filetype_of(file.rel, text) or ''
  if vim.bo[buf].filetype ~= ft then
    pcall(vim.treesitter.stop, buf)
    vim.bo[buf].filetype = ft
  end
  return buf
end

-- Every key the review sets, in the order its reference lists them: rows of the action registry (desk/actions.lua),
-- which make the mappings, the key hints in the menus and footers (M.bind), the home menu's review rows and the review
-- table in NVIM-KEYBINDS.md (python3 tests/test_nvim_keys.py --write rewrites it). on: the file list (LIST), the
-- comparison panes (DIFF) or both; each run gets ctx.review, the review the buffer belongs to.
-- Pressed in the list, a key that checks, refreshes or moves to another file leaves focus in the list, so "m, j, m"
-- checks files in a row and Tab steps through files without landing in the comparison.
-- s in the list: a label on every row j and k stop on (commits, files, changed functions), at its first mark; typing
-- one puts the cursor there, so the strip and the bar follow as they do for j and k.
function M.jump_rows(r)
  if not (r and r.entries and api.nvim_win_is_valid(r.panel_win or -1)) then return end
  local text, targets = api.nvim_buf_get_lines(r.panel_buf, 0, -1, false), {}
  for line in pairs(r.entries) do targets[#targets + 1] = { line = line, col = ((text[line] or ''):find('%S') or 1) - 1 } end
  require('desk.nav').jump(r.panel_win, targets, function(t) api.nvim_win_set_cursor(r.panel_win, { t.line, 0 }) end)
end
local function in_list(r, fn) return function()
  local from = api.nvim_get_current_win()
  fn()
  if from == r.panel_win and api.nvim_win_is_valid(from) then api.nvim_set_current_win(from) end
end end
local function next_file(r) return in_list(r, function() M.select(r.index % #r.files + 1) end) end
local function previous_file(r) return in_list(r, function() M.select((r.index - 2) % #r.files + 1) end) end
local function to_diff(r, fn) return function() if api.nvim_get_current_win() == r.panel_win then api.nvim_set_current_win(r.right_win) end; fn() end end
local function symdeps_here() return actions.symdeps() or 'requires symdeps' end
local LIST, DIFF, BOTH = 'review-list', 'review-diff', { 'review-list', 'review-diff' }
local WARN = vim.log.levels.WARN
local function pop() local ok, P = pcall(require, 'desk.popout'); return ok and P or nil end

-- What a row of the list stands for, as a key that stays while the list is drawn again (a commit, a file, a part).
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
-- An entry's key as the pop-out keeps an item's (at most 120 bytes: a long one keeps its start and a digest of it all).
local function item_key(key) return #key > 120 and (key:sub(1, 80) .. '#' .. vim.fn.sha256(key):sub(1, 32)) or key end
-- The row a key names, in the list as it is now (a refresh may have moved it since it was drawn), or nil.
local function resolve(r, ref)
  if not (r and type(ref) == 'table' and type(ref.key) == 'string') then return nil end
  for _, entry in pairs(build(r, 40).entries) do if entry_key(r, entry) == ref.key then return entry end end
end
-- The comparison pane last read (the after side until one was).
local function diff_window(r)
  local win = r.last_diff_win
  if win ~= r.left_win and win ~= r.right_win or not api.nvim_win_is_valid(win or -1) then win = r.right_win end
  return api.nvim_win_is_valid(win or -1) and win or nil
end

-- The keys of the list are also the keys of its view in the pop-out (desk.popout; the view kind is at the end of this
-- file). There a drawn row runs on the pop-out's copy of the list (ctx.copy: j, k, s); a remote one runs here for the
-- row the pop-out named (ctx.view, ctx.item), never through the list's window, which is hidden while the list is out;
-- remote = false keeps a row here.
local function named(ctx)
  local entry = resolve(ctx.review, ctx.item)
  if not entry then tell('That row is no longer in the list.', WARN) end
  return entry
end
local function open_row(ctx)
  if not ctx.view then return M.enter() end
  local entry = named(ctx)
  if not entry then return end
  local r, before = ctx.review, save_view(ctx.view)
  M.open_entry(entry)
  -- Another file shown here is a step H undoes in the pop-out. During an Enter the pop-out folds this into its own step
  -- for it (which keeps this list's state from before, and the editor's spot), so one H puts back both.
  local now = r.files[r.index]
  local P = pop()
  if P and before.step and (not now or now.rel ~= before.rel or r.active_set ~= before.set) then
    vim.schedule(function() P.stepped(ctx.view, before) end)
  end
end
-- j and k: in the pop-out the next or previous row of its copy; in the list Vim's own j and k (with a count), the
-- list passing the cursor over headings and blank lines as it always has.
local function step_row(ctx, how, key)
  if ctx.copy then return require('desk.callgraph').move(ctx.copy, how) end
  vim.cmd('normal! ' .. vim.v.count1 .. key)
end
-- s in the pop-out: labels on its copy's rows at their first mark, as in the list; typing one selects that row.
local function jump_items(s)
  if not (s.drawn and s.win and api.nvim_win_is_valid(s.win)) then return end
  local text, targets = api.nvim_buf_get_lines(s.buf, 0, -1, false), {}
  for i, item in ipairs(s.drawn.boxes or {}) do targets[#targets + 1] = { line = item.line, col = ((text[item.line] or ''):find('%S') or 1) - 1, index = i } end
  require('desk.nav').jump(s.win, targets, function(t) require('desk.callgraph').select(s, t.index, true) end)
end
-- ]c and [c: run in the pane they are pressed in; from the list or the pop-out, in the pane last read (the other pane
-- follows it, as it does in diff mode).
local function change(ctx, key)
  local r = ctx.review
  local win = (ctx.win == r.left_win or ctx.win == r.right_win) and ctx.win or diff_window(r)
  if win then api.nvim_win_call(win, function() vim.cmd('normal! ' .. key) end) end
end
-- c asks for a live Claude session, then the words (as claude.send asks them, in the window c was pressed in).
local function sessions()
  local out = {}
  for _, p in ipairs(require('desk.claude').live or {}) do
    if type(p.id) == 'string' then
      local mark = p.state == 'needs you' and '●' or (p.busy and '✎' or '○')
      out[#out + 1] = { id = p.id, name = mark .. ' ' .. tostring(p.name or p.id) .. (p.project and (' · ' .. p.project) or '') .. (p.state and (' · ' .. p.state) or '') }
    end
  end
  return out
end
local function has_claude()
  local C = require('desk.claude')
  return (#(C.live or {}) > 0 and C.runtime() ~= nil) or 'no other Claude is open'
end
-- c: a change request to a Claude session about the file (or the lines) in the comparison. Its key in the list or a
-- pane asks as it always has (claude.send); from a menu or the pop-out the session and the words are given (ctx.choice,
-- ctx.text), and from the pop-out it is about the row it named.
local function request(ctx)
  local r, C = ctx.review, require('desk.claude')
  local in_list_now = api.nvim_get_current_win() == r.panel_win
  if ctx.text == nil then
    if not in_list_now or M.enter(true) then api.nvim_set_current_win(r.right_win); C.send() end
    return
  end
  if ctx.view or in_list_now then
    local entry
    if ctx.view then entry = named(ctx) else entry = r.entries and r.entries[api.nvim_win_get_cursor(r.panel_win)[1]] end
    if not (entry and entry.file) then return tell('A change request is about a file: pick one first.', WARN) end
    M.open_entry(entry, true)
    api.nvim_set_current_win(r.right_win)
  end
  local peer, dir = nil, C.runtime()
  for _, p in ipairs(C.live or {}) do if p.id == ctx.choice then peer = p end end
  if not (peer and dir) then return tell('That Claude session is no longer open.', WARN) end
  local context = M.note_context(nil)
  if not context then return tell('Put the cursor in the comparison first.', WARN) end
  if not C.write_note(dir, peer.id, C.note(ctx.text, context.file, context.first, context.last, context.code)) then
    return tell('Could not leave the note.', vim.log.levels.ERROR)
  end
  local tracked = M.requested(context.file, peer, ctx.text)
  tell(tracked and ('Change requested from ' .. peer.name .. ' · the file waits for it.') or ('Note left for ' .. peer.name .. '.'))
end
-- R: finish, then the next unchecked commit, close or stay. Its key asks after finishing (M.ask_after_finish); from a
-- menu or the pop-out the answer is given first (ctx.choice), so nothing waits here on a question she cannot see.
local function next_commit(r)
  if r.row.kind ~= 'commit' or not r.sets then return nil end
  local at = 1
  for i, set in ipairs(r.sets) do if set == r.active_set then at = i; break end end
  for offset = 1, #r.sets - 1 do
    local set = r.sets[(at + offset - 1) % #r.sets + 1]
    if set.row.kind == 'commit' and not set.completed then
      if not set.files then set.files = M.files(set.row, r.root) end
      if set.files and #set.files > 0 then return set end
    end
  end
end
local function finish_choices(r)
  local out = {}
  if r and next_commit(r) then out[1] = { id = 'next', name = 'Next commit' } end
  out[#out + 1] = { id = 'close', name = 'Close review' }
  out[#out + 1] = { id = 'stay', name = 'Stay' }
  return out
end
local function finishable(ctx)
  local r = ctx.review
  if not r then return 'no review is open' end
  local done = progress(r)
  return done == #r.files or ('check each file first (' .. done .. ' of ' .. #r.files .. ' checked)')
end
-- a: the review's actions. From the pop-out the menu opens here, and the keyboard comes here with it: a menu is read
-- and chosen in the window it is in.
local function actions_here(ctx)
  M.actions()
  local P = ctx.view and pop()
  if P then P.focus({ pid = vim.fn.getpid(), pane = require('desk.nav').pane() or '' }) end
end
M.rows = actions.add({
  { id = 'review.enter', group = 'Review', name = 'Expand commit / open review file', key = '<CR>', on = LIST, remote = true,
    about = 'Open the selected file in the comparison panes; on a commit, expand or collapse its changed files', run = open_row },
  { id = 'review.enter-l', group = 'Review', name = 'Expand commit / open review file', key = 'l', on = LIST, line = 'review.enter', menu = false,
    remote = true, run = open_row },
  { id = 'review.enter-mouse', group = 'Review', name = 'Expand commit / open review file', key = '<2-LeftMouse>', on = LIST, line = 'review.enter',
    menu = false, doc = false, remote = false, run = function() M.enter() end },
  { id = 'review.down', group = 'Review', name = 'The row below', key = 'j', on = LIST, menu = false, drawn = true,
    doc = 'The row below / above, over headings and blank lines', about = 'The row below, over headings and blank lines',
    run = function(ctx) step_row(ctx, 'down', 'j') end },
  { id = 'review.up', group = 'Review', name = 'The row above', key = 'k', on = LIST, menu = false, drawn = true, line = 'review.down',
    about = 'The row above, over headings and blank lines', run = function(ctx) step_row(ctx, 'up', 'k') end },
  { id = 'review.fold', group = 'Review', name = 'Collapse review commit', key = 'h', on = LIST, remote = true,
    about = 'Collapse changed functions first, then the selected commit',
    run = function(ctx)
      if not ctx.view then return M.fold() end
      local entry = named(ctx)
      if entry then M.fold(entry) end
    end },
  { id = 'review.next-file', group = 'Review', name = 'Next review file', key = ']f', on = BOTH, doc = 'Next / previous file', remote = true,
    about = 'The next file of this review', run = function(ctx) next_file(ctx.review)() end },
  { id = 'review.previous-file', group = 'Review', name = 'Previous review file', key = '[f', on = BOTH, line = 'review.next-file', remote = true,
    about = 'The previous file of this review', run = function(ctx) previous_file(ctx.review)() end },
  { id = 'review.next-file-tab', group = 'Review', name = 'Next review file', key = '<Tab>', on = BOTH, line = 'review.next-file', menu = false,
    remote = true, run = function(ctx) next_file(ctx.review)() end },
  { id = 'review.previous-file-tab', group = 'Review', name = 'Previous review file', key = '<S-Tab>', on = BOTH, line = 'review.next-file',
    menu = false, remote = true, run = function(ctx) previous_file(ctx.review)() end },
  { id = 'review.next-change', group = 'Review', name = 'Next review change', key = ']c', on = BOTH, doc = 'Next / previous changed block',
    remote = true, about = 'The next changed block of this file (from the list, in the comparison)', run = function(ctx) change(ctx, ']c') end },
  { id = 'review.previous-change', group = 'Review', name = 'Previous review change', key = '[c', on = BOTH, line = 'review.next-change',
    remote = true, about = 'The previous changed block of this file (from the list, in the comparison)', run = function(ctx) change(ctx, '[c') end },
  { id = 'review.mark', group = 'Review', name = 'Mark/unmark file reviewed', key = 'm', on = DIFF,
    about = 'Check or uncheck the file as reviewed', run = function() M.mark() end },
  { id = 'review.mark-list', group = 'Review', name = 'Mark selected file reviewed', key = 'm', on = LIST, line = 'review.mark', remote = true,
    about = 'Check or uncheck the selected file as reviewed (on one of its changed functions it only checks it); the cursor stays in the list',
    run = function(ctx)
      if not ctx.view then return in_list(ctx.review, M.mark_row)() end
      local entry = named(ctx)
      if entry then M.mark_row(entry) end
    end },
  { id = 'review.unread', group = 'Review', name = 'First unread review file', key = 'u', on = BOTH, remote = true,
    about = 'Resume at the first unchecked file (files with a risk mark or ready for re-review first)', run = function() M.unread() end },
  { id = 'review.since-list', group = 'Review', name = 'New since review / the whole change', key = 'n', on = LIST, remote = true,
    about = 'Only what is new since you reviewed a file / the whole change (remembered)', run = function(ctx) in_list(ctx.review, M.toggle_since)() end },
  { id = 'review.since', group = 'Review', name = 'New since review / the whole change', key = '<leader>rn', on = DIFF, line = 'review.since-list',
    about = 'Only what is new since you reviewed a file / the whole change (remembered)', run = function() M.toggle_since() end },
  { id = 'review.request', group = 'Review', name = 'Request changes from a Claude session', key = 'c', on = BOTH, remote = true,
    about = 'Request changes: a note about this file or the selected lines to a Claude session; the file waits on it',
    input = { prompt = 'Change request: ', choices = sessions }, available = has_claude, run = request },
  -- ? lists the keys (desk.keys, every view's); the actions are a and a row of the home menu, Space Space.
  { id = 'review.actions-list', group = 'Review', name = 'Review actions', key = 'a', on = LIST, menu = false, remote = true,
    doc = 'Actions: every action of this review, with what each needs (also a row of `Space Space`)', run = actions_here },
  { id = 'review.actions', group = 'Review', name = 'Review actions', on = BOTH, remote = true,
    about = 'Every action of this review, with what each needs', run = actions_here },
  { id = 'review.api', group = 'Review', name = 'Open the API review of this file', key = 'A', on = BOTH, remote = false,
    about = 'Open the saved API review of this file (Actions has "API review: file / change" and "Explain this hunk")', run = function() M.api_open() end },
  { id = 'review.plan', group = 'Review', name = 'Plan coverage', key = 'P', on = BOTH, remote = false,
    about = 'Plan coverage: each plan step with the commits that touched it, steps not started, files outside the plan', run = function() M.plan_coverage() end },
  { id = 'review.note', group = 'Review', name = 'Note to self on this line', key = 'N', on = BOTH, remote = false,
    about = 'Note to self on this line; it stays with the file in every later review (`:ReviewNotes` lists them)',
    run = function(ctx) to_diff(ctx.review, function() M.note_here() end)() end },
  { id = 'review.finish', group = 'Review', name = 'Finish review, then next commit or close', key = 'R', on = BOTH, remote = true,
    about = 'Finish after every file is checked, then choose: open the next unchecked commit, close the review, or stay; this clears the finished commit from pending reviews',
    input = { choices = function(ctx) return finish_choices(ctx.review) end }, available = finishable,
    run = function(ctx) M.finish_next(ctx.choice) end },
  { id = 'review.whitespace', group = 'Review', name = 'Toggle review whitespace', key = '<leader>rw', on = BOTH, about = 'Show / hide whitespace differences',
    remote = true,
    run = function(ctx) local r = ctx.review; r.whitespace = not r.whitespace; options(r); tell('Whitespace changes: ' .. (r.whitespace and 'hidden' or 'shown')) end },
  { id = 'review.context', group = 'Review', name = 'Toggle review context', key = '<leader>rc', on = BOTH, about = 'Six context lines / full-file context',
    remote = true,
    run = function(ctx) local r = ctx.review; r.context = not r.context; options(r); tell('Context: ' .. (r.context and 'full file' or 'six lines')) end },
  { id = 'review.list-back', group = 'Review', name = 'Back to the review file list', key = '<BS>', on = DIFF,
    about = 'Back to the file list from a comparison pane, showing it again if it was hidden (or in the pop-out)', run = function() M.show_panel(true) end },
  { id = 'review.file-list', group = 'Review', name = 'Toggle review file list', key = '<leader>re', on = BOTH, also = '`:ReviewFiles`', remote = false,
    about = 'Toggle the review file list, keeping the comparison open; `Space e` keeps its normal Neo-tree binding', run = function() M.toggle_panel() end },
  -- s: labels on the list's rows; in a diff it stays the code's flash s (no row there). symdeps is gs in both.
  { id = 'review.jump', group = 'Review', name = 'Jump to a row by its label', key = 's', on = LIST, menu = false, drawn = true,
    available = function() return require('desk.nav').labels_ready() end,
    about = 'Labels on the rows on screen, as `s` draws them in code (flash.nvim): typing one moves there, as `j` and `k` would; `Esc` stays',
    run = function(ctx) if ctx.copy then return jump_items(ctx.copy) end; M.jump_rows(ctx.review) end },
  { id = 'review.symdeps', group = 'Review', name = 'Inspect changed C++ symbol in working copy', key = 'gs', on = BOTH, available = symdeps_here,
    remote = false, about = 'Inspect the changed C/C++ file in symdeps (current working copy near the reviewed line)', run = function() M.symdeps(false) end },
  { id = 'review.source', group = 'Review', name = 'Open the working file for this change', key = 'gf', on = BOTH, remote = false,
    about = 'Open the editable working file in a separate tab', run = function() M.open_source() end },
  { id = 'review.layout', group = 'Review', name = 'Compare struct layout with review base', key = 'S', on = BOTH, available = symdeps_here,
    remote = false, about = "Compare the current struct's layout with the selected commit's parent", run = function() M.symdeps(true) end },
  { id = 'review.refresh', group = 'Review', name = 'Refresh this comparison', key = 'r', on = BOTH, about = 'Refresh the comparison', remote = true,
    run = function(ctx) local r = ctx.review; in_list(r, function() M.refresh_live(); if M.current == r then M.select(r.index, true) end end)() end },
  -- f in the pop-out is its own (go there and focus the editor).
  { id = 'review.follow', group = 'Review', name = 'Follow selected live session', key = 'f', on = LIST, remote = false,
    about = 'Follow the selected live session\'s edits in a separate tab (`:ClaudeFollow` stops)',
    run = function(ctx)
      local r = ctx.review
      local entry = r.entries and r.entries[api.nvim_win_get_cursor(0)[1]]
      local row = entry and entry.set and entry.set.row or r.row
      if row.kind == 'live' then require('desk.claude').follow(row)
      else tell('Follow works on a live session row; this one is ' .. (row.kind == 'commit' and 'a commit.' or 'not a live session.')) end
    end },
  { id = 'review.popout', group = 'Review', name = 'File list to the pop-out', key = 'o', on = LIST, remote = false,
    about = 'Move the file list to the pop-out on the other screen (it opens): the comparison takes this whole screen, `Enter` there shows a file here while the keyboard stays there; `o` there brings the list back',
    available = function() local P = pop(); if not P then return 'requires desk.popout' end; return P.can_pop() end,
    run = function(ctx) local P = pop(); if P then P.show('review', ctx) end end },
  { id = 'review.hide', group = 'Review', name = 'Hide review file list', key = 'q', on = LIST, also = '`:q` there', remote = false,
    about = 'Hide the file list; the diff keeps its file, cursor and folds', run = function() M.hide_panel() end },
  { id = 'review.hide-esc', group = 'Review', name = 'Hide review file list', key = '<Esc>', on = LIST, line = 'review.hide', menu = false,
    remote = false, run = function() M.hide_panel() end },
  { id = 'review.clear', group = 'Review', name = 'Clear search highlight', key = '<Esc>', on = DIFF, menu = false, about = 'Clear search highlighting',
    run = function() vim.cmd.nohlsearch() end },
  { id = 'review.close', group = 'Review', name = 'Close review', key = 'q', on = DIFF, also = '`:q` in a diff, `Space Cq`',
    about = 'Close the whole review and return to your editor', run = function(ctx) ctx.review.close() end },
  { id = 'review.close-bd', group = 'Review', name = 'Close Changes', key = '<leader>bd', on = BOTH, line = 'review.close', menu = false,
    remote = false, run = function(ctx) ctx.review.close() end },
})
-- The key a menu row names for one of these, as typed ("m", "<leader>re").
function M.bind(id) return actions.key('review.' .. id) end
-- A key pressed in the list or a pane: a row that asks first (c, R) asks in its own way there (the session, then the
-- note; finishing, then what next). Its input is what a menu and the pop-out ask before it runs.
local function press(row, ctx)
  if row.input then return row.run(ctx) end
  actions.press(row, ctx)
end
maps = function(r, buf, sidebar)
  -- Space in the review shows its own keys under one name (actions.PREFIXES: the review's <leader>r group).
  actions.map(sidebar and LIST or DIFF, { buffer = buf, silent = true, ctx = { review = r }, press = press })
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
    -- Rows only: a blank between commits, or the strip below the list, passes the cursor on to the next row the way
    -- it was going (the last row stops it), so the bar never falls back to the open file far up the list.
    -- The way it was going is read against the last row the cursor stood on (r.strip_for), and a bounce lands on a
    -- row and becomes that row here, so the next j or k moves on from it: a cursor set from this handler raises no
    -- second CursorMoved, and a stale strip_for once sent j back up over a heading, trapping the cursor.
    if r.entries and not r.entries[line] then
      local step = line >= (r.strip_for or line) and 1 or -1
      local count = api.nvim_buf_line_count(r.panel_buf)
      local landed
      for _, dir in ipairs({ step, -step }) do
        local l = line + dir
        while l >= 1 and l <= count and not r.entries[l] do l = l + dir end
        if r.entries[l] then landed = l; break end
      end
      if not landed then return end
      api.nvim_win_set_cursor(r.panel_win, { landed, 0 })
      line = landed
    end
    if line ~= r.strip_for then
      r.strip_for = line
      if r.strip and r.panel_w and api.nvim_buf_line_count(r.panel_buf) >= r.strip[2] then
        vim.bo[r.panel_buf].modifiable = true
        api.nvim_buf_set_lines(r.panel_buf, r.strip[1] - 1, r.strip[2], false, strip_lines(r, line))
        vim.bo[r.panel_buf].modifiable = false
        mark_cursor(r, line)
      else
        panel(r)
      end
    end
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
  M.layout(); restore_views(saved); set_footer(r)
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
  -- In the pop-out, the list comes back from there (one list, in one place).
  if r.popout then
    local view, P = r.popout, pop()
    if P then P.clear(view.id) end
    r.popout = nil
  end
  r.panel_back = nil
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
  restore_views(saved); set_footer(r)
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
    -- Most selects bring back the same requests: redraw the panel only when they changed (each redraw rebuilds every row).
    local changed = not vim.deep_equal(standing, r.shared_requests or {})
    r.shared_requests = standing
    if changed and api.nvim_buf_is_valid(r.panel_buf) then panel(r) end
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
  load_file(r, file, refresh and 'force' or r.row.kind ~= 'commit')
  read_structure(r)
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
  side_buffer(r, 'before', file, left); side_buffer(r, 'after', file, right)
  local before = file.since and 'What you reviewed' or r.row.before_label or (r.row.kind == 'commit' and ('Before · ' .. r.row.parent:sub(1, 8))
    or r.row.kind == 'working' and 'HEAD · last commit' or 'Before session · captured baseline')
  local after = file.since and 'Now · only what is new since then' or r.row.after_label or (r.row.kind == 'commit' and ('After · ' .. r.row.sha:sub(1, 8))
    or r.row.kind == 'working' and 'Working copy · includes drafts' or 'Working copy · captured now')
  for _, pair in ipairs({ { r.left_win, r.left_buf, before }, { r.right_win, r.right_buf, after } }) do
    local win, buf, label = unpack(pair)
    if api.nvim_win_get_buf(win) ~= buf then api.nvim_win_set_buf(win, buf) end
    -- The same buffer keeps its window's cursor; a new file starts at its top, as a new buffer would.
    api.nvim_win_set_cursor(win, { 1, 0 })
    api.nvim_win_call(win, function() vim.cmd('diffthis'); vim.wo.foldmethod = 'diff'; vim.wo.foldlevel = 0 end)
    vim.wo[win].number, vim.wo[win].relativenumber = true, false
    -- The line under the cursor is marked in both files (diff mode keeps the two cursors on the same line).
    vim.wo[win].cursorline, vim.wo[win].cursorlineopt, vim.wo[win].wrap = true, 'line,number', false
    vim.wo[win].signcolumn, vim.wo[win].foldcolumn = 'no', '1'
    vim.wo[win].winbar = '%#Title# ' .. escaped(label) .. ' · %<%#Normal#' .. escaped(file.rel) .. '%*'
    vim.wo[win].winhighlight = win == r.left_win
      and 'DiffAdd:FoxReviewRemoved,DiffDelete:FoxReviewFiller,DiffChange:FoxReviewOldLine,DiffText:FoxReviewOldWord,DiffTextAdd:FoxReviewOldAdd'
      or 'DiffDelete:FoxReviewFiller,DiffChange:FoxReviewNewLine,DiffText:FoxReviewNewWord'
  end
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
local function resync_working(r, data)
  if r.row.kind ~= 'working' then return false end
  local now = M.working_files(r.root, data)
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
local refresh_files
-- echo: the work event our own check sent (see share); the request list and the working tree's file list are what
-- it changed, and both are already current here, so only the files themselves are looked at.
-- background (work events, focus): git status and the HEAD lookup run without waiting, and the rest follows when they
-- answer; an explicit refresh waits for them, as before. A refresh asked for while one is running runs once after it.
function M.refresh_live(echo, background)
  local r = M.current
  if not r or r.closing then return end
  if not echo then M.refresh_requests() end
  if r.row.kind == 'commit' or r.row.snapshots then return end
  -- Hidden comparisons catch up when their tab returns, without taking focus from ordinary editing.
  if api.nvim_get_current_tabpage() ~= r.tab then r.live_dirty = true; return end
  if r.live_running then
    r.live_again = { echo = (r.live_again == nil or r.live_again.echo) and echo }
    return
  end
  if not background then return refresh_files(r, echo, nil) end
  r.live_running = true
  local want, answers = { head = true, status = not echo and r.row.kind == 'working' or nil }, {}
  local function answered(name, out)
    answers[name] = out.code == 0 and out.stdout or false
    for key in pairs(want) do if answers[key] == nil then return end end
    r.live_running = false
    if M.current ~= r or r.closing then return end
    if api.nvim_get_current_tabpage() ~= r.tab then r.live_dirty = true
    else
      set_head(r, vim.trim(answers.head or ''))
      refresh_files(r, echo, answers.status)
    end
    local again = r.live_again
    r.live_again = nil
    if again then M.refresh_live(again.echo, true) end
  end
  for name, args in pairs({ head = { 'rev-parse', '--verify', '-q', 'HEAD' }, status = want.status and STATUS or nil }) do
    local argv = vim.list_extend({ 'git', '--no-optional-locks', '-C', r.root }, args)
    local ok = pcall(vim.system, argv, { text = false, timeout = 3000 }, vim.schedule_wrap(function(out) answered(name, out) end))
    if not ok then answered(name, { code = 1 }) end
  end
end
-- status: git status output a background refresh already has; nil reads it here, false (it failed) leaves the list.
refresh_files = function(r, echo, status)
  r.live_dirty = false
  local moved, open = false, nil
  if not echo and status ~= false then moved, open = resync_working(r, status) end
  if moved then
    if #r.files == 0 then panel(r); return end
    if r.files[r.index].rel ~= open then M.select(r.index); return end
  end
  local selected = r.files[r.index]
  if not selected then return end
  local signature, failed, binary = selected.signature, selected.error, selected.binary
  -- The list is redrawn only when something it shows changed: a file, or the review's state file (another client).
  local function seen(file) return file.loaded and (file.signature .. tostring(file.error) .. tostring(file.binary)) end
  local changed, state = moved, r.state_cache and r.state_cache.stamp
  for _, file in ipairs(r.files) do
    if file.loaded or file == selected then
      local before = seen(file)
      load_file(r, file, true)
      if seen(file) ~= before then changed = true end
    end
  end
  M.state_of(r)
  if r.state_cache.stamp ~= state then changed = true end
  if signature == selected.signature and failed == selected.error and binary == selected.binary then
    if changed then panel(r) end
    return
  end
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
  -- The last file of a commit checked: it no longer counts as to review; stamping it stays an explicit step.
  r.status_line = nil
  if r.row.kind == 'commit' and r.marks[file.rel] and progress(r) == #r.files then
    r.status_line = 'All ' .. #r.files .. (#r.files == 1 and ' file' or ' files') .. ' checked: every file checked, so it is off the review list · '
      .. hint('finishes and stamps the commit', 'finish')
    tell(r.status_line)
  end
end

-- m in the list: the row's file checked, or unchecked. On a part of a file (one of its changed functions or line
-- ranges) it only checks: "m, j, m" down an open file lands the second m on its first part, which must never undo it.
-- entry: the row (the pop-out names one); nil, the row under the list's cursor.
function M.mark_row(entry)
  local r = M.current
  if not r then return false end
  if not entry then
    if not api.nvim_win_is_valid(r.panel_win) then return false end
    entry = r.entries[api.nvim_win_get_cursor(r.panel_win)[1]]
  end
  if not M.open_entry(entry, true) then return false end
  local file = r.files[r.index]
  if entry and entry.symbol and r.marks[file.rel] == file.signature then
    tell(vim.fs.basename(file.rel) .. ' is checked; m on its own row unchecks it.')
    return true
  end
  M.mark()
  return true
end

-- quiet: what next is asked at once, and its question says this; a notice drawn now would sit under it, hidden.
function M.finish(quiet)
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
  if not quiet then tell('Review complete · ' .. #r.files .. ' files checked') end
  return true
end

-- Asks what to do once a review is finished; returns 'next', 'close' or 'stay'. Tests replace it.
function M.ask_after_finish(count, has_next)
  local head = 'Review done · ' .. count .. (count == 1 and ' file' or ' files') .. ' checked.'
  local choices = has_next and { 'next', 'close', 'stay' } or { 'close', 'stay' }
  local labels = has_next and '&Next commit\n&Close review\n&Stay' or '&Close review\n&Stay'
  local ok, pick = pcall(vim.fn.confirm, head, labels, 1)
  return ok and choices[pick] or 'stay'
end

-- choice: 'next', 'close' or 'stay' when it was asked already (a menu, the pop-out); else it is asked once finished.
function M.finish_next(choice)
  local r = M.current
  if not r or not M.finish(choice == nil) then return false end
  local following = next_commit(r)
  choice = choice or M.ask_after_finish(#r.files, following ~= nil)
  if choice == 'next' and following then M.switch(following); M.unread()
  elseif choice == 'close' then
    -- A Neovim the notebook opened just for this review (desk.work open_args) goes with it, as q does there.
    M.close()
    if vim.g.desk_work_view then vim.cmd('confirm qall') end
  else panel(r) end
  return true
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

-- Enter in the list: the row under its cursor (M.open_entry).
function M.enter(marking)
  local r = M.current
  if not r or not api.nvim_win_is_valid(r.panel_win) then return false end
  return M.open_entry(r.entries[api.nvim_win_get_cursor(r.panel_win)[1]], marking)
end
-- A row of the list opened: a file (or one of its parts) in the comparison, a commit folded or unfolded. marking: only
-- to check it, so a file is not unfolded and a commit not folded. true when it showed a file.
function M.open_entry(entry, marking)
  local r = M.current
  if not r then return false end
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

-- keep: leave the list as drawn unless its width changed (returning to the tab or the terminal).
function M.layout(keep)
  local r = M.current
  if not r or not api.nvim_tabpage_is_valid(r.tab) or api.nvim_get_current_tabpage() ~= r.tab then return end
  for _, win in ipairs({r.left_win, r.right_win}) do if not api.nvim_win_is_valid(win) then return end end
  local shown = api.nvim_win_is_valid(r.panel_win)
  local room = api.nvim_win_get_width(r.left_win) + api.nvim_win_get_width(r.right_win) + (shown and api.nvim_win_get_width(r.panel_win) or 0)
  local width = shown and math.min(math.max(16, room - 36), r.panel_width or math.min(52, math.max(30, math.floor(room * .30)))) or 0
  if shown then
    api.nvim_win_set_width(r.panel_win, width)
    if not keep or r.panel_dirty or r.panel_w ~= math.max(24, api.nvim_win_get_width(r.panel_win) - 1) then panel(r) end
  end
  local left, right = api.nvim_win_get_position(r.left_win), api.nvim_win_get_position(r.right_win)
  if left[1] == right[1] and right[2] == left[2] + api.nvim_win_get_width(r.left_win) + 1 then
    local available = api.nvim_win_get_width(r.left_win) + api.nvim_win_get_width(r.right_win)
    api.nvim_win_set_width(r.left_win, math.max(1, math.floor(available / 2)))
  end
end

-- h: the row's file folded (its changed functions), else its commit; the selection goes to what was folded. entry:
-- the row (the pop-out names one); nil, the row under the list's cursor.
function M.fold(entry)
  local r = M.current
  if not r then return end
  local here = entry == nil
  if here then
    if not api.nvim_win_is_valid(r.panel_win) then return end
    entry = r.entries[api.nvim_win_get_cursor(r.panel_win)[1]]
  end
  if not entry then return end
  local folded
  if entry.file then
    local file = (entry.set and entry.set.files or r.files)[entry.file]
    if file.expanded then file.expanded, folded = false, { set = entry.set, file = entry.file } end
  end
  if not folded then
    if not entry.set then return end
    entry.set.expanded, folded = false, { set = entry.set }
  end
  local key = entry_key(r, folded)
  if r.popout then r.popout.select = item_key(key) end
  panel(r)
  if not (here and api.nvim_win_is_valid(r.panel_win)) then return end
  for line, e in pairs(r.entries) do
    if entry_key(r, e) == key then api.nvim_win_set_cursor(r.panel_win, { line, 0 }); break end
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
  -- Its list in the pop-out goes with it.
  if r.popout then
    local view, P = r.popout, pop()
    r.popout = nil
    if P then P.clear(view.id) end
  end
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
    if M.current == r and not r.closing and api.nvim_get_current_tabpage() == r.tab then
      -- The pop-out let the list go while another tab was in front: it comes back now.
      if r.panel_back then M.show_panel(false) end
      options(r); M.layout(true); M.refresh_live(false, not r.live_dirty)
    end
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
    if M.current == r then M.refresh_live(r.shared_at ~= nil and uv.now() - r.shared_at < 2500, true) end
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
    if more then vim.defer_fn(next_count, 10) else read_structure(r) end
  end
  vim.defer_fn(next_count, 10)
  return r
end

-- ─── the list in the pop-out: desk.popout's review view (the review navigator) ─────────────────────────────────
-- o in the list (or Space Space › Review list to the pop-out) moves the list to the pop-out on the other screen: the
-- panel here is hidden and the comparison takes the whole screen. The view is the list built for the pop-out's width,
-- its rows as items, the strip at its end (the panel's own footer is the pop-out's key line there). While it is out,
-- every redraw of the list goes there (popout_redraw). o there, the pop-out closing, or BS / Space re in a pane bring
-- the list back here; closing the review clears the view.
local DESK = { title = 'DeskReviewTitle', head = 'DeskReviewHead', ok = 'DeskReviewOk', warn = 'DeskReviewWarn', dim = 'DeskReviewDim',
  alarm = 'DeskReviewAlarm' }
local VIEW_GROUPS = { 'DeskReviewTitle', 'DeskReviewHead', 'DeskReviewOk', 'DeskReviewWarn', 'DeskReviewDim', 'DeskReviewAlarm', 'DeskReviewOpen' }
local VIEW_KEYS = { { ids = { 'review.down', 'review.up' }, words = 'file' }, { ids = { 'review.enter' }, words = 'show' },
  { ids = { 'review.mark-list' }, words = 'check' }, { ids = { 'review.request' }, words = 'change' }, { ids = { 'popout.keys' }, words = 'keys' } }

local function row_name(r, entry)
  if entry.symbol then return entry.symbol.name end
  local f = entry.file and (entry.set and entry.set.files or r.files)[entry.file]
  if f then return f.rel end
  local row = entry.set and entry.set.row or r.row
  if row.kind == 'working' then return 'Working changes' end
  if row.kind == 'live' then return row.name or 'live session' end
  return (row.short or 'commit') .. ' ' .. (row.subject or '')
end

-- News for the pop-out's header (its ✱ on the view's name until she looks): a file that joined the list, a change
-- request now ready for re-review, a file she checked that changed since. Never what she did (a check, a request), nor
-- another commit shown.
local function news_of(view, r)
  local now = { review = r.id, set = r.active_set, files = {}, ready = {}, stale = {} }
  for _, f in ipairs(r.files) do
    now.files[f.rel] = true
    if f.loaded and r.marks[f.rel] and r.marks[f.rel] ~= f.signature then now.stale[f.rel] = true end
    local request = M.request_of(r, f)
    if request and request.ready then now.ready[f.rel] = true end
  end
  local known, news = view.known, false
  if known and known.review == now.review and known.set == now.set then
    for _, part in ipairs({ 'files', 'ready', 'stale' }) do
      for rel in pairs(now[part]) do news = news or not known[part][rel] end
    end
  end
  view.known = now
  return news
end

local function render_view(view, width)
  local r = view.review
  if not (r and M.current == r and not r.closing) then return { title = 'review', state = 'closed', lines = { '', '  The review is closed.' } } end
  -- The pop-out draws in this editor's colours: these groups go with the view, as the theme draws them here.
  for role, name in pairs(DESK) do api.nvim_set_hl(0, name, { link = group_of(role) }) end
  api.nvim_set_hl(0, 'DeskReviewOpen', { link = 'CursorLine' })
  local w = math.max(24, math.min(width - 2, 100))
  local built = build(r, w)
  ask_reach(r, built)
  local lines, items, shown = built.lines, {}, nil
  local rows = vim.tbl_keys(built.entries)
  table.sort(rows)
  for _, line in ipairs(rows) do
    local entry, text = built.entries[line], built.lines[line]
    local key = entry_key(r, entry)
    items[#items + 1] = { key = item_key(key), kind = 'row', line = line, name_col = (text:find('%S') or 1) - 1, x = 0, w = w,
      spans = { { line, 0, #text } }, name = row_name(r, entry), ref = { key = key }, strip = strip_of(r, entry, w) }
    if line == built.selected then shown = items[#items] end
  end
  local strip = add_strip(built, (shown or items[1] or { strip = strip_of(r, nil, w) }).strip, w)
  local marks = {}
  for _, m in ipairs(built.marks) do
    local len = #lines[m[1]]
    marks[#marks + 1] = { m[1], math.max(0, m[2]), m[3] < 0 and len or math.min(m[3], len), DESK[m[4]] }
  end
  -- The file the comparison shows keeps a quieter band, as in the panel.
  if built.selected then marks[#marks + 1] = { built.selected, 0, #lines[built.selected], 'DeskReviewOpen', -1 } end
  return { title = 'review · ' .. (r.label or r.row.short or 'changes'), state = built.progress, lines = lines, marks = marks,
    hl = VIEW_GROUPS, items = items, strip = strip, footer = VIEW_KEYS, news = news_of(view, r) }
end

-- The row of what the comparison shows (its file, or the part of it gone to), as the pop-out names its item.
local function shown_key(r)
  local f = r.files[r.index]
  local entry = { set = r.sets and r.active_set or nil, file = r.index }
  if r.symbol and f and f.expanded then entry.symbol = r.symbol end
  return item_key(entry_key(r, entry))
end
-- select_row: the comparison moved (Enter, ]f, u, Next commit), so the pop-out selects what it shows now; asked for
-- here, not when the view is drawn, so the last ask wins over a redraw still waiting its turn.
popout_redraw = function(r, select_row)
  local P = pop()
  if select_row then r.popout.select = shown_key(r) end
  if P then P.redraw(r.popout) end
  set_footer(r)
end

-- The list back here: beside the comparison when its tab is in front, else as soon as it is (TabEnter).
local function bring_back(r, focus)
  if M.current ~= r or r.closing or r.popout then return end
  if not focus and api.nvim_get_current_tabpage() ~= r.tab then r.panel_back = true; return set_footer(r) end
  M.show_panel(focus)
end

local function open_view(view)
  local r = M.current
  if not r or r.closing then return end
  -- The list is going to the pop-out (again: Restore after the pop-out went): a "bring it back when its tab is in front"
  -- left from that going is over, or it would take this view away on the next TabEnter.
  view.review, r.popout, r.panel_back = r, view, nil
  -- The pop-out starts on the row the list's cursor was on.
  if api.nvim_win_is_valid(r.panel_win or -1) then
    local entry = r.entries and r.entries[api.nvim_win_get_cursor(r.panel_win)[1]]
    if entry then view.select = item_key(entry_key(r, entry)) end
    M.hide_panel()
  end
  set_footer(r)
  -- A pop-out that never came: the list comes back here.
  local P = pop()
  vim.defer_fn(function() if r.popout == view and P and not P.host.chan then P.clear(view.id) end end, (P and P.START_MS or 15000) + 1000)
end

-- The view left the pop-out (o there, the pop-out closed, the list taken back here): the list comes back beside the
-- comparison, on the row the pop-out last named.
local function close_view(view)
  local r = view.review
  if not r or r.popout ~= view then return end
  r.popout = nil
  if M.current ~= r or r.closing then return end
  if view.last_key then r.panel_selection, r.panel_active_file = view.last_key, r.files[r.index] end
  vim.schedule(function() bring_back(r, false) end)
end

-- What the view shows, for desk.popout: the history keeps all of it (step: restore puts back the commit, the file the
-- comparison showed and where in it); the layout record keeps target = { file, line, name }: the file shown, its line,
-- and which review (commit:<sha>, working:working), so Restore after a restart opens that review again.
local function review_key(r) return (r.row.kind or '') .. ':' .. (r.row.sha or r.row.sid or '') end
save_view = function(view)
  local r = view.review
  if not (r and M.current == r and not r.closing) then return { pinned = view.pinned == true } end
  local f = r.files[r.index]
  local function cursor(win) return api.nvim_win_is_valid(win or -1) and api.nvim_win_get_cursor(win) or nil end
  local right = cursor(r.right_win)
  return { step = true, pinned = view.pinned == true, review = r.id, set = r.active_set, rel = f and f.rel, symbol = r.symbol,
    right = right, left = cursor(r.left_win), select = shown_key(r),
    target = f and { file = f.rel, line = right and right[1] or 1, name = review_key(r) } or nil }
end

-- The review a record names, opened again as Space Cw opens it: its tree, the working changes first (and open) when
-- there are any, then the change it showed (a commit still in the log, a session still live) and so the same review,
-- working changes included. nil when nothing is here to review.
local function reopen(target)
  local kind, id = tostring(target.name or ''):match('^(%a+):(.*)$')
  if kind ~= 'commit' and kind ~= 'working' and kind ~= 'live' then return nil end
  require('desk.claude').changes()
  local r = M.current
  if not r then return nil end
  for _, set in ipairs(r.sets or {}) do
    local row = set.row
    if (kind == 'commit' and row.kind == 'commit' and row.sha == id) or (kind == 'live' and row.kind == 'live' and row.sid == id)
        or (kind == 'working' and row.kind == 'working') then
      if set ~= r.active_set then M.switch(set) end
      break
    end
  end
  return r
end

-- A step of the history put back (saved.step), in this review only; or, after a restart, the record's { pinned,
-- target }: the list of the review open (else the one it names, opened again) in the pop-out, on the file it showed.
local function restore_view(view, saved)
  local r = M.current
  if saved.step then
    if not (r and view.review == r and not r.closing and saved.review == r.id) then return end
    if saved.set and saved.set ~= r.active_set then M.switch(saved.set) end
    for i, f in ipairs(r.files) do
      if f.rel == saved.rel then
        if i ~= r.index then M.select(i) end
        break
      end
    end
    for _, side in ipairs({ { r.right_win, saved.right }, { r.left_win, saved.left } }) do
      if side[2] and api.nvim_win_is_valid(side[1] or -1) then pcall(api.nvim_win_set_cursor, side[1], side[2]) end
    end
    r.symbol, view.select = saved.symbol, saved.select
    return
  end
  local target = type(saved.target) == 'table' and saved.target or {}
  if not (r and not r.closing) then r = reopen(target) end
  if not r then
    local P = pop()
    if P then P.clear(view.id) end
    return tell("The review's list was not brought back: no review is open (Space Cw opens one).")
  end
  open_view(view)
  for i, f in ipairs(r.files) do
    if f.rel == target.file then
      M.select(i)
      if tonumber(target.line) and api.nvim_win_is_valid(r.right_win or -1) then
        pcall(api.nvim_win_set_cursor, r.right_win, { math.max(1, math.min(tonumber(target.line), api.nvim_buf_line_count(r.right_buf))), 0 })
      end
      break
    end
  end
  view.select = shown_key(r)
end

M.view_kind = {
  name = 'review', title = 'review', surface = LIST, menu = 'Review list to the pop-out',
  about = "The open review's file list in the pop-out on the other screen: the comparison takes this whole screen, and `Enter` there shows a file here while the keyboard stays there",
  -- In the list its own o sends it.
  available = function(ctx)
    if not M.current or M.current.closing then return 'requires an open review' end
    if not ctx.remote and ctx.surface == LIST then return false end
  end,
  open = open_view,
  render = render_view,
  -- What a remote row runs with: this review, its list's surface, the pane last read; the row named is kept, so the
  -- list comes back on it.
  ctx_for = function(view, ref)
    local r = view.review
    if not (r and M.current == r and not r.closing) then error('the review is closed', 0) end
    if type(ref) == 'table' and type(ref.key) == 'string' then view.last_key = ref.key end
    local ctx = actions.context(diff_window(r) or api.nvim_get_current_win())
    ctx.surface, ctx.review = LIST, r
    return ctx
  end,
  -- o in the pop-out: the list back here, with the editor's cursor in it.
  attach = function(view)
    local r = view.review
    if r then vim.schedule(function() bring_back(r, true) end) end
  end,
  close = close_view,
  save = save_view,
  restore = restore_view,
}

-- What is here, for an ask, a pin or the pop-out's history (actions.about): the selected row of the list (in the
-- pop-out, the row it named), or the line under the cursor in a pane.
actions.provide(LIST, function(ctx)
  local r = ctx.review
  if not r then return nil, 'no review is open' end
  local entry
  if ctx.view then entry = resolve(r, ctx.item)
  elseif api.nvim_win_is_valid(r.panel_win or -1) and r.entries then entry = r.entries[api.nvim_win_get_cursor(r.panel_win)[1]] end
  if not entry then return nil, 'no row is selected' end
  local f = entry.file and (entry.set and entry.set.files or r.files)[entry.file]
  local about = describe(r, entry)
  if entry.symbol and f then
    local s = entry.symbol
    return { title = s.name, refs = { { kind = s.kind == 'hunk' and 'code' or 'unit', file = f.rel, line = s.line, name = s.name,
      label = s.name .. ' · ' .. f.rel .. ':' .. s.line } }, excerpt = table.concat(about, '\n') }
  end
  if f then return { title = f.rel, refs = { { kind = 'file', file = f.rel, label = f.rel } }, excerpt = table.concat(about, '\n') } end
  local row = entry.set and entry.set.row or r.row
  if row.kind == 'commit' then
    return { title = row_name(r, entry), refs = { { kind = 'commit', id = row.sha, label = 'commit ' .. (row.short or '') } }, excerpt = table.concat(about, '\n') }
  end
  return { title = row_name(r, entry), refs = {}, excerpt = table.concat(about, '\n') }
end)
actions.provide(DIFF, function(ctx)
  local r = ctx.review
  local f = r and r.files[r.index]
  if not f or not api.nvim_win_is_valid(ctx.win or -1) then return nil, 'no file is shown' end
  local buf, line = api.nvim_win_get_buf(ctx.win), api.nvim_win_get_cursor(ctx.win)[1]
  local side = (vim.b[buf].desk_review or {}).side or 'after'
  return { title = f.rel .. ':' .. line, refs = { { kind = 'code', file = f.rel, line = line, label = f.rel .. ':' .. line .. ' (' .. side .. ')' } },
    excerpt = api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or '' }
end)

-- Registered as the module loads, so its Views row is in the registry; not in the headless readers that load this
-- module for its parsing only (the notebook's changed symbols, the map's syntax reader).
local reader = type(arg) == 'table' and (arg[1] == '--turn-symbols' or arg[1] == '--syntax-graph')
if not reader then
  local P = pop()
  if P then P.kind(M.view_kind) end
end

return M
