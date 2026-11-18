-- nvim --headless --clean -l shared/nvim_lua/tests/test_map.lua : desk.map — the syntax reader on small files, the
-- pure layout at each zoom, and the view driven by a fake desk-work (no desk-work record is read or written).
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
table.insert(package.loaders, 2, function(name)
  local file = here .. "../" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/site")   -- the installed treesitter parsers, as desk-work's job has them
vim.g.desk_style = "paper"
local Map = require("desk.map")
local api = vim.api
local passed, failed, skipped = 0, 0, {}
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want)) end
end
local function ok(cond, what) eq(not not cond, true, what) end
local function text(lines) return table.concat(lines, "\n") end
local function line_with(lines, pattern)
  for i, l in ipairs(lines) do if l:find(pattern, 1, true) then return i, l end end
end
local function has_parser(lang) return vim.treesitter.language.add(lang) == true end

-- ─── the syntax reader ─────────────────────────────────────────────────────────────────────────────────────────
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/lua", "p")
vim.fn.mkdir(root .. "/csrc", "p")
vim.fn.mkdir(root .. "/py", "p")
local sources = {
  ["lua/mod.lua"] = { "local M = {}", "local function helper(x) return x + 1 end", "function M.alpha()", "  return M.beta() + helper(2)", "end",
                      "function M.beta()", "  vim.schedule(function() M.alpha() end)", "  return 1", "end", "M.gamma = function() return helper(3) end",
                      "local t = { delta = function() return M.gamma() end }", "return M" },
  ["lua/other.lua"] = { "local R = require('mod')", "local function helper() end", "local function use() return R.alpha() + helper() end",
                        "local function twice() return dup() end", "return use" },
  ["lua/dups.lua"] = { "function dup() end" },
  ["lua/dups2.lua"] = { "function dup() end" },
  ["csrc/util.c"] = { "struct point { int x, y; };", "struct point *make(void);", "static int square(int v) { return v * v; }",
                      "int norm(struct point *p) { return square(p->x) + square(p->y); }",
                      "int *find(int *a, int n) { return n ? a : (int *)(long)norm(0); }" },
  ["py/app.py"] = { "class Store:", "    def save(self, item):", "        self.check(item)", "        return write(item)", "",
                    "    def check(self, item):", "        return item is not None", "", "", "def write(item):", "    return len(str(item))", "",
                    "def total(p):", "    return norm(p)" },
  ["lua/a/one.lua"] = { "local function pick() return 1 end", "return pick" },
  ["lua/a/two.lua"] = { "local function choose() return pick() end", "return choose" },
  ["lua/b/three.lua"] = { "local function pick() return 3 end", "return pick" },
  ["csrc/pipe.cpp"] = { "struct Tick { int px; };", "struct Ring { int head; };", "struct Order { int qty; };",
                        "struct Adapter { bool (*submit_market_buy)(const Order&); };",
                        "static void Ring_Push(Ring* r, const Tick& t) { r->head = t.px; }",
                        "static bool Ring_Pop(Ring* r, Tick* out) { out->px = r->head; return true; }",
                        "static bool Binance_Submit(const Order& o) { return o.qty > 0; }",
                        "struct Core { Ring tick_ring; Adapter adapter; };",
                        "void FanOut(Core* core, const Tick& tick) { Ring_Push(&core->tick_ring, tick); }",
                        "void HotThreadBody(Core* core) { Tick t{0}; while (Ring_Pop(&core->tick_ring, &t)) { Order o{t.px}; core->adapter.submit_market_buy(o); } }",
                        "void Setup(Core* core) { core->adapter.submit_market_buy = &Binance_Submit; std::thread hot(HotThreadBody, core); }",
                        "void Drainer() {}", "void Sender(int n) {}",
                        "void StartAll(Pool& workers) { std::jthread j{Drainer}; workers.emplace_back(Sender, 2); }",
                        "void Produce(Core* cores) { tt::SPSCRing_TryPush(&cores->node_rings[tt::Idx{3}], Tick{1}); }",
                        "void Consume(Ring& node_ring) { Tick t; tt::SPSCRing_TryPop(&node_ring, &t); }",
                        "void Style() { ImPlot::PushStyleColor(1, 2); } void Unstyle() { ImPlot::PopStyleColor(1); }",
                        "void Short() { Ring_Push(&s, Tick{}); } void Short2() { Ring_Pop(&s, nullptr); }" },
  ["csrc/queue.cpp"] = { "#include <vector>", "namespace fox {", "class Queue {", "public:", "    void push(int x) { grow(); items.push_back(x); }",
                         "    int size() const;", "private:", "    void grow() {}", "    std::vector<int> items;", "};",
                         "int Queue::size() const { return static_cast<int>(items.size()); }", "int run(Queue& q) { q.push(1); return q.size(); }", "}" },
}
for rel, lines in pairs(sources) do
  vim.fn.mkdir(vim.fs.dirname(root .. "/" .. rel), "p")
  vim.fn.writefile(lines, root .. "/" .. rel)
end
local files = vim.tbl_keys(sources)
table.sort(files)
vim.list_extend(files, { "../outside.lua", "/etc/passwd" })
local graph = Map.syntax_graph({ root = root, files = files })
do
  -- Every call between two functions kept as a site of the one edge (the trace offers each).
  local two_root = vim.fn.tempname()
  vim.fn.mkdir(two_root .. "/lua", "p")
  vim.fn.writefile({ "local M = {}", "function M.leaf(x) return x end", "function M.twice()", "  M.leaf(1)", "  return M.leaf(2)", "end", "return M" }, two_root .. "/lua/two.lua")
  local g2 = Map.syntax_graph({ root = two_root, files = { "lua/two.lua" } })
  local e = vim.iter(g2.edges or {}):find(function(x) return x.from:find("twice", 1, true) and x.to:find("leaf", 1, true) end)
  eq(e and vim.tbl_map(function(site) return site.line end, e.sites or {}), { 4, 5 }, "two calls from twice to leaf: one edge, both its sites")
  vim.fn.delete(two_root, "rf")
end
local by_label, ids = {}, {}
for _, n in ipairs(graph.nodes) do by_label[n.label] = by_label[n.label] or n; ids[n.id] = n end
local function edge(a, b, kind)
  for _, e in ipairs(graph.edges) do
    if ids[e.from] and ids[e.to] and ids[e.from].label == a and ids[e.to].label == b and e.kind == (kind or "call-by-name") then return true end
  end
  return false
end
ok(by_label["M.alpha"] and by_label["M.beta"] and by_label["helper"], "Lua: functions by their names")
ok(by_label["M.gamma"] and by_label["delta"], "Lua: a function assigned to a name, or a table field, takes that name")
eq(by_label["M.alpha"] and { by_label["M.alpha"].file, by_label["M.alpha"].line, by_label["M.alpha"].kind }, { "lua/mod.lua", 3, "function" }, "a node's file, line and kind")
eq(graph.spans[by_label["M.alpha"].id], { 3, 5 }, "a unit's span, for what a commit touched")
ok(edge("M.alpha", "M.beta") and edge("M.alpha", "helper") and edge("M.gamma", "helper") and edge("delta", "M.gamma"), "calls by name")
ok(edge("M.beta", "M.alpha"), "a call inside an anonymous function belongs to the function around it")
local other_helper = false
for _, e in ipairs(graph.edges) do if ids[e.from].label == "use" and ids[e.to].id == "lua/other.lua::helper" then other_helper = true end end
ok(other_helper, "two functions of one name: the caller's own file wins")
ok(edge("use", "M.alpha"), "R.alpha (a module required under another name) still finds the one alpha")
ok(not edge("twice", "dup") and graph.stats.ambiguous >= 1 and graph.notes[1]:find("told apart by name", 1, true), "a name defined twice elsewhere is left out, and counted")
local chose = {}
for _, e in ipairs(graph.edges) do if ids[e.from].label == "choose" then chose[#chose + 1] = e.to end end
eq(chose, { "lua/a/one.lua::pick" }, "two functions of one name in other files: the caller's own folder wins")
ok(not ids["../outside.lua"] and graph.stats.files == #files - 2, "paths outside the root are refused")
for _, e in ipairs(graph.edges) do ok(e.kind == "call-by-name" or e.kind == "contains" or e.kind == "handoff", "every edge says it is by name, a class's member, or a handoff: " .. e.kind) end
eq(graph.complete, true, "complete when nothing was capped")

ok(by_label["square"] and by_label["norm"] and by_label["find"] and by_label["point"], "C: functions, a pointer-returning one, a struct with a body")
ok(not by_label["make"], "a declaration is no unit")
local points = 0
for _, n in ipairs(graph.nodes) do if n.label == "point" then points = points + 1 end end
eq(points, 1, "a struct named in a declaration is not a second struct")
ok(edge("norm", "square") and edge("find", "norm"), "C calls by name")
-- What a function takes and gives, for the trace: each parameter as written, how it is passed, which way data can go.
eq(by_label["norm"].params, { { name = "p", type = "struct point *", pass = "pointer", dir = "inout", reads = { "x", "y" } } },
  "C: a pointer parameter, which the callee may write through, and the fields it reads of it")
eq({ by_label["find"].returns, #by_label["find"].params, by_label["find"].params[2].pass }, { "int *", 2, "value" }, "… a pointer return, an int by value")
local function call_of(from, to)
  for _, e in ipairs(graph.edges) do if e.from:match("::(.*)$") == from and e.to:match("::(.*)$") == to then return e end end
end
eq({ call_of("find", "norm").line, call_of("find", "norm").args }, { 5, { "0" } }, "a call keeps its line and its arguments as written")
local function M_passing_cases()
  local out = {}
  for _, c in ipairs({ { true, "T", { { "&" } } }, { false, "T", { { "&" } } }, { true, "T", { { "*" } } }, { false, "T", { { "*" } } },
                       { false, "T", { { "&&" } } }, { false, "int", { { "*" }, { "&" } } }, { false, "std::unique_ptr<T>", {} }, { false, "int", {} } }) do
    local pass, dir = Map.passing(c[1], c[2], c[3])
    out[#out + 1] = pass .. "/" .. dir
  end
  return out
end
eq(M_passing_cases(), { "const ref/in", "ref/inout", "const pointer/in", "pointer/inout", "rvalue/in", "ref/inout", "smart/in", "value/in" },
  "passing: const&, &, const*, *, &&, *& (a reference to a pointer: the mark nearest the name), unique_ptr, by value")

if has_parser("python") then
  ok(by_label["Store"] and by_label["Store"].kind == "type" and by_label["Store.save"] and by_label["write"], "Python: a class, its methods, a function")
  ok(edge("Store.save", "Store.check") and edge("Store.save", "write"), "self.check is the class's own; write the module's")
  ok(edge("Store", "Store.save", "contains"), "a class contains its methods")
  ok(by_label["total"] and not edge("total", "norm"), "a Python call never reaches a C function of that name")
else skipped[#skipped + 1] = "python (no parser)" end
if has_parser("cpp") then
  ok(by_label["fox::Queue"] and by_label["fox::Queue::push"] and by_label["fox::Queue::size"] and by_label["fox::run"], "C++: names qualified by namespace and class, in and out of the class")
  ok(edge("fox::Queue::push", "fox::Queue::grow") and edge("fox::run", "fox::Queue::push") and edge("fox::run", "fox::Queue::size"), "C++ calls by name")
  ok(not edge("fox::Queue::size", "fox::Queue::size"), "items.size() inside size() is another object's size, not recursion")
  eq({ by_label["fox::run"].returns, by_label["fox::run"].params }, { "int", { { name = "q", type = "Queue &", pass = "ref", dir = "inout" } } },
    "C++: a reference parameter the callee may change")
  eq(by_label["fox::Queue::push"].params, { { name = "x", type = "int", pass = "value", dir = "in" } }, "… a method's value parameter")
  eq(call_of("fox::run", "fox::Queue::push").args, { "1" }, "… and what it is called with")
  -- Handoffs: where data or control moves without a call between the two functions.
  local function handoff(from, to)
    for _, e in ipairs(graph.edges) do
      if e.kind == "handoff" and ids[e.from] and ids[e.to] and ids[e.from].label == from and ids[e.to].label == to then return e.label end
    end
  end
  eq(handoff("FanOut", "HotThreadBody"), "tick_ring: push :9 → pop :10", "a push and a pop on one object (its last name), two functions")
  eq(handoff("HotThreadBody", "Binance_Submit"), "through submit_market_buy (set at :11)", "a call through a function pointer set elsewhere")
  eq({ handoff("Setup", "HotThreadBody"), handoff("StartAll", "Drainer"), handoff("StartAll", "Sender") },
    { "passed to thread", "passed to jthread", "passed to emplace_back" },
    "a thread started with a function: std::thread t(f, …) (read as a declaration), jthread{f}, emplace_back(f, …)")
  ok(not handoff("FanOut", "Ring_Push") and edge("FanOut", "Ring_Push"), "a direct call is a call, not also a handoff")
  eq(handoff("Produce", "Consume"), "node_rings: push :15 → pop :16",
    "a subscripted ring pushed (tt:: is a namespace: the object is the first argument), its singular popped")
  ok(not handoff("Style", "Unstyle"), "a namespace's push and pop of a style stack name no object")
  ok(not handoff("Short", "Short2"), "a one- or two-letter object is too common to mean one ring")
  -- What a function reads and writes of what it is passed (struct consumption).
  local push_params = by_label["Ring_Push"].params
  eq({ push_params[1].writes, push_params[1].reads, push_params[2].reads }, { { "head" }, nil, { "px" } }, "r->head written, t.px read")
  eq(by_label["FanOut"].params[1].reads, { "tick_ring" }, "… &core->tick_ring passed on is core's tick_ring read")
else skipped[#skipped + 1] = "cpp (no parser)" end

-- The same headless, as desk-work runs it: a request file in, the answer written to a file.
local request, answer = root .. "/request.json", root .. "/answer.json"
vim.fn.writefile({ vim.json.encode({ root = root, files = { "lua/mod.lua" } }) }, request)
local cli = vim.system({ "nvim", "--headless", "--clean", "-l", here .. "../desk/map.lua", "--syntax-graph", request, answer }, { text = true }):wait(30000)
eq(cli.code, 0, "the reader exits cleanly: " .. (cli.stderr or ""))
local decoded = vim.json.decode(table.concat(vim.fn.readfile(answer), "\n"))
eq(#decoded.nodes, 5, "headless: the same five Lua functions")
eq(vim.tbl_isempty(decoded.spans), false, "spans are an object")

-- ─── layout and levels (pure) ──────────────────────────────────────────────────────────────────────────────────
eq(Map.layers({ "a", "b", "c", "d" }, { { from = "a", to = "b" }, { from = "b", to = "c" }, { from = "c", to = "a" }, { from = "a", to = "d" } }),
  { { "a" }, { "b", "d" }, { "c" } }, "layers: callers above callees, a cycle broken once")
local modules = { ok = true, q = "module", modules = {
  { name = "lua", files = 4, functions = 9, types = 0 }, { name = "csrc", files = 2, functions = 6, types = 2 }, { name = "(library)", files = 0, functions = 3, types = 0 } },
  edges = { { from = "lua", to = "csrc", count = 2 }, { from = "csrc", to = "(library)", count = 5 } } }
local page = Map.level_modules(modules)
page.header = { { "PROJECT MAP", "DeskMapTitle" } }
local drawn = Map.layout(page, 70, false)
local lua_row, csrc_row = line_with(drawn.lines, "│ lua"), line_with(drawn.lines, "│ csrc")
ok(lua_row and csrc_row and lua_row < csrc_row, "parts in layers: lua calls csrc, so it sits above")
ok(line_with(drawn.lines, "4 files · 9 functions") and line_with(drawn.lines, "3 library functions"), "each part says its size")
ok(line_with(drawn.lines, "lua → csrc · 2"), "the calls between parts, listed")
for i, l in ipairs(drawn.lines) do ok(api.nvim_strwidth(l) <= 70, "line " .. i .. " fits") end
local _, l = line_with(drawn.lines, "│ lua")
eq(Map.item_at(drawn, lua_row, l:find("lua", 1, true)).target, { kind = "module", module = "lua" }, "a box is a hit with where Enter goes")
local many = { ok = true, modules = {}, edges = {} }
for i = 1, 70 do many.modules[i] = { name = string.format("m%02d", i), files = 1, functions = 1, types = 0 } end
ok(line_with(Map.layout(Map.level_modules(many), 100, false).lines, "+10 more · m shows them"), "past 60 boxes on a level: +N more names the key")
for i=1,15 do many.edges[i] = { from = "m01", to = ("m%02d"):format(i+1), count = 1 } end
ok(line_with(Map.layout(Map.level_modules(many), 100, false).lines, "+3 more · m shows them"),
  "show more advertises omitted connections between parts")
local expanded_modules = Map.layout(Map.level_modules(many, true), 100, false)
ok(line_with(expanded_modules.lines, "│ m70") and line_with(expanded_modules.lines, "m01 → m16"),
  "show more reveals every loaded part and connection")
ok(line_with(Map.layout(Map.level_modules(many), 100, true).lines, "+10 MORE · m SHOWS THEM"),
  "retro preserves the case of m in the show-more prompt")
local retro = Map.layout(page, 70, true)
ok(line_with(retro.lines, "┌") and not line_with(retro.lines, "╭") and line_with(retro.lines, "CALLS BETWEEN PARTS"), "retro: code page 437 boxes and capitals")
local zoom = Map.layout(vim.tbl_extend("force", page, { zoom = 2 }), 70, true)
eq(zoom.lines[2]:sub(1, #" █ DIR"), " █ DIR", "retro lights the current zoom bar itself")
ok(vim.iter(zoom.marks):any(function(m) return vim.deep_equal(m, { 2, 1, #" █", "DeskMapFocus", 1 }) end),
  "the active zoom bar has the focus colour")

local contents = { ok = true, q = "module", module = "lua",
  files = { { file = "lua/mod.lua", functions = 3, types = 0 }, { file = "lua/other.lua", functions = 2, types = 0 } },
  nodes = { { id = "lua/mod.lua::M.alpha", label = "M.alpha", file = "lua/mod.lua", line = 3, kind = "function", module = "lua" },
            { id = "lua/mod.lua::M.beta", label = "M.beta", file = "lua/mod.lua", line = 6, kind = "function", module = "lua" },
            { id = "lua/mod.lua::T", label = "T", file = "lua/mod.lua", line = 10, kind = "type", module = "lua" },
            { id = "lua/mod.lua::T.m", label = "T.m", file = "lua/mod.lua", line = 11, kind = "function", module = "lua" },
            { id = "lua/other.lua::use", label = "use", file = "lua/other.lua", line = 3, kind = "function", module = "lua" } },
  edges = { { from = "lua/other.lua::use", to = "lua/mod.lua::M.alpha", kind = "call-by-name" }, { from = "lua/mod.lua::M.alpha", to = "lua/mod.lua::M.beta", kind = "call-by-name" },
            { from = "lua/mod.lua::M.beta", to = "csrc/util.c::norm", kind = "call" }, { from = "lua/mod.lua::T", to = "lua/mod.lua::T.m", kind = "contains" } },
  outside = { { id = "csrc/util.c::norm", label = "norm", file = "csrc/util.c", line = 4, kind = "function", module = "csrc" } } }
local files_page = Map.layout(Map.level_files(contents, "lua"), 80, false)
ok(line_with(files_page.lines, "│ mod.lua") and line_with(files_page.lines, "│ other.lua"), "a part's files, named inside the part")
ok(line_with(files_page.lines, "│ other.lua") < line_with(files_page.lines, "│ mod.lua"), "other.lua calls mod.lua: above it")
ok(line_with(files_page.lines, "calls out · 1") and line_with(files_page.lines, "│ csrc"), "the parts it calls, below")
local fn_page = Map.layout(Map.level_nodes(contents, "lua", "lua/mod.lua"), 80, false)
ok(line_with(fn_page.lines, "called from · 1") and line_with(fn_page.lines, "│ use"), "who calls into the file, above")
ok(line_with(fn_page.lines, "│ M.alpha") < line_with(fn_page.lines, "│ M.beta"), "M.alpha calls M.beta: above it")
ok(line_with(fn_page.lines, "line 10 · 1 method"), "a class says its methods")
ok(line_with(fn_page.lines, "calls out · 1") and line_with(fn_page.lines, "│ norm"), "what the file calls elsewhere, below")
-- Many neighbours of many weights (a real part's): the busiest first, the cap with +N more, and a sort that holds.
local crowd = vim.deepcopy(contents)
for i = 1, 40 do
  local id = string.format("csrc/c%02d.c::caller", i)
  crowd.outside[#crowd.outside + 1] = { id = id, label = string.format("caller%02d", i), file = string.format("csrc/c%02d.c", i), line = 1, kind = "function", module = "csrc" }
  for _ = 1, (i % 7) + 1 do crowd.edges[#crowd.edges + 1] = { from = id, to = "lua/mod.lua::M.alpha", kind = "call" } end
end
local crowded_ok, crowded = pcall(function() return Map.layout(Map.level_nodes(crowd, "lua", "lua/mod.lua"), 120, false) end)
ok(crowded_ok, "forty callers of mixed weights lay out: " .. tostring(not crowded_ok and crowded or ""))
ok(crowded_ok and line_with(crowded.lines, "called from · 41") and line_with(crowded.lines, "+17 more"), "at most 24 on a side, the rest counted")
local all_sides = Map.layout(Map.level_nodes(crowd, "lua", "lua/mod.lua", nil, true), 120, false)
ok(line_with(all_sides.lines, "│ caller40") and not line_with(all_sides.lines, "+17 more"),
  "show more reveals omitted callers on a file page")
local reach = { ok = true, q = "reach", depth = 2, from = contents.nodes[5],
  nodes = { vim.tbl_extend("force", contents.nodes[5], { depth = 0 }), vim.tbl_extend("force", contents.nodes[1], { depth = 1 }), vim.tbl_extend("force", contents.nodes[2], { depth = 2 }) },
  steps = { { from = "lua/other.lua::use", to = "lua/mod.lua::M.alpha", depth = 1, mark = "follow" },
            { from = "lua/mod.lua::M.alpha", to = "lua/mod.lua::M.beta", depth = 2, mark = "capped", cycle = true } }, more = 0 }
local reach_page = Map.layout(Map.level_query(reach), 80, false)
ok(line_with(reach_page.lines, "╔") and line_with(reach_page.lines, "║ use"), "reach: the start in a double box")
ok(line_with(reach_page.lines, "║ use") < line_with(reach_page.lines, "│ M.alpha") and line_with(reach_page.lines, "│ M.alpha") < line_with(reach_page.lines, "│ M.beta"), "… then each depth below")
ok(line_with(reach_page.lines, "in a cycle · calls more"), "cycle and depth marks")
local callers = vim.tbl_extend("force", reach, { q = "callers" })
local callers_page = Map.layout(Map.level_query(callers), 80, false)
ok(line_with(callers_page.lines, "│ M.beta") < line_with(callers_page.lines, "║ use"), "callers: the farthest at the top, the function at the bottom")
local ways = Map.layout(Map.level_query({ ok = true, q = "paths", from = contents.nodes[5], to = contents.nodes[2], depth = 10, max = 20,
  paths = { { nodes = { "lua/other.lua::use", "lua/mod.lua::M.alpha", "lua/mod.lua::M.beta" }, kinds = { "call-by-name", "call" } } }, nodes = contents.nodes }), 80, false)
-- The trace page: a box per step (the function itself double), its parameters under it, the call between steps with
-- each argument → the parameter it lands in, and the other callers and callees, Enter-able.
local trace_answer = { ok = true, q = "trace", focus = "e.cpp::tick", depth = 16,
  steps = {
    { id = "e.cpp::hot", label = "hot", file = "e.cpp", line = 12, kind = "function", role = "up", returns = "void",
      params = { { name = "ring", type = "Ring &", pass = "ref", dir = "inout" } }, callers = {}, more_callers = 0, callees = {}, more_callees = 0 },
    { id = "e.cpp::tick", label = "tick", file = "e.cpp", line = 11, kind = "function", role = "focus", returns = "bool",
      params = { { name = "t", type = "const Tick &", pass = "const ref", dir = "in" } },
      callers = { { id = "e.cpp::replay", label = "replay", file = "e.cpp", line = 30 } }, more_callers = 1, callees = {}, more_callees = 0 },
    { id = "e.cpp::submit", label = "submit", file = "e.cpp", line = 10, kind = "function", role = "down", returns = "bool",
      params = { { name = "order", type = "Order &&", pass = "rvalue", dir = "in" }, { name = "retries", type = "int", pass = "value", dir = "in" } },
      callers = {}, more_callers = 0, callees = {}, more_callees = 0 } },
  calls = { { from = "e.cpp::hot", to = "e.cpp::tick", kind = "call-by-name", line = 12, args = { "t" } },
            { from = "e.cpp::tick", to = "e.cpp::submit", kind = "call-by-name", line = 11, args = { "Order{t.px}", "3" } } } }
trace_answer.steps[2].lines = 32
trace_answer.steps[2].before, trace_answer.steps[2].after = 41, 23
trace_answer.steps[2].params[1].reads, trace_answer.steps[2].params[1].writes = { "px", "ts" }, { "seq" }
local traced = Map.layout(Map.trace_page(trace_answer), 90, false)
ok(line_with(traced.lines, "trace through `tick` · 3 functions") or line_with(traced.lines, "trace through tick · 3 functions"), "the trace's heading")
ok(line_with(traced.lines, "╔═ tick ") and line_with(traced.lines, " e.cpp:11 ═╗"), "a card per step: the function it goes through double, its name and place in the top border")
ok(line_with(traced.lines, "║ → bool · 32 lines · ▲ 41 ▼ 23"), "… what it returns, how big it is, how many come before and after it")
ok(line_with(traced.lines, "▲ 41 before · ▼ 23 after it in the map"), "the function it goes through: before and after, under the heading")
local up_row, up_line = line_with(traced.lines, "▲ 41 ▼ 23")
eq(up_row and Map.item_at(traced, up_row, up_line:find("▲ 41", 1, true)).target, { kind = "walk", q = "callers", node = trace_answer.steps[2] },
  "▲ on a card: Enter opens what comes before it")
eq(up_row and Map.item_at(traced, up_row, up_line:find("▼ 23", 1, true)).target.q, "reach", "… ▼ what comes after it")
ok(line_with(traced.lines, "║ ▾ uses (1)") and line_with(traced.lines, "║     t  reads   px · ts") and line_with(traced.lines, "║        writes  seq"),
  "what it reads and writes of each parameter, open on the function it goes through")
ok(line_with(traced.lines, "║ ▸ layout (1)"), "… and its layout, folded until asked")
ok(line_with(traced.lines, "║ ▾ parameters (1)") and line_with(traced.lines, "║     in  const ref  const Tick &  t"), "its parameters, open: which way, how passed, type, name")
ok(line_with(traced.lines, "│     in  moved in  Order &&  order") and line_with(traced.lines, "│     in  value     int       retries"), "… aligned in columns")
ok(line_with(traced.lines, "│     inout  ref  Ring &  ring"), "… inout where the callee can change the caller's value")
ok(line_with(traced.lines, "║ ▸ other callers (1)") and not line_with(traced.lines, "replay"), "its other callers, folded, counted")
for i, line in ipairs(traced.lines) do
  if line:find("┌", 1, true) or line:find("╔", 1, true) then ok(api.nvim_strwidth(line) == api.nvim_strwidth(traced.lines[i + 1]), "a card's top line meets its sides: " .. line) end
end
ok(line_with(traced.lines, ":11   Order{t.px} → order · 3 → retries"), "between steps the call: its line, each argument → its parameter")
ok(line_with(traced.lines, ":12   t"), "… an argument named as its parameter is said once")
local fold_row, fold_line = line_with(traced.lines, "other callers (1)")
local fold = fold_row and Map.item_at(traced, fold_row, fold_line:find("other callers", 1, true))
eq(fold and fold.target, { kind = "fold", fold = "e.cpp::tick|callers" }, "a fold's header is a hit, to open it")
local opened = Map.layout(Map.trace_page(trace_answer, { ["e.cpp::tick|callers"] = true, ["e.cpp::tick|params"] = false }), 90, false)
ok(line_with(opened.lines, "║ ▾ other callers (1)") and line_with(opened.lines, "║     replay  e.cpp:30"), "open: one caller a line, with where it is")
ok(line_with(opened.lines, "║ ▸ parameters (1)") and not line_with(opened.lines, "const Tick &  t"), "… and the parameters folded when she closed them")
local replay_row, replay_line = line_with(opened.lines, "replay  e.cpp:30")
eq(replay_row and Map.item_at(opened, replay_row, replay_line:find("replay", 1, true)).target.node.id, "e.cpp::replay", "… each one Enter-able")
-- The layout fold, from symdeps' census of the step's file: each struct passed, its size, and the fields it touches.
eq(Map.base_type("const tt::Tick<F> &"), "Tick", "a type's own name, for the census")
local lay = { ["e.cpp::tick|layout"] = true }
ok(line_with(Map.layout(Map.trace_page(trace_answer, lay), 90, false).lines, "opening asks symdeps to lay this file out"), "layout open before an answer: says what it will do")
ok(line_with(Map.layout(Map.trace_page(trace_answer, lay, { ["e.cpp"] = { pending = true } }), 90, false).lines, "symdeps is laying this file out…"), "… while symdeps works")
do
-- A complete layout (symdeps' layoutof: every member placed and sized): two bit-fields share byte 8, the second runs on
-- into byte 9 (bits 3..12), bytes 10..15 padding.
local TICK = { name = "tt::Tick<double>", size = 32, align = 8, complete = true, members = {
  { kind = "field", name = "px", type = "double", off = 0, size = 8 },
  { kind = "bitfield", name = "flags", type = "unsigned int", off = 8, bit_lo = 0, bit_hi = 2 },
  { kind = "bitfield", name = "kind", type = "unsigned int", off = 8, bit_lo = 3, bit_hi = 12 },
  { kind = "field", name = "seq", type = "long", off = 16, size = 8 },
  { kind = "field", name = "ts", type = "long", off = 24, size = 8 } } }
local laid = Map.layout(Map.trace_page(trace_answer, lay, { ["e.cpp"] = { records = { TICK } } }), 90, false)
ok(line_with(laid.lines, "║     t  Tick  32 B, align 8 · 1 line · 6 B padding") and line_with(laid.lines, "║         touches  px@0 8 B · ts@24 8 B · seq@16 8 B"),
  "… its size, alignment, cache lines, its padding, and the fields this function touches with their offsets and sizes")
local row0 = line_with(laid.lines, " 0 │aaaaaaaa ▒c······│")
ok(row0 and line_with(laid.lines, "16 │dddddddd eeeeeeee│"), "the byte map: a letter per member over its bytes (a bit-field's by its bits), ▒ where bit-fields share one, · padding")
local function lit(drawn, row)
  local out = {}
  for _, m in ipairs(drawn.marks) do
    if m[1] == row and m[4] == "DeskMapFocus" then out[#out + 1] = drawn.lines[row]:sub(m[2] + 1, m[3]) end
  end
  return out
end
ok(line_with(laid.lines, "   0 │aaaaaaaa ▒c······│  a px 8 B  b flags 3 bits  c kind 10 bits") and line_with(laid.lines, "  16 │dddddddd eeeeeeee│  d seq 8 B  e ts 8 B"),
  "… beside each row, the members that start in it: letter, name and size")
eq(row0 and lit(laid, row0), { "aaaaaaaa", "px 8 B" }, "… the touched member's name lit with its bytes")
ok(line_with(laid.lines, "           ▒ shared  · padding"), "… and a key for the marks, under the cells")
-- A partial layout (an older symdeps, or a member symdeps could not size): its gaps are never called padding.
local partial = vim.tbl_extend("force", TICK, { complete = false, why = "no size for `seq`", members = {
  { kind = "field", name = "px", off = 0, size = 8 }, { kind = "field", name = "seq", off = 16 }, { kind = "field", name = "ts", off = 24, size = 8 } } })
local plaid = Map.layout(Map.trace_page(trace_answer, lay, { ["e.cpp"] = { records = { partial } } }), 90, false)
ok(line_with(plaid.lines, " 0 │aaaaaaaa ░░░░░░░░│") and line_with(plaid.lines, "16 │b░░░░░░░ cccccccc│") and not line_with(plaid.lines, "padding"),
  "partly laid out: bytes it cannot account for are ░, never padding")
ok(line_with(plaid.lines, "partly laid out: no size for `seq`") and line_with(plaid.lines, "b seq ?"), "… and it says why, the unknown size as ?")
-- A template whose versions differ: all said, none picked.
local float = vim.tbl_extend("force", TICK, { name = "tt::Tick<float>", size = 24 })
local vlaid = Map.layout(Map.trace_page(trace_answer, lay, { ["e.cpp"] = { records = { TICK, float, vim.deepcopy(TICK) } } }), 90, false)
ok(line_with(vlaid.lines, "t  Tick  2 versions, laid out differently") and line_with(vlaid.lines, "tt::Tick<double>  32 B, align 8")
  and line_with(vlaid.lines, "tt::Tick<float>  24 B, align 8") and not line_with(vlaid.lines, "│aaaaaaaa"), "versions that differ: each named, no byte map picked")
-- A big buffer: rows of one member fold into one line, and cache lines are marked.
local big = { name = "Ring", size = 4096, align = 64, complete = true, members = { { kind = "field", name = "head", off = 0, size = 8 },
  { kind = "field", name = "buf", off = 64, size = 4032 } } }
local bm = Map.byte_map(big, {}, false)
local bm_text = vim.tbl_map(function(r) return table.concat(vim.tbl_map(function(pt) return pt[1] end, r)) end, bm.rows)
local small = Map.byte_map({ size = 8, complete = true, members = { { name = "x", off = 0, size = 8 } } }, {}, false)
eq({ small.rows[1][1][1], bm.rows[1][1][1] }, { "       0 │", "       0 │" }, "a small struct's map and a big one's line up (one offset width)")
ok(bm_text[1]:find("0 │aaaaaaaa ········│", 1, true) and bm_text[2]:find("16 │········ ········│", 1, true), "big: the head, then its padding")
ok(vim.tbl_contains(bm_text, "         ─── line 2 ───"), "… a cache line's start marked: " .. vim.inspect(bm_text))
ok(vim.iter(bm_text):any(function(t) return t:find("… the same to byte 4095, line 64", 1, true) end) and #bm.rows < 10, "… and the buffer's 252 rows folded into one line, saying the line it ends on")
ok(vim.iter(bm_text):any(function(t) return vim.endswith(t, "… the same to byte 63") end), "… a run inside one line says no line")
end
ok(line_with(Map.layout(Map.trace_page(trace_answer, lay, { ["e.cpp"] = { error = "requires symdeps (an optional plugin for C and C++ layouts)" } }), 90, false).lines,
  "requires symdeps (an optional plugin"), "… and without symdeps, says so")
vim.g.desk_style = "retro"
local traced_retro = Map.layout(Map.trace_page(trace_answer), 90, true)
vim.g.desk_style = nil
ok(line_with(traced_retro.lines, "║     IN  CONST REF  const Tick &  t") and line_with(traced_retro.lines, "║ + OTHER CALLERS (1)")
  and line_with(traced_retro.lines, "32 LINES"), "retro: the words in capitals, the code as typed")
local unreached = Map.layout(Map.trace_page(vim.tbl_extend("force", trace_answer, { to = "e.cpp::flush", reached = false })), 90, false)
ok(line_with(unreached.lines, "tick does not reach flush within 16 calls"), "e to a function it does not reach: says so")
local unled = Map.layout(Map.trace_page(vim.tbl_extend("force", trace_answer, { start = "e.cpp::idle", start_reached = false })), 90, false)
ok(line_with(unled.lines, "idle does not lead to tick within 16 calls"), "S from a function that does not lead there: says so")
-- A busy function (the trader's draw loop has 55 other callees) and a long call stay within the page.
local busy = vim.deepcopy(trace_answer)
busy.steps[2].callees, busy.steps[2].more_callees = {}, 30
for i = 1, 8 do busy.steps[2].callees[i] = { id = "e.cpp::Callee_Number_" .. i, label = "Callee_Number_" .. i, file = "e.cpp", line = i } end
busy.calls[2].args = {}
for i = 1, 12 do busy.calls[2].args[i] = "&state->field_number_" .. i end
local busy_page = Map.layout(Map.trace_page(busy, { ["e.cpp::tick|callees"] = true }), 70, false)
local too_wide = vim.tbl_filter(function(l) return api.nvim_strwidth(l) > 70 end, busy_page.lines)
eq(too_wide, {}, "a long list of other callees and a long call stay within the page")
ok(line_with(busy_page.lines, "Callee_Number_8  e.cpp:8") and line_with(busy_page.lines, "… 22 more"), "… the list one a line, the rest counted")
do
  -- A long list of what a step reads wraps between the names inside its card, going on under the list's start.
  local busy = vim.deepcopy(trace_answer)
  local many = {}
  for i = 1, 14 do many[i] = "field_number_" .. i end
  busy.steps[2].params[1].reads = many
  local drawn = Map.layout(Map.trace_page(busy, { ["e.cpp::tick|uses"] = true }), 60, false)
  local text = table.concat(drawn.lines, "\n")
  local wide = vim.tbl_filter(function(l) return api.nvim_strwidth(l) > 60 end, drawn.lines)
  eq(wide, {}, "a long uses list stays inside a narrow page")
  ok(text:find("field_number_14", 1, true) and not text:find("field_numb…", 1, true), "… every name kept, none cut")
  local first, firstl = line_with(drawn.lines, "reads   field_number_1 ")
  local next_line = first and drawn.lines[first + 1] or ""
  local col = firstl and firstl:find("field_number_1 ", 1, true)
  ok(col and next_line:find("field_number_", 1, true) == col, "… the next line under the list's start: " .. tostring(next_line))
end
do
  -- The layout fold in either order (the second step once found no struct: the file's answer was the first's alone).
  local real_sd, real_of = package.loaded["fox-symdeps"], package.loaded["fox-symdeps.layoutof"]
  package.loaded["fox-symdeps"] = {}
  local asks, answers = {}, {}
  local LAYOUTS = { Tick = { name = "tt::Tick", size = 8, align = 8, complete = true, members = { { kind = "field", name = "px", off = 0, size = 8 } } },
                    Order = { name = "tt::Order", size = 16, align = 8, complete = true, members = { { kind = "field", name = "qty", off = 0, size = 16 } } } }
  package.loaded["fox-symdeps.layoutof"] = { of = function(_, names, done)
    asks[#asks + 1] = table.concat(names, ",")
    answers[#answers + 1] = function()
      local recs = {}
      for _, n in ipairs(names) do recs[n] = LAYOUTS[n] end
      done({ records = recs })
    end
  end }
  local function opened(order)
    asks, answers = {}, {}
    local top = { answer = trace_answer }
    local fake_view = { root = "/r", stack = {}, buf = -1, win = -1 }
    for _, id in ipairs(order) do Map.lay_out(fake_view, top, id) end
    for _, a in ipairs(answers) do a() end
    local folds = { ["e.cpp::tick|layout"] = true, ["e.cpp::submit|layout"] = true }
    local text = table.concat(Map.layout(Map.trace_page(trace_answer, folds, top.layouts), 100, false).lines, "\n")
    return { text:find("t  Tick  8 B", 1, true) ~= nil, text:find("order  Order  16 B", 1, true) ~= nil, #asks }
  end
  eq(opened({ "e.cpp::tick", "e.cpp::submit" }), { true, true, 2 }, "tick then submit: both structs laid out, each asked once")
  eq(opened({ "e.cpp::submit", "e.cpp::tick" }), { true, true, 2 }, "… submit then tick: the same two answers")
  eq(opened({ "e.cpp::tick", "e.cpp::tick" }), { true, false, 1 }, "a type already on the way is waited for, not asked twice")
  local top = { answer = trace_answer }
  asks, answers = {}, {}
  Map.lay_out({ root = "/r", stack = {}, buf = -1, win = -1 }, top, "e.cpp::tick")
  local waiting = table.concat(Map.layout(Map.trace_page(trace_answer, { ["e.cpp::tick|layout"] = true, ["e.cpp::submit|layout"] = true }, top.layouts), 100, false).lines, "\n")
  ok(waiting:find("symdeps is laying this file out", 1, true) and waiting:find("no struct it is passed is laid out", 1, true) == nil,
    "… and while it is, its step says so (not \"no struct\")")
  ok(waiting:find("opening asks symdeps to lay this file out", 1, true), "… and a step of the file not asked yet says opening asks, not \"no struct\"")
  package.loaded["fox-symdeps"], package.loaded["fox-symdeps.layoutof"] = real_sd, real_of
end
do
  -- Possible false sharing across a handoff: the producer writes px, the consumer (another thread) reads ts on its line.
  local function step(id, label, prm) return { id = id, label = label, file = "q.cpp", line = 1, params = { prm } } end
  local steps = { step("q.cpp::feed", "feed", { name = "t", type = "Tick &", pass = "ref", dir = "inout", writes = { "px" } }),
                  step("q.cpp::drain", "drain", { name = "t", type = "const Tick &", pass = "const ref", dir = "in", reads = { "ts", "px.raw" } }) }
  local calls = { { from = "q.cpp::feed", to = "q.cpp::drain", kind = "handoff", label = "tick ring" } }
  local function tick(ts_off, complete) return { ["q.cpp"] = { records = { { name = "tt::Tick", size = 128, align = 8, complete = complete ~= false,
    members = { { kind = "field", name = "px", off = 0, size = 8 }, { kind = "field", name = "ts", off = ts_off, size = 8 } } } } } } end
  local found = Map.false_sharing(steps, calls, tick(8))
  eq(found["q.cpp::feed"] and found["q.cpp::feed"].Tick, { { other = "drain", thread = "drain", here = "writes px", there = "reads ts", line = 1 } },
    "a field written on one thread on the line of a field another thread reads: noted, with the other step and its thread")
  eq(found["q.cpp::drain"] and found["q.cpp::drain"].Tick, { { other = "feed", thread = "feed", here = "reads ts", there = "writes px", line = 1 } }, "… on both steps")
  eq(Map.false_sharing(steps, { { kind = "call" } }, tick(8)), {}, "one thread (no handoff between them): nothing")
  eq(Map.false_sharing(steps, calls, tick(64)), {}, "the two fields on different lines: nothing")
  eq(Map.false_sharing(steps, calls, tick(8, false)), {}, "a layout symdeps could not place completely: nothing claimed")
  local same = vim.deepcopy(steps)
  same[2].params[1].reads = { "px" }
  eq(Map.false_sharing(same, calls, tick(8)), {}, "the same field on both sides is sharing, not false sharing: nothing")
  local page = Map.layout(Map.trace_page({ q = "trace", focus = "q.cpp::feed", steps = steps, calls = calls }, { ["q.cpp::feed|layout"] = true }, tick(8)), 120, false)
  ok(line_with(page.lines, "may share a cache line with drain on the drain thread: writes px here, reads ts there (line 1)"), "… said in the step's layout")
end
do
  -- The line under an arrow is a hit: Enter opens the call; with several, it says how many. A cycle folded on the route
  -- is said, never drawn as a call.
  local many = vim.deepcopy(trace_answer)
  many.calls[2].sites = { { line = 11, args = { "Order{t.px}", "3" } }, { line = 14, args = { "retry" } } }
  local page = Map.layout(Map.trace_page(many), 90, false)
  local row, text = line_with(page.lines, ":11 (2 calls)")
  local hit = row and Map.item_at(page, row, text:find(":11", 1, true))
  eq(hit and { hit.target.kind, hit.target.caller, hit.target.callee, #hit.target.sites }, { "call", "tick", "submit", 2 }, "a call's line is a hit, with its sites")
  local cyc = vim.deepcopy(trace_answer)
  cyc.calls[2] = { from = "e.cpp::tick", to = "e.cpp::submit", kind = "none" }
  local cpage = Map.layout(Map.trace_page(cyc), 120, false)
  ok(line_with(cpage.lines, "┄ no call from tick to submit: the route came back through a cycle here") and not line_with(cpage.lines, ":11   Order"),
    "two steps with no call between them: said, not drawn as a call")
end
do
  -- A possible path: its ends, and who chose each.
  local text = table.concat(Map.layout(Map.trace_page(trace_answer), 120, false).lines, "\n")
  ok(text:find("from hot (picked by the map: the farthest start) · to submit (picked by the map: where the calls end)", 1, true), "the route's ends, each picked by the map")
  local chosen = vim.tbl_extend("force", vim.deepcopy(trace_answer), { to = "e.cpp::submit", start = "e.cpp::hot" })
  text = table.concat(Map.layout(Map.trace_page(chosen), 120, false).lines, "\n")
  ok(text:find("from hot (your choice) · to submit (your choice)", 1, true), "… or chosen by her (S and e)")
  eq(require("desk.actions").get("map.trace").name, "Trace a possible path through this function", "t says what it answers: a possible path")
end
local handed = vim.deepcopy(trace_answer)
handed.calls[2] = { from = "e.cpp::tick", to = "e.cpp::submit", kind = "handoff", label = "tick_ring: push :11 → pop :20", line = 11, to_line = 20 }
local handed_page = Map.layout(Map.trace_page(handed), 90, false)
ok(line_with(handed_page.lines, "══[ tick_ring: push :11 → pop :20 ]══  inferred"), "a handoff between steps: what it went through, said as inferred")
ok(not line_with(handed_page.lines, ":11   Order{t.px}"), "… with no call's arguments, as there is no call")
do
  local row, text = line_with(handed_page.lines, "══[ tick_ring")
  local hit = row and Map.item_at(handed_page, row, text:find("tick_ring", 1, true))
  eq(hit and { hit.target.kind, hit.target.from, hit.target.to, hit.target.by_hand, hit.target.producer, hit.target.consumer },
    { "handoff", "e.cpp::tick", "e.cpp::submit", false, { label = "tick", file = "e.cpp", line = 11 }, { label = "submit", file = "e.cpp", line = 20 } },
    "… the handoff a hit (x drops it, Enter opens either side), naming its two ends and where each is")
  handed.calls[2].by_hand = true
  ok(line_with(Map.layout(Map.trace_page(handed), 90, false).lines, "══[ tick_ring: push :11 → pop :20 ]══  added by you"), "one she added says so")
end
local way_row, way = line_with(ways.lines, "use → M.alpha → M.beta")
ok(way_row and way:find("(by name)", 1, true), "a way, with the part found by name said")
eq(Map.item_at(ways, way_row, way:find("M.alpha", 1, true)).target.node.id, "lua/mod.lua::M.alpha", "each name on a way is a hit")

-- ─── its keys: rows of the action registry ─────────────────────────────────────────────────────────────────────
local A = require("desk.actions")
local Menu = require("desk.menu")
eq(A.problems, {}, "every map row was taken")
local function keys_of(surface) return vim.tbl_map(function(k) return k.key end, A.keys(surface)) end
eq(keys_of("map"), { "?", "<CR>", "<BS>", "-", "+", "D", "U", "c", "t", "e", "S", "x", "a", "gs", "P", "m", "M", "r", "R", "B", "q", "o", "j", "k", "h", "l" },
  "the map's keys, in order (? is the shared row; the box moves last)")
local opener = A.get("map.open")
eq(opener and { opener.key, opener.on, opener.remote, opener.group }, { "<leader>cm", "editor", true, "Project map" },
  "Space cm, a global row the pop-out may ask for")
local empty_bin = root .. "/empty-bin"   -- a PATH with no desk-work on it
vim.fn.mkdir(empty_bin, "p")
local saved_path = vim.env.PATH
vim.env.PATH = empty_bin
eq(A.available(opener, { surface = "editor" }), true, "Space cm opens the map without desk-work too (the page says what it needs)")
-- From the pop-out's home menu a view opens in the pop-out: Space cm's row would open a tab here, so there only the
-- Views row (Pop out the project map) is offered.
local function offered(ctx) return vim.tbl_map(function(r) return r.id end, A.describe(ctx)) end
local from_popout = vim.tbl_extend("force", A.context(), { surface = "callgraph", remote = true, also = { "popout" } })
eq({ vim.tbl_contains(offered(from_popout), "map.open"), vim.tbl_contains(offered(from_popout), "popout.view.map") }, { false, true },
  "asked from the pop-out: Space cm's row is not offered, the Views row that opens the map there is")
eq(A.available(opener, { surface = "callgraph" }), true, "… and in the editor's own windows it still is")
vim.env.PATH = saved_path
eq(A.available(opener, { surface = "map" }), false, "inside the map its own keys apply, not Space cm")
Map.setup()
eq(vim.fn.maparg("<leader>cm", "n", false, true).desc, "Project map", "setup binds Space cm")

-- ─── the view, with a fake desk-work ───────────────────────────────────────────────────────────────────────────
local real_desk_work = Map.desk_work
local status = { ok = true, built = true, building = false, stale = true, stale_why = "1 changed file differs from when it was built",
  head = "3789c69aaaaaaaa", built_at = os.time(), complete = true,
  providers = { { name = "syntax", state = "ok" }, { name = "binary", state = "not built", why = "requires a built binary: desk-work map build --binary PATH" } } }
local paths = { ok = true, q = "paths", from = contents.nodes[5], to = contents.nodes[2], depth = 10, max = 20, nodes = contents.nodes,
  paths = { { nodes = { "lua/other.lua::use", "lua/mod.lua::M.alpha", "lua/mod.lua::M.beta" }, kinds = { "call-by-name", "call" } } } }
local asked, building = {}, false
local function fake(args, done)
  asked[#asked + 1] = table.concat(args, " ")
  local answer
  if args[2] == "status" then answer = vim.tbl_extend("force", status, { building = building })
  elseif args[2] == "build" then building = true; answer = { ok = true, started = true }
  elseif args[2] == "query" and args[6] == "module" and args[9] == "--name" then answer = args[10] == "lua" and contents or { ok = false, message = "No part" }
  elseif args[2] == "query" and args[6] == "module" then answer = modules
  elseif args[2] == "query" and args[6] == "reach" then
    answer = vim.tbl_extend("force", reach, { depth = tonumber(args[10]) or reach.depth })
  elseif args[2] == "query" and args[6] == "paths" then answer = paths end
  vim.defer_fn(function() done(answer, { code = 0, stdout = "", stderr = "" }) end, 5)   -- never in the caller's path
end
Map.desk_work = fake
vim.fn.mkdir(root .. "/.git", "p")   -- a checkout, as Space cm finds one
vim.fn.writefile({ "-- code" }, root .. "/lua/start.lua")
vim.cmd.edit(root .. "/lua/start.lua")
local origin = api.nvim_get_current_win()
local view = Map.open(root)
ok(api.nvim_get_current_buf() == view.buf and vim.bo[view.buf].filetype == "deskmap", "the map opens in a tab of its own")
ok(vim.wait(2000, function() return view.drawn and line_with(view.drawn.lines, "│ lua") end), "the parts of the checkout")
ok(line_with(view.drawn.lines, "stale since 3789c69 · R rebuilds"), "the stale badge, naming the commit it was built at")
ok(line_with(view.drawn.lines, "1 changed file differs"), "… and why")
ok(line_with(view.drawn.lines, "answered by syntax (calls by name"), "the footer names the reader that answered")
ok(line_with(view.drawn.lines, "binary: requires a built binary"), "… and the one that did not, with what it requires")
ok(line_with(view.drawn.lines, "Enter in · BS out · D reach · U callers · P paths · ? keys · q close"),
  "the key line: the keys that matter, as their rows have them, and ? for the rest")
for i, line in ipairs(view.drawn.lines) do ok(api.nvim_strwidth(line) <= api.nvim_win_get_width(view.win), "line " .. i .. " of the view fits its window") end
eq(vim.bo[view.buf].modifiable, false, "the page is read-only")
local mapped = {}
for _, m in ipairs(api.nvim_buf_get_keymap(view.buf, "n")) do mapped[m.lhs] = m.desc end
eq({ mapped["?"], mapped["<BS>"], mapped["-"], mapped["P"] }, { "The keys here", "Zoom out, or back to the code", "Zoom out, or take a level off", "The ways between two functions" },
  "the map's buffer has the registry's keys: ? lists them, Backspace and - zoom out, P the ways")
eq({ mapped["p"], mapped["s"], mapped["o"] }, { nil, nil, "Send the map to the pop-out" },
  "p (the grammar's pin) and s (no jump labels in the map) stay free; o sends the map to the pop-out, as it does a graph")
local in_menu = {}
for _, r in ipairs(A.for_context(A.context(view.win))) do if r.menu ~= false then in_menu[r.id] = true end end
ok(in_menu["map.paths"] and in_menu["map.rebuild"] and in_menu["map.back"], "Space Space in the map: its own rows")
ok(not in_menu["map.open"] and not in_menu["map.out"], "… without Space cm (it is here) and - (Backspace's twin)")
-- A key with nothing on it, or a box not drawn, is a failure of its own and the rest still runs.
local function press(key)
  local found = vim.fn.maparg(key, "n", false, true)
  if type(found.callback) ~= "function" then return ok(false, "nothing on " .. key .. " here") end
  found.callback()
end
local function cursor_on(name)
  local row, ln = line_with(view.drawn.lines, "│ " .. name)
  if not row then return ok(false, "no box " .. name .. " on the page") end
  api.nvim_win_set_cursor(view.win, { row, (ln:find(name, 1, true)) })
end

-- ? lists the map's keys, from the same rows: Backspace and - on one line, P for the ways, and Enter runs one there.
local listed = {}
for _, l in ipairs(A.key_lines(A.context(view.win))) do listed[l.ident] = l end
eq({ listed["map.back"] and listed["map.back"].keys, listed["map.paths"] and listed["map.paths"].keys }, { { "<BS>", "-" }, { "P" } },
  "the ? list: Backspace and - on one line, P for the ways")
ok(not listed["desk.keys"], "… and not ? itself")
press("?")
local list = Menu._last
ok(list and api.nvim_win_is_valid(list.win) and vim.inspect(api.nvim_win_get_config(list.win).title):find("Keys · project map", 1, true),
  "? opens the list, titled with the place")
local list_lines = list and api.nvim_buf_get_lines(list.buf, 0, -1, false) or {}
local shown = table.concat(list_lines, "\n")
ok(shown:find("BS/-", 1, true) and shown:find("The ways between two functions", 1, true), "… keys as typed:\n" .. shown)
press("q")   -- the list's own q
eq(api.nvim_get_current_win(), view.win, "q closes the list, back in the map")

-- M: the parts in the desk menu, not a numbered list (VM test 2026-11-16): / filters them by name, Enter goes there.
local numbered, real_select = 0, vim.ui.select
vim.ui.select = function(_, _, done) numbered = numbered + 1; done(nil) end
press("M")
vim.ui.select = real_select
eq(numbered, 0, "M does not ask with vim.ui.select's numbered list")
local parts_menu = Menu._last
ok(parts_menu and parts_menu ~= list and api.nvim_win_is_valid(parts_menu.win)
  and vim.inspect(api.nvim_win_get_config(parts_menu.win).title):find("Part of the checkout", 1, true), "M opens the parts in a menu")
local function menu_text() return parts_menu and table.concat(api.nvim_buf_get_lines(parts_menu.buf, 0, -1, false), "\n") or "" end
ok(menu_text():find("csrc", 1, true) and menu_text():find("4 files · 9 functions", 1, true), "… every part, with its size:\n" .. menu_text())
local real_input = vim.ui.input
vim.ui.input = function(_, done) done("lu") end
press("/")
vim.ui.input = real_input
ok(menu_text():find("lua", 1, true) and not menu_text():find("csrc", 1, true), "/ filters them by name:\n" .. menu_text())
press("<CR>")
ok(vim.wait(2000, function() return line_with(view.drawn.lines, "│ mod.lua") end), "Enter goes to the part picked: its files")
press("<BS>")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ csrc") end), "… and Backspace back to the parts")

do
  local saved = view.cache.modules
  view.cache.modules = vim.deepcopy(many)
  Map.render(view)
  cursor_on("m05")
  local before = #asked
  ok(line_with(view.drawn.lines, "m show more"), "the map footer advertises m when boxes are left out")
  press("m")
  ok(line_with(view.drawn.lines, "│ m70") and not line_with(view.drawn.lines, "more · m"), "m reveals the rest of the parts")
  local c = api.nvim_win_get_cursor(view.win)
  local held = Map.item_at(view.drawn, c[1], c[2])
  eq({ held and held.name, #asked }, { "m05", before }, "expanding keeps selection and uses the loaded answer")
  view.cache.modules, view.stack[#view.stack].all = saved, nil
  Map.render(view)
end

-- Zoom in and out; Enter on a function goes to the code, the map left open.
cursor_on("lua")
press("<CR>")
ok(vim.wait(2000, function() return line_with(view.drawn.lines, "│ mod.lua") end), "Enter on a part: its files")
ok(line_with(view.drawn.lines, "parts › lua"), "where you are")
cursor_on("mod.lua")
press("<CR>")
ok(vim.wait(2000, function() return line_with(view.drawn.lines, "│ M.alpha") end), "Enter on a file: its functions")
ok(line_with(view.drawn.lines, "parts › lua › mod.lua"), "… one level further")
cursor_on("M.alpha")
press("<CR>")
eq(api.nvim_get_current_win(), origin, "Enter on a function goes to the code")
eq({ api.nvim_buf_get_name(0), api.nvim_win_get_cursor(0)[1] }, { root .. "/lua/mod.lua", 3 }, "… at its line")

-- From the review's tab (2026-11-16): the map opened there remembered the review's list window, and Enter put the
-- code in it, over the list. Code opens in a code window instead (desk.nav.open_code), the review left as it was.
do
  local Nav = require("desk.nav")
  Nav.setup()
  api.nvim_set_current_win(view.win)
  api.nvim_set_current_win(origin)
  eq(Nav.last_code(), origin, "the last code window is kept")
  vim.cmd("tabnew")
  vim.cmd.tcd(vim.fn.fnameescape(root))   -- the review's checkout: Space cm maps that one
  local review_tab, list = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
  vim.t[review_tab].desk_view = "review"
  local list_buf = api.nvim_create_buf(false, true)
  vim.bo[list_buf].bufhidden = "hide"   -- as the review's list: hidden, not wiped, so :edit over it succeeded
  api.nvim_win_set_buf(list, list_buf)
  press("<leader>cm")
  eq(api.nvim_get_current_win(), view.win, "Space cm from the review: the map")
  cursor_on("M.alpha")
  press("<CR>")
  eq(api.nvim_win_get_buf(list), list_buf, "Enter on a function leaves the review's list alone")
  eq({ api.nvim_get_current_win(), api.nvim_buf_get_name(0) }, { origin, root .. "/lua/mod.lua" }, "… the code opens in her code window")
  ok(not Nav.code_window(list), "a window in the review's tab is never a code window")
  api.nvim_set_current_tabpage(review_tab); vim.cmd("tabclose")
  api.nvim_set_current_win(origin)
  press("<leader>cm")
end
api.nvim_set_current_win(view.win)
press("<BS>")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ mod.lua") and not line_with(view.drawn.lines, "│ M.alpha") end), "Backspace zooms out")
press("-")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ lua") and line_with(view.drawn.lines, "│ csrc") end), "… and - too, to the parts")
eq(#vim.tbl_filter(function(a) return a:find("--name lua", 1, true) end, asked), 1, "a part read once is drawn from what was read")

-- Backspace at the top goes back to the code, the map left open; Space cm brings the same map back, as it was.
local tabs = #api.nvim_list_tabpages()
press("<BS>")
eq(api.nvim_get_current_win(), origin, "Backspace at the top goes back to the code")
ok(Map.views[view.buf] == view and api.nvim_win_is_valid(view.win), "… and leaves the map open")
vim.cmd("vsplit")
local second = api.nvim_get_current_win()
press("<leader>cm")
eq({ api.nvim_get_current_win(), #api.nvim_list_tabpages() }, { view.win, tabs }, "Space cm from the code: the same map, no second tab")
ok(#view.stack == 1 and line_with(view.drawn.lines, "│ csrc"), "… as it was")
press("<BS>")
eq(api.nvim_get_current_win(), second, "… and Backspace goes back to where Space cm was pressed")
api.nvim_win_close(second, true)
api.nvim_set_current_win(origin)
press("<leader>cm")
eq(api.nvim_get_current_win(), view.win, "back in the map")

-- A query from a key: the box under the cursor is the default, its id what desk-work is asked about.
press("<CR>")   -- back into lua (the cursor stayed on its box)
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ mod.lua") end), "into the part again")
cursor_on("mod.lua")
press("<CR>")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ use") end), "and the file")
cursor_on("use")
local prompt
vim.ui.input = function(opts, done) prompt = opts; done(opts.default) end
press("D")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "║ use") end), "D: what the function reaches")
eq(prompt.default, "use", "the prompt offers the box under the cursor")
ok(asked[#asked]:find("--q reach --from lua/other.lua::use --depth 3", 1, true), "… and asks by its id, at depth 3 without a count")
press("<BS>")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ M.alpha") end), "Backspace leaves the answer")
api.nvim_feedkeys("2D", "x", false)
ok(asked[#asked]:find("--q reach --from lua/other.lua::use --depth 2", 1, true), "a count reaches the key through the registry: 2D is depth 2")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "║ use") end), "… and shows its answer")
-- r reads the page again where it is, as r reads a call graph again (2026-11-16: r here was what it reaches): an
-- answer is asked again and replaces itself; a level of the map is read again with desk-work's status.
local depth, before_r = #view.stack, #asked
press("r")
ok(vim.wait(1000, function() return #asked >= before_r + 2 end), "r on an answer: desk-work asked again")
eq({ asked[before_r + 1]:match("^map status") ~= nil, asked[before_r + 2]:find("--q reach --from lua/other.lua::use --depth 2", 1, true) ~= nil },
  { true, true }, "… its status, then the same question")
ok(vim.wait(1000, function() return #view.stack == depth and line_with(view.drawn.lines, "║ use") end), "… the answer in its place, not one more page")
press("+")
ok(vim.wait(1000, function() return view.stack[depth].answer.depth == 3 end), "+ increases the walk depth in place")
press("-")
ok(vim.wait(1000, function() return view.stack[depth].answer.depth == 2 end), "- reduces the walk depth in place")
ok(line_with(view.drawn.lines, "+2"), "reach tiers have a signed gauge")
press("<BS>")
ok(vim.wait(1000, function() return #view.stack == depth - 1 and line_with(view.drawn.lines, "│ M.alpha") end), "Backspace leaves the depth query")
-- - on a page of one level zooms out, as on every page (review of 2026-11-17, C1: it said "Already showing the first
-- level." and stayed).
cursor_on("use")
api.nvim_feedkeys("1D", "x", false)
ok(vim.wait(1000, function() return #view.stack == depth and view.stack[depth].answer.depth == 1 end), "1D: a reach page of one level")
local said_here, real_notify = {}, vim.notify
vim.notify = function(msg, ...) said_here[#said_here + 1] = msg; return real_notify(msg, ...) end
press("-")
ok(vim.wait(1000, function() return #view.stack == depth - 1 and line_with(view.drawn.lines, "│ M.alpha") end),
  "- there zooms out, to the page it was asked on")
vim.notify = real_notify
eq(said_here, {}, "… saying nothing")
-- c on a function: the call graph centred on it, where the map is (here a graph tab), as c centres a graph.
cursor_on("M.alpha")
press("c")
local CG = require("desk.callgraph")
local graph_tab = CG.view()
eq({ graph_tab ~= nil, graph_tab and api.nvim_buf_get_name(graph_tab.buf):match("call graph · M%.alpha") ~= nil,
  graph_tab and api.nvim_get_current_win() == graph_tab.win }, { true, true, true }, "c: the graph tab, centred on the function under the cursor")
CG.close_view(graph_tab.buf)
api.nvim_set_current_win(view.win)
-- gs: the function in symdeps' card, as gs in the call graph, with the cursor on its NAME (2026-11-18: on
-- `int norm(…)` the line's first text is the return type, which symdeps would read). A fake symdeps says where it was asked.
do
  local card_at, said_gs, real_notify_gs, real_input, fake_before = nil, {}, vim.notify, vim.ui.input, Map.desk_work
  package.loaded["fox-symdeps"] = {}
  package.loaded["fox-symdeps.card"] = { inspect_cursor = function() card_at = { vim.fn.expand("%:t"), vim.fn.expand("<cword>") } end }
  vim.notify = function(msg) said_gs[#said_gs + 1] = msg end
  cursor_on("M.alpha")
  press("gs")
  eq({ card_at, said_gs[#said_gs] }, { nil, "Requires a C or C++ function." }, "gs on a Lua function: no card, and why")
  local norm = contents.outside[1]
  Map.desk_work = function(args, done)
    if args[2] == "query" and args[6] == "reach" and args[8] == norm.id then
      return vim.defer_fn(function() done({ ok = true, q = "reach", depth = 1, from = norm, more = 0, steps = {},
        nodes = { vim.tbl_extend("force", norm, { depth = 0 }) } }, { code = 0, stdout = "", stderr = "" }) end, 5)
    end
    return fake_before(args, done)
  end
  vim.ui.input = function(_, done) done(norm.id) end
  cursor_on("use")
  press("D")
  ok(vim.wait(1000, function() return line_with(view.drawn.lines, "║ norm") end), "a page with the C function norm")
  local row, ln = line_with(view.drawn.lines, "║ norm")
  if row then
    api.nvim_win_set_cursor(view.win, { row, (ln:find("norm", 1, true)) })
    press("gs")
    eq(card_at, { "util.c", "norm" }, "gs on norm: its card, asked with the cursor on norm in util.c (not on `int`)")
  end
  api.nvim_set_current_win(view.win)
  press("<BS>")
  ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ M.alpha") end), "… and back to the page it was on")
  Map.desk_work, vim.ui.input, vim.notify = fake_before, real_input, real_notify_gs
  package.loaded["fox-symdeps"], package.loaded["fox-symdeps.card"] = nil, nil
end
-- t: the trace through the box under the cursor, asked of desk-work by its id; e there: down to a function she names.
do
  local fake_before, real_input, traced_args = Map.desk_work, vim.ui.input, {}
  Map.desk_work = function(args, done)
    if args[2] == "query" and args[6] == "trace" then
      traced_args[#traced_args + 1] = table.concat(args, " ")
      if traced_args[#traced_args]:find("--line 99 ", 1, true) then
        return vim.defer_fn(function() done({ ok = false, message = "no function at e.cpp:99" }, { code = 1, stdout = "", stderr = "" }) end, 5)
      end
      return vim.defer_fn(function() done(trace_answer, { code = 0, stdout = "", stderr = "" }) end, 5)
    end
    return fake_before(args, done)
  end
  local depth_before = #view.stack
  cursor_on("M.alpha")
  press("t")
  ok(vim.wait(1000, function() return line_with(view.drawn.lines, "╔═ tick ") end), "t: the trace page, drawn")
  -- Following (the pop-out's): once the cursor rests in a code window of the checkout, outside the traced function.
  do
    local code = view.root .. "/e.cpp"
    local text = {}
    for i = 1, 120 do text[i] = "// line " .. i end
    vim.fn.writefile(text, code)
    local here = api.nvim_get_current_win()
    vim.cmd("split " .. vim.fn.fnameescape(code))
    local cw = api.nvim_get_current_win()
    api.nvim_set_current_win(here)
    local n, depth, rest = #traced_args, #view.stack, Map.FOLLOW_MS + 250
    local function moved(line) api.nvim_win_set_cursor(cw, { line, 0 }); Map.view_kind.follow(view, { type = "moved", win = cw }) end
    eq({ Map.view_kind.render(view, 90, "paper") and view.follows, Map.view_kind.follows }, { true, false }, "a trace page follows (↻), the map's kind does not")
    moved(20)
    vim.wait(rest, function() return false end)
    eq(#traced_args, n, "following: the cursor inside the traced function asks nothing")
    moved(60)
    ok(vim.wait(rest + 1000, function() return #traced_args == n + 1 end), "… out of it and resting: the trace asked again")
    ok((traced_args[n + 1] or ""):find("--q trace --file e.cpp --line 60 --from", 1, true), "… for the function under the cursor: " .. tostring(traced_args[n + 1]))
    vim.wait(200, function() return false end)
    eq(#view.stack, depth, "… in place: no page added")
    moved(61); moved(62); moved(63)
    ok(vim.wait(rest + 1000, function() return #traced_args == n + 2 end), "moves in a row: asked once, when the cursor rests")
    vim.wait(rest, function() return false end)
    eq(#traced_args, n + 2, "… and only once")
    view.pinned = true
    moved(70)
    vim.wait(rest, function() return false end)
    eq(#traced_args, n + 2, "pinned: nothing asked")
    view.pinned = false
    moved(72)
    view.pinned = true
    vim.wait(rest, function() return false end)
    eq(#traced_args, n + 2, "pinned while the cursor was settling: nothing asked")
    view.pinned = false
    Map.view_kind.follow(view, { type = "pin" })
    ok(vim.wait(1000, function() return #traced_args == n + 3 end), "p again: it follows from where the cursor is")
    local said, real_notify = {}, vim.notify
    vim.notify = function(m) said[#said + 1] = m end
    moved(99)
    ok(vim.wait(rest + 1000, function() return #traced_args == n + 4 end), "the cursor in no function: asked")
    vim.wait(200, function() return false end)
    vim.notify = real_notify
    eq({ said, #view.stack, line_with(view.drawn.lines, "╔═ tick ") ~= nil }, { {}, depth, true }, "… and quiet: nothing said, the trace kept")
    local outside = vim.fn.tempname() .. ".cpp"
    vim.fn.writefile({ "int x;" }, outside)
    api.nvim_win_call(cw, function() vim.cmd("edit " .. vim.fn.fnameescape(outside)) end)
    moved(1)
    vim.wait(rest, function() return false end)
    eq(#traced_args, n + 4, "a file outside the checkout: nothing asked")
    api.nvim_win_close(cw, true)
    for i = #traced_args, n + 1, -1 do table.remove(traced_args, i) end -- the checks below count from t's ask
  end
  -- x on a handoff drops it (one the map got wrong), a on a step adds one; desk-work keeps them, the trace is asked again.
  do
    local n, corrections, saved_call = #traced_args, {}, trace_answer.calls[2]
    trace_answer.calls[2] = { from = "e.cpp::tick", to = "e.cpp::submit", kind = "handoff", label = "tick_ring", line = 11 }
    local inner = Map.desk_work
    Map.desk_work = function(args, done)
      if args[2] == "handoff" then
        corrections[#corrections + 1] = table.concat(args, " ")
        return vim.defer_fn(function() done({ ok = true, did = args[3] == "add" and "added" or "dropped", file = "/c/foxml/desk.d/map-x.json" }, { code = 0 }) end, 5)
      end
      return inner(args, done)
    end
    press("r")
    ok(vim.wait(1000, function() return line_with(view.drawn.lines, "══[ tick_ring ]══  inferred") end), "the trace with a handoff, read again")
    vim.wait(300, function() return false end) -- r reads the status too: its redraw lands before the cursor is placed
    local said, real_notify, real_input = {}, vim.notify, vim.ui.input
    vim.notify = function(m) said[#said + 1] = m end
    local hrow, htext = line_with(view.drawn.lines, "══[ tick_ring")
    api.nvim_win_set_cursor(view.win, { hrow, (htext:find("tick_ring", 1, true)) })
    vim.ui.input = function(opts, done) eq(opts.prompt, "Drop this handoff (it is wrong)? y/n: ", "x asks first"); done("n") end
    press("x")
    vim.wait(200, function() return false end)
    eq(corrections, {}, "… no: nothing dropped")
    local asked_before = #traced_args
    vim.ui.input = function(_, done) done("y") end
    press("x")
    ok(vim.wait(1000, function() return #corrections == 1 end), "… yes: desk-work drops it")
    eq(corrections[1], "map handoff drop --root " .. view.root .. " --from e.cpp::tick --to e.cpp::submit", "… that handoff, by its two ends")
    ok(vim.wait(1000, function() return #traced_args == asked_before + 1 end), "… and the trace is asked again")
    ok(vim.iter(said):any(function(m) return m:find("Handoff dropped", 1, true) ~= nil end), "… saying what it did: " .. vim.inspect(said))
    local trow, ttext = line_with(view.drawn.lines, "╔═ tick ")
    api.nvim_win_set_cursor(view.win, { trow, (ttext:find("tick", 1, true)) })
    vim.ui.input = function(opts, done) eq(opts.prompt, "Hands off to: ", "a asks where to"); done("consumer") end
    press("a")
    ok(vim.wait(1000, function() return #corrections == 2 end), "a on a step: desk-work adds a handoff")
    eq(corrections[2], "map handoff add --root " .. view.root .. " --from e.cpp::tick --to consumer", "… from that step to the one named")
    vim.wait(200, function() return false end)
    -- Enter on a call with two sites: both offered, each with its source line; the one chosen opened.
    local real_select, offered = vim.ui.select, nil
    vim.ui.select = function(items, opts, done) offered = vim.tbl_map(opts.format_item, items); done(items[2]) end
    trace_answer.calls[2] = { from = "e.cpp::tick", to = "e.cpp::submit", kind = "call-by-name", line = 11, args = { "t" },
      sites = { { line = 11, args = { "t" } }, { line = 14, args = { "u" } } } }
    press("r")
    ok(vim.wait(1000, function() return line_with(view.drawn.lines, ":11 (2 calls)") end), "a call with two sites, drawn")
    vim.wait(300, function() return false end)
    local crow, ctext = line_with(view.drawn.lines, ":11 (2 calls)")
    api.nvim_win_set_cursor(view.win, { crow, (ctext:find(":11", 1, true)) - 1 })
    press("<CR>")
    eq(offered, { "// line 11  e.cpp:11", "// line 14  e.cpp:14" }, "Enter on it: each call offered with its source line and place")
    ok(vim.wait(1000, function() return vim.endswith(api.nvim_buf_get_name(0), "/e.cpp") and api.nvim_win_get_cursor(0)[1] == 14 end),
      "… the one chosen opened at its line: " .. api.nvim_buf_get_name(0) .. ":" .. api.nvim_win_get_cursor(0)[1])
    api.nvim_set_current_win(view.win)
    -- Enter on a handoff: its producer (the push) or its consumer (the pop).
    trace_answer.calls[2] = { from = "e.cpp::tick", to = "e.cpp::submit", kind = "handoff", label = "ring", line = 11, to_line = 20 }
    press("r")
    ok(vim.wait(1000, function() return line_with(view.drawn.lines, "══[ ring ]══") end), "the handoff drawn")
    vim.wait(300, function() return false end)
    local hr, ht = line_with(view.drawn.lines, "══[ ring ]══")
    api.nvim_win_set_cursor(view.win, { hr, (ht:find("ring", 1, true)) })
    press("<CR>")
    eq(offered, { "where it is handed over: tick  e.cpp:11", "where it is taken: submit  e.cpp:20" }, "Enter on a handoff: its producer and its consumer")
    ok(vim.wait(1000, function() return vim.endswith(api.nvim_buf_get_name(0), "/e.cpp") and api.nvim_win_get_cursor(0)[1] == 20 end), "… the consumer opened at the pop")
    api.nvim_set_current_win(view.win)
    -- A field in a step's uses: Enter follows it — on this route, its declaration, who writes it.
    local code_lines = vim.fn.readfile(view.root .. "/e.cpp")
    code_lines[15] = "  return t.px > 0;"
    vim.fn.writefile(code_lines, view.root .. "/e.cpp")
    for _, b in ipairs(api.nvim_list_bufs()) do if vim.endswith(api.nvim_buf_get_name(b), "/e.cpp") then pcall(vim.cmd, "checktime " .. b) end end
    local choice_of
    vim.ui.select = function(items, opts, done)
      offered = vim.tbl_map(opts.format_item, items)
      for _, it in ipairs(items) do if it.id == choice_of then return done(it) end end
      done(items[1])
    end
    local function on_px()
      local r, l = line_with(view.drawn.lines, "reads   px")
      if not r then r, l = line_with(view.drawn.lines, "reads   ◆ px") end
      api.nvim_win_set_cursor(view.win, { r, (l:find("px", l:find("reads", 1, true), true)) - 1 })
    end
    on_px()
    choice_of = "route"
    press("<CR>")
    eq(offered and #offered, 3, "Enter on a field: three ways to follow it")
    ok(vim.wait(1000, function() return line_with(view.drawn.lines, "◆ Tick.px") and line_with(view.drawn.lines, "on this route: written by none · read by tick (by name, within Tick)") end),
      "on this route: the field marked, who writes and reads it said (by name): " .. table.concat(view.drawn.lines, "\n"):sub(1, 400))
    ok(line_with(view.drawn.lines, "reads   ◆ px"), "… and marked where each step reads or writes it")
    said = {}
    on_px()
    choice_of = "decl"
    press("<CR>")
    ok(vim.wait(1000, function() return vim.endswith(api.nvim_buf_get_name(0), "/e.cpp") and api.nvim_win_get_cursor(0)[1] == 15 end), "its declaration: the field's use in the step's code first")
    ok(vim.iter(said):any(function(m) return m:find("Requires a language server", 1, true) ~= nil end), "… and without a language server, says so")
    api.nvim_set_current_win(view.win)
    package.loaded["fox-symdeps"] = {}
    package.loaded["fox-symdeps.writers"] = { for_symbol = function(ctx2, cb)
      cb({ sites = { { file = view.root .. "/e.cpp", line = 30, scope = "feed" } }, reads = 2 }, "ok")
    end }
    on_px()
    choice_of = "writers"
    press("<CR>")
    ok(vim.wait(1000, function() return api.nvim_win_get_cursor(0)[1] == 30 end), "who writes it: symdeps' write sites, the one chosen opened")
    package.loaded["fox-symdeps"], package.loaded["fox-symdeps.writers"] = nil, nil
    api.nvim_set_current_win(view.win)
    vim.ui.select = real_select
    vim.notify, vim.ui.input, Map.desk_work = real_notify, real_input, inner
    trace_answer.calls[2] = saved_call
    for i = #traced_args, n + 1, -1 do table.remove(traced_args, i) end
  end
  -- Enter on a fold's header opens it there, the cursor staying on the header.
  local fold_row, fold_line = line_with(view.drawn.lines, "other callers (1)")
  api.nvim_win_set_cursor(view.win, { fold_row, (fold_line:find("other callers", 1, true)) })
  press("<CR>")
  ok(vim.wait(1000, function() return line_with(view.drawn.lines, "replay  e.cpp:30") end), "Enter on a fold: open")
  eq(api.nvim_win_get_cursor(view.win)[1], line_with(view.drawn.lines, "other callers (1)"), "… the cursor still on its header")
  press("<CR>")
  ok(vim.wait(1000, function() return not line_with(view.drawn.lines, "replay  e.cpp:30") end), "… and Enter again closes it")
  -- Opening the layout asks symdeps' census of the step's file once; its answer fills the page.
  local censused = {}
  package.loaded["fox-symdeps"] = {}
  package.loaded["fox-symdeps.recordlayout"] = { census = function(buf, done)
    censused[#censused + 1] = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
    vim.defer_fn(function() done({ records = { { name = "Tick", size = 24, align = 8, fields = { { name = "px", off = 0 } } },
      { name = "Ring", size = 16, align = 8, fields = { { name = "head", off = 0 } } } } }) end, 5)
  end }
  local lay_row, lay_line = line_with(view.drawn.lines, "layout (1)")
  api.nvim_win_set_cursor(view.win, { lay_row, (lay_line:find("layout", 1, true)) })
  press("<CR>")
  ok(vim.wait(1000, function() return line_with(view.drawn.lines, "Ring  16 B, align 8") end), "Enter on layout: symdeps lays the file out, the page shows it")
  eq(censused, { "e.cpp" }, "… asked once, of the step's file")
  package.loaded["fox-symdeps.recordlayout"] = nil
  -- A symdeps with layoutof: asked for the step's parameter types only, and its field sizes shown.
  local asked_of
  package.loaded["fox-symdeps.layoutof"] = { of = function(path, names, done)
    asked_of = { vim.fn.fnamemodify(path, ":t"), names }
    vim.defer_fn(function() done({ records = { Ring = { name = "tt::Ring", size = 16, align = 8, complete = true, members = { { kind = "field", name = "head", off = 0, size = 8 } },
      variants = { { name = "tt::Ring", size = 16, align = 8, complete = true, members = { { kind = "field", name = "head", off = 0, size = 8 } } },
        { name = "tt::Ring2", size = 16, align = 8, complete = true, members = {} } } } } }) end, 5)
  end }
  local top = view.stack[#view.stack]
  top.layouts = nil
  local tick_lay_row, tick_lay_line
  for i, l in ipairs(view.drawn.lines) do if l:find("layout (", 1, true) then tick_lay_row, tick_lay_line = i, l; break end end
  api.nvim_win_set_cursor(view.win, { tick_lay_row, (tick_lay_line:find("layout", 1, true)) })
  press("<CR>")
  press("<CR>")
  ok(vim.wait(1000, function() return asked_of ~= nil end), "with layoutof: symdeps is asked through it")
  eq(asked_of, { "e.cpp", { "Ring" } }, "… for the step's file and its parameters' types only")
  ok(vim.wait(1000, function() return line_with(view.drawn.lines, "Ring  16 B, align 8 · 1 line · 8 B padding") end), "… its answer drawn, complete: " .. vim.inspect(view.drawn.lines))
  package.loaded["fox-symdeps"], package.loaded["fox-symdeps.layoutof"] = nil, nil
  ok(traced_args[1] and traced_args[1]:find("--q trace --from lua/mod.lua::M.alpha", 1, true), "… asked through the box's function: " .. tostring(traced_args[1]))
  vim.ui.input = function(opts, done) eq(opts.prompt, "Trace to: ", "e asks where to"); done("submit") end
  press("e")
  ok(vim.wait(1000, function() return #traced_args == 2 and #view.stack == depth_before + 2 end), "e: asked again, its answer a page of its own")
  ok(traced_args[2] and traced_args[2]:find("--from e.cpp::tick --to submit", 1, true), "… from the same function, down to the one named: " .. tostring(traced_args[2]))
  -- Enter on ▲: the callers page from that step, three levels, a page of its own (Backspace back).
  local walked
  local fake_trace = Map.desk_work
  Map.desk_work = function(args, done)
    if args[2] == "query" and args[6] == "callers" then walked = table.concat(args, " ") end
    return fake_trace(args, done)
  end
  local up_row2, up_line2 = line_with(view.drawn.lines, "▲ 41 ▼ 23")
  api.nvim_win_set_cursor(view.win, { up_row2, (up_line2:find("▲ 41", 1, true)) })
  press("<CR>")
  ok(vim.wait(1000, function() return walked ~= nil end), "Enter on ▲: the callers page asked")
  ok(walked and walked:find("--q callers --from e.cpp::tick --depth 3", 1, true), "… from that step, three levels: " .. tostring(walked))
  Map.desk_work = fake_trace
  vim.wait(200, function() return false end)
  if #view.stack > depth_before + 2 then press("<BS>") end
  -- S: the same trace up from a start she names, the end she chose kept.
  trace_answer.to = "submit"
  vim.ui.input = function(opts, done) eq(opts.prompt, "Trace from: ", "S asks where from"); done("hot") end
  press("S")
  ok(vim.wait(1000, function() return #traced_args == 3 and #view.stack == depth_before + 3 end), "S: asked again, a page of its own")
  ok(traced_args[3] and traced_args[3]:find("--from e.cpp::tick --to submit --start hot", 1, true), "… from the same function, the end kept, from the start named: " .. tostring(traced_args[3]))
  -- S with a name that fits several: the desk menu, each with its signature and place; the one chosen goes back in as the
  -- start (it once replaced the focus: the picker read only "To:").
  do
    local inner, real_select, offered = Map.desk_work, vim.ui.select, nil
    Map.desk_work = function(args, done)
      if table.concat(args, " "):find("--start dup", 1, true) then
        traced_args[#traced_args + 1] = table.concat(args, " ")
        return vim.defer_fn(function() done({ ok = false, message = "Start: Several things in the map are named dup; pick one", flag = "--start",
          candidates = { { id = "a.cpp::dup", label = "ns::dup", file = "a.cpp", line = 3, params = { { name = "x", type = "int" } }, returns = "bool" },
        { id = "b.cpp::dup", label = "other::dup", file = "b.cpp", line = 9 } } }, { code = 1 }) end, 5)
      end
      return inner(args, done)
    end
    vim.ui.select = function(items, opts, done)
      offered = { prompt = opts.prompt, shown = vim.tbl_map(opts.format_item, items) }
      done(items[2])
    end
    vim.ui.input = function(_, done) done("dup") end
    local n = #traced_args
    press("S")
    ok(vim.wait(1000, function() return #traced_args == n + 2 end), "S with an ambiguous name: asked, then asked again with the one chosen")
    eq(offered, { prompt = "Start: Several things in the map are named dup; pick one", shown = { "ns::dup(int) → bool  a.cpp:3", "other::dup  b.cpp:9" } },
      "… the menu: each with its signature where known, and its place")
    ok((traced_args[n + 2] or ""):find("--from e.cpp::tick --to submit --start b.cpp::dup", 1, true), "… the one chosen is the start, the focus and end kept: " .. tostring(traced_args[n + 2]))
    vim.wait(100, function() return false end)
    press("<BS>")
    Map.desk_work, vim.ui.select = inner, real_select
  end
  trace_answer.to = nil
  press("<BS>"); press("<BS>"); press("<BS>")
  ok(vim.wait(1000, function() return #view.stack == depth_before end), "Backspace goes back off the traces")
  Map.desk_work, vim.ui.input = fake_before, real_input
end
before_r = #asked
local function box_here() local c = api.nvim_win_get_cursor(view.win); local it = Map.item_at(view.drawn, c[1], c[2]); return it and it.name end
local box_before = box_here()
press("r")
ok(vim.wait(1000, function() return #asked >= before_r + 2 end), "r on a level of the map")
eq({ asked[before_r + 1]:match("^map status") ~= nil, asked[before_r + 2]:find("--q module", 1, true) ~= nil }, { true, true },
  "… its status, then that level read again")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ M.alpha") end), "… and drawn again")
eq({ box_here() ~= nil, box_here() }, { true, box_before }, "… the cursor on the box it was on")
-- P: the ways from the box under the cursor to a function she names.
local prompts = {}
vim.ui.input = function(opts, done) prompts[#prompts + 1] = opts.prompt; done(#prompts == 1 and opts.default or "M.beta") end
cursor_on("use")
press("P")
eq(prompts, { "Ways from: ", "… to: " }, "P asks for the ways: from the box under the cursor, to a function")
ok(asked[#asked]:find("--q paths --from lua/other.lua::use --to M.beta", 1, true), "… and asks desk-work for them")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "ways from use to M.beta") end), "… and shows them")
press("<BS>")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ M.alpha") end), "Backspace leaves the ways")
-- Enter on a row of the ? list runs it in the map, as the menus run it: P asks its one question, where to, and goes
-- from the box under the cursor.
prompts = {}
vim.ui.input = function(opts, done) prompts[#prompts + 1] = opts.prompt; done(opts.prompt == "Ways to: " and "M.beta" or opts.default) end
cursor_on("use")
press("?")
list = Menu._last
local open_again = list and api.nvim_win_is_valid(list.win) and api.nvim_get_current_win() == list.win
ok(open_again, "? opens the list again")
for i, l in ipairs(open_again and api.nvim_buf_get_lines(list.buf, 0, -1, false) or {}) do
  if l:find("The ways between two functions", 1, true) then api.nvim_win_set_cursor(list.win, { i, 0 }) end
end
if open_again then press("<CR>") end
ok(vim.wait(1000, function() return asked[#asked]:find("--q paths --from lua/other.lua::use --to M.beta", 1, true) ~= nil end),
  "Enter on a line of the ? list runs it in the map")
eq(prompts, { "Ways to: " }, "… asking its row's question, from the box under the cursor")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "ways from use to M.beta") end), "… and the map shows it")
api.nvim_set_current_win(view.win)
press("<BS>")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ M.alpha") end), "back from the ways")

-- Rebuild: started in the background; the page says so, asks for the status until the build is done, then reads again.
Map.POLL_MS = 20
press("R")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "rebuilding") end), "R: the page says it is rebuilding")
ok(vim.tbl_contains(asked, "map build --root " .. root), "… having asked desk-work to build")
local reads = #vim.tbl_filter(function(a) return a:find("--name lua", 1, true) end, asked)
status.stale, status.stale_why, status.head = false, "", "4444444bbbbbbbb"
building = false
local blank = false
ok(vim.wait(3000, function()
  if not line_with(view.drawn.lines, "│ M.alpha") then blank = true end
  return view.timer == nil and line_with(view.drawn.lines, "built ") and line_with(view.drawn.lines, "at 4444444") and true or false
end), "when the build is done the badge says built, at the new commit")
ok(vim.wait(1000, function() return #vim.tbl_filter(function(a) return a:find("--name lua", 1, true) end, asked) > reads end), "… and the level is read again")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ M.alpha") ~= nil end), "… and drawn")
eq(blank, false, "the page never went blank while the build ran and the map was read again")

-- After the build a work event (an agent saving files, up to once a second) is no news for the map: desk-work is asked
-- nothing and the cursor stays on its box. Each one read the map again and put the cursor on the first box (2026-11-16).
local function box_here()
  local c = api.nvim_win_get_cursor(view.win)
  local item = Map.item_at(view.drawn, c[1], c[2])
  return item and item.name
end
local function level_reads() return #vim.tbl_filter(function(a) return a:find("--name lua", 1, true) end, asked) end
ok(vim.wait(1000, function() return view.cache["module:lua"] ~= nil end), "(the level read after that build is in)")
cursor_on("M.alpha")
local before_event = #asked
api.nvim_exec_autocmds("User", { pattern = "FoxWorkChanged", data = { root = view.root } })
vim.wait(300)
eq({ #asked - before_event, box_here() }, { 0, "M.alpha" }, "a work event after the build: nothing asked, the cursor on its box")
-- A build that ends reads the level again, and the cursor stays on the box it was on.
local reads_before = level_reads()
press("R")
building = false
ok(vim.wait(3000, function() return view.timer == nil and level_reads() > reads_before and view.cache["module:lua"] ~= nil end),
  "another build ends: the level is read again")
eq(box_here(), "M.alpha", "… and the cursor is still on the box it was on, not the first")

-- j/k go box to box (a box is several lines; line by line left the cursor in the gaps between them, 2026-11-16).
local function on_a_name()
  local c = api.nvim_win_get_cursor(view.win)
  for _, b in ipairs(view.drawn.items) do if b.line == c[1] and (b.name_col or 0) == c[2] then return b end end
end
cursor_on("M.alpha")
press("j")
local below = box_here()
ok(below and below ~= "M.alpha" and on_a_name(), "j: the next box down, the cursor on its name (got " .. tostring(below) .. ")")
local alpha_line = (function() for _, b in ipairs(view.drawn.items) do if b.item and b.item.name == "M.alpha" then return b.line end end end)()
press("k")
local up = on_a_name()
ok(up and up.line == alpha_line, "k: back up into M.alpha's row (the box nearest by centre, as in the call graph), on its name")
api.nvim_win_set_cursor(view.win, { #view.drawn.lines, 0 })
press("k")
ok(box_here() and on_a_name(), "from a gap or the bottom, k lands on a box")

-- The box under the cursor is drawn selected in the tab too, as in the call graph and the pop-out (2026-11-16: only
-- the cursor showed where she was).
local function painted()
  local G = require("desk.callgraph")
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(view.buf, G.sel_ns, 0, -1, { details = true })) do
    if m[4].hl_group == "DeskCallGraphSelected" then out[#out + 1] = m[2] + 1 end
  end
  return out
end
cursor_on("M.alpha")
api.nvim_exec_autocmds("CursorMoved", { buffer = view.buf })
local alpha_box = (function() for _, b in ipairs(view.drawn.items) do if b.item and b.item.name == "M.alpha" then return b end end end)()
local lit = painted()
ok(#lit > 0 and vim.tbl_contains(lit, alpha_box.spans[1][1]), "the box under the cursor is drawn selected (lines " .. vim.inspect(lit) .. ")")
ok(next(api.nvim_get_hl(0, { name = "DeskCallGraphSelected" })) ~= nil, "… in a colour that is defined with no call graph opened (in the VM it was empty)")
press("j")
api.nvim_exec_autocmds("CursorMoved", { buffer = view.buf })
ok(not vim.tbl_contains(painted(), alpha_box.spans[1][1]), "… and j moves the selection off it")

vim.g.desk_style = "retro"
Map.render(view)
ok(line_with(view.drawn.lines, "PROJECT MAP") and line_with(view.drawn.lines, "┌"), "retro: the page in capitals and code page 437 boxes")
-- Retro shouts words, not code: a commit's hash and a function's name stay as they are.
local retro_said = function(st) return table.concat(vim.tbl_map(function(h) return h[1] end, Map.header({ root = root, status = st }, Map.glyphs(true))), "\n") end
ok(retro_said({ ok = true, built = true, stale = true, head = "3789c69aaaa" }):find("STALE SINCE 3789c69 · R REBUILDS", 1, true),
  "retro: the stale badge shouts, its hash stays as it is")
ok(retro_said({ ok = true, built = true, stale = false, head = "abcdef0123", built_at = os.time() }):find(" AT abcdef0", 1, true),
  "… and the built badge's")
local titled = Map.header({ root = "/srv/checkouts/Linux_Theme", status = { ok = true, built = true, head = "abc", built_at = os.time() } }, Map.glyphs(true))
eq(titled[1][1], "PROJECT MAP · Linux_Theme", "… and the checkout's folder, a name, keeps its case")
ok(line_with(view.drawn.lines, "BINARY: REQUIRES A BUILT BINARY: desk-work map build --binary PATH"),
  "… and the command a reader's note names is left as typed:\n" .. table.concat(view.drawn.lines, "\n"))
local retro_reach = table.concat(Map.layout(Map.level_query(reach), 80, true).lines, "\n")
local retro_ways = table.concat(Map.layout(Map.level_query({ ok = true, q = "paths", from = contents.nodes[5], to = contents.nodes[2], paths = {} }), 80, true).lines, "\n")
ok(retro_reach:find("WHAT use REACHES · DEPTH 2", 1, true) and retro_ways:find("WAYS FROM use TO M.beta · 0", 1, true),
  "… and so do the functions a query names:\n" .. retro_reach:sub(1, 300))ok(line_with(view.drawn.lines, "Enter IN · BS OUT · D REACH · U CALLERS · P PATHS · ? KEYS · q CLOSE"),
  "retro: the keys as typed (keys keep their case: P and p are two keys), the words in capitals")
ok(line_with(view.drawn.lines, "parts » lua » mod.lua") and not line_with(view.drawn.lines, "›") and not line_with(view.drawn.lines, "…"),
  "retro: nothing outside code page 437 (» between the levels, .. for an ellipsis)")
vim.g.desk_style = "paper"
press("q")
eq(Map.views[view.buf], nil, "q closes the map")

-- ─── in the pop-out: the map as desk.popout's view kind 'map' ──────────────────────────────────────────────────
-- Driven as desk.popout drives a kind: its view registered with the host, its keys run through the registry with the
-- ctx its ctx_for gives (what the bridge's act does), the history walked with the host's H and L. Nothing is sent
-- anywhere but, at the end, through the bridge to this Neovim itself. No kitty, hyprctl or desk-work on PATH here.
local P = require("desk.popout")
local K = P.kinds.map
eq(K, Map.view_kind, "the map is the pop-out's view kind 'map'")
vim.env.PATH = empty_bin
local unsaid = {}
for _, r in ipairs(A.rows()) do
  local on = type(r.on) == "table" and r.on or { r.on }
  if vim.tbl_contains(on, "map") and not r.drawn and r.remote == nil then unsaid[#unsaid + 1] = r.id end
end
eq(unsaid, {}, "every row on the map says where it runs for the pop-out: drawn, remote, or remote = false")
local there, clashes = A.popout_rows("map")
eq(clashes, {}, "no map row is on a key the pop-out's own rows take (H, L, gt, gT, Backspace, q, p, o, f, ?)")
local remote_ids = {}
for _, r in ipairs(there) do if r.id:match("^map%.") then remote_ids[#remote_ids + 1] = r.id end end
table.sort(remote_ids)
eq(remote_ids, { "map.callers", "map.centre", "map.down", "map.expand", "map.handoff-add", "map.handoff-drop", "map.in", "map.left", "map.more", "map.out", "map.paths", "map.reach", "map.read", "map.rebuild", "map.right", "map.symdeps", "map.trace", "map.trace-from", "map.trace-to", "map.up" },
  "the pop-out can show more and retains its existing navigation keys")
-- An answer goes to the pop-out it was asked from: t on pop-out 2's graph traces in pop-out 2's map, never pop-out 1's.
do
  local real_P, real_dw = package.loaded["desk.popout"], Map.desk_work
  local repo = vim.fs.root(debug.getinfo(1, "S").source:sub(2), ".git")
  local shown_in, asked = {}, nil
  local maps = { [1] = { out = true, pop = 1, root = repo, stack = { { kind = "modules" } }, cache = {} } }
  package.loaded["desk.popout"] = setmetatable({
    show = function(name, ctx, opts)
      shown_in[#shown_in + 1] = { name, opts.pop, ctx.map_root }
      maps[opts.pop] = maps[opts.pop] or { out = true, pop = opts.pop, root = ctx.map_root, stack = { { kind = "modules" } }, cache = {} }
    end,
    view_of = function(name, pop) if pop then return maps[pop] end; return maps[1] end,
    holds = function(v) return v ~= nil end,
  }, { __index = real_P })
  Map.desk_work = function(args, done) asked = { args = table.concat(args, " "), root = args[4] }; done({ ok = false, message = "stub" }, { code = 1 }) end
  local said, real_notify = {}, vim.notify
  vim.notify = function(m) said[#said + 1] = m end
  Map.trace_at(repo .. "/shared/nvim_lua/desk/map.lua", 10, { pop = 2 })
  vim.notify = real_notify
  eq(shown_in, { { "map", 2, repo } }, "asked from pop-out 2: the map shown in pop-out 2, for that checkout")
  ok(asked and asked.args:find("--q trace --file shared/nvim_lua/desk/map.lua --line 10", 1, true) and maps[2] ~= nil, "… and the trace asked there: " .. vim.inspect(asked))
  package.loaded["desk.popout"], Map.desk_work = real_P, real_dw
end
local views_row = A.get("popout.view.map")
eq(views_row and { views_row.group, views_row.name, views_row.remote }, { "Views", "Pop out the project map", true },
  "a row in Views opens it from anywhere, the pop-out too")
local function item_named(drawn, name) for i, it in ipairs(drawn.items) do if it.name == name then return it, i end end end

-- o in the tab: what the pop-out needs, then o's work as desk.popout does it once the pop-out can open (M.show calls
-- the kind's open): the map leaves its tab, at the level it was on.
local tab = Map.open(root)
ok(vim.wait(2000, function() return tab.drawn and line_with(tab.drawn.lines, "│ lua") end), "a map in its tab")
eq(A.available(A.get("map.popout"), A.context(tab.win)), "requires kitty", "o says what the pop-out needs (here kitty)")
eq(K.available({ surface = "map" }), false, "in the map's tab its own o sends it, not the Views row")
do
  local row, ln = line_with(tab.drawn.lines, "│ lua")
  api.nvim_win_set_cursor(tab.win, { row, (ln:find("lua", 1, true)) })
end
press("<CR>")
ok(vim.wait(1000, function() return line_with(tab.drawn.lines, "│ mod.lua") end), "… zoomed into a part")
local tab_root, tab_buf = tab.root, tab.buf
local pv = { id = "map", kind = "map", gen = 0, pinned = false }
P.host.views, P.host.order, P.host.history = { map = pv }, { "map" }, { steps = {}, at = 0 }
K.open(pv, A.context(tab.win))
ok(Map.views[tab_buf] == nil and not api.nvim_buf_is_valid(tab_buf), "o: the map leaves its tab")
eq({ pv.out, pv.root, #pv.stack, pv.stack[2] and pv.stack[2].module }, { true, tab_root, 2, "lua" }, "… for the pop-out, at the level it was on")
local function shown() return K.render(pv, 80, "paper") end
ok(vim.wait(1000, function() return item_named(shown(), "mod.lua") ~= nil end), "the pop-out's map: the part's files")
local d = shown()
eq({ d.title, d.state, d.news }, { "project map · " .. vim.fn.fnamemodify(tab_root, ":t"), "", false }, "its title, and no state: it follows nothing")
do
  -- The key line says what the selected thing is and what its keys do: a C++ function, a fold, a handoff, a pick.
  local G = Map.glyphs(false)
  local fn = { name = "tick", target = { kind = "node", node = { id = "e.cpp::tick", label = "tt::tick", file = "e.cpp", line = 11, returns = "bool" } } }
  eq(Map.strip_text(fn, G), { "tt::tick · e.cpp:11 → bool", "Enter source · t trace · c calls · D reach · U callers · gs inspect" },
    "a function: what it is, then Enter source · t trace · c calls …, gs where symdeps can look (C and C++)")
  eq(Map.strip_text({ name = "layout (2)", open = false, target = { kind = "fold", fold = "x|layout" } }, G), { "layout (2)", "Enter opens it" }, "a fold: Enter opens it")
  eq(Map.strip_text({ name = "tick ring", target = { kind = "handoff", by_hand = false } }, G)[2], "Enter opens its producer or consumer · x drops it (it is wrong)", "a handoff: Enter either side, x drops it")
  eq(Map.strip_text({ name = "a → b", target = { kind = "call", caller = "a", callee = "b", sites = { { line = 3 }, { line = 9 } } } }, G),
    { "a → b — 2 calls", "Enter lists them, each with its line" }, "a call with two sites: Enter lists them")
  local payload = P._payload(pv)
  ok(vim.iter(payload.items):any(function(i) return type(i.keys) == "string" and i.keys:find(" — Enter ", 1, true) ~= nil end), "the pop-out's items carry their line")
  local line = P._keyline({ id = "v", copy = { index = 1 }, items = { { keys = "tt::tick · e.cpp:11 — Enter source · t trace" } }, footer = {} })
  ok(line:find("tt::tick · e.cpp:11 — Enter source · t trace", 1, true) and line:find("?%#DeskPopoutWords# keys", 1, true), "the key line shows the selected thing's own line: " .. line)
end
eq(P._payload(pv).follows, false, "the map's pages do not follow the cursor (no ↻ sent)")
eq({ P._payload(pv).tab, P._payload(pv).subject }, { "map", vim.fn.fnamemodify(tab_root, ":t") }, "its tab: map · the checkout")
pv.stack[#pv.stack + 1] = { kind = "query", answer = trace_answer, args = {} }
eq(P._payload(pv).follows, true, "… a trace does (↻ sent)")
eq({ P._payload(pv).tab, P._payload(pv).subject }, { "trace", "tick" }, "… and its tab says what it reads: trace · tick")
pv.stack[#pv.stack] = nil
-- A file of its checkout saved: desk-work's status read again, so "stale since …" shows in the pop-out too (it was read
-- on open only, 2026-11-16); a file elsewhere is not its business.
do
  local function status_asks() return #vim.tbl_filter(function(a) return a:find("map status", 1, true) ~= nil end, asked) end
  local before = status_asks()
  local inside = vim.fn.bufadd(tab_root .. "/lua/start.lua")
  local outside = vim.fn.bufadd(vim.fn.tempname() .. ".lua")
  K.follow(pv, { type = "saved", buf = outside })
  eq(status_asks(), before, "a file outside its checkout saved: nothing asked")
  K.follow(pv, { type = "saved", buf = inside })
  eq(status_asks(), before + 1, "a file of its checkout saved: its status asked again")
  K.follow(pv, { type = "moved", win = api.nvim_get_current_win() })
  eq(status_asks(), before + 1, "… and a cursor move asks nothing")
  ok(vim.wait(1000, function() return pv.status ~= nil end), "… its status kept")
end
ok(not table.concat(d.lines, "\n"):find("Enter in", 1, true), "no key line in its lines: the pop-out's window has its own")
eq(table.concat(vim.tbl_map(function(p) return p[1] .. " " .. p[2] end, P.key_pairs(d.footer)), " · "), "Enter in · - out · D reach · U callers · ? keys",
  "its key line in the pop-out: five keys, as she reads them")
local file_item = item_named(d, "mod.lua")
eq({ file_item.kind, #file_item.spans, file_item.key, d.lines[file_item.line]:sub(file_item.name_col + 1, file_item.name_col + 7) },
  { "box", 4, "file:lua/mod.lua", "mod.lua" }, "a box is an item: its four lines, a key that says what it is, the cursor on its name")
-- The parts page draws a part twice (its box, and again in the calls between parts): two items, two keys.
local parts_page = K.render({ out = true, root = root, stack = { { kind = "modules" } }, cache = { modules = modules }, status = status }, 80, "paper")
local count_of, csrc_keys = {}, {}
for _, it in ipairs(parts_page.items) do
  count_of[it.key] = (count_of[it.key] or 0) + 1
  if it.name == "csrc" then csrc_keys[#csrc_keys + 1] = it.key end
end
eq({ vim.tbl_count(count_of), csrc_keys[1], csrc_keys[2] }, { #parts_page.items, "module:csrc", "module:csrc#2" },
  "every item has a key of its own: a part drawn twice, counted")
-- Seventy parts wrap into rows of boxes: at another width each box is on another line, and keeps its key.
local crowd_view = { out = true, root = root, stack = { { kind = "modules" } }, cache = { modules = many }, status = status }
local wide_items, narrow_items = K.render(crowd_view, 100, "paper").items, K.render(crowd_view, 60, "paper").items
eq(vim.tbl_map(function(i) return i.key end, narrow_items), vim.tbl_map(function(i) return i.key end, wide_items),
  "drawn again at another width, the items keep their keys")
ok(#wide_items > 30 and wide_items[30].line ~= narrow_items[30].line, "… though the boxes moved to other lines")

-- Its keys, run here for the box selected there (the ctx the bridge builds from ctx_for).
local function ctx_on(item)
  local ctx = K.ctx_for(pv, item and item.ref)
  ctx.view, ctx.item, ctx.remote = pv, item and item.ref, true
  return ctx
end
local function act(id, item, extra)
  local ctx = ctx_on(item)
  for k, v in pairs(extra or {}) do ctx[k] = v end
  return { A.act(id, ctx) }
end
do
  local ref = { name = "tick", target = { kind = "node", node = { id = "e.cpp::tick", label = "tt::Engine::tick", file = "e.cpp", line = 11 } } }
  local ctx = ctx_on(nil)
  ctx.item = ref
  eq({ A.about_of(A.get("map.trace"), ctx):find("tt::Engine::tick · e.cpp:11 — ", 1, true), (A.about_of(A.get("map.in"), ctx):find("tt::Engine::tick · e.cpp:11 — ", 1, true)) }, { 1, 1 },
    "the map's keys say in their descriptions which function they act on")
end
-- In the pop-out, a name that fits several is asked there, as a page: Enter on one asks again with it, in its place.
do
  local stack, inner, asked, history = pv.stack, Map.desk_work, {}, vim.deepcopy(P.host.history)
  pv.stack = { { kind = "modules" }, { kind = "query", answer = trace_answer, args = { "--q", "trace", "--from", "e.cpp::tick" } } }
  Map.desk_work = function(args, done)
    local line = table.concat(args, " ")
    asked[#asked + 1] = line
    if line:find("--to dup", 1, true) then
      return vim.defer_fn(function() done({ ok = false, message = "To: Several things in the map are named dup; pick one", flag = "--to",
        candidates = { { id = "a.cpp::dup", label = "ns::dup", file = "a.cpp", line = 3, params = { { name = "x", type = "int" } }, returns = "bool" },
        { id = "b.cpp::dup", label = "other::dup", file = "b.cpp", line = 9 } } }, { code = 1 }) end, 5)
    end
    if args[2] == "query" then return vim.defer_fn(function() done(trace_answer, { code = 0 }) end, 5) end
    return inner(args, done)
  end
  act("map.trace-to", nil, { text = "dup" })
  ok(vim.wait(1000, function() return pv.stack[#pv.stack].kind == "pick" end), "the pop-out: an ambiguous end becomes a page to pick from")
  local drawn = shown()
  local pick = item_named(drawn, "other::dup")
  ok(pick and table.concat(drawn.lines, "\n"):find("ns::dup(int) → bool  a.cpp:3", 1, true), "… each candidate with its signature and place")
  act("map.in", pick)
  ok(vim.wait(1000, function() return pv.stack[#pv.stack].kind == "query" and #pv.stack == 3 end), "Enter on one: its answer in the page's place")
  ok(asked[#asked]:find("--from e.cpp::tick --to other", 1, true) == nil and asked[#asked]:find("--to b.cpp::dup", 1, true) ~= nil,
    "… asked with the one chosen as the end: " .. tostring(asked[#asked]))
  pv.stack, Map.desk_work, P.host.history = stack, inner, history
  pv.pinned = false
end
-- A route she chose holds: e in the pop-out pins it; pinned, moving through its code selects the step there and asks
-- nothing; saved, it comes back after a restart with its question, open folds and selected step.
do
  local stack, inner, history, asked = pv.stack, Map.desk_work, vim.deepcopy(P.host.history), {}
  local routed = vim.deepcopy(trace_answer)
  routed.to = "e.cpp::submit"
  pv.stack = { { kind = "modules" }, { kind = "query", answer = trace_answer, args = { "--q", "trace", "--from", "e.cpp::tick" } } }
  Map.desk_work = function(args, done)
    asked[#asked + 1] = table.concat(args, " ")
    if args[2] == "query" then return vim.defer_fn(function() done(routed, { code = 0 }) end, 5) end
    return inner(args, done)
  end
  pv.pinned = false
  act("map.trace-to", nil, { text = "submit" })
  ok(vim.wait(1000, function() return #pv.stack == 3 end) and pv.pinned == true, "e in the pop-out: the route asked, and pinned (following leaves it)")
  local code = pv.root .. "/e.cpp"
  local text = {}
  for i = 1, 60 do text[i] = "// " .. i end
  vim.fn.writefile(text, code)
  vim.cmd("split " .. vim.fn.fnameescape(code))
  local cw = api.nvim_get_current_win()
  vim.cmd("wincmd p")
  local before = #asked
  api.nvim_win_set_cursor(cw, { 20, 0 })
  pv.select = nil
  K.follow(pv, { type = "moved", win = cw })
  ok(vim.wait(Map.FOLLOW_MS + 1000, function() return pv.select == "node:e.cpp::tick" end), "pinned: the cursor in tick's code selects tick's step: " .. tostring(pv.select))
  eq(#asked, before, "… and nothing is asked: the route stays")
  api.nvim_win_close(cw, true)
  local top = pv.stack[#pv.stack]
  top.folds = { ["e.cpp::tick|uses"] = true }
  local saved = K.save(pv)
  eq(saved.target.trace, { focus = "e.cpp::tick", to = "e.cpp::submit", folds = { ["e.cpp::tick|uses"] = true }, selected = "node:e.cpp::tick" },
    "saved: the trace's question and how she left it")
  local fresh_view = { id = "map-restored", kind = "map", pop = pv.pop, gen = 0 }
  local host_pop = P.pops and P.pops[1] or P.host
  host_pop.views[fresh_view.id] = fresh_view
  asked = {}
  local fine = pcall(K.restore, fresh_view, { pinned = true, target = vim.json.decode(vim.json.encode(saved.target)) })
  ok(fine and vim.wait(2000, function() local t = fresh_view.stack and fresh_view.stack[#fresh_view.stack]; return t and t.kind == "query" end),
    "restored: the trace asked again of the map as it is now")
  ok(vim.iter(asked):any(function(a) return a:find("--q trace --from e.cpp::tick --to e.cpp::submit", 1, true) ~= nil end), "… with its focus and end: " .. vim.inspect(asked))
  local rt = fresh_view.stack and fresh_view.stack[#fresh_view.stack] or {}
  eq({ rt.folds, rt.selected }, { { ["e.cpp::tick|uses"] = true }, "node:e.cpp::tick" }, "… its folds open and its step selected as she left them")
  K.close(fresh_view)
  host_pop.views[fresh_view.id] = nil
  pv.stack, Map.desk_work, P.host.history, pv.pinned = stack, inner, history, false
end
do
  local stack, cache = pv.stack, pv.cache
  pv.stack, pv.cache = { { kind = "modules" } }, { modules = many }
  local partial = shown()
  local item = item_named(partial, "m05")
  ok(item and not item_named(partial, "m70"), "the pop-out initially shows a bounded preview")
  eq(act("map.more", item), { true }, "m is available from the pop-out")
  ok(item_named(shown(), "m70") and not pv.has_more, "the pop-out shows the rest after m")
  eq(pv.stack[1].selected, item.key, "the pop-out keeps the selected item while expanding")
  pv.stack, pv.cache, pv.select = stack, cache, nil
  shown()
end
local c = ctx_on(file_item)
eq({ c.surface, c.map == pv, c.item == file_item.ref, c.origin and vim.bo[api.nvim_win_get_buf(c.origin)].buftype },
  { "map", true, true, "" }, "ctx_for: the map's surface, this map, the box selected there, and a file window here for Enter")
eq(act("map.in", file_item), { true }, "Enter on a file, from the pop-out")
ok(vim.wait(1000, function() return item_named(shown(), "M.alpha") ~= nil end), "… the pop-out's map zooms into its functions")
eq(vim.tbl_map(function(s) return s.type end, P.host.history.steps), { "state" }, "… a step of the pop-out's history")
P.history_back()
ok(vim.wait(1000, function() return item_named(shown(), "mod.lua") ~= nil end), "H (and Backspace) there: back out to the files")
eq(pv.select, "file:lua/mod.lua", "… the file it went into selected again")
P.history_forward()
ok(vim.wait(1000, function() return item_named(shown(), "M.alpha") ~= nil end), "L: in again")
eq(act("map.out"), { true }, "- there: out a level")
ok(vim.wait(1000, function() return item_named(shown(), "mod.lua") ~= nil and not item_named(shown(), "M.alpha") end), "… to the files")
eq(#P.host.history.steps, 2, "… a step back too")
eq(A.available(A.get("map.reach"), ctx_on(file_item)), "select a function first", "D there needs a function selected")
eq(A.available(A.get("map.in"), ctx_on(nil)), "nothing is selected", "… and Enter something selected")
-- f: what Enter does, then the keyboard to the editor; on a file Enter zooms here, so the keyboard stays (2026-11-16).
local real_focus, focused = P.focus, 0
P.focus = function() focused = focused + 1 end
eq(act("popout.go-focus", file_item), { true }, "f on a file there")
ok(vim.wait(1000, function() return item_named(shown(), "M.alpha") ~= nil end), "into the file again")
eq(focused, 0, "… zoomed in as Enter does, the keyboard left in the pop-out")
local alpha = item_named(shown(), "M.alpha")
local code = ctx_on(alpha).origin
local real_show, shown_graph = P.show, nil
P.show = function(name, ctx, opts) shown_graph = { name, ctx.target and ctx.target.name, ctx.remote, opts and opts.pop } end
-- Named: the map's own pop-out (with several, the first was taking it: seen in a VM, 2026-11-17).
eq(act("map.centre", alpha), { true }, "c on a function, from the pop-out")
P.show = real_show
eq(shown_graph, { "graph", "M.alpha", nil, pv.pop or 1 }, "… the call graph shown in the map's own pop-out, filled for that function (not a remote ask: it opens there)")
eq(act("popout.go-focus", alpha), { true }, "f on a function there")
eq(focused, 1, "… goes to its code, and the keyboard goes there too")
P.focus = real_focus
eq(act("map.in", alpha), { true }, "Enter on a function, from the pop-out")
eq({ api.nvim_get_current_win(), api.nvim_buf_get_name(0), api.nvim_win_get_cursor(0)[1] }, { code, root .. "/lua/mod.lua", 3 },
  "… goes to its code here, in the file window")
pv.news = nil
local prompted = 0
local real_input = vim.ui.input
vim.ui.input = function(opts, done) prompted = prompted + 1; real_input(opts, done) end
eq(act("map.reach", alpha), { true }, "D on a function, from the pop-out")
ok(asked[#asked]:find("--q reach --from lua/mod.lua::M.alpha --depth 3", 1, true), "… asks what the selected function reaches, at depth 3")
eq(prompted, 0, "… without asking anything here: the keyboard is in the pop-out")
vim.ui.input = real_input
ok(vim.wait(1000, function() return table.concat(shown().lines, "\n"):find("what use reaches", 1, true) end), "… and shows the answer there")
eq({ pv.news, shown().news }, { true, true }, "… news in the pop-out's header until she looks")
local saved = K.save(pv)
eq({ saved.step, #saved.stack, saved.target.root, #saved.target.levels }, { true, 4, tab_root, 3 },
  "save: all of it for the history; for the layout record its checkout and zoom, not a query's answer")
ok(pcall(vim.json.encode, saved.target), "… plain data")
eq(act("map.expand"), { true }, "+ expands the reach page from the pop-out")
ok(vim.wait(1000, function() return pv.stack[#pv.stack].answer.depth == 4 end), "… one more level, in place")
eq(act("map.out"), { true }, "- collapses the reach page from the pop-out")
ok(vim.wait(1000, function() return pv.stack[#pv.stack].answer.depth == 3 end), "… back to the original depth")
eq(act("popout.history-back"), { true }, "going back leaves the reach page")
ok(vim.wait(1000, function() return #pv.stack == 3 and item_named(shown(), "M.alpha") ~= nil end), "the pop-out returns to the file's functions")
eq(act("map.paths", alpha, { text = "M.beta" }), { true }, "P from the pop-out, with the words it asked there")
ok(asked[#asked]:find("--q paths --from lua/mod.lua::M.alpha --to M.beta", 1, true), "… the ways from the selected function to the one named")
ok(vim.wait(1000, function() return table.concat(shown().lines, "\n"):find("ways from use to M.beta", 1, true) end), "… shown there")
eq(act("map.paths", alpha), { false, "The ways between two functions: needs its words" }, "… and without them it does not run")
act("map.out")
ok(vim.wait(1000, function() return item_named(shown(), "M.alpha") ~= nil end), "- leaves the ways")
-- In the pop-out too: - takes a level off down to one, then zooms out (C1).
eq(act("map.reach", alpha), { true }, "D again from the pop-out")
ok(vim.wait(1000, function() return #pv.stack == 4 and pv.stack[4].answer.depth == 3 end), "… its reach page, at depth 3")
act("map.out")
ok(vim.wait(1000, function() return pv.stack[4] and pv.stack[4].answer.depth == 2 end), "- there takes a level off")
act("map.out")
ok(vim.wait(1000, function() return pv.stack[4] and pv.stack[4].answer.depth == 1 end), "… down to one")
act("map.out")
ok(vim.wait(1000, function() return #pv.stack == 3 and item_named(shown(), "M.alpha") ~= nil end), "- at one level goes out, to the file's functions")
Map.POLL_MS = 20
pv.news = nil
local redraws, real_redraw = 0, P.redraw
P.redraw = function(v) if v == pv then redraws = redraws + 1 end; return real_redraw(v) end
eq(act("map.rebuild"), { true }, "R from the pop-out")
ok(vim.wait(1000, function() return table.concat(shown().lines, "\n"):find("rebuilding", 1, true) end), "… its page says it is rebuilding")
ok(redraws > 0, "… and the pop-out is sent it")
building = false
ok(vim.wait(3000, function() return pv.timer == nil and pv.news == true end), "… and when it is done, news there")
P.redraw = real_redraw
-- After a restart: the layout record's target is that checkout's map, zoomed in as it was.
local again = { id = "map", kind = "map", gen = 0, pinned = true }
P.host.views.map = again
K.restore(again, { pinned = true, target = saved.target })
ok(vim.wait(1000, function() return again.stack and #again.stack == 3 and item_named(K.render(again, 80, "paper"), "M.alpha") ~= nil end),
  "restore from the layout record: that checkout's map, zoomed in as it was")
K.close(again)
P.host.views.map = pv
-- o in the pop-out: it leaves the pop-out (desk.popout's clear), and the kind puts it back here as its tab.
P.host.views, P.host.order = {}, {}
pv.gone = true
K.close(pv)
K.attach(pv)
local back_tab
for _, v in pairs(Map.views) do if v.root == tab_root then back_tab = v end end
ok(back_tab and api.nvim_get_current_win() == back_tab.win and #back_tab.stack == #pv.stack, "o there: back here as its tab, at the level it was on")
ok(vim.wait(1000, function() return back_tab and back_tab.drawn and line_with(back_tab.drawn.lines, "│ M.alpha")
  and line_with(back_tab.drawn.lines, "parts › lua › mod.lua") end), "… and drawn in it, the file's functions")
press("q")
-- Space cm here while this checkout's map is in the pop-out: that map comes back as the tab, as it was (2026-11-16: a
-- second, fresh map opened beside it).
local pv3 = { id = "map", kind = "map", gen = 0, pinned = false }
P.host.views, P.host.order = { map = pv3 }, { "map" }
api.nvim_set_current_win(code)
K.open(pv3, A.context(code))
ok(vim.wait(1000, function() return item_named(K.render(pv3, 80, "paper"), "lua") ~= nil end), "a map in the pop-out")
local lua_ref = item_named(K.render(pv3, 80, "paper"), "lua").ref
local into = K.ctx_for(pv3, lua_ref)
into.view, into.item, into.remote = pv3, lua_ref, true
A.act("map.in", into)
ok(vim.wait(1000, function() return #pv3.stack == 2 and item_named(K.render(pv3, 80, "paper"), "mod.lua") ~= nil end), "… zoomed into lua there")
api.nvim_set_current_win(code)
local came = Map.open()
local tabs_of_root = 0
for _, v in pairs(Map.views) do if v.root == tab_root then tabs_of_root = tabs_of_root + 1 end end
eq({ came and #came.stack, P.host.views.map == nil, tabs_of_root }, { 2, true, 1 },
  "Space cm: the pop-out's map back as the one tab, at the level it was on")
press("q")

-- The bridge's act, as the pop-out sends it: each Enter is one step back, holding where the editor was and the map as
-- it was (desk.popout folds the map's own step into it), so each H does something: an Enter that zoomed is undone by
-- the map going back out, one that went to a function by the editor going back.
local server = vim.fn.serverstart(vim.fn.tempname() .. ".sock")
local chan = vim.fn.sockconnect("pipe", server, { rpc = true })
local pv2 = { id = "map", kind = "map", gen = 0, pinned = false }
P.host.views, P.host.order, P.host.history, P.host.chan = { map = pv2 }, { "map" }, { steps = {}, at = 0 }, chan
api.nvim_set_current_win(code)
api.nvim_win_set_cursor(code, { 1, 0 })
K.open(pv2, A.context())
ok(vim.wait(1000, function() return item_named(K.render(pv2, 80, "paper"), "lua") ~= nil end), "from the code, its Views row: this checkout's map")
local function bridge_act(action, name)
  pv2.sent = nil
  P.redraw(pv2)
  local index
  for i, ref in ipairs(pv2.refs or {}) do if ref.name == name and not index then index = i end end
  local s, us = vim.uv.gettimeofday()
  return require("desk.bridge").receive({ version = 1, type = "act", view = "map", gen = pv2.gen, item = index, action = action,
    deadline = s * 1000 + math.floor(us / 1000) + 5000 })
end
local function steps() return vim.tbl_map(function(s) return s.type end, P.host.history.steps) end
eq(bridge_act("map.in", "lua"), { done = true }, "Enter there, through the bridge: taken")
ok(vim.wait(1000, function() return item_named(K.render(pv2, 80, "paper"), "mod.lua") ~= nil end), "… the map zooms in")
local first = P.host.history.steps[1]
eq({ steps(), first and first.saved and #first.saved.stack }, { { "enter" }, 1 }, "… one step back, holding the map as it was: at its top")
bridge_act("map.in", "mod.lua")
ok(vim.wait(1000, function() return item_named(K.render(pv2, 80, "paper"), "M.alpha") ~= nil end), "into the file")
bridge_act("map.in", "M.alpha")
ok(vim.wait(1000, function() return #steps() == 3 end), "Enter on a function moved the editor …")
eq({ steps(), api.nvim_win_get_cursor(code)[1] }, { { "enter", "enter", "enter" }, 3 }, "… to its line: one step for each Enter")
P.history_back()
eq(api.nvim_win_get_cursor(code), { 1, 0 }, "H: the editor back where it was")
P.history_back()
ok(vim.wait(1000, function() return item_named(K.render(pv2, 80, "paper"), "mod.lua") ~= nil end), "H again: the map back out (each press did something)")
K.close(pv2)
P.host.views, P.host.order, P.host.history, P.host.chan = {}, {}, { steps = {}, at = 0 }, nil
pcall(vim.fn.chanclose, chan)
vim.fn.serverstop(server)
-- What the pop-out's map says without desk-work, or before a build: the tab's words.
eq((table.concat(K.render({ out = true, root = root, stack = { { kind = "modules" } }, cache = {}, missing = true }, 80, "paper").lines, "\n"))
  :find("Requires desk-work", 1, true) ~= nil, true, "without desk-work the pop-out's map says what it needs")
eq((table.concat(K.render({ out = true, root = root, stack = { { kind = "modules" } }, cache = {}, status = { ok = true, built = false } }, 80, "paper")
  .lines, "\n")):find("no map built yet · R builds it", 1, true) ~= nil, true, "… and before a build, that R builds it")
vim.env.PATH = saved_path

-- No desk-work at all (the real call, with no desk-work on PATH): the page opens and says what it needs, and a key that
-- needs it says so instead of asking. With desk-work there again, back on the page, the map.
local said, asked_for = {}, 0
local real_notify = vim.notify
vim.notify = function(msg) said[#said + 1] = msg end
vim.ui.input = function() asked_for = asked_for + 1 end
Map.desk_work = real_desk_work
vim.env.PATH = empty_bin
local lonely = Map.open(root)
ok(vim.wait(1000, function() return lonely.drawn and line_with(lonely.drawn.lines, "Requires desk-work: it builds the project map") end),
  "without desk-work the page says what it needs")
ok(line_with(lonely.drawn.lines, "requires desk-work") and not line_with(lonely.drawn.lines, "reading"), "… its badge too: not reading forever")
local why = {}
for _, l in ipairs(A.key_lines(A.context(lonely.win))) do why[l.ident] = l.right or true end
eq({ why["map.reach"], why["map.paths"], why["map.rebuild"], why["map.back"], why["map.close"] },
  { "requires desk-work", "requires desk-work", "requires desk-work", true, true }, "? says which keys need desk-work")
press("D")
eq({ asked_for, said[#said] }, { 0, "Requires desk-work." }, "D says so instead of asking for a function")
vim.env.PATH = saved_path
Map.desk_work = fake
api.nvim_set_current_win(origin)
api.nvim_set_current_win(lonely.win)
ok(vim.wait(2000, function() return line_with(lonely.drawn.lines, "│ lua") ~= nil end), "with desk-work there, back on the page: the map")
eq(lonely.missing, nil, "… and its keys work again")
press("q")

-- No map built yet: the page and its badge say how to build one; a question to the map says so instead of asking.
status.built = false
local unbuilt = Map.open(root)
ok(vim.wait(1000, function() return unbuilt.drawn and line_with(unbuilt.drawn.lines, "no map built yet · R builds it") end), "no map yet: the badge")
ok(line_with(unbuilt.drawn.lines, "No map built yet. R builds it in the background"), "… and the page say R builds it")
press("D")
eq({ asked_for, said[#said] }, { 0, "No map built yet · R builds it." }, "D says so instead of asking")
why = {}
for _, l in ipairs(A.key_lines(A.context(unbuilt.win))) do why[l.ident] = l.right or true end
eq({ why["map.reach"], why["map.rebuild"] }, { "no map built yet · R builds it", true }, "? greys the questions, not the build")
press("q")

-- Not a git checkout and no binary given (VM test 2026-11-16): no reader can build a map here. The page says what is
-- needed, first, and offers no R; B (reading a binary) still can.
status.providers = { { name = "syntax", state = "not built", why = "requires a git checkout (the files to read come from git)" },
  { name = "binary", state = "not built", why = "requires a built binary: desk-work map build --binary PATH (kept for the next builds)" } }
local nowhere = Map.open(root)
ok(vim.wait(1000, function() return nowhere.drawn and line_with(nowhere.drawn.lines, "requires a git checkout") end), "not a checkout: it says so")
local title_row = line_with(nowhere.drawn.lines, "project map")
ok(title_row and (nowhere.drawn.lines[title_row + 1] or ""):find("^requires a git checkout"), "… first, in the badge under the title:\n"
  .. text(nowhere.drawn.lines))
ok(line_with(nowhere.drawn.lines, "syntax: requires a git checkout (the files") and line_with(nowhere.drawn.lines, "binary: requires a built binary"),
  "… and the page says what each reader needs")
ok(not line_with(nowhere.drawn.lines, "builds it") and not line_with(nowhere.drawn.lines, "No map built yet"), "… with no R to build one")
why = {}
for _, l in ipairs(A.key_lines(A.context(nowhere.win))) do why[l.ident] = l.right or true end
eq({ why["map.rebuild"], why["map.reach"], why["map.binary"] }, { "requires a git checkout", "requires a git checkout", true },
  "? greys R and the questions with the reason, not B")
local builds = #vim.tbl_filter(function(a) return a:find("map build", 1, true) end, asked)
press("R")
eq({ said[#said], #vim.tbl_filter(function(a) return a:find("map build", 1, true) end, asked) }, { "Requires a git checkout.", builds },
  "R says so instead of starting a build that cannot run")
press("q")
vim.notify = real_notify

vim.fn.delete(root, "rf")
print(string.format("test_map: %d passed%s%s", passed, failed > 0 and (", " .. failed .. " failed") or "",
  #skipped > 0 and (" (skipped: " .. table.concat(skipped, ", ") .. ")") or ""))
os.exit(failed > 0 and 1 or 0)
