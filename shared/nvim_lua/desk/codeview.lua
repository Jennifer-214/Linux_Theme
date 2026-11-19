-- A read-only view of one editor buffer. The pop-out transport owns delivery and recovery.
local M = {}
local api = vim.api
local actions = require('desk.actions')
local nav = require('desk.nav')
local function pop() return require('desk.popout') end

local function filename(buf)
  if not buf or not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then return end
  local path = api.nvim_buf_get_name(buf)
  if path:sub(1, 1) == '/' then return path end
end

local function size_problem(buf)
  local P = pop()
  local count = api.nvim_buf_line_count(buf)
  if count > P.MIRROR_LINES then return 'too large to mirror: ' .. count .. ' lines' end
  if api.nvim_buf_get_offset(buf, count) > P.MIRROR_BYTES then return 'too large to mirror: over 8 MiB' end
end

local function available(ctx)
  local buf = ctx.buf
  if not filename(buf) or not api.nvim_buf_is_loaded(buf) then return 'open a working file first' end
  return size_problem(buf) or true
end

local function source_window(view, prefer)
  if not view.buf then return end
  if prefer and api.nvim_win_is_valid(prefer) and api.nvim_win_get_buf(prefer) == view.buf then return prefer end
  local current = api.nvim_get_current_win()
  if api.nvim_win_get_buf(current) == view.buf then return current end
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do if nav.code_window(win) then return win end end
end

local function position(view)
  local win = source_window(view, view.win)
  return win and api.nvim_win_get_cursor(win)[1] or view.source_line or 1
end

local function unavailable(view)
  if not view.buf or not api.nvim_buf_is_loaded(view.buf) then return 'This buffer was closed.' end
  if not filename(view.buf) then return 'This buffer is no longer a working file.' end
  return size_problem(view.buf)
end

local function modified(view)
  return vim.bo[view.buf].modified and (vim.g.desk_style == 'retro' and '*' or '●') or ''
end

local function detach(view)
  -- Lua buffer callbacks detach on their next invocation. The token also covers reopening the same buffer.
  view.listener, view.pending, view.snapshot = nil, nil, nil
end

local function watch(view, buf, win, line)
  detach(view)
  view.buf, view.win, view.source_line = buf, win, line
  local listener = {}
  view.listener = listener
  local function active() return view.listener == listener end
  local function full()
    view.needs_full = true
    pop().mirror_changed(view)
  end
  api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, last, new_last)
      if not active() then return true end
      -- The pending end is in current coordinates. Any part of this edit beyond it extends the original range.
      local change = view.pending
      if change then
        change.first = math.min(change.first, first)
        change.last = change.last + math.max(0, last - change.new_last)
        change.new_last = math.max(change.new_last, last) + new_last - last
      else
        view.pending = { first = first, last = last, new_last = new_last }
      end
      pop().mirror_changed(view)
    end,
    on_reload = function() if not active() then return true end; full() end,
    on_detach = function() if active() then detach(view); view.buf = nil; full() end end,
  })
end

local function render(view)
  local footer = { { ids = { 'code.go' }, words = 'go to line' },
    { ids = { 'popout.pin' }, words = 'pin/follow' },
    { ids = { 'popout.back' }, words = 'bring back' } }
  local problem = unavailable(view)
  local mark = problem or modified(view)
  view.last_state, view.pending, view.needs_full, view.cursor_pending = mark, nil, nil, nil
  view.pin_pending = nil
  view.usable = not problem
  if problem then return { title = view.title, state = mark, lines = { mark }, footer = footer } end
  local buf = view.buf
  view.title = vim.fn.fnamemodify(filename(buf), ':t')
  return { title = view.title, tab = 'source', subject = view.title, lines = api.nvim_buf_get_lines(buf, 0, -1, true), state = mark, footer = footer,
    lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype), tick = api.nvim_buf_get_changedtick(buf),
    cursor = position(view) }
end

local function delta(view)
  local problem = unavailable(view)
  local mark = problem or modified(view)
  if view.needs_full or (mark ~= view.last_state and (problem or not view.usable)) then
    return nil, true
  end
  if problem then return end
  local change = view.pending
  if change and change.new_last - change.first > pop().MAX_LINES then return nil, true end
  local cursor = view.cursor_pending
  if not change and not cursor and not view.pin_pending and mark == view.last_state then return end
  view.pending, view.cursor_pending, view.last_state = nil, nil, mark
  view.pin_pending = nil
  local buf = view.buf
  return { first = change and change.first or 0, last = change and change.last or 0,
    lines = change and api.nvim_buf_get_lines(buf, change.first, change.new_last, true) or {},
    tick = api.nvim_buf_get_changedtick(buf), total = api.nvim_buf_line_count(buf), state = mark,
    cursor = not view.pinned and cursor or nil, pinned = view.pinned }
end

-- The preview pane's (desk.popout preview_show): this view shows `file` at `line`, pinned to it.
function M.retarget(view, file, line)
  local buf = vim.fn.bufnr(file)
  if buf < 0 or not api.nvim_buf_is_loaded(buf) then
    local stat = vim.uv.fs_stat(file)
    if not stat or stat.type ~= 'file' then return false end
    buf = vim.fn.bufadd(file)
    vim.fn.bufload(buf)
  end
  view.title = vim.fn.fnamemodify(file, ':t')
  view.pinned = true
  watch(view, buf, nil, line)
  view.needs_full = true
  view.cursor_pending = line
  return true
end

local function follow(view, event)
  if event.type == 'pin' then
    if not view.usable then return pop().redraw(view) end
    view.pin_pending = true
    if not view.pinned then view.cursor_pending = position(view) end
  elseif event.type == 'moved' and not view.pinned and event.win and api.nvim_win_get_buf(event.win) == view.buf then
    local line = api.nvim_win_get_cursor(event.win)[1]
    view.win = event.win
    if line == view.source_line then return end
    view.source_line, view.cursor_pending = line, line
  elseif event.buf ~= view.buf or (event.type ~= 'modified' and event.type ~= 'saved' and event.type ~= 'file') then
    return
  elseif event.type == 'file' then
    view.needs_full = true
  end
  pop().mirror_changed(view)
end

local function goto_line(view, line, split)
  if not filename(view.buf) or not api.nvim_buf_is_loaded(view.buf) then return false end
  local target = source_window(view, view.win)
  if split then
    nav.code_target(target)
    vim.cmd('belowright sbuffer ' .. view.buf)
    target = api.nvim_get_current_win()
  elseif not target then
    target = nav.code_target()
    api.nvim_win_set_buf(target, view.buf)
  else
    api.nvim_set_current_win(target)
  end
  line = math.max(1, math.min(line or position(view), api.nvim_buf_line_count(view.buf)))
  api.nvim_win_set_cursor(target, { line, 0 })
  return true
end

local rows = actions.add({
  { id = 'code.popout', group = 'Views', name = 'View this file in the pop-out', key = '<leader>cv', on = 'editor',
    menu = false, about = 'Show a live copy of this file, including unsaved changes',
    available = available, run = function(ctx) pop().show('code', ctx) end },
  { id = 'code.go', group = 'Pop-out', name = 'Go to this line in the editor', key = '<CR>', on = 'code', remote = true,
    menu = false, available = function(ctx)
      return (ctx.view and ctx.view.usable and filename(ctx.view.buf) and api.nvim_buf_is_loaded(ctx.view.buf)) or 'the source buffer is unavailable'
    end,
    run = function(ctx) if not goto_line(ctx.view, ctx.line) then error('the source buffer is unavailable') end end },
})

function M.setup()
  local P = pop()
  actions.map('editor', { rows = { rows[1] } })
  P.kind({
    name = 'code', title = 'code', surface = 'code', mirror = true, menu = 'View this file in the pop-out',
    about = 'Read the working file, including unsaved changes, in a pop-out. Enter visits its line in the editor.',
    available = available, follow = follow, render = render, delta = delta,
    match = function(view, ctx)
      if ctx.target then return filename(view.buf) == ctx.target.file end
      return view.buf == ctx.buf
    end,
    open = function(view, ctx) watch(view, ctx.buf, ctx.win, api.nvim_win_get_cursor(ctx.win)[1]) end,
    ctx_for = function(view)
      local origin = api.nvim_get_current_win()
      local win = source_window(view, view.win) or origin
      local ctx = actions.context(win)
      ctx.surface, ctx.origin = 'code', origin
      return ctx
    end,
    attach = function(view, line) goto_line(view, line, true) end,
    close = detach,
    save = function(view)
      local file = filename(view.buf)
      if file then return { target = { file = file, line = position(view) } } end
    end,
    restore = function(view, saved)
      local target = saved.target or {}
      local file = target.file
      if type(file) ~= 'string' or file:sub(1, 1) ~= '/' then return end
      view.title = vim.fn.fnamemodify(file, ':t')
      local loaded = vim.fn.bufnr(file)
      if loaded < 0 or not api.nvim_buf_is_loaded(loaded) then
        local stat = vim.uv.fs_stat(file)
        if not stat or stat.type ~= 'file' or stat.size > P.MIRROR_BYTES then return end
        loaded = vim.fn.bufadd(file)
        vim.fn.bufload(loaded)
      end
      local line = type(target.line) == 'number' and math.max(1, math.floor(target.line)) or 1
      if filename(loaded) then watch(view, loaded, nil, line) end
    end,
  })
end

return M
