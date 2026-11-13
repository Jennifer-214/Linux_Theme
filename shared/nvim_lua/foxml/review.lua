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
  if file then disk.files[file.rel] = r.marks[file.rel] end
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
local function panel(r, select_row)
  if not api.nvim_buf_is_valid(r.panel_buf) then return end
  local external = r.row.kind == 'external'
  local finish_label = r.row.kind == 'commit' and r.sets and 'Finish & next' or 'Finish review'
  local text = { external and '  Outside edits · both copies kept' or ('  ' .. progress(r) .. '/' .. #r.files .. ' files reviewed'),
    '  ' .. (r.row.short or 'changes'), external and '  [ Merge edits ]  [ Actions ]' or
      (progress(r) == #r.files and ('  [ ' .. finish_label .. ' ] [ Actions ]') or '  [ Check & next ] [ Actions ]') }
  local selected_line
  r.entries = {}
  local function file_row(i, f, prefix, set)
    local marks = set and set.marks or r.marks
    local check = marks and marks[f.rel] == f.signature and f.loaded and '✓' or '○'
    local stats = not f.loaded and '' or f.error and ' unavailable' or f.binary and ' binary' or (' +' .. f.added .. ' −' .. f.deleted)
    local active = (not set or set == r.active_set) and i == r.index
    text[#text + 1] = string.format('%s%s %s %s %s%s', prefix, f.expanded and '▾' or '▸', check, f.status, f.rel:gsub('[\r\n\t]', ' '), stats)
    if active then selected_line = #text end
    r.entries[#text] = { set = set, file = i }
    if f.expanded and f.loaded and not f.error and not f.binary then
      for _, symbol in ipairs(M.changed_symbols(f)) do
        local icon = symbol.side == 'before' and '− ' or symbol.kind == 'hunk' and '↳ ' or symbol.kind:match('struct') and '◇ ' or 'ƒ '
        text[#text + 1] = '      ' .. icon .. symbol.name
        r.entries[#text] = { set = set, file = i, symbol = symbol }
        if active and r.symbol and r.symbol.name == symbol.name then selected_line = #text end
      end
    end
  end
  if r.sets then
    for _, set in ipairs(r.sets) do
      local row = set.row
      local title = row.kind == 'live' and ('✎ ' .. (row.name or 'live session')) or ((row.short or 'commit') .. ' ' .. (row.subject or ''))
      text[#text + 1] = (set.expanded and '▾ ' or '▸ ') .. (set.completed and '✓ ' or '') .. title:gsub('[\r\n\t]', ' ')
      r.entries[#text] = { set = set }
      if set.expanded then
        for i, f in ipairs(set.files or {}) do file_row(i, f, '  ', set) end
        if #(set.files or {}) == 0 then text[#text + 1] = row.kind == 'working' and '    (working tree is clean)' or '    (no changed files)' end
      end
    end
  else
    for i, f in ipairs(r.files) do file_row(i, f, i == r.index and '› ' or '  ') end
  end
  vim.list_extend(text, external and { '', '  Your edits are on the left.', '  Disk edits are on the right.', '  Merge keeps the result unsaved.', '', '  q or :q returns to your editor' }
    or { '', '  Commit → file → changed symbol', '  Click ○ / ✓ to check a file.', '  Actions has the other tools.', '', '  Enter/l open · h fold', '  Tab next file · ? actions', '  q or :q returns to your editor' })
  vim.bo[r.panel_buf].modifiable = true
  api.nvim_buf_set_lines(r.panel_buf, 0, -1, false, text)
  vim.bo[r.panel_buf].modifiable = false
  api.nvim_buf_clear_namespace(r.panel_buf, ns, 0, -1)
  if selected_line then api.nvim_buf_set_extmark(r.panel_buf, ns, selected_line - 1, 0, { line_hl_group = 'Visual' }) end
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
    key('<LeftMouse>', function()
      local mouse = vim.fn.getmousepos()
      if mouse.winid ~= r.panel_win or mouse.line < 1 or mouse.line > api.nvim_buf_line_count(r.panel_buf) then return end
      api.nvim_set_current_win(r.panel_win)
      api.nvim_win_set_cursor(r.panel_win, { mouse.line, 0 })
      if mouse.line == 3 then
        if mouse.column <= 20 then M.primary() else M.actions() end
        return
      end
      local entry = r.entries and r.entries[mouse.line]
      local file_row = entry and entry.file and not entry.symbol
      local expanded = file_row and (entry.set and entry.set.files or r.files)[entry.file].expanded
      if M.enter() and file_row then
        if mouse.column >= 5 and mouse.column <= 6 then M.mark()
        elseif mouse.column <= 3 then
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
  if file.error then left, right = 'Snapshot unavailable. Refresh to retry.', 'Snapshot unavailable. This file cannot be marked reviewed.'
  elseif file.binary then left, right = 'Binary file — text comparison unavailable.', 'Binary file — inspect externally before marking reviewed.' end
  r.left_buf, r.right_buf = scratch(r, file, 'before', left), scratch(r, file, 'after', right)
  local before = r.row.before_label or (r.row.kind == 'commit' and ('Before · ' .. r.row.parent:sub(1, 8))
    or r.row.kind == 'working' and 'HEAD · last commit' or 'Before session · captured baseline')
  local after = r.row.after_label or (r.row.kind == 'commit' and ('After · ' .. r.row.sha:sub(1, 8))
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

function M.unread()
  local r = M.current
  if not r then return end
  for i, f in ipairs(r.files) do
    load_file(r, f, r.row.kind ~= 'commit')
    if r.marks[f.rel] ~= f.signature then M.select(i); return end
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

local function menu_mouse(opened)
  if not opened or not api.nvim_win_is_valid(opened.win) then return end
  local win, layout = opened.win, opened.layout
  local buf = api.nvim_win_get_buf(win)
  -- Let the renderer move and submit its own selection, including its remembered row and cursor restoration.
  vim.keymap.set('n', '<LeftMouse>', function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid ~= win or not layout.rows[mouse.line] then return end
    local current = api.nvim_win_get_cursor(win)[1]
    local key = current < mouse.line and 'j' or 'k'
    local move = vim.fn.maparg(key, 'n', false, true)
    for _ = 1, vim.tbl_count(layout.rows) do
      if api.nvim_win_get_cursor(win)[1] == mouse.line then break end
      if type(move.callback) ~= 'function' then return end
      move.callback()
    end
    if api.nvim_win_get_cursor(win)[1] ~= mouse.line then return end
    local submit = vim.fn.maparg('<CR>', 'n', false, true)
    if type(submit.callback) == 'function' then submit.callback() end
  end, { buffer = buf, silent = true, nowait = true, desc = 'Choose this action' })
end

-- Use the optional plugin's menu kit so its selection, detail strip and navigation stay identical.
function M.show_menu(items, opts)
  opts = opts or {}
  local ok, menu = pcall(require, 'fox-symdeps.menu')
  if not ok then
    vim.ui.select(items, { prompt = opts.title or 'Actions', format_item = function(item) return item.name or item.label end },
      function(item) if item then item.run() end end)
    return
  end
  for _, item in ipairs(items) do
    if item.stays then
      item.run_stays = function()
        item.run()
        -- The renderer reopens toggles itself; bind clicks on the replacement buffer too.
        vim.schedule(function() menu_mouse(menu._last) end)
      end
    end
  end
  menu.open(items, { title = opts.title, anchor_win = opts.anchor_win, memo = opts.memo, back = false })
  menu_mouse(menu._last)
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
  end
  local file = r.files[r.index]
  local ft = vim.filetype.match({ filename = file.path })
  if vim.fn.filereadable(file.path) == 1 or vim.fn.bufnr(file.path) >= 0 then
    add('Open working file', 'Open the editable working file at this change; keep the review available in its own tab.',
      function() api.nvim_set_current_win(r.right_win); M.open_source() end, { group = 'inspect', bind = 'gf' })
  end
  if ft == 'cpp' or ft == 'c' then
    add('Inspect symbol', 'Open the current working C++ file near this change and inspect it in symdeps.',
      function() api.nvim_set_current_win(r.right_win); M.symdeps(false) end, { group = 'inspect', bind = 's' })
    if r.row.kind == 'commit' then
      add('Compare struct layout', 'Compare the current struct with this commit’s base, using the current project headers.',
        function() api.nvim_set_current_win(r.right_win); M.symdeps(true) end, { group = 'inspect', bind = 'S' })
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
  local width = math.min(42, math.max(24, math.floor(vim.o.columns * .25)))
  api.nvim_win_set_width(r.panel_win, width)
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

function M.tree(rows)
  local r = M.current
  if not r then return end
  r.sets = {}
  for _, row in ipairs(rows) do
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
  if not loaded then tell('The optional symdeps plugin is not installed.', vim.log.levels.WARN); return end
  if compare and r.row.kind == 'commit' then
    local available, rev = pcall(require, 'fox-symdeps.revcompare')
    if available and plugin._menu_ctx then rev.open(plugin._menu_ctx(), r.row.parent)
    else tell('This symdeps version does not expose revision comparison.') end
  else
    tell('Symdeps · current working copy near the reviewed line')
    plugin.inspect_cursor()
  end
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
  api.nvim_win_set_width(r.panel_win, math.min(38, math.max(20, math.floor(vim.o.columns * .23))))
  _G.FoxReviewActions = function() M.actions() end
  vim.wo[r.panel_win].winbar = '%#Title# Changes%*  %@v:lua.FoxReviewActions@[ Actions ]%X'
  vim.wo[r.panel_win].statusline = ' Enter open · ? help · q close '
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
