-- Since you last looked: what happened in this checkout after this page was last opened here (desk-work since):
-- new commits, test runs with their result, job runs with how their figures moved, and Claude turns with the files
-- they edited, newest first. Opening the page marks now as looked. Enter opens what a line names: a commit's review,
-- a test run's results, a job's output, a turn's changes, a file. The read runs in the background; typing never waits.
-- The page keeps its list until there is something newer: opened again with nothing new, it shows the last list it
-- showed (kept in the state folder, so another Neovim sees it too), and an open page comes back rather than a second.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
local actions = require('desk.actions')
local ns = api.nvim_create_namespace('desk_since')

-- The drawing style: retro (a DOS screen: code page 437 marks, capitals for headings) or the normal one, as init.lua
-- publishes it in vim.g.desk_style.
function M.style()
  return type(vim.g.desk_style) == 'string' and vim.g.desk_style or 'paper'
end
local MARKS = {
  paper = { commit = '❦', passed = '✓', failed = '!', running = '◷', other = '○', job = '◇', turn = '✎', file = '·', up = '↑', down = '↓' },
  retro = { commit = '♦', passed = '√', failed = '!', running = '☼', other = '○', job = '►', turn = '*', file = '·', up = '↑', down = '↓' },
}
local function marks(style) return MARKS[style] or MARKS.paper end
local function heading(text, style) return style == 'retro' and text:upper() or text end

local function figure(m, mk)
  local value = tostring(tonumber(string.format('%.6g', m.value)) or m.value)
  value = value:gsub('%.0$', '')
  local arrow = (type(m.change) == 'number' and m.verdict ~= 'same') and ((m.change > 0 and mk.up or mk.down) .. ' ') or ''
  return string.format('%s %s%s%s  %s%s', m.name, value, m.unit or '', (m.delta or '') ~= '' and ' (' .. m.delta .. ')' or '', arrow, m.verdict or '')
end
local function tests_text(item)
  local p, f = item.passed, item.failed
  if item.state == 'running' then return 'tests running' end
  if type(f) == 'number' and f > 0 then return f .. ' failed' .. (type(p) == 'number' and ' · ' .. p .. ' passed' or '') end
  if type(p) == 'number' then return p .. ' passed' end
  return 'tests ' .. (item.state or '?')
end

-- When a look was: its time today, else its day too.
local function clock(at)
  if os.date('%Y%m%d', at) == os.date('%Y%m%d') then return os.date('%H:%M', at) end
  return os.date(os.time() - at < 6 * 86400 and '%a %H:%M' or '%b %d %H:%M', at)
end

-- The page's lines and what each opens (an action table per line number), from desk-work since's answer. Pure, so a
-- test can read it. data.kept: these are the last look's items, shown again because nothing is new since then.
function M.layout(data, style, root)
  local mk = marks(style)
  local lines, actions, paints = {}, {}, {}
  local function add(text, action, paint)
    lines[#lines + 1] = text
    if action then actions[#lines] = action end
    if paint then paints[#lines] = paint end
  end
  local when = (data.since or '') ~= '' and data.since or nil
  local title = data.kept and ('Nothing new since ' .. clock(data.kept) .. ' · what that look showed')
    or data.first and 'Since you last looked · the last day' or ('Since you last looked' .. (when and ' · ' .. when or ''))
  add(heading(title, style), nil, 'heading')
  -- The keys as typed, the words in the style's voice.
  add(table.concat({ 'Enter ' .. heading('opens', style), 'q ' .. heading('closes', style), '? ' .. heading('keys', style) }, ' · '), nil, 'dim')
  add('')
  local items = data.items or {}
  if #items == 0 then add(data.first and 'Nothing in the last day.' or 'Nothing new since you looked.', nil, 'dim') end
  for _, item in ipairs(items) do
    local at = type(item.at) == 'number' and os.date('%H:%M', item.at) or ''
    local function row(mark, text, action, paint) add(string.format('%s %s  %s', mark, text, at), action, paint) end
    if item.kind == 'commit' then
      row(mk.commit, (item.sha or ''):sub(1, 7) .. ' ' .. (item.label or '') .. (item.author and item.author ~= '' and ' · ' .. item.author or ''),
        { kind = 'commit', sha = item.sha })
    elseif item.kind == 'tests' then
      local failed = item.state == 'failed' or (type(item.failed) == 'number' and item.failed > 0)
      row(failed and mk.failed or item.state == 'passed' and mk.passed or item.state == 'running' and mk.running or mk.other,
        tests_text(item) .. ' · ' .. (item.label or ''), { kind = 'tests', id = item.id }, failed and 'failed' or item.state == 'passed' and 'passed' or nil)
    elseif item.kind == 'job' then
      row(item.state == 'failed' and mk.failed or item.state == 'running' and mk.running or mk.job, (item.label or '') .. ' · ' .. (item.state or ''),
        { kind = 'log', id = item.id }, item.state == 'failed' and 'failed' or nil)
      for _, m in ipairs(item.metrics or {}) do
        add('    ' .. figure(m, mk), { kind = 'log', id = item.id }, m.verdict == 'worse' and 'worse' or m.verdict == 'better' and 'passed' or 'dim')
      end
    elseif item.kind == 'turn' then
      local files = {}
      for _, f in ipairs(item.files or {}) do files[#files + 1] = root .. '/' .. f end
      row(mk.turn, item.label or 'Claude turn', { kind = 'turn', session = item.session, name = item.name, files = files })
      for _, f in ipairs(item.files or {}) do add('    ' .. mk.file .. ' ' .. f, { kind = 'file', file = root .. '/' .. f }, 'dim') end
    end
  end
  if data.truncated then add(''); add('Older entries are left out; the page keeps the newest 60.', nil, 'dim') end
  return lines, actions, paints
end

local function scratch_tab(name)
  vim.cmd.tabnew()
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'desk-since'
  pcall(api.nvim_buf_set_name, buf, name .. ' · ' .. buf)
  return buf
end
local function fill(buf, lines, paints)
  if not api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local groups = { heading = 'Title', dim = 'Comment', failed = 'DiagnosticError', worse = 'DiagnosticWarn', passed = 'DiagnosticOk' }
  for line, paint in pairs(paints or {}) do
    pcall(api.nvim_buf_set_extmark, buf, ns, line - 1, 0, { end_row = line - 1, end_col = #lines[line], hl_group = groups[paint] })
  end
end

-- The page is a list, not a file: no line numbers, a selection bar on the entry the cursor is on (the menus' colour),
-- and j/k/the mouse that land on a line that opens nothing (the heading, a blank line) go on to the next entry that
-- way, else back to the last one.
local function as_list(win, buf, page)
  for opt, value in pairs({ number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0', wrap = false,
                            list = false, spell = false, cursorline = true, winhighlight = 'CursorLine:PmenuSel' }) do
    vim.wo[win][opt] = value
  end
  local last = 1
  api.nvim_create_autocmd('CursorMoved', { buffer = buf, callback = function()
    local row = api.nvim_win_get_cursor(0)[1]
    if page.actions[row] then last = row; return end
    local dir, n = row >= last and 1 or -1, api.nvim_buf_line_count(buf)
    for r = row + dir, dir > 0 and n or 1, dir do
      if page.actions[r] then last = r; return pcall(api.nvim_win_set_cursor, 0, { r, 0 }) end
    end
    if page.actions[last] then pcall(api.nvim_win_set_cursor, 0, { last, 0 }) end
  end })
end

-- A job's output in a tab of its own, read in the background too.
local function show_log(id)
  local buf = scratch_tab('job output')
  fill(buf, { 'Reading the job output...' })
  vim.system({ 'desk-work', 'log', '--id', id }, { text = true, timeout = 15000 }, vim.schedule_wrap(function(out)
    if out.code ~= 0 then fill(buf, { 'The job output could not be read.' }); return end
    fill(buf, vim.split((out.stdout or ''):gsub('\n$', ''), '\n', { plain = true }))
  end))
  vim.keymap.set('n', 'q', '<cmd>tabclose<CR>', { buffer = buf, desc = 'Close job output' })
end

function M.jump(action, root)
  if not action then return end
  if action.kind == 'commit' then require('desk.review').open_item({ kind = 'commit', sha = action.sha }, root)
  elseif action.kind == 'tests' then require('desk.work').tests(action.id)
  elseif action.kind == 'log' then show_log(action.id)
  elseif action.kind == 'turn' then
    local C = require('desk.claude')
    C.open_review({ kind = 'live', sid = action.session or '', name = action.name or 'Claude', short = action.name or 'Claude',
      files = action.files, label = 'a Claude turn' }, root)
  elseif action.kind == 'file' then vim.cmd('tabedit ' .. vim.fn.fnameescape(action.file)) end
end

-- The last list the page showed for a checkout: { items, truncated, at = when that look was }.
local function kept_path(root) return vim.fn.stdpath('state') .. '/desk-since/' .. vim.fn.sha256(root):sub(1, 16) .. '.json' end
function M.kept(root)
  local ok, text = pcall(vim.fn.readfile, kept_path(root))
  if not ok or #text == 0 then return nil end
  local parsed, data = pcall(vim.json.decode, table.concat(text, '\n'), { luanil = { object = true, array = true } })
  if not parsed or type(data) ~= 'table' or type(data.items) ~= 'table' or #data.items == 0 or type(data.at) ~= 'number' then return nil end
  return data
end
local function keep(root, data)
  local path = kept_path(root)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local temp = path .. '.' .. uv.os_getpid() .. '.tmp'
  local record = vim.json.encode({ items = data.items, truncated = data.truncated, at = type(data.at) == 'number' and data.at or os.time() })
  if pcall(vim.fn.writefile, { record }, temp) then uv.fs_rename(temp, path) end
end

-- The newest open wins: an answer to an older open that arrives late is dropped.
local newest = 0
local pages = {}   -- root → the page open for it: { buf, page }
function M.open(root)
  root = root or vim.fs.root(0, '.git') or vim.fn.getcwd()
  local style = M.style()
  local open = pages[root]
  local win = open and api.nvim_buf_is_valid(open.buf) and vim.fn.win_findbuf(open.buf)[1]
  local buf, page
  if win then
    -- Already open: back to it; it keeps its list while the new read runs.
    api.nvim_set_current_win(win)
    buf, page = open.buf, open.page
  else
    buf = scratch_tab('since you last looked')
    fill(buf, { heading('Since you last looked', style), '', 'Reading...' }, { 'heading' })
    -- What each line opens, filled in when the answer comes; the page's keys (rows below) read it.
    page = { root = root, actions = {} }
    as_list(api.nvim_get_current_win(), buf, page)
    actions.map('since', { buffer = buf, ctx = { page = page } })
    pages[root] = { buf = buf, page = page }
  end
  newest = newest + 1
  local mine = newest
  local ok = pcall(vim.system, { 'desk-work', 'since', '--root', root, '--reader', 'nvim', '--mark', 'yes' }, { text = true, timeout = 15000 },
    vim.schedule_wrap(function(out)
      if mine ~= newest or not api.nvim_buf_is_valid(buf) then return end
      local parsed, data = pcall(vim.json.decode, out.stdout or '', { luanil = { object = true, array = true } })
      if out.code ~= 0 or not parsed or type(data) ~= 'table' then
        fill(buf, { heading('Since you last looked', style), '', require('desk.work').refusal({ 'since' }, out) }, { 'heading' }); return
      end
      -- Something new replaces the list and is kept; nothing new shows the kept list again.
      local shown = data
      if #(data.items or {}) > 0 then keep(root, data)
      else
        local last = M.kept(root)
        if last then shown = { items = last.items, truncated = last.truncated, kept = last.at } end
      end
      local window = vim.fn.bufwinid(buf)
      local at = win and shown ~= data and window ~= -1 and api.nvim_win_get_cursor(window) or nil
      local lines, acts, paints = M.layout(shown, style, root)
      page.actions = acts
      fill(buf, lines, paints)
      -- The cursor starts on the newest entry; a page that came back with the same list keeps its place.
      if at then pcall(api.nvim_win_set_cursor, window, at); return end
      for line = 1, #lines do if acts[line] then pcall(api.nvim_win_set_cursor, window, { line, 0 }); break end end
    end))
  if not ok then fill(buf, { heading('Since you last looked', style), '', 'desk-work did not start; is it installed?' }, { 'heading' }) end
  return buf
end

-- The newest finished job's figures against its previous run (desk-work metrics), as a menu; Enter on one opens that
-- job's output. Read in the background, as the page is.
function M.figures(root)
  root = root or vim.fs.root(0, '.git') or vim.fn.getcwd()
  local ok = pcall(vim.system, { 'desk-work', 'metrics', '--root', root }, { text = true, timeout = 15000 }, vim.schedule_wrap(function(out)
    local parsed, data = pcall(vim.json.decode, out.stdout or '', { luanil = { object = true, array = true } })
    if out.code ~= 0 or not parsed or type(data) ~= 'table' then
      vim.notify(require('desk.work').refusal({ 'metrics' }, out), vim.log.levels.WARN); return
    end
    local job, metrics = type(data.job) == 'table' and data.job or nil, data.metrics or {}
    if not job or #metrics == 0 then vim.notify('No job in this checkout has printed figures yet.'); return end
    local previous = type(data.previous) == 'table' and type(data.previous.ended) == 'number' and data.previous.ended
    local against = previous and ('Against the run that ended at ' .. os.date('%H:%M', previous)) or 'The first run of this job: nothing to set it against'
    local mk, items = marks(M.style()), {}
    for _, m in ipairs(metrics) do
      local name = figure(m, mk)
      items[#items + 1] = { ident = m.name, name = name, label = name .. ' — ' .. against .. '. Enter opens its output.',
        run = function() show_log(job.id) end }
    end
    local title = (job.title or '') ~= '' and job.title or job.command or 'the last job'
    require('desk.review').show_menu(items, { title = 'Figures · ' .. title, memo = 'desk-figures' })
  end))
  if not ok then vim.notify('desk-work did not start; is it installed?', vim.log.levels.WARN) end
end

-- The keys are rows of the action registry (desk/actions.lua): the page's own, and the global one that opens it.
local function desk_work() return vim.fn.executable('desk-work') == 1 or 'requires desk-work' end
local ROWS = actions.add({
  { id = 'since.open', group = 'Work', name = 'Since you last looked: commits, tests, jobs, Claude turns', key = '<leader>Ch', on = 'editor',
    remote = true, also = '`:WorkSince`', available = desk_work,
    about = "Since you last looked: new commits, test runs, job runs with how their figures moved, and Claude turns with their files, newest first; `Enter` opens one (a commit's review, the results, the output, the turn's changes, a file). Opening it marks now as looked; with nothing new it shows the last list again",
    run = function() M.open() end },
  { id = 'since.figures', group = 'Work', name = 'Figures', on = 'editor', available = desk_work,
    about = "The newest job's figures against its previous run (desk-work metrics); `Enter` on one opens that job's output",
    run = function() M.figures() end },
  { id = 'since.open-line', group = 'Work', name = 'Open what this line names', key = '<CR>', on = 'since',
    about = "Open what the line names: a commit's review, a test run's results, a job's output, a turn's changes, a file",
    run = function(ctx) M.jump(ctx.page.actions[api.nvim_win_get_cursor(0)[1]], ctx.page.root) end },
  { id = 'since.close', group = 'Work', name = 'Close since you last looked', key = 'q', on = 'since', about = 'Close this page',
    run = function() actions.ex('tabclose') end },
})

function M.setup()
  vim.api.nvim_create_user_command('WorkSince', function() M.open() end, { desc = 'What happened since you last looked here' })
  actions.map('editor', { rows = ROWS })
end
return M
