-- Since you last looked: what happened in this checkout after this page was last opened here (desk-work since):
-- new commits, test runs with their result, job runs with how their figures moved, and Claude turns with the files
-- they edited, newest first. Opening the page marks now as looked. Enter opens what a line names: a commit's review,
-- a test run's results, a job's output, a turn's changes, a file. The read runs in the background; typing never waits.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('desk_since')

-- The drawing style: retro (a DOS screen: code page 437 marks, capitals for headings) or the normal one. init.lua
-- may set vim.g.desk_style; otherwise retro is known by the underscore insert cursor it sets.
function M.style()
  if type(vim.g.desk_style) == 'string' then return vim.g.desk_style end
  return (vim.o.guicursor or ''):find('i-ci-ve:hor20', 1, true) and 'retro' or 'paper'
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

-- The page's lines and what each opens (an action table per line number), from desk-work since's answer. Pure, so a
-- test can read it.
function M.layout(data, style, root)
  local mk = marks(style)
  local lines, actions, paints = {}, {}, {}
  local function add(text, action, paint)
    lines[#lines + 1] = text
    if action then actions[#lines] = action end
    if paint then paints[#lines] = paint end
  end
  local when = (data.since or '') ~= '' and data.since or nil
  add(heading(data.first and 'Since you last looked · the last day' or ('Since you last looked' .. (when and ' · ' .. when or '')), style), nil, 'heading')
  add(heading('Enter opens · q closes', style), nil, 'dim')
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

-- The newest open wins: an answer to an older open that arrives late is dropped.
local newest = 0
function M.open(root)
  root = root or vim.fs.root(0, '.git') or vim.fn.getcwd()
  local style = M.style()
  local buf = scratch_tab('since you last looked')
  fill(buf, { heading('Since you last looked', style), '', 'Reading...' }, { 'heading' })
  local actions = {}
  vim.keymap.set('n', '<CR>', function() M.jump(actions[api.nvim_win_get_cursor(0)[1]], root) end, { buffer = buf, desc = 'Open what this line names' })
  vim.keymap.set('n', 'q', '<cmd>tabclose<CR>', { buffer = buf, desc = 'Close since you last looked' })
  newest = newest + 1
  local mine = newest
  local ok = pcall(vim.system, { 'desk-work', 'since', '--root', root, '--reader', 'nvim', '--mark', 'yes' }, { text = true, timeout = 15000 },
    vim.schedule_wrap(function(out)
      if mine ~= newest or not api.nvim_buf_is_valid(buf) then return end
      local parsed, data = pcall(vim.json.decode, out.stdout or '', { luanil = { object = true, array = true } })
      if out.code ~= 0 or not parsed or type(data) ~= 'table' then
        fill(buf, { heading('Since you last looked', style), '', require('desk.work').refusal({ 'since' }, out) }, { 'heading' }); return
      end
      local lines, acts, paints = M.layout(data, style, root)
      actions = acts
      fill(buf, lines, paints)
      -- The cursor starts on the newest entry.
      for line = 1, #lines do if actions[line] then pcall(api.nvim_win_set_cursor, vim.fn.bufwinid(buf), { line, 0 }); break end end
    end))
  if not ok then fill(buf, { heading('Since you last looked', style), '', 'desk-work did not start; is it installed?' }, { 'heading' }) end
  return buf
end

function M.setup()
  vim.api.nvim_create_user_command('WorkSince', function() M.open() end, { desc = 'What happened since you last looked here' })
  vim.keymap.set('n', '<leader>Ch', function() M.open() end, { desc = 'Since you last looked: commits, tests, jobs, Claude turns' })
end
return M
