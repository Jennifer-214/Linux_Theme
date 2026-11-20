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
M.WAIT_MS, M.GRACE_MS, M.DEBOUNCE_MS, M.PANEL_WIDTH = 15000, 2000, 300, 36

local function tell(text, level) vim.notify(text, level or vim.log.levels.INFO, { title = 'Call graph' }) end
local function width_of(s) return api.nvim_strwidth(s) end

-- ─── style ─────────────────────────────────────────────────────────────────────────────────────────────────────
-- Retro draws in a DOS font: code page 437 boxes, plain capitals. init.lua publishes the style in vim.g.desk_style.
function M.retro() return vim.g.desk_style == 'retro' end

-- said: the theme's voice (actions.voice): capitals in retro, but never a key or command between backticks.
function M.glyphs(retro)
  if retro then
    return { single = { tl = '┌', tr = '┐', bl = '└', br = '┘', h = '─', v = '│' },
             double = { tl = '╔', tr = '╗', bl = '╚', br = '╝', h = '═', v = '║' },
             down = '↓', ellipsis = '..', said = actions.voice(true) }
  end
  return { single = { tl = '╭', tr = '╮', bl = '╰', br = '╯', h = '─', v = '│' },
           double = { tl = '╔', tr = '╗', bl = '╚', br = '╝', h = '═', v = '║' },
           down = '↓', ellipsis = '…', said = actions.voice(false) }
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

-- Names fitted where they still differ (Codex's #5, 2026-11-18): a box clipped at its right edge made two long names
-- of one class read the same just where she had to choose. The selected box's strip keeps the whole name.
--- pure: a code name fitted to w columns, shortened where it still says the most: the qualifiers go first (from the
--- outside in: …::OrderBook::apply_insert(const Order&)), then the parameters' qualifiers (const, &, *), then the end.
function M.fit_name(name, w, ell)
  name = tostring(name or ''):gsub('[%c]', ' ')
  if width_of(name) <= w then return name end
  local base, params = name:match('^(.-)(%b())$')
  base, params = base or name, params or ''
  local parts = vim.split(base, '::', { plain = true })
  for drop = 1, #parts - 1 do
    local c = ell .. table.concat(vim.list_slice(parts, drop + 1), '::') .. params
    if width_of(c) <= w then return c end
  end
  local short = params:gsub('const%s+', ''):gsub('%s*[&*]+', ''):gsub('%s+', ' ')
  local last = parts[#parts]
  local lead = #parts > 1 and ell or ''
  if width_of(lead .. last .. short) <= w then return lead .. last .. short end
  return fit(lead .. last .. short, w, ell)
end

-- One way of naming in a drawing (the VM pass, 2026-11-19): clangd names a function without its namespace or class
-- ("one"), the project map with them ("eng::two"), and a graph mixes both. A box says the short one; the key line
-- and Enter keep the whole name.
local function short_name(name)
  local base, params = name:match('^(.-)(%b())$')
  base, params = base or name, params or ''
  local depth, cut = 0, nil
  for i = 1, #base do
    local ch = base:sub(i, i)
    if ch == '<' then depth = depth + 1 elseif ch == '>' then depth = depth - 1
    elseif depth == 0 and base:sub(i, i + 1) == '::' then cut = i + 2 end
  end
  return cut and (base:sub(cut) .. params) or name
end
--- pure: the names of one drawing, each short, except where two would read the same: those keep the whole name.
function M.short_names(names)
  local out, count = {}, {}
  for i, n in ipairs(names) do out[i] = short_name(tostring(n or '')) end
  for i, n in ipairs(out) do count[n] = count[n] or {}; count[n][tostring(names[i] or '')] = true end
  for i, n in ipairs(out) do if vim.tbl_count(count[n]) > 1 then out[i] = tostring(names[i] or '') end end
  return out
end

--- pure: names of one row (siblings) each fitted, and where two would read the same, the part where they differ kept
--- instead: the end of each from a little before the first character they differ at.
function M.fit_names(names, w, ell)
  local out = {}
  for i, n in ipairs(names) do out[i] = M.fit_name(n, w, ell) end
  for i = 1, #names do
    for j = i + 1, #names do
      if out[i] == out[j] and names[i] ~= names[j] then
        local a, b = names[i], names[j]
        local k = 1
        while k <= math.min(#a, #b) and a:sub(k, k) == b:sub(k, k) do k = k + 1 end
        -- from the start of the word they differ in
        local from = k
        while from > 1 and a:sub(from - 1, from - 1):match('[%w_]') do from = from - 1 end
        for _, idx in ipairs({ i, j }) do
          local n = names[idx]
          local method = n:match('([%w_~]+)%b()$') or n:match('([%w_~]+)$') or ''
          local tail = n:sub(from)
          local c = ell .. method .. '(' .. tail
          if tail:find('^' .. vim.pesc(method)) or not n:find('%(') then c = ell .. tail end
          out[idx] = fit(c, w, ell)
        end
      end
    end
  end
  return out
end

--- pure: file details of one drawing, where two different files share a name (feed/queue.hpp, replay/queue.hpp): the
--- folders that tell them apart added. items = { { file, line } } → the details "queue.hpp:40", "feed/queue.hpp:40".
function M.details(items)
  local out, by = {}, {}
  for i, it in ipairs(items) do
    local base = vim.fs.basename(it.file or '')
    by[base] = by[base] or {}
    by[base][it.file] = true
    out[i] = base
  end
  for i, it in ipairs(items) do
    local base = out[i]
    if vim.tbl_count(by[base]) > 1 then
      local parts = vim.split(it.file, '/', { plain = true, trimempty = true })
      for depth = 2, #parts do
        local label = table.concat(vim.list_slice(parts, #parts - depth + 1), '/')
        local clash = false
        for other in pairs(by[base]) do
          if other ~= it.file then
            local op = vim.split(other, '/', { plain = true, trimempty = true })
            if table.concat(vim.list_slice(op, #op - depth + 1), '/') == label then clash = true end
          end
        end
        out[i] = label
        if not clash then break end
      end
    end
    out[i] = out[i] .. (it.line and (':' .. it.line) or '')
  end
  return out
end


M.GAUGE_WIDTH = 7
M.NARROW = 56   -- the layout's width (the window's less its margin) under which boxes drop their places
function M.gauge_range(boxes)
  local first, last
  for _, box in ipairs(boxes) do
    if box.gauge then first, last = first or box.line, box.line end
  end
  if first then return { first, last } end
end

function M.gauge(drawn, bands, retro, group, active_group)
  local rail, offsets, active = {}, {}, {}
  local selectable = {}
  for _, band in ipairs(bands) do
    local shade = retro and ({ '█', '▓', '▒', '░' })[math.min(4, math.abs(band.level) + 1)] or '│'
    local label = band.label or (band.level == 0 and '0' or string.format('%+d', band.level))
    local marker = band.active and not retro and '‹' or ' '
    if retro and band.active then shade = '█' end
    for line = band.first, band.last do
      rail[line] = marker .. shade .. ' ' .. pad(line == band.first and fit(label, 3, retro and '..' or '…') or '', 3) .. ' '
      selectable[line] = not band.label and band or nil
      if retro and band.active then active[line] = true end
    end
  end
  -- The rail beside the drawing, not at the window's edge (Codex's #1, 2026-11-18: on a wide monitor matching "+3" to
  -- its box took a trip across the screen): it starts two columns left of the leftmost thing drawn, the drawing as
  -- far right as before, so every line keeps its width and every column past the rail moves by the rail alone.
  -- Measured on the lines the rail runs along (a wider heading above them does not push it out); a line that starts
  -- further left keeps its text, the rail's width inserted before it.
  local shift
  for i, line in ipairs(drawn.lines) do
    if rail[i] and line:find('%S') then shift = math.min(shift or math.huge, #line:match('^ *')) end
  end
  shift = math.max(0, (shift or 0) - 2)
  drawn.gauge_col = shift
  for i, line in ipairs(drawn.lines) do
    local prefix = rail[i] or string.rep(' ', M.GAUGE_WIDTH)
    local cut = math.min(shift, #line:match('^ *'))
    offsets[i], drawn.lines[i] = #prefix, line:sub(1, cut) .. prefix .. line:sub(cut + 1)
  end
  for _, m in ipairs(drawn.marks) do m[2], m[3] = m[2] + offsets[m[1]], m[3] + offsets[m[1]] end
  for line, hits in pairs(drawn.hits or {}) do
    for _, hit in ipairs(hits) do hit.s, hit.e = hit.s + offsets[line], hit.e + offsets[line] end
  end
  for _, box in ipairs(drawn.boxes) do
    local band = selectable[box.line]
    box.gauge = band ~= nil
    box.gauge_col = shift
    if band then box.gauge_band = { band.first, band.last } end
    box.x, box.name_col = box.x + M.GAUGE_WIDTH, box.name_col + offsets[box.line]
    for _, span in ipairs(box.spans) do span[2], span[3] = span[2] + offsets[span[1]], span[3] + offsets[span[1]] end
  end
  for i, prefix in pairs(rail) do drawn.marks[#drawn.marks + 1] = { i, shift, shift + #prefix, group or 'DeskCallGraphDim' } end
  for i in pairs(active) do drawn.marks[#drawn.marks + 1] = { i, shift + 1, shift + 1 + #'█', active_group or 'DeskCallGraphCentre', 1 } end
end

local SIDES = { 'callers', 'callees' }
local function layers_of(graph, side)
  return (graph.layers or {})[side] or (graph[side] and { graph[side] } or {})
end

--- pure: the side whose outermost level holds `item` (where > can unfold it), and that level's depth; nil when it
--- is the centre or on a level with more below it.
function M.edge_of(graph, item)
  for _, side in ipairs(SIDES) do
    local tiers = (graph.layers or {})[side] or (graph[side] and { graph[side] }) or {}
    local last = tiers[#tiers]
    for _, it in ipairs(last or {}) do if it == item then return side, #tiers end end
  end
end
local function identity(item)
  local start = item.range and item.range.start
  if start and item.uri then return table.concat({ item.uri, start.line, item.name or '' }, '\0') end
  return item.map_id or tostring(item.name or '')
end
-- Who calls whom between two levels, as each level is read (a level keeps each function once, at its nearest depth,
-- so the rows alone cannot say which box below belongs to which above): graph.links[a][b], both ways.
local function link(graph, a, b)
  local x, y = identity(a), identity(b)
  if x == y then return end
  graph.links = graph.links or {}
  graph.links[x] = graph.links[x] or {}
  graph.links[y] = graph.links[y] or {}
  graph.links[x][y], graph.links[y][x] = true, true
end
M._link = link
-- Where a caller calls a callee (Codex's E7): the call's place as the language server gave it (its fromRanges, in the
-- caller's file), the first and how many, kept per pair as each level is read.
local function site(graph, caller, callee, uri, ranges)
  if not (uri and type(ranges) == 'table' and ranges[1] and ranges[1].start) then return end
  graph.sites = graph.sites or {}
  local key = identity(caller) .. '\1' .. identity(callee)
  local got = graph.sites[key] or { uri = uri, line = ranges[1].start.line + 1, count = 0 }
  got.count = got.count + #ranges
  graph.sites[key] = got
end
M._site = site

-- ─── layout (pure) ─────────────────────────────────────────────────────────────────────────────────────────────
-- graph: { center = item?, callers = {item}?, callees = {item}?, more = {callers, callees}?, message = text?,
--          notes = {text}?, keys = {{key, words, more?}}? (the key line, last; more: only while something is left
--          out), header = text? (first) }
-- item: { name, detail, uri?, range?, enc? }. Returns the lines, the highlights and the boxes in reading order
-- (callers row by row, the centre, callees row by row), each with its role (caller, centre, callee), its top line, the
-- line its name is on (line), its byte span on each of its four lines, where its name starts and its column and width
-- on screen. Every box is drawn (2026-11-19: "+N more" and m went, the page scrolls); boxes flow left to right, wrap
-- at `width`, and every row is centred.
function M.layout(graph, width, retro)
  width = math.max(16, width or 80)
  local G = M.glyphs(retro)
  local lines, boxlist, marks, bands, heads = {}, {}, {}, {}, {}
  -- each level's heading and the boxes under it, for "where am I" once it has scrolled away (Codex's E8)
  local centre_name = graph.center and tostring(graph.center.name or '') or nil
  local function heading(label)
    return { line = #lines, text = centre_name and (G.said(label .. ' of ') .. centre_name) or G.said(label), of = G.said(' of '), first = #boxlist + 1 }
  end
  local function close_heading(h) h.last, h.last_line = #boxlist, #lines; heads[#heads + 1] = h end
  local gauge = graph.layers and width >= 36
  if gauge then width = width - M.GAUGE_WIDTH end
  local function add(text, group, from, to)
    lines[#lines + 1] = text
    if group then marks[#marks + 1] = { #lines, from or 0, to or #text, group } end
  end
  local function centred(text, group)
    text = fit(text, width, G.ellipsis)
    local left = string.rep(' ', math.max(0, math.floor((width - width_of(text)) / 2)))
    add(left .. text, group, #left, #left + #text)
  end
  -- a file name two different files share in this drawing gets the folders that tell them apart
  local where_of = {}
  do
    local all = {}
    local function take(item) if item and item.uri and item.uri:match('^file:') and item.range then all[#all + 1] = item end end
    take(graph.center)
    for _, side in ipairs(SIDES) do
      for _, tier in ipairs(layers_of(graph, side)) do for _, it in ipairs(tier) do take(it) end end
    end
    local said = M.details(vim.tbl_map(function(it) return { file = vim.uri_to_fname(it.uri), line = it.range.start.line + 1 } end, all))
    for i, it in ipairs(all) do
      if said[i]:find('/', 1, true) then where_of[it] = said[i] end
    end
  end
  -- A narrow split (under M.NARROW columns, Codex's #8): a box keeps its name and drops its place (the key line says
  -- it for the selected box), unless two boxes share a name; the drawing says what it dropped.
  local narrow, dropped = width < M.NARROW, false
  local function boxes(items, frame, border, name_group, role)
    local built = {}
    local names = M.fit_names(M.short_names(vim.tbl_map(function(it) return it.name end, items)), width - 4, G.ellipsis)
    local twice = {}
    for _, n in ipairs(names) do twice[n] = (twice[n] or 0) + 1 end
    for k, item in ipairs(items) do
      local name, detail = names[k], fit(where_of[item] or item.detail or '', width - 4, G.ellipsis)
      if narrow and twice[name] == 1 and frame ~= G.double and detail ~= '' then detail, dropped = '', true end
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
        local box = { item = b.item, role = role, top = first, line = first + 1, w = b.w, spans = {}, centre = frame == G.double }
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
  local function group(label, items, none, role)
    if items == nil then return end
    centred(G.said(label .. (#items > 0 and (' · ' .. #items) or '')), 'DeskCallGraphHead')
    local h = heading(label)
    if #items == 0 then centred(G.said(none), 'DeskCallGraphDim') else boxes(items, G.single, 'DeskCallGraphBox', 'DeskCallGraphName', role) end
    close_heading(h)
  end
  local above, below = layers_of(graph, 'callers'), layers_of(graph, 'callees')
  local nearest, used = {}, {}
  if graph.center then used[identity(graph.center)] = true end
  if graph.layers then
    for _, tiers in ipairs({ above, below }) do
      for d, tier in ipairs(tiers) do
        for _, item in ipairs(tier) do
          local id = identity(item)
          nearest[id] = math.min(nearest[id] or d, d)
        end
      end
    end
    -- G.ellipsis: '..' in retro, which Big Blue Term draws (… is not code page 437; tests/test_retro_style.lua).
    centred(G.said(('layers %s ' .. G.ellipsis .. ' %s · %d functions'):format(#above == 0 and '0' or '-' .. #above,
      #below == 0 and '0' or '+' .. #below, vim.tbl_count(nearest) + (graph.center and 1 or 0)
        - (graph.center and nearest[identity(graph.center)] and 1 or 0))), 'DeskCallGraphHead')
  end
  -- Each level's own functions (each once, at its nearest depth), in the order they are drawn: callers deepest first,
  -- then callees.
  local function picked(side, list, depth)
    local items = list
    if graph.layers then
      items = {}
      for _, item in ipairs(list) do
        local id = identity(item)
        if not used[id] and nearest[id] == depth then used[id] = true; items[#items + 1] = item end
      end
    end
    return { items = items, depth = depth }
  end
  local up, down = {}, {}
  for d = #above, 1, -1 do up[d] = picked('callers', above[d], d) end
  for d, list in ipairs(below) do down[d] = picked('callees', list, d) end
  local function tier(side, level, sign, none, role)
    local first = #lines + 1
    local before = #boxlist
    group(level.depth == 1 and side or (side .. ' ' .. level.depth), level.items, none, role)
    for i = before + 1, #boxlist do boxlist[i].level = sign * level.depth end
    bands[#bands + 1] = { first = first, last = #lines, level = sign * level.depth }
  end
  -- A straight run (two or more levels in a row of one function each): one heading, then a row a
  -- function, names on one left edge, the rail counting depth (Codex's #2: five single-callee hops were five box
  -- stacks and five headings). Boxes stay where a level has a choice.
  local function single(level) return level and #level.items == 1 end
  local function chain(side, levels, sign, role)
    local built, wname, wdetail = {}, 1, 0
    local shorts = M.short_names(vim.tbl_map(function(level) return level.items[1].name end, levels))
    for k, level in ipairs(levels) do
      local item = level.items[1]
      local name, detail = M.fit_name(shorts[k], width - 6, G.ellipsis), where_of[item] or item.detail or ''
      wname = math.max(wname, width_of(name))
      built[#built + 1] = { item = item, name = name, detail = detail, level = level }
    end
    if narrow then
      for _, b in ipairs(built) do if b.detail ~= '' then dropped = true end; b.detail = '' end
    end
    for _, b in ipairs(built) do wdetail = math.max(wdetail, width_of(b.detail)) end
    local total = 2 + wname + (wdetail > 0 and (2 + wdetail) or 0)
    if total > width then wdetail = math.max(0, width - 4 - wname); total = math.min(width, 2 + wname + (wdetail > 0 and (2 + wdetail) or 0)) end
    local left = string.rep(' ', math.max(0, math.floor((width - total) / 2)))
    centred(G.said(side), 'DeskCallGraphHead')
    local h = heading(side)
    for _, b in ipairs(built) do
      local detail = wdetail > 0 and fit(b.detail, wdetail, G.ellipsis) or ''
      local text = left .. G.single.v .. ' ' .. pad(b.name, wname) .. (wdetail > 0 and ('  ' .. pad(detail, wdetail)) or '')
      add(text)
      local ln = #lines
      local s0, name_col = #left, #left + #G.single.v + 1
      marks[#marks + 1] = { ln, s0, s0 + #G.single.v, 'DeskCallGraphBox' }
      marks[#marks + 1] = { ln, name_col, name_col + #b.name, 'DeskCallGraphName', 1 }
      if detail ~= '' then
        local dc = name_col + #pad(b.name, wname) + 2
        marks[#marks + 1] = { ln, dc, dc + #detail, 'DeskCallGraphDim', 1 }
      end
      boxlist[#boxlist + 1] = { item = b.item, role = role, top = ln, line = ln, w = width_of(text) - #left, x = width_of(left),
        spans = { { ln, s0, #text } }, name_col = name_col, level = sign * b.level.depth, row = true }
      bands[#bands + 1] = { first = ln, last = ln, level = sign * b.level.depth }
    end
    close_heading(h)
  end
  -- the levels of one side, in drawing order, cut into runs and single levels
  local function pieces(levels, from, to, step)
    local out, d = {}, from
    while (step > 0 and d <= to) or (step < 0 and d >= to) do
      local run = {}
      while ((step > 0 and d <= to) or (step < 0 and d >= to)) and single(levels[d]) do run[#run + 1] = levels[d]; d = d + step end
      if #run >= 2 then out[#out + 1] = { run = run }
      elseif #run == 1 then out[#out + 1] = { level = run[1] }
      else out[#out + 1] = { level = levels[d] }; d = d + step end
    end
    return out
  end
  for i, piece in ipairs(pieces(up, #above, 1, -1)) do
    if i > 1 then centred(G.down, 'DeskCallGraphBox') end
    if piece.run then chain('callers', piece.run, -1, 'caller') else tier('callers', piece.level, -1, 'no callers found', 'caller') end
  end
  if graph.center then
    if #above > 0 then centred(G.down, 'DeskCallGraphBox') end
    local first = #lines + 1
    boxes({ graph.center }, G.double, 'DeskCallGraphCentre', 'DeskCallGraphCentre', 'centre')
    boxlist[#boxlist].level = 0
    bands[#bands + 1] = { first = first, last = #lines, level = 0 }
  end
  for i, piece in ipairs(pieces(down, 1, #below, 1)) do
    if graph.center or i > 1 then centred(G.down, 'DeskCallGraphBox') end
    if piece.run then chain('callees', piece.run, 1, 'callee') else tier('callees', piece.level, 1, 'calls nothing found', 'callee') end
  end
  if dropped then centred(G.said('narrow: places in the key line'), 'DeskCallGraphDim') end
  local drawn = { lines = lines, boxes = boxlist, marks = marks, heads = heads }
  M.neighbours(graph, boxlist)
  M.connect(graph, boxlist)
  if gauge then M.gauge(drawn, bands, retro); width = width + M.GAUGE_WIDTH end
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
      box.top, box.line = box.top + 1, box.line + 1
      for _, span in ipairs(box.spans) do span[1] = span[1] + 1 end
      local band = box.gauge_band
      if band then band[1], band[2] = band[1] + 1, band[2] + 1 end
    end
    marks[#marks + 1] = { 1, #left, #left + #text, 'DeskCallGraphKey', 1 }
  end
  if gauge then drawn.gauge_range = M.gauge_range(boxlist) end
  return drawn
end

--- pure: each box's real neighbours (box.near, indexes), when some level has more than one box (a wide graph, where the
--- nearest box in the next row can look like the callee and is not): the centre and its first level on each side,
--- and between deeper levels the calls read (graph.links). A narrow graph sets none (nothing to dim).
function M.neighbours(graph, boxlist)
  local per = {}
  for _, box in ipairs(boxlist) do if box.level then per[box.level] = (per[box.level] or 0) + 1 end end
  local wide = false
  for _, n in pairs(per) do if n > 1 then wide = true end end
  if not wide then return end
  -- by the calls read, not every pair of boxes (2026-11-19: 751 boxes took 537 ms, every pair's identity built)
  local links, ids, at = graph.links or {}, {}, {}
  for i, box in ipairs(boxlist) do
    ids[i] = identity(box.item)
    if box.level then
      local key = box.level .. '\1' .. ids[i]
      at[key] = at[key] or {}
      table.insert(at[key], i)
    end
  end
  local by_level = {}
  for i, box in ipairs(boxlist) do if box.level then by_level[box.level] = by_level[box.level] or {}; table.insert(by_level[box.level], i) end end
  for i, a in ipairs(boxlist) do
    local near = {}
    if a.level then
      for _, level in ipairs({ a.level - 1, a.level + 1 }) do
        if a.level == 0 or level == 0 then
          for _, j in ipairs(by_level[level] or {}) do near[#near + 1] = j end
        else
          for other in pairs(links[ids[i]] or {}) do
            for _, j in ipairs(at[level .. '\1' .. other] or {}) do near[#near + 1] = j end
          end
        end
      end
    end
    table.sort(near)
    a.near = near
  end
end

--- pure: each box's real calls, by direction (Codex's E7): box.down, the boxes it calls (the next level down the
--- drawing), box.up, those that call it, each with the call's place when one was read (down_sites, up_sites:
--- "e.cpp:15", or "e.cpp:122 · 2 calls"). The centre and its first level on each side always; deeper, the calls read
--- (graph.links). Every graph, wide or not; level by level, so 2500 boxes on one level are 2500 pairs, not millions.
function M.connect(graph, boxlist)
  -- by the calls read, not every pair on two levels (2026-11-19: 1801 boxes took 2.6 s)
  local links, sites, by_level, ids, at = graph.links or {}, graph.sites or {}, {}, {}, {}
  for i, box in ipairs(boxlist) do
    box.down, box.up, box.down_sites, box.up_sites = {}, {}, {}, {}
    ids[i] = identity(box.item)
    if box.level then
      by_level[box.level] = by_level[box.level] or {}; table.insert(by_level[box.level], i)
      local key = box.level .. '\1' .. ids[i]
      at[key] = at[key] or {}
      table.insert(at[key], i)
    end
  end
  local pairs_found = {}
  for level, list in pairs(by_level) do
    for _, i in ipairs(list) do
      if level == 0 or level + 1 == 0 then
        for _, j in ipairs(by_level[level + 1] or {}) do pairs_found[#pairs_found + 1] = { i, j } end
      else
        for other in pairs(links[ids[i]] or {}) do
          for _, j in ipairs(at[(level + 1) .. '\1' .. other] or {}) do pairs_found[#pairs_found + 1] = { i, j } end
        end
      end
    end
  end
  -- in box order, as the pair-by-pair walk gave them
  table.sort(pairs_found, function(x, y) if x[1] ~= y[1] then return x[1] < y[1] end return x[2] < y[2] end)
  local named = {}
  for _, pr in ipairs(pairs_found) do
    local i, j = pr[1], pr[2]
    local got = sites[ids[i] .. '\1' .. ids[j]]
    local said = ''
    if got then
      local file = named[got.uri]
      if not file then file = vim.fn.fnamemodify(vim.uri_to_fname(got.uri), ':t'); named[got.uri] = file end
      said = file .. ':' .. got.line .. (got.count > 1 and (' · ' .. got.count .. ' calls') or '')
    end
    local a, b = boxlist[i], boxlist[j]
    a.down[#a.down + 1], a.down_sites[#a.down + 1] = j, said
    b.up[#b.up + 1], b.up_sites[#b.up + 1] = i, said
  end
end

-- gj / gk (Codex's E7): to a function the selected box calls (down) or one that calls it (up), even rows away; again,
-- the next of them from the box it began on (wrapping), until another move. When the box it began on has only one
-- that way, again walks on from where it landed (a chain is walked, a branch is cycled). The call's place beside it.
local along_ns = api.nvim_create_namespace('desk_callgraph_along')
function M.along(s, dir)
  local boxes = s and s.drawn and s.drawn.boxes or {}
  if not (s.index and boxes[s.index]) then return end
  local st = s.along
  local cycling = st and st.dir == dir and st.at == s.index and boxes[st.anchor] and #(boxes[st.anchor][dir] or {}) > 1
  if not cycling then st = { anchor = s.index, dir = dir, pos = 0 } end
  local anchor = boxes[st.anchor]
  local list = anchor[dir] or {}
  if #list == 0 then return end
  st.pos = st.pos % #list + 1
  local j = list[st.pos]
  M.select(s, j, true)
  st.at, s.along = j, st
  local said = actions.voice(vim.g.desk_style == 'retro')
  local place = (anchor[dir .. '_sites'] or {})[st.pos] or ''
  local text = '  ' .. (dir == 'down' and '↓ ' or '↑ ') .. (place ~= '' and (said('called at ') .. place .. ' · ') or '')
    .. st.pos .. said(' of ') .. #list
  local box = boxes[j]
  if s.buf and api.nvim_buf_is_valid(s.buf) and box.line then
    pcall(api.nvim_buf_set_extmark, s.buf, along_ns, box.line - 1, 0, { virt_text = { { text, 'DeskCallGraphDim' } }, virt_text_pos = 'eol', priority = 300 })
  end
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
-- A row of boxes is the boxes whose names share a line, so a list of one-line rows (the pop-out's) moves the same way.
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
    return boxes[j] and boxes[j].line == here.line and j or index
  end
  local lines, seen = {}, {}
  for _, b in ipairs(boxes) do if not seen[b.line] then seen[b.line] = true; lines[#lines + 1] = b.line end end
  table.sort(lines)
  local row
  for i, line in ipairs(lines) do if line == here.line then row = i end end
  local want = lines[row + (how == 'down' and 1 or -1)]
  if not want then return index end
  local centre, best, gap = here.x + here.w / 2, index, math.huge
  for i, b in ipairs(boxes) do
    local d = b.line == want and math.abs(b.x + b.w / 2 - centre)
    if d and d < gap then best, gap = i, d end
  end
  return best
end

local function highlights()
  for name, link in pairs({ DeskCallGraphCentre = 'Title', DeskCallGraphBox = 'FloatBorder', DeskCallGraphName = 'Function',
    DeskCallGraphDim = 'Comment', DeskCallGraphHead = 'Comment', DeskCallGraphKey = 'Special', DeskCallGraphFaint = 'NonText' }) do
    api.nvim_set_hl(0, name, { link = link, default = true })
  end
  -- The selected box: inverse in retro (amber on black turned over, as a DOS list does), the selection colour elsewhere.
  api.nvim_set_hl(0, 'DeskCallGraphSelected', M.retro() and { reverse = true, default = true } or { link = 'Visual', default = true })
end
-- desk.popout sends these definitions with each view, so the pop-out draws in this editor's colours.
M.highlights = highlights

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
M.gauge_ns = api.nvim_create_namespace('desk_callgraph_gauge')
local edge_ns = api.nvim_create_namespace('desk_callgraph_gauge_edges')
--- pure: where the top line `top` is, once the heading it is under has scrolled away (Codex's E8): the heading's words
--- and, when it counts boxes, the first box on screen of how many ("callers of Submit · 17 of 43"); nil while the
--- heading is on screen or the top line is under none. drawn.heads: { line, last_line, text, of, first?, last?, count? }
--- (the graph's, the map's, the pop-out's copy of either).
function M.location(drawn, top)
  local best
  for _, h in ipairs(drawn and drawn.heads or {}) do
    -- the nearest heading above the top line that still covers it (a step inside a page's heading wins)
    if h.line < top and (h.last_line or h.line) >= top and (not best or h.line > best.line) then best = h end
  end
  if not best then return nil end
  local text = best.text
  if best.count ~= false and best.first and best.last and best.last >= best.first then
    for i = best.first, best.last do
      local b = drawn.boxes[i]
      if b and (b.line or 0) >= top then return text .. ' · ' .. (i - best.first + 1) .. (best.of or ' of ') .. (best.last - best.first + 1) end
    end
  end
  return text
end

function M.gauge_edges(s)
  local range = s and s.drawn and s.drawn.gauge_range
  local heads = s and s.drawn and s.drawn.heads and #s.drawn.heads > 0
  if not range and not heads and not (s and s.gauge_edges_drawn) then return end
  if not (s and s.win and api.nvim_win_is_valid(s.win) and api.nvim_win_get_buf(s.win) == s.buf) then return end
  api.nvim_buf_clear_namespace(s.buf, edge_ns, 0, -1)
  s.gauge_edges_drawn = nil
  local top, bottom = vim.fn.line('w0', s.win), vim.fn.line('w$', s.win)
  -- where you are, once the heading has scrolled away: over the right of the top line (the boxes are centred)
  local here = heads and M.location(s.drawn, top)
  if here then
    pcall(api.nvim_buf_set_extmark, s.buf, edge_ns, top - 1, 0, { virt_text = { { ' ' .. here .. ' ', 'DeskCallGraphDim' } },
      virt_text_pos = 'right_align', priority = 290 })
    s.gauge_edges_drawn = true
  end
  if not range then return end
  local selected = s.index and s.drawn.boxes[s.index]
  local col = s.drawn.gauge_col or (s.drawn.boxes[1] and s.drawn.boxes[1].gauge_col) or 0
  local function arrow(row, text)
    if row <= 0 or (selected and row == selected.line) then return end
    pcall(api.nvim_buf_set_extmark, s.buf, edge_ns, row - 1, col,
      { virt_text = { { text, 'DeskCallGraphDim' } }, virt_text_pos = 'overlay', priority = 290 })
    s.gauge_edges_drawn = true
  end
  if range[1] < top then arrow(top, '▲') end
  if range[2] > bottom then arrow(bottom, '▼') end
end

-- The dimming of a wide graph or map page (every box but the selected one and its real callers and callees) is drawn
-- by a decoration provider on the lines being drawn, never stored on the page: a page of every box re-dimmed 1500
-- boxes on each j, 55 ms a move, half a core in the pop-out (2026-11-19). faint_of: a buffer → its selection.
M.faint_ns = api.nvim_create_namespace('desk_callgraph_faint')
local faint_of = {}
--- pure: the spans to dim on lines first..last (1-based) of selection s, { { line, col, end_col } }; none when nothing
--- is selected on the page it shows (s.keep is the page's it was worked out on).
function M.faint_spans(s, first, last)
  local drawn = s and s.drawn
  if not (drawn and s.keep and s.keep_for == drawn) then return {} end
  local by_line = drawn.spans_by_line
  if not by_line then
    by_line = {}
    for j, b in ipairs(drawn.boxes or {}) do
      for _, span in ipairs(b.spans or {}) do
        local row = by_line[span[1]]
        if not row then row = {}; by_line[span[1]] = row end
        row[#row + 1] = { j, span[2], span[3] }
      end
    end
    drawn.spans_by_line = by_line
  end
  local out = {}
  for line = first, last do
    for _, sp in ipairs(by_line[line] or {}) do
      if not s.keep[sp[1]] then out[#out + 1] = { line, sp[2], sp[3] } end
    end
  end
  return out
end
api.nvim_set_decoration_provider(M.faint_ns, {
  on_win = function(_, _, buf) return faint_of[buf] ~= nil end,
  on_line = function(_, _, buf, row)
    for _, sp in ipairs(M.faint_spans(faint_of[buf], row + 1, row + 1)) do
      pcall(api.nvim_buf_set_extmark, buf, M.faint_ns, row, sp[2], { end_col = sp[3], hl_group = 'DeskCallGraphFaint', priority = 250, ephemeral = true })
    end
  end,
})
api.nvim_create_autocmd('BufWipeout', { group = api.nvim_create_augroup('desk_callgraph_faint', { clear = true }),
  callback = function(a) faint_of[a.buf] = nil end })

local function paint(s)
  if not api.nvim_buf_is_valid(s.buf) then return end
  -- Its colour, when no graph has been opened yet to define it (the map paints its boxes with it too).
  if next(api.nvim_get_hl(0, { name = 'DeskCallGraphSelected' })) == nil then highlights() end
  api.nvim_buf_clear_namespace(s.buf, M.sel_ns, 0, -1)
  api.nvim_buf_clear_namespace(s.buf, M.gauge_ns, 0, -1)
  api.nvim_buf_clear_namespace(s.buf, along_ns, 0, -1)   -- gj/gk's call place, gone with any other move
  local box = s.index and s.drawn and s.drawn.boxes[s.index]
  for _, span in ipairs(box and box.spans or {}) do
    pcall(api.nvim_buf_set_extmark, s.buf, M.sel_ns, span[1] - 1, span[2], { end_col = span[3], hl_group = 'DeskCallGraphSelected', priority = 300 })
  end
  -- A wide graph: the selected box's real callers and callees stay lit, every other box dims (drawn by the provider).
  if box and type(box.near) == 'table' then
    local keep = { [s.index] = true }
    for _, j in ipairs(box.near) do keep[j] = true end
    s.keep, s.keep_for, faint_of[s.buf] = keep, s.drawn, s
  else
    s.keep, s.keep_for = nil, nil
    if faint_of[s.buf] == s then faint_of[s.buf] = nil end
  end
  pcall(api.nvim__redraw, { buf = s.buf, valid = false })
  if box and box.gauge then
    if M.retro() then
      local band = box.gauge_band or { box.line, box.line }
      local opts = { virt_text = { { '█', 'Title' } }, virt_text_pos = 'overlay', priority = 300 }
      for line = band[1], math.min(band[2], api.nvim_buf_line_count(s.buf)) do
        pcall(api.nvim_buf_set_extmark, s.buf, M.gauge_ns, line - 1, (box.gauge_col or 0) + 1, opts)
      end
    else
      pcall(api.nvim_buf_set_extmark, s.buf, M.gauge_ns, box.line - 1, box.gauge_col or 0,
        { virt_text = { { '›', 'DeskCallGraphSelected' } }, virt_text_pos = 'overlay', priority = 300 })
    end
  end
end

-- Selects box `index`; place: put the cursor on its name too (never moving the focus).
function M.select(s, index, place)
  local box = s.drawn and s.drawn.boxes[index]
  if not box then return end
  if s.index ~= index then s.index = index; paint(s) end
  if place and s.win and api.nvim_win_is_valid(s.win) and api.nvim_win_get_buf(s.win) == s.buf then
    pcall(api.nvim_win_set_cursor, s.win, { box.line, box.name_col })
  end
  M.gauge_edges(s)
end

function M.move(s, how)
  for _ = 1, math.max(1, vim.v.count1 or 1) do
    local index = M.nav(s.drawn and s.drawn.boxes or {}, s.index, how)
    if index then M.select(s, index, true) end
  end
end

function M.selected(s) local box = s.index and s.drawn and s.drawn.boxes[s.index]; return box and box.item end

-- s: a label on every box, at its top-left corner (its name stays readable); typing one selects that box, as a move
-- landing there would. Enter still goes.
function M.jump_boxes(s)
  if not (s and s.drawn and s.win and api.nvim_win_is_valid(s.win)) then return end
  local targets = {}
  for i, box in ipairs(s.drawn.boxes) do targets[#targets + 1] = { line = box.spans[1][1], col = box.spans[1][2], index = i } end
  require('desk.nav').jump(s.win, targets, function(t) M.select(s, t.index, true) end)
end

-- A new drawing: the centre box selected (else the first), the cursor on it; keep: the same graph drawn again, so
-- the selection stays where it was.
--- The selected box kept at the screen row it was on when a drawing changes under it (Codex's #2: a level expanded
--- above it pushed it down the screen). held = { line, top } from before (its line, the window's first line).
function M.keep_row(win, held, line)
  if not (held and win and api.nvim_win_is_valid(win) and line) then return end
  local top = math.max(1, line - (held.line - held.top))
  pcall(api.nvim_win_call, win, function() vim.fn.winrestview({ topline = top }) end)
end
local function show(s, drawn, keep)
  local was = keep and s.index and s.drawn and s.drawn.boxes[s.index]
  local held = was and s.win and api.nvim_win_is_valid(s.win) and api.nvim_win_get_buf(s.win) == s.buf
    and { line = was.line, top = vim.fn.line('w0', s.win) } or nil
  s.drawn, s.index = drawn, nil
  draw(s.buf, drawn)
  local first
  if was then
    for i, box in ipairs(drawn.boxes) do
      if box.role == was.role and identity(box.item) == identity(was.item) then first = i; break end
    end
  end
  local kept = first ~= nil
  for i, box in ipairs(drawn.boxes) do if not first and box.centre then first = i end end
  first = first or (drawn.boxes[1] and 1)
  if first then M.select(s, first, true) else paint(s); M.gauge_edges(s) end
  if kept then M.keep_row(s.win, held, drawn.boxes[first].line) end
end
M._show = show

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
  local scroll = api.nvim_create_autocmd('WinScrolled', { pattern = tostring(s.win), callback = function() M.gauge_edges(s) end })
  api.nvim_create_autocmd('BufWipeout', { buffer = s.buf, once = true, callback = function() api.nvim_del_autocmd(scroll) end })
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

--- pure: textDocument/implementation's answer (Location[] or LocationLink[]) as places to offer, each once, sorted:
--- { file, line (1-based), col, label "name · file:line" } — named by the line's first words when the server names none.
function M.implementations(result, read_line)
  local out, seen = {}, {}
  for _, loc in ipairs(result or {}) do
    local uri = loc.targetUri or loc.uri
    local range = loc.targetSelectionRange or loc.targetRange or loc.range
    if type(uri) == 'string' and range and range.start then
      local file, line = vim.uri_to_fname(uri), range.start.line + 1
      local key = file .. ':' .. line
      if not seen[key] then
        seen[key] = true
        local text = vim.trim(read_line and read_line(file, line) or '')
        out[#out + 1] = { file = file, line = line, col = range.start.character or 0,
          label = (text ~= '' and text:sub(1, 70) or vim.fn.fnamemodify(file, ':t')) .. ' · ' .. vim.fn.fnamemodify(file, ':t') .. ':' .. line }
      end
    end
  end
  table.sort(out, function(a, b) return a.file == b.file and a.line < b.line or a.file < b.file end)
  return out
end
local function line_of(file, line)
  local buf = vim.fn.bufnr(file)
  if buf > 0 and api.nvim_buf_is_loaded(buf) then return (api.nvim_buf_get_lines(buf, line - 1, line, false)[1]) end
  local ok, text = pcall(vim.fn.readfile, file, '', line)
  return ok and text[line] or nil
end

-- I on a box: the overrides the language server knows for its function (a virtual call), offered as possible
-- implementations: one of them runs, the graph never says which (Codex's C8). One: opened; several: picked.
local function implementations(item, source, origin)
  local client = source and api.nvim_buf_is_valid(source) and M.clients(source)[1]
  if not client then return tell('Requires a language server attached to this graph\'s code.', vim.log.levels.WARN) end
  local raw = item.raw or item
  local range = raw.selectionRange or raw.range
  if not (raw.uri and range) then return tell(tostring(item.name) .. ' has no place the language server can be asked about.', vim.log.levels.WARN) end
  M.transport(client, source, 'textDocument/implementation', { textDocument = { uri = raw.uri }, position = range.start }, function(err, result)
    vim.schedule(function()
      if err then return tell('The language server could not say: ' .. tostring(err.message or err), vim.log.levels.WARN) end
      local places = M.implementations(result, line_of)
      if #places == 0 then return tell('The language server knows no implementation of ' .. tostring(item.name) .. ' (not virtual, or none it has read).') end
      local function open(p)
        require('desk.nav').code_target(origin)
        vim.cmd.edit(vim.fn.fnameescape(p.file))
        pcall(api.nvim_win_set_cursor, 0, { p.line, p.col })
      end
      if #places == 1 then return open(places[1]) end
      vim.ui.select(places, { prompt = 'Possible implementations of ' .. tostring(item.name) .. ' (one of them runs)', format_item = function(p) return p.label end },
        function(p) if p then open(p) end end)
    end)
  end)
end
M._implementations = implementations

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
  return out
end

-- Its centre's file edited since the graph was read (unsaved: the server answered for the text before the edit).
function M.edited_since(graph)
  local at = graph and graph.read_at
  return at ~= nil and api.nvim_buf_is_valid(at.buf) and api.nvim_buf_get_changedtick(at.buf) ~= at.tick
end
M.EDITED = 'edited since it was read: lines may have moved'

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
    local graph = { center = M.item(raw, enc), source = buf, client_id = client.id }
    -- Where its centre's file stood when it was read: edits after it move the lines the graph names (M.edited_since).
    local file_buf = raw.uri and vim.fn.bufnr(vim.uri_to_fname(raw.uri)) or -1
    if file_buf > 0 then graph.read_at = { buf = file_buf, tick = api.nvim_buf_get_changedtick(file_buf) } end
    step('callHierarchy/incomingCalls', { item = raw }, function(incoming)
      graph.callers = calls(incoming, 'from', enc)
      for _, call in ipairs(incoming or {}) do
        if call.from then site(graph, M.item(call.from, enc), graph.center, call.from.uri, call.fromRanges) end
      end
      step('callHierarchy/outgoingCalls', { item = raw }, function(outgoing)
        graph.callees = calls(outgoing, 'to', enc)
        for _, call in ipairs(outgoing or {}) do
          if call.to then site(graph, graph.center, M.item(call.to, enc), raw.uri, call.fromRanges) end
        end
        graph.layers = {}
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

local function location(item)
  if item.uri and item.range and item.uri:match('^file:') then
    return vim.uri_to_fname(item.uri), item.range.start.line + 1
  end
  if item.buf and api.nvim_buf_is_valid(item.buf) and item.row then return api.nvim_buf_get_name(item.buf), item.row + 1 end
end

--- pure: every function the graph has read — the centre, then each side level by level — as location-list items, each once at its nearest level: "Caller, depth 2 · Queue::flush · q.cpp:84".
--- A box with no file (no working source) is left out and counted. → items, left out.
function M.loclist_items(graph)
  local items, seen, missing = {}, {}, 0
  local function add(item, said)
    local key = identity(item)
    if seen[key] then return end
    seen[key] = true
    local file, line = location(item)
    if not file then missing = missing + 1; return end
    local col = item.range and item.range.start and item.range.start.character or item.col or 0
    items[#items + 1] = { filename = file, lnum = line, col = col + 1,
      text = said .. ' · ' .. tostring(item.name or '?') .. ((item.detail and item.detail ~= '') and (' · ' .. item.detail) or '') }
  end
  if graph.center then add(graph.center, 'Centre') end
  for _, side in ipairs(SIDES) do
    local word = side == 'callers' and 'Caller' or 'Callee'
    local tiers = graph.layers and graph.layers[side]
    if not tiers then
      tiers = graph[side] and { graph[side] } or {}
    end
    for depth, tier in ipairs(tiers) do
      for _, item in ipairs(tier) do add(item, word .. ', depth ' .. depth) end
    end
  end
  return items, missing
end

-- gl: that list in a code window's location list (the one she was last in), so :lnext and :lprev walk it while she
-- edits, the graph closed or not, and the quickfix list keeps what it has (the build's errors).
local function to_loclist(graph)
  local items, missing = M.loclist_items(graph)
  if #items == 0 then return tell('No function of this graph has a file to list.', vim.log.levels.WARN) end
  local nav = require('desk.nav')
  local here = api.nvim_get_current_win()
  local win = nav.code_window(here) and here or nav.last_code()
  if not win then win = nav.code_target() end
  vim.fn.setloclist(win, {}, ' ', { title = 'call graph · ' .. tostring(graph.center and graph.center.name or '?'), items = items })
  local name = vim.fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(win)), ':t')
  tell(('%d function%s in the location list of the window with %s — :lnext / :lprev walk them, :lopen lists them%s.'):format(#items,
    #items == 1 and '' or 's', name ~= '' and name or 'no name', missing > 0 and (' (' .. missing .. ' with no file left out)') or ''))
  return win
end
M._to_loclist = to_loclist

-- Expand through every member of a frontier.
local function server_layers(graph, side, depth, active, done)
  local source = graph.source
  local client = source and api.nvim_buf_is_valid(source) and vim.iter(M.clients(source)):find(function(c) return c.id == graph.client_id end)
  if not (client and graph.center.raw and graph[side]) then
    done(nil, 'requires a project map or a language server with call hierarchy')
    return function() end
  end
  local tiers = { vim.list_slice(graph[side]) }
  local kept = graph.layer_source and graph.layer_source[side] == 'server' and layers_of(graph, side)
  if kept then tiers = vim.list_slice(kept) end
  local visited = { [identity(graph.center)] = true }
  for _, tier in ipairs(tiers) do
    for _, item in ipairs(tier) do visited[identity(item)] = true end
  end
  local outgoing = side == 'callees'
  local method, field = outgoing and 'callHierarchy/outgoingCalls' or 'callHierarchy/incomingCalls', outgoing and 'to' or 'from'
  local stopped, cancel, at, next_tier = false, function() end, 0, {}
  local function stop() stopped = true; cancel() end
  local function step()
    if stopped or not active() then return end
    local last = tiers[#tiers] or {}
    if #tiers >= depth or #last == 0 then return done(tiers) end
    at = at + 1
    local item = last[at]
    while item and graph.unfold_only and identity(item) ~= graph.unfold_only do at = at + 1; item = last[at] end
    if not item then
      if #next_tier == 0 then return done(tiers) end
      table.sort(next_tier, function(a, b) return a.name < b.name end)
      tiers[#tiers + 1], at, next_tier = next_tier, 0, {}
      return step()
    end
    cancel = M.transport(client, source, method, { item = item.raw }, function(err, result)
      vim.schedule(function()
        if stopped or not active() then return end
        if err then return done(nil, 'the language server failed: ' .. tostring(err.message or err)) end
        for _, call in ipairs(result or {}) do
          local raw = call[field]
          if raw then
            local found = M.item(raw, client.offset_encoding or 'utf-16')
            local id = identity(found)
            link(graph, item, found)
            if field == 'from' then site(graph, found, item, raw.uri, call.fromRanges)
            else site(graph, item, found, item.uri, call.fromRanges) end
            if not visited[id] then visited[id] = true; next_tier[#next_tier + 1] = found end
          end
        end
        step()
      end)
    end)
  end
  vim.defer_fn(function()
    if not stopped and active() then stop(); done(nil, 'the language server took too long to read this level') end
  end, M.WAIT_MS)
  step()
  return stop
end

-- The levels a side shows now.
local function shown_layers(graph, side)
  if graph.layers and graph.layers[side] then return vim.list_slice(graph.layers[side]) end
  if not graph[side] then return {} end
  return { vim.list_slice(graph[side]) }
end

-- Where a function is, as file:line keys: the lines from where its definition starts to its name. The language server
-- gives both (range, selectionRange), the project map the line its definition starts on, so one function read by
-- both has a key in common. real: a cache of the files' real paths.
local function places(item, real)
  if not item then return {} end
  local file, line = location(item)
  if not file then return {} end
  real[file] = real[file] or uv.fs_realpath(file) or file
  local raw = item.raw or {}
  local first, name = (raw.range or item.range or {}).start, (raw.selectionRange or item.range or {}).start
  if not (first and name) then return { real[file] .. ':' .. (line - 1) } end
  local out = {}
  for line = math.min(first.line, name.line), math.min(math.max(first.line, name.line), first.line + 20) do
    out[#out + 1] = real[file] .. ':' .. line
  end
  return out
end

local function map_item(n, root)
  local item = { name = n.label, map_id = n.id, detail = n.detail or 'project map' }
  if type(n.file) == 'string' and type(n.line) == 'number' and n.line >= 1 then
    local start = { line = n.line - 1, character = 0 }
    item.uri, item.range, item.enc = vim.uri_from_fname(root .. '/' .. n.file), { start = start, ['end'] = start }, 'utf-8'
    item.detail = vim.fs.basename(n.file) .. ':' .. n.line
  end
  return item
end

-- The levels shown now with the next one under them, from the project map's answer (its walk from the centre: the
-- functions and the steps between them), or nil when the map cannot give that level. The levels shown stay, the
-- language server's level 1 above all: the map reads calls by name and misses the ones the server resolves (through
-- pointers, virtual calls, macros). The map adds the level below the last one, walking its steps out from the
-- functions on it (the centre, when nothing is shown), each function once, at its nearest depth; only when it read
-- every one of them that is in the checkout: one it does not have, or did not read that far, would lose its calls.
local function map_level(graph, side, answer)
  local real = {}
  local root = uv.fs_realpath(answer.root) or answer.root
  local items, at, read, outward = {}, {}, {}, {}
  for _, n in ipairs(answer.nodes) do
    if type(n) == 'table' and type(n.id) == 'string' and type(n.label) == 'string' then
      items[n.id] = map_item(n, answer.root)
      for _, p in ipairs(places(items[n.id], real)) do at[p] = at[p] or n.id end
      if n.depth == 0 then read[n.id] = true end
    end
  end
  -- Each step says what its far end is: read further (follow), or calling nothing (leaf); capped: not read.
  for _, s in ipairs(type(answer.steps) == 'table' and answer.steps or {}) do
    local near, far = s.from, s.to
    if side == 'callers' then near, far = s.to, s.from end
    if items[near] and items[far] then
      outward[near] = outward[near] or {}
      table.insert(outward[near], far)
      if s.mark == 'follow' or s.mark == 'leaf' then read[far] = true end
    end
  end
  local function id_of(item)
    if item.map_id then return items[item.map_id] and item.map_id end
    for _, p in ipairs(places(item, real)) do if at[p] then return at[p] end end
  end
  local tiers, shown, seen = shown_layers(graph, side), {}, {}
  for _, tier in ipairs({ { graph.center }, unpack(tiers) }) do
    for _, item in ipairs(tier) do
      for _, p in ipairs(places(item, real)) do shown[p] = true end
      local id = id_of(item)
      if id then seen[id] = true end
    end
  end
  local level = {}
  for _, item in ipairs(tiers[#tiers] or { graph.center }) do
    if not (graph.unfold_only and identity(item) ~= graph.unfold_only) then
      local id, file = id_of(item), (places(item, real)[1] or ''):match('^(.*):%d+$')
      if not id then
        if file and file:sub(1, #root + 1) == root .. '/' then return nil end
      elseif not read[id] then return nil
      else
        for _, far in ipairs(outward[id] or {}) do
          link(graph, item, items[far])
          local here = places(items[far], real)
          if not seen[far] and not vim.iter(here):any(function(p) return shown[p] end) then
            level[#level + 1] = items[far]
            for _, p in ipairs(here) do shown[p] = true end
          end
          seen[far] = true
        end
      end
    end
  end
  if #level == 0 then return nil end
  table.sort(level, function(a, b) return a.name < b.name end)
  tiers[#tiers + 1] = level
  return tiers
end

-- done(levels, note): the levels shown with the next under them, from the project map; done() when the map has no
-- answer or cannot give that level (map_level), and the language server reads it.
local function map_layers(graph, side, depth, active, done)
  local file, line = location(graph.center)
  if not file or file == '' or M.edited_since(graph) then done(); return end
  local buf = vim.fn.bufnr(file)
  if buf > 0 and vim.bo[buf].modified then done(); return end
  return require('desk.map').desk_work({ 'map', 'query', '--root', vim.fs.dirname(file), '--q', side == 'callers' and side or 'reach',
    '--file', file, '--line', tostring(line), '--from', graph.center.name or '', '--depth', tostring(depth), '--cap', '3000' }, function(answer)
    if not active() then return end
    if not (answer and answer.ok and type(answer.root) == 'string' and type(answer.nodes) == 'table') then return done() end
    local tiers = map_level(graph, side, answer)
    if not tiers or #tiers < depth then return done() end
    done(tiers, answer.capped and 'more calls were left out of the project map answer' or nil)
  end, 2500)
end

local function stop_depth(holder)
  local requests = holder.depth_requests
  holder.depth_requests = nil
  for _, request in pairs(requests or {}) do if request.cancel then request.cancel() end end
end

local function with_depth(holder, graph)
  local notes = vim.list_slice(graph.notes or {})
  for _, side in ipairs(SIDES) do
    local request = (holder.depth_requests or {})[side]
    if request then
      notes[#notes + 1] = ('reading %s level %d…'):format(side, request.depth)
    elseif graph.layer_note and graph.layer_note[side] then
      notes[#notes + 1] = graph.layer_note[side]
    end
  end
  return vim.tbl_extend('force', {}, graph, { notes = notes })
end

-- only: one box's identity (> on it: its branch alone, Codex's C2); nil reads the whole level.
local function change_depth(holder, side, delta, redraw, only)
  local graph = holder.graph
  if not (graph and graph.center) then return end
  local count = #layers_of(graph, side)
  graph.partial = graph.partial or {}
  -- + after >: the level that holds one branch is read again whole
  if delta > 0 and not only and graph.partial[side] and graph.partial[side] == count and count > 1 then
    graph.layers[side] = vim.list_slice(graph.layers[side], 1, count - 1)
    count = count - 1
    graph.partial[side] = nil
    if graph.exhausted then graph.exhausted[side] = nil end
  end
  local requests = holder.depth_requests or {}
  holder.depth_requests = requests
  if delta < 0 then
    local request = requests[side]
    requests[side] = nil
    if request then if request.cancel then request.cancel() end; return redraw() end
    if count > 1 then
      graph.layers[side] = vim.list_slice(graph.layers[side], 1, count - 1)
      if graph.exhausted then graph.exhausted[side] = nil end
      if graph.layer_note then graph.layer_note[side] = nil end
      if graph.partial[side] and graph.partial[side] >= count then graph.partial[side] = nil end
      redraw()
    end
    return
  end
  if requests[side] or ((graph.exhausted or {})[side] and not only) then return end
  local request = { depth = count + 1, only = only }
  requests[side] = request
  local function active() return holder.graph == graph and holder.depth_requests == requests and requests[side] == request end
  local function finish(tiers, source, note)
    if not active() then return end
    requests[side] = nil
    graph.layer_note = graph.layer_note or {}
    graph.layer_note[side] = note
    if tiers then
      graph.layers, graph.layer_source, graph.exhausted = graph.layers or {}, graph.layer_source or {}, graph.exhausted or {}
      graph.layers[side], graph.layer_source[side] = tiers, source
      if source == 'map' then graph.message = nil end
      if #tiers < request.depth then
        if request.only then
          graph.layer_note[side] = note or ((request.name or 'it') .. (side == 'callees' and ' calls nothing found' or ': no callers found'))
        else
          graph.exhausted[side] = true
          graph.layer_note[side] = note or ('no more ' .. side)
        end
      elseif request.only then
        graph.partial[side] = request.depth
        graph.layer_note[side] = note or ('level ' .. (side == 'callees' and '+' or '-') .. request.depth .. ': ' .. (request.name or 'one box') .. "'s " .. side .. ' only · ' .. M.typed('expand') .. ' reads the whole level')
      end
    end
    redraw()
  end
  redraw()
  graph.unfold_only = only
  local job = map_layers(graph, side, request.depth, active, function(tiers, note)
    if tiers then return finish(tiers, 'map', note) end
    request.cancel = server_layers(graph, side, request.depth, active, function(answer, why) finish(answer, 'server', why) end)
  end)
  if job then request.cancel = function() pcall(job.kill, job, 15) end end
end

-- What symdeps adds, for C and C++: its own card on the centre (every use by role) when it is loaded.
local function symdeps_state(buf)
  local ft = api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype
  if ft ~= 'c' and ft ~= 'cpp' then return nil end
  return (package.loaded['fox-symdeps'] or pcall(require, 'fox-symdeps')) and 'loaded' or 'missing'
end

-- An item from the language server goes to its range; the centre drawn before the answer, to where it was asked.
local target_at
local function target_for_item(item, source)
  if item.raw then return { buf = source, item = item, name = item.name } end
  local file, line = location(item)
  if file and item.map_id then return target_at(file, line, item.name) end
end

local function jump(item, win)
  if item.map_id then
    local target = target_for_item(item)
    if not target then return tell('The project map has no working source for ' .. item.name .. '.', vim.log.levels.WARN) end
    return M.jump({ buf = target.buf, row = target.row, col = target.col }, win)
  end
  require('desk.nav').code_target(win)   -- that window when it is code, else another code window: never a view's
  if item.uri and item.range then
    vim.lsp.util.show_document({ uri = item.uri, range = item.range }, item.enc or 'utf-16', { focus = true })
  elseif item.buf and api.nvim_buf_is_valid(item.buf) and item.row then
    api.nvim_win_set_buf(0, item.buf)
    pcall(api.nvim_win_set_cursor, 0, { item.row + 1, item.col or 0 })
  end
end
-- desk.popout's Enter: a box chosen in the pop-out, gone to in this editor.
M.jump = jump
local function placeholder(target)
  return { name = target.name, detail = vim.fn.fnamemodify(api.nvim_buf_get_name(target.buf), ':t') .. ':' .. (target.row + 1),
           buf = target.buf, row = target.row, col = target.col }
end

local function pending_graph(center, message)
  return { center = center, message = message or 'reading the call hierarchy…', reading = true }
end

-- ─── the graph view (one tab, reused) ──────────────────────────────────────────────────────────────────────────
-- Like the review: Enter goes to a function in the code window the graph came from and the tab stays open behind it,
-- Backspace goes back to that window as it was, and Space cc from anywhere brings the same tab back on the function
-- under the cursor (walking a call chain is Enter on a callee, then Space cc there).
local views = {}

-- keep: the same graph again (its window changed width), so the selection stays.
local function render(view, keep)
  if not api.nvim_win_is_valid(view.win) then return end
  local graph = with_depth(view, view.graph)
  local symdeps = symdeps_state(view.source)
  if symdeps == 'missing' then graph.notes[#graph.notes + 1] = 'every use by role: requires symdeps' end
  if M.edited_since(view.graph) then graph.notes[#graph.notes + 1] = M.EDITED .. ' · ' .. M.typed('reload') .. ' reads it again' end
  graph.keys = vim.deepcopy(M.VIEW_KEYS)
  if symdeps == 'loaded' then table.insert(graph.keys, #graph.keys, { M.typed('symdeps'), 'symdeps' }) end
  view.width = api.nvim_win_get_width(view.win)
  show(view, M.layout(graph, view.width - 2, M.retro()), keep)
end

-- The tab's name: the function it shows now (c moves it); its buffer number only when another buffer has that name.
local function name_view(view, target)
  local name = 'call graph · ' .. tostring(target.name or (target.item and target.item.name) or '')
  if not pcall(api.nvim_buf_set_name, view.buf, name) then pcall(api.nvim_buf_set_name, view.buf, name .. ' · ' .. view.buf) end
end
M.name_view = name_view

local function load(view, target)
  stop_depth(view)
  if view.cancel then view.cancel() end
  name_view(view, target)
  view.graph = pending_graph(target.item or placeholder(target))
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
  end, function(message) view.graph = pending_graph(view.graph.center, message); render(view) end)
  view.cancel = function() stop_wait(); if stop_fetch then stop_fetch() end end
end

function M.close_view(buf)
  local view = views[buf]
  if view then
    stop_depth(view)
    if view.cancel then view.cancel() end
  end
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
    load(open, target)
    return open
  end
  vim.cmd('tabnew')
  local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  vim.bo[buf].filetype = 'deskcallgraph'
  for opt, value in pairs({ number = false, relativenumber = false, signcolumn = 'no', wrap = false, list = false, spell = false, cursorline = false }) do
    vim.wo[win][opt] = value
  end
  local view = { buf = buf, win = win, origin = origin, source = target.buf }
  views[buf] = view
  bind_selection(view, 'callgraph')
  -- A narrower or wider window (a tmux pane resized) draws the graph again for its width; it kept the old one until r.
  local resized = api.nvim_create_augroup('desk_callgraph_view_' .. buf, { clear = true })
  api.nvim_create_autocmd('WinResized', { group = resized, callback = function()
    if view.graph and api.nvim_win_is_valid(view.win) and api.nvim_win_get_width(view.win) ~= view.width then render(view, true) end
  end })
  api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function()
    stop_depth(view)
    if views[buf] and views[buf].cancel then views[buf].cancel() end
    views[buf] = nil
    pcall(api.nvim_del_augroup_by_id, resized)
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

-- keep: the same graph again (pinning, unpinning, a new width), so the selection stays.
local function panel_show(graph, keep)
  if not panel_open() then return end
  if panel.graph ~= graph then stop_depth(panel) end
  panel.graph = graph
  panel.width = api.nvim_win_get_width(panel.win)
  local drawn = vim.tbl_extend('force', with_depth(panel, graph), { keys = M.panel_keys(panel.pinned), header = panel.pinned and 'PINNED' or nil })
  show(panel, M.layout(drawn, panel.width - 1, M.retro()), keep)
end

local function cache_key(t) return vim.uri_from_bufnr(t.buf) .. '\0' .. t.name .. '\0' .. t.row end

local function panel_request()
  if panel.inflight or not panel.wanted then return end
  local target = panel.wanted
  panel.wanted = nil
  local cached = panel.cache[cache_key(target)]
  if cached then if panel.key == target.key then panel_show(cached) end; return end
  panel.inflight = target
  local center = target.item or placeholder(target)
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
  end, function(message) if panel.key == target.key then panel_show(pending_graph(center, message)) end end)
  panel.stop = function() stop_wait(); if stop_fetch then stop_fetch() end end
end

-- Where the cursor is now in the followed window: draws from the cache, or asks. Pinned, the panel stays put.
function M.panel_update()
  if not panel_open() or panel.pinned then return end
  local win = panel.source_win
  if not win or not followed(win) then return end
  local buf, cursor = api.nvim_win_get_buf(win), api.nvim_win_get_cursor(win)
  M.with_tree(buf, function(tree)
    -- Pinned meanwhile (o brought a graph back, the notebook named a function): it keeps that one.
    if not panel_open() or panel.pinned or not api.nvim_buf_is_valid(buf) then return end
    local target, why = M.symbol_in(tree, buf, cursor[1] - 1, cursor[2])
    if not tree then target, why = nil, 'no treesitter parser for this file type' end
    local key = target and target.key or ('none:' .. buf .. ':' .. why)
    if key == panel.key then return end
    panel.key, panel.target = key, target
    if not target then return panel_show({ message = why }) end
    local cached = panel.cache[cache_key(target)]
    if cached then panel.wanted = nil; return panel_show(cached) end
    panel_show(pending_graph(placeholder(target)))
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
  M.panel_reload()
end

-- r in the panel: its graph asked for again (pinned: the same function; following: the one under the cursor, its
-- kept answer dropped).
function M.panel_reload()
  local target = panel.target
  if not panel_open() then return end
  stop_depth(panel)
  if not panel.pinned then
    if target and target.buf and target.name and target.row then panel.cache[cache_key(target)] = nil end
    panel.key = nil
    return M.panel_update()
  end
  if not target then return end
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

-- c in the panel: the graph centred on the selected box and pinned there, as in the pop-out; p follows again.
function M.panel_centre()
  local item = panel_open() and M.selected(panel)
  if not item then return end
  local buf = panel.target and panel.target.buf
  if not (buf and api.nvim_buf_is_valid(buf)) and panel.source_win and api.nvim_win_is_valid(panel.source_win) then
    buf = api.nvim_win_get_buf(panel.source_win)
  end
  local target = target_for_item(item, buf)
  if not (target and target.buf) then return end
  if panel.timer then panel.timer:stop() end
  local row = item.range and item.range.start.line or 0
  target.row, target.col, target.key = target.row or row, target.col or 0, 'centre:' .. tostring(item.uri) .. ':' .. row
  panel.pinned, panel.target, panel.key, panel.wanted = true, target, target.key, target
  panel_show(pending_graph(item))
  if not (panel.inflight and panel.inflight.key == target.key) then panel_request() end
end

function M.panel_close()
  stop_depth(panel)
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
  api.nvim_create_autocmd('WinResized', { group = group, callback = function()
    if panel_open() and panel.graph and api.nvim_win_get_width(panel.win) ~= panel.width then panel_show(panel.graph, true) end
  end })
  panel_show({ message = 'move the cursor into a function' })
  if followed(source) then panel.source_win = source; M.panel_update() end
end

-- The panel opened on a graph it is given (desk.popout brings its graph back): pinned, it keeps that graph; unpinned,
-- it follows the cursor from where it is.
function M.panel_open_with(graph, target, pinned)
  if not panel_open() then M.panel_toggle() end
  if not (panel_open() and pinned and graph) then return end
  if panel.timer then panel.timer:stop() end
  panel.pinned, panel.target, panel.wanted = true, target, nil
  panel.key = target and target.key or panel.key
  panel_show(graph)
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
-- The pop-out's graph (its view kind, below) has the graph tab's keys: the moves and the labels are drawn there, on
-- its copy (ctx.copy); Enter, c and gs are remote, run here with ctx.view (that view) and ctx.item (the box's item).
local function go(s)
  local item = M.selected(s)
  if item then jump(item, s == panel and panel.source_win or s.origin) end
end
local popout_centre, popout_reload, popout_symdeps   -- the pop-out's c, r and gs, with its view kind below
local function pop() return require('desk.popout') end
local GRAPH, BOTH = 'callgraph', { 'callgraph', 'callgraph-panel' }
local function depth_side(ctx, graph)
  if not ctx.view and ctx.graph then
    local box = ctx.graph.drawn and ctx.graph.drawn.boxes[ctx.graph.index or 0]
    return box and box.role == 'caller' and 'callers' or 'callees'
  end
  if ctx.item and ctx.item ~= graph.center then
    local nearest, side = math.huge, 'callees'
    for _, candidate in ipairs(SIDES) do
      for depth, tier in ipairs(layers_of(graph, candidate)) do
        if depth < nearest and vim.tbl_contains(tier, ctx.item) then nearest, side = depth, candidate end
      end
    end
    return side
  end
  return 'callees'
end

local function depth_row(delta, id, key, name)
  return { id = 'callgraph.' .. id, group = 'Call graph', name = name, key = key, on = BOTH, remote = true,
    about = delta > 0 and 'Read the next level on the selected side. From the centre, expand callees.'
      or 'Collapse the outermost level on the selected side, or cancel the level being read',
    available = function(ctx)
      local holder = ctx.view or ctx.graph
      local graph = holder and holder.graph
      if not (graph and graph.center) then return 'no function is shown' end
      if graph.reading then return 'reading the call hierarchy' end
      local side = depth_side(ctx, graph)
      local pending = (holder.depth_requests or {})[side]
      if delta < 0 then return pending ~= nil or #layers_of(graph, side) > 1 or 'already showing the first level' end
      if pending then return 'already reading this side' end
      return not (graph.exhausted or {})[side] or 'no more ' .. side
    end,
    run = function(ctx)
      local holder = ctx.view or ctx.graph
      if not holder or not holder.graph then return end
      change_depth(holder, depth_side(ctx, holder.graph), delta, function()
        if ctx.view then return pop().redraw(holder) end
        if holder == panel then return panel_show(holder.graph, true) end
        render(holder, true)
      end)
    end }
end

local function moving(how, key, name, about, line, doc)
  return { id = 'callgraph.' .. how, group = 'Call graph', name = name, about = about, key = key, on = BOTH, menu = false, drawn = true,
    line = line and ('callgraph.' .. line) or nil, doc = doc, run = function(ctx) M.move(ctx.copy or ctx.graph, how) end }
end
local function picked(ctx) if ctx.view and not ctx.item then return 'no box is selected' end end
-- The box a key acts on, the same everywhere: the pop-out's selection, the panel's, the tab's (once the centre in a tab).
local function selected_item(ctx)
  if ctx.view then return ctx.item end
  if ctx.graph == panel then return M.selected(panel) end
  if ctx.graph then return M.selected(ctx.graph) end
end
local function subject(ctx)
  local item = selected_item(ctx)
  return item and (tostring(item.name) .. (item.detail and item.detail ~= '' and (' · ' .. item.detail) or '')) or nil
end
local ROWS = actions.add({
  -- These two read this editor's current window (the function under its cursor; the tab the panel splits): asked from
  -- the pop-out they would act on whatever window is current here, not the box or row selected there. The editor's own.
  { id = 'callgraph.open', group = 'This function', name = 'Call graph of this function', key = '<leader>cc', on = 'editor', remote = false,
    also = '`:CallGraph`',
    about = "Call graph of the function under the cursor, in a tab: callers above, the function in a double box, what it calls below (the language server's call hierarchy). It opens with the function's box selected. One tab: pressed again anywhere, it brings that tab back on the function under the cursor",
    -- In the graph itself its own keys are the ones that apply.
    available = function(ctx) return (ctx.surface ~= 'callgraph' and ctx.surface ~= 'callgraph-panel') or false end,
    run = function() M.open_cursor() end },
  { id = 'callgraph.panel', group = 'This function', name = 'Live call graph panel', key = '<leader>co', on = 'editor', remote = false,
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
  -- gj / gk: j and k along a real call (Codex's E7); h/j/k/l stay for browsing the drawing
  { id = 'callgraph.along-down', group = 'Call graph', name = 'Along a call, to what it calls', key = 'gj', on = BOTH, menu = false, drawn = true,
    about = 'To a function the selected box calls, however far down the drawing; again, the next one it calls (wrapping), or on down when it calls only one; the call\'s place beside it',
    doc = 'Along a real call: to what the box calls / to what calls it, again for the next',
    run = function(ctx) M.along(ctx.copy or ctx.graph, 'down') end },
  { id = 'callgraph.along-up', group = 'Call graph', name = 'Along a call, to what calls it', key = 'gk', on = BOTH, menu = false, drawn = true,
    line = 'callgraph.along-down',
    about = 'To a function that calls the selected box, however far up the drawing; again, the next one that calls it (wrapping), or on up when only one does',
    run = function(ctx) M.along(ctx.copy or ctx.graph, 'up') end },
  { id = 'callgraph.jump', group = 'Call graph', name = 'Jump to a box by its label', key = 's', on = BOTH, menu = false, drawn = true,
    available = function() return require('desk.nav').labels_ready() end,
    about = 'Labels on the boxes on screen, as `s` draws them in code (flash.nvim): typing one selects that box, as `j` and `k` would; `Enter` still goes',
    run = function(ctx) M.jump_boxes(ctx.copy or ctx.graph) end },
  { id = 'callgraph.go', group = 'Call graph', name = 'Go to the selected function', key = '<CR>', on = BOTH, also = 'a double click',
    remote = true, available = picked, subject = subject,
    about = "Go to the selected box's function, in the code window the graph came from; the graph stays open (a click, or any motion that lands in a box, selects it)",
    run = function(ctx)
      if ctx.view then if ctx.item then jump(ctx.item, ctx.origin) end; return end
      go(ctx.graph)
    end },
  { id = 'callgraph.go-mouse', group = 'Call graph', name = 'Go to the function clicked', key = '<2-LeftMouse>', on = BOTH, line = 'callgraph.go',
    menu = false, doc = false, remote = false,
    run = function(ctx)
      local s, pos = ctx.graph, vim.fn.getmousepos()
      if pos.winid == s.win and (pos.line or 0) > 0 then
        local index = M.box_at(s.drawn, pos.line, math.max(0, (pos.column or 1) - 1))
        if index then M.select(s, index, false) end
      end
      go(s)
    end },
  { id = 'callgraph.back', group = 'Call graph', name = 'Back to the code, the graph left open', key = '<BS>', on = GRAPH, remote = false,
    about = 'Back to that code window as it was, the graph left open',
    run = function(ctx)
      if api.nvim_win_is_valid(ctx.graph.origin) then api.nvim_set_current_win(ctx.graph.origin)
      elseif #api.nvim_list_tabpages() > 1 then vim.cmd('tabprevious') end
    end },
  -- On every graph (2026-11-16: in the panel c was Vim's own, an error on its read-only buffer).
  { id = 'callgraph.centre', group = 'Call graph', name = 'Centre the graph on the selected function', key = 'c', on = BOTH, remote = true,
    about = 'Centre the graph on the selected box: its own callers and callees (in the panel and the pop-out it is pinned there; `p` follows again)',
    available = function(ctx)
      if not ctx.view then return end
      if not ctx.item then return 'no box is selected' end
      return ctx.item.raw ~= nil or (ctx.item.map_id ~= nil and ctx.item.uri ~= nil) or 'this box has no call hierarchy or working source'
    end,
    run = function(ctx)
      if ctx.view then return popout_centre(ctx.view, ctx.item) end
      if ctx.graph == panel then return M.panel_centre() end
      local view, item = ctx.graph, M.selected(ctx.graph)
      local target = item and target_for_item(item, view.source)
      if target then view.source, view.target = target.buf, target; load(view, target) end
    end },
  depth_row(1, 'expand', '+', 'Expand call depth'),
  depth_row(-1, 'collapse', '-', 'Collapse call depth'),
  { id = 'callgraph.implementations', group = 'Call graph', name = 'Possible implementations of this function', key = 'I', on = BOTH, remote = true,
    subject = subject,
    about = 'For a virtual function (an interface\'s): the overrides the language server knows, as possible implementations (one of them runs; the graph cannot say which); one opens, several are offered',
    available = function(ctx)
      local item = selected_item(ctx)
      if not item then return 'no box is selected' end
      return (item.raw or (item.uri and item.range)) and true or 'this box has no place the language server can be asked about'
    end,
    run = function(ctx)
      local holder = ctx.view or ctx.graph
      local source = holder and (holder.source or (holder.graph and holder.graph.source))
      implementations(selected_item(ctx), source, ctx.origin)
    end },
  -- > on a box at the edge of its side: its own next level alone, its siblings kept (Codex's C2: + reads a whole side)
  { id = 'callgraph.unfold', group = 'Call graph', name = "Unfold this box's next level", key = '>', on = BOTH, remote = true, subject = subject,
    about = "Read the selected box's own callees (or, above the centre, its callers) as the next level, the boxes beside it kept: one branch, where `+` reads the whole level",
    available = function(ctx)
      local holder = ctx.view or ctx.graph
      local graph = holder and holder.graph
      local item = selected_item(ctx)
      if not (graph and graph.center and item) then return 'no box is selected' end
      if item == graph.center then return 'on the centre `+` reads its next level' end
      if graph.reading then return 'reading the call hierarchy' end
      local side, at = M.edge_of(graph, item)
      if not side then return 'only a box on the outermost level unfolds (the levels below it are shown)' end
      if (holder.depth_requests or {})[side] then return 'already reading this side' end
      return true
    end,
    run = function(ctx)
      local holder = ctx.view or ctx.graph
      local item = selected_item(ctx)
      local side = holder and holder.graph and item and M.edge_of(holder.graph, item)
      if not side then return end
      change_depth(holder, side, 1, function()
        if ctx.view then return pop().redraw(holder) end
        if holder == panel then return panel_show(holder.graph, true) end
        render(holder, true)
      end, identity(item))
      local request = (holder.depth_requests or {})[side]
      if request then request.name = tostring(item.name or '') end
    end },
  -- gs on every graph, the panel too (2026-11-16: there gs slept a second).
  -- On every graph (2026-11-16: in the panel and the pop-out r was Vim's own, an error on their read-only buffers).
  { id = 'callgraph.reload', group = 'Call graph', name = 'Read the graph again', key = 'r', on = BOTH, remote = true,
    about = 'Ask the language server for the graph again (a graph that follows the cursor: for the function under it)',
    run = function(ctx)
      if ctx.view then return popout_reload(ctx.view) end
      if ctx.graph == panel then return M.panel_reload() end
      load(ctx.graph, ctx.graph.target)
    end },
  { id = 'callgraph.close', group = 'Call graph', name = 'Close the call graph', key = 'q', on = GRAPH, about = 'Close the graph tab', remote = false,
    run = function(ctx) M.close_view(ctx.graph.buf) end },
  { id = 'callgraph.symdeps', group = 'Call graph', name = 'This function in symdeps', key = 'gs', on = BOTH, remote = true,
    about = "The selected box's function in symdeps' card (C and C++), shown in the code — in the tab, the panel and the pop-out alike",
    subject = subject,
    available = function(ctx)
      if not actions.symdeps() then return 'requires symdeps' end
      local item = selected_item(ctx)
      if not item then return 'no box is selected' end
      local ft = vim.filetype.match({ filename = item.uri and vim.uri_to_fname(item.uri) or '' })
      return (ft == 'c' or ft == 'cpp') or 'requires a C or C++ function'
    end,
    run = function(ctx)
      if ctx.view then return popout_symdeps(ctx) end
      if not actions.symdeps() then return tell('Requires symdeps (an optional plugin for C and C++ symbols).') end
      local item = selected_item(ctx)
      if not (item and item.uri) then return tell('Select a function first.') end
      popout_symdeps({ item = item, origin = ctx.graph == panel and panel.source_win or (ctx.graph and ctx.graph.origin) })
    end },
  -- t: the trace through the selected box's function (desk.map's trace page: up to where it starts, down to where it ends).
  { id = 'callgraph.trace', group = 'Call graph', name = 'Trace a possible path through this function', key = 't', on = BOTH, remote = true, subject = subject,
    about = "The project map's trace through the selected function: up to where it starts, down to where it ends, each step with its parameters and the arguments it is called with",
    available = function(ctx)
      local item = selected_item(ctx)
      if not item then return 'no box is selected' end
      return (item.uri and item.range) and true or 'that box has no place in the code'
    end,
    run = function(ctx)
      local item = selected_item(ctx)
      if not (item and item.uri and item.range) then return tell('Select a function first.') end
      -- from a pop-out, into that pop-out's map (never another screen's)
      require('desk.map').trace_at(vim.uri_to_fname(item.uri), item.range.start.line + 1, { pop = ctx.view and ctx.view.pop })
    end },
  -- T: the map's whole trace through the selected box's function (every way through it in one picture), as T on the map.
  { id = 'callgraph.trace-all', group = 'Call graph', name = 'The whole trace through this function', key = 'T', on = BOTH, remote = true, subject = subject,
    about = "The project map's whole trace through the selected function: what leads to it above and what it leads to below, as boxes in layers, the lane `t` follows in double frames",
    available = function(ctx)
      local item = selected_item(ctx)
      if not item then return 'no box is selected' end
      return (item.uri and item.range) and true or 'that box has no place in the code'
    end,
    run = function(ctx)
      local item = selected_item(ctx)
      if not (item and item.uri and item.range) then return tell('Select a function first.') end
      require('desk.map').trace_at(vim.uri_to_fname(item.uri), item.range.start.line + 1, { pop = ctx.view and ctx.view.pop, q = 'flow' })
    end },
  { id = 'callgraph.pin', group = 'Call graph', name = 'Pin the panel to this graph, or follow again', key = 'p', on = 'callgraph-panel',
    about = 'Pin the panel to the graph it shows (PINNED), or follow the cursor again', run = function() M.panel_pin() end },
  { id = 'callgraph.panel-close', group = 'Call graph', name = 'Close the call graph panel', key = 'q', on = 'callgraph-panel',
    about = 'Close the panel', run = function() M.panel_close() end },
  -- o here sends the graph to the pop-out; o there brings it back (desk.popout's own row, popout.back).
  { id = 'callgraph.loclist', group = 'Call graph', name = "Send these functions to the window's location list", key = 'gl', on = BOTH, remote = true,
    about = 'Every function the graph has read into the location list of the code window you were last in: `:lnext` and `:lprev` walk them while you edit, the quickfix list kept',
    available = function(ctx)
      local holder = ctx.view or ctx.graph
      return (holder and holder.graph and holder.graph.center) and true or 'no function is shown'
    end,
    run = function(ctx) to_loclist((ctx.view or ctx.graph).graph) end },
  { id = 'callgraph.popout', group = 'Call graph', name = 'Send this graph to the pop-out', key = 'o', on = BOTH, remote = false,
    about = 'Move this graph to the pop-out on the other screen (opening it) and close it here; `o` there brings it back as a split',
    available = function() return pop().can_pop() end, run = function(ctx) pop().show('graph', ctx) end },
  -- The notebook's, through desk-work editor (the bridge's callgraph message below): no key and no menu.
  { id = 'callgraph.at', group = 'Call graph', name = 'The call graph of a function named elsewhere', on = 'editor', remote = true,
    menu = false, doc = false,
    about = 'The call graph of a function the notebook names (its file and line): in the pop-out when it is open, else in the panel beside the code, pinned on it',
    available = function(ctx)
      if type(ctx.at) ~= 'table' then return false end
      if pop().is_open('graph') then return true end
      local review = package.loaded['desk.review']
      return not (type(review) == 'table' and review.current) or 'a review is open'
    end,
    run = function(ctx) M.show_at(ctx.at) end },
})

-- The keys a key line shows for these rows, as typed ("j/k/h/l", "Enter", "BS").
function M.typed(...)
  local keys = {}
  for _, id in ipairs({ ... }) do keys[#keys + 1] = actions.spell(actions.key('callgraph.' .. id)) end
  return table.concat(keys, '/')
end
-- ? (desk.keys, every view's) lists them all, the ones these lines leave out too.
local KEYS = { actions.key('desk.keys') or '?', 'keys' }
M.VIEW_KEYS = { { M.typed('down', 'up', 'left', 'right'), 'move' }, { M.typed('go'), 'go' }, { M.typed('back'), 'back' },
  { M.typed('centre'), 'centre' }, { M.typed('reload'), 'reload' }, { M.typed('close'), 'close' }, KEYS }
function M.panel_keys(pinned)
  return { { M.typed('down', 'up', 'left', 'right'), 'move' }, { M.typed('go'), 'go' }, { M.typed('pin'), pinned and 'unpin' or 'pin' },
    { M.typed('panel-close'), 'close' }, KEYS }
end

-- ─── what is here: the selected box ────────────────────────────────────────────────────────────────────────────
-- actions.about's answer in a graph (the tab, the panel, and the pop-out's graph through its ctx_for): the selected
-- box's function as a unit, the graph it is in, and its callers and callees by name.
local function relative(file)
  local root = file ~= '' and vim.fs.root(file, '.git')
  root = root and (uv.fs_realpath(root) or root)
  local real = uv.fs_realpath(file) or file
  return (root and real:sub(1, #root + 1) == root .. '/') and real:sub(#root + 2) or file
end
local function spot(item)
  local file = item.uri and vim.uri_to_fname(item.uri) or (item.buf and api.nvim_buf_is_valid(item.buf) and api.nvim_buf_get_name(item.buf)) or ''
  local line = item.range and item.range.start.line + 1 or (item.row and item.row + 1) or nil
  return relative(file), line
end
local function about(ctx)
  local item, graph
  if ctx.view then item, graph = ctx.item, ctx.view.graph
  elseif ctx.graph then item, graph = M.selected(ctx.graph), ctx.graph.graph end
  if not item then return nil, 'no box is selected' end
  graph = graph or {}
  local file, line = spot(item)
  local refs = { { kind = 'unit', file = file, line = line, name = item.name, label = item.name .. (line and (' · ' .. file .. ':' .. line) or '') } }
  local center = graph.center
  if center then
    local cfile, cline = spot(center)
    refs[#refs + 1] = { kind = 'graph', file = cfile, line = cline, name = center.name, label = 'the call graph of ' .. center.name }
  end
  local function names(list) return table.concat(vim.tbl_map(function(i) return i.name end, list or {}), ', ') end
  local excerpt = ('%s\ncallers: %s\ncallees: %s'):format(center and center.name or item.name, names(graph.callers), names(graph.callees))
  return { title = item.name, refs = refs, excerpt = excerpt:sub(1, 2000) }
end
actions.provide('callgraph', about)
actions.provide('callgraph-panel', about)

-- ─── in the pop-out: desk.popout's first view kind ─────────────────────────────────────────────────────────────
-- The live graph on the other screen. It follows the function under the cursor of the code window it came from, as
-- the panel does (after the cursor rests, or at once on symdeps' FoxUnitChanged), until p there pins it. Each view
-- keeps its own following: cache (answers until that file is saved), key (the function drawn), followed (the window
-- followed), win (where Enter goes), timer, inflight and wanted (one request at a time), stop (a graph read again).
local function code_window(win)
  if not (win and api.nvim_win_is_valid(win)) or api.nvim_win_get_config(win).relative ~= '' then return false end
  local buf = api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == '' and vim.b[buf].desk_callgraph == nil
end
local function centre_of(target) return target.item or placeholder(target) end
local function follow_key(t) return vim.uri_from_bufnr(t.buf) .. '\0' .. tostring(t.name) .. '\0' .. tostring(t.row) end

-- The graph of target ({buf, row, col, name} or {buf, item}) from the language server: done(graph) always, with the
-- reason as its message when there is none. Returns a function that stops it.
local function read(target, done, waiting)
  local stop_fetch
  local stop_wait = M.ready(target.buf, function(client, why)
    if not client then return done({ center = centre_of(target), message = why }) end
    stop_fetch = M.fetch(client, target, function(graph, err)
      if graph and why then graph.notes = { why } end
      done(graph or { center = centre_of(target), message = err })
    end)
  end, waiting)
  return function() stop_wait(); if stop_fetch then stop_fetch() end end
end

local function show_followed(view, graph, target)
  if view.gone or view.pinned then return end
  if view.graph ~= graph then stop_depth(view) end
  view.graph, view.target = graph, target or view.target
  pop().redraw(view)
end

local function follow_request(view)
  if view.gone or view.inflight or not view.wanted or pop().exiting() then return end
  local target = view.wanted
  view.wanted = nil
  local key = follow_key(target)
  if view.cache[key] then
    if view.key == target.key then show_followed(view, view.cache[key], target) end
    return follow_request(view)
  end
  view.inflight = target
  view.stop_follow = read(target, function(graph)
    view.inflight, view.stop_follow = nil, nil
    view.cache[key] = graph
    if view.key == target.key then show_followed(view, graph, target) end
    follow_request(view)
  end, function(message) if view.key == target.key then show_followed(view, pending_graph(centre_of(target), message), target) end end)
end

-- Where the cursor is now in the followed window: drawn from the cache, or asked. Pinned, the graph stays put.
local function follow_update(view)
  if view.gone or view.pinned or not code_window(view.followed) or pop().exiting() then return end
  local win = view.followed
  local buf, cursor = api.nvim_win_get_buf(win), api.nvim_win_get_cursor(win)
  M.with_tree(buf, function(tree)
    if view.gone or view.pinned or not api.nvim_buf_is_valid(buf) then return end
    local target, why = M.symbol_in(tree, buf, cursor[1] - 1, cursor[2])
    if not tree then target, why = nil, 'no treesitter parser for this file type' end
    local key = target and target.key or ('none:' .. buf .. ':' .. tostring(why))
    if key == view.key then return end
    view.key, view.win = key, win
    if not target then return show_followed(view, { message = why }, nil) end
    local cached = view.cache[follow_key(target)]
    if cached then view.wanted = nil; return show_followed(view, cached, target) end
    show_followed(view, pending_graph(centre_of(target)), target)
    -- Back on the function already being asked about: its answer is on the way.
    if view.inflight and view.inflight.key == target.key then view.wanted = nil; return end
    view.wanted = target
    follow_request(view)
  end)
end

-- A cursor move in a window: the graph waits for the cursor to rest. Pinned, only the window followed is kept.
local function follow_moved(view, win)
  if not code_window(win) or pop().exiting() then return end
  view.followed = win
  -- Edited since it was read, or read again since: drawn again once, so the note comes and goes.
  if M.edited_since(view.graph) ~= (view.shown_edited == true) then pop().redraw(view) end
  if view.pinned then return end
  view.timer = view.timer or uv.new_timer()
  view.timer:stop()
  view.timer:start(M.DEBOUNCE_MS, 0, vim.schedule_wrap(function() follow_update(view) end))
end

local function forget_file(view, buf)
  local uri = vim.uri_from_bufnr(buf)
  for key in pairs(view.cache) do if key:sub(1, #uri + 1) == uri .. '\0' then view.cache[key] = nil end end
  if view.key and (view.key:match('^' .. buf .. ':') or view.key:match('^none:' .. buf .. ':')) then view.key = nil end
end

-- A graph read for the view (pinned: its own file was saved; centred; sent here still being read). waiting: what to
-- show meanwhile, with the message. Its answer is news in the pop-out's header until she looks.
local function read_for(view, target, waiting)
  stop_depth(view)
  if view.stop then view.stop() end
  view.stop = read(target, function(graph)
    view.stop = nil
    if not view.gone then view.graph, view.news = graph, true; pop().redraw(view) end
  end, waiting and function(message) if not view.gone then view.graph = pending_graph(waiting, message); pop().redraw(view) end end)
end

-- A pinned graph is read again once its own file is saved (by the server's item when it has one: a save can move it).
local function refresh_pinned(view, buf)
  local target = view.pinned and view.target
  if not (target and target.buf == buf) then return end
  local center = view.graph and view.graph.center
  read_for(view, center and center.raw and vim.tbl_extend('force', {}, target, { item = center }) or target)
end

-- The code window a box is gone to in: the one the graph came from, else the current one, else the first in this tab.
local function target_window(view)
  if code_window(view.win) then return view.win end
  local here = api.nvim_get_current_win()
  if code_window(here) then return here end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do if code_window(win) then return win end end
end

-- The view as it is now, for desk.popout: the history keeps all of it (step = true: restore puts it back as it was),
-- the layout record only pinned and target, a pinned graph's function as { file, line, name }.
local function save_view(view)
  local saved = { step = true, pinned = view.pinned == true, graph = view.graph, at = view.target, win = view.win, key = view.key,
    followed = view.followed }
  local t = view.target
  if view.pinned and t then
    local item = t.item
    local file = item and item.uri and vim.uri_to_fname(item.uri) or (t.buf and api.nvim_buf_is_valid(t.buf) and api.nvim_buf_get_name(t.buf)) or ''
    local line = t.row and t.row + 1 or (item and item.range and item.range.start.line + 1) or nil
    if file ~= '' and line then saved.target = { file = file, line = line, name = t.name } end
  end
  return saved
end

-- c in the pop-out: the graph centred on a box, pinned there; Ctrl+o there goes back to the graph before.
popout_centre = function(view, item)
  if not item then return end
  local before = save_view(view)
  local buf = view.target and view.target.buf
  if not (buf and api.nvim_buf_is_valid(buf)) then buf = api.nvim_win_get_buf(target_window(view) or 0) end
  local target = target_for_item(item, buf)
  if not target then return end
  view.pinned, view.target, view.graph = true, target, pending_graph(item)
  pop().redraw(view)
  read_for(view, target, item)
  pop().stepped(view, before)
  pop().save_layout()
end

-- r in the pop-out: the graph asked for again (pinned: its function; following: the one under the cursor, its kept
-- answer dropped).
popout_reload = function(view)
  if not view.pinned then
    local t = view.target
    if t and t.buf and t.row then view.cache[follow_key(t)] = nil end
    view.key = nil
    return follow_update(view)
  end
  local target, center = view.target, view.graph and view.graph.center
  if target then read_for(view, center and center.raw and vim.tbl_extend('force', {}, target, { item = center }) or target, center) end
end

-- gs in the pop-out: the box's function here, in symdeps' card.
popout_symdeps = function(ctx)
  if not ctx.item then return end
  jump(ctx.item, ctx.origin)
  local inspect = actions.symdeps_card()
  if not inspect then return tell('This symdeps version does not expose its card.') end
  inspect()
end

-- A function named by its file and line (the notebook's, a saved layout's): its file loaded, the function around that
-- line (treesitter), else the line itself. nil and why when the file is gone.
target_at = function(file, line, name)
  if type(file) ~= 'string' or not uv.fs_stat(file) then return nil, 'that file is no longer there' end
  local buf = vim.fn.bufadd(file)
  vim.bo[buf].buflisted = true
  pcall(vim.fn.bufload, buf)
  local row = math.max(0, math.min((tonumber(line) or 1) - 1, api.nvim_buf_line_count(buf) - 1))
  local text = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
  local col = math.max(0, (text:find('%S') or 1) - 1)
  local found = M.symbol_at(buf, row, col)
  if found then return found end
  return { buf = buf, row = row, col = col, key = 'line:' .. buf .. ':' .. row,
    name = (type(name) == 'string' and name ~= '') and name or (vim.fs.basename(file) .. ':' .. (row + 1)) }
end
M.target_at = target_at

-- The view pinned on target: read for it, Enter going to the code window of the current tab.
local function pin_on(view, target)
  view.pinned, view.target, view.key = true, target, nil
  local win = target_window(view)
  view.win, view.followed = win or view.win, win or view.followed
  view.graph = pending_graph(centre_of(target))
  read_for(view, target, centre_of(target))
end

-- The view, from where it was asked: o in the graph tab or the panel (ctx.graph) sends that graph, which leaves the
-- editor (a tab shows one chosen function, so it arrives pinned; the panel arrives as it was); a function named
-- elsewhere (ctx.target, the notebook's) pins it there; from anywhere else it follows the function under the cursor of
-- the window it was asked in.
local function open_view(view, ctx)
  view.cache = view.cache or {}
  if ctx.target then return pin_on(view, ctx.target) end
  local s = ctx.graph
  if s then
    local from_panel = s == panel
    view.graph, view.target = s.graph, s.target
    view.pinned = not from_panel or s.pinned == true
    view.win = from_panel and s.source_win or s.origin
    view.key, view.followed = nil, view.win
    if from_panel then M.panel_close() else M.close_view(s.buf) end
    local graph = view.graph or {}
    -- Still being read when it left: read again for the pop-out.
    if view.pinned and view.target and not (graph.callers or graph.callees or graph.layers) then read_for(view, view.target)
    elseif not view.pinned then follow_update(view) end
    return
  end
  view.pinned, view.key = false, nil
  if code_window(ctx.win) then view.followed, view.win = ctx.win, ctx.win; follow_update(view) end
end

local function follow(view, event)
  if event.type == 'moved' then return follow_moved(view, event.win) end
  if event.type == 'unit' then
    -- symdeps' follow card moved: the graph moves with it, at once.
    if not code_window(event.win) then return end
    view.followed = event.win
    if view.timer then view.timer:stop() end
    return follow_update(view)
  end
  if event.type == 'saved' or event.type == 'attached' then
    forget_file(view, event.buf)
    refresh_pinned(view, event.buf)
    return follow_moved(view, api.nvim_get_current_win())
  end
  if event.type == 'pin' and not view.pinned then
    -- Following again, from where the cursor is now.
    view.key = nil
    if not code_window(view.followed) then view.followed = target_window(view) end
    follow_update(view)
  end
end

-- The history's step back as it was (step); the layout record's { pinned, target } after a restart: a pinned graph read
-- again for its function, else following from the code window here.
local function restore_view(view, saved)
  stop_depth(view)
  view.cache = view.cache or {}
  if view.stop then view.stop() end
  if saved.step then
    view.pinned, view.graph, view.target = saved.pinned == true, saved.graph, saved.at
    view.win, view.followed, view.key = saved.win or view.win, saved.followed or view.followed, saved.key
    if not view.pinned then view.key = nil; follow_update(view) end
    return
  end
  local target = saved.pinned and type(saved.target) == 'table' and target_at(saved.target.file, saved.target.line, saved.target.name)
  if target then return pin_on(view, target) end
  view.pinned, view.key = false, nil
  local win = target_window(view)
  if win then view.followed, view.win = win, win; follow_update(view) end
end

local GROUPS = { 'DeskCallGraphCentre', 'DeskCallGraphBox', 'DeskCallGraphName', 'DeskCallGraphDim', 'DeskCallGraphHead', 'DeskCallGraphFaint',
  'DeskCallGraphKey', 'DeskCallGraphSelected' }
-- Its key line in the pop-out (the header shows PINNED; ? lists every key).
local function footer(pinned)
  local keys = { { ids = { 'callgraph.down', 'callgraph.up', 'callgraph.left', 'callgraph.right' }, words = 'move' },
    { ids = { 'callgraph.go' }, words = 'go' }, { ids = { 'popout.go-focus' }, words = 'go+focus' },
    { ids = { 'popout.pin' }, words = pinned and 'follow' or 'pin' } }
  keys[#keys + 1] = { ids = { 'popout.keys' }, words = 'keys' }
  return keys
end
-- A box's key: its role, its name and where it is, so the same box keeps its selection when the graph is drawn again.
local function box_key(box)
  local item = box.item or {}
  local where = item.uri and item.range and (item.uri .. ':' .. item.range.start.line) or (tostring(item.buf) .. ':' .. tostring(item.row))
  local name = tostring(item.name or '')
  return (box.role or 'box') .. ':' .. vim.fn.sha256(where .. '\0' .. name):sub(1, 16) .. ':' .. name:sub(1, 80)
end
local function render_view(view, width, style)
  highlights()
  local graph = with_depth(view, view.graph or { message = 'move the cursor into a function' })
  view.shown_edited = M.edited_since(graph)
  if view.shown_edited then
    graph = vim.tbl_extend('force', {}, graph, { notes = vim.list_extend(vim.deepcopy(graph.notes or {}), { M.EDITED .. ' · ' .. M.typed('reload') .. ' reads it again' }) })
  end
  local drawn = M.layout(graph, math.max(16, width - 2), style == 'retro')
  local items = {}
  for i, box in ipairs(drawn.boxes) do
    -- the key line's first slot says where Enter goes (Codex's #9), the same width for every box
    local said = actions.voice(style == 'retro')
    local enter = 'Enter ' .. said('go to ') .. tostring(box.item.name or '') .. (box.item.detail and box.item.detail ~= '' and (' (' .. box.item.detail .. ')') or '')
    enter = vim.fn.strdisplaywidth(enter) > 38 and (fit(enter, 38, style == 'retro' and '..' or '…')) or (enter .. string.rep(' ', 38 - vim.fn.strdisplaywidth(enter)))
    items[i] = { key = box_key(box), kind = 'box', line = box.line, x = box.x, w = box.w, name_col = box.name_col, spans = box.spans, near = box.near,
      keys = enter .. ' · f ' .. said('go+focus') .. ' · t ' .. said('trace') .. ' · p ' .. said('pin'),
      centre = box.centre, gauge = box.gauge, gauge_band = box.gauge_band, gauge_col = box.gauge_col, name = tostring(box.item.name or ''),
      where = box.item.detail ~= '' and box.item.detail or nil, ref = box.item,
      down = box.down, up = box.up, down_sites = box.down_sites, up_sites = box.up_sites }
  end
  local center = graph.center
  return { title = 'call graph' .. (center and center.name and (' · ' .. center.name) or ''), state = '',
    tab = 'calls', subject = center and center.name or nil,
    lines = drawn.lines, marks = drawn.marks, hl = GROUPS, items = items, footer = footer(view.pinned), heads = drawn.heads,
    news = view.news == true }
end

M.view_kind = {
  name = 'graph', title = 'call graph', surface = GRAPH,
  about = 'The live call graph in the pop-out, a window of its own on the other screen: it follows the function under the cursor (`p` there pins it), and `Enter` there goes to a function here while the keyboard stays there',
  -- In a graph its own key sends it (callgraph.popout).
  available = function(ctx) if not ctx.remote and (ctx.surface == 'callgraph' or ctx.surface == 'callgraph-panel') then return false end end,
  open = open_view,
  render = render_view,
  follow = follow,
  ctx_for = function(view, ref)
    local win = target_window(view)
    local ctx = actions.context(win or api.nvim_get_current_win())
    ctx.surface, ctx.item, ctx.origin = GRAPH, ref, win
    return ctx
  end,
  -- o in the pop-out: back as the live panel beside the code it came from, pinned when it was pinned there.
  -- The place of a selected box, for the preview pane (gp in another pop-out).
  place = function(_, ref)
    if ref and ref.uri and ref.range then return vim.uri_to_fname(ref.uri), ref.range.start.line + 1 end
  end,
  attach = function(view)
    if code_window(view.win) then pcall(api.nvim_set_current_win, view.win) end
    M.panel_open_with(view.graph, view.target, view.pinned)
  end,
  close = function(view)
    stop_depth(view)
    if view.timer then view.timer:stop(); if not view.timer:is_closing() then view.timer:close() end; view.timer = nil end
    if view.stop_follow then view.stop_follow() end
    if view.stop then view.stop() end
    view.inflight, view.wanted, view.stop_follow, view.stop = nil, nil, nil, nil
  end,
  save = save_view,
  restore = restore_view,
}
-- Registered as the module loads (not run headless for the notebook), so its Views row is in the registry.
if not headless then pop().kind(M.view_kind) end

-- ─── a function named elsewhere: the notebook ──────────────────────────────────────────────────────────────────
-- The panel pinned on target, opened beside the code when it is not open.
function M.panel_on(target)
  if not panel_open() then M.panel_toggle() end
  if not panel_open() then return end
  if panel.timer then panel.timer:stop() end
  panel.pinned, panel.target = true, target
  panel.key, panel.wanted = target.key, target
  panel_show(pending_graph(placeholder(target)))
  if not (panel.inflight and panel.inflight.key == target.key) then panel_request() end
end

-- The call graph of a function named by file and line: in the pop-out when one is open, else in the panel, pinned on
-- it either way.
function M.show_at(spec)
  local target, why = target_at(spec.file, spec.line, spec.name)
  if not target then return tell(why:sub(1, 1):upper() .. why:sub(2) .. '.') end
  if pop().is_open('graph') then return pop().show('graph', { target = target }) end
  M.panel_on(target)
end

-- desk-work editor's callgraph { root, file, line, name } (the notebook's: Enter on a function it lists): runs
-- callgraph.at with that function, after this answer, which says where it shows. Never while she types here, and not
-- into the panel while a review is open.
local function at_message(msg)
  if vim.g.desk_work_view or vim.g.desk_popout then return { refused = 'this editor shows one item; nothing else opens in it' } end
  local root, file = uv.fs_realpath(msg.root), uv.fs_realpath(msg.file)
  if not (root and file) then return { refused = 'that file is not on disk' } end
  if file:sub(1, #root + 1) ~= root .. '/' then return { refused = 'another project' } end
  if require('desk.bridge').typing() then return { refused = 'typing in this editor' } end
  local ctx = actions.context()
  ctx.at = { file = file, line = msg.line, name = msg.name }
  local can = actions.available(actions.get('callgraph.at'), ctx)
  if can ~= true then return { refused = can == false and 'not here' or tostring(can) } end
  vim.schedule(function() actions.act('callgraph.at', ctx) end)
  return { shown = pop().is_open('graph') and 'popout' or 'panel' }
end
if not headless then
  local bridge = require('desk.bridge')
  bridge.register('callgraph', at_message, { root = bridge.field('path', 4096, true), file = bridge.field('path', 4096, true),
    line = bridge.field('integer', 10000000), name = bridge.field('string', 200) })
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
