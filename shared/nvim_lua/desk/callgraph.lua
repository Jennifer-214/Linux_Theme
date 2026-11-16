-- The call graph of one function, drawn as boxes in a scratch buffer: its callers above, the function in a double box,
-- what it calls below. The data is the language server's call hierarchy, so any server that has one works. Also the
-- live panel (a narrow split that follows the cursor) and, run headless, the changed symbols of a turn for the notebook.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
-- Run headless for the notebook (the end of this file), the modules beside this one come first.
local headless = type(arg) == 'table' and arg[1] == '--turn-symbols' and type(arg[0]) == 'string' and arg[0]:match('callgraph%.lua$')
if headless then package.path = (arg[0]:match('(.*/)') or './') .. '../?.lua;' .. package.path end
local actions = require('desk.actions')
local ns = api.nvim_create_namespace('desk_callgraph')
local PREPARE = 'textDocument/prepareCallHierarchy'
M.WAIT_MS, M.GRACE_MS, M.DEBOUNCE_MS, M.PANEL_WIDTH, M.MAX = 15000, 2000, 300, 36, 24

local function tell(text, level) vim.notify(text, level or vim.log.levels.INFO, { title = 'Call graph' }) end
local function width_of(s) return api.nvim_strwidth(s) end

-- ─── style ─────────────────────────────────────────────────────────────────────────────────────────────────────
-- Retro draws in a DOS font: code page 437 boxes, plain capitals. init.lua publishes the style in vim.g.desk_style.
function M.retro() return vim.g.desk_style == 'retro' end

function M.glyphs(retro)
  if retro then
    return { single = { tl = '┌', tr = '┐', bl = '└', br = '┘', h = '─', v = '│' },
             double = { tl = '╔', tr = '╗', bl = '╚', br = '╝', h = '═', v = '║' },
             down = '↓', ellipsis = '..', said = string.upper }
  end
  return { single = { tl = '╭', tr = '╮', bl = '╰', br = '╯', h = '─', v = '│' },
           double = { tl = '╔', tr = '╗', bl = '╚', br = '╝', h = '═', v = '║' },
           down = '↓', ellipsis = '…', said = function(s) return s end }
end

local function fit(s, w, ellipsis)
  s = tostring(s or ''):gsub('[%c]', ' ')
  if width_of(s) <= w then return s end
  local keep, out = math.max(0, w - width_of(ellipsis)), ''
  for _, ch in ipairs(vim.fn.split(s, '\\zs')) do
    if width_of(out .. ch) > keep then break end
    out = out .. ch
  end
  return out .. ellipsis
end
local function pad(s, w) return s .. string.rep(' ', math.max(0, w - width_of(s))) end

-- ─── layout (pure) ─────────────────────────────────────────────────────────────────────────────────────────────
-- graph: { center = item?, callers = {item}?, callees = {item}?, more = {callers, callees}?, message = text?,
--          notes = {text}?, keys = {{key, words}}? (the key line, last), header = text? (first) }
-- item: { name, detail, uri?, range?, enc? }. Returns the lines, the highlights and the boxes in reading order
-- (callers row by row, the centre, callees row by row), each with its top line, its byte span on each of its four
-- lines, where its name starts and its column and width on screen. Boxes flow left to right, wrap at `width`, and
-- every row is centred.
function M.layout(graph, width, retro)
  width = math.max(16, width or 80)
  local G = M.glyphs(retro)
  local lines, boxlist, marks = {}, {}, {}
  local function add(text, group, from, to)
    lines[#lines + 1] = text
    if group then marks[#marks + 1] = { #lines, from or 0, to or #text, group } end
  end
  local function centred(text, group)
    text = fit(text, width, G.ellipsis)
    local left = string.rep(' ', math.max(0, math.floor((width - width_of(text)) / 2)))
    add(left .. text, group, #left, #left + #text)
  end
  local function boxes(items, frame, border, name_group)
    local built = {}
    for _, item in ipairs(items) do
      local name, detail = fit(item.name, width - 4, G.ellipsis), fit(item.detail or '', width - 4, G.ellipsis)
      local inner = math.max(width_of(name), width_of(detail), 1)
      built[#built + 1] = { item = item, name = name, detail = detail, inner = inner, w = inner + 4 }
    end
    local rows, current, used = {}, {}, 0
    for _, b in ipairs(built) do
      if #current > 0 and used + 1 + b.w > width then rows[#rows + 1] = current; current, used = {}, 0 end
      used = used + (#current > 0 and 1 or 0) + b.w
      current[#current + 1] = b
    end
    if #current > 0 then rows[#rows + 1] = current end
    for _, row in ipairs(rows) do
      local total = -1
      for _, b in ipairs(row) do total = total + b.w + 1 end
      local left = string.rep(' ', math.max(0, math.floor((width - total) / 2)))
      local texts, first = { left, left, left, left }, #lines + 1
      for i, b in ipairs(row) do
        local parts = {
          frame.tl .. string.rep(frame.h, b.inner + 2) .. frame.tr,
          frame.v .. ' ' .. pad(b.name, b.inner) .. ' ' .. frame.v,
          frame.v .. ' ' .. pad(b.detail, b.inner) .. ' ' .. frame.v,
          frame.bl .. string.rep(frame.h, b.inner + 2) .. frame.br,
        }
        local box = { item = b.item, top = first, w = b.w, spans = {}, centre = frame == G.double }
        for k = 1, 4 do
          if i > 1 then texts[k] = texts[k] .. ' ' end
          if k == 1 then box.x = width_of(texts[1]) end
          local s = #texts[k]
          texts[k] = texts[k] .. parts[k]
          local lnum = first + k - 1
          box.spans[k] = { lnum, s, #texts[k] }
          marks[#marks + 1] = { lnum, s, #texts[k], border }
          if k == 2 then
            box.name_col = s + #frame.v + 1
            marks[#marks + 1] = { lnum, box.name_col, box.name_col + #b.name, name_group, 1 }
          end
          if k == 3 then marks[#marks + 1] = { lnum, s + #frame.v + 1, s + #frame.v + 1 + #b.detail, 'DeskCallGraphDim', 1 } end
        end
        boxlist[#boxlist + 1] = box
      end
      for k = 1, 4 do lines[#lines + 1] = texts[k] end
    end
  end
  local function group(label, items, more, none)
    if items == nil then return end
    centred(G.said(label .. (#items > 0 and (' · ' .. (#items + (more or 0))) or '')), 'DeskCallGraphHead')
    if #items == 0 then centred(G.said(none), 'DeskCallGraphDim') else boxes(items, G.single, 'DeskCallGraphBox', 'DeskCallGraphName') end
    if (more or 0) > 0 then centred(G.said('+' .. more .. ' more'), 'DeskCallGraphDim') end
  end
  local more = graph.more or {}
  group('callers', graph.callers, more.callers, 'no callers found')
  if graph.center then
    if graph.callers then centred(G.down, 'DeskCallGraphBox') end
    boxes({ graph.center }, G.double, 'DeskCallGraphCentre', 'DeskCallGraphCentre')
    if graph.callees then centred(G.down, 'DeskCallGraphBox') end
  end
  group('callees', graph.callees, more.callees, 'calls nothing found')
  if graph.message then
    if #lines > 0 then add('') end
    for _, line in ipairs(vim.split(graph.message, '\n')) do centred(G.said(fit(line, width, G.ellipsis)), 'DeskCallGraphDim') end
  end
  if graph.notes and #graph.notes > 0 then
    add('')
    for _, note in ipairs(graph.notes) do add(fit(G.said(note), width, G.ellipsis), 'DeskCallGraphDim') end
  end
  -- The keys, last: keys as typed, words in the theme's voice, wrapping between keys when the width runs out.
  if graph.keys and #graph.keys > 0 then
    add('')
    local text, spans = '', {}
    local function flush()
      add(text, 'DeskCallGraphDim')
      for _, span in ipairs(spans) do marks[#marks + 1] = { #lines, span[1], span[2], 'DeskCallGraphKey', 1 } end
      text, spans = '', {}
    end
    for _, k in ipairs(graph.keys) do
      local part = fit(k[1] .. ' ' .. G.said(k[2]), width, G.ellipsis)
      if text ~= '' and width_of(text .. ' · ' .. part) > width then flush() end
      if text ~= '' then text = text .. ' · ' end
      spans[#spans + 1] = { #text, #text + math.min(#k[1], #part) }
      text = text .. part
    end
    flush()
  end
  if graph.header then
    -- A state the drawing is in (the panel pinned), above everything.
    local text = fit(graph.header, width, G.ellipsis)
    local left = string.rep(' ', math.max(0, math.floor((width - width_of(text)) / 2)))
    table.insert(lines, 1, left .. text)
    for _, m in ipairs(marks) do m[1] = m[1] + 1 end
    for _, box in ipairs(boxlist) do
      box.top = box.top + 1
      for _, span in ipairs(box.spans) do span[1] = span[1] + 1 end
    end
    marks[#marks + 1] = { 1, #left, #left + #text, 'DeskCallGraphKey', 1 }
  end
  return { lines = lines, boxes = boxlist, marks = marks }
end

-- The box at a buffer position (1-based line, byte column), by index.
function M.box_at(drawn, lnum, col)
  for i, box in ipairs(drawn and drawn.boxes or {}) do
    for _, span in ipairs(box.spans) do
      if span[1] == lnum and col >= span[2] and col < span[3] then return i end
    end
  end
end

-- From box `index`, the one a move goes to: down/up the nearest by horizontal centre in the row below/above (ties go
-- left), left/right within the row, next/prev through every box (wrapping), first/last. Where nothing is, it stays.
function M.nav(boxes, index, how)
  local n = #boxes
  if n == 0 then return nil end
  if not boxes[index or 0] then index = 1 end
  if how == 'next' then return index % n + 1 end
  if how == 'prev' then return (index - 2) % n + 1 end
  if how == 'first' then return 1 end
  if how == 'last' then return n end
  local here = boxes[index]
  if how == 'left' or how == 'right' then
    local j = index + (how == 'right' and 1 or -1)
    return boxes[j] and boxes[j].top == here.top and j or index
  end
  local tops, seen = {}, {}
  for _, b in ipairs(boxes) do if not seen[b.top] then seen[b.top] = true; tops[#tops + 1] = b.top end end
  table.sort(tops)
  local row
  for i, top in ipairs(tops) do if top == here.top then row = i end end
  local want = tops[row + (how == 'down' and 1 or -1)]
  if not want then return index end
  local centre, best, gap = here.x + here.w / 2, index, math.huge
  for i, b in ipairs(boxes) do
    local d = b.top == want and math.abs(b.x + b.w / 2 - centre)
    if d and d < gap then best, gap = i, d end
  end
  return best
end

local function highlights()
  for name, link in pairs({ DeskCallGraphCentre = 'Title', DeskCallGraphBox = 'FloatBorder', DeskCallGraphName = 'Function',
    DeskCallGraphDim = 'Comment', DeskCallGraphHead = 'Comment', DeskCallGraphKey = 'Special' }) do
    api.nvim_set_hl(0, name, { link = link, default = true })
  end
  -- The selected box: inverse in retro (amber on black turned over, as a DOS list does), the selection colour elsewhere.
  api.nvim_set_hl(0, 'DeskCallGraphSelected', M.retro() and { reverse = true, default = true } or { link = 'Visual', default = true })
end

local function draw(buf, drawn)
  if not api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, drawn.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(drawn.marks) do
    pcall(api.nvim_buf_set_extmark, buf, ns, m[1] - 1, m[2], { end_col = m[3], hl_group = m[4], priority = 100 + (m[5] or 0) })
  end
  vim.b[buf].desk_callgraph = true
end

-- ─── the selected box (the view and the panel alike) ───────────────────────────────────────────────────────────
-- A surface is the view or the panel: { buf, win, drawn, index }. The selection is an index into drawn.boxes; the
-- keys move it box to box, a cursor that lands inside a box (a click, a motion) selects that box, and Enter goes to
-- the selected box's function, wherever the cursor is.
M.sel_ns = api.nvim_create_namespace('desk_callgraph_selected')

local function paint(s)
  if not api.nvim_buf_is_valid(s.buf) then return end
  api.nvim_buf_clear_namespace(s.buf, M.sel_ns, 0, -1)
  local box = s.index and s.drawn and s.drawn.boxes[s.index]
  for _, span in ipairs(box and box.spans or {}) do
    pcall(api.nvim_buf_set_extmark, s.buf, M.sel_ns, span[1] - 1, span[2], { end_col = span[3], hl_group = 'DeskCallGraphSelected', priority = 300 })
  end
end

-- Selects box `index`; place: put the cursor on its name too (never moving the focus).
function M.select(s, index, place)
  local box = s.drawn and s.drawn.boxes[index]
  if not box then return end
  if s.index ~= index then s.index = index; paint(s) end
  if place and s.win and api.nvim_win_is_valid(s.win) and api.nvim_win_get_buf(s.win) == s.buf then
    pcall(api.nvim_win_set_cursor, s.win, { box.top + 1, box.name_col })
  end
end

function M.move(s, how)
  for _ = 1, math.max(1, vim.v.count1 or 1) do
    local index = M.nav(s.drawn and s.drawn.boxes or {}, s.index, how)
    if index then M.select(s, index, true) end
  end
end

function M.selected(s) local box = s.index and s.drawn and s.drawn.boxes[s.index]; return box and box.item end

-- A new drawing: the centre box selected (else the first), the cursor on it; keep: the same graph drawn again, so
-- the selection stays where it was.
local function show(s, drawn, keep)
  local was = keep and s.index
  s.drawn, s.index = drawn, nil
  draw(s.buf, drawn)
  local first = was and drawn.boxes[was] and was
  for i, box in ipairs(drawn.boxes) do if not first and box.centre then first = i end end
  first = first or (drawn.boxes[1] and 1)
  if first then M.select(s, first, true) else paint(s) end
end

-- The cursor moved in the surface's window: inside a box, that box is the selection; elsewhere it stays.
function M.follow_cursor(s)
  local win = api.nvim_get_current_win()
  if not s.drawn or api.nvim_win_get_buf(win) ~= s.buf then return end
  local cursor = api.nvim_win_get_cursor(win)
  local index = M.box_at(s.drawn, cursor[1], cursor[2])
  if index and index ~= s.index then M.select(s, index, false) end
end

-- The surface's keys are rows of the action registry (the keys section, near the end); each run gets ctx.graph, the
-- view or the panel it was pressed in.
local function bind_selection(s, surface)
  actions.map(surface, { buffer = s.buf, nowait = true, ctx = { graph = s } })
  api.nvim_create_autocmd('CursorMoved', { buffer = s.buf, callback = function() M.follow_cursor(s) end })
end

-- ─── the symbol under a position (treesitter) ──────────────────────────────────────────────────────────────────
-- The point an LSP request names: the last identifier of the unit's name (foo in M.foo, bar in A::bar).
local function name_point(unit, name)
  local node = name
  if not node then
    local parent = unit:parent()
    node = parent and (parent:field('name')[1])
  end
  while node do
    local inner = node:field('name')[1] or node:field('field')[1] or node:field('method')[1]
    if not inner and node:named_child_count() > 0 then inner = node:named_child(node:named_child_count() - 1) end
    if not inner then break end
    node = inner
  end
  return node or unit
end

-- { name, row, col (0-based, bytes), key (the unit's range: the panel redraws only when it changes) } or nil, why.
function M.symbol_in(tree, buf, row, col)
  if not tree then return nil, 'no syntax tree for this file' end
  local node = tree:root():named_descendant_for_range(row, col, row, col)
  local unit, name = require('desk.review').unit_of(node)
  if not unit then return nil, 'the cursor is not in a function' end
  local point = name_point(unit, name)
  local label = name and vim.treesitter.get_node_text(name, buf) or vim.treesitter.get_node_text(unit, buf):match('[^\n]+') or unit:type()
  local sr, sc, er, ec = unit:range()
  local prow, pcol = point:start()
  return { buf = buf, name = vim.trim(label:gsub('%s+', ' ')):sub(1, 72), kind = unit:type(), row = prow, col = pcol,
           key = table.concat({ buf, sr, sc, er, ec, unit:type() }, ':') }
end

local function parser_of(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if ok then return parser end
end

-- The tree now if it is current, else parsed off the main loop (an async parse: typing goes on meanwhile).
function M.with_tree(buf, done)
  local parser = parser_of(buf)
  if not parser then return done(nil) end
  if parser:is_valid() then return done(parser:trees()[1]) end
  local called = false
  local ok = pcall(parser.parse, parser, false, function(_, trees)
    if called then return end
    called = true
    vim.schedule(function() done(trees and trees[1]) end)
  end)
  if not ok and not called then called = true; done(parser:parse()[1]) end
end

function M.symbol_at(buf, row, col)
  local parser = parser_of(buf)
  if not parser then return nil, 'no treesitter parser for this file type' end
  return M.symbol_in(parser:parse()[1], buf, row, col)
end

-- ─── the language server ───────────────────────────────────────────────────────────────────────────────────────
local busy = {}  -- client id → {token → true}: work the server reports in progress (indexing)
function M.clients(buf)
  return vim.tbl_filter(function(c) return c.name ~= 'copilot' end, vim.lsp.get_clients({ bufnr = buf, method = PREPARE }))
end
function M.attached(buf)
  return vim.tbl_filter(function(c) return c.name ~= 'copilot' end, vim.lsp.get_clients({ bufnr = buf }))
end
function M.expected(buf)
  local ok, configs = pcall(vim.lsp.get_configs, { enabled = true, filetype = vim.bo[buf].filetype })
  return ok and type(configs) == 'table' and #configs > 0
end
function M.busy(client) return next(busy[client.id] or {}) ~= nil end

-- One request; returns a function that cancels it. Tests put a fake here.
function M.transport(client, buf, method, params, handler)
  local ok, id = client:request(method, params, function(err, result) handler(err, result) end, buf)
  if not ok then handler({ message = 'the language server refused the request' }, nil); return function() end end
  return function() pcall(client.cancel_request, client, id) end
end

-- Waits (bounded) for a server that has a call hierarchy and is not busy indexing; says why it waits meanwhile.
-- done(client, note) or done(nil, why). Returns a function that stops the wait.
function M.ready(buf, done, waiting)
  local deadline, grace, stopped, said = uv.now() + M.WAIT_MS, uv.now() + M.GRACE_MS, false, false
  local function tick()
    if stopped then return end
    if not api.nvim_buf_is_valid(buf) then return done(nil, 'the file was closed') end
    local client = M.clients(buf)[1]
    local others = M.attached(buf)
    if client and not M.busy(client) then return done(client) end
    if not client and #others > 0 then
      local names = table.concat(vim.tbl_map(function(c) return c.name end, others), ', ')
      return done(nil, 'no language server here has a call hierarchy (' .. names .. ')')
    end
    -- A server started some other way than vim.lsp.enable (a plugin, vim.lsp.start) gets two seconds to attach.
    if not client and not M.expected(buf) and uv.now() >= grace then
      return done(nil, 'no language server is set up for ' .. (vim.bo[buf].filetype ~= '' and vim.bo[buf].filetype or 'this file'))
    end
    if uv.now() >= deadline then
      if client then return done(client, 'the language server was still indexing; callers may be missing') end
      return done(nil, 'the language server did not start in ' .. math.floor(M.WAIT_MS / 1000) .. ' seconds')
    end
    if not said and waiting then said = true; waiting('waiting for the language server…') end
    vim.defer_fn(tick, 200)
  end
  tick()
  return function() stopped = true end
end

function M.item(raw, enc)
  local range = raw.selectionRange or raw.range
  local file = vim.uri_to_fname(raw.uri)
  return { name = raw.name, detail = vim.fn.fnamemodify(file, ':t') .. ':' .. (range.start.line + 1), uri = raw.uri,
           range = range, enc = enc, raw = raw }
end

local function calls(list, field, enc)
  local out, seen = {}, {}
  for _, call in ipairs(list or {}) do
    local raw = call[field]
    local key = raw and (raw.uri .. ':' .. raw.name .. ':' .. (raw.selectionRange or raw.range).start.line)
    if raw and not seen[key] then seen[key] = true; out[#out + 1] = M.item(raw, enc) end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  local more = math.max(0, #out - M.MAX)
  while #out > M.MAX do table.remove(out) end
  return out, more
end

-- The graph of target ({buf, row, col} or {buf, item}); one request in flight at a time, in turn. done(graph) or
-- done(nil, why). Returns a function that cancels what is in flight.
function M.fetch(client, target, done)
  local enc, buf = client.offset_encoding or 'utf-16', target.buf
  local cancel, cancelled = function() end, false
  local function step(method, params, next_step)
    cancel = M.transport(client, buf, method, params, function(err, result)
      if cancelled then return end
      vim.schedule(function()
        if cancelled then return end
        if err then return done(nil, 'the language server failed: ' .. tostring(err.message or err)) end
        next_step(result)
      end)
    end)
  end
  local function from(raw)
    local graph = { center = M.item(raw, enc) }
    step('callHierarchy/incomingCalls', { item = raw }, function(incoming)
      local more = {}
      graph.callers, more.callers = calls(incoming, 'from', enc)
      step('callHierarchy/outgoingCalls', { item = raw }, function(outgoing)
        graph.callees, more.callees = calls(outgoing, 'to', enc)
        graph.more = more
        done(graph)
      end)
    end)
  end
  if target.item then from(target.item.raw)
  else
    local line = api.nvim_buf_get_lines(buf, target.row, target.row + 1, false)[1] or ''
    local ok, character = pcall(vim.str_utfindex, line, enc, target.col, false)
    local params = { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = { line = target.row, character = ok and character or target.col } }
    step(PREPARE, params, function(items)
      if type(items) ~= 'table' or not items[1] then return done(nil, 'the language server knows no function here') end
      from(items[1])
    end)
  end
  return function() cancelled = true; cancel() end
end

-- What symdeps adds, for C and C++: its own card on the centre (every use by role) when it is loaded.
local function symdeps_state(buf)
  local ft = api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype
  if ft ~= 'c' and ft ~= 'cpp' then return nil end
  return (package.loaded['fox-symdeps'] or pcall(require, 'fox-symdeps')) and 'loaded' or 'missing'
end

-- An item from the language server goes to its range; the centre drawn before the answer, to where it was asked.
local function jump(item, win)
  if win and api.nvim_win_is_valid(win) then api.nvim_set_current_win(win) end
  if item.uri and item.range then
    vim.lsp.util.show_document({ uri = item.uri, range = item.range }, item.enc or 'utf-16', { focus = true })
  elseif item.buf and api.nvim_buf_is_valid(item.buf) and item.row then
    api.nvim_win_set_buf(0, item.buf)
    pcall(api.nvim_win_set_cursor, 0, { item.row + 1, item.col or 0 })
  end
end
local function placeholder(target)
  return { name = target.name, detail = vim.fn.fnamemodify(api.nvim_buf_get_name(target.buf), ':t') .. ':' .. (target.row + 1),
           buf = target.buf, row = target.row, col = target.col }
end

-- ─── the graph view (one tab, reused) ──────────────────────────────────────────────────────────────────────────
-- Like the review: Enter goes to a function in the code window the graph came from and the tab stays open behind it,
-- Backspace goes back to that window as it was, and Space cc from anywhere brings the same tab back on the function
-- under the cursor (walking a call chain is Enter on a callee, then Space cc there).
local views = {}

local function render(view)
  if not api.nvim_win_is_valid(view.win) then return end
  local graph = vim.deepcopy(view.graph)
  graph.notes = graph.notes or {}
  local symdeps = symdeps_state(view.source)
  if symdeps == 'missing' then graph.notes[#graph.notes + 1] = 'every use by role: requires symdeps' end
  graph.keys = vim.deepcopy(M.VIEW_KEYS)
  if symdeps == 'loaded' then table.insert(graph.keys, #graph.keys, { M.typed('symdeps'), 'symdeps' }) end
  show(view, M.layout(graph, api.nvim_win_get_width(view.win) - 2, M.retro()))
end

local function load(view, target)
  if view.cancel then view.cancel() end
  view.graph = { center = target.item or placeholder(target), message = 'reading the call hierarchy…' }
  render(view)
  local stop_fetch
  local stop_wait = M.ready(target.buf, function(client, why)
    if not client then view.graph = { center = view.graph.center, message = why }; return render(view) end
    stop_fetch = M.fetch(client, target, function(graph, err)
      view.cancel = nil
      view.graph = graph or { center = view.graph.center, message = err }
      if graph and why then graph.notes = { why } end
      render(view)
    end)
  end, function(message) view.graph = { center = view.graph.center, message = message }; render(view) end)
  view.cancel = function() stop_wait(); if stop_fetch then stop_fetch() end end
end

function M.close_view(buf)
  local view = views[buf]
  if view and view.cancel then view.cancel() end
  views[buf] = nil
  if vim.g.desk_work_view then vim.cmd('confirm qall'); return end
  if view and api.nvim_win_is_valid(view.win) then
    if #api.nvim_list_tabpages() > 1 then pcall(vim.cmd, 'tabclose ' .. api.nvim_tabpage_get_number(api.nvim_win_get_tabpage(view.win)))
    else pcall(api.nvim_win_close, view.win, true) end
  end
end

-- The graph tab, while it is open.
function M.view()
  for buf, view in pairs(views) do
    if api.nvim_buf_is_valid(buf) and api.nvim_win_is_valid(view.win) and api.nvim_win_get_buf(view.win) == buf then return view end
  end
end

-- Whether the view shows target's function already: the same place in the same file.
local function showing(view, target)
  local center = view.graph and view.graph.center
  if not center then return false end
  if center.uri and center.range then return center.uri == vim.uri_from_bufnr(target.buf) and center.range.start.line == target.row end
  return center.buf == target.buf and center.row == target.row
end

-- Opens the graph of target (a symbol from M.symbol_at, or {buf, item}): in the graph tab when there is one (only
-- switching to it when it shows that function already), else in a new tab.
function M.open(target)
  highlights()
  local origin = api.nvim_get_current_win()
  local open = M.view()
  if open then
    if origin ~= open.win then open.origin = origin end
    api.nvim_set_current_win(open.win)
    if showing(open, target) then return open end
    open.source, open.target = target.buf, target
    pcall(api.nvim_buf_set_name, open.buf, 'call graph · ' .. (target.name or target.item and target.item.name or '') .. ' · ' .. open.buf)
    load(open, target)
    return open
  end
  vim.cmd('tabnew')
  local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  vim.bo[buf].filetype = 'deskcallgraph'
  pcall(api.nvim_buf_set_name, buf, 'call graph · ' .. (target.name or target.item and target.item.name or '') .. ' · ' .. buf)
  for opt, value in pairs({ number = false, relativenumber = false, signcolumn = 'no', wrap = false, list = false, spell = false, cursorline = false }) do
    vim.wo[win][opt] = value
  end
  local view = { buf = buf, win = win, origin = origin, source = target.buf }
  views[buf] = view
  bind_selection(view, 'callgraph')
  api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function()
    if views[buf] and views[buf].cancel then views[buf].cancel() end
    views[buf] = nil
  end })
  view.target = target
  load(view, target)
  return view
end

function M.open_cursor()
  local buf, cursor = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)
  local target, why = M.symbol_at(buf, cursor[1] - 1, cursor[2])
  if not target then tell(why:sub(1, 1):upper() .. why:sub(2) .. '.'); return end
  return M.open(target)
end

-- From the notebook: desk-work opens nvim on the file with the symbol's line.
function M.open_at(path, line)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = api.nvim_get_current_buf()
  line = math.max(1, math.min(tonumber(line) or 1, api.nvim_buf_line_count(buf)))
  local text = api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ''
  api.nvim_win_set_cursor(0, { line, (text:find('%S') or 1) - 1 })
  return M.open_cursor()
end

-- ─── the live panel ────────────────────────────────────────────────────────────────────────────────────────────
-- A narrow split on the right that follows the cursor: after it rests, and only when the function around it changed.
-- Answers are cached per symbol until its file is saved; one request is in flight at a time; an answer for a symbol
-- the cursor has left is kept in the cache and not drawn. It never takes the focus.
local panel = { cache = {} }
M.panel = panel

local function panel_open() return panel.win and api.nvim_win_is_valid(panel.win) end
local function followed(win)
  if not api.nvim_win_is_valid(win) or win == panel.win or api.nvim_win_get_config(win).relative ~= '' then return false end
  local buf = api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == '' and vim.b[buf].desk_callgraph == nil
end

-- keep: the same graph again (pinning, unpinning), so the selection stays.
local function panel_show(graph, keep)
  if not panel_open() then return end
  panel.graph = graph
  local drawn = vim.tbl_extend('force', {}, graph, { keys = M.panel_keys(panel.pinned), header = panel.pinned and 'PINNED' or nil })
  show(panel, M.layout(drawn, api.nvim_win_get_width(panel.win) - 1, M.retro()), keep)
end

local function cache_key(t) return vim.uri_from_bufnr(t.buf) .. '\0' .. t.name .. '\0' .. t.row end

local function panel_request()
  if panel.inflight or not panel.wanted then return end
  local target = panel.wanted
  panel.wanted = nil
  local cached = panel.cache[cache_key(target)]
  if cached then if panel.key == target.key then panel_show(cached) end; return end
  panel.inflight = target
  local center = placeholder(target)
  local function finish(graph)
    panel.inflight, panel.stop = nil, nil
    panel.cache[cache_key(target)] = graph
    if panel.key == target.key then panel_show(graph) end
    panel_request()
  end
  local stop_fetch
  local stop_wait = M.ready(target.buf, function(client, why)
    if not client then return finish({ center = center, message = why, refused = true }) end
    stop_fetch = M.fetch(client, target, function(graph, err)
      if graph and why then graph.notes = { why } end
      finish(graph or { center = center, message = err })
    end)
  end, function(message) if panel.key == target.key then panel_show({ center = center, message = message }) end end)
  panel.stop = function() stop_wait(); if stop_fetch then stop_fetch() end end
end

-- Where the cursor is now in the followed window: draws from the cache, or asks. Pinned, the panel stays put.
function M.panel_update()
  if not panel_open() or panel.pinned then return end
  local win = panel.source_win
  if not win or not followed(win) then return end
  local buf, cursor = api.nvim_win_get_buf(win), api.nvim_win_get_cursor(win)
  M.with_tree(buf, function(tree)
    if not panel_open() or not api.nvim_buf_is_valid(buf) then return end
    local target, why = M.symbol_in(tree, buf, cursor[1] - 1, cursor[2])
    if not tree then target, why = nil, 'no treesitter parser for this file type' end
    local key = target and target.key or ('none:' .. buf .. ':' .. why)
    if key == panel.key then return end
    panel.key, panel.target = key, target
    if not target then return panel_show({ message = why }) end
    local cached = panel.cache[cache_key(target)]
    if cached then panel.wanted = nil; return panel_show(cached) end
    panel_show({ center = placeholder(target), message = 'reading the call hierarchy…' })
    -- Back on the function already being asked about: its answer is on the way.
    if panel.inflight and panel.inflight.key == target.key then panel.wanted = nil; return end
    panel.wanted = target
    panel_request()
  end)
end

-- A cursor move in a window: the update waits for the cursor to rest. Pinned, only the window Enter goes to follows.
function M.panel_moved(win)
  if not panel_open() or not followed(win) then return end
  panel.source_win = win
  if panel.pinned then return end
  panel.timer = panel.timer or uv.new_timer()
  panel.timer:stop()
  panel.timer:start(M.DEBOUNCE_MS, 0, vim.schedule_wrap(M.panel_update))
end

function M.panel_forget(buf)
  local uri = vim.uri_from_bufnr(buf)
  for key in pairs(panel.cache) do if key:sub(1, #uri + 1) == uri .. '\0' then panel.cache[key] = nil end end
  if panel.key and panel.key:match('^' .. buf .. ':') or (panel.key or ''):match('^none:' .. buf .. ':') then panel.key = nil end
end

-- The pinned graph, read again once its own file is saved (or its server arrives): the same function, by the item
-- the server gave it when there is one, since a save can move its line.
function M.panel_refresh(buf)
  local target = panel.target
  if not (panel_open() and panel.pinned and target and target.buf == buf) then return end
  local center = panel.graph and panel.graph.center
  local again = center and center.raw and vim.tbl_extend('force', {}, target, { item = center }) or target
  panel.cache[cache_key(again)] = nil
  panel.key, panel.wanted = again.key, again
  if not (panel.inflight and panel.inflight.key == again.key) then panel_request() end
end

-- p: pinned, the panel keeps its graph while the cursor goes elsewhere; unpinned, it follows again from where the
-- cursor is now.
function M.panel_pin()
  if not panel_open() then return end
  panel.pinned = not panel.pinned
  if panel.pinned then
    if panel.timer then panel.timer:stop() end
    panel_show(panel.graph or { message = 'move the cursor into a function' }, true)
  else
    panel.key = nil
    panel_show(panel.graph or { message = 'move the cursor into a function' }, true)
    M.panel_update()
  end
end

function M.panel_close()
  if panel.stop then panel.stop() end
  if panel.timer then panel.timer:stop() end
  panel.inflight, panel.wanted, panel.stop, panel.key, panel.pinned, panel.target, panel.graph = nil, nil, nil, nil, false, nil, nil
  pcall(api.nvim_del_augroup_by_name, 'desk_callgraph_panel')
  if panel_open() then pcall(api.nvim_win_close, panel.win, true) end
  panel.win = nil
end

local function normal_windows(tab)
  local count = 0
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if win ~= panel.win and api.nvim_win_get_config(win).relative == '' then count = count + 1 end
  end
  return count
end

-- After a window closes: a panel left alone in its tab goes too (and Neovim with it, when nothing else is open).
function M.panel_alone()
  if not panel_open() then return end
  local tab = api.nvim_win_get_tabpage(panel.win)
  if normal_windows(tab) > 0 then return end
  if #api.nvim_list_tabpages() > 1 then M.panel_close(); return end
  -- The last window there is: quitting it quits Neovim (refused, as ever, while a buffer is unsaved).
  api.nvim_set_current_win(panel.win)
  pcall(vim.cmd, 'quit')
end

function M.panel_toggle()
  if panel_open() then M.panel_close(); return end
  highlights()
  local source = api.nvim_get_current_win()
  panel.buf = api.nvim_create_buf(false, true)
  vim.bo[panel.buf].bufhidden, vim.bo[panel.buf].filetype = 'wipe', 'deskcallgraph'
  pcall(api.nvim_buf_set_name, panel.buf, 'call graph')
  panel.win = api.nvim_open_win(panel.buf, false, { split = 'right', win = -1, width = M.PANEL_WIDTH })
  panel.drawn, panel.index = nil, nil
  for opt, value in pairs({ number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0', wrap = false,
    list = false, spell = false, cursorline = false, winfixwidth = true, winfixbuf = true }) do
    pcall(function() vim.wo[panel.win][opt] = value end)
  end
  bind_selection(panel, 'callgraph-panel')
  local group = api.nvim_create_augroup('desk_callgraph_panel', { clear = true })
  api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter', 'InsertLeave' }, { group = group,
    callback = function() M.panel_moved(api.nvim_get_current_win()) end })
  api.nvim_create_autocmd('BufWritePost', { group = group, callback = function(a)
    M.panel_forget(a.buf)
    M.panel_refresh(a.buf)
    M.panel_moved(api.nvim_get_current_win())
  end })
  api.nvim_create_autocmd('LspAttach', { group = group, callback = function(a)
    M.panel_forget(a.buf)
    M.panel_refresh(a.buf)
    if panel.source_win and followed(panel.source_win) then M.panel_moved(panel.source_win) end
  end })
  -- :q on the last window beside the panel quits as if the panel were not there.
  api.nvim_create_autocmd('QuitPre', { group = group, callback = function()
    if not panel_open() then return end
    local tab = api.nvim_get_current_tabpage()
    if api.nvim_win_get_tabpage(panel.win) == tab and api.nvim_get_current_win() ~= panel.win and normal_windows(tab) <= 1 then M.panel_close() end
  end })
  api.nvim_create_autocmd('WinClosed', { group = group, callback = function(a)
    if tonumber(a.match) == panel.win then vim.schedule(M.panel_close) else vim.schedule(M.panel_alone) end
  end })
  panel_show({ message = 'move the cursor into a function' })
  if followed(source) then panel.source_win = source; M.panel_update() end
end

-- ─── a turn's changed symbols (run headless for the notebook) ──────────────────────────────────────────────────
-- request: { root, files = { { rel, before? } } }; a file with no before is compared with HEAD.
local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  return text
end

function M.turn_symbols(request)
  local R = require('desk.review')
  local root, out = request.root, {}
  if type(root) ~= 'string' or root:sub(1, 1) ~= '/' then return { version = 1, files = out } end
  for i, entry in ipairs(request.files or {}) do
    if i > 20 then break end
    local rel = entry.rel
    if type(rel) == 'string' and rel ~= '' and rel:sub(1, 1) ~= '/' and not ('/' .. rel .. '/'):find('/%.%./') then
      local after = read(root .. '/' .. rel) or ''
      local before = type(entry.before) == 'string' and entry.before or nil
      if not before then
        local ran = vim.system({ 'git', '--no-optional-locks', '-C', root, 'show', 'HEAD:' .. rel }, { text = true }):wait(2000)
        before = ran.code == 0 and ran.stdout or ''
      end
      if #after < 1024 * 1024 and #before < 1024 * 1024 and not after:find('\0', 1, true) and not before:find('\0', 1, true) then
        local diff = vim.text and vim.text.diff or vim.diff
        local ok, hunks = pcall(diff, before, after, { result_type = 'indices', algorithm = 'histogram', linematch = 60 })
        local file = { rel = rel, left = before, right = after, hunks = ok and hunks or {}, signature = vim.fn.sha256(before .. '\0' .. after) }
        local symbols = {}
        for _, s in ipairs(R.changed_symbols(file)) do
          symbols[#symbols + 1] = { name = s.name, kind = s.kind, side = s.side, line = s.line }
        end
        out[#out + 1] = { rel = rel, symbols = symbols }
      end
    end
  end
  return { version = 1, files = out }
end

-- ─── the keys ──────────────────────────────────────────────────────────────────────────────────────────────────
-- Rows of the action registry (desk/actions.lua): the mappings, which-key's words, the home menu, the keybinds
-- reference and the pop-out's ? all read them. The graph tab is the 'callgraph' surface and the panel
-- 'callgraph-panel'; a run gets ctx.graph, the one it was pressed in. The key lines drawn in the graph take their keys
-- from these rows and keep their own words (M.typed).
local function go(s)
  local item = M.selected(s)
  if item then jump(item, s == panel and panel.source_win or s.origin) end
end
local GRAPH, BOTH = 'callgraph', { 'callgraph', 'callgraph-panel' }
local function moving(how, key, name, about, line, doc)
  return { id = 'callgraph.' .. how, group = 'Call graph', name = name, about = about, key = key, on = BOTH, menu = false,
    line = line and ('callgraph.' .. line) or nil, doc = doc, run = function(ctx) M.move(ctx.graph, how) end }
end
local ROWS = actions.add({
  { id = 'callgraph.open', group = 'This function', name = 'Call graph of this function', key = '<leader>cc', on = 'editor', remote = true,
    also = '`:CallGraph`',
    about = "Call graph of the function under the cursor, in a tab: callers above, the function in a double box, what it calls below (the language server's call hierarchy). It opens with the function's box selected. One tab: pressed again anywhere, it brings that tab back on the function under the cursor",
    -- In the graph itself its own keys are the ones that apply.
    available = function(ctx) return (ctx.surface ~= 'callgraph' and ctx.surface ~= 'callgraph-panel') or false end,
    run = function() M.open_cursor() end },
  { id = 'callgraph.panel', group = 'This function', name = 'Live call graph panel', key = '<leader>co', on = 'editor', remote = true,
    also = '`:CallGraphPanel`',
    about = 'Live call graph panel: a narrow split on the right that follows the cursor and redraws when the function under it changes. It never takes the focus (`Ctrl+w l` goes into it); `p` in it pins it to the graph it shows (`PINNED`), `p` again follows the cursor',
    run = function() M.panel_toggle() end },
  moving('down', 'j', 'The box below', 'The box below, the nearest one in that row', nil, 'The box below / above (the nearest one in that row)'),
  moving('up', 'k', 'The box above', 'The box above, the nearest one in that row', 'down'),
  moving('left', 'h', 'The box to the left', 'The box to the left in the same row', nil, 'The box to the left / right in the same row'),
  moving('right', 'l', 'The box to the right', 'The box to the right in the same row', 'left'),
  moving('next', '<Tab>', 'The next box', 'The next box, every box in order, wrapping', nil, 'Every box in order, wrapping; the first / last box'),
  moving('prev', '<S-Tab>', 'The previous box', 'The previous box, wrapping', 'next'),
  moving('first', 'gg', 'The first box', 'The first box', 'next'),
  moving('last', 'G', 'The last box', 'The last box', 'next'),
  { id = 'callgraph.go', group = 'Call graph', name = 'Go to the selected function', key = '<CR>', on = BOTH, also = 'a double click',
    about = "Go to the selected box's function, in the code window the graph came from; the graph stays open (a click, or any motion that lands in a box, selects it)",
    run = function(ctx) go(ctx.graph) end },
  { id = 'callgraph.go-mouse', group = 'Call graph', name = 'Go to the function clicked', key = '<2-LeftMouse>', on = BOTH, line = 'callgraph.go',
    menu = false, doc = false,
    run = function(ctx)
      local s, pos = ctx.graph, vim.fn.getmousepos()
      if pos.winid == s.win and (pos.line or 0) > 0 then
        local index = M.box_at(s.drawn, pos.line, math.max(0, (pos.column or 1) - 1))
        if index then M.select(s, index, false) end
      end
      go(s)
    end },
  { id = 'callgraph.back', group = 'Call graph', name = 'Back to the code, the graph left open', key = '<BS>', on = GRAPH,
    about = 'Back to that code window as it was, the graph left open',
    run = function(ctx)
      if api.nvim_win_is_valid(ctx.graph.origin) then api.nvim_set_current_win(ctx.graph.origin)
      elseif #api.nvim_list_tabpages() > 1 then vim.cmd('tabprevious') end
    end },
  { id = 'callgraph.centre', group = 'Call graph', name = 'Centre the graph on the selected function', key = 'c', on = GRAPH,
    about = 'Centre the graph on the selected box: its own callers and callees',
    run = function(ctx)
      local view, item = ctx.graph, M.selected(ctx.graph)
      if item and item.raw then view.target = { buf = view.source, item = item, name = item.name }; load(view, view.target) end
    end },
  { id = 'callgraph.reload', group = 'Call graph', name = 'Read the graph again', key = 'r', on = GRAPH,
    about = 'Ask the language server for the graph again', run = function(ctx) load(ctx.graph, ctx.graph.target) end },
  { id = 'callgraph.close', group = 'Call graph', name = 'Close the call graph', key = 'q', on = GRAPH, about = 'Close the graph tab',
    run = function(ctx) M.close_view(ctx.graph.buf) end },
  { id = 'callgraph.symdeps', group = 'Call graph', name = 'This function in symdeps', key = 's', on = GRAPH,
    about = "The centre function in symdeps' card (C and C++)",
    available = function() return actions.symdeps() or 'requires symdeps' end,
    run = function(ctx)
      local view = ctx.graph
      local center = view.graph and view.graph.center
      if not center or not center.uri then return end
      local loaded, plugin = pcall(require, 'fox-symdeps')
      if not loaded then tell('Requires symdeps (an optional plugin for C and C++ symbols).'); return end
      local ok, card = pcall(require, 'fox-symdeps.card')
      local inspect = ok and type(card) == 'table' and type(card.inspect_cursor) == 'function' and card.inspect_cursor
        or type(plugin) == 'table' and type(plugin.inspect_cursor) == 'function' and plugin.inspect_cursor or nil
      if not inspect then tell('This symdeps version does not expose its card.'); return end
      jump(center, view.origin)
      inspect()
    end },
  { id = 'callgraph.pin', group = 'Call graph', name = 'Pin the panel to this graph, or follow again', key = 'p', on = 'callgraph-panel',
    about = 'Pin the panel to the graph it shows (PINNED), or follow the cursor again', run = function() M.panel_pin() end },
  { id = 'callgraph.panel-close', group = 'Call graph', name = 'Close the call graph panel', key = 'q', on = 'callgraph-panel',
    about = 'Close the panel', run = function() M.panel_close() end },
})

-- The keys a key line shows for these rows, as typed ("j/k/h/l", "Enter", "BS").
function M.typed(...)
  local keys = {}
  for _, id in ipairs({ ... }) do
    local key = actions.key('callgraph.' .. id)
    keys[#keys + 1] = key == '<CR>' and 'Enter' or key == '<BS>' and 'BS' or key
  end
  return table.concat(keys, '/')
end
M.VIEW_KEYS = { { M.typed('down', 'up', 'left', 'right'), 'move' }, { M.typed('go'), 'go' }, { M.typed('back'), 'back' },
  { M.typed('centre'), 'centre' }, { M.typed('reload'), 'reload' }, { M.typed('close'), 'close' } }
function M.panel_keys(pinned)
  return { { M.typed('down', 'up', 'left', 'right'), 'move' }, { M.typed('go'), 'go' }, { M.typed('pin'), pinned and 'unpin' or 'pin' },
    { M.typed('panel-close'), 'close' } }
end

-- ─── setup ─────────────────────────────────────────────────────────────────────────────────────────────────────
local set = false
function M.setup()
  if set then return end
  set = true
  -- A restarted server has a new id, so work a stopped one never finished is not waited on.
  api.nvim_create_autocmd('LspProgress', { group = api.nvim_create_augroup('desk_callgraph', { clear = true }), callback = function(a)
    local data = a.data or {}
    local value, token = data.params and data.params.value, data.params and data.params.token
    if not data.client_id or type(value) ~= 'table' or token == nil then return end
    busy[data.client_id] = busy[data.client_id] or {}
    if value.kind == 'begin' then busy[data.client_id][token] = true elseif value.kind == 'end' then busy[data.client_id][token] = nil end
  end })
  api.nvim_create_user_command('CallGraph', function() M.open_cursor() end, { desc = 'Call graph of the function under the cursor' })
  api.nvim_create_user_command('CallGraphPanel', function() M.panel_toggle() end, { desc = 'Live call graph beside the code' })
  actions.map('editor', { rows = ROWS })
end

-- nvim --headless --clean -l …/desk/callgraph.lua --turn-symbols < request.json: the notebook's changed symbols (the
-- top of this file put the modules beside it on package.path).
if headless then
  vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/site')
  local ok, request = pcall(vim.json.decode, io.read('*a') or '')
  local answered, result = pcall(M.turn_symbols, ok and type(request) == 'table' and request or {})
  io.stdout:write(vim.json.encode(answered and result or { version = 1, files = {} }) .. '\n')
end

return M
