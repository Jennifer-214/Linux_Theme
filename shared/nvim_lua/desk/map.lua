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
M.POLL_MS, M.BUILD_WAIT_MS = 1000, 15 * 60 * 1000

local function tell(text, level) vim.notify(text, level or vim.log.levels.INFO, { title = 'Project map' }) end
local function one_line(s) return vim.trim(tostring(s or ''):gsub('%s+', ' ')) end

-- ─── the syntax reader (run headless by desk-work) ─────────────────────────────────────────────────────────────
-- A call per language: its node type and the field that names what it calls.
--- pure: text from the source, at most n bytes, cut at a character and never inside one (2026-11-19: a → split at 80
--- bytes made the reader's answer invalid JSON, and desk-work dropped the trader's whole map for it).
function M.cut_text(text, n)
  text = tostring(text or '')
  if #text <= n then return text end
  local i = n
  -- back to the start of the character byte n + 1 belongs to (UTF-8 continuation bytes are 0x80-0xBF)
  while i > 0 and (text:byte(i + 1) or 0) >= 0x80 and (text:byte(i + 1) or 0) < 0xC0 do i = i - 1 end
  return text:sub(1, i)
end
local cut_text = M.cut_text
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

-- ─── signatures (C and C++): what a function takes and gives, for the trace ─────────────────────────────────
-- The declarators around a name, outermost first ('*' with const when the pointer itself is const, '&', '&&', '[]'),
-- and the name; or, reaching a function's declarator, the marks so far (its return's) and that declarator.
local NAME_NODES = { identifier = true, field_identifier = true, qualified_identifier = true, destructor_name = true,
  operator_name = true, type_identifier = true }
local function has_const(node, src)
  for child in node:iter_children() do
    if child:type() == 'type_qualifier' and one_line(text_of(child, src)) == 'const' then return true end
  end
  return false
end
local function declarators(decl, src)
  local marks, d = {}, decl
  for _ = 1, 12 do
    if not d then return marks end
    local t = d:type()
    if NAME_NODES[t] then return marks, one_line(text_of(d, src)) end
    if t == 'function_declarator' then return marks, nil, d end
    if t:find('pointer_declarator', 1, true) then marks[#marks + 1] = { '*', const = has_const(d, src) }
    elseif t:find('reference_declarator', 1, true) then marks[#marks + 1] = { one_line(text_of(d, src)):match('^&&') and '&&' or '&' }
    elseif t:find('array_declarator', 1, true) then marks[#marks + 1] = { '[]' } end
    local inner = d:field('declarator')[1]
    if not inner then
      for child in d:iter_children() do if child:named() and child:type() ~= 'type_qualifier' then inner = child end end
    end
    d = inner
  end
  return marks
end
local function written(const, type_node, marks, src)
  local base = (const and 'const ' or '') .. (type_node and one_line(text_of(type_node, src)) or '')
  local tail = table.concat(vim.tbl_map(function(m) return m[1] .. (m.const and ' const' or '') end, marks or {}), '')
  return cut_text(tail ~= '' and (base .. ' ' .. tail) or base, 120)
end
-- How a parameter is passed: the declarator nearest its name applies to it (`int *& p` is a reference to a pointer).
-- in: the callee cannot write the caller's value through it; inout: a non-const reference, pointer or array, it can.
function M.passing(const, type_text, marks)
  local m = marks[#marks] and marks[#marks][1]
  local pass
  if m == '&&' then pass = 'rvalue'
  elseif m == '&' then pass = const and 'const ref' or 'ref'
  elseif m == '*' then pass = const and 'const pointer' or 'pointer'
  elseif m == '[]' then pass = const and 'const array' or 'array'
  elseif tostring(type_text):find('_ptr<', 1, true) then pass = 'smart'
  else pass = 'value' end
  return pass, (pass == 'ref' or pass == 'pointer' or pass == 'array') and 'inout' or 'in'
end
-- A C or C++ function node's parameters (at most 16: { name, type as written, pass, dir }; params_more: how many more
-- it has) and its return type (nil for a constructor or destructor). nil when no function declarator is found.
function M.signature(node, src)
  local marks, _, fn = declarators(node:field('declarator')[1], src)
  if not fn then return nil end
  local type_node = node:field('type')[1]
  local params, list, more = {}, fn:field('parameters')[1], 0
  for child in (list and list:iter_children() or function() end) do
    local t = child:named() and child:type() or ''
    if (t:find('parameter_declaration', 1, true) or t == 'variadic_parameter') and #params >= 16 then more = more + 1
    elseif t:find('parameter_declaration', 1, true) and #params < 16 then
      local const, ty = has_const(child, src), child:field('type')[1]
      local pmarks, name = declarators(child:field('declarator')[1], src)
      local type_text = ty and one_line(text_of(ty, src)) or ''
      if not (type_text == 'void' and not name and #pmarks == 0) then
        local pass, dir = M.passing(const, type_text, pmarks)
        params[#params + 1] = { name = cut_text(name or '', 64), type = written(const, ty, pmarks, src), pass = pass, dir = dir }
      end
    elseif (t == 'variadic_parameter' or (not child:named() and child:type() == '...')) and #params < 16 then
      params[#params + 1] = { name = '...', type = '...', pass = 'value', dir = 'in' }
    end
  end
  return { params = params, params_more = more > 0 and more or nil, returns = type_node and written(has_const(node, src), type_node, marks, src) or nil }
end
-- A parameter's uses: the fields read and the fields written, each named once in each (one both read and changed
-- is in both); at most 12 of each, reads_more / writes_more counting the other paths left out.
function M.note_use(prm, path, wrote)
  if path == '' or #path > 80 then return end
  local list = wrote and 'writes' or 'reads'
  prm[list] = prm[list] or {}
  if vim.tbl_contains(prm[list], path) then return end
  if #prm[list] < 12 then prm[list][#prm[list] + 1] = path
  else
    prm.seen_more = prm.seen_more or {}
    local key = list .. '\0' .. path
    if not prm.seen_more[key] then prm.seen_more[key] = true; prm[list .. '_more'] = (prm[list .. '_more'] or 0) + 1 end
  end
end
-- A call's arguments as written (at most 12, each on one line, at most 80 characters), and how many more it has.
local function list_texts(list, src)
  local out, more = {}, 0
  for child in (list and list:iter_children() or function() end) do
    if child:named() and not child:type():find('comment', 1, true) then
      if #out < 12 then out[#out + 1] = cut_text(one_line(text_of(child, src)), 80) else more = more + 1 end
    end
  end
  return out, more
end
local function call_args(node, src) return list_texts(node:field('arguments')[1], src) end
M._call_args = call_args

-- ─── handoffs: where data or control moves without a call between the two functions ───
-- Seen while reading: a push or a pop on an object (its last name: `&core->tick_ring` is tick_ring; a method's
-- receiver, else the call's first argument), a function passed by name to a call (a thread start, a callback), and a
-- function pointer set (field → the function named). Joined once every file is read (M.handoff_edges).
local PUSHES, POPS = { 'push', 'enqueue', 'publish', 'submit_to' }, { 'pop', 'dequeue', 'consume', 'drain' }
local function last_name(text)
  -- `&tick_rings[tt::NodeIdx{c}]` is tick_rings: subscripts and braces go first.
  local bare = tostring(text or ''):gsub('%b[]', ''):gsub('%b{}', '')
  local name = bare:gsub('[%s%(%)%*&]', ''):match('([%a_][%w_]*)$')
  return name
end
local function is_op(short, words)
  local lower = short:lower()
  for _, w in ipairs(words) do if lower:find(w, 1, true) then return true end end
  return false
end
function M.note_handoff(ops, passed, owner, full, short, args, line)
  local op = is_op(short, PUSHES) and 'push' or is_op(short, POPS) and 'pop' or nil
  if op then
    -- A method's receiver (q.push, ring->pop), else the first argument (Ring_Push(&ring, …)); a `::` qualifier is a
    -- namespace or class (tt::SPSCRing_TryPop, ImPlot::PushStyleColor), not an object.
    local qualifier = full:sub(1, #full - #short)
    local receiver = qualifier:find('::$') and '' or qualifier:gsub('[%.:]+$', '')
    local object = last_name(receiver ~= '' and receiver or (args or {})[1])
    if object and #object >= 3 and object ~= 'this' and object ~= 'self' then
      ops[#ops + 1] = { owner = owner, object = object, op = op, line = line }
    end
  end
  for _, arg in ipairs(args or {}) do
    local name = arg:gsub('^&', '')
    if name:match('^[%a_][%w_:]*$') then passed[#passed + 1] = { owner = owner, name = name, via = short, line = line } end
  end
end
function M.note_pointer(pointers, field, value, line)
  local name = tostring(value):gsub('^&', '')
  if field:match('^[%a_][%w_]*$') and name:match('^[%a_][%w_:]*$') then
    pointers[field] = pointers[field] or {}
    table.insert(pointers[field], { name = name, line = line })
  end
end
-- The handoff edges: a push to the functions popping the same object (both sides at most 4 functions: a name more
-- functions use is too common to mean one ring), a function passed by name (one function of that name), and a call
-- through a field a function pointer was set into. Each says what it went through; none is a call. units, by_short
-- and the caller's family as the call edges use them; seen: the pairs with an edge already.
function M.handoff_edges(units, by_short, ops, passed, pointers, calls, seen, cap)
  local edges = {}
  local function unit_named(name, family)
    local pick = by_short[name:match('([%w_~]+)$') or name] or {}
    pick = vim.tbl_filter(function(k) return units[k].family == family and units[k].kind == 'function' end, pick)
    return #pick == 1 and pick[1] or nil
  end
  -- line: where it is handed over (the push, the passing, the call through the pointer); to_line: where the other side
  -- takes it (the pop), when there is one.
  local function add(from, to, label, line, to_line)
    if from == to or #edges >= cap then return end
    -- A direct call between the two says it already.
    if seen[units[from].id .. '\0' .. units[to].id] then return end
    local key = units[from].id .. '\0' .. units[to].id .. '\0handoff'
    if seen[key] then return end
    seen[key] = true
    edges[#edges + 1] = { from = units[from].id, to = units[to].id, kind = 'handoff', label = cut_text(label, 80), line = line, to_line = to_line }
  end
  -- One object under a plural and its singular (tick_rings[c] pushed, the core's tick_ring popped).
  local by_object = {}
  for _, o in ipairs(ops) do
    local key = #o.object > 4 and o.object:gsub('s$', '') or o.object
    local slot = by_object[key] or { push = {}, pop = {}, name = o.object }
    by_object[key] = slot
    if o.op == 'push' then slot.name = o.object end
    slot[o.op][o.owner] = slot[o.op][o.owner] or o.line
  end
  for _, slot in pairs(by_object) do
    local object = slot.name
    local pushers, poppers = vim.tbl_keys(slot.push), vim.tbl_keys(slot.pop)
    table.sort(pushers); table.sort(poppers)
    if #pushers >= 1 and #pushers <= 4 and #poppers >= 1 and #poppers <= 4 then
      for _, a in ipairs(pushers) do
        for _, b in ipairs(poppers) do
          add(a, b, object .. ': push :' .. slot.push[a] .. ' → pop :' .. slot.pop[b], slot.push[a], slot.pop[b])
        end
      end
    end
  end
  for _, h in ipairs(passed) do
    local to = unit_named(h.name, units[h.owner].family)
    if to then add(h.owner, to, 'passed to ' .. h.via, h.line) end
  end
  for _, c in ipairs(calls) do
    local set = pointers[c.short]
    if set and not by_short[c.short] then
      for _, target in ipairs(set) do
        local to = unit_named(target.name, units[c.from].family)
        if to then add(c.from, to, 'through ' .. c.short .. ' (set at :' .. target.line .. ')', c.line) end
      end
    end
  end
  return edges
end

-- ─── #if branches: which one a function is in, and whether the compile flags turn it on (Codex's #13) ─────────────
--- pure: a compile command's -D and -U, as { NAME = value } (value '1' when none is given; a -U takes one away).
function M.defines_of(args)
  local out = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    local d = a:match('^%-D(.+)$') or (a == '-D' and args[i + 1]) or nil
    local u = a:match('^%-U(.+)$') or (a == '-U' and args[i + 1]) or nil
    if a == '-D' or a == '-U' then i = i + 1 end
    if d then local name, value = d:match('^([%w_]+)=?(.*)$'); if name then out[name] = value ~= '' and value or '1' end end
    if u then out[u] = nil end
    i = i + 1
  end
  return out
end
-- a simple condition read against the defines: defined(X), defined X, X, !…, a number; nil when it says more than that
local function holds(cond, defines)
  cond = vim.trim(tostring(cond or ''))
  local neg = cond:match('^!%s*(.+)$')
  if neg then local v = holds(neg, defines); if v == nil then return nil end; return not v end
  local name = cond:match('^defined%s*%(%s*([%w_]+)%s*%)$') or cond:match('^defined%s+([%w_]+)$')
  if name then return defines[name] ~= nil end
  if cond:match('^%d+$') then return tonumber(cond) ~= 0 end
  if cond:match('^[%a_][%w_]*$') then local v = defines[cond]; return v ~= nil and v ~= '0' end
  return nil
end
local PREPROC = { preproc_if = true, preproc_ifdef = true, preproc_elif = true, preproc_else = true, preproc_elifdef = true }
--- The #if branch a node is in (the nearest), as written ("#ifdef LINUX", "#elif defined(MAC)", "#else (#ifdef LINUX)"),
--- and whether `defines` turn it on (nil: no flags, or a condition it cannot read). nil when it is in none.
-- An include guard (T2, 2026-11-19): #ifndef X whose first line is #define X, with no #else or #elif, at the top of
-- the file. Not a condition: every function of a header would say it.
local function include_guard(b, src)
  if b:type() ~= 'preproc_ifdef' or b:field('alternative')[1] then return false end
  if not vim.treesitter.get_node_text(b, src):match('^#%s*ifndef') then return false end
  local parent = b:parent()
  if not parent or parent:type() ~= 'translation_unit' then return false end
  local name = b:field('name')[1] and vim.treesitter.get_node_text(b:field('name')[1], src)
  for child in b:iter_children() do
    if child:named() and child ~= b:field('name')[1] then
      local def = child:type() == 'preproc_def' and child:field('name')[1]
      return def ~= nil and def ~= false and vim.treesitter.get_node_text(def, src) == name
    end
  end
  return false
end
function M.preproc_cond(node, src, defines)
  local branch = node:parent()
  while branch and (not PREPROC[branch:type()] or include_guard(branch, src)) do branch = branch:parent() end
  if not branch then return nil end
  local function head(b)
    local t = b:type()
    if t == 'preproc_ifdef' or t == 'preproc_elifdef' then
      local word = vim.treesitter.get_node_text(b, src):match('^#%s*(%a+)') or 'ifdef'
      local name = b:field('name')[1] and vim.treesitter.get_node_text(b:field('name')[1], src) or '?'
      return '#' .. word .. ' ' .. name, word:find('n') and { kind = 'ifndef', name = name } or { kind = 'ifdef', name = name }
    end
    local c = b:field('condition')[1] and vim.trim((vim.treesitter.get_node_text(b:field('condition')[1], src):gsub('%s+', ' '))) or ''
    return '#' .. (t == 'preproc_elif' and 'elif' or 'if') .. ' ' .. c, { kind = 'if', cond = c }
  end
  -- the chain of branches this one ends: the #if it belongs to, its #elifs before it
  local chain, b = {}, branch
  while b and PREPROC[b:type()] do
    table.insert(chain, 1, b)
    local parent = b:parent()
    if parent and PREPROC[parent:type()] and parent:field('alternative')[1] == b then b = parent else break end
  end
  local function on(test)
    if not defines then return nil end
    if test.kind == 'ifdef' then return defines[test.name] ~= nil end
    if test.kind == 'ifndef' then return defines[test.name] == nil end
    return holds(test.cond, defines)
  end
  local text
  local earlier_off = true
  local active
  for k, br in ipairs(chain) do
    local is_last = k == #chain
    if br:type() == 'preproc_else' then
      text = '#else (' .. (head(chain[1])) .. ')'
      if is_last then
        if defines and earlier_off ~= nil then active = earlier_off else active = nil end
      end
    else
      local h, test = head(br)
      local v = on(test)
      if is_last then
        text = h
        if earlier_off == nil or v == nil then active = nil else active = earlier_off and v end
      else
        if v == nil or earlier_off == nil then earlier_off = nil elseif v then earlier_off = false end
      end
    end
  end
  return { text = cut_text(text, 120), active = active }
end

local CACHE_VERSION = '3'   -- changed whenever what a file's piece holds changes: every cached piece read again
-- (2: 2026-11-19, text cut at a character; pieces cached before could hold half a →. 3: include guards no condition)
-- request: { root, files = { rel… }, limits = { nodes, edges }, cache = dir? }. Returns the map's graph shape plus spans (each
-- unit's first and last line, for "what a commit touched"), notes and counts.
function M.syntax_graph(request)
  local R = require('desk.review')
  local unit_types = vim.tbl_extend('force', {}, R.unit_types, MORE_UNITS)
  local root = type(request.root) == 'string' and request.root or ''
  local limits = type(request.limits) == 'table' and request.limits or {}
  local max_nodes, max_edges = tonumber(limits.nodes) or 50000, tonumber(limits.edges) or 200000
  local units, calls, spans = {}, {}, vim.empty_dict()
  -- Handoffs (C and C++): pushes and pops by the object they act on, functions passed by name, function pointers set.
  local ops, passed, pointers = {}, {}, {}
  local stats = { files = 0, parsed = 0, cached = 0, functions = 0, types = 0, calls = 0, edges = 0, ambiguous = 0, outside = 0 }
  local no_parser, parsers, complete, why = {}, {}, true, nil
  local function has_parser(lang)
    if parsers[lang] == nil then parsers[lang] = vim.treesitter.language.add(lang) == true end
    return parsers[lang]
  end
  -- the compile flags of each file, from compile_commands.json (the checkout's or its build/'s): which #if branch is on
  local commands
  local function defines_for(rel)
    if commands == nil then
      commands = false
      for _, at in ipairs({ root .. '/compile_commands.json', root .. '/build/compile_commands.json' }) do
        local text = read_file(at)
        local ok, list = pcall(vim.json.decode, text or '')
        if ok and type(list) == 'table' then
          commands = {}
          for _, e in ipairs(list) do
            if type(e) == 'table' and type(e.file) == 'string' then
              local file = e.file:sub(1, 1) == '/' and e.file or ((e.directory or root) .. '/' .. e.file)
              local args = type(e.arguments) == 'table' and e.arguments or vim.split(tostring(e.command or ''), '%s+', { trimempty = true })
              commands[vim.fs.normalize(file)] = M.defines_of(args)
            end
          end
          break
        end
      end
    end
    return commands and commands[vim.fs.normalize(root .. '/' .. rel)] or nil
  end
  local cache_dir = type(request.cache) == 'string' and request.cache ~= '' and request.cache or nil
  if cache_dir and vim.fn.isdirectory(cache_dir) == 0 then pcall(vim.fn.mkdir, cache_dir, 'p', tonumber('700', 8)) end
  if cache_dir and vim.fn.isdirectory(cache_dir) == 0 then cache_dir = nil end
  local used = {}
  -- a cached file's units and the rest appended, its indexes made the build's
  local function absorb(piece)
    local base = #units
    for _, u in ipairs(piece.units or {}) do
      u.owner = u.owner and (u.owner + base) or nil
      units[#units + 1] = u
      stats[u.kind == 'type' and 'types' or 'functions'] = stats[u.kind == 'type' and 'types' or 'functions'] + 1
    end
    for id, span in pairs(piece.spans or {}) do spans[id] = span end
    for _, c in ipairs(piece.calls or {}) do c.from = c.from + base; calls[#calls + 1] = c; stats.calls = stats.calls + 1 end
    for _, o in ipairs(piece.ops or {}) do o.owner = o.owner + base; ops[#ops + 1] = o end
    for _, o in ipairs(piece.passed or {}) do o.owner = o.owner + base; passed[#passed + 1] = o end
    for field, list in pairs(piece.pointers or {}) do
      pointers[field] = pointers[field] or {}
      vim.list_extend(pointers[field], list)
    end
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
    -- A file read before, unchanged (its text, language and compile flags): its units, calls and handoffs from the
    -- cache, and only the matching of names across files done again (Codex's #43: a rebuild in proportion to the edit,
    -- with a clean rebuild's answer; a new overload elsewhere still makes this file's call ambiguous).
    local key = cache_dir and vim.fn.sha256(table.concat({ CACHE_VERSION, rel, lang, vim.inspect(defines_for(rel) or {}), src }, '\0'))
    if key then
      used[key] = true
      local hit = cache_dir and read_file(cache_dir .. '/' .. key .. '.json')
      local okj, piece = pcall(vim.json.decode, hit or '', { luanil = { object = true, array = true } })
      if okj and type(piece) == 'table' and piece.rel == rel and #units + #(piece.units or {}) <= max_nodes then
        absorb(piece)
        stats.parsed, stats.cached = stats.parsed + 1, stats.cached + 1
        return
      end
    end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok or not parser then return end
    local parsed, trees = pcall(parser.parse, parser)
    if not parsed or not trees or not trees[1] then return end
    stats.parsed = stats.parsed + 1
    local base_units, base_calls, base_ops, base_passed = #units, #calls, #ops, #passed
    local outer_pointers, was_complete = pointers, complete
    local pointers = {}
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
          if (FAMILY[lang] or lang) == 'c' then
            local fine, cond = pcall(M.preproc_cond, node, src, defines_for(rel))
            if fine and cond then units[#units].cond = cond end
          end
          if kind == 'function' and (FAMILY[lang] or lang) == 'c' then
            local fine, sig = pcall(M.signature, node, src)
            if fine and sig then
              units[#units].sig = sig
              units[#units].param_index = {}
              for i, prm in ipairs(sig.params) do if prm.name ~= '' then units[#units].param_index[prm.name] = i end end
            end
          end
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
        if short then
          local fine, args, more = pcall(call_args, node, src)
          calls[#calls + 1] = { from = owner, full = full, short = short, line = node:start() + 1, args = fine and args or nil,
            args_more = fine and more > 0 and more or nil }
          stats.calls = stats.calls + 1
          if (FAMILY[lang] or lang) == 'c' and fine then M.note_handoff(ops, passed, owner, full, short, args, node:start() + 1) end
        end
      end
      -- What a function reads and writes of what it is passed: `tick.px`, `ring->head = …`, `core->cfg.fee_rate` (one
      -- use, its whole path). Taken where the path starts (the parameter's own name), its role from where it ends.
      if t == 'field_expression' and owner and units[owner].param_index then
        local base = node:field('argument')[1]
        local name = base and one_line(text_of(base, src)):gsub('^[%*&%(]+', ''):gsub('%)+$', '')
        local at = name and units[owner].param_index[name]
        if at then
          local path, top = {}, node
          while top do
            local field = top:field('field')[1]
            if field then path[#path + 1] = one_line(text_of(field, src)) end
            local up = top:parent()
            if up and up:type() == 'field_expression' and up:field('argument')[1] and up:field('argument')[1]:id() == top:id() then top = up else break end
          end
          local up = top:parent()
          -- A method called (q.push(1)) is no field used.
          local called = up and up:type() == 'call_expression' and up:field('function')[1] and up:field('function')[1]:id() == top:id()
          if called then table.remove(path) end
          local wrote = up and ((up:type() == 'assignment_expression' and up:field('left')[1] and up:field('left')[1]:id() == top:id())
            or up:type() == 'update_expression')
          if #path > 0 then M.note_use(units[owner].sig.params[at], table.concat(path, '.'), wrote) end
        end
      end
      if (FAMILY[lang] or lang) == 'c' and owner then
        -- A function pointer set: `x.submit = &f;`, `.submit = f` in an initializer; and `std::thread t(f, …)`.
        if t == 'assignment_expression' then
          local left, right = node:field('left')[1], node:field('right')[1]
          local field = left and left:type() == 'field_expression' and left:field('field')[1]
          if field and right then M.note_pointer(pointers, one_line(text_of(field, src)), one_line(text_of(right, src)), node:start() + 1) end
        elseif t == 'initializer_pair' then
          local designator, value = node:field('designator')[1], node:field('value')[1]
          if designator and value then
            M.note_pointer(pointers, (one_line(text_of(designator, src)):gsub('^%.', '')), one_line(text_of(value, src)), node:start() + 1)
          end
        elseif t == 'init_declarator' then
          -- `std::thread t(f, …)` and `std::jthread j{f}`: an object made with a function passed to it.
          local value = node:field('value')[1]
          if value and (value:type() == 'argument_list' or value:type() == 'initializer_list') then
            local fine, args = pcall(list_texts, value, src)
            local ty = node:parent() and node:parent():field('type')[1]
            local made = ty and last_name(one_line(text_of(ty, src))) or 'its constructor'
            if fine then M.note_handoff(ops, passed, owner, made, made, args, node:start() + 1) end
          end
        elseif t == 'declaration' and units[owner].kind == 'function' then
          -- Inside a function, `std::thread hot(HotThreadBody, core);` reads as a function declared (C++'s most vexing
          -- parse): its "parameters" are the arguments it is made with.
          local declarator, ty = node:field('declarator')[1], node:field('type')[1]
          local list = declarator and declarator:type() == 'function_declarator' and declarator:field('parameters')[1]
          if list then
            local fine, args = pcall(list_texts, list, src)
            local made = ty and last_name(one_line(text_of(ty, src))) or 'its constructor'
            if fine then M.note_handoff(ops, passed, owner, made, made, args, node:start() + 1) end
          end
        end
      end
      local children = {}
      for child in node:iter_children() do if child:named() then children[#children + 1] = child end end
      for i = #children, 1, -1 do stack[#stack + 1] = { children[i], owner, scope } end
    end
    -- this file's pointers join the others; the file kept in the cache, its indexes its own (from 1)
    for field, list in pairs(pointers) do
      outer_pointers[field] = outer_pointers[field] or {}
      vim.list_extend(outer_pointers[field], list)
    end
    if key and complete and was_complete then
      local piece = { rel = rel, units = {}, calls = {}, ops = {}, passed = {}, pointers = pointers, spans = {} }
      local function here(i) return i and (i - base_units) or nil end
      for i = base_units + 1, #units do
        local u = vim.deepcopy(units[i])
        u.owner = here(u.owner)
        for _, prm in ipairs(u.sig and u.sig.params or {}) do prm.seen_more = nil end
        piece.units[#piece.units + 1] = u
        piece.spans[u.id] = spans[u.id]
      end
      for i = base_calls + 1, #calls do local c = vim.deepcopy(calls[i]); c.from = here(c.from); piece.calls[#piece.calls + 1] = c end
      for i = base_ops + 1, #ops do local o = vim.deepcopy(ops[i]); o.owner = here(o.owner); piece.ops[#piece.ops + 1] = o end
      for i = base_passed + 1, #passed do local o = vim.deepcopy(passed[i]); o.owner = here(o.owner); piece.passed[#piece.passed + 1] = o end
      pcall(vim.fn.writefile, { vim.json.encode(piece) }, cache_dir .. '/' .. key .. '.json')
    end
  end
  for _, rel in ipairs(type(request.files) == 'table' and request.files or {}) do read_one(rel) end
  -- cached files no build asked for again go
  if cache_dir then
    for name in vim.fs.dir(cache_dir) do
      local k = name:match('^(%x+)%.json$')
      if k and not used[k] then os.remove(cache_dir .. '/' .. name) end
    end
  end

  -- Calls to edges, by name, within the caller's language: a qualified call (M.beta, Queue::push) prefers the
  -- function of that name; self.x and this->x the caller's own class; then the caller's file, then its folder (a
  -- checkout of many programs has many a trim); what is still ambiguous is left out and counted.
  local by_short, nodes, edges, seen, edge_at = {}, {}, {}, {}, {}
  for i, u in ipairs(units) do
    by_short[u.short] = by_short[u.short] or {}
    table.insert(by_short[u.short], i)
    nodes[i] = { id = u.id, label = u.label, file = u.file, line = u.line, kind = u.kind, cond = u.cond }
    if u.sig then
      nodes[i].params, nodes[i].returns, nodes[i].params_more = u.sig.params, u.sig.returns, u.sig.params_more
      for _, prm in ipairs(u.sig.params or {}) do prm.seen_more = nil end
    end
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
      if #pick > 1 then
        -- said beside the function that makes the call (Codex's #4): "send: 2 match", each name once, at most 8
        local n = nodes[c.from]
        n.ambiguous = n.ambiguous or {}
        local known = false
        for _, a in ipairs(n.ambiguous) do if a.name == c.short then known = true end end
        if not known and #n.ambiguous < 8 then n.ambiguous[#n.ambiguous + 1] = { name = c.short, count = #pick, line = c.line } end
      end
      if #pick ~= 1 or elsewhere then stats.ambiguous = stats.ambiguous + 1
      else
        local key = from.id .. '\0' .. units[pick[1]].id
        if seen[key] then
          -- Another call between the same two: kept as one of its sites (the trace offers each), at most 8.
          local e = edges[edge_at[key]]
          if e and #e.sites < 8 then e.sites[#e.sites + 1] = { line = c.line, args = c.args, args_more = c.args_more }
          elseif e then e.sites_more = (e.sites_more or 0) + 1 end
        else
          if #edges >= max_edges then
            if complete then complete, why = false, 'stopped at ' .. max_edges .. ' calls' end
          else
            seen[key] = true
            -- The first call between the two: its line and arguments, what the trace shows flowing in; every site of it.
            edges[#edges + 1] = { from = from.id, to = units[pick[1]].id, kind = 'call-by-name', line = c.line, args = c.args,
              args_more = c.args_more, sites = { { line = c.line, args = c.args, args_more = c.args_more } } }
            edge_at[key] = #edges
            stats.edges = stats.edges + 1
          end
        end
      end
    end
  end
  local handoffs = M.handoff_edges(units, by_short, ops, passed, pointers, calls, seen, math.max(0, max_edges - #edges))
  for _, e in ipairs(handoffs) do edges[#edges + 1] = e end
  stats.handoffs = #handoffs
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
  local ok, job = pcall(vim.system, argv, { text = true, timeout = timeout or 20000 }, vim.schedule_wrap(function(out)
    local parsed, value = pcall(vim.json.decode, out.stdout or '', { luanil = { object = true, array = true } })
    done(parsed and type(value) == 'table' and value or nil, out)
  end))
  if not ok then vim.schedule(function() done(nil, { code = -1, stdout = '', stderr = M.REQUIRES, missing = true }) end)
  else return job end
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

-- A key of this view as typed ("Enter", "BS", "r"), read from its row: the words that name a key follow the row.
local function typed(id)
  local key = actions.key(id:find('%.') and id or ('map.' .. id))
  return key == '<CR>' and 'Enter' or key == '<BS>' and 'BS' or key or '?'
end
-- The theme's voice leaves the key itself as typed.
local function with_key(G, before, id, after) return G.said(before) .. typed(id) .. G.said(after) end

-- page: { header = { { text, group } }, sections = { … }, notes = { text } }. A section is { head = text } (a centred
-- heading), { boxes = { item }, frame = 'single'|'double', more = n, none = text }, { arrow = true },
-- { parts = { { text, item? } }, group } (one line whose named parts are hits) or { blank = true }.
-- item: { name, detail, target }. Returns the lines, the hits per line (byte columns, for Enter), the highlights and
-- the items in reading order, each drawn once: { item, spans = { { line, from, to } }, line (its name's), name_col,
-- x and w (screen columns), centre (in a double box) }, the pop-out's boxes.
function M.layout(page, width, retro)
  width = math.max(20, width or 80)
  local G = M.glyphs(retro)
  local lines, hits, marks, placed, bands = {}, {}, {}, {}, {}
  local parts_text, put_parts
  local graph = require('desk.callgraph')
  local gauge = width >= 28 and (page.zoom or page.layered)
  if gauge then width = width - graph.GAUGE_WIDTH end
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
    -- names fitted where they still differ (the call graph's fitter: qualifiers first, then parameters' const and &)
    local names = graph.fit_names(vim.tbl_map(function(it) return tostring(it.name or '') end, items), width - 4, G.ellipsis)
    for k, item in ipairs(items) do
      local name, detail = names[k], fit(item.detail or '', width - 4, G.ellipsis)
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
        -- a box may ask for its own frame (the whole trace draws its lane double); the centre is then the one it names
        local own = b.item.frame == 'double'
        local f, edge, name_hl = own and G.double or frame, own and 'DeskMapFocus' or border, own and 'DeskMapFocus' or name_group
        local parts = {
          f.tl .. string.rep(f.h, b.inner + 2) .. f.tr,
          f.v .. ' ' .. pad(b.name, b.inner) .. ' ' .. f.v,
          f.v .. ' ' .. pad(b.detail, b.inner) .. ' ' .. f.v,
          f.bl .. string.rep(f.h, b.inner + 2) .. f.br,
        }
        local box = { item = b.item, spans = {}, line = first + 1, w = b.w, centre = (not own and frame == G.double) or b.item.focus == true }
        for k = 1, 4 do
          if i > 1 then texts[k] = texts[k] .. ' ' end
          if k == 1 then box.x = width_of(texts[1]) end
          local s = #texts[k]
          texts[k] = texts[k] .. parts[k]
          local lnum = first + k - 1
          hits[lnum] = hits[lnum] or {}
          table.insert(hits[lnum], { s = s, e = #texts[k], item = b.item })
          box.spans[k] = { lnum, s, #texts[k] }
          marks[#marks + 1] = { lnum, s, #texts[k], edge }
          if k == 2 then
            box.name_col = s + #f.v + 1
            marks[#marks + 1] = { lnum, box.name_col, box.name_col + #b.name, name_hl, 1 }
          end
          if k == 3 then marks[#marks + 1] = { lnum, s + #f.v + 1, s + #f.v + 1 + #b.detail, b.item.warn and 'DeskMapStale' or 'DeskMapDim', 1 } end
        end
        placed[#placed + 1] = box
      end
      for k = 1, 4 do lines[#lines + 1] = texts[k] end
    end
  end
  -- A line of parts: { text, item?, said? }; an item makes its text a hit (Enter goes there), said puts words in the
  -- theme's voice (capitals in retro; code stays as typed).
  function parts_text(parts)
    local t = ''
    for _, part in ipairs(parts) do t = t .. (part[3] and G.said(tostring(part[1] or '')) or tostring(part[1] or '')) end
    return t
  end
  function put_parts(parts, lead, group)
    local text, lnum = lead or '', #lines + 1
    for _, part in ipairs(parts) do
      local piece = part[3] and G.said(tostring(part[1] or '')) or tostring(part[1] or '')
      if part[2] then
        hits[lnum] = hits[lnum] or {}
        table.insert(hits[lnum], { s = #text, e = #text + #piece, item = part[2] })
        marks[#marks + 1] = { lnum, #text, #text + #piece, 'DeskMapName', 1 }
        placed[#placed + 1] = { item = part[2], spans = { { lnum, #text, #text + #piece } }, line = lnum, name_col = #text,
                                x = width_of(text), w = width_of(piece) }
      end
      text = text .. piece
    end
    add(text, group)
  end
  for _, h in ipairs(page.header or {}) do add(fit(h[1], width, G.ellipsis), h[2]) end
  -- The zoom on a row of its own under the header, the current one lit (2026-11-19: on the rail its labels sat on the
  -- header's lines, "ALL PROJECT MAP").
  if gauge and page.zoom then
    local row, lit = G.said('zoom'), nil
    for i, label in ipairs({ 'all', 'dir', 'src', 'cls' }) do
      local active, name = i == page.zoom, G.said(label)
      local mark = retro and (active and '█ ' or '░ ') or (active and '‹' or ' ')
      row = row .. '  ' .. mark
      if active then lit = { #row - (retro and #mark or 0), #row + #name } end
      row = row .. name .. ((not retro and active) and '›' or '')
    end
    add(row, 'DeskMapDim')
    marks[#marks + 1] = { #lines, lit[1], lit[2] + (retro and 0 or #'›'), 'DeskMapFocus', 1 }
    add('')
  end
  -- headings and the boxes under them, for "where am I" once one has scrolled away (Codex's E8): a section's heading
  -- (its count dropped: the location says it) up to the next arrow or heading, each trace step, and the page's title
  -- around them all, counting the page's layers of boxes
  local heads, open_head, steps_total, step_n, layer_first, layer_last = {}, nil, 0, 0, nil, nil
  local links = {}
  for _, s in ipairs(page.sections or {}) do if s.card and s.card.column then steps_total = steps_total + 1 end end
  local function close_head()
    if open_head then open_head.last, open_head.last_line = #placed, #lines; heads[#heads + 1] = open_head end
    open_head = nil
  end
  for _, s in ipairs(page.sections or {}) do
    local first = #lines + 1
    if s.head then
      centred(G.said(s.head), 'DeskMapHead')
      close_head()
      open_head = { line = #lines, text = G.said((tostring(s.head):gsub(' · %d+$', ''))), of = G.said(' of '), first = #placed + 1 }
    elseif s.boxes then
      if #s.boxes == 0 and s.none then centred(G.said(s.none), 'DeskMapDim') end
      local double = s.frame == 'double'
      boxes(s.boxes, double and G.double or G.single, double and 'DeskMapFocus' or 'DeskMapBox', double and 'DeskMapFocus' or 'DeskMapName')
    elseif s.arrow then centred(G.down, 'DeskMapBox'); close_head()
    elseif s.links then vim.list_extend(links, s.links)
    elseif s.parts then
      put_parts(s.parts, '', s.group)
    elseif s.card and s.card.column then
      -- A trace step in one column you read straight down (Codex's #3): a bar (double on the function asked about), the
      -- name on one left edge and its place on the right; what it does indented under it; a part marked `right` set at
      -- the right edge (a call's line).
      local c = s.card
      local bar = c.frame == 'double' and G.double.v or G.single.v
      local left, right_edge = ' ', width - 1
      local head_line = #lines + 1
      local title = fit(c.title or '', math.max(8, width - 6 - width_of(c.right or '')), G.ellipsis)
      local text = left .. bar .. ' '
      local title_col = #text
      text = text .. title
      local place = c.right or ''
      if place ~= '' then text = text .. string.rep(' ', math.max(2, right_edge - width_of(text) - width_of(place))) .. place end
      add(text)
      marks[#marks + 1] = { head_line, #left, #left + #bar, c.frame == 'double' and 'DeskMapFocus' or 'DeskMapBox' }
      marks[#marks + 1] = { head_line, title_col, title_col + #title, c.frame == 'double' and 'DeskMapFocus' or 'DeskMapName', 1 }
      if place ~= '' then marks[#marks + 1] = { head_line, #text - #place, #text, 'DeskMapDim' } end
      hits[head_line] = hits[head_line] or {}
      table.insert(hits[head_line], { s = title_col, e = title_col + #title, item = c.item })
      placed[#placed + 1] = { item = c.item, spans = { { head_line, title_col, title_col + #title } }, line = head_line, name_col = title_col,
                              x = width_of(left) + 2, w = width_of(title), centre = c.frame == 'double' }
      local indent = left .. bar .. '     '
      for _, l in ipairs(c.body or {}) do
        local parts, at_right = {}, nil
        for _, part in ipairs(l.parts or l) do if part.right then at_right = part else parts[#parts + 1] = part end end
        -- wrap between the parts of a list (its first marked `hang`), going on under the list's start
        local room = right_edge - width_of(indent) - (at_right and (width_of(parts_text({ at_right })) + 2) or 0)
        local rows_, cur, w, hang = {}, {}, 0, nil
        for _, part in ipairs(parts) do
          if part.hang and not hang then hang = w end
          local pw = width_of(parts_text({ part }))
          if hang and #cur > 0 and w + pw > room and w > hang then rows_[#rows_ + 1] = cur; cur, w = { { string.rep(' ', hang) } }, hang end
          cur[#cur + 1] = part
          w = w + pw
        end
        rows_[#rows_ + 1] = cur
        for r, row_ in ipairs(rows_) do
          local lnum, line_text = #lines + 1, indent
          add('')
          marks[#marks + 1] = { lnum, #left, #left + #bar, c.frame == 'double' and 'DeskMapFocus' or 'DeskMapBox' }
          for _, part in ipairs(row_) do
            local piece = part[3] and G.said(tostring(part[1] or '')) or tostring(part[1] or '')
            local space = room - width_of(line_text) + width_of(indent)
            if width_of(piece) > space then piece = fit(piece, math.max(1, space), G.ellipsis) end
            if part[2] then
              hits[lnum] = hits[lnum] or {}
              table.insert(hits[lnum], { s = #line_text, e = #line_text + #piece, item = part[2] })
              placed[#placed + 1] = { item = part[2], spans = { { lnum, #line_text, #line_text + #piece } }, line = lnum, name_col = #line_text,
                                      x = width_of(line_text), w = width_of(piece) }
            end
            if part[4] or part[2] then marks[#marks + 1] = { lnum, #line_text, #line_text + #piece, part[4] or 'DeskMapName', 1 } end
            line_text = line_text .. piece
          end
          if at_right and r == 1 then
            local piece = at_right[3] and G.said(tostring(at_right[1] or '')) or tostring(at_right[1] or '')
            line_text = line_text .. string.rep(' ', math.max(2, right_edge - width_of(line_text) - width_of(piece)))
            if at_right[2] then
              hits[lnum] = hits[lnum] or {}
              table.insert(hits[lnum], { s = #line_text, e = #line_text + #piece, item = at_right[2] })
              placed[#placed + 1] = { item = at_right[2], spans = { { lnum, #line_text, #line_text + #piece } }, line = lnum, name_col = #line_text,
                                      x = width_of(line_text), w = width_of(piece) }
            end
            marks[#marks + 1] = { lnum, #line_text, #line_text + #piece, at_right[4] or 'DeskMapDim', 1 }
            line_text = line_text .. piece
          end
          lines[lnum] = line_text
        end
      end
    elseif s.rule then
      -- A full-width break between two steps (a queue or thread handoff): what it is, trusted or not, where the reader
      -- decides; its label a hit.
      local r = s.rule
      local lead = ' ' .. G.double.h .. G.double.h .. ' ' .. G.said(r.said or '') .. ' ' .. G.double.h .. G.double.h .. ' '
      local label = tostring(r.label or '')
      local lnum = #lines + 1
      local text = lead .. label .. ' '
      text = text .. string.rep(G.double.h, math.max(2, width - 1 - width_of(text)))
      add(text, 'DeskMapFocus')
      if r.item then
        hits[lnum] = hits[lnum] or {}
        table.insert(hits[lnum], { s = #lead, e = #lead + #label, item = r.item })
        placed[#placed + 1] = { item = r.item, spans = { { lnum, #lead, #lead + #label } }, line = lnum, name_col = #lead, x = width_of(lead), w = width_of(label) }
        marks[#marks + 1] = { lnum, #lead, #lead + #label, 'DeskMapName', 1 }
      end
    elseif s.card then
      -- A box with lines inside (a trace step): its name and where it is in the top border, the name a hit with where
      -- Enter goes; each line inside a line of parts (folds, parameters, names), cut to the page.
      local c = s.card
      local frame = c.frame == 'double' and G.double or G.single
      local title, right = fit(c.title or '', width - 12, G.ellipsis), c.right or ''
      -- The top line needs the title and the place with `─ ` before, ` ` between, ` ─` after (7), or the title alone (3).
      local inner = width_of(title) + width_of(right) + 7
      for _, l in ipairs(c.body or {}) do inner = math.max(inner, width_of(parts_text(l.parts or l)) + 2) end
      inner = math.min(inner, width - 2)
      if width_of(title) + width_of(right) + 7 > inner then right = '' end
      local left = string.rep(' ', math.max(0, math.floor((width - inner - 2) / 2)))
      local top_line = #lines + 1
      local top = left .. frame.tl .. frame.h .. ' '
      local title_col = #top
      local tail = right ~= '' and (' ' .. right .. ' ' .. frame.h .. frame.tr) or frame.tr
      -- The gap fills the top line to the bottom line's width (left, the corners and `inner` between them).
      local gap = width_of(left) + inner + 2 - width_of(top .. title .. ' ' .. tail)
      top = top .. title .. ' ' .. string.rep(frame.h, math.max(1, gap)) .. tail
      add(top, 'DeskMapBox')
      marks[#marks + 1] = { top_line, title_col, title_col + #title, c.frame == 'double' and 'DeskMapFocus' or 'DeskMapName', 1 }
      hits[top_line] = hits[top_line] or {}
      table.insert(hits[top_line], { s = title_col, e = title_col + #title, item = c.item })
      placed[#placed + 1] = { item = c.item, spans = { { top_line, title_col, title_col + #title } }, line = top_line, name_col = title_col,
                              x = width_of(left) + 3, w = width_of(title), centre = c.frame == 'double' }
      -- A line holding a list (its first item marked `hang`) wraps between the items, going on under the list's start;
      -- any other line is cut to the box.
      local body = {}
      for _, l in ipairs(c.body or {}) do
        local parts, room = l.parts or l, inner - 1
        local cur, w, hang = {}, 0, nil
        for _, part in ipairs(parts) do
          if part.hang and not hang then hang = w end
          local pw = width_of(parts_text({ part }))
          if hang and #cur > 0 and w + pw > room and w > hang then
            body[#body + 1] = cur
            cur, w = { { string.rep(' ', hang) } }, hang
          end
          cur[#cur + 1] = part
          w = w + pw
        end
        body[#body + 1] = cur
      end
      for _, l in ipairs(body) do
        local lnum, text = #lines + 1, left .. frame.v .. ' '
        add('')
        for _, part in ipairs(l.parts or l) do
          local piece = part[3] and G.said(tostring(part[1] or '')) or tostring(part[1] or '')
          local room = inner - 1 - width_of(text) + width_of(left) + width_of(frame.v)
          if width_of(piece) > room then piece = fit(piece, math.max(1, room), G.ellipsis) end
          if part[2] then
            hits[lnum] = hits[lnum] or {}
            table.insert(hits[lnum], { s = #text, e = #text + #piece, item = part[2] })
            placed[#placed + 1] = { item = part[2], spans = { { lnum, #text, #text + #piece } }, line = lnum, name_col = #text,
                                    x = width_of(text), w = width_of(piece) }
          end
          if part[4] or part[2] then marks[#marks + 1] = { lnum, #text, #text + #piece, part[4] or 'DeskMapName', 1 } end
          text = text .. piece
        end
        lines[lnum] = text .. string.rep(' ', math.max(0, width_of(left) + inner + 1 - width_of(text))) .. frame.v
        marks[#marks + 1] = { lnum, 0, #lines[lnum], 'DeskMapBox' }
      end
      add(left .. frame.bl .. string.rep(frame.h, inner) .. frame.br, 'DeskMapBox')
    elseif s.block then
      -- Lines left-aligned among themselves, the block centred (a trace step's parameters under its box). A line wider
      -- than the page wraps between its parts, going on indented (a busy function's other callees).
      local rows = {}
      for _, line in ipairs(s.block) do
        local cur, w = {}, 0
        for _, part in ipairs(line.parts or line) do
          local pw = width_of(parts_text({ part }))
          if w + pw > width - 1 and #cur > 0 then
            rows[#rows + 1] = { parts = cur, group = line.group }
            cur, w = { { '    ' } }, 4
          end
          cur[#cur + 1] = part
          w = w + pw
        end
        if #cur > 0 then rows[#rows + 1] = { parts = cur, group = line.group } end
      end
      local wide = 0
      for _, row_ in ipairs(rows) do wide = math.max(wide, width_of(parts_text(row_.parts))) end
      local left = string.rep(' ', math.max(0, math.floor((width - wide) / 2)))
      for _, row_ in ipairs(rows) do put_parts(row_.parts, left, row_.group or s.group) end
    elseif s.blank then add('') end
    if s.level and #lines >= first then bands[#bands + 1] = { first = first, last = #lines, level = s.level } end
    if s.level and s.boxes and #s.boxes > 0 and not open_head then
      layer_first, layer_last = layer_first or (#placed - #s.boxes + 1), #placed
    end
    if s.card and s.card.column then
      step_n = step_n + 1
      heads[#heads + 1] = { line = first, last_line = #lines, count = false,
        text = G.said('step ') .. step_n .. G.said(' of ') .. steps_total .. ' · ' .. tostring(s.card.title or '') }
    end
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
  close_head()
  if page.header and page.header[1] and #lines > 1 then
    table.insert(heads, 1, { line = 1, text = tostring(page.header[1][1]), of = G.said(' of '), first = layer_first, last = layer_last,
      count = layer_first ~= nil, last_line = #lines })
  end
  M.connect_boxes(placed, links)
  local drawn = { lines = lines, hits = hits, marks = marks, items = placed, boxes = placed, heads = heads }
  if gauge then
    graph.gauge(drawn, bands, retro, 'DeskMapDim', 'DeskMapFocus')
    drawn.gauge_range = graph.gauge_range(placed)
  end
  return drawn
end

function M.item_at(drawn, lnum, col)
  for _, hit in ipairs((drawn and drawn.hits or {})[lnum] or {}) do
    if col >= hit.s and col < hit.e then return hit.item end
  end
end

-- ─── levels (pure): desk-work's answers as pages ───────────────────────────────────────────────────────────────
local function count(n, one, many) return n .. ' ' .. (n == 1 and one or many) end
local function short(sha) return type(sha) == 'string' and sha:sub(1, 7) or '' end
-- Code in words that the theme's voice says (a hash, a function's name): between backticks, so retro shouts the words
-- around it and leaves the code as it is (actions.voice).
local function code(s) return '`' .. (tostring(s or '?'):gsub('`', "'")) .. '`' end
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

--- pure: two routes (lists of ids) lined up by the longest run of steps they share, in order (Codex's E6, 2026-11-19):
--- { { same = ids } | { a = ids, b = ids } }, the parts they share and between them each one's own (one side may be
--- empty: that route goes straight on).
function M.compare_routes(a, b)
  local n, m = #a, #b
  local L = {}
  for i = n + 1, 1, -1 do
    L[i] = {}
    for j = m + 1, 1, -1 do
      if i > n or j > m then L[i][j] = 0
      elseif a[i] == b[j] then L[i][j] = L[i + 1][j + 1] + 1
      else L[i][j] = math.max(L[i + 1][j], L[i][j + 1]) end
    end
  end
  local out, i, j = {}, 1, 1
  local function same(id)
    local last = out[#out]
    if last and last.same then last.same[#last.same + 1] = id else out[#out + 1] = { same = { id } } end
  end
  local function own(side, id)
    local last = out[#out]
    if not last or last.same then last = { a = {}, b = {} }; out[#out + 1] = last end
    table.insert(last[side], id)
  end
  while i <= n or j <= m do
    if i <= n and j <= m and a[i] == b[j] then same(a[i]); i, j = i + 1, j + 1
    elseif j > m or (i <= n and L[i + 1][j] >= L[i][j + 1]) then own('a', a[i]); i = i + 1
    else own('b', b[j]); j = j + 1 end
  end
  return out
end

--- Two traces as one page (E6): "same through …", then each route's own part ("from <its start>: …"), "both reach
--- …". Every name opens its code; a route's "from …" opens that trace. answer: { q = 'routes', a, b, a_args, b_args }.
function M.routes_page(answer)
  local by = {}
  local function ids(r)
    local out = {}
    for _, st in ipairs(type(r) == 'table' and r.steps or {}) do
      if type(st) == 'table' and st.id then by[st.id] = by[st.id] or st; out[#out + 1] = st.id end
    end
    return out
  end
  local ia, ib = ids(answer.a), ids(answer.b)
  local function start_of(list) local st = by[list[1] or '']; return st and tostring(st.label) or '?' end
  local an, bn = start_of(ia), start_of(ib)
  if an == bn then an, bn = an .. ' (1)', bn .. ' (2)' end
  local focus = by[(answer.a or {}).focus or ''] or by[(answer.b or {}).focus or '']
  local sections = { { head = 'two routes to ' .. (focus and tostring(focus.label) or tostring((answer.a or {}).focus)) } }
  local function row(list, lead, lead_item)
    local parts = { lead_item and { lead, lead_item } or { lead, nil, nil, 'DeskMapDim' } }
    if #list == 0 then parts[#parts + 1] = { '(goes straight on)', nil, true, 'DeskMapDim' } end
    for k, id in ipairs(list) do
      local st = by[id]
      parts[#parts + 1] = { tostring(st.label), { name = tostring(st.label), key = 'routes:' .. lead .. id, target = { kind = 'node', node = st } } }
      if k < #list then parts[#parts + 1] = { ' → ', nil, nil, 'DeskMapDim' } end
    end
    return parts
  end
  local segs = M.compare_routes(ia, ib)
  for k, seg in ipairs(segs) do
    if seg.same then
      sections[#sections + 1] = { block = { row(seg.same, (k == #segs and k > 1) and 'both reach ' or 'same through ') } }
    else
      -- the first part is where each starts: its start is its name already
      local la, lb = seg.a, seg.b
      if k == 1 then la, lb = vim.list_slice(la, 2), vim.list_slice(lb, 2) end
      local function lane(which, name) return { name = 'from ' .. name, key = 'routes:lane:' .. which .. ':' .. k, target = { kind = 'route', which = which } } end
      sections[#sections + 1] = { block = { row(la, 'from ' .. an .. ': ', lane('a', an)), row(lb, 'from ' .. bn .. ': ', lane('b', bn)) } }
    end
  end
  return { crumbs = { 'two routes' }, sections = sections }
end

--- A test run's coverage on a page (Codex's E5, 2026-11-19): each function box from a file the run covered says
--- whether the run ran it, from its recorded functions (FN/FNDA: by its line, else by its name), "ran 3×" or "not run"
--- (warn, and unrun for ]u); a file the run did not cover, nothing. Calls keep their style: lcov says which lines ran,
--- never which caller brought it there. files: the run's coverage, { [rel] = { functions = { { name, line, count } } } }.
function M.with_coverage(page, files)
  for _, sec in ipairs(page.sections or {}) do
    for _, item in ipairs(sec.boxes or {}) do
      local node = item.target and item.target.node
      local cov = node and node.file and files and files[node.file]
      if cov then
        local found
        for _, f in ipairs(cov.functions or {}) do
          if tonumber(f.line) == tonumber(node.line) then found = f; break end
        end
        if not found then
          local tail = tostring(node.label or ''):match('([%w_~]+)$')
          for _, f in ipairs(cov.functions or {}) do
            if f.name == node.label or (tail and tostring(f.name):match('([%w_~]+)%s*%(?.-$') == tail) then found = f; break end
          end
        end
        if found then
          local count = tonumber(found.count) or 0
          item.detail = tostring(item.detail or '') .. (count > 0 and (' · ran ' .. count .. '×') or ' · not run')
          if count == 0 then item.warn, item.unrun = true, true end
        end
      end
    end
  end
  return page
end
--- pure: from box `index`, the next (dir 1) or previous (-1) box the run did not reach, wrapping (itself when it is the
--- only one); nil when none is marked.
function M.next_unrun(boxes, index, dir)
  local n = #boxes
  if n == 0 then return nil end
  index = index or 0
  for step = 1, n do
    local i = ((index - 1 + dir * step) % n) + 1
    local b = boxes[i]
    if b and b.item and b.item.unrun or (b and b.unrun) then return i end
  end
end

--- Who calls whom on a page of layers (T1, 2026-11-19: the trader's whole trace drew 93 functions and 129 calls with one
--- arrow between rows): each box its callees (down) and callers (up), with the call's line where the answer has one
--- (down_sites, up_sites, as the call graph's), and near (both), so selecting one dims the rest (the call graph's
--- painter) and gj/gk follow a call (desk.callgraph.along). A box that is in no call gets an empty near.
function M.connect_boxes(boxes, links)
  if #links == 0 then return end
  local at = {}
  for i, b in ipairs(boxes) do
    if b.item and b.item.link_key ~= nil and at[b.item.link_key] == nil then at[b.item.link_key] = i end
  end
  for _, i in pairs(at) do local b = boxes[i]; b.down, b.up, b.near, b.down_sites, b.up_sites = {}, {}, {}, {}, {} end
  local seen, sites = {}, {}
  for _, e in ipairs(links) do
    local a, b = at[e.from], at[e.to]
    local key = a and b and (a .. '>' .. b)
    if key and e.line and not sites[key] then
      local node = boxes[a].item.target and boxes[a].item.target.node
      sites[key] = ((node and node.file) and (vim.fs.basename(node.file) .. ':') or 'line ') .. e.line
    end
    if key and a ~= b and not seen[key] then
      seen[key] = true
      local A, B = boxes[a], boxes[b]
      A.down[#A.down + 1], B.up[#B.up + 1] = b, a
      if not vim.tbl_contains(A.near, b) then A.near[#A.near + 1] = b end
      if not vim.tbl_contains(B.near, a) then B.near[#B.near + 1] = a end
    end
  end
  for _, i in pairs(at) do
    local b = boxes[i]
    for k, j in ipairs(b.down) do b.down_sites[k] = sites[i .. '>' .. j] or '' end
    for k, j in ipairs(b.up) do b.up_sites[k] = sites[j .. '>' .. i] or '' end
  end
end

-- Boxes in layers, with an arrow between layers: every one, the page scrolls (2026-11-19, her "why can't it just show
-- the entire thing at once? and just be scrollable?"; 1000 boxes draw in about 30 ms).
local function layered(sections, keys, edges, item_of)
  for i, tier in ipairs(M.layers(keys, edges)) do
    if i > 1 then sections[#sections + 1] = { arrow = true } end
    sections[#sections + 1] = { boxes = vim.tbl_map(function(key) local it = item_of(key); it.link_key = key; return it end, tier), level = i - 1 }
  end
  -- the calls between them, for who calls whom on the page (T1): the layout gives each box its callers and callees
  sections[#sections + 1] = { links = edges }
end

-- Boxes of one side (who calls in from elsewhere, what is called out there): the checkout's own first (rank 0),
-- libraries and what only the binary has after; the busiest first within each.
local function side(sections, label, items)
  if #items == 0 then return end
  table.sort(items, function(a, b)
    if (a.rank or 0) ~= (b.rank or 0) then return (a.rank or 0) < (b.rank or 0) end
    local wa, wb = a.weight or 0, b.weight or 0
    if wa ~= wb then return wa > wb end
    if a.name ~= b.name then return a.name < b.name end
    return (a.target and a.target.node and a.target.node.id or '') < (b.target and b.target.node and b.target.node.id or '')
  end)
  sections[#sections + 1] = { head = label .. ' · ' .. #items }
  sections[#sections + 1] = { boxes = items }
end

-- A part's size, as its box and the part picker (M) say it.
local function part_size(m)
  return m.name == '(library)' and count(m.functions or 0, 'library function', 'library functions')
    or m.name == '(binary)' and (count(m.functions or 0, 'function', 'functions') .. ' with no source here')
    or (count(m.files or 0, 'file', 'files') .. ' · ' .. count(m.functions or 0, 'function', 'functions'))
end

-- The parts of the checkout (desk-work map query --q module).
function M.level_modules(answer)
  local keys, by = {}, {}
  for _, m in ipairs(answer.modules or {}) do keys[#keys + 1] = m.name; by[m.name] = m end
  local function item(name)
    return { name = name, detail = part_size(by[name]), target = { kind = 'module', module = name } }
  end
  local sections = {}
  if #keys == 0 then sections[1] = { parts = { { 'The map is empty: no reader found anything here.' } }, group = 'DeskMapDim' } end
  layered(sections, keys, answer.edges or {}, item)
  local edges = answer.edges or {}
  if #edges > 0 then
    sections[#sections + 1] = { blank = true }
    sections[#sections + 1] = { head = 'calls between parts' }
    for _, e in ipairs(edges) do
      -- the count a hit too: Enter shows the crossings themselves (the interface one part uses of the other)
      sections[#sections + 1] = { parts = { { '  ' }, { e.from, item(e.from) }, { ' → ' }, { e.to, item(e.to) }, { ' · ' },
        { e.count .. (e.count == 1 and ' call' or ' calls'), { name = e.from .. ' → ' .. e.to, key = 'crossings:' .. e.from .. '>' .. e.to,
          target = { kind = 'crossings', from = e.from, to = e.to } } } } }
    end
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
--- pure: what a function's calls left unresolved, said beside it: "send: 2 match" (the first; "+1" for more).
function M.ambiguity(n)
  local list = type(n.ambiguous) == 'table' and n.ambiguous or {}
  local a = list[1]
  if not (a and a.name) then return nil end
  return tostring(a.name) .. ': ' .. tostring(a.count or '?') .. ' match' .. (#list > 1 and (' +' .. (#list - 1)) or '')
end
--- pure: the #if branch a function is in, as its box says it: "#ifdef LINUX (on)", "(off)" by the compile flags.
function M.cond_said(n)
  local c = type(n.cond) == 'table' and n.cond or nil
  if not (c and c.text) then return nil end
  return c.text .. (c.active == true and ' (on)' or c.active == false and ' (off)' or '')
end
local function node_item(n, extra)
  local said = M.ambiguity(n)
  local cond = M.cond_said(n)
  local item = { name = n.label, detail = where(n) .. (cond and (' · ' .. cond) or '') .. (said and (' · ' .. said) or ''), target = { kind = 'node', node = n } }
  for k, v in pairs(extra or {}) do item[k] = v end
  return item
end

-- A part's files (desk-work map query --q module --name M): files in layers by the calls between them, the parts
-- that call into it above, the parts it calls below. A part with no files (the binary's, the libraries') shows its
-- functions instead.
function M.level_files(answer, module)
  local by, files, keys = node_index(answer), {}, {}
  for _, f in ipairs(answer.files or {}) do files[f.file] = f; keys[#keys + 1] = f.file end
  if #keys == 0 then return M.level_nodes(answer, module) end
  local between, into, out = {}, {}, {}
  for _, e in ipairs(answer.edges or {}) do
    local a, b = by[e.from], by[e.to]
    if a and b and calls(e.kind) then
      local fa, fb = a.module == module and a.file, b.module == module and b.file
      if fa and fb and fa ~= fb then
        local key = fa .. '\0' .. fb
        if not between[key] then between[key] = { from = fa, to = fb } end
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
  layered(sections, keys, edges, item)
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
  local edges, callers, callees = {}, {}, {}
  for _, e in ipairs(answer.edges or {}) do
    if calls(e.kind) and by[e.from] and by[e.to] then
      local a, b = inside[e.from], inside[e.to]
      if a and b then
        edges[#edges + 1] = e
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
  layered(sections, keys, edges, item)
  local below = {}
  side(below, 'calls out', others(callees))
  if #below > 0 then sections[#sections + 1] = { arrow = true }; vim.list_extend(sections, below) end
  local crumbs = { 'parts', module }
  if file then crumbs[#crumbs + 1] = file:sub(#module + 2) ~= '' and module:sub(1, 1) ~= '(' and file:sub(#module + 2) or file end
  if class then crumbs[#crumbs + 1] = class.name end
  return { crumbs = crumbs, sections = sections }
end

-- A query's answer (desk-work map query --q reach|callers|paths).
-- A trace (desk-work map query --q trace): the lane through a function, a box per step (the function itself in a double
-- frame) with its parameters under it, how each is passed and whether the callee can write the caller's value
-- through it (inout), its other callers and callees (Enter on one goes there), and between steps the call: its line
-- and each argument → the parameter it lands in.
local PASS_WORD = { value = 'value', ['const ref'] = 'const ref', ref = 'ref', rvalue = 'moved in', pointer = 'pointer',
  ['const pointer'] = 'const ptr', array = 'array', ['const array'] = 'const array', smart = 'smart ptr' }
-- folds: the page's open and closed folds by step and fold ("<id>|params"); a fold not named is as FOLDS_OPEN says.
local FOLDS_OPEN = { params = true, uses = false, layout = false, callers = false, callees = false }
-- ▲ and ▼ on a card: Enter opens the map's callers (everything above it) or reach (everything below) page from that
-- step, in layers as the call graph has them (+ and - add and take off a level), Backspace back to the trace.
local function walk_item(st, q, count)
  return { name = (q == 'callers' and '▲ ' or '▼ ') .. count, target = { kind = 'walk', q = q, node = st }, key = 'walk:' .. q .. ':' .. st.id }
end
local function fold_item(id, name, open, count)
  return { name = name, target = { kind = 'fold', fold = id .. '|' .. name }, key = 'fold:' .. id .. '|' .. name, open = open, count = count }
end
-- A type's own name: `const tt::Tick<F> &` is Tick (what symdeps' census names a record by, its last part).
local function base_type(t)
  local bare = tostring(t or ''):gsub('%b<>', ''):gsub('[%*&]', ''):gsub('%f[%w]const%f[%W]', ''):gsub('%f[%w]struct%f[%W]', '')
  return vim.trim(bare):match('([%a_][%w_]*)$')
end
M.base_type = base_type

local LETTERS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
--- pure: each member's letter as the byte map draws it, its offset and size: { [name] = { letter, off, size } }
--- (Codex's #10: the same letter in the byte map, the uses and the field table answers "which bytes does it write?").
function M.member_letters(rec)
  local out = {}
  for i, mb in ipairs(rec and rec.members or {}) do
    if mb.name and LETTERS:sub(i, i) ~= '' then out[mb.name] = { letter = LETTERS:sub(i, i), off = mb.off, size = mb.size } end
  end
  return out
end
-- A member's size as said: bits for a bit-field, bytes, or ? where symdeps could not tell.
local function member_size(mb)
  if mb.bit_hi then return (mb.bit_hi - mb.bit_lo + 1) .. ' bits' end
  return mb.size and (mb.size .. ' B') or '?'
end
-- A struct's bytes, 16 to a row: each member's letter over its bytes; ▒ where members share a byte (bit-fields packed
-- together, a union); · padding, only on a layout symdeps placed completely; ░ bytes it could not account for (a partial
-- layout's gaps: they may be a member it could not read). Beside each row, the members that start in it, by letter, name
-- and size (a hex editor's text column), so no legend has to be matched. The members `touched` names are lit. Long runs
-- of the same row fold into one line; at most `cap` lines. → { rows = parts lines, legend = parts lines (the marks'
-- key), padding = bytes or nil }.
function M.byte_map(rec, touched, retro, cap)
  touched, cap = touched or {}, cap or 40 -- a big struct's members, folded runs and all (the trader's ExecutionCore: 34)
  local more = retro and '..' or '…'
  local size = rec.size or 0
  local owners = {}
  for i, mb in ipairs(rec.members or {}) do
    local last
    if mb.bit_hi then last = mb.off + math.floor(mb.bit_hi / 8)
    elseif mb.size then last = mb.off + mb.size - 1
    elseif not mb.empty then last = mb.off end
    for b = mb.off or 0, math.min(last or -1, size - 1) do
      owners[b] = owners[b] or {}
      table.insert(owners[b], i)
    end
  end
  local function cell(b)
    local o = owners[b]
    if not o then return rec.complete and '·' or '░', 'DeskMapDim', rec.complete and 'pad' or 'unknown' end
    local lit = false
    for _, i in ipairs(o) do if touched[rec.members[i].name] then lit = true end end
    if #o > 1 then return '▒', lit and 'DeskMapFocus' or nil, 'shared' end
    return LETTERS:sub(o[1], o[1]) ~= '' and LETTERS:sub(o[1], o[1]) or '#', lit and 'DeskMapFocus' or nil
  end
  local seen, padding = {}, 0
  local w = math.max(4, #tostring(math.max(0, size - 1))) -- one offset width, so maps under each other line up
  local rows, raw = {}, {}
  for r = 0, math.ceil(size / 16) - 1 do
    local cells, key = {}, ''
    for b = r * 16, math.min(size, r * 16 + 16) - 1 do
      local ch, group, kind = cell(b)
      if kind then seen[kind] = true end
      if kind == 'pad' then padding = padding + 1 end
      cells[#cells + 1] = { ch, group }
      key = key .. ch .. (group or '')
    end
    raw[#raw + 1] = { off = r * 16, cells = cells, key = key }
  end
  local starts = {}
  for i, mb in ipairs(rec.members or {}) do
    local r = math.floor((mb.off or 0) / 16)
    starts[r] = starts[r] or {}
    table.insert(starts[r], i)
  end
  local function row(rw)
    local parts = { { '    ' .. string.format('%' .. w .. 'd', rw.off) .. ' │', nil, nil, 'DeskMapDim' } }
    for k, c in ipairs(rw.cells) do
      if k == 9 then parts[#parts + 1] = { ' ' } end
      local last = parts[#parts]
      if k ~= 9 and k > 1 and last[4] == c[2] and last.cell then last[1] = last[1] .. c[1]
      else parts[#parts + 1] = { c[1], nil, nil, c[2], cell = true } end
    end
    parts[#parts + 1] = { '│', nil, nil, 'DeskMapDim' }
    for _, i in ipairs(starts[rw.off / 16] or {}) do
      local mb, letter = rec.members[i], LETTERS:sub(i, i) ~= '' and LETTERS:sub(i, i) or '#'
      parts[#parts + 1] = { '  ' }
      parts[#parts + 1] = { letter .. ' ', nil, nil, 'DeskMapDim' }
      parts[#parts + 1] = { mb.name .. ' ' .. member_size(mb), nil, nil, touched[mb.name] and 'DeskMapFocus' or nil }
    end
    return parts
  end
  local k = 1
  while k <= #raw do
    if #rows >= cap then
      rows[#rows + 1] = { { '    ' .. more .. ' ' .. (size - raw[k].off) .. ' more bytes', nil, true, 'DeskMapDim' } }
      break
    end
    local rw = raw[k]
    if rw.off > 0 and rw.off % 64 == 0 then
      rows[#rows + 1] = { { '    ' .. string.rep(' ', w) .. ' ─── line ' .. (math.floor(rw.off / 64) + 1) .. ' ───', nil, true, 'DeskMapDim' } }
    end
    rows[#rows + 1] = row(rw)
    local j = k
    while raw[j + 1] and raw[j + 1].key == rw.key and #raw[j + 1].cells == #rw.cells do j = j + 1 end
    if j - k >= 2 then
      local last = math.min(size, raw[j].off + 16) - 1
      -- a run over a cache line's start says where it ends (the line marks inside it are folded with it)
      local to_line = math.floor(last / 64) > math.floor(rw.off / 64) and (', line ' .. (math.floor(last / 64) + 1)) or ''
      rows[#rows + 1] = { { '    ' .. string.rep(' ', w) .. '  ' .. more .. ' the same to byte ' .. last .. to_line, nil, true, 'DeskMapDim' } }
      k = j + 1
    else
      k = k + 1
    end
  end
  -- the marks' key, under the map's cells
  local key = {}
  if seen.shared then key[#key + 1] = '▒ shared' end
  if seen.pad then key[#key + 1] = '· padding' end
  if seen.unknown then key[#key + 1] = '░ not accounted for' end
  local legend = {}
  if #key > 0 then legend[1] = { { '    ' .. string.rep(' ', w) .. '  ' }, { table.concat(key, '  '), nil, true, 'DeskMapDim' } } end
  return { rows = rows, legend = legend, padding = rec.complete and padding or nil }
end
-- A list on a card's line, a part per name ("px · ts · seq"), its first part marked to wrap under (a card wraps such a
-- line between the names instead of cutting it).
-- item(n): a name's hit (a field of a step's parameter: Enter follows it), or nil.
--- pure: what the reader left out of a list, said beside it: "12 shown · 3 more omitted".
function M.omitted(shown, more)
  if not more or more <= 0 then return nil end
  return shown .. ' shown · ' .. more .. ' more omitted'
end
local function listed(names, group, item, lit, more, label)
  local parts = {}
  for i, n in ipairs(names) do
    local hit = item and item(n) or nil
    local mark = lit and lit(n) and (lit(n) .. ' ') or ''
    parts[#parts + 1] = { mark .. (label and label(n) or n) .. (i < #names and ' · ' or ''), hit, nil, (mark ~= '' and 'DeskMapFocus') or group, hang = i == 1 }
  end
  local said = M.omitted(#names, more)
  if said then parts[#parts + 1] = { '   (' .. said .. ')', nil, true, 'DeskMapDim' } end
  return parts
end
-- A layout's shape, to tell a template's versions apart: the same size and members are one layout.
local function layout_signature(rec)
  local t = { tostring(rec.size) }
  for _, mb in ipairs(rec.members or {}) do t[#t + 1] = table.concat({ mb.name, mb.off or '', mb.size or '', mb.bit_lo or '', mb.bit_hi or '' }, ':') end
  return table.concat(t, '|')
end
-- Possible false sharing on a route (her ask, 2026-11-18: "has false sharing with x function on y thread? Since threads
-- can change"): a field one thread writes on the same 64 B line as another field a step on another thread touches. The
-- threads are the route's own as traced now — a handoff starts one, named by its first step — never a fixed list.
-- Only where symdeps placed the struct completely, with one layout; the map cannot tell that the two steps hold the
-- same object, so it says "may". → { [step id] = { [type] = { { other, thread, here, there, line } } } }.
function M.false_sharing(steps, calls, layouts)
  local thread, current = {}, steps[1] and steps[1].label
  for k, st in ipairs(steps) do
    if k > 1 and calls[k - 1] and calls[k - 1].kind == 'handoff' then current = st.label end
    thread[k] = current
  end
  local records = {}
  for _, got in pairs(layouts or {}) do
    for _, rec in ipairs(type(got) == 'table' and got.records or {}) do
      local b = base_type(rec.name)
      if b then records[b] = records[b] or {}; table.insert(records[b], rec) end
    end
  end
  local function layout(t)
    local list, seen, one = records[t] or {}, {}, nil
    for _, r in ipairs(list) do
      local sig = layout_signature(r)
      if not seen[sig] then seen[sig] = true; if one then return nil end; one = r end
    end
    return one and one.complete == true and one or nil
  end
  local function lines_of(rec, name)
    for _, mb in ipairs(rec.members or {}) do
      if mb.name == name and mb.off then
        local last = mb.bit_hi and (mb.off + math.floor(mb.bit_hi / 8)) or (mb.size and mb.off + math.max(mb.size, 1) - 1) or nil
        if last then return math.floor(mb.off / 64), math.floor(last / 64) end
      end
    end
  end
  local uses = {}
  for k, st in ipairs(steps) do
    uses[k] = {}
    for _, prm in ipairs(st.params or {}) do
      local t = base_type(prm.type)
      if t then
        local u = uses[k][t] or { writes = {}, touches = {} }
        uses[k][t] = u
        for _, path in ipairs(prm.writes or {}) do local f = path:match('^[^.]+'); u.writes[f] = true; u.touches[f] = true end
        for _, path in ipairs(prm.reads or {}) do local f = path:match('^[^.]+'); u.touches[f] = true end
      end
    end
  end
  local out = {}
  local function add(k, t, note)
    local id = steps[k].id
    out[id] = out[id] or {}
    out[id][t] = out[id][t] or {}
    for _, n in ipairs(out[id][t]) do if n.other == note.other and n.here == note.here and n.there == note.there then return end end
    table.insert(out[id][t], note)
  end
  for k = 1, #steps do
    for j = 1, #steps do
      if j ~= k and thread[j] ~= thread[k] then
        for t, mine in pairs(uses[k]) do
          local theirs, rec = uses[j][t], nil
          if theirs then rec = layout(t) end
          if rec then
            for a in pairs(mine.touches) do
              for b in pairs(theirs.touches) do
                if a ~= b and (mine.writes[a] or theirs.writes[b]) then
                  local a1, a2 = lines_of(rec, a)
                  local b1, b2 = lines_of(rec, b)
                  if a1 and b1 and a1 <= b2 and b1 <= a2 then
                    add(k, t, { other = steps[j].label, thread = thread[j], line = math.max(a1, b1) + 1,
                      here = (mine.writes[a] and 'writes ' or 'reads ') .. a, there = (theirs.writes[b] and 'writes ' or 'reads ') .. b })
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  for _, by_type in pairs(out) do
    for _, list in pairs(by_type) do table.sort(list, function(x, y) return x.other .. x.here .. x.there < y.other .. y.here .. y.there end) end
  end
  return out
end
-- layouts: symdeps' census of a step's file, by file: { records } | { pending = true } | { error = why }.
-- field: { type, name } a field followed on this route (her pick: Enter on it, "highlight on this route").
function M.trace_page(answer, folds, layouts, field)
  folds, layouts = folds or {}, layouts or {}
  local retro = M.retro()
  -- code page 437 has no ▸ ▾ …: DOS's tree marks in retro
  local open_mark, closed_mark, ellipsis = retro and '- ' or '▾ ', retro and '+ ' or '▸ ', retro and '..' or '…'
  local steps, calls = answer.steps or {}, answer.calls or {}
  local sharing = M.false_sharing(steps, calls, layouts)
  local mark = M.retro() and '♦' or '◆'
  -- A field of a step's parameter, a hit: Enter follows it (its declaration, who writes it, on this route).
  local st_now
  local function field_hit(prm)
    local t = base_type(prm.type)
    return function(path)
      local head = path:match('^[^.]+')
      return { name = (t or '?') .. '.' .. head, key = 'field:' .. tostring(st_now and st_now.id) .. ':' .. prm.name .. ':' .. head,
        target = { kind = 'field', type = t, field = head, param = prm.name, step = st_now } }
    end
  end
  local function field_lit(prm)
    local t = base_type(prm.type)
    return function(path) return field and t == field.type and path:match('^[^.]+') == field.name and mark or nil end
  end
  local focus
  for _, st in ipairs(steps) do if st.id == answer.focus then focus = st end end
  local sections = { { head = 'trace through ' .. code(focus and focus.label) .. ' · ' .. #steps .. (#steps == 1 and ' function' or ' functions') } }
  -- A possible path, not the only one: its ends, and who chose each (her e and S, or the map: the farthest start, the
  -- end of the calls) — a backtest's route then says so before it is read as the live one.
  if #steps > 1 then
    local first, last = steps[1], steps[#steps]
    sections[#sections + 1] = { block = { { { 'from ' .. tostring(first.label), nil, nil, 'DeskMapName' },
      { answer.start and ' (your choice)' or ' (picked by the map: the farthest start)', nil, true, 'DeskMapDim' },
      { ' · to ' .. tostring(last.label), nil, nil, 'DeskMapName' },
      { answer.to and ' (your choice)' or ' (picked by the map: where the calls end)', nil, true, 'DeskMapDim' } } }, group = 'DeskMapDim' }
  end
  -- the other starts it could have begun at (T3): each one Enter away from the trace again from there
  if type(answer.starts) == 'table' and #answer.starts > 0 then
    local parts = { { 'also starts at: ', nil, true, 'DeskMapDim' } }
    for k, st in ipairs(answer.starts) do
      parts[#parts + 1] = { tostring(st.label), { name = tostring(st.label), key = 'start:' .. tostring(st.id), target = { kind = 'start', id = st.id, node = st } } }
      if k < #answer.starts then parts[#parts + 1] = { ' · ', nil, nil, 'DeskMapDim' } end
    end
    sections[#sections + 1] = { block = { parts }, group = 'DeskMapDim' }
  end
  if focus and focus.before then
    sections[#sections + 1] = { block = { { { '▲ ' .. focus.before, walk_item(focus, 'callers', focus.before) }, { ' before · ', nil, true },
      { '▼ ' .. (focus.after or 0), walk_item(focus, 'reach', focus.after or 0) }, { ' after it in the map', nil, true } } }, group = 'DeskMapDim' }
  end
  if answer.to and answer.reached == false then
    sections[#sections + 1] = { parts = { { (focus and focus.label or '?') .. ' does not reach ' .. answer.to:gsub('^.*::', '') .. ' within '
      .. (answer.depth or '?') .. ' calls' } }, group = 'DeskMapDim' }
  end
  if answer.start and answer.start_reached == false then
    sections[#sections + 1] = { parts = { { answer.start:gsub('^.*::', '') .. ' does not lead to ' .. (focus and focus.label or '?') .. ' within '
      .. (answer.depth or '?') .. ' calls' } }, group = 'DeskMapDim' }
  end
  if field then
    -- The field followed on this route: who writes it, who reads it (matched by name within its struct: the trace knows
    -- the fields' names, not which object each step holds).
    local wrote, read = {}, {}
    for _, st in ipairs(steps) do
      for _, prm in ipairs(st.params or {}) do
        if base_type(prm.type) == field.type then
          for _, path in ipairs(prm.writes or {}) do if path:match('^[^.]+') == field.name and not vim.tbl_contains(wrote, st.label) then wrote[#wrote + 1] = st.label end end
          for _, path in ipairs(prm.reads or {}) do if path:match('^[^.]+') == field.name and not vim.tbl_contains(read, st.label) then read[#read + 1] = st.label end end
        end
      end
    end
    sections[#sections + 1] = { block = { { { mark .. ' ' .. field.type .. '.' .. field.name, nil, nil, 'DeskMapFocus' },
      { ' on this route: written by ' .. (#wrote > 0 and table.concat(wrote, ', ') or 'none') .. ' · read by ' .. (#read > 0 and table.concat(read, ', ') or 'none')
        .. ' (by name, within ' .. field.type .. ')', nil, true, 'DeskMapDim' } } } }
  end
  for k, st in ipairs(steps) do
    st_now = st
    local body = {}
    local size = st.lines and (st.lines .. (st.lines == 1 and ' line' or ' lines')) or nil
    local first = {}
    -- what it returns, a hit when it returns something: Enter shows where that result goes in each caller
    if st.returns then
      first[#first + 1] = { '→ ' .. st.returns, st.returns ~= 'void' and { name = st.label .. ' → ' .. st.returns, key = 'result:' .. st.id,
        target = { kind = 'result', node = st } } or nil }
    end
    if size then first[#first + 1] = { (#first > 0 and ' · ' or '') .. size, nil, true, 'DeskMapDim' } end
    if st.before then
      if #first > 0 then first[#first + 1] = { ' · ', nil, nil, 'DeskMapDim' } end
      first[#first + 1] = { '▲ ' .. st.before, walk_item(st, 'callers', st.before) }
      first[#first + 1] = { ' ' }
      first[#first + 1] = { '▼ ' .. (st.after or 0), walk_item(st, 'reach', st.after or 0) }
    end
    if #first > 0 then body[#body + 1] = first end
    local function fold(name, title, count, rows)
      if count == 0 then return end
      local key = st.id .. '|' .. name
      local open = folds[key]
      if open == nil then open = FOLDS_OPEN[name] or (name == 'uses' and st.role == 'focus') end
      body[#body + 1] = { { (open and open_mark or closed_mark) }, { title .. ' (' .. count .. ')', fold_item(st.id, name, open, count), true, 'DeskMapHead' } }
      if open then for _, row in ipairs(rows()) do body[#body + 1] = row end end
    end
    local params = st.params or {}
    fold('params', 'parameters', #params, function()
      local rows, wpass, wtype, wdir = {}, 0, 0, 0
      for _, prm in ipairs(params) do
        wpass = math.max(wpass, #(PASS_WORD[prm.pass] or prm.pass))
        wtype = math.max(wtype, vim.fn.strdisplaywidth(prm.type))
        wdir = math.max(wdir, #prm.dir)
      end
      for _, prm in ipairs(params) do
        rows[#rows + 1] = { { '    ' .. string.format('%-' .. wdir .. 's  %-' .. wpass .. 's  ', prm.dir, PASS_WORD[prm.pass] or prm.pass), nil, true, 'DeskMapDim' },
          { prm.type .. string.rep(' ', wtype - vim.fn.strdisplaywidth(prm.type)) .. '  ' }, { prm.name, nil, nil, 'DeskMapName' } }
      end
      local said = M.omitted(#params, st.params_more)
      if said then rows[#rows + 1] = { { '    ' .. said .. ' (the reader keeps 16)', nil, true, 'DeskMapDim' } } end
      return rows
    end)
    -- What it reads and writes of each parameter (struct consumption), a line each way.
    local used = vim.tbl_filter(function(prm) return #(prm.reads or {}) > 0 or #(prm.writes or {}) > 0 end, params)
    -- A field laid out by symdeps: its byte map letter, offset and size beside it (one layout of the type only).
    local function letters_for(prm)
      local got = st.file and layouts[st.file]
      local want, found = base_type(prm.type), nil
      for _, rec in ipairs(got and got.records or {}) do
        if base_type(rec.name) == want then
          if found and layout_signature(found) ~= layout_signature(rec) then return nil end
          found = found or rec
        end
      end
      if not found then return nil end
      local by = M.member_letters(found)
      return function(path)
        local l = by[path:match('^[^.]+')]
        if not l then return path end
        return l.letter .. ' ' .. path .. ' @' .. tostring(l.off) .. (l.size and (' ' .. l.size .. 'B') or '')
      end
    end
    fold('uses', 'uses', #used, function()
      local rows, wname = {}, 0
      for _, prm in ipairs(used) do wname = math.max(wname, vim.fn.strdisplaywidth(prm.name)) end
      for _, prm in ipairs(used) do
        local name = prm.name .. string.rep(' ', wname - vim.fn.strdisplaywidth(prm.name))
        if #(prm.reads or {}) > 0 then
          rows[#rows + 1] = vim.list_extend({ { '    ' }, { name, nil, nil, 'DeskMapName' }, { '  reads   ', nil, true, 'DeskMapDim' } }, listed(prm.reads, nil, field_hit(prm), field_lit(prm), prm.reads_more, letters_for(prm)))
          name = string.rep(' ', wname)
        end
        if #(prm.writes or {}) > 0 then
          rows[#rows + 1] = vim.list_extend({ { '    ' }, { name, nil, nil, 'DeskMapName' }, { '  writes  ', nil, true, 'DeskMapDim' } }, listed(prm.writes, 'DeskMapFocus', field_hit(prm), field_lit(prm), prm.writes_more, letters_for(prm)))
        end
      end
      return rows
    end)
    -- The structs it is passed, as symdeps lays them out: size, alignment, the fields this function touches and where.
    if #params > 0 and st.file then
      fold('layout', 'layout', #params, function()
        local got = layouts[st.file]
        if not got then return { { { '    ' }, { 'opening asks symdeps to lay this file out', nil, true, 'DeskMapDim' } } } end
        -- What this step asks of the file's answer (merged from every step that asked: by file and type, not first come)
        local waiting, asked = got.pending == true, got.all or got.records ~= nil and got.asked == nil
        for _, prm in ipairs(params) do
          local t = base_type(prm.type)
          if t and got.pending_types and got.pending_types[t] then waiting = true end
          if t and got.asked and got.asked[t] then asked = true end
        end
        if not waiting and not asked and not got.error then
          return { { { '    ' }, { 'opening asks symdeps to lay this file out', nil, true, 'DeskMapDim' } } }
        end
        if waiting then return { { { '    ' }, { 'symdeps is laying this file out' .. ellipsis, nil, true, 'DeskMapDim' } } } end
        if got.error and #(got.records or {}) == 0 then return { { { '    ' }, { got.error, nil, nil, 'DeskMapDim' } } } end
        local by = {}
        for _, rec in ipairs(got.records or {}) do
          local base = base_type(rec.name)
          if base then
            by[base] = by[base] or {}
            table.insert(by[base], rec)
          end
        end
        local rows = {}
        for _, prm in ipairs(params) do
          local versions, distinct, seen = by[base_type(prm.type) or ''] or {}, {}, {}
          for _, v in ipairs(versions) do
            local sig = layout_signature(v)
            if not seen[sig] then seen[sig] = true; distinct[#distinct + 1] = v end
          end
          if #distinct > 1 then
            -- a template's versions that differ: all said, none picked (which one this function gets is clangd's to say)
            rows[#rows + 1] = { { '    ' }, { prm.name, nil, nil, 'DeskMapName' }, { '  ' .. base_type(prm.type) .. '  ' },
              { #distinct .. ' versions, laid out differently', nil, true, 'DeskMapDim' } }
            for _, v in ipairs(distinct) do
              rows[#rows + 1] = { { '        ' .. v.name .. '  ' }, { v.size .. ' B, align ' .. (v.align or '?'), nil, true, 'DeskMapDim' } }
            end
          elseif distinct[1] then
            local rec = distinct[1]
            local touched, named, member = {}, {}, {}
            for _, mb in ipairs(rec.members or {}) do member[mb.name] = mb end
            for _, list in ipairs({ prm.reads or {}, prm.writes or {} }) do
              for _, path in ipairs(list) do
                local head = path:match('^[^.]+')
                local mb = member[head]
                if mb and not named[head] then
                  named[head] = true
                  local l = M.member_letters(rec)[head]
                  touched[#touched + 1] = (l and (l.letter .. ' ') or '') .. head .. '@' .. mb.off .. ' ' .. member_size(mb)
                end
              end
            end
            local map = M.byte_map(rec, named, retro)
            local lines_ = rec.size and math.max(1, math.ceil(rec.size / 64)) or nil
            rows[#rows + 1] = { { '    ' }, { prm.name, nil, nil, 'DeskMapName' }, { '  ' .. base_type(prm.type) .. '  ' },
              { (rec.size and (rec.size .. ' B') or '? B') .. (rec.align and (', align ' .. rec.align) or '') .. (lines_ and (' · ' .. lines_ .. (lines_ == 1 and ' line' or ' lines')) or '')
                .. (map.padding and map.padding > 0 and (' · ' .. map.padding .. ' B padding') or ''), nil, true, 'DeskMapDim' } }
            if #touched > 0 then rows[#rows + 1] = vim.list_extend({ { '        ' }, { 'touches  ', nil, true, 'DeskMapDim' } }, listed(touched)) end
            for _, note in ipairs(sharing[st.id] and sharing[st.id][base_type(prm.type) or ''] or {}) do
              rows[#rows + 1] = { { '        ' }, { 'may share a cache line ', nil, true, 'DeskMapFocus' },
                { 'with ' .. note.other .. ' on the ' .. note.thread .. ' thread: ' .. note.here .. ' here, ' .. note.there .. ' there (line ' .. note.line .. ')', nil, nil, 'DeskMapFocus' } }
            end
            if rec.complete == false then
              rows[#rows + 1] = { { '        ' }, { 'partly laid out: ' .. (rec.why or 'symdeps could not size every member'), nil, nil, 'DeskMapDim' } }
            end
            for _, r in ipairs(map.rows) do rows[#rows + 1] = r end
            for _, r in ipairs(map.legend) do rows[#rows + 1] = r end
          end
        end
        if #rows == 0 then rows[1] = { { '    ' }, { 'no struct it is passed is laid out in this file', nil, true, 'DeskMapDim' } } end
        return rows
      end)
    end
    for _, side in ipairs({ { 'callers', 'more_callers', 'other callers' }, { 'callees', 'more_callees', 'other callees' } }) do
      local list, more = st[side[1]] or {}, st[side[2]] or 0
      fold(side[1], side[3], more, function()
        local rows = {}
        for _, other in ipairs(list) do rows[#rows + 1] = { { '    ' }, { other.label, node_item(other) }, { '  ' .. where(other), nil, nil, 'DeskMapDim' } } end
        if more > #list then rows[#rows + 1] = { { '    ' .. ellipsis .. ' ' .. (more - #list) .. ' more', nil, true, 'DeskMapDim' } } end
        return rows
      end)
    end
    local call, after = calls[k], steps[k + 1]
    local card = { item = node_item(st), title = st.label, right = where(st), body = body, column = true,
      frame = st.role == 'focus' and 'double' or 'single' }
    sections[#sections + 1] = { card = card }
    if call and after and call.kind == 'handoff' then
      -- No call between the two: what one gives, the other takes (a ring's push and pop, a thread started with it, a
      -- function pointer). Inferred from the code, and said so.
      -- `x` on it drops a wrong one; one she added says so.
      -- Enter offers its two sides: where it is handed over (the push), where it is taken (the pop).
      local item = { name = call.label or 'handoff', target = { kind = 'handoff', from = call.from, to = call.to, by_hand = call.by_hand == true,
        producer = { label = st.label, file = st.file, line = call.line or st.line },
        consumer = { label = after.label, file = after.file, line = call.to_line or after.line } },
        key = 'handoff:' .. tostring(call.from) .. '>' .. tostring(call.to) }
      -- a full-width break: "inferred" said on the transition, where the reader decides whether to trust it
      sections[#sections + 1] = { blank = true }
      sections[#sections + 1] = { rule = { said = 'handoff · ' .. (call.by_hand and 'added by you' or 'inferred'), label = call.label or 'handoff', item = item } }
      sections[#sections + 1] = { blank = true }
    elseif call and after and call.kind == 'none' then
      -- Two steps with no call between them: a cycle on the route (A → F → A → Z) was walked once, so F and Z meet here
      -- without F calling Z. Said, never drawn as a call.
      body[#body + 1] = { { '┄ no call to ' .. after.label .. ': the route came back through a cycle here', nil, true, 'DeskMapDim' } }
      sections[#sections + 1] = { blank = true }
    elseif call and after then
      local flow, into = {}, after.params or {}
      for i, arg in ipairs(call.args or {}) do
        local prm = into[i]
        flow[#flow + 1] = (prm and prm.name ~= '' and prm.name ~= arg) and (arg .. ' → ' .. prm.name) or arg
      end
      local sites = call.sites or (call.line and { { line = call.line, args = call.args } }) or {}
      local calls_n = #sites + (call.sites_more or 0)
      local at = call.line and (':' .. call.line .. (calls_n > 1 and (' (' .. calls_n .. ' calls' .. ((call.sites_more or 0) > 0 and (', ' .. #sites .. ' kept') or '') .. ')') or '')) or ''
      if at ~= '' or #flow > 0 then
        -- A part per argument, so a long call wraps between them; the line its own hit: Enter opens the call (each of
        -- them when there are several).
        local call_item = { name = st.label .. ' → ' .. after.label, key = 'call:' .. tostring(call.from) .. '>' .. tostring(call.to),
          target = { kind = 'call', file = st.file, caller = st.label, callee = after.label, sites = sites } }
        -- the call, indented under the step that makes it: "calls  submit(Order{t.px} → order · 3 → retries)   :11"
        local parts = { { 'calls  ', nil, true, 'DeskMapDim' }, { after.label, nil, nil, 'DeskMapName' }, { '(' } }
        for i, f in ipairs(flow) do parts[#parts + 1] = { f .. (i < #flow and ' · ' or ''), nil, nil, 'DeskMapDim', hang = i == 1 } end
        parts[#parts + 1] = { ')' }
        local said = M.omitted(#flow, call.args_more)
        if said then parts[#parts + 1] = { '   (' .. said .. ')', nil, nil, 'DeskMapDim' } end
        if at ~= '' then parts[#parts + 1] = { at, call_item, nil, 'DeskMapName', right = true } end
        body[#body + 1] = parts
      end
      sections[#sections + 1] = { blank = true }
    end
  end
  return { crumbs = { 'trace' }, sections = sections }
end

-- T: the whole trace (desk-work map query --q flow): every way through a function in one picture, what leads to it
-- above and what it leads to below, in layers by their calls; the trace's own lane in double frames, the function
-- asked about where the selection starts. A start or end she chose (S, e) narrows it, and the page says so.
function M.flow_page(answer)
  local by, keys = {}, {}
  for _, n in ipairs(answer.nodes or {}) do by[n.id] = n; keys[#keys + 1] = n.id end
  table.sort(keys, function(a, b)
    if (by[a].at or 0) ~= (by[b].at or 0) then return (by[a].at or 0) < (by[b].at or 0) end
    return a < b
  end)
  local label = function(id) return (by[id] and by[id].label) or (tostring(id or '?'):gsub('^.*::', '')) end
  local sections = { { head = 'whole trace through ' .. code(label(answer.focus)) .. ' · ' .. #keys .. (#keys == 1 and ' function' or ' functions') } }
  local said = 'what leads to it above, what it leads to below; double: the lane `t` follows'
  if answer.start then said = 'from ' .. code(label(answer.start)) .. ' (your choice) · ' .. said end
  if answer.to then said = said .. ' · to ' .. code(label(answer.to)) .. ' (your choice)' end
  sections[#sections + 1] = { parts = { { said, nil, true } }, group = 'DeskMapDim' }
  if answer.to and answer.reached == false then
    sections[#sections + 1] = { parts = { { label(answer.focus) .. ' does not reach ' .. label(answer.to) .. ' within ' .. (answer.depth or '?') .. ' calls', nil, true } }, group = 'DeskMapDim' }
  end
  local function item(id)
    local n = by[id]
    return node_item(n, { frame = n.lane and 'double' or nil, focus = id == answer.focus or nil })
  end
  layered(sections, keys, answer.edges or {}, item)
  return { crumbs = { 'whole trace' }, sections = sections }
end

function M.level_query(answer, level)
  local page = M.level_query_plain(answer, level)
  -- What this answer was asked without, said where the answer is read: one line, and the key that brings them back.
  if type(answer.excluded) == 'table' and #answer.excluded > 0 and page and page.sections then
    local names = vim.tbl_map(function(id) return tostring(id):match('::(.+)$') or tostring(id) end, answer.excluded)
    table.insert(page.sections, 1, { parts = { { #names .. ' left out of this answer: ' .. table.concat(names, ' · ') }, { '  · Z brings them back', nil, true } },
      group = 'DeskMapFocus' })
  end
  return page
end
function M.level_query_plain(answer, level)
  if answer.q == 'trace' then return M.trace_page(answer, level and level.folds, level and level.layouts, level and level.field) end
  if answer.q == 'routes' then return M.routes_page(answer) end
  if answer.q == 'flow' then return M.flow_page(answer) end
  local sections = {}
  if answer.q == 'changes' then
    -- What the last rebuild changed against the build before it, and why as far as the builds can say.
    sections[#sections + 1] = { head = 'what the rebuild changed · ' .. os.date('%H:%M', tonumber(answer.built_at) or 0)
      .. (answer.previous_built_at and (' against ' .. os.date('%H:%M', tonumber(answer.previous_built_at) or 0)) or '') }
    local because = type(answer.because) == 'table' and answer.because or {}
    sections[#sections + 1] = { parts = { { #because > 0 and ('because ' .. table.concat(because, ' · ')) or 'the same source, binary and parsers: the readers answered differently' } }, group = 'DeskMapDim' }
    local function short(id) return tostring(id):match('::(.+)$') or tostring(id) end
    local function list(title, items, count, row)
      if (tonumber(count) or 0) == 0 then return end
      sections[#sections + 1] = { head = title .. ' · ' .. count .. ((tonumber(count) or 0) > #items and (' (the first ' .. #items .. ')') or '') }
      local rows = {}
      for _, it in ipairs(items) do rows[#rows + 1] = row(it) end
      sections[#sections + 1] = { block = rows }
    end
    -- each change a target where the answer says where it is (Codex's E9): an added call opens in its file today, a
    -- removed one in the source the build before read
    local function change(side, name, key, file, line)
      if not file then return nil end
      return { name = name, key = 'change:' .. side .. ':' .. key, target = { kind = 'change', side = side, file = file, line = line,
        head = side == 'removed' and answer.previous_head or nil } }
    end
    local function call_row(side)
      return function(e)
        local name = short(e.from) .. ' → ' .. short(e.to)
        return { { name, change(side, name, tostring(e.from) .. '>' .. tostring(e.to), e.file, e.line) },
          { e.kind == 'call-by-name' and '  (by name)' or e.kind == 'handoff' and '  (handoff)' or '', nil, true, 'DeskMapDim' } }
      end
    end
    list('calls added', answer.edges_added_list or {}, answer.edges_added, call_row('added'))
    list('calls removed', answer.edges_removed_list or {}, answer.edges_removed, call_row('removed'))
    list('functions added', answer.nodes_added_list or {}, answer.nodes_added, function(n) return { { n.label, n.file and node_item(n) or nil } } end)
    list('functions removed', answer.nodes_removed_list or {}, answer.nodes_removed, function(n)
      return { { n.label, change('removed', n.label, tostring(n.id), n.file ~= vim.NIL and n.file or nil, n.line ~= vim.NIL and n.line or nil) } }
    end)
    local moved = {}
    if (tonumber(answer.found_source) or 0) > 0 then moved[#moved + 1] = answer.found_source .. ' found their source' end
    if (tonumber(answer.lost_source) or 0) > 0 then moved[#moved + 1] = answer.lost_source .. ' lost their source match' end
    if #moved > 0 then sections[#sections + 1] = { parts = { { table.concat(moved, ' · ') } }, group = 'DeskMapDim' } end
    return { crumbs = { 'changes' }, sections = sections }
  end
  if answer.q == 'handoffs' then
    -- Her handoff corrections, each checked against the map as built now (Codex's #38): what she added and dropped,
    -- its label, where it is declared, and whether each end is still there. Enter: forget, rebind, open.
    local entries = answer.entries or {}
    sections[#sections + 1] = { head = 'handoff corrections · ' .. #entries }
    sections[#sections + 1] = { parts = { { 'desk-work keeps yours in ' .. vim.fn.fnamemodify(tostring(answer.file or ''), ':~') }, { ' · Enter on one: forget, rebind or open it', nil, true } }, group = 'DeskMapDim' }
    local STATE = { ok = '', moved = '  (moved)', ambiguous = '  (ambiguous: several now)', gone = '  (gone from the map)' }
    for i, e in ipairs(entries) do
      local function name(side)
        local id = tostring(e[side] and e[side].id or '?')
        return id:match('::(.+)$') or id
      end
      local trouble = (e.from.state ~= 'ok' or e.to.state ~= 'ok' or e.stale) and 'DeskMapFocus' or nil
      local item = { name = name('from') .. ' → ' .. name('to'), key = 'correction:' .. i, target = { kind = 'correction', entry = e } }
      local rows = { { { (e.side == 'add' and 'added    ' or 'dropped  '), nil, true, 'DeskMapDim' }, { name('from') .. STATE[e.from.state or 'ok'], item, nil, trouble },
        { ' → ' }, { name('to') .. STATE[e.to.state or 'ok'], nil, nil, trouble },
        { e.label and ('   ══ ' .. e.label .. ' ══') or '', nil, nil, 'DeskMapDim' } } }
      local notes = {}
      if e.stale then notes[#notes + 1] = 'the reader no longer reads this as a handoff: the drop does nothing now' end
      if not e.own then notes[#notes + 1] = 'declared in ' .. vim.fn.fnamemodify(tostring(e.declared_in), ':~') .. ' (yours to edit there)' end
      if #notes > 0 then
        local nparts = { { '         ' } }
        for k, note in ipairs(notes) do nparts[#nparts + 1] = { note .. (k < #notes and ' · ' or ''), nil, true, 'DeskMapDim', hang = k == 1 } end
        rows[#rows + 1] = nparts
      end
      sections[#sections + 1] = { block = rows }
    end
    if #entries == 0 then sections[#sections + 1] = { parts = { { 'No handoff corrections for this checkout: `a` on a trace step adds one, `x` on a handoff drops it.' } }, group = 'DeskMapDim' } end
    return { crumbs = { 'handoffs' }, sections = sections }
  end
  if answer.q == 'touched' then
    -- What a commit changed, on the map: the functions its hunks touch, by file (a file changed since may have moved).
    local by = node_index(answer)
    sections[#sections + 1] = { head = 'what ' .. tostring(answer.commit or ''):sub(1, 8) .. ' changed · ' .. #(answer.nodes or {}) .. ' functions' }
    if (answer.subject or '') ~= '' then sections[#sections + 1] = { parts = { { answer.subject } }, group = 'DeskMapDim' } end
    for _, f in ipairs(answer.files or {}) do
      local rows = { { { f.file, nil, nil, 'DeskMapHead' }, { f.moved and '  (changed since: its lines may have moved)' or '', nil, true, 'DeskMapDim' } } }
      local names = {}
      for _, id in ipairs(f.nodes or {}) do
        local n = by[type(id) == 'table' and id.id or id] or (type(id) == 'table' and id) or nil
        if n then names[#names + 1] = { '    ' }; names[#names + 1] = { n.label, node_item(n) } end
      end
      if #names > 0 then rows[#rows + 1] = names end
      sections[#sections + 1] = { block = rows }
    end
    if #(answer.files or {}) == 0 then sections[#sections + 1] = { parts = { { 'No function in the map is in its change.' } }, group = 'DeskMapDim' } end
    return { crumbs = { 'change' }, sections = sections }
  end
  if answer.q == 'calls-into' then
    -- Where a function's result goes, call by call (read from each call's line: a first answer, said as such).
    local to = answer.to or {}
    local short = tostring(to.label or ''):match('([%w_~]+)$') or tostring(to.label)
    local root = level and level.root
    local cache = {}
    local function line_of(file, n)
      if not (root and file) then return nil end
      cache[file] = cache[file] or (pcall(vim.fn.readfile, root .. '/' .. file) and vim.fn.readfile(root .. '/' .. file) or {})
      return cache[file][n]
    end
    local rows, counts = {}, {}
    for _, c in ipairs(answer.callers or {}) do
      local n = c.node or {}
      for _, site in ipairs(c.sites or {}) do
        local text = line_of(n.file, site.line)
        local use = text and M.result_use(text, short) or 'not read (no source here)'
        counts[use] = (counts[use] or 0) + 1
        rows[#rows + 1] = { { use .. '  ', nil, true, use:find('^discarded$') and 'DeskMapStale' or 'DeskMapDim' },
          { n.label, node_item({ id = n.id, label = n.label, file = n.file, line = site.line }) },
          { '  ' .. (n.file and vim.fs.basename(n.file) or '?') .. ':' .. site.line .. (text and ('  ' .. vim.trim(text)) or ''), nil, nil, 'DeskMapDim' } }
      end
    end
    local summary = {}
    for use, k in pairs(counts) do summary[#summary + 1] = k .. ' ' .. use end
    table.sort(summary)
    sections[#sections + 1] = { head = 'where ' .. code(to.label) .. "'s result goes · " .. #rows .. (#rows == 1 and ' call' or ' calls') }
    sections[#sections + 1] = { block = { { { (#summary > 0 and table.concat(summary, ' · ') or 'no call of it in the map') .. ' (read from each call\'s line)', nil, true } } }, group = 'DeskMapDim' }
    if #rows > 0 then sections[#sections + 1] = { block = rows } end
    return { crumbs = { 'result' }, sections = sections }
  end
  if answer.q == 'crossings' then
    local n_entries = #(answer.entries or {})
    sections[#sections + 1] = { head = 'how ' .. tostring(answer.from) .. ' uses ' .. tostring(answer.to) .. ' · ' .. n_entries
      .. (n_entries == 1 and ' entry function, ' or ' entry functions, ') .. tostring(answer.calls or 0) .. ' calls in' }
    if #(answer.entries or {}) == 0 then sections[#sections + 1] = { parts = { { 'No call crosses from ' .. tostring(answer.from) .. ' into ' .. tostring(answer.to) .. '.' } }, group = 'DeskMapDim' } end
    for _, e in ipairs(answer.entries or {}) do
      local n = e.node or {}
      local rows = { { { n.label, node_item(n) }, { '  ' .. where(n) .. ' · ' .. tostring(e.count) .. (e.count == 1 and ' caller' or ' callers'), nil, nil, 'DeskMapDim' } } }
      local callers = { { '    from ', nil, true, 'DeskMapDim' } }
      for i, c in ipairs(e.callers or {}) do callers[#callers + 1] = { c.label .. (i < #e.callers and ' · ' or ''), node_item(c), nil, nil } end
      rows[#rows + 1] = callers
      sections[#sections + 1] = { block = rows }
    end
    if (answer.more or 0) > 0 then sections[#sections + 1] = { parts = { { '… and ' .. answer.more .. ' more entry functions', nil, true } }, group = 'DeskMapDim' } end
    return { crumbs = { 'interface' }, sections = sections }
  end
  if answer.q == 'paths' then
    local by = node_index(answer)
    local from, to = answer.from or {}, answer.to or {}
    local avoid = type(answer.avoided) == 'table' and answer.avoided or nil
    sections[#sections + 1] = { head = 'ways from ' .. code(from.label) .. ' to ' .. code(to.label) .. (avoid and (' avoiding ' .. code(avoid.label)) or '') .. ' · ' .. #(answer.paths or {}) }
    if avoid and #(answer.paths or {}) > 0 then
      sections[#sections + 1] = { parts = { { #answer.paths .. (#answer.paths == 1 and ' way reaches ' or ' ways reach ') .. (to.label or '?') .. ' without going through ' .. (avoid.label or '?') .. ': each is a bypass to look at' } }, group = 'DeskMapFocus' }
    elseif avoid then
      -- A "no" is only as strong as what was searched: said with it (Codex's C3).
      local sr = type(answer.searched) == 'table' and answer.searched or {}
      local built = tonumber(sr.built_at) and os.date('%Y-%m-%d %H:%M', tonumber(sr.built_at)) or '?'
      sections[#sections + 1] = { parts = { { 'No way from ' .. (from.label or '?') .. ' to ' .. (to.label or '?') .. ' avoids ' .. (avoid.label or '?') .. ' in the map.' } }, group = 'DeskMapFocus' }
      local said = { 'Searched: the map built ' .. built .. ' · ', 'calls, calls matched by name and handoffs · ', 'up to ' .. tostring(sr.depth or answer.depth or '?') .. ' calls deep',
        sr.complete == false and ' · the map is partial: ' or '', sr.complete == false and 'a way may be among what it could not read' or '',
        '. Function pointers, virtual calls ', 'and macros the map did not read are not in it.' }
      local sparts = {}
      for i, t in ipairs(said) do if t ~= '' then sparts[#sparts + 1] = { t, nil, true, nil, hang = i == 1 } end end
      sections[#sections + 1] = { block = { sparts }, group = 'DeskMapDim' }
    end
    if #(answer.paths or {}) == 0 and not avoid then
      sections[#sections + 1] = { parts = { { (from.label or '?') .. ' does not reach ' .. (to.label or '?') .. ' in the map within ' .. (answer.depth or '?') .. ' calls' } }, group = 'DeskMapDim' }
      -- Why, and where to look next: the two sides, each a function to open (a queue's publish on one side and its
      -- consumer on the other is a handoff the map missed: `a` on a trace step adds it).
      local why = ({ depth = 'The search stopped at ' .. tostring(answer.depth) .. ' calls; more may join them (a count before P asks deeper).',
        partial = 'The map is partial (some calls could not be read); the way may be among them.',
        ran_out = 'Both sides ran out of known calls: if one ends at a queue or a callback the other takes, that is a handoff the map missed.' })[answer.why]
      if why then sections[#sections + 1] = { block = { { { why, nil, true } } }, group = 'DeskMapDim' } end
      local function side(title, list)
        if #(list or {}) == 0 then return end
        sections[#sections + 1] = { head = title }
        local rows = {}
        for _, n in ipairs(list) do rows[#rows + 1] = { { n.label, node_item(n) }, { '  ' .. where(n) .. '  ' .. tostring(n.depth or '?') .. (n.depth == 1 and ' call' or ' calls'), nil, nil, 'DeskMapDim' } } end
        sections[#sections + 1] = { block = rows }
      end
      side('where ' .. tostring(from.label or '?') .. "'s calls end", answer.ends)
      side('what calls ' .. tostring(to.label or '?') .. ', nearest first', answer.callers)
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
    local said = not backwards and M.ambiguity(n)
    local cond = M.cond_said(n)
    if cond then detail = detail .. ' · ' .. cond end
    if said then detail = detail .. ' · ' .. said end   -- what it reaches may be among the names it calls ambiguously
    return node_item(n, { detail = detail, warn = cycle[n.id] or nil })
  end
  local start = answer.from or (tiers[0] and tiers[0][1]) or {}
  local order = {}
  for d = 1, deepest do order[#order + 1] = d end
  if backwards then order = vim.fn.reverse(order) end
  local function tier(d)
    sections[#sections + 1] = { boxes = vim.tbl_map(item, tiers[d] or {}), level = backwards and -d or d }
  end
  local label = (backwards and 'who calls ' or 'what ') .. code(start.label) .. (backwards and '' or ' reaches') .. ' · depth ' .. (answer.depth or '?')
  sections[#sections + 1] = { head = label }
  if not backwards then sections[#sections + 1] = { boxes = { item(start) }, frame = 'double', level = 0 } end
  for _, d in ipairs(order) do
    if not backwards or d ~= order[1] then sections[#sections + 1] = { arrow = true } end
    tier(d)
  end
  if backwards then
    if #order > 0 then sections[#sections + 1] = { arrow = true } end
    sections[#sections + 1] = { boxes = { item(start) }, frame = 'double', level = 0 }
  end
  if #order == 0 then sections[#sections + 1] = { head = backwards and 'nothing in the map calls it' or 'it calls nothing in the map' } end
  if (answer.more or 0) > 0 then sections[#sections + 1] = { head = answer.more .. ' more calls were left out' } end
  return { crumbs = { backwards and 'callers' or 'reach' }, sections = sections, layered = true }
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

-- A map is in a tab here (view.buf, view.win), or in the pop-out (view.out: desk.popout's view of kind 'map', which
-- this module fills and draws for it). Its state is the same either way: root, stack, cache, previous, status,
-- missing, message, building, building_at and asked (the newest request's number: an older answer is dropped).
local function pop() return require('desk.popout') end
local function valid(view)
  if not view then return false end
  if view.out then return pop().holds(view) end
  return api.nvim_buf_is_valid(view.buf) and api.nvim_win_is_valid(view.win) and views[view.buf] == view
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
end

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
-- desk-work's words about a reader with the command in them as code ("requires a built binary: desk-work map build
-- --binary PATH"), so the theme's voice shouts the words and leaves the command as it is typed.
local function command_as_code(text)
  text = tostring(text or '')
  local at = text:find('desk-work ', 1, true)
  if not at then return text end
  local stop = text:find(' (', at, true) or (#text + 1)
  return text:sub(1, at - 1) .. code(text:sub(at, stop - 1)) .. text:sub(stop)
end

-- The checkout's folder is a name, not the theme's words: it keeps its case in retro too.
function M.header(view, G)
  local s = view.status
  local out = { { G.said('project map · ' .. code(vim.fn.fnamemodify(view.root, ':t'))), 'DeskMapTitle' } }
  if view.missing then out[#out + 1] = { G.said('requires desk-work'), 'DeskMapStale' }
  elseif view.building or (s and s.building) then
    out[#out + 1] = { G.said('rebuilding' .. G.ellipsis .. ' started ' .. os.date('%H:%M', s and s.building_since or view.building_at or os.time())), 'DeskMapDim' }
  elseif not s then out[#out + 1] = { G.said('reading' .. G.ellipsis), 'DeskMapDim' }
  elseif unbuildable(s) then out[#out + 1] = { G.said(command_as_code(unbuildable(s)[1].short)), 'DeskMapStale' }
  elseif not s.built then out[#out + 1] = { no_map(G), 'DeskMapStale' }
  elseif s.stale then
    out[#out + 1] = { with_key(G, 'stale since ' .. code(short(s.head)) .. ' · ', 'rebuild', ' rebuilds'), 'DeskMapStale' }
    if (s.stale_why or '') ~= '' then out[#out + 1] = { s.stale_why, 'DeskMapDim' } end
  else out[#out + 1] = { G.said('built ' .. os.date('%H:%M', s.built_at or 0) .. ' at ' .. code(short(s.head))), 'DeskMapDim' } end
  -- what the last rebuild changed (Codex's #42): its counts, and the key that lists them
  local said = s and M.changes_said(s.changes)
  if said and not view.missing and not (view.building or (s and s.building)) then
    out[#out + 1] = { G.said('since the last build: ' .. said .. ' · ') .. typed('changes') .. G.said(' what changed'), 'DeskMapDim' }
  end
  return out
end
--- pure: a rebuild's changes as counts ("+1 call · −2 calls · +1 function"), nil for the first build or none.
function M.changes_said(c)
  if type(c) ~= 'table' or c.first then return nil end
  local parts = {}
  local function n(count, one, many, sign)
    count = tonumber(count) or 0
    if count > 0 then parts[#parts + 1] = sign .. count .. ' ' .. (count == 1 and one or many) end
  end
  n(c.edges_added, 'call', 'calls', '+'); n(c.edges_removed, 'call', 'calls', '−')
  n(c.nodes_added, 'function', 'functions', '+'); n(c.nodes_removed, 'function', 'functions', '−')
  n(c.found_source, 'found its source', 'found their source', ''); n(c.lost_source, 'lost its source', 'lost their source', '')
  if #parts == 0 then return 'no change' end
  return table.concat(parts, ' · ')
end

-- The key line at the foot of the page: the keys that matter here (? lists every one), as typed, in the theme's voice.
local KEY_LINE = { { 'in', 'in' }, { 'back', 'out' }, { 'reach', 'reach' }, { 'callers', 'callers' }, { 'paths', 'paths' },
  { 'desk.keys', 'keys' }, { 'close', 'close' } }

-- keys = false: without the key line (the pop-out's window has its own, its status line).
function M.footer(view, G, keys)
  G = G or M.glyphs(M.retro())
  local s = view.status or {}
  -- One plain line for the usual case (Codex's #4: in a split the explanation took nearly as much room as the
  -- answer); i opens the whole of it. A partial map stays said in full: it can change the answer.
  if not view.evidence_open then
    local parts = {}
    for _, p in ipairs(s.providers or {}) do
      if p.state == 'ok' then parts[#parts + 1] = p.name == 'syntax' and 'calls matched by name' or ('exact calls from ' .. vim.fn.fnamemodify(p.binary or '', ':t'))
      elseif not unbuildable(view.status) then parts[#parts + 1] = p.name .. ' not built' end
    end
    local notes = {}
    -- the words in the theme's voice, the key as typed ({ text }: the layout keeps its case)
    if #parts > 0 then notes[1] = { G.said(table.concat(parts, ' · ') .. ' · ') .. typed('why') .. G.said(' why') } end
    if s.complete == false and s.why then notes[#notes + 1] = 'partial: ' .. s.why end
    if keys == false then return notes end
    local line = {}
    for _, k in ipairs(KEY_LINE) do line[#line + 1] = typed(k[1]) .. ' ' .. G.said(k[2]) end
    notes[#notes + 1] = { table.concat(line, ' · ') }
    return notes
  end
  local notes, answered = {}, {}
  for _, p in ipairs(s.providers or {}) do
    if p.state == 'ok' then
      answered[#answered + 1] = p.name == 'syntax' and 'syntax (calls by name: overloads, macros and virtual dispatch are not resolved)'
        or ('binary (exact calls in ' .. vim.fn.fnamemodify(p.binary or '', ':t') .. ' after inlining)')
    end
  end
  if #answered > 0 then notes[#notes + 1] = 'answered by ' .. table.concat(answered, ' · ') end
  for _, p in ipairs(unbuildable(view.status) and {} or s.providers or {}) do   -- (else the page itself says them)
    if p.state ~= 'ok' then notes[#notes + 1] = p.name .. ': ' .. ((p.why or '') ~= '' and command_as_code(p.why) or 'not built yet') end
  end
  if s.complete == false and s.why then notes[#notes + 1] = 'partial: ' .. s.why end
  if keys == false then return notes end
  local line = {}
  for _, k in ipairs(KEY_LINE) do line[#line + 1] = typed(k[1]) .. ' ' .. G.said(k[2]) end
  notes[#notes + 1] = { table.concat(line, ' · ') }
  return notes
end

-- What was read for a level; while a rebuilt map is read again, what was read before it.
local function cached(view, key) return view.cache[key] or (view.previous or {})[key] end

local function page_of(view)
  local level = view.stack[#view.stack]
  if level.kind == 'modules' then return cached(view, 'modules') and M.level_modules(cached(view, 'modules')) end
  if level.kind == 'query' then
    local page = M.level_query(level.answer, level)
    -- a note the asker gave (the review of an older commit: the callers are the map's as it is now)
    if page and level.note then table.insert(page.sections, math.min(2, #page.sections + 1), { block = { { { level.note, nil, true } } }, group = 'DeskMapStale' }) end
    return page
  end
  if level.kind == 'pick' then return M.level_pick(level) end
  if level.kind == 'findings' then return M.level_findings(level) end
  if level.kind == 'stack' then return M.level_stack(level) end
  if level.kind == 'sanitizer' then return M.level_sanitizer(level) end
  if level.kind == 'regression' then return M.level_regression(level) end
  if level.kind == 'binary' then return M.level_binary(level) end
  local answer = cached(view, 'module:' .. level.module)
  if not answer then return nil end
  if level.kind == 'files' then return M.level_files(answer, level.module) end
  if level.kind == 'functions' then return M.level_nodes(answer, level.module, level.file) end
  if level.kind == 'class' then
    return M.level_nodes(answer, level.module, level.file, { id = level.id, name = level.name, node = level.node })
  end
end

-- The page a map shows now, its header and crumbs on top (notes are the caller's): its level, or what it waits for,
-- or what it needs.
local function page_for(view, G)
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
  local top = view.stack[#view.stack]
  if page.crumbs and top.kind ~= 'query' then
    page.zoom = ({ modules = 1, files = 2, functions = 3, class = 4 })[top.kind]
  end
  if view.coverage and page.sections then
    M.with_coverage(page, view.coverage.files)
    table.insert(page.header, { G.said('coverage of ') .. tostring(view.coverage.name) .. G.said(' · ]u what it did not reach · gc off'), 'DeskMapDim' })
  end
  if page.crumbs then table.insert(page.header, { table.concat(page.crumbs, G.crumb), 'DeskMapDim' }) end
  table.insert(page.header, { '' })
  return page
end

-- The map in its tab, drawn for its window.
function M.render(view)
  if not valid(view) or view.out then return end
  local retro = M.retro()
  local G = M.glyphs(retro)
  local page = page_for(view, G)
  page.notes = M.footer(view, G)
  view.drawn = M.layout(page, api.nvim_win_get_width(view.win) - 2, retro)
  draw(view.buf, view.drawn)
  local s = view.sel or {}
  s.buf, s.win, s.drawn, s.index = view.buf, view.win, view.drawn, nil
  view.sel = s
  M.mark_selected(view)
end

-- The box under the cursor drawn selected, as the call graph and the pop-out draw theirs (callgraph.select: one
-- colour and one painter for every box view); off a box, the last one stays.
function M.mark_selected(view)
  local s = view and view.sel
  if not (s and api.nvim_win_is_valid(s.win) and api.nvim_win_get_buf(s.win) == s.buf) then return end
  local cursor = api.nvim_win_get_cursor(s.win)
  local under = M.item_at(view.drawn, cursor[1], cursor[2])
  for i, b in ipairs(s.drawn.boxes) do
    if under and b.item == under then
      return require('desk.callgraph').select(s, i, false)
    end
  end
end

-- Drawn again where it is: its tab, or sent to the pop-out (which draws it with the view kind below).
local function redraw(view)
  if view.out then return pop().redraw(view) end
  M.render(view)
end

local function status(view, after)
  M.desk_work({ 'map', 'status', '--root', view.root }, function(answer, out)
    if not valid(view) then return end
    -- The first read failing is the page's news (desk-work missing, a broken record); a later one keeps the page.
    if answer and answer.ok ~= false then view.status, view.missing = answer, nil
    elseif out and out.missing then view.missing = true
    elseif not view.status then view.message = refusal(answer, out) end
    if after then after(view.status) end
    redraw(view)
  end, 30000)
end

-- What a box stands for (a function's id, a class, a file, a part): the same box in another drawing of the page.
local function box_of(item)
  local t = item.target or {}
  local what = t.kind == 'node' and t.node and t.node.id or t.kind == 'class' and t.id or t.file or t.module or item.name or ''
  return (t.kind or 'box') .. ':' .. tostring(what)
end

-- The cursor where it was on this level (each is put back once), on the box it was on when the level was read again
-- (level.keep), else on the first box (its name line), so Enter works at once. In the pop-out its selection does that:
-- the box the level was left by, else the pop-out's own choice (a double box, the first).
local function place_cursor(view)
  local level = view.stack[#view.stack]
  if view.out then return end
  local keep, cursor = level.keep, level.cursor
  level.keep, level.cursor = nil, nil
  if keep then
    for _, box in ipairs(view.drawn and view.drawn.items or {}) do
      if box_of(box.item) == keep.box then return pcall(api.nvim_win_set_cursor, view.win, { box.line, box.name_col or 0 }) end
    end
    cursor = keep.cursor
  end
  if cursor then return pcall(api.nvim_win_set_cursor, view.win, cursor) end
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
  if view.out and view.select == nil then view.select = level.selected end
  if not key or view.cache[key] or not (view.status and view.status.built) then redraw(view); return place_cursor(view) end
  view.asked = (view.asked or 0) + 1
  local asked = view.asked
  local args = { 'map', 'query', '--root', view.root, '--q', 'module', '--cap', '2000' }
  if level.module then vim.list_extend(args, { '--name', level.module }) end
  redraw(view)
  M.desk_work(args, function(answer, out)
    if asked ~= view.asked or not valid(view) then return end
    if out and out.missing then view.missing = true
    elseif not answer or answer.ok == false then view.message, view.news = refusal(answer, out), true else view.cache[key] = answer end
    redraw(view)
    place_cursor(view)
  end)
end

-- With no build to watch, a work event is no news for the map (view.tick is what answers one).
local function stop_polling(view)
  if view.timer then view.timer:stop(); view.timer:close(); view.timer = nil end
  view.tick = nil
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
        -- The level is read again; the cursor stays on the box it is on (here, not in the pop-out: its selection does).
        if not view.out and api.nvim_win_is_valid(view.win) then
          local cursor = api.nvim_win_get_cursor(view.win)
          local item = M.item_at(view.drawn, cursor[1], cursor[2])
          view.stack[#view.stack].keep = { box = item and box_of(item), cursor = cursor }
        end
        -- The build ended: news in the pop-out's header until she looks.
        view.building, view.previous, view.cache, view.news = false, view.cache, {}, true
        -- A status read while building skips the stale check: once more, then the level.
        return status(view, function() load(view) end)
      end
      if uv.now() - started > M.BUILD_WAIT_MS then stop_polling(view); view.building = false end
      redraw(view)
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
  redraw(view)
  M.desk_work(args, function(answer, out)
    if not valid(view) then return end
    if not answer or answer.ok == false then
      view.building, view.news = false, true
      tell(refusal(answer, out), vim.log.levels.WARN)
      return redraw(view)
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

-- A map's state as data, for desk.popout: the history keeps it all (step = true: restore puts it back as it was), the
-- layout record its checkout and zoom as target = { root, levels } (a query's answer is not kept).
local function save_view(view)
  local levels = {}
  for _, level in ipairs(view.stack or {}) do
    if level.kind ~= 'query' then
      levels[#levels + 1] = { kind = level.kind, module = level.module, file = level.file, id = level.id, name = level.name, node = level.node }
    end
  end
  local target = { root = view.root, levels = levels }
  -- A trace on top: its question (focus, end, start) and how she left it (open folds, the step selected), asked again of
  -- the map as it is when restored.
  local top = view.stack and view.stack[#view.stack]
  if top and top.kind == 'query' and top.answer and top.answer.q == 'trace' and type(top.answer.focus) == 'string' then
    local folds = {}
    for k, v in pairs(top.folds or {}) do if type(k) == 'string' and type(v) == 'boolean' then folds[k] = v end end
    target.trace = { focus = top.answer.focus, to = top.answer.to, start = top.answer.start, folds = folds,
      selected = type(top.selected) == 'string' and top.selected or nil }
  end
  return { step = true, stack = vim.list_slice(view.stack or {}), pinned = view.pinned == true, target = target }
end

-- A level on top: zoomed in, or a query's answer. from: in the pop-out, the key of the box it was asked from (selected
-- again when she comes back to this level). In the pop-out it is a step back for Ctrl+o and Backspace there.
local function push(view, level, from)
  local before = view.out and save_view(view)
  local top = view.stack[#view.stack]
  if view.out then top.selected = from else top.cursor = api.nvim_win_get_cursor(view.win) end
  view.stack[#view.stack + 1] = level
  load(view)
  if before then pop().stepped(view, before) end
end

-- - in the pop-out: out a level (its Backspace is the pop-out's own: back through what happened there).
local function zoom_out(view)
  if #view.stack <= 1 then return tell('This is the top: the parts of the checkout.') end
  local before = save_view(view)
  table.remove(view.stack)
  load(view)
  pop().stepped(view, before)
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

-- A function's code, in the window the map came from (from the pop-out: ctx.origin, a code window here), else a tab.
local function jump(view, node, origin)
  if not node.file then return tell(node.label .. ' has no source in this checkout (' .. (node.detail or 'binary only') .. ').') end
  local path = view.root .. '/' .. node.file
  -- The window the map came from when that is code; never a view's (from the review it was the review's list).
  local ok, why = require('desk.nav').open_code(path, node.line, nil, origin or (not view.out and view.origin) or nil)
  if not ok then tell('Could not open ' .. node.file .. ': ' .. tostring(why)) end
  return ok
end

--- A rebuild's change where it is (Codex's E9): an added call in its file today; a removed call or function in the
--- source the build before read (t.head), read-only in a split, gf to today's file; a commit not in this checkout said.
function M.open_change(root, t, origin)
  if not (t and t.file) then return tell('This change says no place.') end
  if t.side ~= 'removed' then
    local ok, why = require('desk.nav').open_code(root .. '/' .. t.file, t.line or 1, nil, origin)
    if not ok then tell('Could not open ' .. t.file .. ': ' .. tostring(why)) end
    return
  end
  local got = t.head and vim.system({ 'git', '-C', root, 'show', t.head .. ':' .. t.file }, { text = true }):wait()
  if not (got and got.code == 0) then
    return tell(tostring(t.head or 'The build before'):sub(1, 7) .. ' is not in this checkout: the source that call was read in cannot be shown.', vim.log.levels.WARN)
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(got.stdout:gsub('\n$', ''), '\n', { plain = true }))
  vim.bo[buf].bufhidden, vim.bo[buf].modifiable = 'wipe', false
  pcall(api.nvim_buf_set_name, buf, t.file .. ' · as the build before read it (' .. t.head:sub(1, 7) .. ')')
  local kind = vim.filetype.match({ filename = t.file })
  if kind then vim.bo[buf].filetype = kind end
  vim.cmd('sbuffer ' .. buf)
  local path = root .. '/' .. t.file
  vim.keymap.set('n', 'q', '<cmd>bwipeout<cr>', { buffer = buf, desc = 'Close the earlier version' })
  vim.keymap.set('n', 'gf', function() vim.cmd('edit ' .. vim.fn.fnameescape(path)) end, { buffer = buf, desc = 'Open the file as it is now' })
  pcall(api.nvim_win_set_cursor, 0, { math.max(1, math.min(t.line or 1, api.nvim_buf_line_count(buf))), 0 })
end

-- The box a key is about: in the pop-out the one selected there (ctx.item), here the one under the cursor.
local function about_item(view, ctx) if view.out then return ctx and ctx.item end; return here(view) end

-- A candidate as a picker says it: its qualified name, its signature where the map has one, where it is.
function M.candidate_text(n)
  local types = {}
  for _, prm in ipairs(n.params or {}) do types[#types + 1] = prm.type end
  local sig = n.params and ('(' .. table.concat(types, ', ') .. ')') or ''
  -- a plain choice (what to do: { id, label }) is no function, and has no place
  return tostring(n.label or n.id) .. sig .. (n.returns and (' → ' .. n.returns) or ''), (n.kind or n.file) and where(n) or ''
end
-- One picker for a name that fits several functions (a trace's start, end or focus, a handoff's destination): in the
-- editor the desk menu (searchable), in the pop-out a page of its own, on the screen it was asked from; Enter on one
-- calls chosen(id). The question is said with which end it is about.
local function choose(view, answer, chosen)
  local list = answer.candidates or {}
  if view.out then
    push(view, { kind = 'pick', message = answer.message, candidates = list, chosen = chosen })
    return
  end
  vim.ui.select(list, { prompt = answer.message, format_item = function(n)
    local name, at = M.candidate_text(n)
    return name .. (at ~= '' and ('  ' .. at) or '')
  end }, function(choice) if choice then chosen(choice.id) end end)
end
function M.level_pick(level)
  local sections = { { head = tostring(level.message or 'Pick one') } }
  for i, n in ipairs(level.candidates or {}) do
    local name, at = M.candidate_text(n)
    sections[#sections + 1] = { block = { { { name, { name = name, target = { kind = 'pick', index = i }, key = 'pick:' .. tostring(n.id) } },
      { '  ' .. at, nil, nil, 'DeskMapDim' } } } }
  end
  return { crumbs = { 'pick one' }, sections = sections }
end

local query   -- defined below (a page asked of desk-work); Enter on a trace's ▲ and ▼ asks one
local function enter(view, ctx)
  local item = about_item(view, ctx)
  local t = item and item.target
  if not t then return end
  -- A zoom stays in the view (f in the pop-out keeps the keyboard there); a function goes to the editor.
  if ctx and t.kind ~= 'node' then ctx.stayed = true end
  if t.kind == 'module' then push(view, { kind = 'files', module = t.module }, item.key)
  elseif t.kind == 'file' then push(view, { kind = 'functions', module = t.module, file = t.file }, item.key)
  elseif t.kind == 'class' then push(view, { kind = 'class', module = t.module, file = t.file, id = t.id, name = item.name, node = t.node }, item.key)
  elseif t.kind == 'node' then jump(view, t.node, ctx and ctx.origin)
  elseif t.kind == 'call' or t.kind == 'handoff' then
    -- A call: its line in the caller (one of its sites, asked, when there are several, each with its source line); a
    -- handoff: its producer or its consumer.
    local origin = ctx and ctx.origin
    local places = {}
    if t.kind == 'call' then
      local lines = t.file and vim.fn.readfile(view.root .. '/' .. t.file) or {}
      for i, site in ipairs(t.sites or {}) do
        local source = vim.trim((lines[site.line] or ''):gsub('%s+', ' '))
        places[#places + 1] = { id = tostring(i), label = (source ~= '' and source or (t.caller .. ' → ' .. t.callee)), file = t.file, line = site.line }
      end
    else
      for _, side in ipairs({ { 'producer', 'where it is handed over: ' }, { 'consumer', 'where it is taken: ' } }) do
        local at = t[side[1]]
        if at and at.file then places[#places + 1] = { id = side[1], label = side[2] .. at.label, file = at.file, line = at.line } end
      end
    end
    if #places == 1 and t.kind == 'call' then return jump(view, places[1], origin) end
    if #places == 0 then return tell('No place in the code for this one.') end
    ctx.stayed = true
    local message = t.kind == 'call' and (#places .. ' calls from ' .. t.caller .. ' to ' .. t.callee .. ': which one?') or ('The handoff ' .. tostring(item.name) .. ': which side?')
    choose(view, { message = message, candidates = places }, function(id, picked)
      if picked and view.stack[#view.stack] == picked then table.remove(view.stack); load(view) end
      for _, place in ipairs(places) do if place.id == id then jump(view, place, origin) end end
    end)
  elseif t.kind == 'field' then
    ctx = ctx or {}
    ctx.stayed = true
    M.follow_field(view, t, ctx.origin)
  elseif t.kind == 'commit' then
    -- a commit of a slowdown's range: the functions it changed, on the map
    query(view, { '--q', 'touched', '--commit', t.sha }, item.key)
  elseif t.kind == 'correction' then
    ctx = ctx or {}
    ctx.stayed = true
    M.correction_menu(view, t.entry, ctx.origin)
  elseif t.kind == 'pick' then
    -- A name chosen on the pick page: the question asked again with its id, in the page's place.
    local top = view.stack[#view.stack]
    local n = top.kind == 'pick' and top.candidates[t.index]
    if n and top.chosen then top.chosen(n.id, top) end
  elseif t.kind == 'result' then
    -- Where its result goes: each call of it, with its line read.
    query(view, { '--q', 'calls-into', '--of', t.node.id }, item.key)
  elseif t.kind == 'change' then
    -- A rebuild's change (E9): where it is, in the editor.
    ctx = ctx or {}
    ctx.stayed = nil
    M.open_change(view.root, t, ctx.origin or (not view.out and view.origin) or nil)
  elseif t.kind == 'route' then
    -- One of two routes compared (E6): its trace, a page of its own.
    local top = view.stack[#view.stack]
    local r = top and top.answer and top.answer[t.which]
    if r then push(view, { kind = 'query', answer = r, args = top.answer[t.which .. '_args'], root = view.root }, item.key) end
  elseif t.kind == 'start' then
    -- Another start of this trace (T3): the trace again from there, the end she chose kept.
    local a = view.stack[#view.stack] and view.stack[#view.stack].answer
    if a and a.q == 'trace' then
      local args = { '--q', 'trace', '--from', a.focus, '--start', t.id }
      if a.to then vim.list_extend(args, { '--to', a.to }) end
      query(view, args)
    end
  elseif t.kind == 'crossings' then
    -- The calls from one part into another, by the entry function each reaches: a page of its own.
    query(view, { '--q', 'crossings', '--from', t.from, '--to', t.to }, item.key)
  elseif t.kind == 'walk' then
    -- The map's callers or reach page from that step (3 levels; + and - change it), a page of its own.
    query(view, { '--q', t.q, '--from', t.node.id, '--depth', '3' }, item.key)
  elseif t.kind == 'fold' then
    -- A trace's fold: open or closed, kept with the page, the cursor (the pop-out's selection) staying on its header.
    local top = view.stack[#view.stack]
    top.folds = top.folds or {}
    top.folds[t.fold] = not item.open
    if view.out then top.selected = item.key else top.keep = { box = box_of(item), cursor = api.nvim_win_get_cursor(view.win) } end
    -- Opening a step's layout: symdeps lays its file out (once per file and page; a census takes seconds).
    local id = t.fold:match('^(.*)|layout$')
    if id and not item.open then M.lay_out(view, top, id) end
    load(view)
  end
end

-- symdeps' census of a trace step's file, into the page's layouts (fox-symdeps.recordlayout: clang's record-layout
-- dump of that file, through symdeps' guard). Without symdeps the fold says so.
function M.lay_out(view, top, id)
  local step
  for _, st in ipairs(top.answer and top.answer.steps or {}) do if st.id == id then step = st end end
  if not (step and step.file) then return end
  top.layouts = top.layouts or {}
  -- One answer per file, merged as steps ask: the records found, the types asked, those still on the way. A second step
  -- in the file asks only for its own new types, and one already on the way is waited for, not asked twice.
  local entry = top.layouts[step.file] or { records = {}, asked = {}, pending_types = {} }
  top.layouts[step.file] = entry
  if entry.all or entry.unavailable then return end
  local missing = {}
  for _, prm in ipairs(step.params or {}) do
    local t = base_type(prm.type)
    if t and not entry.asked[t] and not entry.pending_types[t] and not vim.tbl_contains(missing, t) then missing[#missing + 1] = t end
  end
  if #missing == 0 then return end
  local path = view.root .. '/' .. step.file
  local function merge(list)
    local have = {}
    for _, r in ipairs(entry.records) do have[r.name] = true end
    for _, r in ipairs(list or {}) do if not have[r.name] then have[r.name] = true; entry.records[#entry.records + 1] = r end end
  end
  local function settle(got, types)
    for _, t in ipairs(types) do entry.pending_types[t] = nil; entry.asked[t] = true end
    if got and got.error then entry.error = got.error end
    if valid(view) and view.stack[#view.stack] == top then load(view) end
  end
  -- symdeps' layoutof (a file's structs laid out once, cached; only those asked), else its census (every record, a
  -- compile each time) from an older symdeps.
  local has_of, layoutof = pcall(require, 'fox-symdeps.layoutof')
  local has_census, census = pcall(require, 'fox-symdeps.recordlayout')
  if not actions.symdeps() or not ((has_of and type(layoutof) == 'table' and type(layoutof.of) == 'function')
      or (has_census and type(census) == 'table' and type(census.census) == 'function')) then
    entry.error, entry.unavailable = 'requires symdeps (an optional plugin for C and C++ layouts)', true
    return
  end
  for _, t in ipairs(missing) do entry.pending_types[t] = true end
  local fine
  if has_of and type(layoutof) == 'table' and type(layoutof.of) == 'function' then
    fine = pcall(layoutof.of, path, missing, function(got)
      local list = {}
      for _, rec in pairs(got and got.records or {}) do vim.list_extend(list, rec.variants or { rec }) end
      merge(list)
      settle(got, missing)
    end)
  else
    -- an older symdeps' census: offsets and type names only, no member sizes and no bit-fields, so never complete
    -- (its gaps are not drawn as padding); a base's or the vtable pointer's line has no plain name and is left out.
    -- It answers every record of the file at once.
    local buf = vim.fn.bufadd(path)
    pcall(vim.fn.bufload, buf)
    fine = pcall(census.census, buf, function(got)
      local list = {}
      for _, rec in ipairs(got and got.records or {}) do
        local members = {}
        for _, f in ipairs(rec.fields or {}) do
          if f.name:match('^[%a_][%w_]*$') then members[#members + 1] = { kind = 'field', name = f.name, type = f.type, off = f.off } end
        end
        list[#list + 1] = { name = rec.name, size = rec.size, align = rec.align, members = members, complete = false,
          why = 'an older symdeps gives no member sizes' }
      end
      merge(list)
      if got and got.records then entry.all = true end
      settle(got, missing)
    end)
  end
  if not fine then settle({ error = 'symdeps could not lay it out' }, missing) end
end

local function ask(prompt, default, done)
  vim.ui.input({ prompt = prompt, default = default or '' }, function(text)
    if text and vim.trim(text) ~= '' then done(vim.trim(text)) end
  end)
end

-- A query: its answer goes on the stack as a page of its own (Backspace goes back). A name that fits several things
-- asks which one, then asks desk-work again with its id (in the pop-out the reason is said instead: what she names
-- there is asked once). from: the box it was asked from, in the pop-out. again: r on that answer's page: the new
-- answer replaces it.
query = function(view, args, from, again, quiet)
  local full = { 'map', 'query', '--root', view.root }
  vim.list_extend(full, args)
  -- z: functions left out of the questions on this map (a logger, an allocator), until Z brings them back
  if view.excluded and #view.excluded > 0 then
    vim.list_extend(full, { '--exclude', table.concat(vim.tbl_map(function(x) return x.id end, view.excluded), '\n') })
  end
  view.asked = (view.asked or 0) + 1
  local asked = view.asked
  M.desk_work(full, function(answer, out)
    if asked ~= view.asked or not valid(view) then return end
    -- a page asked by following the cursor says nothing when there is no answer (the cursor in no function)
    if quiet and (not answer or answer.ok == false) then return end
    view.news = true
    if answer and answer.ok == false and type(answer.candidates) == 'table' and #answer.candidates > 0 then
      -- the name she gave fits several: which end it was (desk-work says; an older one only in its words)
      local msg = answer.message or ''
      local flag = answer.flag or (msg:find('^To: ') and '--to') or (msg:find('^Start: ') and '--start') or '--from'
      return choose(view, answer, function(id, picked)
        local args2 = vim.list_slice(args)
        for i = 1, #args2 - 1 do if args2[i] == flag then args2[i + 1] = id end end
        -- from the pick page: its answer takes the page's place; in the editor, as asked
        if picked then return query(view, args2, nil, picked) end
        query(view, args2, from, again)
      end)
    end
    if not answer or answer.ok == false then return tell(refusal(answer, out), vim.log.levels.WARN) end
    local top = view.stack[#view.stack]
    if again then
      if top ~= again then return end
      view.stack[#view.stack] = { kind = 'query', answer = answer, args = args, keep = top.keep, selected = top.selected, root = view.root }
      return load(view)
    end
    local level = { kind = 'query', answer = answer, args = args, root = view.root, note = view.pending_note }
    view.pending_note = nil
    -- a trace restored after a restart: its folds and selected step as she left them
    if view.restoring and answer.q == 'trace' then
      level.folds, level.selected, view.select = view.restoring.folds, view.restoring.selected, view.restoring.selected
      view.restoring = nil
    end
    push(view, level, from)
  end)
end

local function walk_level(view)
  local top = view and view.stack and view.stack[#view.stack]
  local answer = top and top.answer
  if answer and (answer.q == 'reach' or answer.q == 'callers') and top.args then return top end
end

local function keep_selection(view, ctx, top)
  if view.out then top.selected = ctx.item and ctx.item.key
  else
    local cursor = api.nvim_win_get_cursor(view.win)
    local item = M.item_at(view.drawn, cursor[1], cursor[2])
    top.keep = { box = item and box_of(item), cursor = cursor }
  end
end

local function change_walk(view, ctx, delta)
  local top = walk_level(view)
  if not top then return end
  local depth = (top.answer.depth or 3) + delta
  if depth < 1 then return tell('Already showing the first level.') end
  local args = vim.list_slice(top.args)
  for i = 1, #args - 1 do if args[i] == '--depth' then args[i + 1] = tostring(depth) end end
  keep_selection(view, ctx, top)
  query(view, args, nil, top)
end

local function name_of(node, typed) return node and typed == node.label and node.id or typed end

-- r and c: here, asked with the box under the cursor as the default (a count first is the depth); in the pop-out, of
-- the function selected there, at depth 3.
local function walk(view, q, ctx)
  local item = about_item(view, ctx)
  local node, depth = item and item.target and item.target.node, vim.v.count > 0 and vim.v.count or 3
  if view.out then
    if node then query(view, { '--q', q, '--from', node.id, '--depth', '3' }, item.key) end
    return
  end
  ask(q == 'reach' and 'Reach from: ' or 'Callers of: ', node and node.label, function(name)
    query(view, { '--q', q, '--from', name_of(node, name), '--depth', tostring(depth) })
  end)
end

-- c: the call graph centred on the function, where the map is (its tab here: the graph tab; in the pop-out: the
-- pop-out's graph, pinned on it, Ctrl+o there back to the map), as c centres a call graph (2026-11-16).
local function centre(view, ctx)
  local item = about_item(view, ctx)
  local node = item and item.target and item.target.node
  if not node then return tell('Put the cursor on a function first.') end
  if not node.file then return tell(node.label .. ' has no source in this checkout (' .. (node.detail or 'binary only') .. ').') end
  local G = require('desk.callgraph')
  local target, why = G.target_at(view.root .. '/' .. node.file, node.line, node.label)
  if not target then return tell(why:sub(1, 1):upper() .. why:sub(2) .. '.') end
  -- In the map's own pop-out, with several open: the first was taking it (seen in a VM, 2026-11-17).
  if view.out then return pop().show('graph', { target = target }, { pop = view.pop or 1 }) end
  G.open(target)
end

-- t: the trace through the function (its lane up to where it starts and down to where it ends); e on a trace: down to
-- a function she names instead (the pop-out asks that as the row's question).
local function trace_from(view, ctx)
  local item = about_item(view, ctx)
  local node = item and item.target and item.target.node
  if not node then return tell('Put the cursor on a function first.') end
  query(view, { '--q', 'trace', '--from', node.id }, item.key)
end
local function on_trace(view)
  local top = view and view.stack and view.stack[#view.stack]
  return top and top.answer and top.answer.q == 'trace' and top.answer or nil
end
-- e (to) and S (from): the same trace re-asked with a chosen end or start, the other one kept.
local function trace_end(view, ctx, flag, prompt)
  local answer = on_trace(view)
  if not answer then return tell('Open a trace first (`t` on a function).') end
  local name = ctx and type(ctx.text) == 'string' and vim.trim(ctx.text) ~= '' and vim.trim(ctx.text) or nil
  local function go(chosen)
    local args = { '--q', 'trace', '--from', answer.focus }
    if flag ~= '--to' and answer.to then vim.list_extend(args, { '--to', answer.to }) end
    if flag ~= '--start' and answer.start then vim.list_extend(args, { '--start', answer.start }) end
    vim.list_extend(args, { flag, chosen })
    query(view, args)
    -- A route she chose holds: in the pop-out it is pinned, so following the cursor leaves it (p follows again).
    if view.out and not view.pinned then pop().pin(view) end
  end
  if name then return go(name) end
  if view.out then return end
  ask(prompt, '', go)
end
local function trace_to(view, ctx) trace_end(view, ctx, '--to', 'Trace to: ') end
-- x on a trace's handoff (one the reader got wrong) and a on a step (a handoff it missed): her correction, kept by
-- desk-work outside the checkout (desk.d), then the trace asked again in place. Dropping one she added forgets it.
local function correct_handoff(view, verb, from, to, label, done)
  local top = view.stack[#view.stack]
  local argv = { 'map', 'handoff', verb, '--root', view.root, '--from', from, '--to', to }
  if label then vim.list_extend(argv, { '--label', label }) end
  M.desk_work(argv, function(answer, out)
    if answer and answer.ok == false and type(answer.candidates) == 'table' and #answer.candidates > 0 then
      return choose(view, answer, function(id, picked)
        if picked and view.stack[#view.stack] == picked then table.remove(view.stack); load(view) end
        correct_handoff(view, verb, answer.flag == '--from' and id or from, answer.flag == '--from' and to or id, label, done)
      end)
    end
    if not answer or answer.ok == false then return tell(refusal(answer, out), vim.log.levels.WARN) end
    if done then return done(answer) end
    tell('Handoff ' .. tostring(answer.did) .. ' (kept in ' .. vim.fn.fnamemodify(tostring(answer.file), ':~') .. ').')
    if valid(view) and view.stack[#view.stack] == top and top.args then query(view, top.args, nil, top) end
  end)
end
-- Enter on a correction of the review page: forget it, rebind an end that moved or became several, open an end, or
-- (declared elsewhere) open the file it is in.
function M.correction_menu(view, e, origin)
  local choices, by = {}, {}
  local function add(id, label, run) choices[#choices + 1] = { id = id, label = label }; by[id] = run end
  local function again()
    local top = view.stack[#view.stack]
    if valid(view) and top and top.args then query(view, top.args, nil, top) end
  end
  local function short(id) return tostring(id):match('::(.+)$') or tostring(id) end
  local verb = e.side == 'add' and 'add' or 'drop'
  local function rebind(side, n)
    local from, to = side == 'from' and n.id or e.from.id, side == 'to' and n.id or e.to.id
    correct_handoff(view, 'forget', e.from.id, e.to.id, nil, function()
      correct_handoff(view, verb, from, to, e.label, function(answer)
        tell('Rebound: ' .. short(from) .. ' → ' .. short(to) .. ' (' .. tostring(answer.did) .. ').')
        again()
      end)
    end)
  end
  if e.own then
    add('forget', 'forget this correction', function()
      correct_handoff(view, 'forget', e.from.id, e.to.id, nil, function() tell('Forgotten.'); again() end)
    end)
  else
    add('edit', 'open ' .. vim.fn.fnamemodify(tostring(e.declared_in), ':~') .. ' (declared there: yours to edit)', function()
      require('desk.nav').open_code(tostring(e.declared_in), 1, nil, origin or (not view.out and view.origin) or nil)
    end)
  end
  for _, side in ipairs({ 'from', 'to' }) do
    local end_ = e[side] or {}
    if e.own and end_.state == 'moved' and end_.now then
      add('rebind-' .. side, 'rebind its ' .. side .. ' to ' .. tostring(end_.now.label) .. ' · ' .. where(end_.now), function() rebind(side, end_.now) end)
    elseif e.own and end_.state == 'ambiguous' then
      for k, c in ipairs(end_.candidates or {}) do
        add('rebind-' .. side .. '-' .. k, 'rebind its ' .. side .. ' to ' .. tostring(c.label) .. ' · ' .. where(c), function() rebind(side, c) end)
      end
    elseif end_.state == 'ok' then
      add('open-' .. side, 'open ' .. short(end_.id) .. (end_.node and (' · ' .. where(end_.node)) or ''), function()
        jump(view, end_.node or { id = end_.id, label = short(end_.id) }, origin)
      end)
    end
  end
  choose(view, { message = short(e.from.id) .. ' → ' .. short(e.to.id) .. ': what to do?', candidates = choices }, function(id, picked)
    if picked and view.stack[#view.stack] == picked then table.remove(view.stack); load(view) end
    if by[id] then by[id]() end
  end)
  return choices
end
local function drop_handoff(view, ctx)
  local item = about_item(view, ctx)
  local t = item and item.target
  if not (t and t.kind == 'handoff') then return tell('Put the cursor on a handoff (its ══ handoff ══ break) first.') end
  local function go(yes) if yes:lower():sub(1, 1) == 'y' then correct_handoff(view, 'drop', t.from, t.to) end end
  local said = ctx and type(ctx.text) == 'string' and vim.trim(ctx.text) ~= '' and vim.trim(ctx.text) or nil
  if said then return go(said) end
  if view.out then return end
  ask(t.by_hand and 'Forget the handoff you added? y/n: ' or 'Drop this handoff (it is wrong)? y/n: ', '', go)
end
local function add_handoff(view, ctx)
  local item = about_item(view, ctx)
  local node = item and item.target and item.target.kind == 'node' and item.target.node
  if not node then return tell('Put the cursor on a step of the trace first.') end
  local function go(name) correct_handoff(view, 'add', node.id, name) end
  local said = ctx and type(ctx.text) == 'string' and vim.trim(ctx.text) ~= '' and vim.trim(ctx.text) or nil
  if said then return go(said) end
  if view.out then return end
  ask('Hands off to: ', '', go)
end
local function trace_start(view, ctx) trace_end(view, ctx, '--start', 'Trace from: ') end
-- T: the whole trace (every way between a trace's two ends). On a trace: asked as that trace was (its function, the
-- end and start she chose); elsewhere: through the selected function.
local function whole_trace(view, ctx)
  local answer = on_trace(view)
  if answer then
    local args = { '--q', 'flow', '--from', answer.focus }
    if answer.to then vim.list_extend(args, { '--to', answer.to }) end
    if answer.start then vim.list_extend(args, { '--start', answer.start }) end
    return query(view, args)
  end
  local item = about_item(view, ctx)
  local node = item and item.target and item.target.node
  if not node then return tell('Put the cursor on a function first.') end
  query(view, { '--q', 'flow', '--from', node.id }, item.key)
end

-- gs: the function in symdeps' card (C and C++), as gs in the call graph: its code, the cursor on its NAME, then the
-- card. On the line's first text (`int norm(…)`) symdeps would read the return type.
local function in_symdeps(view, ctx)
  local item = about_item(view, ctx)
  local node = item and item.target and item.target.node
  if not node then return tell('Put the cursor on a function first.') end
  if not actions.symdeps() then return tell('Requires symdeps (an optional plugin for C and C++ symbols).') end
  local inspect = actions.symdeps_card()
  if not inspect then return tell('This symdeps version does not expose its card.') end
  if not jump(view, node, ctx and ctx.origin) then return end
  local name = tostring(node.label or ''):match('([%w_~]+)$')
  local at = name and api.nvim_get_current_line():find('%f[%w_~]' .. vim.pesc(name) .. '%f[^%w_]')
  if at then pcall(api.nvim_win_set_cursor, 0, { api.nvim_win_get_cursor(0)[1], at - 1 }) end
  inspect()
end

-- P: the ways from one function to another. Its key here asks for both, the box under the cursor the default; asked
-- first for where to (ctx.text: the pop-out asks that there, and so do the menus), it goes from the selected box, or
-- the one under the cursor (asking only when there is none).
local function ways(view, ctx)
  local item = about_item(view, ctx)
  local node = item and item.target and item.target.node
  local to = ctx and type(ctx.text) == 'string' and vim.trim(ctx.text) ~= '' and vim.trim(ctx.text) or nil
  if to then
    if node then return query(view, { '--q', 'paths', '--from', node.id, '--to', to }, item.key) end
    if view.out then return end
    return ask('Ways from: ', '', function(from) query(view, { '--q', 'paths', '--from', from, '--to', to }) end)
  end
  ask('Ways from: ', node and node.label, function(from)
    ask('… to: ', '', function(to_name) query(view, { '--q', 'paths', '--from', name_of(node, from), '--to', to_name }) end)
  end)
end

-- gP on a function of a ways page: the same question, every way that does not go through it ("can an order reach
-- submission without validation?"). Asked again by desk-work with --avoid.
local function avoid_this(view, ctx)
  local item = about_item(view, ctx)
  local node = item and item.target and item.target.node
  local top = view.stack[#view.stack]
  local a = top and top.answer
  if not (node and a and a.q == 'paths') then return tell('On a ways page (P), put the cursor on a function of a way first.') end
  if node.id == (a.from or {}).id or node.id == (a.to or {}).id then return tell('That is an end of the question; pick a function between them.') end
  query(view, { '--q', 'paths', '--from', a.from.id, '--to', a.to.id, '--avoid', node.id }, item.key)
end
M._avoid_this = avoid_this

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

-- r: this page read again where it is, as r reads a call graph again: desk-work's status, and the level shown (a
-- query's answer asked again); the cursor stays on its box. R rebuilds the map itself.
local function reread(view)
  local level = view.stack[#view.stack]
  if not view.out and api.nvim_win_is_valid(view.win) then
    local cursor = api.nvim_win_get_cursor(view.win)
    local item = M.item_at(view.drawn, cursor[1], cursor[2])
    level.keep = { box = item and box_of(item), cursor = cursor }
  end
  if level.kind == 'query' then
    return status(view, function() if level.args then query(view, level.args, nil, level) end end)
  end
  local key = level.kind == 'modules' and 'modules' or level.module and ('module:' .. level.module)
  if key then view.cache[key] = nil end
  refresh(view)
end

-- A map's state moved from one place to another (its tab to the pop-out, and back).
local STATE = { 'root', 'stack', 'cache', 'previous', 'status', 'missing', 'message', 'building', 'building_at', 'asked' }
local function adopt(to, from) for _, k in ipairs(STATE) do to[k] = from[k] end end

-- Opens the map of root (default: this checkout) in a tab of its own; one tab per checkout: when it is open already,
-- it comes back as it was, and Backspace at its top goes back to the window this was pressed in. from: a map's state
-- to show there (one coming back from the pop-out). The map of root in the pop-out comes back from there as this tab,
-- as o there brings it back: one map per checkout (2026-11-16: Space cm made a second, fresh one).
-- Space c p: the trace through the function at the cursor, by its file and line (desk-work finds the function whose
-- lines hold it): in the pop-out's map when the pop-out shows this checkout's map, else in the map's tab.
function M.trace_here() return M.trace_at(api.nvim_buf_get_name(0), api.nvim_win_get_cursor(0)[1]) end

-- The map for `root` where an answer for it goes: the pop-out's map when it shows that checkout, else a map here.
local function map_for(root)
  local P = package.loaded['desk.popout']
  local out = P and P.view_of('map')
  local view = (out and out.out and not out.gone and out.root == root) and out or nil
  if view then P.show('map', actions.context(), { pop = view.pop }) else view = M.open(root) end
  return view
end
local function rel_of(path)
  local root = path ~= '' and vim.fs.root(path, '.git')
  if not root then return nil, nil, 'Open a file of a git checkout first.' end
  root = uv.fs_realpath(root) or root
  local real = uv.fs_realpath(path) or path
  local rel = real:sub(1, #root + 1) == root .. '/' and real:sub(#root + 2) or nil
  if not rel then return nil, nil, 'This file is not in the checkout.' end
  return root, rel
end
-- Who calls (or what reaches) the function at line `line` of `path` (the review's U: a changed function's callers).
-- opts.note: said under the page's heading (the review of an older commit: these are the callers as the map has them now).
function M.walk_at(q, path, line, opts)
  local root, rel, why = rel_of(path)
  if not root then return tell(why) end
  local view = map_for(root)
  view.pending_note = opts and opts.note or nil
  query(view, { '--q', q, '--file', rel, '--line', tostring(line), '--from', '', '--depth', '3' })
end
-- The functions a commit changed, on the map (the review's M on a commit).
function M.touched_on_map(root, sha)
  root = uv.fs_realpath(root) or root
  local view = map_for(root)
  query(view, { '--q', 'touched', '--commit', sha })
end

-- The debugger's stack where it stopped (nvim-dap's stopped thread, innermost first): { name, path, line }, or nil, why.
function M.dap_frames()
  local ok, dap = pcall(require, 'dap')
  local session = ok and dap.session and dap.session()
  if not session then return nil, 'not debugging (F5 starts the debugger)' end
  local thread = session.stopped_thread_id and session.threads and session.threads[session.stopped_thread_id]
  if not (thread and thread.frames and #thread.frames > 0) then return nil, 'the program is not stopped' end
  local out = {}
  for _, f in ipairs(thread.frames) do
    out[#out + 1] = { name = tostring(f.name or '?'), path = f.source and f.source.path or nil, line = f.line }
  end
  return out, nil, session.stopped_thread_id
end
-- The stack on the map: each frame, and which of the stopped function's callers in the map are on it (static callers
-- of replay and live alike; the stack says which one brought it here). Pure but for nothing: frames and the callers
-- answer are given. → a page.
function M.level_stack(level)
  local frames, callers = level.frames or {}, level.callers
  local short = function(name) return (tostring(name or ''):gsub('%b()', ''):match('([%w_~]+)%s*$')) or tostring(name) end
  local on = {}
  for _, f in ipairs(frames) do on[short(f.name)] = true end
  local sections = { { head = 'the stack where it stopped' .. (level.thread and (' · thread ' .. level.thread) or '') .. ' · ' .. #frames .. (#frames == 1 and ' frame' or ' frames') } }
  local rows = {}
  for i, f in ipairs(frames) do
    local rel = f.rel or (f.path and vim.fs.basename(f.path)) or 'no source'
    local item = f.rel and node_item({ id = f.rel .. ':' .. tostring(f.line), label = f.name, file = f.rel, line = f.line }) or nil
    rows[#rows + 1] = { { string.format('#%-2d ', i - 1), nil, nil, 'DeskMapDim' }, { f.name, item },
      { '  ' .. rel .. (f.line and (':' .. f.line) or '') .. (i == 1 and '  (stopped here)' or ''), nil, nil, i == 1 and 'DeskMapFocus' or 'DeskMapDim' } }
  end
  sections[#sections + 1] = { block = rows }
  if callers then
    local top = frames[1] and short(frames[1].name) or '?'
    sections[#sections + 1] = { head = 'what calls ' .. top .. ' in the map' }
    local list = {}
    for _, n in ipairs(callers) do
      local here = on[short(n.label)]
      list[#list + 1] = { { n.label, node_item(n) }, { '  ' .. where(n) .. (here and '  on this stack' or '  not on this stack'), nil, nil, here and 'DeskMapFocus' or 'DeskMapDim' } }
    end
    if #list == 0 then list[1] = { { 'the map knows no caller of it', nil, true, 'DeskMapDim' } } end
    sections[#sections + 1] = { block = list }
  end
  return { crumbs = { 'stack' }, sections = sections }
end
--- pure: a sanitizer's report (AddressSanitizer, ThreadSanitizer, LeakSanitizer) as its stacks, each with its title and
--- frames { name, path, line }: the bad access, where the memory was freed, where it was allocated (Codex's #17). And
--- for each stack, the first frame whose function another stack has too (where the stories meet): stack.shared = index.
function M.sanitizer_stacks(text)
  local out, current = { stacks = {} }, nil
  for line in (tostring(text or '') .. '\n'):gmatch('([^\n]*)\n') do
    local kind = line:match('ERROR: (%a+Sanitizer: [%w%-]+)') or line:match('WARNING: (%a+Sanitizer: [%w%- ]+)')
    if kind and not out.kind then out.kind = vim.trim(kind) end
    local title = line:match('^%s*((%u%u+) of size %d+ at %S+ by thread %S+)') or line:match('^%s*((%u%u+) of size %d+ at %S+ thread %S+)')
      or line:match('^%s*(freed by thread %S+) here:') or line:match('^%s*(previously allocated by thread %S+) here:')
      or line:match('^%s*(allocated by thread %S+) here:') or line:match('^%s*(Previous %a+ of size %d+ at %S+ by thread %S+).*:$')
      or line:match('^%s*(%a+ of size %d+ at %S+ by thread %S+).*:$') or line:match('^%s*(Direct leak of %d+ byte%(?s?%)? in %d+ object%(?s?%)?) allocated from:')
    if title then
      current = { title = title:gsub('^previously ', ''):gsub(' at 0x%x+', ''), frames = {} }
      out.stacks[#out.stacks + 1] = current
    else
      local name, where = line:match('^%s*#%d+%s+0x%x+%s+in%s+(.-)%s+(%S+)%s*$')
      -- ThreadSanitizer's: no address, the file then (module+offset)
      if not name then name, where = line:match('^%s*#%d+%s+(.-)%s+(%S+:%d+:?%d*)%s*%(?[^%s]*%)?%s*$') end
      if current and name then
        local path, l = where:match('^(.-):(%d+):%d+$')
        if not path then path, l = where:match('^(.-):(%d+)$') end
        if not path and where:match('^%(') then path = nil end
        current.frames[#current.frames + 1] = { name = name, path = path, line = tonumber(l) }
      elseif line:match('^%s*$') and current and #current.frames > 0 then
        current = nil
      end
    end
  end
  -- where the stacks meet: each stack's first frame whose function another has too, and how (E16): the same file and
  -- line ('line'), the same file on another line ('function'), or only the name ('name': no source, or another file)
  local function short(n) return (tostring(n):gsub('%b()', ''):match('([%w_~:]+)%s*$')) or n end
  local rank = { name = 1, ['function'] = 2, line = 3 }
  for i, st in ipairs(out.stacks) do
    for k, f in ipairs(st.frames) do
      local how
      for j, other in ipairs(out.stacks) do
        if j ~= i then
          for _, g in ipairs(other.frames) do
            if short(g.name) == short(f.name) then
              local this = (f.path and f.path == g.path) and (f.line == g.line and 'line' or 'function') or 'name'
              if not how or rank[this] > rank[how] then how = this end
            end
          end
        end
      end
      if how then st.shared, st.match = k, how; break end
    end
  end
  return out
end
function M.level_sanitizer(level)
  local report = level.report or { stacks = {} }
  local sections = { { head = (report.kind or 'sanitizer report') .. ' · ' .. #report.stacks .. (#report.stacks == 1 and ' stack' or ' stacks') } }
  if level.mapped then sections[#sections + 1] = { parts = { { 'from another machine: read ' .. level.mapped .. ' as this checkout' } }, group = 'DeskMapDim' } end
  if #report.stacks == 0 then
    sections[#sections + 1] = { parts = { { 'No sanitizer stack in this text (an AddressSanitizer or ThreadSanitizer report has lines like "#0 0x… in f file.c:12").' } }, group = 'DeskMapDim' }
  end
  local mark = M.retro() and '♦' or '◆'
  local short = function(n) return (tostring(n):gsub('%b()', ''):match('([%w_~:]+)%s*$')) or n end
  for _, st in ipairs(report.stacks) do
    sections[#sections + 1] = { head = st.title }
    local rows = {}
    for k, f in ipairs(st.frames) do
      local rel = f.rel or (f.path and vim.fs.basename(f.path)) or 'no source'
      local item = f.rel and node_item({ id = f.rel .. ':' .. tostring(f.line), label = f.name, file = f.rel, line = f.line }) or nil
      local here = st.shared == k
      rows[#rows + 1] = { { string.format('#%-2d ', k - 1), nil, nil, 'DeskMapDim' }, { (here and (mark .. ' ') or '') .. short(f.name), item, nil, here and 'DeskMapFocus' or nil },
        { '  ' .. rel .. (f.line and (':' .. f.line) or '') .. (here and ('  where the stacks meet' .. (({ line = ' · the same line', ['function'] = ' · the same function, another line',
          name = ' · only the same name' })[st.match] or '')) or ''), nil, nil, here and 'DeskMapFocus' or 'DeskMapDim' } }
    end
    sections[#sections + 1] = { block = rows }
  end
  return { crumbs = { 'sanitizer' }, sections = sections }
end
-- The report in this buffer (a test's log, a pasted report) or, with none there, the clipboard: its stacks on the map.
--- pure: a report from another machine (Codex's E17): for its absolute paths, the longest tail of one that is exactly
--- one tracked file here gives the prefix that machine had for this checkout → { prefix, example, rel } or nil. A tail
--- two files here share is no guess.
function M.guess_prefix(paths, tracked)
  local count = {}
  for _, t in ipairs(tracked or {}) do
    local parts = vim.split(t, '/', { plain = true })
    for k = 1, #parts do
      local tail = table.concat(parts, '/', k)
      count[tail] = (count[tail] or 0) + 1
    end
  end
  local known = {}
  for _, t in ipairs(tracked or {}) do known[t] = true end
  for _, path in ipairs(paths or {}) do
    if type(path) == 'string' and path:sub(1, 1) == '/' then
      local parts = vim.split(path:sub(2), '/', { plain = true })
      for k = 1, #parts do
        local tail = table.concat(parts, '/', k)
        if known[tail] and count[tail] == 1 then
          return { prefix = path:sub(1, #path - #tail), example = path, rel = tail }
        end
        if (count[tail] or 0) > 1 then break end
      end
    end
  end
end

function M.sanitizer_on_map(text, opts)
  opts = opts or {}
  text = text or table.concat(api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  local report = M.sanitizer_stacks(text)
  if #report.stacks == 0 then
    local clip = vim.fn.getreg('+')
    if clip ~= '' then report = M.sanitizer_stacks(clip) end
  end
  if #report.stacks == 0 then return tell('No sanitizer report in this buffer or the clipboard.') end
  local first
  for _, st in ipairs(report.stacks) do for _, f in ipairs(st.frames) do first = first or (f.path and f.path:sub(1, 1) == '/' and f.path) end end
  local root = opts.root or first and vim.fs.root(first, '.git') or vim.fs.root(0, '.git') or vim.fn.getcwd()
  root = uv.fs_realpath(root) or root
  local outside = {}
  for _, st in ipairs(report.stacks) do
    for _, f in ipairs(st.frames) do
      local real = f.path and (uv.fs_realpath(f.path) or f.path)
      if real and real:sub(1, #root + 1) == root .. '/' then f.rel = real:sub(#root + 2)
      elseif f.path and f.path:sub(1, 1) == '/' then outside[#outside + 1] = f.path end
    end
  end
  local shown
  local function finish(prefix)
    local level = { kind = 'sanitizer', report = report, mapped = prefix }
    if prefix then
      for _, st in ipairs(report.stacks) do
        for _, f in ipairs(st.frames) do
          if not f.rel and f.path and f.path:sub(1, #prefix) == prefix and uv.fs_stat(root .. '/' .. f.path:sub(#prefix + 1)) then f.rel = f.path:sub(#prefix + 1) end
        end
      end
    end
    local view = M.open(root)
    push(view, level)
    shown = view
  end
  -- from another machine: the prefix it had for this checkout, guessed from a file only one path here ends with,
  -- read as this checkout once she says so (once per report)
  local guess
  if #outside > 0 then
    local got = vim.system({ 'git', '-C', root, 'ls-files' }, { text = true, timeout = 10000 }):wait()
    if got.code == 0 then guess = M.guess_prefix(outside, vim.split(vim.trim(got.stdout or ''), '\n', { plain = true })) end
  end
  if not guess then finish(nil); return shown end
  local pick = opts.pick or function(choices, done)
    vim.ui.select(choices, { prompt = 'A report from another machine (' .. guess.example .. ' is ' .. guess.rel .. ' here)', format_item = function(c) return c.label end }, done)
  end
  pick({ { label = 'Read ' .. guess.prefix .. ' as this checkout (' .. vim.fs.basename(root) .. ')', yes = true },
         { label = 'No: leave the frames from there unopened' } }, function(choice)
    finish(choice and choice.yes and guess.prefix or nil)
  end)
  return shown
end
--- A slowdown between two actual runs (desk-work metrics --job --against; Codex's #20): what was measured and how
--- each run was made above the change, then the commits between them (Enter: what each changed, on the map) and the
--- files. The slowdown observed is kept apart from its possible causes.
function M.level_regression(level)
  local a = level.answer or {}
  local job, base = a.job or {}, a.baseline or {}
  local sections = { { head = 'a slowdown between two runs · ' .. tostring((job.title or '') ~= '' and job.title or job.command or '?') } }
  local function run_line(label, r)
    return { { label, nil, true, 'DeskMapDim' }, { tostring(r.command or '?') },
      { '  at ' .. code(short(r.head)) .. (r.clean == false and ' + edits' or '') .. (tonumber(r.ended) and ('  ended ' .. os.date('%m-%d %H:%M', tonumber(r.ended))) or ''), nil, true, 'DeskMapDim' } }
  end
  sections[#sections + 1] = { block = { run_line('slower    ', job), run_line('baseline  ', base),
    { { 'binaries  ', nil, true, 'DeskMapDim' }, { tostring(a.binary or '?'), nil, true, 'DeskMapDim' } } } }
  sections[#sections + 1] = { head = 'what was measured (observed)' }
  local rows = {}
  for _, m in ipairs(a.metrics or {}) do
    local was = m.previous ~= nil and m.previous ~= vim.NIL and tostring(m.previous) or 'not in the baseline'
    rows[#rows + 1] = { { tostring(m.name) .. '  ' }, { tostring(m.value) .. ' ' .. tostring(m.unit or '') .. '  ', nil, nil, m.verdict == 'worse' and 'DeskMapStale' or nil },
      { 'was ' .. was .. ((m.delta or '') ~= '' and ('  ' .. m.delta) or '') .. '  ' .. tostring(m.verdict or ''), nil, true, 'DeskMapDim' } }
  end
  if #rows == 0 then rows[1] = { { 'neither run printed figures desk-work could read', nil, true, 'DeskMapDim' } } end
  sections[#sections + 1] = { block = rows }
  sections[#sections + 1] = { head = 'what changed between them (possible causes) · ' .. #(a.commits or {}) .. ' commits · ' .. #(a.files or {}) .. ' files' }
  if a.same_commit then sections[#sections + 1] = { parts = { { 'Both ran at the same commit: the difference is in the machine, the input or uncommitted edits.' } }, group = 'DeskMapDim' } end
  local crows = {}
  for _, c in ipairs(a.commits or {}) do
    crows[#crows + 1] = { { short(c.sha) .. '  ' .. tostring(c.subject), { name = short(c.sha), key = 'commit:' .. c.sha, target = { kind = 'commit', sha = c.sha } } } }
  end
  if #crows > 0 then sections[#sections + 1] = { block = crows } end
  if #(a.files or {}) > 0 then
    -- files as typed (code), a part each so a long list wraps between them
    local fparts = {}
    for i, f in ipairs(a.files) do fparts[#fparts + 1] = { f .. (i < #a.files and ' · ' or ''), nil, nil, 'DeskMapDim', hang = i == 1 } end
    sections[#sections + 1] = { block = { fparts }, group = 'DeskMapDim' }
  end
  return { crumbs = { 'slowdown' }, sections = sections }
end
function M.regression_on_map(root, job_id, base_id)
  root = uv.fs_realpath(root) or root
  M.desk_work({ 'metrics', '--root', root, '--job', job_id, '--against', base_id }, function(answer, out)
    if not answer or answer.ok == false then return tell(refusal(answer, out), vim.log.levels.WARN) end
    local view = M.open(root)
    push(view, { kind = 'regression', answer = answer })
  end)
end
--- A function as the binary has it (Codex's #15): its linked symbol and the compiler's copies folded into it; with
--- none, why a function seen in the source is no box of its own there. binary: the provider's row from status.
function M.level_binary(level)
  local n, provider = level.node or {}, level.provider or {}
  local b = type(n.binary) == 'table' and n.binary or nil
  local sections = { { head = tostring(n.label) .. ' in the binary' } }
  if b then
    sections[#sections + 1] = { block = { { { 'symbol  ', nil, true, 'DeskMapDim' }, { tostring(b.symbol) } } } }
    if #(b.clones or {}) > 0 then
      sections[#sections + 1] = { head = 'copies the compiler made of it · ' .. #b.clones }
      local rows = {}
      for _, c in ipairs(b.clones) do rows[#rows + 1] = { { tostring(c) } } end
      sections[#sections + 1] = { block = rows }
      sections[#sections + 1] = { parts = { { 'Folded into this one function on the map: a .cold part, an .isra or .constprop copy is the same function, specialised or split.' } }, group = 'DeskMapDim' }
    else
      sections[#sections + 1] = { parts = { { 'No copies: the compiler kept it as one function.' } }, group = 'DeskMapDim' }
    end
  elseif provider.state == 'ok' then
    sections[#sections + 1] = { parts = { { 'No symbol of its own in ' .. vim.fn.fnamemodify(tostring(provider.binary or 'the binary'), ':t')
      .. ': inlined into every caller, or not built into it. The binary reader sees linked symbols, not inlined copies; its callers\' boxes hold its code.' } } }
  else
    sections[#sections + 1] = { parts = { { 'Requires a built binary: B rebuilds the map reading one.' } }, group = 'DeskMapDim' }
  end
  return { crumbs = { 'binary' }, sections = sections }
end
-- Space c s while stopped: the stack on the map, in the pop-out's map when it shows this checkout.
function M.stack_on_map()
  local frames, why, thread = M.dap_frames()
  if not frames then return tell('Show the stack: ' .. why .. '.') end
  local top = frames[1]
  local root = top.path and vim.fs.root(top.path, '.git')
  root = root and (uv.fs_realpath(root) or root) or nil
  if not root then return tell('The stopped frame is not in a git checkout.') end
  for _, f in ipairs(frames) do
    local real = f.path and (uv.fs_realpath(f.path) or f.path)
    if real and real:sub(1, #root + 1) == root .. '/' then f.rel = real:sub(#root + 2) end
  end
  local P = package.loaded['desk.popout']
  local out = P and P.view_of('map')
  local view = (out and out.out and not out.gone and out.root == root) and out or nil
  if view then P.show('map', actions.context(), { pop = view.pop }) else view = M.open(root) end
  local level = { kind = 'stack', frames = frames, thread = thread }
  push(view, level)
  if top.rel and top.line then
    M.desk_work({ 'map', 'query', '--root', root, '--q', 'callers', '--file', top.rel, '--line', tostring(top.line), '--from', '', '--depth', '1' }, function(answer)
      local callers = {}
      for _, n in ipairs(answer and answer.nodes or {}) do if (n.depth or 0) == 1 then callers[#callers + 1] = n end end
      level.callers = callers
      if valid(view) and view.stack[#view.stack] == level then load(view) end
    end)
  end
end
-- The trace through the function holding line `line` of file `path` (the call graph's t gives its box's; its T gives
-- opts.q = 'flow', the whole trace). opts.pop:
-- the pop-out it was asked from — the answer goes to that pop-out's map (opened there when it has none), never another
-- screen's. Asked in the editor (no pop): the pop-out's map when one shows this checkout, else a map here.
function M.trace_at(path, line, opts)
  local root = path ~= '' and vim.fs.root(path, '.git')
  if not root then return tell('Open a file of a git checkout first.') end
  root = uv.fs_realpath(root) or root
  local real = uv.fs_realpath(path) or path
  local rel = real:sub(1, #root + 1) == root .. '/' and real:sub(#root + 2) or nil
  if not rel then return tell('This file is not in the checkout.') end
  local P = package.loaded['desk.popout']
  local pop = opts and opts.pop
  local view
  if P and pop then
    local ctx = actions.context()
    ctx.map_root = root
    P.show('map', ctx, { pop = pop })
    view = P.view_of('map', pop)
    if not (view and view.out and not view.gone) then return tell('The map could not open in that pop-out.') end
  else
    local out = P and P.view_of('map')
    view = (out and out.out and not out.gone and out.root == root) and out or nil
    if view then P.show('map', actions.context(), { pop = view.pop }) else view = M.open(root) end
  end
  query(view, { '--q', (opts and opts.q == 'flow') and 'flow' or 'trace', '--file', rel, '--line', tostring(line), '--from', '' })
end

function M.open(root, from)
  local here_view = views[api.nvim_get_current_buf()]
  root = root or (here_view and here_view.root) or vim.fs.root(0, '.git') or vim.fn.getcwd()
  root = uv.fs_realpath(root) or root
  local P = package.loaded['desk.popout']
  local out = not from and P and P.view_of('map')
  if out and out.out and not out.gone and out.root == root then
    P.back(out)
    for _, open in pairs(views) do if open.root == root and valid(open) then return open end end
  end
  highlights()
  local origin = api.nvim_get_current_win()
  for _, open in pairs(views) do
    local shown = open.root == root and valid(open) and vim.fn.win_findbuf(open.buf)[1]
    if shown then
      open.win = api.nvim_win_get_buf(open.win) == open.buf and open.win or shown
      if origin ~= open.win then open.origin = origin end
      api.nvim_set_current_win(open.win)
      if from then
        stop_polling(open)
        adopt(open, from)
        refresh(open)
      end
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
  local view = { buf = buf, win = win, origin = origin, root = root, stack = { { kind = 'modules' } }, cache = {}, asked = 0 }
  if from then adopt(view, from); view.root = root end
  views[buf] = view
  -- Its keys are the rows on the 'map' surface (the keys section below); each run gets ctx.map, this view. A key here
  -- runs its row at once: the row asks what it needs itself, with the box under the cursor as the default, rather than
  -- the question its row asks in the pop-out and the menus (P's "Ways to").
  actions.map('map', { buffer = buf, nowait = true, ctx = { map = view }, press = function(row, ctx) row.run(ctx) end })
  local group = api.nvim_create_augroup('desk_map_' .. buf, { clear = true })
  api.nvim_create_autocmd('CursorMoved', { group = group, buffer = buf, callback = function() M.mark_selected(view) end })
  api.nvim_create_autocmd('WinScrolled', { group = group, callback = function(a)
    if tonumber(a.match) == view.win then require('desk.callgraph').gauge_edges(view.sel) end
  end })
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
-- keybinds reference all read them. The view is the 'map' surface and a run gets ctx.map, the map it was pressed in:
-- its tab, or the one in the pop-out (the view kind below; ctx.item is the box selected there). Space cm is a global
-- key. The page's key line and its badges take their keys from these rows (typed). In the pop-out Enter, -, r, c, P,
-- m and R run here as remote rows; Backspace, q, M, B and o are the tab's own (there Backspace, q and o are the pop-out's:
-- back through what happened there, close, back to the editor).
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
-- In the pop-out a key is about the box selected there: Enter needs one, a question to the map a function.
local function needs_selection(ctx) return not (ctx.view and not ctx.item) or 'nothing is selected' end
-- What a call's line does with the result of `name` (a first answer, from the line alone: the value is not followed
-- further). Pure.
function M.result_use(line, name)
  local l = vim.trim((line or ''):gsub('//.*$', ''))
  local esc = vim.pesc(name)
  local at = l:find('%f[%w_]' .. esc .. '%s*%(')
  if not at then return 'used' end
  local before = l:sub(1, at - 1)
  if before:find('%(%s*void%s*%)%s*[%w_%.%->:]*$') then return 'discarded on purpose (void)' end
  if before:find('^return%f[^%w_]') or before:find('^co_return%f[^%w_]') then return 'returned upward' end
  if before:find('%f[%w_]if%s*%(') or before:find('%f[%w_]while%s*%(') or before:find('[!&|?]%s*[%w_%.%->:]*$') or before:find('%f[%w_]assert%w*%s*%(') then
    return 'checked'
  end
  if before:find('[^=!<>]=%s*[%w_%.%->:]*$') or before:find('^[%w_:<>%*&%s]+[%w_]+%s*=%s*$') then return 'kept in a variable' end
  if before:find('^[%w_%.%->:]*$') and l:find('%)%s*;%s*$') then return 'discarded' end
  return 'used in an expression'
end

-- Findings inside a route's functions (her pick: "Findings on this path"): pure — the steps' spans (file, first line,
-- lines) against each finding's file and line (relative to root, or absolute under it). → the findings that fall in a
-- step, each with its step.
function M.findings_on(steps, findings, root)
  local out = {}
  for _, f in ipairs(findings or {}) do
    local file = type(f.file) == 'string' and f.file or nil
    if file and root and file:sub(1, #root + 1) == root .. '/' then file = file:sub(#root + 2) end
    local line = tonumber(f.line)
    for _, st in ipairs(steps or {}) do
      if file and line and st.file == file and st.line and line >= st.line and line < st.line + math.max(1, st.lines or 1) then
        out[#out + 1] = vim.tbl_extend('force', f, { file = file, line = line, step = st.label })
        break
      end
    end
  end
  table.sort(out, function(a, b) return a.file .. string.format('%08d', a.line) < b.file .. string.format('%08d', b.line) end)
  return out
end
local function findings_on_path(view)
  local top = view.stack[#view.stack]
  if not (top and top.answer and top.answer.q == 'trace') then return tell('Open a trace first (`t` on a function).') end
  local steps = top.answer.steps or {}
  M.desk_work({ 'tools', 'list', '--root', view.root }, function(listed)
    local tools = vim.tbl_filter(function(t) return t.gives == 'findings' and not t.refused end, listed and listed.tools or {})
    if #tools == 0 then return tell('No tool here gives findings (declare one in .desk/tools.json or desk.d: docs/desk-tools.md).') end
    local found, left = {}, #tools
    for _, tool in ipairs(tools) do
      M.desk_work({ 'tools', 'result', tool.id, '--root', view.root }, function(answer)
        for _, f in ipairs(answer and answer.findings or {}) do
          found[#found + 1] = vim.tbl_extend('force', f, { tool = tool.name or tool.id, at = answer.at })
        end
        left = left - 1
        if left > 0 or not valid(view) then return end
        push(view, { kind = 'findings', on = M.findings_on(steps, found, view.root), of = top.answer.focus, tools = #tools })
      end)
    end
  end)
end
function M.level_findings(level)
  local list = level.on or {}
  local sections = { { head = 'findings on this path · ' .. #list .. ' (from ' .. tostring(level.tools) .. (level.tools == 1 and ' tool)' or ' tools)') } }
  if #list == 0 then sections[#sections + 1] = { parts = { { 'None of their findings falls inside the functions on this route.', nil, true } }, group = 'DeskMapDim' } end
  for _, f in ipairs(list) do
    local item = { name = tostring(f.message or f.kind or 'finding'), key = 'finding:' .. f.file .. ':' .. f.line .. ':' .. tostring(f.id or f.message),
      target = { kind = 'node', node = { id = f.file .. ':' .. f.line, label = tostring(f.step), file = f.file, line = f.line } } }
    sections[#sections + 1] = { block = { { { tostring(f.severity or 'note') .. '  ', nil, true, f.severity == 'error' and 'DeskMapStale' or 'DeskMapDim' },
      { tostring(f.message or f.kind or ''), item }, { '  ' .. f.file .. ':' .. f.line .. ' · in ' .. tostring(f.step) .. ' · ' .. tostring(f.tool), nil, nil, 'DeskMapDim' } } } }
  end
  return { crumbs = { 'findings' }, sections = sections }
end

-- A trace as a short note to hand to another person (y on a trace): the question, the revision the map read, the steps
-- with their file:line, the handoffs it relies on (inferred or hers), the field followed, and her sentence. Pure.
-- at: { map = the map's commit, now = HEAD when copied, dirty = edits in the checkout, stale = why the map was stale }
-- (Codex's E15, 2026-11-19: it named HEAD when copied, not what the map had read), or a revision alone.
function M.investigation_md(answer, at, sentence, field)
  if type(at) ~= 'table' then at = { map = at } end
  local revision = at.map
  local steps, calls = answer.steps or {}, answer.calls or {}
  local focus
  for _, st in ipairs(steps) do if st.id == answer.focus then focus = st end end
  local out = { '## How ' .. tostring(focus and focus.label or '?') .. ' is reached, and where it leads', '' }
  if #steps > 1 then
    out[#out + 1] = ('A possible path from `%s` (%s) to `%s` (%s), %d functions, at %s.'):format(steps[1].label,
      answer.start and 'chosen' or 'the farthest start the map found', steps[#steps].label, answer.to and 'chosen' or 'where the calls end',
      #steps, revision and ('`' .. revision .. '`' .. (at.now and ' (the revision the map read)' or '')) or 'an unknown revision')
    out[#out + 1] = ''
  end
  -- what a reader tomorrow needs to see the same route: what moved since, why the map was stale, what was left out
  local notes = {}
  if at.now and revision and at.now ~= revision then
    notes[#notes + 1] = 'The checkout is now at `' .. at.now .. '`' .. (at.dirty and ', with uncommitted edits' or '') .. ': lines may have moved since.'
  elseif at.dirty then
    notes[#notes + 1] = 'The checkout has uncommitted edits since: lines may have moved.'
  end
  if at.stale then notes[#notes + 1] = 'The map was stale: ' .. tostring(at.stale):gsub('%.$', '') .. '.' end
  if type(answer.excluded) == 'table' and #answer.excluded > 0 then
    notes[#notes + 1] = 'Left out of this answer: ' .. table.concat(vim.tbl_map(function(id)
      return '`' .. (tostring(id):match('::(.+)$') or tostring(id)) .. '`' end, answer.excluded), ' · ') .. ' (`z` on the map).'
  end
  if #notes > 0 then vim.list_extend(out, notes); out[#out + 1] = '' end
  for k, st in ipairs(steps) do
    local at = st.file and (st.file .. (st.line and (':' .. st.line) or '')) or 'no source'
    out[#out + 1] = ('%d. `%s` — %s%s'):format(k, st.label, at, st.id == answer.focus and ' (the function asked about)' or '')
    local c = calls[k]
    if c and c.kind == 'handoff' then
      out[#out + 1] = ('   - hands off through %s (%s)'):format(c.label or 'a handoff', c.by_hand and 'added by hand' or 'inferred from the code')
    elseif c and c.kind == 'none' then
      out[#out + 1] = '   - no call to the next step: the route came back through a cycle'
    end
  end
  if field then out[#out + 1] = ''; out[#out + 1] = ('Followed: `%s.%s` (matched by name on this route).'):format(field.type, field.name) end
  if sentence and vim.trim(sentence) ~= '' then out[#out + 1] = ''; out[#out + 1] = vim.trim(sentence) end
  return table.concat(out, '\n') .. '\n'
end
local function sh_ok(root) return type(root) == 'string' and root ~= '' and vim.fn.executable('git') == 1 end
local function copy_investigation(view, ctx)
  local top = view.stack[#view.stack]
  if not (top and top.answer and top.answer.q == 'trace') then return tell('Open a trace first (`t` on a function).') end
  -- the revision the map read (its build), and what has moved in the checkout since
  local s = view.status or {}
  local at = { map = type(s.head) == 'string' and s.head ~= '' and s.head:sub(1, 7) or nil,
    stale = s.stale and ((s.stale_why or '') ~= '' and s.stale_why or 'built at an older commit') or nil }
  if sh_ok(view.root) then
    local head = vim.system({ 'git', '-C', view.root, 'rev-parse', '--short=7', 'HEAD' }, { text = true }):wait()
    if head.code == 0 then at.now = vim.trim(head.stdout) end
    local dirty = vim.system({ 'git', '--no-optional-locks', '-C', view.root, 'status', '--porcelain', '--untracked-files=no' }, { text = true }):wait()
    at.dirty = dirty.code == 0 and vim.trim(dirty.stdout) ~= '' or nil
  end
  at.map = at.map or at.now
  local function go(sentence)
    local md = M.investigation_md(top.answer, at, sentence, top.field)
    vim.fn.setreg('"', md)
    if vim.fn.has('clipboard') == 1 then pcall(vim.fn.setreg, '+', md) end
    tell('The investigation is copied as Markdown (' .. #vim.split(md, '\n') - 1 .. ' lines).')
  end
  local said = ctx and type(ctx.text) == 'string' and ctx.text or nil
  if said then return go(said) end
  if view.out then return go('') end
  vim.ui.input({ prompt = 'A sentence to add (optional): ' }, function(text) if text ~= nil then go(text) end end)
end

-- A field of a step chosen (Enter on it): her three ways to follow it.
function M.follow_field(view, t, origin)
  local top = view.stack[#view.stack]
  local function at_use()
    -- the field's first use in the step's code (`t.px`, `t->px`), where the language server can be asked about it
    local st = t.step
    if not (st and st.file and st.line) then return nil end
    local path = view.root .. '/' .. st.file
    local lines = vim.fn.readfile(path)
    for l = st.line, math.min(#lines, st.line + math.max(1, st.lines or 200) - 1) do
      local col = lines[l]:find('[%.>]' .. vim.pesc(t.field) .. '%f[^%w_]')
      if col then return { file = st.file, line = l, col = col } end
    end
  end
  local choices = {
    { id = 'route', label = 'highlight it on this route' },
    { id = 'decl', label = 'show its declaration (the language server)' },
    { id = 'writers', label = 'show who writes it (symdeps)' },
  }
  choose(view, { message = t.type .. '.' .. t.field .. ': follow it how?', candidates = choices }, function(id, picked)
    if picked and view.stack[#view.stack] == picked then table.remove(view.stack) end
    if id == 'route' then
      top.field = { type = t.type, name = t.field }
      return load(view)
    end
    load(view)
    local use = at_use()
    if not use then return tell('No use of ' .. t.field .. ' found in ' .. tostring(t.step and t.step.label) .. "'s code.") end
    if not jump(view, { file = use.file, line = use.line, label = t.field }, origin) then return end
    pcall(api.nvim_win_set_cursor, 0, { use.line, use.col })
    local buf = api.nvim_get_current_buf()
    if id == 'decl' then
      if #vim.lsp.get_clients({ bufnr = buf }) == 0 then return tell('Requires a language server attached to ' .. use.file .. '.') end
      return vim.lsp.buf.definition()
    end
    local has, writers = pcall(require, 'fox-symdeps.writers')
    if not (actions.symdeps() and has and type(writers) == 'table' and type(writers.for_symbol) == 'function') then
      return tell('Requires symdeps (an optional plugin for C and C++).')
    end
    writers.for_symbol({ bufnr = buf, line = use.line, col = use.col }, function(got, state)
      vim.schedule(function()
        if not got then return tell(state == 'no_client' and 'symdeps needs the language server attached; try again in a moment.' or ('No writes of ' .. t.field .. ' found.')) end
        local places = {}
        for i, site in ipairs(got.sites or {}) do
          local rel = vim.fs.relpath and vim.fs.relpath(view.root, site.file) or site.file
          places[#places + 1] = { id = tostring(i), label = tostring(site.scope) .. ' writes ' .. t.field, file = rel or site.file, line = site.line }
        end
        if #places == 0 then return tell('Nothing writes ' .. t.field .. ' (' .. (got.reads or 0) .. ' reads).') end
        choose(view, { message = #places .. ' writes of ' .. t.type .. '.' .. t.field .. ':', candidates = places }, function(pid, p2)
          if p2 and view.stack[#view.stack] == p2 then table.remove(view.stack); load(view) end
          for _, place in ipairs(places) do if place.id == pid then jump(view, place, origin) end end
        end)
      end)
    end)
  end)
end

-- z on a function: left out of this map's questions (or back in, pressed again); the page asked again without it.
-- Z: every one back. Kept with the map tab (view.excluded), not across a restart.
function M.exclude(view, node)
  view.excluded = view.excluded or {}
  for i, x in ipairs(view.excluded) do
    if x.id == node.id then
      table.remove(view.excluded, i)
      tell(tostring(node.label) .. ' is back in the answers.')
      return reread(view)
    end
  end
  if #view.excluded >= 32 then return tell('32 left out already: Z brings them back.') end
  view.excluded[#view.excluded + 1] = { id = node.id, label = node.label }
  tell(tostring(node.label) .. ' left out of the answers (' .. #view.excluded .. ') · z again or Z brings it back.')
  reread(view)
end
function M.include_all(view)
  local n = #(view.excluded or {})
  view.excluded = {}
  tell(n == 1 and 'The one left out is back.' or (n .. ' left out are back.'))
  reread(view)
end
local function needs_function(ctx)
  local why = needs_map(ctx)
  if why ~= true or not ctx.view then return why end
  local t = ctx.item and ctx.item.target
  return (t and t.kind == 'node') or 'select a function first'
end
local function needs_trace(ctx)
  local why = needs_map(ctx)
  if why ~= true then return why end
  return on_trace(ctx and ctx.map) and true or 'open a trace first (`t` on a function)'
end
local function needs_handoff(ctx)
  local why = needs_trace(ctx)
  if why ~= true then return why end
  local t = ctx.item and ctx.item.target
  return (not ctx.view or (t and t.kind == 'handoff')) or 'select a handoff (its ══ handoff ══ break) first'
end
local function needs_trace_step(ctx)
  local why = needs_trace(ctx)
  if why ~= true then return why end
  local t = ctx.item and ctx.item.target
  return (not ctx.view or (t and t.kind == 'node')) or 'select a step of the trace first'
end
local function needs_c_function(ctx)
  if not actions.symdeps() then return 'requires symdeps' end
  local why = needs_function(ctx)
  if why ~= true then return why end
  -- The box it is about: selected in the pop-out, under the cursor here.
  local view = ctx and ctx.map
  local item = ctx and (ctx.item or (valid(view) and not view.out and here(view)) or nil)
  local node = item and item.target and item.target.node
  if node and node.file and not ({ c = true, cpp = true })[vim.filetype.match({ filename = node.file }) or ''] then
    return 'requires a C or C++ function'
  end
  return true
end
local function row(id, key, name, about, run, needs, extra)
  local r = { id = 'map.' .. id, group = GROUP, name = name, about = about, key = key, on = 'map', available = needs,
    run = function(ctx)
      local view = ctx and ctx.map
      if not valid(view) then return end
      local why = needs and needs(ctx)
      if why ~= nil and why ~= true then return tell(sentence(why), vim.log.levels.WARN) end
      run(view, ctx)
    end }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end
local HERE, THERE = { remote = false }, { remote = true }
-- What a key on the map acts on, for the menus: the selected box's (the pop-out's) or the one under the cursor (here).
local function map_subject(ctx)
  local view = ctx and ctx.map
  local item = ctx and (ctx.item or (valid(view) and not view.out and here(view)) or nil)
  local n = item and item.target and item.target.node
  if n then return tostring(n.label) .. ' · ' .. where(n) end
  return item and item.name and tostring(item.name) or nil
end
local ON_IT = { remote = true, subject = map_subject }
-- j/k/h/l go box to box, as in the call graph (its nav): a box is several lines tall and the gaps hold
-- nothing, so line by line left the cursor between boxes. In the pop-out they move its selection (ctx.copy); here they
-- go from the box under the cursor (or the nearest one, from a gap) and put the cursor on the next box's name.
local function moving(how, key, name, line, doc)
  return { id = 'map.' .. how, group = GROUP, name = name, about = name, key = key, on = 'map', menu = false, drawn = true,
    line = line and ('map.' .. line) or nil, doc = doc,
    run = function(ctx)
      local G = require('desk.callgraph')
      if ctx.copy then return G.move(ctx.copy, how) end
      local view = ctx.map
      if not (valid(view) and view.drawn and view.win and api.nvim_win_is_valid(view.win)) then return end
      local boxes, cursor = view.drawn.items or {}, api.nvim_win_get_cursor(view.win)
      local under, at = M.item_at(view.drawn, cursor[1], cursor[2]), nil
      for i, b in ipairs(boxes) do if under and b.item == under then at = i end end
      if not at then
        local gap = math.huge
        for i, b in ipairs(boxes) do local d = math.abs(b.line - cursor[1]); if d < gap then at, gap = i, d end end
      end
      for _ = 1, math.max(1, vim.v.count1 or 1) do at = G.nav(boxes, at, how) end
      local b = at and boxes[at]
      if b then pcall(api.nvim_win_set_cursor, view.win, { b.line, b.name_col or 0 }) end
    end }
end
local ROWS = actions.add({
  { id = 'map.debug-stack', group = GROUP, name = 'Show this stack on the map', key = '<leader>cs', on = 'editor', remote = true,
    about = "While the debugger is stopped: its stack, frame by frame (`Enter` opens each), and which of the stopped function's callers in the map are on it — the live caller or the replay one",
    available = function() local f, why = M.dap_frames(); return f and true or why end,
    run = function() M.stack_on_map() end },
  { id = 'map.sanitizer', group = GROUP, name = "A sanitizer report's stacks on the map", on = 'editor', remote = false,
    about = "The AddressSanitizer or ThreadSanitizer report in this buffer (a test's log) or the clipboard: the bad access, where the memory was freed, where it was allocated, each a stack of its own, the function where they meet marked and how they matched (the same line, the same function, only the same name); `Enter` on a frame opens it. A report from another machine: the prefix it had for this checkout is guessed from a file only one path here ends with, and read as this checkout once you say so",
    run = function() M.sanitizer_on_map() end },
  { id = 'map.trace-here', group = GROUP, name = 'Trace a possible path through this function', key = '<leader>cp', on = 'editor', remote = true,
    about = 'The path through the function at the cursor, up to where it starts and down to where it ends, with each step\'s parameters and the arguments it is called with (in the pop-out\'s map when it shows one)',
    run = function() M.trace_here() end },
  { id = 'map.open', group = GROUP, name = 'Project map', key = '<leader>cm', on = 'editor', remote = true, also = '`:ProjectMap`',
    about = 'The whole checkout as boxes, by part, file and function, callers above; queries and a rebuild inside. One tab per checkout: pressed again, it brings that tab back as it was, or the map out in the pop-out back as the tab',
    -- In the map itself its own keys apply; without desk-work the page opens and says so. Asked from the pop-out it
    -- would open a tab here, beside the Views row that opens the map there: there only that one is offered (2026-11-16:
    -- "when in the popout, opening more graphs, opens them in the editor").
    available = function(ctx) return (ctx.surface ~= 'map' and not ctx.remote) or false end,
    run = function() M.open() end },
  row('in', '<CR>', 'Zoom in, or go to the function',
    'Zoom into the part, file or class under the cursor; on a function, go to its code (the map stays open)', enter,
    needs_selection, ON_IT),
  row('back', '<BS>', 'Zoom out, or back to the code',
    "Zoom out a level (from a query's answer, back to the page it was asked on); at the top, back to the code, the map left open", back,
    nil, { remote = false, doc = "Zoom out a level (from a query's answer, back to the page it was asked on); at the top, back to the "
      .. 'code, the map left open. On a callers or reach page of more than one level, `-` takes a level off instead' }),
  -- At one level a callers or reach page zooms out, as every page does (2026-11-17: it only said it showed one level).
  row('out', '-', 'Zoom out, or take a level off',
    'Zoom out a level; on a callers or reach page of more than one level, take a level off (`+` adds one)',
    function(view, ctx)
      local top = walk_level(view)
      if top and (top.answer.depth or 3) > 1 then return change_walk(view, ctx, -1) end
      if view.out then return zoom_out(view) end
      back(view)
    end, nil, { line = 'map.back', menu = false, remote = true }),
  row('expand', '+', 'Expand call depth', 'Read another level on the callers or reach page',
    function(view, ctx) change_walk(view, ctx, 1) end, function(ctx)
      local top = walk_level(ctx.map)
      if not top then return 'open a callers or reach page first' end
      for _, step in ipairs(top.answer.steps or {}) do if step.mark == 'capped' then return true end end
      return 'no more levels in the project map'
    end, THERE),
  -- D and U: down and up the calls (2026-11-16: r and c here meant what they do not mean on a graph, read again and
  -- centre).
  row('reach', 'D', 'What a function reaches (downstream)',
    'Everything a function reaches, down the calls (a count before `D` is the depth; 3 without one)',
    function(view, ctx) walk(view, 'reach', ctx) end, needs_function, THERE),
  row('callers', 'U', 'Who calls a function (upstream)', 'Who calls a function, up the calls, transitively (a count before `U` is the depth)',
    function(view, ctx) walk(view, 'callers', ctx) end, needs_function, THERE),
  row('centre', 'c', 'The call graph of this function',
    'The call graph centred on the selected function, where the map is: a graph tab here, the call graph in the pop-out (`Ctrl+o` there comes back to the map)',
    centre, needs_function, ON_IT),
  row('trace', 't', 'Trace a possible path through this function',
    'The lane through the selected function: up to where it starts, down to where it ends; each step with its parameters (how each is passed, and whether the callee can change it) and what it is called with. In the pop-out it follows the function at the cursor (`p` pins it)',
    trace_from, needs_function, ON_IT),
  row('trace-to', 'e', 'Trace to a chosen function', 'On a trace: down to the function you name instead of where the chain ends',
    trace_to, needs_trace, { remote = true, input = { prompt = 'Trace to: ' } }),
  row('trace-from', 'S', 'Trace from a chosen start', 'On a trace: up from the function you name (a thread body, the live path) instead of the farthest start',
    trace_start, needs_trace, { remote = true, input = { prompt = 'Trace from: ' } }),
  row('trace-all', 'T', 'The whole trace', "Every way through the function in one picture: what leads to it above and what it leads to below, as boxes in layers, the lane `t` follows in double frames (on a trace: within the start and end you chose)",
    whole_trace, function(ctx) if needs_trace(ctx) == true then return true end return needs_function(ctx) end, ON_IT),
  row('handoff-drop', 'x', 'Drop this handoff',
    'On a trace, on a handoff (its `══ handoff ══` break): the map inferred it wrongly, so it is dropped (one you added is forgotten). Kept by desk-work outside the checkout, in `~/.config/foxml/desk.d/`',
    drop_handoff, needs_handoff, { remote = true, input = { prompt = 'Drop this handoff? y/n: ' } }),
  row('handoff-add', 'a', 'Add a handoff from this step',
    'On a trace: this function hands its data on to the one you name (a queue or a callback the map missed), so the trace goes on through it',
    add_handoff, needs_trace_step, { remote = true, input = { prompt = 'Hands off to: ' } }),
  row('handoffs', nil, 'Review handoff corrections',
    'Every handoff you added or dropped, its label and where it is declared, each end checked against the map as built now (moved, several now, gone); `Enter` on one forgets, rebinds or opens it',
    function(view) query(view, { '--q', 'handoffs' }) end, nil, THERE),
  row('findings', 'F', 'Findings on this path',
    "On a trace: the findings of the checkout's tools (desk-work's, docs/desk-tools.md) that fall inside the route's functions, each with its tool; `Enter` opens its line",
    findings_on_path, needs_trace, THERE),
  row('tests', 'K', 'Known tests for this file',
    "On a function: the test commands desk-work has seen touch its file, each with why it is suggested and whether its result is stale; one chosen runs on the saved files",
    function(view, ctx)
      local item = about_item(view, ctx)
      local n = item and item.target and item.target.node
      if not (n and n.file) then return tell('Put the cursor on a function with a file first.') end
      require('desk.work').suggested_tests(view.root .. '/' .. n.file)
    end, needs_function, THERE),
  row('copy', 'y', 'Copy this investigation as Markdown',
    'On a trace: its question, the revision the map read (and what has moved since, why it was stale, what was left out), each step with its file:line, the handoffs it relies on and a sentence of yours, as Markdown for a review, an issue or the notebook',
    copy_investigation, needs_trace, THERE),
  row('symdeps', 'gs', 'This function in symdeps', "The selected function in symdeps' card (C and C++), shown in the code, as `gs` in the call graph",
    in_symdeps, needs_c_function, ON_IT),
  row('paths', 'P', 'The ways between two functions', 'Every way from one function to another, shortest first', ways, needs_function,
    { remote = true, input = { prompt = 'Ways to: ' } }),
  row('avoid', 'gP', 'Ways that avoid this function',
    'On a ways page: the same two ends, every way that does not go through the selected function (can it be reached without it?); a "no" says what was searched',
    avoid_this, function(ctx)
      local why = needs_function(ctx)
      if why ~= true then return why end
      local top = ctx.map and ctx.map.stack and ctx.map.stack[#ctx.map.stack]
      return (top and top.answer and top.answer.q == 'paths') or 'on a ways page (P)'
    end, ON_IT),
  row('module', 'M', 'A part of the checkout', 'Go to a part of the checkout, picked by name', part, needs_map, HERE),
  row('exclude', 'z', 'Leave this function out of the answers',
    'The selected function left out of the map\'s answers (a logger, an allocator every path goes through), its calls with it, until `z` again or `Z`; the page says how many are left out',
    function(view, ctx)
      local item = about_item(view, ctx)
      local n = item and item.target and item.target.node
      if not (n and n.id) then return tell('Put the cursor on a function first.') end
      M.exclude(view, n)
    end, needs_function, ON_IT),
  row('include', 'Z', 'Bring back what was left out',
    'Every function `z` left out of the answers back in; the page asked again', function(view) M.include_all(view) end,
    function(ctx) return (ctx.map and ctx.map.excluded and #ctx.map.excluded > 0) or 'nothing is left out' end, THERE),
  row('in-binary', 'gb', 'This function in the binary',
    "The selected function as the binary has it: its linked symbol and the copies the compiler made of it (.cold, .isra, .constprop), or why it has no box of its own there (inlined, or not built into it)",
    function(view, ctx)
      local item = about_item(view, ctx)
      local n = item and item.target and item.target.node
      if not n then return tell('Put the cursor on a function first.') end
      local provider
      for _, p in ipairs(view.status and view.status.providers or {}) do if p.name == 'binary' then provider = p end end
      push(view, { kind = 'binary', node = n, provider = provider }, item.key)
    end, needs_function, ON_IT),
  row('changes', 'W', 'What the last rebuild changed',
    'The calls and functions the last rebuild added and removed, the functions that found or lost their source, and why (the source, the binary, a parser), against the build before it',
    function(view) query(view, { '--q', 'changes' }) end, needs_map, THERE),
  row('why', 'i', 'Why the answer is what it is',
    "The map's evidence in full: which reader answered (the syntax reader matches calls by name: overloads, macros and virtual dispatch are not resolved; the binary reader has the exact calls), what is not built and what it needs; `i` again folds it to one line",
    function(view) view.evidence_open = not view.evidence_open; load(view) end, needs_map, THERE),
  row('read', 'r', 'Read the map again',
    "Read this page again, as `r` does in a call graph: desk-work's status and the level shown (a query's answer is asked again); `R` rebuilds the map",
    function(view) reread(view) end, needs_map, THERE),
  row('rebuild', 'R', 'Rebuild the map', 'Rebuild the map in the background (a desk-work job; its log is in the jobs list)',
    function(view) M.rebuild(view) end, needs_reader, THERE),
  row('binary', 'B', 'Rebuild reading a binary', 'Rebuild, reading a built binary for its exact calls (remembered for the next builds)',
    binary, needs_desk_work, HERE),
  row('close', 'q', 'Close the project map', 'Close the project map', function(view) M.close(view) end, nil, HERE),
  -- o here sends the map to the pop-out; o there brings it back (desk.popout's own row, popout.back).
  row('popout', 'o', 'Send the map to the pop-out',
    'Move this map to the pop-out on the other screen (opening it) and close it here; `o` there brings it back as this tab, as it was',
    function(_, ctx) pop().show('map', ctx) end, function() return pop().can_pop() end, HERE),
  moving('down', 'j', 'The box below', nil, 'The box below / above (the nearest one in that row)'),
  -- Two routes (E6): this trace beside the one from another of its starts, where they part and meet; a menu row
  row('compare-route', nil, 'Compare with another start',
    'This trace beside the one from another start it could have begun at: what they share, where they part, where they meet again',
    function(view, ctx)
      local top = view.stack[#view.stack]
      local a = top.answer
      local args = { '--q', 'trace', '--from', a.focus, '--start', tostring(ctx.choice) }
      if a.to then vim.list_extend(args, { '--to', a.to }) end
      local full = vim.list_extend({ 'map', 'query', '--root', view.root }, args)
      if view.excluded and #view.excluded > 0 then
        vim.list_extend(full, { '--exclude', table.concat(vim.tbl_map(function(x) return x.id end, view.excluded), '\n') })
      end
      -- in turn with the map's other questions: one asked before it (the trace following the cursor) is dropped
      view.asked = (view.asked or 0) + 1
      local asked = view.asked
      M.desk_work(full, function(b, out)
        if asked ~= view.asked or not valid(view) or view.stack[#view.stack] ~= top then return end
        if not b or b.ok == false then return tell(refusal(b, out), vim.log.levels.WARN) end
        push(view, { kind = 'query', answer = { ok = true, q = 'routes', a = a, b = b, a_args = top.args, b_args = args }, root = view.root })
      end)
    end, function(ctx)
      local view = ctx and ctx.map
      local top = valid(view) and view.stack[#view.stack]
      local a = top and top.kind == 'query' and top.answer
      if not (a and a.q == 'trace') then return 'on a trace (t)' end
      if type(a.starts) ~= 'table' or #a.starts == 0 then return 'this trace has no other start' end
      return true
    end, { remote = true, input = { choices = function(ctx)
      local view = ctx and ctx.map
      local top = valid(view) and view.stack[#view.stack]
      local out = {}
      for _, st in ipairs(top and top.answer and type(top.answer.starts) == 'table' and top.answer.starts or {}) do
        out[#out + 1] = { id = st.id, name = tostring(st.label) }
      end
      return out
    end } }),
  -- A test run's coverage on the page (E5): gc picks the run (or takes it off), ]u / [u go between what it did not reach
  row('coverage', 'gc', "A test run's coverage on this page",
    "Each function on the page marked with whether one test run ran it (\"ran 3×\" or \"not run\"), from the run's recorded coverage; `]u` and `[u` go between the ones it did not reach",
    function(view, ctx)
      if ctx.choice == 'off' then view.coverage = nil; return load(view) end
      local got = vim.system({ 'desk-work', 'coverage', '--root', view.root, '--run', tostring(ctx.choice) }, { text = true, timeout = 20000 }):wait()
      local ok, doc = pcall(vim.json.decode, got.stdout or '')
      if got.code ~= 0 or not ok or type(doc) ~= 'table' or type(doc.files) ~= 'table' then return tell('That run kept no coverage.', vim.log.levels.WARN) end
      local label = (doc.command ~= vim.NIL and doc.command) or tostring(ctx.choice)
      view.coverage = { id = ctx.choice, name = (tostring(label):match('(%S+)%s*$') or label):gsub('^[\'"]', ''):gsub('[\'"]$', ''), files = doc.files }
      load(view)
    end, needs_map, { remote = true, input = { choices = function(ctx)
      local view = ctx and ctx.map
      local out = {}
      if valid(view) and view.coverage then out[#out + 1] = { id = 'off', name = 'Take the coverage off' } end
      local got = valid(view) and vim.system({ 'desk-work', 'jobs', '--root', view.root }, { text = true, timeout = 10000 }):wait()
      local ok, runs = pcall(vim.json.decode, got and got.stdout or '')
      for _, r in ipairs(ok and type(runs) == 'table' and runs or {}) do
        if type(r) == 'table' and type(r.coverage) == 'table' and #out < 20 then
          out[#out + 1] = { id = r.id, name = os.date('%m-%d %H:%M', r.ended or 0) .. '  ' .. tostring((r.title or '') ~= '' and r.title or r.command) }
        end
      end
      return out
    end } }),
  { id = 'map.next-unrun', group = GROUP, name = 'The next box the run did not reach', key = ']u', on = 'map', menu = false, drawn = true,
    about = 'With a run\'s coverage on the page (`gc`): the next function it did not run, wrapping', doc = 'With a run\'s coverage on (`gc`): the next / previous function it did not run',
    run = function(ctx)
      local sel = ctx.copy or (valid(ctx.map) and ctx.map.sel)
      local j = sel and sel.drawn and M.next_unrun(sel.drawn.boxes, sel.index, 1)
      if not j then return tell('Nothing on this page the run did not reach (or no run chosen: gc).') end
      require('desk.callgraph').select(sel, j, true)
    end },
  { id = 'map.prev-unrun', group = GROUP, name = 'The previous box the run did not reach', key = '[u', on = 'map', menu = false, drawn = true, line = 'map.next-unrun',
    about = 'With a run\'s coverage on the page (`gc`): the previous function it did not run, wrapping',
    run = function(ctx)
      local sel = ctx.copy or (valid(ctx.map) and ctx.map.sel)
      local j = sel and sel.drawn and M.next_unrun(sel.drawn.boxes, sel.index, -1)
      if not j then return tell('Nothing on this page the run did not reach (or no run chosen: gc).') end
      require('desk.callgraph').select(sel, j, true)
    end },
  -- gj / gk along a real call, as on the call graph (T1): the selected box's callees and callers, the call's line
  { id = 'map.along-down', group = GROUP, name = 'Along a call, to what it calls', key = 'gj', on = 'map', menu = false, drawn = true,
    about = 'To a function the selected box calls, however far down the page; again, the next one it calls (wrapping), or on down when it calls only one',
    doc = 'Along a real call: to what the box calls / to what calls it, again for the next',
    run = function(ctx) if ctx.copy then return require('desk.callgraph').along(ctx.copy, 'down') end; if valid(ctx.map) and ctx.map.sel then require('desk.callgraph').along(ctx.map.sel, 'down') end end },
  { id = 'map.along-up', group = GROUP, name = 'Along a call, to what calls it', key = 'gk', on = 'map', menu = false, drawn = true, line = 'map.along-down',
    about = 'To a function that calls the selected box, however far up the page; again, the next one that calls it (wrapping), or on up when only one does',
    run = function(ctx) if ctx.copy then return require('desk.callgraph').along(ctx.copy, 'up') end; if valid(ctx.map) and ctx.map.sel then require('desk.callgraph').along(ctx.map.sel, 'up') end end },
  moving('up', 'k', 'The box above', 'down'),
  moving('left', 'h', 'The box to the left', nil, 'The box to the left / right in the same row'),
  moving('right', 'l', 'The box to the right', 'left'),
})

-- ─── in the pop-out: desk.popout's view kind 'map' ─────────────────────────────────────────────────────────────
-- The map on the other screen: the same pages, keys and state as its tab. Enter there zooms in, or goes to a function
-- here while the keyboard stays there; - goes back out, and each zoom and each answer is a step of the pop-out's
-- history (H and Backspace there). o there brings it back here as its tab. It follows nothing: p pins it only so that
-- it comes back here when the pop-out goes on its own.

-- A window here that shows a file: the current one, else the first in this tab (where Enter on a function goes).
local function code_window(win)
  if not (win and api.nvim_win_is_valid(win)) or api.nvim_win_get_config(win).relative ~= '' then return false end
  return vim.bo[api.nvim_win_get_buf(win)].buftype == ''
end
local function target_window()
  local current = api.nvim_get_current_win()
  if code_window(current) then return current end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do if code_window(win) then return win end end
end
-- The checkout of the window a map was asked for in, else of the working directory.
local function root_of(ctx)
  if ctx and type(ctx.map_root) == 'string' then return ctx.map_root end   -- an answer for another checkout's map
  local name = ctx and ctx.buf and api.nvim_buf_is_valid(ctx.buf) and api.nvim_buf_get_name(ctx.buf) or ''
  local root = vim.fs.root(name ~= '' and name or vim.fn.getcwd(), '.git') or vim.fn.getcwd()
  return uv.fs_realpath(root) or root
end
-- A map of root, at its top, nothing read yet.
local function fresh(view, root)
  stop_polling(view)
  view.root, view.stack, view.cache, view.previous, view.status = root, { { kind = 'modules' } }, {}, nil, nil
  view.missing, view.message, view.building, view.building_at, view.asked = nil, nil, false, nil, view.asked or 0
end

-- The view, from where it was asked: o in a map's tab sends that map (it leaves the tab); the Views row anywhere else
-- opens the map of that checkout (the one already there when it is that checkout's).
local function open_view(view, ctx)
  view.out = true
  local from = ctx and ctx.map
  if from and from ~= view and not from.out and valid(from) then
    stop_polling(from)
    adopt(view, from)
    M.close(from)
  elseif not view.stack or view.root ~= root_of(ctx) then
    fresh(view, root_of(ctx))
  end
  refresh(view)
end

-- A box's key: what it stands for, so the same box keeps its selection when the page is drawn again; a second drawing
-- of one thing (a part again in the calls between parts) gets its count.
local function item_key(item, seen)
  local base = box_of(item)
  if #base > 100 then base = base:sub(1, 80) .. ':' .. vim.fn.sha256(base):sub(1, 16) end
  seen[base] = (seen[base] or 0) + 1
  return seen[base] > 1 and (base .. '#' .. seen[base]) or base
end
local GROUPS = { 'DeskMapFocus', 'DeskMapBox', 'DeskMapName', 'DeskMapDim', 'DeskMapHead', 'DeskMapTitle', 'DeskMapStale' }
-- Its key line in the pop-out (? there lists every key).
local FOOTER = { { ids = { 'map.in' }, words = 'in' }, { ids = { 'map.out' }, words = 'out' }, { ids = { 'map.reach' }, words = 'reach' },
  { ids = { 'map.callers' }, words = 'callers' }, { ids = { 'popout.keys' }, words = 'keys' } }
-- The page for the pop-out's width: the tab's, without its key line (the pop-out's window has its own), each box and
-- named part an item (its ref the map's own item: what the keys there are about).
-- The view's page is a trace (the one page that follows the cursor in the pop-out).
local function tracing(view)
  local top = view.stack and view.stack[#view.stack]
  return top and top.kind == 'query' and top.answer and top.answer.q == 'trace' and top or nil
end
local function render_view(view, width, style)
  highlights()
  local retro = style == 'retro'
  local G = M.glyphs(retro)
  local page = page_for(view, G)
  page.notes = M.footer(view, G, false)
  local drawn = M.layout(page, math.max(20, width - 2), retro)
  local items, seen = {}, {}
  for _, p in ipairs(drawn.items) do
    local key = item_key(p.item, seen)
    p.item.key = key
    items[#items + 1] = { key = key, kind = 'box', line = p.line, name_col = p.name_col, x = p.x, w = p.w, spans = p.spans,
      centre = p.centre == true, gauge = p.gauge, gauge_band = p.gauge_band, gauge_col = p.gauge_col, name = tostring(p.item.name or ''),
      where = type(p.item.detail) == 'string' and p.item.detail ~= '' and p.item.detail or nil, ref = p.item,
      near = p.near, down = p.down, up = p.up, down_sites = p.down_sites, up_sites = p.up_sites, unrun = p.item.unrun == true or nil }
  end
  -- The key line says what the selected thing is and what its keys do there (the pop-out shows it while it is selected).
  for _, it in ipairs(items) do
    local two = M.strip_text(it.ref, G)
    -- Enter's slot first (Codex's #9: it never moves), what the thing is after it
    if two then it.keys = two[2] .. '   ' .. two[1] end
  end
  local footer = FOOTER
  view.follows = tracing(view) ~= nil
  if view.follows then footer = vim.list_extend(vim.list_slice(footer), { { ids = { 'popout.pin' }, words = 'pin/follow' } }) end
  local traced = tracing(view)
  local focus_label
  for _, st in ipairs(traced and traced.answer.steps or {}) do if st.id == traced.answer.focus then focus_label = st.label end end
  return { title = 'project map · ' .. vim.fn.fnamemodify(view.root or '', ':t'), state = '',
    tab = traced and 'trace' or 'map', subject = traced and focus_label or vim.fn.fnamemodify(view.root or '', ':t'),
    lines = drawn.lines, marks = drawn.marks, hl = GROUPS, items = items, footer = footer, heads = drawn.heads, news = view.news == true }
end

-- What the selected thing is, then what its keys do there (the pop-out's key line while it is selected) — a function's, a fold's, a handoff's, a step on a pick page. Words in the theme's voice, code and
-- keys as typed. nil: nothing to say.
--- The first slot of a key line (Codex's #9): what Enter does with the selected thing, named, padded to one width so
--- the rest of the line stays put as the selection moves.
M.ENTER_SLOT = 38
function M.enter_slot(G, words, code_part)
  -- the words in the theme's voice, the code (a name, a place) as typed: retro shouts only the words
  local text = typed('in') .. ' ' .. G.said(words) .. (code_part and (' ' .. code_part) or '')
  local w = vim.fn.strdisplaywidth(text)
  if w > M.ENTER_SLOT then
    local chars, out = vim.fn.split(text, '\\zs'), ''
    for _, ch in ipairs(chars) do
      if vim.fn.strdisplaywidth(out .. ch) > M.ENTER_SLOT - 1 then break end
      out = out .. ch
    end
    return out .. G.ellipsis
  end
  return text .. string.rep(' ', M.ENTER_SLOT - w)
end
function M.strip_text(item, G)
  G = G or M.glyphs(false)
  local t = item and item.target
  if not t then return nil end
  local function keys(list)
    local out = {}
    for _, k in ipairs(list) do out[#out + 1] = typed(k[1]) .. ' ' .. G.said(k[2]) end
    return table.concat(out, ' · ')
  end
  local function line(enter, rest, code_part)
    local slot = M.enter_slot(G, enter, code_part)
    return rest and rest ~= '' and (slot .. ' · ' .. rest) or vim.trim(slot)
  end
  if t.kind == 'node' and t.node then
    local n = t.node
    local list = { { 'trace', 'trace' }, { 'centre', 'calls' }, { 'reach', 'reach' }, { 'callers', 'callers' } }
    if n.file and ({ c = true, cpp = true })[vim.filetype.match({ filename = n.file }) or ''] then list[#list + 1] = { 'symdeps', 'inspect' } end
    return { tostring(n.label) .. ' · ' .. where(n) .. (n.returns and (' → ' .. n.returns) or ''),
      line('open', keys(list), tostring(n.label) .. ' (' .. where(n) .. ')') }
  elseif t.kind == 'module' or t.kind == 'file' or t.kind == 'class' then
    return { tostring(item.name), line('zoom into', keys({ { 'back', 'out' } }), tostring(item.name)) }
  elseif t.kind == 'start' then
    return { G.said('another start · ') .. tostring(item.name), line('trace from here', tostring(item.name)) }
  elseif t.kind == 'route' then
    return { G.said('one route · ') .. tostring(item.name), line('open it as its trace', tostring(item.name)) }
  elseif t.kind == 'change' then
    return { tostring(item.name) .. ' · ' .. t.file .. (t.line and (':' .. t.line) or ''),
      line(t.side == 'removed' and 'open it as the build before read it' or 'open it', tostring(item.name)) }
  elseif t.kind == 'walk' then
    return { G.said(t.q == 'callers' and 'what comes before ' or 'what comes after ') .. tostring(t.node and t.node.label or ''),
      line(t.q == 'callers' and 'open what comes before' or 'open what comes after', G.said('3 levels (+ and - change it)')) }
  elseif t.kind == 'fold' then
    return { tostring(item.name), line(item.open and 'close it' or 'open it') }
  elseif t.kind == 'handoff' then
    return { G.said('handoff ') .. tostring(item.name) .. G.said(t.by_hand and ' — added by you' or ' — inferred from the code'),
      line('open producer or consumer', typed('handoff-drop') .. ' ' .. G.said(t.by_hand and 'forgets it' or 'drops it (it is wrong)')) }
  elseif t.kind == 'field' then
    return { tostring(item.name), line('inspect field', G.said('its declaration, who writes it, or on this route'), tostring(t.field or item.name)) }
  elseif t.kind == 'result' then
    return { tostring(item.name), line('show where its result goes', G.said('checked, returned, kept or dropped')) }
  elseif t.kind == 'crossings' then
    return { tostring(item.name), line('show the calls that cross', G.said('by the entry function they reach')) }
  elseif t.kind == 'call' then
    local n = #(t.sites or {})
    return { tostring(t.caller) .. ' → ' .. tostring(t.callee) .. G.said(n > 1 and (' — ' .. n .. ' calls') or ''),
      line(n > 1 and ('open call site (' .. n .. ': pick)') or 'open call site') }
  elseif t.kind == 'correction' then
    return { tostring(item.name), line('forget, rebind or open it') }
  elseif t.kind == 'commit' then
    return { tostring(item.name), line('show what it changed, on the map') }
  elseif t.kind == 'pick' then
    return { tostring(item.name), line('use this one') }
  end
end

-- The history's step back as it was (step); the layout record's { pinned, target } after a restart: that checkout's
-- map, zoomed in as it was (its queries are not kept).
local LEVELS = { modules = true, files = true, functions = true, class = true }
local function text_or_nil(value) return type(value) == 'string' and value or nil end
local function restore_view(view, saved)
  view.out = true
  if saved.step then
    view.stack, view.select = vim.list_slice(saved.stack), nil
    return load(view)
  end
  local target = type(saved.target) == 'table' and saved.target or {}
  local root = type(target.root) == 'string' and uv.fs_stat(target.root) and (uv.fs_realpath(target.root) or target.root) or root_of(nil)
  fresh(view, root)
  local levels = {}
  for _, l in ipairs(type(target.levels) == 'table' and target.levels or {}) do
    if type(l) == 'table' and LEVELS[l.kind] then
      levels[#levels + 1] = { kind = l.kind, module = text_or_nil(l.module), file = text_or_nil(l.file), id = text_or_nil(l.id),
        name = text_or_nil(l.name), node = type(l.node) == 'table' and l.node or nil }
    end
  end
  if levels[1] and levels[1].kind == 'modules' then view.stack = levels end
  local trace = type(target.trace) == 'table' and target.trace or nil
  if not (trace and text_or_nil(trace.focus)) then return refresh(view) end
  do
    local args = { '--q', 'trace', '--from', trace.focus }
    if text_or_nil(trace.to) then vim.list_extend(args, { '--to', trace.to }) end
    if text_or_nil(trace.start) then vim.list_extend(args, { '--start', trace.start }) end
    local folds = {}
    for k, v in pairs(type(trace.folds) == 'table' and trace.folds or {}) do if type(k) == 'string' and type(v) == 'boolean' then folds[k] = v end end
    view.restoring = { folds = folds, selected = text_or_nil(trace.selected) }
    -- asked once the map is known to be built; the page under it is read when she goes back to it (reading it now
    -- would make the trace's answer one asked before the last, and dropped)
    status(view, function(st)
      if st and st.building then poll(view) end
      if st and st.built then query(view, args) end
    end)
  end
end

-- Following, a trace in the pop-out (her ask, 2026-11-18: the trace "should be able to be used in the pop out"): once
-- the cursor rests in a code window of the same checkout and has left the traced function, the trace is asked again for
-- the function under it — in place, no page added, quiet when the cursor is in no function. p pins it. Only a trace
-- follows; the map's other pages stay where they are (view.follows says which, for the pop-out's ↻).
M.FOLLOW_MS = 300
local function follow_trace(view, win)
  local top = tracing(view)
  if not top or view.pinned or view.gone or not valid(view) or not (win and api.nvim_win_is_valid(win)) then return end
  local buf = api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= '' or views[buf] or api.nvim_win_get_config(win).relative ~= '' then return end
  local name = api.nvim_buf_get_name(buf)
  name = uv.fs_realpath(name) or name
  local root = view.root or ''
  if root == '' or name:sub(1, #root + 1) ~= root .. '/' then return end
  local rel, line = name:sub(#root + 2), api.nvim_win_get_cursor(win)[1]
  for _, st in ipairs(top.answer.steps or {}) do
    if st.id == top.answer.focus and st.file == rel and st.line and line >= st.line and line < st.line + math.max(1, st.lines or 1) then return end
  end
  query(view, { '--q', 'trace', '--file', rel, '--line', tostring(line), '--from', '' }, nil, top, true)
end
-- Pinned on a route: moving through its code selects the step the cursor is in (the route stays as it is).
local function show_step(view, win)
  local top = tracing(view)
  if not top or not view.pinned or view.gone or not (win and api.nvim_win_is_valid(win)) then return end
  local name = api.nvim_buf_get_name(api.nvim_win_get_buf(win))
  name = uv.fs_realpath(name) or name
  local root = view.root or ''
  if root == '' or name:sub(1, #root + 1) ~= root .. '/' then return end
  local rel, line = name:sub(#root + 2), api.nvim_win_get_cursor(win)[1]
  for _, st in ipairs(top.answer.steps or {}) do
    if st.file == rel and st.line and line >= st.line and line < st.line + math.max(1, st.lines or 1) then
      local key = box_of(node_item(st))
      if top.selected ~= key then top.selected, view.select = key, key; pop().redraw(view) end
      return
    end
  end
end
local function follow_soon(view, win)
  view.follow_win = win
  if view.pinned and tracing(view) then
    view.follow_timer = view.follow_timer or uv.new_timer()
    view.follow_timer:stop()
    view.follow_timer:start(M.FOLLOW_MS, 0, vim.schedule_wrap(function() show_step(view, win) end))
    return
  end
  if view.pinned or not tracing(view) then return end
  view.follow_timer = view.follow_timer or uv.new_timer()
  view.follow_timer:stop()
  view.follow_timer:start(M.FOLLOW_MS, 0, vim.schedule_wrap(function() follow_trace(view, win) end))
end
M._follow_trace = follow_trace

M.view_kind = {
  name = 'map', title = 'project map', surface = 'map',
  about = 'The project map in the pop-out, a window of its own on the other screen: `Enter` there zooms in, or goes to a function here while the keyboard stays there; `-` and `Backspace` go back out',
  -- In a map's tab its own key sends it (map.popout).
  available = function(ctx) if not ctx.remote and ctx.surface == 'map' then return false end end,
  open = open_view,
  render = render_view,
  -- A file of its checkout saved: desk-work's status read again, so "stale since …" shows here too (on open only before,
  -- 2026-11-16). Only a trace follows the cursor (view.follows, set as it draws).
  follows = false,
  follow = function(view, event)
    if event.type == 'moved' or event.type == 'unit' then return follow_soon(view, event.win) end
    if event.type == 'pin' then
      if not view.pinned and view.follow_win then follow_trace(view, view.follow_win) end
      return
    end
    if event.type ~= 'saved' or view.timer or not view.status or not api.nvim_buf_is_valid(event.buf) then return end
    local name, root = api.nvim_buf_get_name(event.buf), view.root or ''
    if root ~= '' and name:sub(1, #root + 1) == root .. '/' then status(view) end
  end,
  ctx_for = function(view, ref)
    local win = target_window()
    local ctx = actions.context(win or api.nvim_get_current_win())
    ctx.surface, ctx.map, ctx.item, ctx.origin = 'map', view, ref, win
    return ctx
  end,
  -- o in the pop-out: back here as its tab, as it was, beside the code it is open on.
  attach = function(view)
    local win = target_window()
    if win then pcall(api.nvim_set_current_win, win) end
    M.open(view.root, view)
  end,
  -- The place of a selected item, for the preview pane (gp): a function's line, a call's, a handoff's push.
  place = function(view, ref)
    local t = ref and ref.target
    if not (t and view.root) then return nil end
    if t.kind == 'node' and t.node and t.node.file then return view.root .. '/' .. t.node.file, t.node.line or 1 end
    if t.kind == 'call' and t.file and t.sites and t.sites[1] then return view.root .. '/' .. t.file, t.sites[1].line end
    if t.kind == 'handoff' and t.producer and t.producer.file then return view.root .. '/' .. t.producer.file, t.producer.line end
    if t.kind == 'field' and t.step and t.step.file then return view.root .. '/' .. t.step.file, t.step.line end
  end,
  close = function(view)
    stop_polling(view)
    if view.follow_timer then view.follow_timer:stop(); view.follow_timer:close(); view.follow_timer = nil end
  end,
  save = save_view,
  restore = restore_view,
}
-- Registered as the module loads (not when it runs headless as the syntax reader), so its Views row is in the registry.
if not headless then pop().kind(M.view_kind) end

-- ─── Space i: investigate this function (I1, 2026-11-19) ────────────────────────────────────────────────────────
-- One prefix for every question about a function, wherever it is pressed: in code the function at the cursor, on a
-- call graph the selected box, on the map the selected function, in the review the selected changed function. The
-- same letters everywhere (which-key lists them after Space i); each runs the existing action, nothing of its own.
--- The function a Space i key is about → { path, line, name } or nil and why.
function M.function_here(ctx)
  ctx = ctx or {}
  local surface = ctx.surface or ''
  if ctx.review or surface:match('^review') then
    local r = ctx.review or (package.loaded['desk.review'] or {}).current
    local f, s = r and r.files and r.files[r.index], r and r.symbol
    if f and s and s.line and s.side ~= 'before' and s.kind ~= 'hunk' then return { path = f.path, line = s.line, name = s.name } end
    return nil, 'select a changed function first'
  end
  local function from_item(item)
    if item and item.uri and item.range and item.range.start then
      return { path = vim.uri_to_fname(item.uri), line = item.range.start.line + 1, name = item.name }
    end
  end
  if ctx.map then
    local item = about_item(ctx.map, ctx)
    local node = item and item.target and item.target.node
    if node and node.file then return { path = ctx.map.root .. '/' .. node.file, line = node.line or 1, name = node.label } end
    return nil, 'select a function first'
  end
  if ctx.graph or surface:match('^callgraph') then
    local item = ctx.view and ctx.item or (ctx.graph and require('desk.callgraph').selected(ctx.graph))
    return from_item(item) or nil, 'select a function first'
  end
  if ctx.view then return from_item(ctx.item) or nil, 'select a function first' end
  local buf = ctx.buf or api.nvim_get_current_buf()
  local path = vim.bo[buf].buftype == '' and api.nvim_buf_get_name(buf) or ''
  if path == '' then return nil, 'put the cursor in a function of a file first' end
  local win = ctx.win and api.nvim_win_is_valid(ctx.win) and ctx.win or api.nvim_get_current_win()
  return { path = path, line = api.nvim_win_get_cursor(win)[1] }
end
local INVESTIGATE_ON = { 'editor', 'callgraph', 'callgraph-panel', 'map', 'review-list', 'review-diff' }
local function investigate(verb, letter, name, about, run)
  return { id = 'investigate.' .. verb, group = 'This function', name = name, key = '<leader>i' .. letter, on = INVESTIGATE_ON, remote = true,
    about = about,
    available = function(ctx) local f, why = M.function_here(ctx); return f and true or why end,
    run = function(ctx)
      local f, why = M.function_here(ctx)
      if not f then return tell(why:sub(1, 1):upper() .. why:sub(2) .. '.') end
      run(f, ctx)
    end }
end
local INVESTIGATE = actions.add({
  investigate('graph', 'c', 'Its call graph', 'The call graph of the function: in a tab here, in the pop-out from there', function(f, ctx)
    local G = require('desk.callgraph')
    local target, why = G.target_at(f.path, f.line, f.name)
    if not target then return tell(why:sub(1, 1):upper() .. why:sub(2) .. '.') end
    if ctx.view then return pop().show('graph', { target = target }, { pop = ctx.view.pop or 1 }) end
    G.open(target)
  end),
  investigate('trace', 't', 'Trace a possible path through it', 'One lane through the function: up to where it starts, down to where it ends (the map\'s `t`)',
    function(f, ctx) M.trace_at(f.path, f.line, { pop = ctx.view and ctx.view.pop }) end),
  investigate('trace-all', 'T', 'Its whole trace', 'Every way through the function in one picture: what leads to it, what it leads to (the map\'s `T`)',
    function(f, ctx) M.trace_at(f.path, f.line, { pop = ctx.view and ctx.view.pop, q = 'flow' }) end),
  investigate('callers', 'u', 'Who calls it (up)', 'Who calls the function, up the calls, on the project map (the map\'s `U`)',
    function(f) M.walk_at('callers', f.path, f.line) end),
  investigate('reach', 'd', 'What it reaches (down)', 'Everything the function reaches, down the calls, on the project map (the map\'s `D`)',
    function(f) M.walk_at('reach', f.path, f.line) end),
  investigate('tests', 'k', 'Known tests', 'The test commands desk-work has seen touch its file, the one that ran most of it first (the map\'s `K`)',
    function(f) require('desk.work').suggested_tests(f.path) end),
  investigate('coverage', 'r', 'Which test ran it', 'The coverage of a test run marked on its file: which lines of it ran (and, from the review, on the changed function)',
    function(f, ctx)
      if ctx.review or (ctx.surface or ''):match('^review') then return require('desk.review').coverage_of_symbol() end
      if ctx.surface ~= 'editor' then require('desk.nav').open_code(f.path, f.line) end
      require('desk.work').coverage()
    end),
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
  actions.map('editor', { rows = INVESTIGATE })
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
