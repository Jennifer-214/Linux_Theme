-- Messages into this editor from other programs, over its own socket. desk-work editor connects and makes one call,
-- nvim_exec_lua("return require('desk.bridge').receive(...)", { message }): one fixed entry point, and the message is
-- only ever its argument. The types are a closed set, those registered here and by later modules (register); any
-- other type is refused by name, and so is a field its type does not list. Handlers answer within a few milliseconds
-- and schedule whatever takes longer.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
local handlers = {}
-- focused: nil until the terminal has said; last_focus: when this editor last gained the focus (milliseconds since the
-- epoch), its start until then (setup), so a Neovim she just started counts as the one she is in.
local state = { focused = nil, last_focus = 0 }
M.state = state

local function now_ms() local s, us = uv.gettimeofday(); return s * 1000 + math.floor(us / 1000) end
local function refuse(why) return { refused = why } end

-- A field of a message: its kind (string, path, integer or boolean), its cap (bytes, or the largest whole number) and
-- whether it must be there. A path is absolute.
function M.field(kind, cap, required) return { kind = kind, cap = cap, required = required or false } end

-- A message type: handler(message) gives the answer, a table; fields lists what it takes. Registering is the whole
-- allow-list.
function M.register(name, handler, fields)
  assert(type(name) == 'string' and #name <= 32 and name:match('^[%w_.-]+$'), 'a message type is a short name')
  assert(type(handler) == 'function', 'a message type needs its handler')
  handlers[name] = { run = handler, fields = fields or {} }
end

-- Every message has a version, a type and, from desk-work, the time its sender stops waiting.
local ENVELOPE = { version = true, type = true, deadline = true }
local function invalid(msg, fields)
  for key in pairs(msg) do
    if type(key) ~= 'string' then return 'a message has named fields only' end
    if not ENVELOPE[key] and not fields[key] then return ('a %s message does not take "%s"'):format(msg.type, key:sub(1, 40)) end
  end
  for key, field in pairs(fields) do
    local value = msg[key]
    if value == vim.NIL then value = nil; msg[key] = nil end
    if value == nil then
      if field.required then return ('a %s message needs "%s"'):format(msg.type, key) end
    elseif field.kind == 'boolean' then
      if type(value) ~= 'boolean' then return ('"%s" is true or false'):format(key) end
    elseif field.kind == 'integer' then
      if type(value) ~= 'number' or value % 1 ~= 0 or math.abs(value) > field.cap then return ('"%s" is a whole number up to %d'):format(key, field.cap) end
    elseif type(value) ~= 'string' then return ('"%s" is text'):format(key)
    elseif #value > field.cap then return ('"%s" is limited to %d characters'):format(key, field.cap)
    elseif value:find('\0', 1, true) then return ('"%s" holds a zero byte'):format(key)
    elseif field.kind == 'path' and value:sub(1, 1) ~= '/' then return ('"%s" is an absolute path'):format(key) end
  end
end

function M.receive(msg)
  if type(msg) ~= 'table' then return refuse('a message is a table of named fields') end
  if msg.version ~= 1 then return refuse('this editor takes version 1 messages') end
  if type(msg.type) ~= 'string' then return refuse('a message names its type') end
  local handler = handlers[msg.type]
  if not handler then return refuse(('"%s" is not a message this editor takes'):format(msg.type:sub(1, 40))) end
  local deadline = msg.deadline
  if deadline == vim.NIL then deadline = nil end
  if deadline ~= nil and type(deadline) ~= 'number' then return refuse('"deadline" is milliseconds since the epoch') end
  -- An editor that was at a prompt gets to a message late: its sender has stopped waiting and gone another way.
  if deadline and now_ms() > deadline then return refuse('this message came after its sender stopped waiting') end
  local why = invalid(msg, handler.fields)
  if why then return refuse(why) end
  local ok, answer = pcall(handler.run, msg)
  if not ok then return refuse(('the %s message failed here: %s'):format(msg.type, tostring(answer):sub(1, 300))) end
  return type(answer) == 'table' and answer or refuse(('the %s message gave no answer'):format(msg.type))
end

-- A path as the file system resolves it; a file not saved yet resolves through its folder.
local function resolve(path)
  if type(path) ~= 'string' or path == '' or path:match('^%a[%w+.-]*://') then return nil end
  local real = uv.fs_realpath(path)
  if real then return real end
  local folder = uv.fs_realpath(vim.fs.dirname(path))
  return folder and (folder .. '/' .. vim.fs.basename(path)) or nil
end
local function within(root, path) return path ~= nil and path:sub(1, #root + 1) == root .. '/' end
-- The checkout a message names, resolved; nil when it is no folder on disk.
local function checkout(path)
  local real = uv.fs_realpath(path)
  local stat = real and uv.fs_stat(real)
  return stat and stat.type == 'directory' and real or nil
end

-- The checkouts of the files open here, each folder looked up once.
local function roots()
  local by_folder, seen, out = {}, {}, {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and api.nvim_buf_get_name(buf) or ''
    if name ~= '' and not name:match('^%a[%w+.-]*://') then
      local folder = vim.fs.dirname(name)
      if by_folder[folder] == nil then
        local root = vim.fs.root(name, '.git')
        by_folder[folder] = root and (uv.fs_realpath(root) or root) or false
      end
      local root = by_folder[folder]
      if root and not seen[root] and #out < 50 then seen[root], out[#out + 1] = true, root end
    end
  end
  table.sort(out)
  return out
end

-- Who this editor is, for desk-work choosing among several on one checkout: the one she focused last.
local function ping()
  return { role = require('desk.work_events').role(), roots = roots(), last_focus = state.last_focus, mode = api.nvim_get_mode().mode }
end

-- At most `limit` bytes of `text`, never cut inside a character; and whether it was cut.
local function cut(text, limit)
  if #text <= limit then return text, false end
  local stop = limit
  while stop > 0 and (text:byte(stop + 1) or 0) >= 0x80 and text:byte(stop + 1) < 0xC0 do stop = stop - 1 end
  return text:sub(1, stop), true
end
local SEVERITY = { 'error', 'warn', 'info', 'hint' }

-- What she looks at, when it is in the asked checkout: the file in front, the cursor, the lines on screen, a visual
-- selection, the diagnostics in view, and whether the buffer is saved. Anything else says so and nothing more.
local function view(msg)
  local root = checkout(msg.root)
  if not root then return refuse('that checkout is not on disk') end
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local file = vim.bo[buf].buftype == '' and resolve(api.nvim_buf_get_name(buf)) or nil
  if not file then return refuse('no file in view') end
  if not within(root, file) then return refuse('another project') end
  local cursor = api.nvim_win_get_cursor(win)
  local first, last = vim.fn.line('w0', win), vim.fn.line('w$', win)
  local answer = { root = root, file = file, cursor = { line = cursor[1], col = cursor[2] + 1 }, visible = { first = first, last = last },
    modified = vim.bo[buf].modified, changedtick = api.nvim_buf_get_changedtick(buf), at = os.time(), diagnostics = {} }
  local mode = api.nvim_get_mode().mode
  if mode == 'v' or mode == 'V' or mode == '\22' then
    local ok, lines = pcall(vim.fn.getregion, vim.fn.getpos('v'), vim.fn.getpos('.'), { type = mode })
    if ok and type(lines) == 'table' then
      local text, truncated = cut(table.concat(lines, '\n'), 8192)
      local a, b = vim.fn.line('v'), vim.fn.line('.')
      answer.selection = { first = math.min(a, b), last = math.max(a, b), text = text, truncated = truncated }
    end
  end
  local shown = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.lnum + 1 >= first and d.lnum + 1 <= last then shown[#shown + 1] = d end
  end
  table.sort(shown, function(a, b)
    if a.severity ~= b.severity then return a.severity < b.severity end
    return a.lnum < b.lnum
  end)
  for i = 1, math.min(#shown, 30) do
    local d = shown[i]
    answer.diagnostics[i] = { line = d.lnum + 1, col = d.col + 1, severity = SEVERITY[d.severity] or 'info',
      message = (cut(d.message or '', 500)), source = d.source }
  end
  if #shown > 30 then answer.more_diagnostics = #shown - 30 end
  return answer
end

-- ─── open: a work item, in a new tab ─────────────────────────────────────────────────────────────────────────────
-- What desk-work open sends (the notebook's rows, the drawer's and notices' buttons): the items of desk.work's
-- open_action, but not "workspace", which is an editor of its own for another worktree.
local OPENS = {}
for _, action in ipairs({ 'file', 'file-diff', 'callgraph', 'suggested-tests', 'reviews', 'tests', 'compare', 'log', 'tasks', 'ask',
  'ask-service', 'service', 'timeline', 'digest', 'snoozed', 'since', 'health', 'backups' }) do OPENS[action] = true end
local FILES = { file = true, ['file-diff'] = true, callgraph = true, ['suggested-tests'] = true }
-- Opening a review closes the one already open (desk.claude open_review): these wait until she has closed hers.
local REVIEWS = { ['file-diff'] = true, reviews = true }

-- She is typing here: this editor has the focus (or has not said otherwise) and is in insert, replace, command-line or
-- terminal mode, or in the command-line window. A new tab now would take her keys.
function M.typing()
  local mode = api.nvim_get_mode().mode:sub(1, 1)
  return state.focused ~= false and (mode == 'i' or mode == 'R' or mode == 'c' or mode == 't' or vim.fn.getcmdwintype() ~= '')
end

local function untouched(buf)
  return api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf) == '' and not vim.bo[buf].modified
    and api.nvim_buf_line_count(buf) == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ''
end

-- The item in a new tab of its own, whose folder is the checkout (the work actions read the checkout from the buffer in
-- front, else that folder), never as a work viewer: a viewer's close quits the whole editor. An item that makes its
-- own tab (a review, health) leaves this one empty, and it goes.
function M.open_in_tab(action, id, index, root)
  if not pcall(vim.cmd.tabnew) then vim.notify('Could not open a tab for ' .. action, vim.log.levels.WARN, { title = 'desk' }); return end
  local tab, empty = api.nvim_get_current_tabpage(), api.nvim_get_current_buf()
  vim.cmd('tcd ' .. vim.fn.fnameescape(root))
  local ok, err = pcall(require('desk.work').open_action, action, id, index, { root = root })
  if not ok then vim.notify('Could not open ' .. action .. ': ' .. tostring(err), vim.log.levels.WARN, { title = 'desk' }) end
  if api.nvim_tabpage_is_valid(tab) and tab ~= api.nvim_get_current_tabpage() then
    local wins = api.nvim_tabpage_list_wins(tab)
    if #wins == 1 and api.nvim_win_get_buf(wins[1]) == empty and untouched(empty) then
      pcall(vim.cmd, 'tabclose ' .. api.nvim_tabpage_get_number(tab))
    end
  end
  -- A view that took the tab's window left the tab's first buffer hidden: that goes too.
  if untouched(empty) and #vim.fn.win_findbuf(empty) == 0 then pcall(api.nvim_buf_delete, empty, { force = true }) end
end

local function open(msg)
  if vim.g.desk_work_view or vim.g.desk_popout then return refuse('this editor shows one item; nothing else opens in it') end
  if not OPENS[msg.action] then return refuse(('"%s" does not open in a running editor'):format(msg.action)) end
  local root = checkout(msg.root)
  if not root then return refuse('that checkout is not on disk') end
  local id = msg.id or ''
  if FILES[msg.action] then
    id = resolve(id)
    if not within(root, id) then return refuse('another project') end
  end
  local review = package.loaded['desk.review']
  if REVIEWS[msg.action] and type(review) == 'table' and review.current then return refuse('a review is open') end
  if M.typing() then
    vim.schedule(function() vim.notify('Not opened here while you type: it opens in a window of its own.', vim.log.levels.INFO, { title = 'desk' }) end)
    return refuse('typing in this editor')
  end
  vim.schedule(function() M.open_in_tab(msg.action, id, msg.index, root) end)
  return { opened = true }
end

function M.setup()
  state.last_focus = now_ms()
  local group = api.nvim_create_augroup('desk_bridge', { clear = true })
  api.nvim_create_autocmd('FocusGained', { group = group, callback = function() state.focused, state.last_focus = true, now_ms() end })
  api.nvim_create_autocmd('FocusLost', { group = group, callback = function() state.focused = false end })
end

M.register('ping', ping, { root = M.field('path', 4096) })
M.register('view', view, { root = M.field('path', 4096, true) })
M.register('open', open, { root = M.field('path', 4096, true), action = M.field('string', 32, true),
  id = M.field('string', 4096), index = M.field('string', 256) })
return M
