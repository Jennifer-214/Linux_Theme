-- The project map: the whole checkout as boxes at three zooms (its parts, a part's files, a file's functions and
-- classes), drawn like the call graph (callgraph.lua's frames and glyphs). desk-work keeps the map (desk-work map
-- build: a background job, rebuilt only when asked) and answers its queries; this draws the answers and never waits
-- on them. Run headless (nvim --headless --clean -l map.lua --syntax-graph REQUEST ANSWER), it is also the map's
-- syntax reader: the functions and classes in each file, and the calls between them by name, from treesitter.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
-- Run headless as the syntax reader (the end of this file), the modules beside this one come first.
local headless = type(arg) == 'table' and arg[1] == '--syntax-graph' and type(arg[0]) == 'string' and ('/' .. arg[0]):match('/map%.lua$')
if headless then package.path = (arg[0]:match('(.*/)') or './') .. '../?.lua;' .. package.path end
local actions = require('desk.actions')
local ns = api.nvim_create_namespace('desk_map')
M.MAX_BOXES, M.MAX_SIDE, M.MAX_TIER, M.POLL_MS, M.BUILD_WAIT_MS = 60, 24, 24, 1000, 15 * 60 * 1000

local function tell(text, level) vim.notify(text, level or vim.log.levels.INFO, { title = 'Project map' }) end
local function one_line(s) return vim.trim(tostring(s or ''):gsub('%s+', ' ')) end

-- ─── the syntax reader (run headless by desk-work) ─────────────────────────────────────────────────────────────
-- A call per language: its node type and the field that names what it calls.
local CALLS = { call_expression = 'function', function_call = 'name', call = 'function', command = 'name', method_invocation = 'name' }
-- Units are the review's (desk.review's unit_types); classes in JavaScript, TypeScript and Java are declarations.
local MORE_UNITS = { class_declaration = true }
local TYPES = { class_definition = true, class_specifier = true, struct_specifier = true, struct_item = true, class_declaration = true }
-- What qualifies a name without being a unit itself: a C++ namespace, a Rust impl block.
local SCOPES = { namespace_definition = 'name', impl_item = 'type' }
local SEPARATOR = { c = '::', cpp = '::', rust = '::' }
-- The parser a file type uses when nvim-treesitter is not there to say so (a headless --clean Neovim).
local LANG_OF = { sh = 'bash', typescriptreact = 'tsx', javascriptreact = 'javascript' }
-- A call reaches functions of its own language only (C and C++ call each other, so do JavaScript and TypeScript).
local FAMILY = { cpp = 'c', typescript = 'js', tsx = 'js', javascript = 'js' }

local function text_of(node, src) return vim.treesitter.get_node_text(node, src) end

-- A unit's own name (review.unit_of finds it), cut to the name in C's declarators ("*make(int)" is make); else the
-- name it is assigned to (M.f = function() end, { f = function() end }, const f = () => {}); nil when anonymous.
local function unit_name(R, node, src)
  local _, name = R.unit_of(node)
  if name then
    local s = one_line(text_of(name, src))
    if name:type():find('declarator') then s = vim.trim(s:match('^[%s%*&]*([^%(]+)') or s) end
    return s ~= '' and s or nil
  end
  local parent = node:parent()
  if not parent then return nil end
  local t = parent:type()
  if t == 'variable_declarator' or t == 'pair' or t == 'field' then
    local n = parent:field('name')[1] or parent:field('key')[1]
    return n and one_line(text_of(n, src)) or nil
  elseif t == 'assignment_expression' then
    local n = parent:field('left')[1]
    return n and one_line(text_of(n, src)) or nil
  elseif t == 'expression_list' then
    -- Lua: a, b = function() end, …: the name at the same place on the left.
    local statement = parent:parent()
    if not statement or statement:type() ~= 'assignment_statement' then return nil end
    local at = 0
    for i = 0, parent:named_child_count() - 1 do if parent:named_child(i):id() == node:id() then at = i end end
    local names = statement:named_child(0)
    local var = names and names:type() == 'variable_list' and names:named_child(at)
    return var and one_line(text_of(var, src)) or nil
  end
end

-- What a call names: the whole callee as written (M.beta, self.helper, q->push) and its last name (beta, helper,
-- push). A call through an expression (a pointer, a call's result, "$cmd") names nothing.
local function callee(node, src)
  if not node then return nil end
  local full = one_line(text_of(node, src))
  if full == '' or #full > 160 then return nil end
  local inner = node
  for _ = 1, 8 do
    local next_one = inner:field('name')[1] or inner:field('field')[1] or inner:field('attribute')[1]
                     or inner:field('method')[1] or inner:field('property')[1]
    if not next_one then break end
    inner = next_one
  end
  local short = one_line(text_of(inner, src))
  if not short:match('^[%a_~][%w_]*$') then return nil end
  return (full:gsub('%->', '.')), short
end

local function read_file(path, limit)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read(limit or 1024 * 1024 + 1)
  f:close()
  return text
end

-- request: { root, files = { rel… }, limits = { nodes, edges } }. Returns the map's graph shape plus spans (each
-- unit's first and last line, for "what a commit touched"), notes and counts.
function M.syntax_graph(request)
  local R = require('desk.review')
  local unit_types = vim.tbl_extend('force', {}, R.unit_types, MORE_UNITS)
  local root = type(request.root) == 'string' and request.root or ''
  local limits = type(request.limits) == 'table' and request.limits or {}
  local max_nodes, max_edges = tonumber(limits.nodes) or 50000, tonumber(limits.edges) or 200000
  local units, calls, spans = {}, {}, vim.empty_dict()
  local stats = { files = 0, parsed = 0, functions = 0, types = 0, calls = 0, edges = 0, ambiguous = 0, outside = 0 }
  local no_parser, parsers, complete, why = {}, {}, true, nil
  local function has_parser(lang)
    if parsers[lang] == nil then parsers[lang] = vim.treesitter.language.add(lang) == true end
    return parsers[lang]
  end
  local function read_one(rel)
    if type(rel) ~= 'string' or rel == '' or rel:sub(1, 1) == '/' or ('/' .. rel .. '/'):find('/%.%./') then return end
    stats.files = stats.files + 1
    local ft = vim.filetype.match({ filename = rel })
    local lang = ft and (LANG_OF[ft] or vim.treesitter.language.get_lang(ft))
    if not lang or not has_parser(lang) then
      local ext = rel:match('%.([^./]+)$') or rel
      no_parser[ext] = (no_parser[ext] or 0) + 1
      return
    end
    local src = read_file(root .. '/' .. rel)
    if not src or #src > 1024 * 1024 or src:find('\0', 1, true) then return end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok or not parser then return end
    local parsed, trees = pcall(parser.parse, parser)
    if not parsed or not trees or not trees[1] then return end
    stats.parsed = stats.parsed + 1
    local sep, in_file = SEPARATOR[lang] or '.', {}
    local stack = { { trees[1]:root(), nil, {} } }
    while #stack > 0 do
      local node, owner, scope = unpack(table.remove(stack))
      local t = node:type()
      if unit_types[t] and not (TYPES[t] and not node:field('body')[1]) and #units < max_nodes then
        local name = unit_name(R, node, src)
        if name then
          local label = (#scope > 0 and table.concat(scope, sep) .. sep or '') .. name
          local id = rel .. '::' .. label
          in_file[id] = (in_file[id] or 0) + 1
          if in_file[id] > 1 then id = id .. '#' .. in_file[id] end
          local first, _, last = node:range()
          local kind = TYPES[t] and 'type' or 'function'
          units[#units + 1] = { id = id, label = label, short = name:match('([%w_~]+)$') or name, file = rel, line = first + 1,
                                kind = kind, owner = owner, owner_label = owner and units[owner].label or '',
                                family = FAMILY[lang] or lang, folder = rel:match('^(.*)/') or '' }
          spans[id] = { first + 1, last + 1 }
          stats[kind == 'type' and 'types' or 'functions'] = stats[kind == 'type' and 'types' or 'functions'] + 1
          owner = #units
          scope = vim.list_extend(vim.list_slice(scope), { name })
        end
      elseif unit_types[t] and #units >= max_nodes and complete then
        complete, why = false, 'stopped at ' .. max_nodes .. ' functions and classes'
      elseif SCOPES[t] then
        local n = node:field(SCOPES[t])[1]
        if n then scope = vim.list_extend(vim.list_slice(scope), { one_line(text_of(n, src)) }) end
      end
      if CALLS[t] and owner then
        local full, short = callee(node:field(CALLS[t])[1], src)
        if short then calls[#calls + 1] = { from = owner, full = full, short = short }; stats.calls = stats.calls + 1 end
      end
      local children = {}
      for child in node:iter_children() do if child:named() then children[#children + 1] = child end end
      for i = #children, 1, -1 do stack[#stack + 1] = { children[i], owner, scope } end
    end
  end
  for _, rel in ipairs(type(request.files) == 'table' and request.files or {}) do read_one(rel) end

  -- Calls to edges, by name, within the caller's language: a qualified call (M.beta, Queue::push) prefers the
  -- function of that name; self.x and this->x the caller's own class; then the caller's file, then its folder (a
  -- checkout of many programs has many a trim); what is still ambiguous is left out and counted.
  local by_short, nodes, edges, seen = {}, {}, {}, {}
  for i, u in ipairs(units) do
    by_short[u.short] = by_short[u.short] or {}
    table.insert(by_short[u.short], i)
    nodes[i] = { id = u.id, label = u.label, file = u.file, line = u.line, kind = u.kind }
    if u.owner and units[u.owner].kind == 'type' and u.kind == 'function' then
      edges[#edges + 1] = { from = units[u.owner].id, to = u.id, kind = 'contains' }
    end
  end
  local function dotted(s) return (s:gsub('::', '.')) end
  for _, c in ipairs(calls) do
    local from = units[c.from]
    local pick = by_short[c.short] and vim.tbl_filter(function(k) return units[k].family == from.family end, by_short[c.short]) or {}
    if #pick == 0 then stats.outside = stats.outside + 1
    else
      local qualifier = c.full:sub(1, #c.full - #c.short):gsub('[%.:]+$', '')
      local own, matched = qualifier == 'self' or qualifier == 'this' or qualifier == 'cls', false
      if qualifier ~= '' then
        local narrowed, wanted = {}, dotted(c.full)
        for _, k in ipairs(pick) do
          local u = units[k]
          if own and u.owner_label ~= '' and u.owner_label == from.owner_label then narrowed[#narrowed + 1] = k
          elseif not own and (dotted(u.label) == wanted or dotted(u.label):sub(-#wanted - 1) == '.' .. wanted) then narrowed[#narrowed + 1] = k end
        end
        if #narrowed > 0 then pick, matched = narrowed, true end
      end
      for _, near in ipairs({ 'file', 'folder' }) do
        if #pick > 1 then
          local same = vim.tbl_filter(function(k) return units[k][near] == from[near] end, pick)
          if #same > 0 then pick = same end
        end
      end
      -- items.size() inside size(): another object's size (a library's, by name we cannot tell), not recursion.
      local elsewhere = #pick == 1 and pick[1] == c.from and qualifier ~= '' and not own and not matched
      if #pick ~= 1 or elsewhere then stats.ambiguous = stats.ambiguous + 1
      else
        local key = from.id .. '\0' .. units[pick[1]].id
        if not seen[key] then
          if #edges >= max_edges then
            if complete then complete, why = false, 'stopped at ' .. max_edges .. ' calls' end
          else
            seen[key] = true
            edges[#edges + 1] = { from = from.id, to = units[pick[1]].id, kind = 'call-by-name' }
            stats.edges = stats.edges + 1
          end
        end
      end
    end
  end
  local notes = {}
  if stats.ambiguous > 0 then
    notes[#notes + 1] = stats.ambiguous .. (stats.ambiguous == 1 and ' call' or ' calls') .. ' could not be told apart by name'
      .. ' (several functions of that name, or another object\'s method) and ' .. (stats.ambiguous == 1 and 'was' or 'were') .. ' left out'
  end
  local missing = {}
  for ext, n in pairs(no_parser) do missing[#missing + 1] = '.' .. ext .. ' ' .. n end
  table.sort(missing)
  if #missing > 0 then notes[#notes + 1] = 'no treesitter parser for ' .. table.concat(missing, ', ') end
  return { version = 1, nodes = nodes, edges = edges, spans = spans, complete = complete, why = why, notes = notes, stats = stats }
end

-- ─── desk-work ─────────────────────────────────────────────────────────────────────────────────────────────────
M.REQUIRES = 'Requires desk-work: it builds the project map and answers its queries.'
-- Every call in the background with a timeout: done(answer or nil, out); out.missing when desk-work could not be
-- started (it is not installed). Tests put a fake here.
function M.desk_work(args, done, timeout)
  local argv = { 'desk-work' }
  vim.list_extend(argv, args)
  local ok = pcall(vim.system, argv, { text = true, timeout = timeout or 20000 }, vim.schedule_wrap(function(out)
    local parsed, value = pcall(vim.json.decode, out.stdout or '', { luanil = { object = true, array = true } })
    done(parsed and type(value) == 'table' and value or nil, out)
  end))
  if not ok then vim.schedule(function() done(nil, { code = -1, stdout = '', stderr = M.REQUIRES, missing = true }) end) end
end

local function refusal(answer, out)
  if out and out.missing then return M.REQUIRES end
  if type(answer) == 'table' and type(answer.message) == 'string' and answer.message ~= '' then return answer.message end
  local said = vim.trim((out and out.stderr) or ''):match('([^\n]*)$') or ''
  if said ~= '' then return said end
  return 'desk-work map did not answer (exit ' .. tostring(out and out.code) .. ')'
end

-- ─── layout (pure) ─────────────────────────────────────────────────────────────────────────────────────────────
local function width_of(s) return api.nvim_strwidth(s) end
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

-- The call graph's glyphs (code page 437 in retro); the focus box takes the double border init.lua publishes.
function M.glyphs(retro)
  local G = vim.deepcopy(require('desk.callgraph').glyphs(retro))
  local b = vim.g.desk_border
  if type(b) == 'table' and #b == 8 then G.double = { tl = b[1], h = b[2], tr = b[3], v = b[4], br = b[5], bl = b[7] } end
  G.crumb = retro and ' » ' or ' › '   -- code page 437 has », not ›
  return G
end
function M.retro() return vim.g.desk_style == 'retro' end

-- page: { header = { { text, group } }, sections = { … }, notes = { text } }. A section is { head = text } (a centred
-- heading), { boxes = { item }, frame = 'single'|'double', more = n, none = text }, { arrow = true },
-- { parts = { { text, item? } }, group } (one line whose named parts are hits) or { blank = true }.
-- item: { name, detail, target }. Returns the lines, the hits per line (byte columns, for Enter) and the highlights.
function M.layout(page, width, retro)
  width = math.max(20, width or 80)
  local G = M.glyphs(retro)
  local lines, hits, marks = {}, {}, {}
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
        for k = 1, 4 do
          if i > 1 then texts[k] = texts[k] .. ' ' end
          local s = #texts[k]
          texts[k] = texts[k] .. parts[k]
          local lnum = first + k - 1
          hits[lnum] = hits[lnum] or {}
          table.insert(hits[lnum], { s = s, e = #texts[k], item = b.item })
          marks[#marks + 1] = { lnum, s, #texts[k], border }
          if k == 2 then marks[#marks + 1] = { lnum, s + #frame.v + 1, s + #frame.v + 1 + #b.name, name_group, 1 } end
          if k == 3 then marks[#marks + 1] = { lnum, s + #frame.v + 1, s + #frame.v + 1 + #b.detail, b.item.warn and 'DeskMapStale' or 'DeskMapDim', 1 } end
        end
      end
      for k = 1, 4 do lines[#lines + 1] = texts[k] end
    end
  end
  for _, h in ipairs(page.header or {}) do add(fit(h[1], width, G.ellipsis), h[2]) end
  for _, s in ipairs(page.sections or {}) do
    if s.head then centred(G.said(s.head), 'DeskMapHead')
    elseif s.boxes then
      if #s.boxes == 0 and s.none then centred(G.said(s.none), 'DeskMapDim') end
      local double = s.frame == 'double'
      boxes(s.boxes, double and G.double or G.single, double and 'DeskMapFocus' or 'DeskMapBox', double and 'DeskMapFocus' or 'DeskMapName')
      if (s.more or 0) > 0 then centred(G.said('+' .. s.more .. ' more'), 'DeskMapDim') end
    elseif s.arrow then centred(G.down, 'DeskMapBox')
    elseif s.parts then
      local text, lnum = '', #lines + 1
      for _, part in ipairs(s.parts) do
        local piece = tostring(part[1] or '')
        if part[2] then
          hits[lnum] = hits[lnum] or {}
          table.insert(hits[lnum], { s = #text, e = #text + #piece, item = part[2] })
          marks[#marks + 1] = { lnum, #text, #text + #piece, 'DeskMapName', 1 }
        end
        text = text .. piece
      end
      add(text, s.group)
    elseif s.blank then add('') end
  end
  -- Notes wrap at the width (a "requires …" line is worth reading whole), between its " · " parts where it has them,
  -- else between words; only a word wider than the page is cut. A note given as { text } keeps its case in retro
  -- (the keys: r and R are two keys).
  if page.notes and #page.notes > 0 then
    add('')
    for _, note in ipairs(page.notes) do
      local said = type(note) == 'table' and note[1] or G.said(note)
      local parts = vim.split(said, ' · ', { plain = true })
      local pieces = #parts > 1 and parts or vim.split(said, ' ', { plain = true, trimempty = true })
      local joiner = #parts > 1 and ' · ' or ' '
      local line = ''
      for _, piece in ipairs(pieces) do
        local next_line = line == '' and piece or (line .. joiner .. piece)
        if line ~= '' and width_of(next_line) > width then add(line, 'DeskMapDim'); next_line = '  ' .. piece end
        line = next_line
      end
      if line ~= '' then add(fit(line, width, G.ellipsis), 'DeskMapDim') end
    end
  end
  return { lines = lines, hits = hits, marks = marks }
end

function M.item_at(drawn, lnum, col)
  for _, hit in ipairs((drawn and drawn.hits or {})[lnum] or {}) do
    if col >= hit.s and col < hit.e then return hit.item end
  end
end

-- ─── levels (pure): desk-work's answers as pages ───────────────────────────────────────────────────────────────
local function count(n, one, many) return n .. ' ' .. (n == 1 and one or many) end
local function short(sha) return type(sha) == 'string' and sha:sub(1, 7) or '' end
local function where(n)
  if n.file then return vim.fn.fnamemodify(n.file, ':t') .. (n.line and (':' .. n.line) or '') end
  return n.detail or 'in the binary'
end
local function calls(kind) return kind == 'call' or kind == 'call-by-name' end

-- Callers above what they call, so a page reads downwards: each box sits one row below the lowest box that calls
-- it. A call that closes a cycle is left out of the ordering (a depth-first pass decides which).
function M.layers(keys, edges)
  local index, out = {}, {}
  for i, k in ipairs(keys) do index[k] = i; out[i] = {} end
  for _, e in ipairs(edges) do
    local a, b = index[e.from], index[e.to]
    if a and b and a ~= b then table.insert(out[a], b) end
  end
  local state, kept = {}, {}
  for i = 1, #keys do kept[i] = {} end
  for root = 1, #keys do
    if not state[root] then
      local stack = { { root, 1 } }
      state[root] = 1
      while #stack > 0 do
        local top = stack[#stack]
        local v, k = top[1], top[2]
        if k <= #out[v] then
          top[2] = k + 1
          local w = out[v][k]
          if state[w] == nil then state[w] = 1; table.insert(kept[v], w); stack[#stack + 1] = { w, 1 }
          elseif state[w] == 2 then table.insert(kept[v], w) end
        else state[v] = 2; stack[#stack] = nil end
      end
    end
  end
  local indegree, rank, queue = {}, {}, {}
  for i = 1, #keys do indegree[i], rank[i] = 0, 0 end
  for v = 1, #keys do for _, w in ipairs(kept[v]) do indegree[w] = indegree[w] + 1 end end
  for i = 1, #keys do if indegree[i] == 0 then queue[#queue + 1] = i end end
  local head = 1
  while head <= #queue do
    local v = queue[head]
    head = head + 1
    for _, w in ipairs(kept[v]) do
      rank[w] = math.max(rank[w], rank[v] + 1)
      indegree[w] = indegree[w] - 1
      if indegree[w] == 0 then queue[#queue + 1] = w end
    end
  end
  local tiers = {}
  for i = 1, #keys do
    tiers[rank[i] + 1] = tiers[rank[i] + 1] or {}
    table.insert(tiers[rank[i] + 1], keys[i])
  end
  return tiers
end

-- At most `cap` keys, the most connected first; the rest are counted.
local function busiest(keys, degree, cap)
  if #keys <= cap then return keys, 0 end
  local order = vim.list_slice(keys)
  local at = {}
  for i, k in ipairs(keys) do at[k] = i end
  table.sort(order, function(a, b)
    local da, db = degree[a] or 0, degree[b] or 0
    if da ~= db then return da > db end
    return at[a] < at[b]
  end)
  local kept = {}
  for i = 1, cap do kept[order[i]] = true end
  return vim.tbl_filter(function(k) return kept[k] end, keys), #keys - cap
end

-- Boxes in layers, with an arrow between layers.
local function layered(sections, keys, edges, item_of, degree, cap)
  local shown, more = busiest(keys, degree, cap)
  for i, tier in ipairs(M.layers(shown, edges)) do
    if i > 1 then sections[#sections + 1] = { arrow = true } end
    sections[#sections + 1] = { boxes = vim.tbl_map(item_of, tier) }
  end
  if more > 0 then sections[#sections + 1] = { head = '+' .. more .. ' more (fewer calls)' } end
end

-- Boxes of one side (who calls in from elsewhere, what is called out there), at most M.MAX_SIDE: the checkout's own
-- first (rank 0), libraries and what only the binary has after; the busiest first within each.
local function side(sections, label, items)
  if #items == 0 then return end
  table.sort(items, function(a, b)
    if (a.rank or 0) ~= (b.rank or 0) then return (a.rank or 0) < (b.rank or 0) end
    local wa, wb = a.weight or 0, b.weight or 0
    if wa ~= wb then return wa > wb end
    if a.name ~= b.name then return a.name < b.name end
    return (a.target and a.target.node and a.target.node.id or '') < (b.target and b.target.node and b.target.node.id or '')
  end)
  local more = math.max(0, #items - M.MAX_SIDE)
  while #items > M.MAX_SIDE do table.remove(items) end
  sections[#sections + 1] = { head = label .. ' · ' .. (#items + more) }
  sections[#sections + 1] = { boxes = items, more = more }
end

-- A part's size, as its box and the part picker (m) say it.
local function part_size(m)
  return m.name == '(library)' and count(m.functions or 0, 'library function', 'library functions')
    or m.name == '(binary)' and (count(m.functions or 0, 'function', 'functions') .. ' with no source here')
    or (count(m.files or 0, 'file', 'files') .. ' · ' .. count(m.functions or 0, 'function', 'functions'))
end

-- The parts of the checkout (desk-work map query --q module).
function M.level_modules(answer)
  local keys, degree, by = {}, {}, {}
  for _, m in ipairs(answer.modules or {}) do keys[#keys + 1] = m.name; by[m.name] = m end
  for _, e in ipairs(answer.edges or {}) do
    degree[e.from] = (degree[e.from] or 0) + (e.count or 1)
    degree[e.to] = (degree[e.to] or 0) + (e.count or 1)
  end
  local function item(name)
    return { name = name, detail = part_size(by[name]), target = { kind = 'module', module = name } }
  end
  local sections = {}
  if #keys == 0 then sections[1] = { parts = { { 'The map is empty: no reader found anything here.' } }, group = 'DeskMapDim' } end
  layered(sections, keys, answer.edges or {}, item, degree, M.MAX_BOXES)
  local edges = answer.edges or {}
  if #edges > 0 then
    sections[#sections + 1] = { blank = true }
    sections[#sections + 1] = { head = 'calls between parts' }
    for i = 1, math.min(#edges, 12) do
      local e = edges[i]
      sections[#sections + 1] = { parts = { { '  ' }, { e.from, item(e.from) }, { ' → ' }, { e.to, item(e.to) }, { ' · ' .. e.count } } }
    end
    if #edges > 12 then sections[#sections + 1] = { parts = { { '  +' .. (#edges - 12) .. ' more' } }, group = 'DeskMapDim' } end
  end
  return { crumbs = { 'parts' }, sections = sections }
end

-- Every node an answer carries (its own and the far ends of its edges), by id.
local function node_index(answer)
  local by = {}
  for _, n in ipairs(answer.nodes or {}) do by[n.id] = n end
  for _, n in ipairs(answer.outside or {}) do by[n.id] = by[n.id] or n end
  return by
end
local function node_item(n, extra)
  local item = { name = n.label, detail = where(n), target = { kind = 'node', node = n } }
  for k, v in pairs(extra or {}) do item[k] = v end
  return item
end

-- A part's files (desk-work map query --q module --name M): files in layers by the calls between them, the parts
-- that call into it above, the parts it calls below. A part with no files (the binary's, the libraries') shows its
-- functions instead.
function M.level_files(answer, module)
  local by, files, keys = node_index(answer), {}, {}
  for _, f in ipairs(answer.files or {}) do files[f.file] = f; keys[#keys + 1] = f.file end
  if #keys == 0 then return M.level_nodes(answer, module, nil) end
  local between, degree, into, out = {}, {}, {}, {}
  for _, e in ipairs(answer.edges or {}) do
    local a, b = by[e.from], by[e.to]
    if a and b and calls(e.kind) then
      local fa, fb = a.module == module and a.file, b.module == module and b.file
      if fa and fb and fa ~= fb then
        local key = fa .. '\0' .. fb
        if not between[key] then between[key] = { from = fa, to = fb } end
        degree[fa], degree[fb] = (degree[fa] or 0) + 1, (degree[fb] or 0) + 1
      elseif fb and not fa then into[a.module] = (into[a.module] or 0) + 1
      elseif fa and not fb then out[b.module] = (out[b.module] or 0) + 1 end
    end
  end
  local prefix = module:find('^%(') and '' or (module .. '/')
  local function item(file)
    local f = files[file]
    local name = file:sub(1, #prefix) == prefix and file:sub(#prefix + 1) or file
    local detail = count(f.functions or 0, 'function', 'functions') .. ((f.types or 0) > 0 and (' · ' .. count(f.types, 'type', 'types')) or '')
    return { name = name, detail = detail, target = { kind = 'file', module = module, file = file } }
  end
  local function parts(list)
    local items = {}
    for name, n in pairs(list) do
      items[#items + 1] = { name = name, detail = count(n, 'call', 'calls'), weight = n, rank = name:sub(1, 1) == '(' and 1 or 0,
                            target = { kind = 'module', module = name } }
    end
    return items
  end
  local sections = {}
  side(sections, 'called from', parts(into))
  if #sections > 0 then sections[#sections + 1] = { arrow = true } end
  local edges = {}
  for _, e in pairs(between) do edges[#edges + 1] = e end
  table.sort(edges, function(a, b)
    if a.from ~= b.from then return a.from < b.from end
    return a.to < b.to
  end)
  layered(sections, keys, edges, item, degree, M.MAX_BOXES)
  local below = {}
  side(below, 'calls out', parts(out))
  if #below > 0 then sections[#sections + 1] = { arrow = true }; vim.list_extend(sections, below) end
  if (answer.more or 0) > 0 then sections[#sections + 1] = { head = answer.more .. ' more functions in this part were left out' } end
  return { crumbs = { 'parts', module }, sections = sections }
end

-- The functions and classes of one file (or of a part with no files, or of one class): in layers by the calls among
-- them, the functions elsewhere that call in above, what they call elsewhere below.
function M.level_nodes(answer, module, file, class)
  local by, inside, keys = node_index(answer), {}, {}
  local methods = {}
  for _, e in ipairs(answer.edges or {}) do
    if e.kind == 'contains' then methods[e.from] = (methods[e.from] or 0) + 1 end
  end
  local members = {}
  if class then
    for _, e in ipairs(answer.edges or {}) do if e.kind == 'contains' and e.from == class.id then members[e.to] = true end end
  end
  for _, n in ipairs(answer.nodes or {}) do
    local mine = n.module == module and (file == nil or n.file == file) and (not class or members[n.id])
    if mine then inside[n.id] = true; keys[#keys + 1] = n.id end
  end
  local edges, degree, callers, callees = {}, {}, {}, {}
  for _, e in ipairs(answer.edges or {}) do
    if calls(e.kind) and by[e.from] and by[e.to] then
      local a, b = inside[e.from], inside[e.to]
      if a and b then
        edges[#edges + 1] = e
        degree[e.from], degree[e.to] = (degree[e.from] or 0) + 1, (degree[e.to] or 0) + 1
      elseif b and not a then callers[e.from] = (callers[e.from] or 0) + 1
      elseif a and not b then callees[e.to] = (callees[e.to] or 0) + 1 end
    end
  end
  local function item(id)
    local n = by[id]
    local detail = n.line and ('line ' .. n.line) or where(n)
    if n.kind == 'type' then
      detail = detail .. ' · ' .. (methods[id] and count(methods[id], 'method', 'methods') or 'type')
      if methods[id] then return { name = n.label, detail = detail, target = { kind = 'class', module = module, file = n.file, id = id, node = n } } end
    end
    if n.detail and n.file then detail = detail .. ' · ' .. n.detail end
    return node_item(n, { detail = detail })
  end
  local function others(list)
    local items = {}
    for id, weight in pairs(list) do items[#items + 1] = node_item(by[id], { weight = weight, rank = by[id].file and 0 or 1 }) end
    return items
  end
  local sections = {}
  if class then
    sections[#sections + 1] = { boxes = { node_item(class.node or by[class.id] or { label = class.name, id = class.id }) }, frame = 'double' }
    sections[#sections + 1] = { arrow = true }
  end
  side(sections, 'called from', others(callers))
  if #sections > (class and 2 or 0) then sections[#sections + 1] = { arrow = true } end
  if #keys == 0 then sections[#sections + 1] = { head = 'nothing here' } end
  layered(sections, keys, edges, item, degree, M.MAX_BOXES)
  local below = {}
  side(below, 'calls out', others(callees))
  if #below > 0 then sections[#sections + 1] = { arrow = true }; vim.list_extend(sections, below) end
  local crumbs = { 'parts', module }
  if file then crumbs[#crumbs + 1] = file:sub(#module + 2) ~= '' and module:sub(1, 1) ~= '(' and file:sub(#module + 2) or file end
  if class then crumbs[#crumbs + 1] = class.name end
  return { crumbs = crumbs, sections = sections }
end

-- A query's answer (desk-work map query --q reach|callers|paths).
function M.level_query(answer)
  local sections = {}
  if answer.q == 'paths' then
    local by = node_index(answer)
    local from, to = answer.from or {}, answer.to or {}
    sections[#sections + 1] = { head = 'ways from ' .. (from.label or '?') .. ' to ' .. (to.label or '?') .. ' · ' .. #(answer.paths or {}) }
    if #(answer.paths or {}) == 0 then
      sections[#sections + 1] = { parts = { { (from.label or '?') .. ' does not reach ' .. (to.label or '?') .. ' in the map within ' .. (answer.depth or '?') .. ' calls' } }, group = 'DeskMapDim' }
    end
    for i, p in ipairs(answer.paths or {}) do
      local parts, by_name = { { string.format('%2d  ', i) } }, false
      for k, id in ipairs(p.nodes or {}) do
        local n = by[id] or { id = id, label = id }
        if k > 1 then parts[#parts + 1] = { ' → ' } end
        parts[#parts + 1] = { n.label, node_item(n) }
        if p.kinds and p.kinds[k] == 'call-by-name' then by_name = true end
      end
      if by_name then parts[#parts + 1] = { '  (by name)' } end
      sections[#sections + 1] = { parts = parts }
    end
    if answer.capped then sections[#sections + 1] = { parts = { { 'There may be more ways; the answer stops at ' .. (answer.max or '?') .. '.' } }, group = 'DeskMapDim' } end
    return { crumbs = { 'ways' }, sections = sections }
  end
  local backwards = answer.q == 'callers'
  local cycle, capped = {}, {}
  for _, s in ipairs(answer.steps or {}) do
    local far = backwards and s.from or s.to
    if s.cycle then cycle[far] = true end
    if s.mark == 'capped' then capped[far] = true end
  end
  local tiers, deepest = {}, 0
  for _, n in ipairs(answer.nodes or {}) do
    local d = n.depth or 0
    tiers[d] = tiers[d] or {}
    table.insert(tiers[d], n)
    deepest = math.max(deepest, d)
  end
  local function item(n)
    local detail = where(n)
    if cycle[n.id] then detail = detail .. ' · in a cycle' end
    if capped[n.id] then detail = detail .. (backwards and ' · called from more' or ' · calls more') end
    return node_item(n, { detail = detail, warn = cycle[n.id] or nil })
  end
  local start = answer.from or (tiers[0] and tiers[0][1]) or {}
  local order = {}
  for d = 1, deepest do order[#order + 1] = d end
  if backwards then order = vim.fn.reverse(order) end
  local function tier(d)
    local list = tiers[d] or {}
    local more = math.max(0, #list - M.MAX_TIER)
    local items = {}
    for i = 1, math.min(#list, M.MAX_TIER) do items[i] = item(list[i]) end
    sections[#sections + 1] = { boxes = items, more = more }
  end
  local label = (backwards and 'who calls ' or 'what ') .. (start.label or '?') .. (backwards and '' or ' reaches') .. ' · depth ' .. (answer.depth or '?')
  sections[#sections + 1] = { head = label }
  if not backwards then sections[#sections + 1] = { boxes = { item(start) }, frame = 'double' } end
  for _, d in ipairs(order) do
    if not backwards or d ~= order[1] then sections[#sections + 1] = { arrow = true } end
    tier(d)
  end
  if backwards then
    if #order > 0 then sections[#sections + 1] = { arrow = true } end
    sections[#sections + 1] = { boxes = { item(start) }, frame = 'double' }
  end
  if #order == 0 then sections[#sections + 1] = { head = backwards and 'nothing in the map calls it' or 'it calls nothing in the map' } end
  if (answer.more or 0) > 0 then sections[#sections + 1] = { head = answer.more .. ' more calls were left out' } end
  return { crumbs = { backwards and 'callers' or 'reach' }, sections = sections }
end

-- ─── the view ──────────────────────────────────────────────────────────────────────────────────────────────────
local views = {}
M.views = views

local function highlights()
  for name, link in pairs({ DeskMapFocus = 'Title', DeskMapBox = 'FloatBorder', DeskMapName = 'Function', DeskMapDim = 'Comment',
    DeskMapHead = 'Comment', DeskMapTitle = 'Title', DeskMapStale = 'DiagnosticWarn' }) do
    api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

local function valid(view) return view and api.nvim_buf_is_valid(view.buf) and api.nvim_win_is_valid(view.win) and views[view.buf] == view end

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
end

-- A key of this view as typed ("Enter", "BS", "r"), read from its row: the words that name a key follow the row.
local function typed(id)
  local key = actions.key(id:find('%.') and id or ('map.' .. id))
  return key == '<CR>' and 'Enter' or key == '<BS>' and 'BS' or key or '?'
end
-- 'no map built yet · R builds it' in the theme's voice, the key as typed (in retro r and R are two keys).
local function with_key(G, before, id, after) return G.said(before) .. typed(id) .. G.said(after) end
local function no_map(G) return with_key(G, 'no map built yet · ', 'rebuild', ' builds it') end
-- What every reader needs and does not have here (a folder that is no git checkout, and no binary given), else nil: the
-- page and its keys say that first, and offer no rebuild that cannot run.
local function unbuildable(s)
  if not s or s.built or s.building or #(s.providers or {}) == 0 then return nil end
  local needs = {}
  for _, p in ipairs(s.providers) do
    if (p.why or '') == '' then return nil end
    needs[#needs + 1] = { name = p.name, why = p.why, short = p.why:match('^(.-) %(') or p.why }
  end
  return needs
end

function M.header(view, G)
  local s = view.status
  local out = { { G.said('project map · ' .. vim.fn.fnamemodify(view.root, ':t')), 'DeskMapTitle' } }
  if view.missing then out[#out + 1] = { G.said('requires desk-work'), 'DeskMapStale' }
  elseif view.building or (s and s.building) then
    out[#out + 1] = { G.said('rebuilding' .. G.ellipsis .. ' started ' .. os.date('%H:%M', s and s.building_since or view.building_at or os.time())), 'DeskMapDim' }
  elseif not s then out[#out + 1] = { G.said('reading' .. G.ellipsis), 'DeskMapDim' }
  elseif unbuildable(s) then out[#out + 1] = { G.said(unbuildable(s)[1].short), 'DeskMapStale' }
  elseif not s.built then out[#out + 1] = { no_map(G), 'DeskMapStale' }
  elseif s.stale then
    out[#out + 1] = { with_key(G, 'stale since ' .. short(s.head) .. ' · ', 'rebuild', ' rebuilds'), 'DeskMapStale' }
    if (s.stale_why or '') ~= '' then out[#out + 1] = { s.stale_why, 'DeskMapDim' } end
  else out[#out + 1] = { G.said('built ' .. os.date('%H:%M', s.built_at or 0) .. ' at ' .. short(s.head)), 'DeskMapDim' } end
  return out
end

-- The key line at the foot of the page: the keys that matter here (? lists every one), as typed, in the theme's voice.
local KEY_LINE = { { 'in', 'in' }, { 'back', 'out' }, { 'reach', 'reach' }, { 'callers', 'callers' }, { 'paths', 'paths' },
  { 'desk.keys', 'keys' }, { 'close', 'close' } }

function M.footer(view, G)
  G = G or M.glyphs(M.retro())
  local s, notes, answered = view.status or {}, {}, {}
  for _, p in ipairs(s.providers or {}) do
    if p.state == 'ok' then
      answered[#answered + 1] = p.name == 'syntax' and 'syntax (calls by name: overloads, macros and virtual dispatch are not resolved)'
        or ('binary (exact calls in ' .. vim.fn.fnamemodify(p.binary or '', ':t') .. ' after inlining)')
    end
  end
  if #answered > 0 then notes[#notes + 1] = 'answered by ' .. table.concat(answered, ' · ') end
  for _, p in ipairs(unbuildable(view.status) and {} or s.providers or {}) do   -- (else the page itself says them)
    if p.state ~= 'ok' then notes[#notes + 1] = p.name .. ': ' .. ((p.why or '') ~= '' and p.why or 'not built yet') end
  end
  if s.complete == false and s.why then notes[#notes + 1] = 'partial: ' .. s.why end
  local keys = {}
  for _, k in ipairs(KEY_LINE) do keys[#keys + 1] = typed(k[1]) .. ' ' .. G.said(k[2]) end
  notes[#notes + 1] = { table.concat(keys, ' · ') }
  return notes
end

-- What was read for a level; while a rebuilt map is read again, what was read before it.
local function cached(view, key) return view.cache[key] or (view.previous or {})[key] end

local function page_of(view)
  local level = view.stack[#view.stack]
  if level.kind == 'modules' then return cached(view, 'modules') and M.level_modules(cached(view, 'modules')) end
  if level.kind == 'query' then return M.level_query(level.answer) end
  local answer = cached(view, 'module:' .. level.module)
  if not answer then return nil end
  if level.kind == 'files' then return M.level_files(answer, level.module) end
  if level.kind == 'functions' then return M.level_nodes(answer, level.module, level.file) end
  if level.kind == 'class' then return M.level_nodes(answer, level.module, level.file, { id = level.id, name = level.name, node = level.node }) end
end

function M.render(view)
  if not valid(view) then return end
  local retro = M.retro()
  local G = M.glyphs(retro)
  local page
  local s = view.status
  if view.missing then page = { sections = { { parts = { { M.REQUIRES } }, group = 'DeskMapStale' } } }
  elseif view.message then page = { sections = { { parts = { { view.message } }, group = 'DeskMapStale' } } }
  elseif unbuildable(s) and not view.building then
    page = { sections = {} }
    for _, need in ipairs(unbuildable(s)) do
      table.insert(page.sections, { parts = { { need.name .. ': ' .. need.why } }, group = 'DeskMapStale' })
    end
  elseif s and not s.built and not s.building and not view.building then
    page = { sections = { { parts = { { 'No map built yet. ' .. typed('rebuild') .. ' builds it in the background (a desk-work job; its log is in the' } } },
                          { parts = { { 'jobs list), and this page fills in when it is done.' } } } } }
  else
    local waiting = ((view.building or (s and s.building)) and 'The map is being built' or 'Reading the map') .. G.ellipsis
    page = page_of(view) or { sections = { { parts = { { waiting } }, group = 'DeskMapDim' } } }
  end
  page.header = M.header(view, G)
  if page.crumbs then table.insert(page.header, { table.concat(page.crumbs, G.crumb), 'DeskMapDim' }) end
  table.insert(page.header, { '' })
  page.notes = M.footer(view, G)
  view.drawn = M.layout(page, api.nvim_win_get_width(view.win) - 2, retro)
  draw(view.buf, view.drawn)
end

local function status(view, after)
  M.desk_work({ 'map', 'status', '--root', view.root }, function(answer, out)
    if not valid(view) then return end
    -- The first read failing is the page's news (desk-work missing, a broken record); a later one keeps the page.
    if answer and answer.ok ~= false then view.status, view.missing = answer, nil
    elseif out and out.missing then view.missing = true
    elseif not view.status then view.message = refusal(answer, out) end
    if after then after(view.status) end
    M.render(view)
  end, 30000)
end

-- The cursor where it was on this level, else on the first box (its name line), so Enter works at once.
local function place_cursor(view)
  local level = view.stack[#view.stack]
  if level.cursor then return pcall(api.nvim_win_set_cursor, view.win, level.cursor) end
  local hits, first = view.drawn and view.drawn.hits or {}, nil
  for lnum in pairs(hits) do first = first and math.min(first, lnum) or lnum end
  if not first then return end
  local line = hits[first + 1] and hits[first + 1][1].item == hits[first][1].item and first + 1 or first
  pcall(api.nvim_win_set_cursor, view.win, { line, hits[line][1].s + (line ~= first and 4 or 0) })
end

-- The level on top of the stack: drawn from what was read for it, else read in the background.
local function load(view)
  local level = view.stack[#view.stack]
  local key = level.kind == 'modules' and 'modules' or level.module and ('module:' .. level.module)
  view.message = nil
  if not key or view.cache[key] or not (view.status and view.status.built) then M.render(view); return place_cursor(view) end
  view.gen = view.gen + 1
  local gen = view.gen
  local args = { 'map', 'query', '--root', view.root, '--q', 'module', '--cap', '2000' }
  if level.module then vim.list_extend(args, { '--name', level.module }) end
  M.render(view)
  M.desk_work(args, function(answer, out)
    if gen ~= view.gen or not valid(view) then return end
    if out and out.missing then view.missing = true
    elseif not answer or answer.ok == false then view.message = refusal(answer, out) else view.cache[key] = answer end
    M.render(view)
    place_cursor(view)
  end)
end

local function stop_polling(view)
  if view.timer then view.timer:stop(); view.timer:close(); view.timer = nil end
end

-- While a build runs: its status once a second (one read at a time); when it is done, the map is read again.
local function poll(view)
  if view.timer then return end
  view.timer = uv.new_timer()
  local started = uv.now()
  view.tick = function()
    if not valid(view) then return stop_polling(view) end
    if view.polling then return end
    view.polling = true
    M.desk_work({ 'map', 'status', '--root', view.root }, function(answer)
      view.polling = false
      if not valid(view) then return stop_polling(view) end
      if answer and answer.ok ~= false then view.status = answer end
      if answer and answer.ok ~= false and not answer.building then
        stop_polling(view)
        view.building, view.previous, view.cache = false, view.cache, {}
        -- A status read while building skips the stale check: once more, then the level.
        return status(view, function() load(view) end)
      end
      if uv.now() - started > M.BUILD_WAIT_MS then stop_polling(view); view.building = false end
      M.render(view)
    end, 10000)
  end
  view.timer:start(M.POLL_MS, M.POLL_MS, vim.schedule_wrap(view.tick))
end

function M.rebuild(view, binary)
  view = view or views[api.nvim_get_current_buf()]
  if not view then return M.build(binary) end
  local args = { 'map', 'build', '--root', view.root }
  if binary then vim.list_extend(args, { '--binary', binary }) end
  view.building, view.building_at = true, os.time()
  M.render(view)
  M.desk_work(args, function(answer, out)
    if not valid(view) then return end
    if not answer or answer.ok == false then
      view.building = false
      tell(refusal(answer, out), vim.log.levels.WARN)
      return M.render(view)
    end
    poll(view)
  end)
end

-- From outside the view: start a build of this checkout and say so.
function M.build(binary)
  local root = vim.fs.root(0, '.git') or vim.fn.getcwd()
  local args = { 'map', 'build', '--root', root }
  if binary then vim.list_extend(args, { '--binary', vim.fn.fnamemodify(binary, ':p') }) end
  M.desk_work(args, function(answer, out)
    if not answer or answer.ok == false then return tell(refusal(answer, out), vim.log.levels.WARN) end
    tell((answer.message or 'Building the project map') .. '; :ProjectMap shows it.')
  end)
end

local function here(view)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= view.buf then win = view.win end
  local cursor = api.nvim_win_get_cursor(win)
  return M.item_at(view.drawn, cursor[1], cursor[2])
end
local function node_here(view)
  local item = here(view)
  return item and item.target and item.target.node or nil
end

local function push(view, level)
  view.stack[#view.stack].cursor = api.nvim_win_get_cursor(view.win)
  view.stack[#view.stack + 1] = level
  load(view)
end

-- Out a level (from a query's answer, back to the page it was asked on); at the top, back to the code window the map
-- was opened from, the map left open: Space cm brings it back as it was.
local function back(view)
  if #view.stack > 1 then
    table.remove(view.stack)
    return load(view)
  end
  if view.origin and view.origin ~= view.win and api.nvim_win_is_valid(view.origin) then return api.nvim_set_current_win(view.origin) end
  if #api.nvim_list_tabpages() > 1 then return vim.cmd('tabprevious') end
  tell('This is the top: the parts of the checkout.')
end

local function jump(view, node)
  if not node.file then return tell(node.label .. ' has no source in this checkout (' .. (node.detail or 'binary only') .. ').') end
  local path = view.root .. '/' .. node.file
  if view.origin and api.nvim_win_is_valid(view.origin) then api.nvim_set_current_win(view.origin) else vim.cmd('tabnew') end
  if not pcall(vim.cmd.edit, vim.fn.fnameescape(path)) then vim.cmd('tabedit ' .. vim.fn.fnameescape(path)) end
  local line = math.max(1, math.min(tonumber(node.line) or 1, api.nvim_buf_line_count(0)))
  local text = api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ''
  api.nvim_win_set_cursor(0, { line, math.max(0, (text:find('%S') or 1) - 1) })
end

local function enter(view)
  local item = here(view)
  local t = item and item.target
  if not t then return end
  if t.kind == 'module' then push(view, { kind = 'files', module = t.module })
  elseif t.kind == 'file' then push(view, { kind = 'functions', module = t.module, file = t.file })
  elseif t.kind == 'class' then push(view, { kind = 'class', module = t.module, file = t.file, id = t.id, name = item.name, node = t.node })
  elseif t.kind == 'node' then jump(view, t.node) end
end

local function ask(prompt, default, done)
  vim.ui.input({ prompt = prompt, default = default or '' }, function(text)
    if text and vim.trim(text) ~= '' then done(vim.trim(text)) end
  end)
end

-- A query: its answer goes on the stack as a page of its own (Backspace goes back). A name that fits several things
-- asks which one, then asks desk-work again with its id.
local function query(view, args)
  local full = { 'map', 'query', '--root', view.root }
  vim.list_extend(full, args)
  view.gen = view.gen + 1
  local gen = view.gen
  M.desk_work(full, function(answer, out)
    if gen ~= view.gen or not valid(view) then return end
    if answer and answer.ok == false and type(answer.candidates) == 'table' and #answer.candidates > 0 then
      local flag = (answer.message or ''):find('^To: ') and '--to' or '--from'
      return vim.ui.select(answer.candidates, { prompt = answer.message, format_item = function(n) return n.label .. '  ' .. where(n) end }, function(choice)
        if not choice then return end
        local again = vim.list_slice(args)
        for i = 1, #again - 1 do if again[i] == flag then again[i + 1] = choice.id end end
        query(view, again)
      end)
    end
    if not answer or answer.ok == false then return tell(refusal(answer, out), vim.log.levels.WARN) end
    push(view, { kind = 'query', answer = answer })
  end)
end

local function name_of(node, typed) return node and typed == node.label and node.id or typed end

local function walk(view, q)
  local node, depth = node_here(view), vim.v.count > 0 and vim.v.count or 3
  ask(q == 'reach' and 'Reach from: ' or 'Callers of: ', node and node.label, function(name)
    query(view, { '--q', q, '--from', name_of(node, name), '--depth', tostring(depth) })
  end)
end

local function ways(view)
  local node = node_here(view)
  ask('Ways from: ', node and node.label, function(from)
    ask('… to: ', '', function(to) query(view, { '--q', 'paths', '--from', name_of(node, from), '--to', to }) end)
  end)
end

-- The parts in the menu every desk view uses (symdeps' when it is installed, else the built-in one): / filters them
-- by name, Enter goes there.
local function part(view)
  local modules = cached(view, 'modules')
  if not modules then return tell('The map is not read yet.') end
  local items = {}
  for _, m in ipairs(modules.modules or {}) do
    items[#items + 1] = { name = m.name, label = m.name .. ' — ' .. part_size(m), run = function()
      if not valid(view) then return end
      view.stack = { view.stack[1] }
      push(view, { kind = 'files', module = m.name })
    end }
  end
  require('desk.review').show_menu(items, { title = 'Part of the checkout', anchor_win = view.win, memo = 'desk-map-part' })
end

local function binary(view)
  local current = view.status and view.status.binary
  vim.ui.input({ prompt = 'Binary to read: ', default = type(current) == 'string' and current or '', completion = 'file' }, function(path)
    if not path or vim.trim(path) == '' then return end
    path = vim.trim(path)
    if path:sub(1, 1) ~= '/' then path = view.root .. '/' .. path end
    M.rebuild(view, path)
  end)
end

function M.close(view)
  view = view or views[api.nvim_get_current_buf()]
  if not view then return end
  stop_polling(view)
  views[view.buf] = nil
  if api.nvim_win_is_valid(view.win) then
    if #api.nvim_list_tabpages() > 1 then pcall(vim.cmd, 'tabclose ' .. api.nvim_tabpage_get_number(api.nvim_win_get_tabpage(view.win)))
    else pcall(api.nvim_win_close, view.win, true) end
  end
end

-- What the map is now: its status, then the level on top (built) or the poll until the build is done (building).
local function refresh(view)
  status(view, function(s)
    if s and s.building then poll(view) end
    if s and s.built then load(view) end
  end)
end

-- Opens the map of root (default: this checkout) in a tab of its own; one tab per checkout: when it is open already,
-- it comes back as it was, and Backspace at its top goes back to the window this was pressed in.
function M.open(root)
  local here_view = views[api.nvim_get_current_buf()]
  root = root or (here_view and here_view.root) or vim.fs.root(0, '.git') or vim.fn.getcwd()
  root = uv.fs_realpath(root) or root
  highlights()
  local origin = api.nvim_get_current_win()
  for _, open in pairs(views) do
    local shown = open.root == root and valid(open) and vim.fn.win_findbuf(open.buf)[1]
    if shown then
      open.win = api.nvim_win_get_buf(open.win) == open.buf and open.win or shown
      if origin ~= open.win then open.origin = origin end
      api.nvim_set_current_win(open.win)
      return open
    end
  end
  vim.cmd('tabnew')
  local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  vim.bo[buf].filetype = 'deskmap'
  pcall(api.nvim_buf_set_name, buf, 'project map · ' .. vim.fn.fnamemodify(root, ':t') .. ' · ' .. buf)
  for opt, value in pairs({ number = false, relativenumber = false, signcolumn = 'no', wrap = false, list = false, spell = false, cursorline = false }) do
    vim.wo[win][opt] = value
  end
  local view = { buf = buf, win = win, origin = origin, root = root, stack = { { kind = 'modules' } }, cache = {}, gen = 0 }
  views[buf] = view
  -- Its keys are the rows on the 'map' surface (the keys section below); each run gets ctx.map, this view.
  actions.map('map', { buffer = buf, nowait = true, ctx = { map = view } })
  local group = api.nvim_create_augroup('desk_map_' .. buf, { clear = true })
  api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, once = true, callback = function()
    stop_polling(view)
    views[buf] = nil
    pcall(api.nvim_del_augroup_by_id, group)
  end })
  -- Back on the page: is the map still current, or desk-work there now? (While a build runs, the poll says so.)
  api.nvim_create_autocmd('BufEnter', { group = group, buffer = buf, callback = function()
    if view.timer then return end
    if view.missing then refresh(view) elseif view.status then status(view) end
  end })
  api.nvim_create_autocmd('WinResized', { group = group, callback = function()
    if valid(view) and vim.tbl_contains(vim.v.event.windows or {}, view.win) then M.render(view) end
  end })
  -- A job's record changing (this build ending) is worth a status read at once rather than at the next tick.
  api.nvim_create_autocmd('User', { group = group, pattern = 'FoxWorkChanged', callback = function(a)
    if view.tick and type(a.data) == 'table' and a.data.root == root then view.tick() end
  end })
  M.render(view)
  refresh(view)
  return view
end

-- ─── the keys ──────────────────────────────────────────────────────────────────────────────────────────────────
-- Rows of the action registry (desk/actions.lua): the mappings, which-key's words, the home menu, the ? list and the
-- keybinds reference all read them. The view is the 'map' surface and a run gets ctx.map, the view it was pressed in;
-- Space cm is a global key. The page's key line and its badges take their keys from these rows (typed).
local GROUP = 'Project map'
local function sentence(text) text = tostring(text); return text:sub(1, 1):upper() .. text:sub(2) .. (text:match('[.!?]$') and '' or '.') end
-- What a row needs (desk-work; for a question to the map, a map built): why not, or true. The menus show the why
-- beside the row; a key pressed when its row cannot run says it.
local function needs_desk_work(ctx) return not (ctx.map and ctx.map.missing) or 'requires desk-work' end
local function needs_map(ctx)
  local why = needs_desk_work(ctx)
  if why ~= true then return why end
  local view, s = ctx.map, ctx.map and ctx.map.status
  if unbuildable(s) then return unbuildable(s)[1].short end
  return not (s and not s.built and not s.building and not view.building) or no_map(M.glyphs(false))
end
-- A rebuild needs a reader that can run here (a remembered binary can, outside a checkout too).
local function needs_reader(ctx)
  local why = needs_desk_work(ctx)
  if why ~= true then return why end
  local needs = unbuildable(ctx.map and ctx.map.status)
  return not needs or needs[1].short
end
local function row(id, key, name, about, run, needs, extra)
  local r = { id = 'map.' .. id, group = GROUP, name = name, about = about, key = key, on = 'map', available = needs,
    run = function(ctx)
      local view = ctx and ctx.map
      if not valid(view) then return end
      local why = needs and needs(ctx)
      if why ~= nil and why ~= true then return tell(sentence(why), vim.log.levels.WARN) end
      run(view)
    end }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end
local ROWS = actions.add({
  { id = 'map.open', group = GROUP, name = 'Project map', key = '<leader>cm', on = 'editor', remote = true, also = '`:ProjectMap`',
    about = 'The whole checkout as boxes, by part, file and function, callers above; queries and a rebuild inside. One tab per checkout: pressed again, it brings that tab back as it was',
    -- In the map itself its own keys apply; without desk-work the page opens and says so.
    available = function(ctx) return ctx.surface ~= 'map' or false end,
    run = function() M.open() end },
  row('in', '<CR>', 'Zoom in, or go to the function',
    'Zoom into the part, file or class under the cursor; on a function, go to its code (the map stays open)', enter),
  row('back', '<BS>', 'Zoom out, or back to the code',
    "Zoom out a level (from a query's answer, back to the page it was asked on); at the top, back to the code, the map left open", back),
  row('out', '-', 'Zoom out', 'Zoom out a level', back, nil, { line = 'map.back', menu = false }),
  row('reach', 'r', 'What a function reaches', 'Everything a function reaches (a count before r is the depth; 3 without one)',
    function(view) walk(view, 'reach') end, needs_map),
  row('callers', 'c', 'Who calls a function', 'Who calls a function, transitively (a count before c is the depth)',
    function(view) walk(view, 'callers') end, needs_map),
  row('paths', 'P', 'The ways between two functions', 'Every way from one function to another, shortest first', ways, needs_map),
  row('module', 'm', 'A part of the checkout', 'Go to a part of the checkout, picked by name', part, needs_map),
  row('rebuild', 'R', 'Rebuild the map', 'Rebuild the map in the background (a desk-work job; its log is in the jobs list)',
    function(view) M.rebuild(view) end, needs_reader),
  row('binary', 'B', 'Rebuild reading a binary', 'Rebuild, reading a built binary for its exact calls (remembered for the next builds)',
    binary, needs_desk_work),
  row('close', 'q', 'Close the project map', 'Close the project map', function(view) M.close(view) end),
})

-- ─── setup ─────────────────────────────────────────────────────────────────────────────────────────────────────
local set = false
function M.setup()
  if set then return end
  set = true
  api.nvim_create_user_command('ProjectMap', function() M.open() end, { desc = 'The project map of this checkout' })
  api.nvim_create_user_command('ProjectMapBuild', function(o) M.build(o.args ~= '' and o.args or nil) end,
    { nargs = '?', complete = 'file', desc = 'Rebuild the project map in the background (optionally reading a binary)' })
  actions.map('editor', { rows = ROWS })
end

-- nvim --headless --clean -l …/desk/map.lua --syntax-graph REQUEST ANSWER: desk-work's syntax reader (the top of this
-- file put the modules beside it on package.path).
if headless then
  vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/site')
  local ok, request = pcall(vim.json.decode, read_file(arg[2] or '', 64 * 1024 * 1024) or '')
  local answered, result = pcall(M.syntax_graph, ok and type(request) == 'table' and request or {})
  if not answered then io.stderr:write('map: the syntax reader failed: ' .. tostring(result) .. '\n'); os.exit(1) end
  local temp = arg[3] .. '.' .. uv.os_getpid() .. '.tmp'
  local f = assert(io.open(temp, 'wb'))
  f:write(vim.json.encode(result))
  f:close()
  assert(os.rename(temp, arg[3]))
end

return M
