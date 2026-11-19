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
  -- What the reader keeps of long lists: 16 parameters, 12 arguments, 12 fields a way; the rest counted.
  ["csrc/wide.c"] = { "void use(int v) {}", "void wide(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9, int a10, int a11, int a12, int a13, int a14, int a15, int a16, int a17, int a18) {}", "void many(struct S* s) { use(s->f1); use(s->f2); use(s->f3); use(s->f4); use(s->f5); use(s->f6); use(s->f7); use(s->f8); use(s->f9); use(s->f10); use(s->f11); use(s->f12); use(s->f13); use(s->f14); }", "void calls(void) { wide(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14); }" },
  ["lua/c/x.lua"] = { "local function dup() return 1 end", "return dup" },
  ["lua/c/y.lua"] = { "local function dup() return 2 end", "return dup" },
  ["lua/c/z.lua"] = { "local function use_dup() return dup() end", "return use_dup" },
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
do
  -- Same-name functions told apart by their #if branch, and which one the compile flags turn on (Codex's #13).
  local pp_root = vim.fn.tempname()
  vim.fn.mkdir(pp_root .. "/src", "p")
  vim.fn.writefile({ "#ifdef LINUX", "void send(int a) { a1(); }", "#elif defined(MAC)", "void send(int a) { m1(); }", "#else", "void send(int a) { b1(); }", "#endif",
    "int plain(void) { return 0; }" }, pp_root .. "/src/net.c")
  vim.fn.writefile({ vim.json.encode({ { directory = pp_root, file = "src/net.c", arguments = { "cc", "-DLINUX", "-c", "src/net.c" } } }) }, pp_root .. "/compile_commands.json")
  local g3 = Map.syntax_graph({ root = pp_root, files = { "src/net.c" } })
  local conds = {}
  for _, n in ipairs(g3.nodes) do conds[#conds + 1] = { n.label, n.cond and n.cond.text or false, n.cond and n.cond.active } end
  eq(conds, { { "send", "#ifdef LINUX", true }, { "send", "#elif defined(MAC)", false }, { "send", "#else (#ifdef LINUX)", false }, { "plain", false } },
    "each send() with its branch, and the one -DLINUX turns on; a function in none has none")
  eq({ Map.cond_said(g3.nodes[1]), Map.cond_said(g3.nodes[2]), Map.cond_said({ cond = { text = "#if X > 1" } }) },
    { "#ifdef LINUX (on)", "#elif defined(MAC) (off)", "#if X > 1" }, "… said on its box; a condition the flags cannot settle, as written")
  vim.fn.delete(pp_root, "rf")
end
do
  -- A rebuild in proportion to the edit (Codex's #43): each file's reading cached by its text, the names matched again
  -- across every file; the answer a clean build's, also when a new overload elsewhere makes an untouched call ambiguous.
  local cr = vim.fn.tempname()
  vim.fn.mkdir(cr .. "/src", "p")
  vim.fn.writefile({ "int feed(void) { return helper(1); }" }, cr .. "/src/a.c")
  vim.fn.writefile({ "int helper(int x) { return x; }" }, cr .. "/src/b.c")
  vim.fn.writefile({ "int other(void) { return 0; }" }, cr .. "/src/d.c")
  vim.fn.writefile({ "local M = {}", "function M.go() return M.stop() end", "function M.stop() return 1 end", "return M" }, cr .. "/src/c.lua")
  local files3, cache = { "src/a.c", "src/b.c", "src/c.lua", "src/d.c" }, cr .. "/cache"
  local function shape(g) return { nodes = g.nodes, edges = g.edges, spans = g.spans } end
  local clean = Map.syntax_graph({ root = cr, files = files3 })
  local first = Map.syntax_graph({ root = cr, files = files3, cache = cache })
  local second = Map.syntax_graph({ root = cr, files = files3, cache = cache })
  eq({ first.stats.cached, second.stats.cached, #vim.fn.readdir(cache) }, { 0, 4, 4 }, "a second build of unchanged files: all four from the cache")
  ok(vim.deep_equal(shape(second), shape(clean)), "… with a clean build's answer")
  ok(vim.iter(second.edges):find(function(e) return e.from == "src/a.c::feed" and e.to == "src/b.c::helper" end), "feed calls helper (one of that name)")
  -- a second helper in d.c: feed's call in the untouched a.c is ambiguous now
  vim.fn.writefile({ "int other(void) { return 0; }", "int helper(int x) { return x + 1; }" }, cr .. "/src/d.c")
  local after = Map.syntax_graph({ root = cr, files = files3, cache = cache })
  local fresh = Map.syntax_graph({ root = cr, files = files3 })
  eq(after.stats.cached, 3, "one file changed: only it read again")
  ok(vim.deep_equal(shape(after), shape(fresh)) and after.stats.ambiguous == fresh.stats.ambiguous, "… the answer a clean rebuild's")
  local feed_helper = vim.iter(after.edges):find(function(e) return e.from == "src/a.c::feed" and e.to:find("helper", 1, true) end)
  ok(not feed_helper and (vim.iter(after.nodes):find(function(n) return n.id == "src/a.c::feed" end) or {}).ambiguous ~= nil,
    "… feed's call to helper, in the file not read again, ambiguous now (said on feed)")
  eq(#vim.fn.readdir(cache), 4, "the old reading of d.c left the cache")
  vim.fn.delete(cr, "rf")
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
  -- The review's rows (desk.review, which reads C++ with the same parser): methods of two classes named alike, and
  -- overloads, each a row of its own.
  local Rv = require("desk.review")
  local BOOK = "struct Bids {\n  void flush() {\n    a();\n  }\n};\nstruct Asks {\n  void flush() {\n    b();\n  }\n};\nvoid send(int o) {\n  c();\n}\nvoid send(double c) {\n  d();\n}\n"
  local after = BOOK:gsub("a%(%);", "a(); x();"):gsub("b%(%);", "b(); y();"):gsub("c%(%);", "c(); z();"):gsub("d%(%);", "d(); w();")
  local book = { rel = "book.cpp", left = BOOK, right = after, loaded = true, signature = "book",
    hunks = (vim.text and vim.text.diff or vim.diff)(BOOK, after, { result_type = "indices", algorithm = "histogram", linematch = 60 }) }
  eq(vim.tbl_map(function(s) return s.name end, Rv.changed_symbols(book)), { "Bids::flush()", "Asks::flush()", "send(int o)", "send(double c)" },
    "review: flush on two classes and two send overloads, each its own row, named by class and parameters")
  local st = Rv.structure(book)
  eq({ st.calls["Bids::flush()"].added, st.calls["Asks::flush()"].added, st.calls["send(double c)"].added }, { { "x" }, { "y" }, { "w" } },
    "… each compared with itself")
else skipped[#skipped + 1] = "cpp (no parser)" end

-- A call the reader could not tell apart by name, placed on the function that makes it (Codex's #4).
eq(by_label["use_dup"] and by_label["use_dup"].ambiguous, { { name = "dup", count = 2, line = 1 } }, "use_dup's dup(): two functions of that name in its folder, said on use_dup")
eq(by_label["choose"].ambiguous, nil, "… a call the folder settles is not")
eq({ Map.ambiguity(by_label["use_dup"]), Map.ambiguity({ ambiguous = { { name = "a", count = 2 }, { name = "b", count = 3 } } }), Map.ambiguity({}) },
  { "dup: 2 match", "a: 2 match +1", nil }, "… said beside it as the first name and how many more")
do
  local n = { id = "lua/c/z.lua::use_dup", label = "use_dup", file = "lua/c/z.lua", line = 1, depth = 0, ambiguous = { { name = "dup", count = 2, line = 1 } } }
  local page = Map.layout(Map.level_query({ ok = true, q = "reach", from = n, depth = 1, nodes = { n }, steps = {} }), 80, false)
  ok(line_with(page.lines, "z.lua:1 · dup: 2 match"), "… on its box, where the answer is read")
end
-- The reader's caps, counted (Codex's #41, 2026-11-18): what was left out is said beside the list.
eq({ by_label["wide"] and #by_label["wide"].params, by_label["wide"] and by_label["wide"].params_more }, { 16, 2 }, "18 parameters: 16 kept, 2 more counted")
local many = by_label["many"] and by_label["many"].params and by_label["many"].params[1] or {}
eq({ #(many.reads or {}), many.reads_more, many.seen_more }, { 12, 2, nil }, "14 fields read: 12 kept, 2 more counted (its working set not in the map)")
local wide_call = call_of("calls", "wide") or {}
eq({ #(wide_call.args or {}), wide_call.args_more, wide_call.sites and wide_call.sites[1].args_more }, { 12, 2, 2 }, "14 arguments: 12 kept, 2 more counted, on the call and its site")
eq({ Map.omitted(12, 2), Map.omitted(12, nil), Map.omitted(3, 0) }, { "12 shown · 2 more omitted" }, "said as shown · more omitted, nothing when nothing was left out")

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
-- Every box and every call drawn, the page scrolls (2026-11-19, her "show the entire thing at once? and just be
-- scrollable?"): no "+N more", no key to show the rest.
for i=1,15 do many.edges[i] = { from = "m01", to = ("m%02d"):format(i+1), count = 1 } end
for _, retro_style in ipairs({ false, true }) do
  local every = Map.layout(Map.level_modules(many), 100, retro_style)
  ok(line_with(every.lines, "│ m70") and line_with(every.lines, "│ m61") and line_with(every.lines, "m01 → m16"),
    "seventy parts and fifteen calls between them: every one drawn (" .. (retro_style and "retro" or "paper") .. ")")
  ok(not vim.iter(every.lines):any(function(l) return l:lower():find("more", 1, true) end), "… and nothing says more")
end
local retro = Map.layout(page, 70, true)
ok(line_with(retro.lines, "┌") and not line_with(retro.lines, "╭") and line_with(retro.lines, "CALLS BETWEEN PARTS"), "retro: code page 437 boxes and capitals")
-- The zoom on a row of its own under the header (2026-11-19, her "space the labels out": the rail's ALL/DIR/SRC/CLS sat
-- on the header's lines and read "ALL PROJECT MAP").
local zoom_page = vim.tbl_extend("force", page, { zoom = 2, header = { { "PROJECT MAP · eng", "DeskMapTitle" }, { "BUILT 03:40", "DeskMapDim" } } })
for _, retro_style in ipairs({ true, false }) do
  local zoom = Map.layout(zoom_page, 70, retro_style)
  local said = retro_style and string.upper or function(s) return s end
  local title_row, title = line_with(zoom.lines, "PROJECT MAP")
  local zoom_row, row = line_with(zoom.lines, said("zoom"))
  ok(title and not title:find(said("all"), 1, true) and not zoom.lines[title_row + 1]:find(said("dir"), 1, true),
    "the header's lines carry no zoom label (" .. (retro_style and "retro" or "paper") .. ")")
  ok(zoom_row and zoom_row > title_row + 1 and row:find(said("all") .. ".*" .. said("dir") .. ".*" .. said("src") .. ".*" .. said("cls")),
    "the zoom is one row under the header, its levels in order")
  eq(vim.trim(zoom.lines[(zoom_row or 0) + 1] or "x"), "", "a blank line between the zoom row and the drawing")
  local dir_at = row and row:find(said("dir"), 1, true)
  ok(dir_at and vim.iter(zoom.marks):any(function(m)
    return m[1] == zoom_row and m[4] == "DeskMapFocus" and m[2] <= dir_at - 1 and m[3] >= dir_at - 1 + 3 end),
    "the current zoom is lit in the focus colour")
  ok(not vim.iter(zoom.marks):any(function(m)
    local all_at = row and row:find(said("all"), 1, true)
    return all_at and m[1] == zoom_row and m[4] == "DeskMapFocus" and m[2] <= all_at - 1 and m[3] >= all_at + 2 end),
    "… and only it")
end

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
local drawn_callers = crowded_ok and #vim.tbl_filter(function(b) return tostring(b.item and b.item.name or ""):find("^caller%d") end, crowded.boxes) or 0
ok(crowded_ok and line_with(crowded.lines, "called from · 41") and drawn_callers == 40 and not line_with(crowded.lines, "more"),
  "forty-one callers on a side: every one drawn (" .. drawn_callers .. " of the 40 callerNN)")
-- The whole trace (T, 2026-11-19, her "an entire trace would be nice"): every function on some way between the trace's
-- ends as boxes in layers, the trace's own lane in double frames, F (the function asked about) where the selection starts.
do
  local function n(id, lane, at) return { id = id, label = id, file = "f.cpp", line = at + 1, kind = "function", lane = lane, at = at } end
  local whole = { ok = true, q = "flow", focus = "F", from = "entry2", to = "end", depth = 16,
    nodes = { n("entry2", true, 0), n("a", true, 1), n("F", true, 2), n("g", false, 2), n("b", true, 3), n("end", true, 4) },
    edges = { { from = "entry2", to = "a" }, { from = "a", to = "F" }, { from = "a", to = "g" }, { from = "F", to = "b" },
              { from = "g", to = "b" }, { from = "b", to = "end" } },
    lane = { "entry2", "a", "F", "b", "end" } }
  for _, retro_style in ipairs({ false, true }) do
    local G = Map.glyphs(retro_style)
    local page = Map.layout(Map.level_query(whole), 100, retro_style)
    local style = retro_style and "retro" or "paper"
    ok(line_with(page.lines, G.double.v .. " F ") and line_with(page.lines, G.double.v .. " entry2 ") and line_with(page.lines, G.double.v .. " end "),
      "the whole trace: the lane's functions in double frames (" .. style .. ")")
    ok(line_with(page.lines, G.single.v .. " g ") and not line_with(page.lines, G.double.v .. " g "), "… g, on another way round F, in a single one")
    ok(line_with(page.lines, G.said("whole trace through")) and line_with(page.lines, "6 " .. G.said("functions")), "… its heading says what and how many")
    local _, a_line = line_with(page.lines, "│ a ")
    local a_row, g_row = line_with(page.lines, " a "), line_with(page.lines, " g ")
    ok(a_row and g_row and a_row < g_row, "… callers above what they call: a above g")
    local centres = vim.tbl_filter(function(b) return b.centre end, page.boxes)
    eq(vim.tbl_map(function(b) return b.item.name end, centres), { "F" }, "… only F is where the selection starts")
    local _, gl = line_with(page.lines, G.single.v .. " g ")
    eq(Map.item_at(page, (line_with(page.lines, G.single.v .. " g ")), gl:find("g ", 1, true) - 1).target.node.id, "g", "… a box is a hit: Enter goes to its code")
  end
end
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
do
  -- the map's boxes fit names as the call graph's do: two overloads in a narrow page stay different (Codex's #5)
  local nodes = { { id = "q.hpp::a", label = "fox::engine::OrderBook::apply_insert(const Order&)", file = "q.hpp", line = 4, depth = 1 },
    { id = "q.hpp::b", label = "fox::engine::OrderBook::apply_insert(const Cancel&)", file = "q.hpp", line = 9, depth = 1 },
    { id = "r.cpp::route", label = "route", file = "r.cpp", line = 2, depth = 0 } }
  local page = Map.layout(Map.level_query({ ok = true, q = "reach", from = nodes[3], depth = 1, nodes = nodes,
    steps = { { from = "r.cpp::route", to = "q.hpp::a", depth = 1, mark = "leaf" }, { from = "r.cpp::route", to = "q.hpp::b", depth = 1, mark = "leaf" } } }), 26, false)
  local text = table.concat(page.lines, "\n")
  ok(text:find("apply_insert(Ord", 1, true) and text:find("apply_insert(Can", 1, true), "two overloads in a 26-column map page: told apart\n" .. text)
end
do
  -- what a rebuild changed (Codex's #42): counts in the header, the lists a key away
  local c = { edges_added = 1, edges_removed = 2, nodes_added = 1, nodes_removed = 0, found_source = 0, lost_source = 1, because = { "the source changed (aaaaaaa → bbbbbbb)" } }
  eq({ Map.changes_said(c), Map.changes_said({ first = true }), Map.changes_said({ edges_added = 0 }) },
    { "+1 call · −2 calls · +1 function · 1 lost its source", nil, "no change" }, "the counts, said; nothing for a first build")
  local head = Map.header({ root = "/r", status = { ok = true, built = true, head = "abc", built_at = os.time(), changes = c } }, Map.glyphs(false))
  ok(head[#head][1]:find("since the last build: +1 call · −2 calls · +1 function · 1 lost its source · W what changed", 1, true), "… in the header, with the key")
  local page = Map.layout(Map.level_query(vim.tbl_extend("force", c, { ok = true, q = "changes", built_at = os.time(), previous_built_at = os.time() - 60,
    edges_added_list = { { from = "a.c::f", to = "a.c::extra", kind = "call-by-name" } }, edges_removed_list = { { from = "a.c::f", to = "a.c::old", kind = "call" }, { from = "a.c::g", to = "a.c::old", kind = "call" } },
    nodes_added_list = { { id = "a.c::extra", label = "extra", file = "a.c", line = 9 } }, nodes_removed_list = {} })), 100, false)
  local text = table.concat(page.lines, "\n")
  ok(text:find("because the source changed (aaaaaaa → bbbbbbb)", 1, true) and text:find("calls added · 1", 1, true) and text:find("f → extra  (by name)", 1, true)
    and text:find("calls removed · 2", 1, true) and text:find("functions added · 1", 1, true) and text:find("1 lost their source match", 1, true),
    "W: the page, why first, then each list\n" .. text)
end
do
  -- A sanitizer's report as its stacks, where they meet marked (Codex's #17).
  local report = Map.sanitizer_stacks([==[
=================================================================
==12345==ERROR: AddressSanitizer: heap-use-after-free on address 0x602000000010 at pc 0x55d4 bp 0x7ffc sp 0x7ffc
READ of size 4 at 0x602000000010 thread T0
    #0 0x55d4c1 in drain(Ring*) /w/src/ring.cpp:41:12
    #1 0x55d4c2 in tick(Engine&) /w/src/engine.cpp:88:3
    #2 0x55d4c3 in main /w/src/main.cpp:9:5
    #3 0x7f00 in __libc_start_main (/usr/lib/libc.so.6+0x27b8a)

0x602000000010 is located 0 bytes inside of 4-byte region [0x602000000010,0x602000000014)
freed by thread T0 here:
    #0 0x55aa in operator delete(void*) (/w/build/app+0x1234)
    #1 0x55d4d1 in reset(Ring*) /w/src/ring.cpp:60:3
    #2 0x55d4c2 in tick(Engine&) /w/src/engine.cpp:85:3
    #3 0x55d4c3 in main /w/src/main.cpp:9:5

previously allocated by thread T0 here:
    #0 0x55bb in operator new(unsigned long) (/w/build/app+0x2234)
    #1 0x55d4e1 in make_ring() /w/src/ring.cpp:12:10
    #2 0x55d4c3 in main /w/src/main.cpp:7:5

SUMMARY: AddressSanitizer: heap-use-after-free /w/src/ring.cpp:41:12 in drain(Ring*)
]==])
  eq(report.kind, "AddressSanitizer: heap-use-after-free", "the report's kind")
  eq(vim.tbl_map(function(st) return { st.title, #st.frames, st.shared } end, report.stacks), {
    { "READ of size 4 thread T0", 4, 2 }, { "freed by thread T0", 4, 3 }, { "allocated by thread T0", 3, 3 } },
    "three stacks: the access, the free, the allocation; each meets the others first at tick or main")
  eq({ report.stacks[1].frames[1].name, report.stacks[1].frames[1].path, report.stacks[1].frames[1].line, report.stacks[2].frames[1].path },
    { "drain(Ring*)", "/w/src/ring.cpp", 41, nil }, "a frame: its function, file and line; one in a library has no source")
  for _, st in ipairs(report.stacks) do for _, f in ipairs(st.frames) do if f.path then f.rel = f.path:gsub("^/w/", "") end end end
  local page = Map.layout(Map.level_sanitizer({ report = report }), 110, false)
  local text = table.concat(page.lines, "\n")
  ok(text:find("AddressSanitizer: heap-use-after-free · 3 stacks", 1, true) and text:find("freed by thread T0", 1, true)
    and text:find("◆ tick  src/engine.cpp:88  where the stacks meet", 1, true) and text:find("◆ main  src/main.cpp:7  where the stacks meet", 1, true),
    "the page: each stack, the frame where it meets the others marked\n" .. text)
  local row, l = line_with(page.lines, "drain  src/ring.cpp:41")
  eq(row and Map.item_at(page, row, l:find("drain", 1, true)).target.node.file, "src/ring.cpp", "… each frame with source a function to open")
  eq(#Map.sanitizer_stacks("no report here").stacks, 0, "text with no report: no stacks")
end
do
  -- A slowdown between two actual runs (Codex's #20): what was measured and how each run was made, then the commits
  -- between them, each a way onto the map; the observed slowdown kept apart from its possible causes.
  local a = { ok = true, job = { id = "j2", command = "make bench", head = "bbbbbbb2", clean = true, ended = 1700000600 },
    baseline = { id = "j1", command = "make bench", head = "aaaaaaa1", clean = false, ended = 1700000000 }, binary = "not recorded by the runs",
    metrics = { { name = "p99", value = 480, unit = "ns", previous = 400, delta = "+80", verdict = "worse" } },
    commits = { { sha = "bbbbbbb2cccc", subject = "a slower tick" } }, files = { "engine.c" } }
  local page = Map.layout(Map.level_regression({ answer = a }), 110, false)
  local text = table.concat(page.lines, "\n")
  ok(text:find("a slowdown between two runs · make bench", 1, true) and text:find("slower    make bench  at bbbbbbb", 1, true)
    and text:find("baseline  make bench  at aaaaaaa + edits", 1, true) and text:find("binaries  not recorded by the runs", 1, true),
    "the runs: each its command and commit, the baseline's edits said, the binaries not guessed\n" .. text)
  ok(text:find("what was measured (observed)", 1, true) and text:find("p99  480 ns  was 400  +80  worse", 1, true), "… the figures, observed")
  ok(text:find("what changed between them (possible causes) · 1 commits · 1 files", 1, true) and text:find("engine.c", 1, true), "… then the possible causes")
  local row, l = line_with(page.lines, "a slower tick")
  eq(row and Map.item_at(page, row, l:find("a slower tick", 1, true)).target, { kind = "commit", sha = "bbbbbbb2cccc" }, "… a commit a way onto the map (what it changed)")
  vim.g.desk_style = "retro"
  local narrow_retro = Map.layout(Map.level_regression({ answer = vim.tbl_extend("force", a, { files = { "src/engine.c", "src/book.cpp", "src/risk.cpp", "src/feed/queue.hpp" } }) }), 50, true)
  vim.g.desk_style = nil
  local wide_line = vim.iter(narrow_retro.lines):find(function(x) return vim.fn.strdisplaywidth(x) > 50 end)
  ok(not wide_line and table.concat(narrow_retro.lines, "\n"):find("src/feed/queue.hpp", 1, true), "… in retro at 50 columns: files as typed, every line within the page: " .. tostring(wide_line))
end
do
  -- A function as the binary has it (Codex's #15): its symbol and copies, or why it has none.
  local function page(level) return table.concat(Map.layout(Map.level_binary(level), 110, false).lines, "\n") end
  local with = page({ node = { label = "Queue::grow", binary = { symbol = "fox::Queue<int>::grow() [clone .isra.0]", clones = { "fox::Queue<int>::grow() [clone .isra.0] [clone .cold]" } } } })
  ok(with:find("symbol  fox::Queue<int>::grow() [clone .isra.0]", 1, true) and with:find("copies the compiler made of it · 1", 1, true) and with:find("[clone .cold]", 1, true),
    "its symbol and the copies folded into it\n" .. with)
  local inlined = page({ node = { label = "tiny" }, provider = { name = "binary", state = "ok", binary = "/w/build/app" } })
  ok(inlined:find("No symbol of its own in app: inlined into every caller, or not built into it", 1, true), "none in a binary that was read: why")
  ok(page({ node = { label = "tiny" }, provider = { name = "binary", state = "not built" } }):find("Requires a built binary", 1, true), "no binary read: what it needs")
end
do
  -- A test run's coverage in a file (Codex's #16): covered lines one colour, missed another, each function's count.
  local W = require("desk.work")
  local cbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, { "int tick() {", "  if (x) return 1;", "  return 0;", "}", "int spare() { return 2; }", "" })
  local ran, missed = W.coverage_marks(cbuf, { lines = { ["1"] = 3, ["2"] = 0, ["3"] = 3, ["9"] = 1 }, functions = { { name = "tick", line = 1, count = 3 }, { name = "spare", line = 5, count = 0 } } })
  eq({ ran, missed }, { 2, 1 }, "two lines ran, one did not (a line past the end left out)")
  local signs, texts = {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(cbuf, W.cover_ns, 0, -1, { details = true })) do
    if m[4].sign_hl_group then signs[m[2] + 1] = m[4].sign_hl_group end
    if m[4].virt_text then texts[m[2] + 1] = m[4].virt_text[1][1] end
  end
  eq({ signs[1], signs[2], signs[3] }, { "DeskCoverRan", "DeskCoverNot", "DeskCoverRan" }, "… each line's mark")
  eq({ texts[1], texts[5] }, { "  ran 3×", "  not run" }, "… and each function's count beside it")
  vim.api.nvim_buf_delete(cbuf, { force = true })
end
do
  -- Coverage on the version that ran (Codex's E2, 2026-11-19): marks were put at the recorded line numbers in the open
  -- file whatever changed since. Now: the same file, marks there; a changed one, the version that ran (read from the
  -- run's commit) in a read-only split by default, or today's file with only the lines unchanged since.
  local W = require("desk.work")
  eq(W.map_lines({ "a", "b", "c", "d" }, { "x", "a", "b", "C", "d" }), { [1] = 2, [2] = 3, [4] = 5 },
    "map_lines: each unchanged line to where it is now, a changed one to nothing")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function git(...) return vim.system({ "git", "-C", dir, ... }, { text = true }):wait() end
  git("init", "-q")
  local body = { "int tick() {", "  if (x) return 1;", "  return 0;", "}" }
  vim.fn.writefile(body, dir .. "/f.c")
  git("add", "f.c")
  git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "f")
  local head = vim.trim(git("rev-parse", "HEAD").stdout)
  local cov = { lines = { ["1"] = 3, ["2"] = 0, ["3"] = 3 } }
  local function marked(buf)
    local at = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, W.cover_ns, 0, -1, { details = true })) do
      if m[4].sign_hl_group then at[#at + 1] = m[2] + 1 end
    end
    table.sort(at)
    return at
  end
  local said, real_notify = {}, vim.notify
  vim.notify = function(m) said[#said + 1] = m end
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/f.c"))
  local code_buf, code_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local twenty = {}
  for i = 1, 20 do twenty[i] = "// " .. i end
  vim.api.nvim_buf_set_lines(code_buf, 0, 0, false, twenty)
  local offered
  W.show_coverage(code_buf, dir, "f.c", cov, { head = head, id = "r1", said = "run r1" }, function(choices, done) offered = choices; done(choices[1]) end)
  local then_buf = vim.api.nvim_get_current_buf()
  ok(offered and #offered == 2 and offered[1].label:find("version that ran", 1, true), "a changed file: the version that ran offered first")
  ok(then_buf ~= code_buf and vim.api.nvim_buf_get_name(then_buf):find("as run r1 tested it", 1, true), "… opened beside it: " .. vim.api.nvim_buf_get_name(then_buf))
  eq(vim.api.nvim_buf_get_lines(then_buf, 0, -1, false), body, "… the file as it was at the run's commit")
  eq({ marked(then_buf), marked(code_buf) }, { { 1, 2, 3 }, {} }, "… the marks on its lines, none on today's file")
  eq({ vim.bo[then_buf].modifiable, vim.fn.maparg("gf", "n", false, true).buffer }, { false, 1 }, "… read-only, gf to today's file")
  vim.cmd("close")
  vim.api.nvim_set_current_win(code_win)
  W.show_coverage(code_buf, dir, "f.c", cov, { head = head, id = "r1", said = "run r1" }, function(choices, done) done(choices[2]) end)
  eq(marked(code_buf), { 21, 22, 23 }, "mapped onto today's file: each line where it is now (20 lines above it)")
  vim.api.nvim_buf_set_lines(code_buf, 20, 21, false, { "int tick(void) {" })
  W.show_coverage(code_buf, dir, "f.c", cov, { head = head, id = "r1", said = "run r1" }, function(choices, done) done(choices[2]) end)
  eq(marked(code_buf), { 22, 23 }, "… a line changed since is not marked")
  ok(said[#said]:find("1 line changed since", 1, true), "… and the note says how many: " .. tostring(said[#said]))
  -- the same file: marks there, nothing asked; a run with edits says so; a commit not here, marks with a warning
  vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, body)
  local asked = false
  W.show_coverage(code_buf, dir, "f.c", cov, { head = head, id = "r1", said = "run r1", clean = false }, function() asked = true end)
  eq({ asked, marked(code_buf) }, { false, { 1, 2, 3 } }, "the file as it ran: marks here, nothing asked")
  ok(said[#said]:find("uncommitted edits", 1, true), "… a run with uncommitted edits says so: " .. tostring(said[#said]))
  W.show_coverage(code_buf, dir, "f.c", cov, { head = string.rep("d", 40), id = "r2", said = "run r2" }, function() asked = true end)
  ok(not asked and #marked(code_buf) == 3 and said[#said]:find("not in this checkout", 1, true), "a commit not here: marks with a warning: " .. tostring(said[#said]))
  vim.notify = real_notify
  vim.cmd("bwipeout!")
  vim.fn.delete(dir, "rf")
end
do
  -- Which test ran this changed function (Codex's E1, 2026-11-19): each run that kept coverage of the file, its lines
  -- moved from the version it ran onto today's file, counted over the function's lines today.
  local W = require("desk.work")
  local most = { name = "test_most.py", lines = { [21] = 4, [22] = 0, [23] = 1, [30] = 1 }, mapped = { [21] = true, [22] = true, [23] = true, [30] = true } }
  local some = { name = "test_some.py", lines = { [21] = 2, [22] = 0, [23] = 0 }, mapped = { [21] = true, [22] = true, [23] = true } }
  eq(W.function_hits(most, 21, 24), { ran = 2, total = 3, new = 1 }, "function_hits: 2 of its 3 executable lines ran; line 24 is new since the run")
  eq(W.ran_by_said({ some, most }, 21, 24), "ran by test_most.py 2 of 3 · test_some.py 1 of 3 · 1 line new since",
    "the review's words: each run's count, the most first, and what is new since")
  local none = { name = "test_none.py", lines = { [21] = 0, [22] = 0 }, mapped = { [21] = true, [22] = true } }
  eq(W.ran_by_said({ none }, 21, 24), "no test run with coverage ran it (test_none.py 0 of 2)", "… none ran it: said")
  eq(W.ran_by_said({ most }, 40, 44), nil, "… no executable line of the run in the function: nothing said")
  -- the runs, fetched: desk-work's suggestions with coverage, each run's lines read at its commit and moved onto today
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/bin", "p")
  local function git(...) return vim.system({ "git", "-C", dir, ... }, { text = true }):wait() end
  git("init", "-q")
  local body = { "int tick() {", "  if (x) return 1;", "  return 0;", "}" }
  vim.fn.writefile(body, dir .. "/f.c")
  git("add", "f.c")
  git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "f")
  local head = vim.trim(git("rev-parse", "HEAD").stdout)
  local suggest = vim.json.encode({ { id = "r1", label = "python3 'test_most.py'", ran = 2, lines = 3 }, { id = "r2", label = "plain", reason = "inferred" } })
  local cover = vim.json.encode({ ok = true, head = head, command = "python3 test_most.py", files = { ["f.c"] = { lines = { ["1"] = 4, ["2"] = 0, ["3"] = 1 } } } })
  vim.fn.writefile({ "#!/bin/sh", 'case "$1" in', "  suggest-tests) cat <<'J'", suggest, "J", ";;", "  coverage) cat <<'J'", cover, "J", ";;", "esac" }, dir .. "/bin/desk-work")
  vim.fn.setfperm(dir .. "/bin/desk-work", "rwxr-xr-x")
  local today = {}
  for i = 1, 20 do today[i] = "// " .. i end
  vim.list_extend(today, body)
  local got
  W.coverage_runs(dir, "f.c", table.concat(today, "\n") .. "\n", function(runs) got = runs end, { "sh", dir .. "/bin/desk-work" })
  ok(vim.wait(5000, function() return got ~= nil end), "coverage_runs answers")
  eq(got and #got, 1, "… only the run that kept coverage of the file")
  eq(got and { got[1].name, got[1].id, got[1].head, got[1].lines[21], got[1].lines[22], got[1].lines[23], got[1].lines[1] },
    { "test_most.py", "r1", head, 4, 0, 1, nil }, "… its lines moved by the twenty added above the function")
  eq(got and W.ran_by_said(got, 21, 24), "ran by test_most.py 2 of 3", "… and said for the function")
  -- the review's line for a changed function: from those runs, the function's lines today
  local R = require("desk.review")
  local f = { path = dir .. "/f.c", rel = "f.c" }
  R.covered_known[f.path] = { runs = got }
  local s = { name = "tick", at = { after = { 20, 0 } }, ends = { after = 23 } }
  eq(R.coverage_line(f, s), "ran by test_most.py 2 of 3", "the review: the line under a changed function")
  eq(R.coverage_line(f, { name = "gone", at = { before = { 3, 0 } } }), nil, "… a function the change removed: nothing")
  -- K on it (in the list): the working file opened at the function, the run's coverage (as it ran, with its commit) handed to
  -- show_coverage, which puts it on the version that ran when the file changed since
  local real_current, real_show, shown = R.current, W.show_coverage, nil
  W.show_coverage = function(buf, root, rel, cov, info) shown = { vim.api.nvim_buf_get_name(buf), root, rel, cov, info.head, info.id, vim.api.nvim_win_get_cursor(0)[1] } end
  vim.fn.writefile(today, dir .. "/f.c")   -- the working copy: twenty lines above the function since the run
  R.current = { files = { f }, index = 1, symbol = s, root = dir, row = { kind = "working" } }
  eq(require("desk.actions").available(require("desk.actions").get("review.coverage"), {}), true, "K: available on a function a run reached")
  local tabs = #vim.api.nvim_list_tabpages()
  R.coverage_of_symbol()
  eq(shown and { vim.fs.basename(shown[1]), shown[2], shown[3], shown[4], shown[5], shown[6], shown[7] },
    { "f.c", dir, "f.c", got[1].cov, head, "r1", 21 }, "K: the file at the function, the run's coverage as it ran and its commit to show_coverage")
  eq(#vim.api.nvim_list_tabpages(), tabs + 1, "… in a tab of its own")
  vim.cmd("tabclose")
  R.current = { files = { f }, index = 1, symbol = { name = "far", at = { after = { 40, 0 } }, ends = { after = 44 } }, root = dir, row = { kind = "working" } }
  eq(require("desk.actions").available(require("desk.actions").get("review.coverage"), {}), "no recorded test run reaches this function", "… greyed where no run reached it")
  R.current, W.show_coverage = real_current, real_show
  R.covered_known[f.path] = nil
  vim.fn.delete(dir, "rf")
end
do
  -- Two runs in one gutter (Codex's E3, 2026-11-19): a second run chosen used to replace the first; now it can be
  -- compared with it: both ran █, only the first ▌, only the second ▐, an executable line neither ran · (each distinct
  -- in monochrome retro, and code page 437 has all four), each run's lines moved onto today's file through its commit.
  local W = require("desk.work")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d", "e", "f" })
  local counts = W.compare_marks(buf, { [1] = 3, [2] = 0, [3] = 2, [4] = 0 }, { [1] = 1, [2] = 4, [3] = 0, [5] = 0 }, { "reconnect", "startup" })
  local function gutter(b)
    local at = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, W.cover_ns, 0, -1, { details = true })) do
      if m[4].sign_text then at[m[2] + 1] = { vim.trim(m[4].sign_text), m[4].sign_hl_group } end
    end
    return at
  end
  eq(gutter(buf), { { "█", "DeskCoverBoth" }, { "▐", "DeskCoverB" }, { "▌", "DeskCoverA" }, { "·", "DeskCoverNot" }, { "·", "DeskCoverNot" } },
    "both ran █, only the second ▐, only the first ▌, neither · (a line one run has not counted as not run by it)")
  eq(counts, { both = 1, a = 1, b = 1, neither = 2 }, "… and the counts")
  vim.api.nvim_buf_delete(buf, { force = true })
  -- two runs at two commits, lined up on today's file
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function git(...) return vim.system({ "git", "-C", dir, ... }, { text = true }):wait() end
  local function commit(lines)
    vim.fn.writefile(lines, dir .. "/f.c")
    git("add", "f.c")
    git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "f")
    return vim.trim(git("rev-parse", "HEAD").stdout)
  end
  git("init", "-q")
  local body = { "int tick() {", "  if (x) return 1;", "  return 0;", "}" }
  local first = commit(body)
  local ten = {}
  for i = 1, 10 do ten[i] = "// " .. i end
  local second = commit(vim.list_extend(vim.deepcopy(ten), body))
  local today = vim.list_extend(vim.list_extend(vim.deepcopy(ten), { "// one more" }), body)
  vim.fn.writefile(today, dir .. "/f.c")
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/f.c"))
  local code = vim.api.nvim_get_current_buf()
  local A = { id = "ra", name = "reconnect", head = first, cov = { lines = { ["1"] = 2, ["2"] = 2, ["3"] = 0 }, functions = { { name = "tick", line = 1, count = 2 } } } }
  local B = { id = "rb", name = "startup", head = second, cov = { lines = { ["11"] = 1, ["12"] = 0, ["13"] = 1 }, functions = { { name = "tick", line = 11, count = 1 } } } }
  local said = W.compare_coverage(code, dir, "f.c", A, B)
  eq(gutter(code), { [12] = { "█", "DeskCoverBoth" }, [13] = { "▌", "DeskCoverA" }, [14] = { "▐", "DeskCoverB" } },
    "each run's lines through its own commit: tick at 1 in the first, at 11 in the second, at 12 today")
  eq(said, "Comparing reconnect (▌) with startup (▐): both ran 1 line · only reconnect 1 · only startup 1 · neither 0.", "… the summary")
  local eol
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(code, W.cover_ns, 0, -1, { details = true })) do
    if m[4].virt_text then eol = { m[2] + 1, m[4].virt_text[1][1] } end
  end
  eq(eol, { 12, "  reconnect 2× · startup 1×" }, "… and the function's line says both counts")
  -- the choice: with one run's marks shown, another chosen asks compare or replace; compare draws both, replace one
  W.show_coverage(code, dir, "f.c", A.cov, { head = A.head, id = A.id, said = "run ra", name = "reconnect" }, function(choices, done) done(choices[2]) end)
  local asked
  W.place_run(code, dir, "f.c", B, function(choices, done) asked = vim.tbl_map(function(c) return c.label end, choices); done(choices[1]) end)
  eq(asked, { "Compare with the marks shown (reconnect)", "Replace them" }, "a second run: compare or replace")
  eq(gutter(code)[14], { "▐", "DeskCoverB" }, "… compare: both runs in the gutter")
  W.place_run(code, dir, "f.c", B, function(choices, done) asked = choices end)
  eq(vim.tbl_count(gutter(code)), 0, "the shown run chosen again: its marks taken off")
  W.show_coverage(code, dir, "f.c", A.cov, { head = A.head, id = A.id, said = "run ra", name = "reconnect" }, function(choices, done) done(choices[2]) end)
  W.place_run(code, dir, "f.c", B, function(choices, done) done(choices[2]) end)
  eq(gutter(code)[14], { "▎", "DeskCoverRan" }, "replace: the second run alone, as before")
  vim.cmd("bwipeout!")
  vim.fn.delete(dir, "rf")
end
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
do
  -- What the reader left out, beside each list on the page.
  local cut = vim.deepcopy(trace_answer)
  cut.steps[2].params_more = 2
  cut.steps[2].params[1].reads_more = 3
  cut.calls[2].args_more, cut.calls[2].sites_more, cut.calls[2].sites = 4, 9, { { line = 11 } }
  local cut_page = Map.layout(Map.trace_page(cut, { ["e.cpp::tick|params"] = true }), 140, false)
  ok(line_with(cut_page.lines, "1 shown · 2 more omitted (the reader keeps 16)"), "parameters left out: said under them")
  ok(line_with(cut_page.lines, "reads   px · ts   (2 shown · 3 more omitted)"), "fields left out: said beside them")
  ok(line_with(cut_page.lines, ":11 (10 calls, 1 kept)") and line_with(cut_page.lines, "3 → retries)   (2 shown · 4 more omitted)"),
    "calls and arguments left out: said on the call's line\n" .. table.concat(cut_page.lines, "\n"))
end
local traced = Map.layout(Map.trace_page(trace_answer), 90, false)
ok(line_with(traced.lines, "trace through `tick` · 3 functions") or line_with(traced.lines, "trace through tick · 3 functions"), "the trace's heading")
ok(line_with(traced.lines, " ║ tick ") and (select(2, line_with(traced.lines, " ║ tick ")) or ""):find("e.cpp:11$"),
  "a step a line (Codex's #3): the function it goes through with a double bar, its name on the left edge, its place on the right")
ok(line_with(traced.lines, "║     → bool · 32 lines · ▲ 41 ▼ 23"), "… what it returns, how big it is, how many come before and after it")
ok(line_with(traced.lines, "▲ 41 before · ▼ 23 after it in the map"), "the function it goes through: before and after, under the heading")
local up_row, up_line = line_with(traced.lines, "▲ 41 ▼ 23")
eq(up_row and Map.item_at(traced, up_row, up_line:find("▲ 41", 1, true)).target, { kind = "walk", q = "callers", node = trace_answer.steps[2] },
  "▲ on a card: Enter opens what comes before it")
eq(up_row and Map.item_at(traced, up_row, up_line:find("▼ 23", 1, true)).target.q, "reach", "… ▼ what comes after it")
ok(line_with(traced.lines, "║     ▾ uses (1)") and line_with(traced.lines, "║         t  reads   px · ts") and line_with(traced.lines, "║            writes  seq"),
  "what it reads and writes of each parameter, open on the function it goes through")
ok(line_with(traced.lines, "║     ▸ layout (1)"), "… and its layout, folded until asked")
ok(line_with(traced.lines, "║     ▾ parameters (1)") and line_with(traced.lines, "║         in  const ref  const Tick &  t"), "its parameters, open: which way, how passed, type, name")
ok(line_with(traced.lines, "│         in  moved in  Order &&  order") and line_with(traced.lines, "│         in  value     int       retries"), "… aligned in columns")
ok(line_with(traced.lines, "│         inout  ref  Ring &  ring"), "… inout where the callee can change the caller's value")
ok(line_with(traced.lines, "║     ▸ other callers (1)") and not line_with(traced.lines, "replay"), "its other callers, folded, counted")
for _, line in ipairs(traced.lines) do ok(api.nvim_strwidth(line) <= 90, "a line fits the page: " .. line) end
local call_row, call_line = line_with(traced.lines, "║     calls  submit(Order{t.px} → order · 3 → retries)")
ok(call_row and call_line:find(":11$"), "the call, indented under the step that makes it: each argument → its parameter, its line on the right")
ok(line_with(traced.lines, "│     calls  tick(t)"), "… an argument named as its parameter is said once")
local fold_row, fold_line = line_with(traced.lines, "other callers (1)")
local fold = fold_row and Map.item_at(traced, fold_row, fold_line:find("other callers", 1, true))
eq(fold and fold.target, { kind = "fold", fold = "e.cpp::tick|callers" }, "a fold's header is a hit, to open it")
local opened = Map.layout(Map.trace_page(trace_answer, { ["e.cpp::tick|callers"] = true, ["e.cpp::tick|params"] = false }), 90, false)
ok(line_with(opened.lines, "║     ▾ other callers (1)") and line_with(opened.lines, "║         replay  e.cpp:30"), "open: one caller a line, with where it is")
ok(line_with(opened.lines, "║     ▸ parameters (1)") and not line_with(opened.lines, "const Tick &  t"), "… and the parameters folded when she closed them")
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
-- One letter per field (Codex's #10): the byte map's letter, offset and size beside each field the step uses.
do
  local used = Map.layout(Map.trace_page(trace_answer, { ["e.cpp::tick|uses"] = true }, { ["e.cpp"] = { records = { TICK } } }), 110, false)
  ok(line_with(used.lines, "reads   a px @0 8B · e ts @24 8B") and line_with(used.lines, "writes  d seq @16 8B"),
    "the uses: each field with its byte map letter, offset and size\n" .. table.concat(used.lines, "\n"))
  eq(Map.member_letters(TICK).seq, { letter = "d", off = 16, size = 8 }, "… the letters the byte map gives")
  local plain = Map.layout(Map.trace_page(trace_answer, { ["e.cpp::tick|uses"] = true }), 110, false)
  ok(line_with(plain.lines, "reads   px · ts"), "… and the names alone while no layout is known")
end
ok(line_with(laid.lines, "║         t  Tick  32 B, align 8 · 1 line · 6 B padding") and line_with(laid.lines, "║             touches  a px@0 8 B · e ts@24 8 B · d seq@16 8 B"),
  "… its size, alignment, cache lines, its padding, and the fields this function touches with their offsets and sizes")
local row0 = line_with(laid.lines, " 0 │aaaaaaaa ▒c······│")
ok(row0 and line_with(laid.lines, "16 │dddddddd eeeeeeee│"), "the byte map: a letter per member over its bytes (a bit-field's by its bits), ▒ where bit-fields share one, · padding")
local function lit(drawn, row)
  local out = {}
  for _, m in ipairs(drawn.marks) do
    -- (the focus step's bar is lit too: it is no member)
    if m[1] == row and m[4] == "DeskMapFocus" and drawn.lines[row]:sub(m[2] + 1, m[3]) ~= "║" then out[#out + 1] = drawn.lines[row]:sub(m[2] + 1, m[3]) end
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
ok(line_with(traced_retro.lines, "║         IN  CONST REF  const Tick &  t") and line_with(traced_retro.lines, "║     + OTHER CALLERS (1)")
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
  ok(line_with(cpage.lines, "║     ┄ no call to submit: the route came back through a cycle here") and not line_with(cpage.lines, "calls  submit("),
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
do
  -- No way found: why, and the two sides to open.
  local none = { ok = true, q = "paths", from = { id = "a.cpp::feed", label = "feed" }, to = { id = "b.cpp::submit", label = "submit" }, depth = 16, paths = {},
    why = "ran_out", ends = { { id = "a.cpp::publish", label = "publish", file = "a.cpp", line = 9, depth = 3 } },
    callers = { { id = "b.cpp::drain", label = "drain", file = "b.cpp", line = 4, depth = 1 } } }
  local page = Map.layout(Map.level_query(none), 100, false)
  local text = table.concat(page.lines, "\n")
  ok(text:find("Both sides ran out of known calls", 1, true) and text:find("where feed's calls end", 1, true) and text:find("what calls submit, nearest first", 1, true),
    "no way: why, and the two sides")
  local row, l = line_with(page.lines, "publish  a.cpp:9  3 calls")
  eq(row and Map.item_at(page, row, l:find("publish", 1, true)).target.node.id, "a.cpp::publish", "… each a function to open")
end
do
  -- Where you are once a heading has scrolled away (Codex's E8): the map's pages as the graph's.
  local G = require("desk.callgraph")
  local page = Map.layout(Map.level_query(trace_answer), 90, false)
  local steps = vim.tbl_filter(function(h) return h.count == false end, page.heads)
  eq(#steps, 3, "a trace: each step a heading")
  local second = steps[2]
  ok(second.last_line > second.line, "… covering its card")
  eq(G.location(page, second.line + 1), "step 2 of 3 · " .. trace_answer.steps[2].label, "inside step 2's card, its heading gone: which step")
  eq(G.location(page, second.line), steps[1] and G.location(page, second.line) or nil, "… on its own heading line: the step above it, or nothing")
  local retro_page = Map.layout(Map.level_query(trace_answer), 90, true)
  local rsteps = vim.tbl_filter(function(h) return h.count == false end, retro_page.heads)
  eq(G.location(retro_page, rsteps[2].line + 1), "STEP 2 OF 3 · " .. trace_answer.steps[2].label, "… retro: capitals, the name as typed")
  -- a heading's section: its words without the count, then how far in
  local crowded = Map.layout(Map.level_nodes(crowd, "lua", "lua/mod.lua"), 120, false)
  local from = line_with(crowded.lines, "called from · 41")
  local function first_box(drawn, top) for i, b in ipairs(drawn.boxes) do if b.line >= top then return i end end end
  local at = G.location(crowded, from + 9)
  ok(at and at:match("^called from · %d+ of 41$"), "a section scrolled past its heading: \"called from · k of 41\": " .. tostring(at))
  -- a page with no heading: its title
  local titled = Map.level_modules(many)
  titled.header = { { "PROJECT MAP · eng", "DeskMapTitle" } }
  local drawn = Map.layout(titled, 100, false)
  ok(G.location(drawn, 20) and G.location(drawn, 20):find("^PROJECT MAP · eng · %d+ of 70$"), "no heading: the page's title: " .. tostring(G.location(drawn, 20)))
end
do
  -- y on a trace: the investigation as Markdown, for another person.
  local routed = vim.tbl_extend("force", vim.deepcopy(trace_answer), { to = "e.cpp::submit" })
  routed.calls[2] = { from = "e.cpp::tick", to = "e.cpp::submit", kind = "handoff", label = "tick ring", by_hand = false }
  local md = Map.investigation_md(routed, "abc1234", "The live caller checks it; replay drops it.", { type = "Tick", name = "px" })
  eq(vim.split(md, "\n"), {
    "## How tick is reached, and where it leads", "",
    "A possible path from `hot` (the farthest start the map found) to `submit` (chosen), 3 functions, at `abc1234`.", "",
    "1. `hot` — e.cpp:12", "2. `tick` — e.cpp:11 (the function asked about)", "   - hands off through tick ring (inferred from the code)", "3. `submit` — e.cpp:10", "",
    "Followed: `Tick.px` (matched by name on this route).", "", "The live caller checks it; replay drops it.", "" },
    "the question, the revision, each step with its place, the handoff relied on and how it was found, the field, her sentence")
  -- Codex's E15 (2026-11-19): the revision the map read, not HEAD when copied; what has moved since, the map's stale
  -- reason and what the answer left out, so the note can be read again tomorrow.
  local function lines_of(at, answer)
    return vim.split(Map.investigation_md(answer or routed, at, "", nil), "\n")
  end
  local function has(list, text) return vim.iter(list):any(function(l) return l == text end) end
  local same = lines_of({ map = "abc1234", now = "abc1234" })
  ok(same[3]:find("at `abc1234` (the revision the map read)", 1, true) and not vim.iter(same):any(function(l) return l:find("now at", 1, true) end),
    "the map's revision, said as the map's; the checkout still there: nothing more")
  local moved = lines_of({ map = "abc1234", now = "9c41d7e", dirty = true })
  ok(has(moved, "The checkout is now at `9c41d7e`, with uncommitted edits: lines may have moved since."), "the checkout moved and edited since: said")
  ok(has(lines_of({ map = "abc1234", now = "abc1234", dirty = true }), "The checkout has uncommitted edits since: lines may have moved."), "… edits alone: said")
  ok(has(lines_of({ map = "abc1234", now = "9c41d7e", stale = "3 files changed since the build" }), "The map was stale: 3 files changed since the build."), "the map's stale reason")
  local cut = vim.tbl_extend("force", vim.deepcopy(routed), { excluded = { "lua/log.lua::log", "alloc.c::xmalloc" } })
  ok(has(lines_of({ map = "abc1234", now = "abc1234" }, cut), "Left out of this answer: `log` · `xmalloc` (`z` on the map)."), "what the answer left out")
end
do
  -- Findings on this path: only those inside the route's functions, each with its step.
  local steps = { { label = "tick", file = "e.cpp", line = 11, lines = 32 }, { label = "submit", file = "e.cpp", line = 50, lines = 5 } }
  local on = Map.findings_on(steps, { { file = "e.cpp", line = 20, severity = "warning", message = "copied by value", tool = "lint" },
    { file = "/r/e.cpp", line = 52, severity = "error", message = "unchecked result", tool = "lint" },
    { file = "e.cpp", line = 45, message = "between the two" }, { file = "other.cpp", line = 12, message = "elsewhere" } }, "/r")
  eq(vim.tbl_map(function(f) return { f.file, f.line, f.step } end, on), { { "e.cpp", 20, "tick" }, { "e.cpp", 52, "submit" } },
    "findings inside the route's functions only (an absolute path under the checkout read as its own), each with its step")
  local text = table.concat(Map.layout(Map.level_findings({ on = on, tools = 1 }), 100, false).lines, "\n")
  ok(text:find("findings on this path · 2 (from 1 tool)", 1, true) and text:find("error  unchecked result  e.cpp:52 · in submit · lint", 1, true), "… drawn with severity, place, step and tool")
end
do
  -- The parts page's count is a hit: the interface one part uses of the other, by entry function.
  local parts = Map.layout(Map.level_modules({ ok = true, modules = { { name = "lua", files = 2, functions = 9 }, { name = "csrc", files = 1, functions = 3 } },
    edges = { { from = "lua", to = "csrc", count = 4 } } }), 100, false)
  local row, l = line_with(parts.lines, "lua → csrc · 4 calls")
  local hit = row and Map.item_at(parts, row, l:find("4 calls", 1, true))
  eq(hit and hit.target, { kind = "crossings", from = "lua", to = "csrc" }, "the count of calls between two parts is a hit")
  local page = Map.layout(Map.level_query({ ok = true, q = "crossings", from = "lua", to = "csrc", calls = 3,
    entries = { { node = { id = "csrc/p.c::leaf", label = "leaf", file = "csrc/p.c", line = 2 }, count = 2,
      callers = { { id = "lua/a.lua::alpha", label = "alpha", file = "lua/a.lua", line = 3 }, { id = "lua/b.lua::beta", label = "beta", file = "lua/b.lua", line = 5 } } } } }), 100, false)
  local text = table.concat(page.lines, "\n")
  ok(text:find("how lua uses csrc · 1 entry function, 3 calls in", 1, true) and text:find("leaf  p.c:2 · 2 callers", 1, true) and text:find("from alpha · beta", 1, true),
    "the crossings: each entry function with its callers from the other part")
end
do
  -- Where a function's result goes, read from each call's line.
  local cases = {
    { "  submit(order);", "discarded" }, { "  (void)submit(order);", "discarded on purpose (void)" }, { "  return submit(order);", "returned upward" },
    { "  if (!submit(order)) retry();", "checked" }, { "  ok = ok && submit(order);", "checked" }, { "  auto st = submit(order);", "kept in a variable" },
    { "  st = mgr.submit(order);", "kept in a variable" }, { "  log(submit(order));", "used in an expression" }, { "  mgr->submit(order); // fire", "discarded" },
  }
  for _, c in ipairs(cases) do eq(Map.result_use(c[1], "submit"), c[2], "result: " .. vim.trim(c[1])) end
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ "void a() {", "  if (!submit(o)) retry();", "  submit(p);", "}" }, root .. "/a.cpp")
  local page = Map.layout(Map.level_query({ ok = true, q = "calls-into", to = { id = "o.cpp::submit", label = "Mgr::submit" },
    callers = { { node = { id = "a.cpp::a", label = "a", file = "a.cpp", line = 1 }, sites = { { line = 2 }, { line = 3 } } } } }, { root = root }), 110, false)
  local text = table.concat(page.lines, "\n")
  ok(text:find("where `Mgr::submit`'s result goes · 2 calls", 1, true) or text:find("where Mgr::submit's result goes · 2 calls", 1, true), "the page: how many calls")
  ok(text:find("1 checked · 1 discarded (read from each call's line)", 1, true) and text:find("discarded  a  a.cpp:3  submit(p);", 1, true), "… what each does with it, the line shown")
  vim.fn.delete(root, "rf")
  local hit_page = Map.layout(Map.trace_page(trace_answer), 90, false)
  local r, l = line_with(hit_page.lines, "→ bool")
  eq(r and Map.item_at(hit_page, r, l:find("→ bool", 1, true)).target.kind, "result", "a step's → type is a hit: where its result goes")
end
do
  -- The debugger's stack on the map: its frames, and which of the stopped function's callers in the map are on it.
  local real_dap = package.loaded["dap"]
  package.loaded["dap"] = nil
  local none, why = Map.dap_frames()
  eq({ none, why }, { nil, "not debugging (F5 starts the debugger)" }, "no debugger: said")
  eq(require("desk.actions").get("map.debug-stack").available(), "not debugging (F5 starts the debugger)", "… and Space c s says why it cannot run")
  package.loaded["dap"] = { session = function() return { stopped_thread_id = 3, threads = { [3] = { frames = {
    { name = "Engine::tick(Tick const&)", source = { path = "/r/e.cpp" }, line = 20 }, { name = "live_feed(int)", source = { path = "/r/f.cpp" }, line = 7 } } } } } end }
  local frames, _, thread = Map.dap_frames()
  eq({ #frames, frames[1].name, frames[1].line, thread }, { 2, "Engine::tick(Tick const&)", 20, 3 }, "stopped: the stopped thread's frames, innermost first")
  frames[1].rel, frames[2].rel = "e.cpp", "f.cpp"
  local text = table.concat(Map.layout(Map.level_stack({ frames = frames, thread = 3, callers = {
    { id = "f.cpp::live_feed", label = "live_feed", file = "f.cpp", line = 5 }, { id = "r.cpp::replay", label = "replay", file = "r.cpp", line = 9 } } }), 100, false).lines, "\n")
  ok(text:find("the stack where it stopped · thread 3 · 2 frames", 1, true) and text:find("Engine::tick(Tick const&)  e.cpp:20  (stopped here)", 1, true), "the frames, the stop said")
  ok(text:find("live_feed  f.cpp:5  on this stack", 1, true) and text:find("replay  r.cpp:9  not on this stack", 1, true), "… and which caller brought it here: live on the stack, replay not")
  package.loaded["dap"] = real_dap
end
local handed = vim.deepcopy(trace_answer)
handed.calls[2] = { from = "e.cpp::tick", to = "e.cpp::submit", kind = "handoff", label = "tick_ring: push :11 → pop :20", line = 11, to_line = 20 }
local handed_page = Map.layout(Map.trace_page(handed), 90, false)
ok(line_with(handed_page.lines, " ══ handoff · inferred ══ tick_ring: push :11 → pop :20 ══"), "a handoff between steps: a full-width break, inferred said where the reader decides to trust it")
ok(not line_with(handed_page.lines, "calls  submit("), "… with no call's arguments, as there is no call")
do
  local row, text = line_with(handed_page.lines, "══ tick_ring")
  local hit = row and Map.item_at(handed_page, row, text:find("tick_ring", 1, true))
  eq(hit and { hit.target.kind, hit.target.from, hit.target.to, hit.target.by_hand, hit.target.producer, hit.target.consumer },
    { "handoff", "e.cpp::tick", "e.cpp::submit", false, { label = "tick", file = "e.cpp", line = 11 }, { label = "submit", file = "e.cpp", line = 20 } },
    "… the handoff a hit (x drops it, Enter opens either side), naming its two ends and where each is")
  handed.calls[2].by_hand = true
  ok(line_with(Map.layout(Map.trace_page(handed), 90, false).lines, "══ handoff · added by you ══ tick_ring: push :11 → pop :20"), "one she added says so")
end
local way_row, way = line_with(ways.lines, "use → M.alpha → M.beta")
ok(way_row and way:find("(by name)", 1, true), "a way, with the part found by name said")
eq(Map.item_at(ways, way_row, way:find("M.alpha", 1, true)).target.node.id, "lua/mod.lua::M.alpha", "each name on a way is a hit")

-- ─── its keys: rows of the action registry ─────────────────────────────────────────────────────────────────────
local A = require("desk.actions")
local Menu = require("desk.menu")
eq(A.problems, {}, "every map row was taken")
local function keys_of(surface) return vim.tbl_map(function(k) return k.key end, A.keys(surface)) end
eq(keys_of("map"), { "?", "<CR>", "<BS>", "-", "+", "D", "U", "c", "t", "e", "S", "T", "x", "a", "F", "K", "y", "gs", "P", "gP", "M", "z", "Z", "gb", "W", "i", "r", "R", "B", "q", "o", "j", "k", "h", "l" },
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
  elseif args[2] == "query" and args[6] == "paths" then
    answer = paths
    local at = vim.fn.index(args, "--avoid")
    if at >= 0 then   -- as desk-work answers --avoid (src/desk-work/tests/test_map.py): here, no way avoids it
      answer = vim.tbl_extend("force", paths, { paths = {}, avoided = { id = args[at + 2], label = (args[at + 2]:match("::(.+)$")) },
        searched = { built_at = 1700000000, edges = { "call", "call-by-name", "handoff" }, depth = 10, max = 20, complete = true } })
    end
  end
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
ok(line_with(view.drawn.lines, "calls matched by name · binary not built · i why"), "the footer: the evidence in one plain line (Codex's #4), i for the rest")
ok(not line_with(view.drawn.lines, "answered by syntax (calls by name"), "… not the whole explanation")
view.evidence_open = true
Map.render(view)
ok(line_with(view.drawn.lines, "answered by syntax (calls by name"), "i: the footer names the reader that answered")
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
  ok(line_with(view.drawn.lines, "│ m70") and not line_with(view.drawn.lines, "show more"), "the map's tab draws all seventy parts, its key line no m")
  view.cache.modules = saved
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
-- z: a function left out of the map's answers until Z (Codex's C5); the page says so where the answer is read.
do
  local n0, notify = #asked, vim.notify
  vim.notify = function() end
  Map.exclude(view, { id = "lua/mod.lua::helper", label = "helper" })
  ok(vim.wait(1000, function() return #asked >= n0 + 2 end), "z: the page asked again")
  ok(asked[#asked]:find("--q reach --from lua/other.lua::use --depth 2", 1, true) and asked[#asked]:find("--exclude lua/mod.lua::helper", 1, true), "… the same question, without the function left out: " .. asked[#asked])
  Map.exclude(view, { id = "csrc/prog.c::log", label = "log" })
  ok(vim.wait(1000, function() return asked[#asked]:find("--exclude lua/mod.lua::helper\ncsrc/prog.c::log", 1, true) ~= nil end), "… two left out")
  local n1 = #asked
  Map.include_all(view)
  ok(vim.wait(1000, function() return #asked >= n1 + 2 end) and not asked[#asked]:find("--exclude", 1, true), "Z: asked again with everything back")
  vim.notify = notify
  local said = Map.layout(Map.level_query({ ok = true, q = "reach", from = { id = "a", label = "a" }, nodes = {}, steps = {}, excluded = { "lua/log.lua::log", "c/alloc.c::alloc" } }), 100, false)
  ok(line_with(said.lines, "2 left out of this answer: log · alloc  · Z brings them back"), "the page's first line: what was left out, and the key")
end
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
  ok(vim.wait(1000, function() return line_with(view.drawn.lines, " ║ tick ") end), "t: the trace page, drawn")
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
    eq({ said, #view.stack, line_with(view.drawn.lines, " ║ tick ") ~= nil }, { {}, depth, true }, "… and quiet: nothing said, the trace kept")
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
    ok(vim.wait(1000, function() return line_with(view.drawn.lines, "══ handoff · inferred ══ tick_ring ══") end), "the trace with a handoff, read again")
    vim.wait(300, function() return false end) -- r reads the status too: its redraw lands before the cursor is placed
    local said, real_notify, real_input = {}, vim.notify, vim.ui.input
    vim.notify = function(m) said[#said + 1] = m end
    local hrow, htext = line_with(view.drawn.lines, "══ tick_ring")
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
    local trow, ttext = line_with(view.drawn.lines, " ║ tick ")
    api.nvim_win_set_cursor(view.win, { trow, (ttext:find("tick", 1, true)) })
    vim.ui.input = function(opts, done) eq(opts.prompt, "Hands off to: ", "a asks where to"); done("consumer") end
    press("a")
    ok(vim.wait(1000, function() return #corrections == 2 end), "a on a step: desk-work adds a handoff")
    eq(corrections[2], "map handoff add --root " .. view.root .. " --from e.cpp::tick --to consumer", "… from that step to the one named")
    vim.wait(200, function() return false end)
    -- Her corrections reviewed (Codex's #38): each checked against the map as built now; Enter forgets, rebinds, opens.
    do
      local tick_node = { id = "e.cpp::tick", label = "tick", file = "e.cpp", line = 11 }
      local review = { ok = true, q = "handoffs", file = "/c/foxml/desk.d/map-x.json", entries = {
        { side = "add", label = "a queue", own = true, declared_in = "/c/foxml/desk.d/map-x.json", from = { id = "e.cpp::tick", state = "ok", node = tick_node },
          to = { id = "e.cpp::gone", state = "ambiguous", candidates = { { id = "a.cpp::gone", label = "gone", file = "a.cpp", line = 3 },
            { id = "b.cpp::gone", label = "gone", file = "b.cpp", line = 9 } } } },
        { side = "drop", own = false, stale = true, declared_in = view.root .. "/.desk/tools.json", from = { id = "e.cpp::hot", state = "gone" },
          to = { id = "e.cpp::tick", state = "ok", node = tick_node } } } }
      local corrected = Map.desk_work
      Map.desk_work = function(args, done)
        if table.concat(args, " "):find("--q handoffs", 1, true) then return vim.defer_fn(function() done(vim.deepcopy(review), { code = 0 }) end, 5) end
        return corrected(args, done)
      end
      local depth0, n0 = #view.stack, #corrections
      require("desk.actions").get("map.handoffs").run({ map = view })
      ok(vim.wait(1000, function() return line_with(view.drawn.lines, "handoff corrections · 2") end), "the corrections review: a page of its own")
      ok(line_with(view.drawn.lines, "added    tick → gone  (ambiguous: several now)   ══ a queue ══"), "… an added one, its end that is several now said")
      ok(line_with(view.drawn.lines, "dropped  hot  (gone from the map) → tick"), "… a dropped one whose end is gone")
      ok(line_with(view.drawn.lines, "the reader no longer reads this as a handoff") and line_with(view.drawn.lines, ".desk/tools.json (yours to edit there)"),
        "… a stale drop said, and one declared elsewhere is hers to edit there")
      local rrow, rtext = line_with(view.drawn.lines, "added    tick")
      api.nvim_win_set_cursor(view.win, { rrow, (rtext:find("tick", 1, true)) })
      local menu_of, pick, saved_select = nil, "rebind-to-2", vim.ui.select
      vim.ui.select = function(items, opts, done)
        menu_of = vim.tbl_map(opts.format_item, items)
        for _, it in ipairs(items) do if it.id == pick then return done(it) end end
        done(nil)
      end
      press("<CR>")
      ok(vim.wait(1000, function() return #corrections == n0 + 2 end), "Enter: what to do with it, and the rebind done")
      eq(menu_of, { "forget this correction", "open tick · e.cpp:11", "rebind its to to gone · a.cpp:3", "rebind its to to gone · b.cpp:9" },
        "… forget, open the end still there, rebind the other to each of the functions of its name now")
      eq({ corrections[n0 + 1], corrections[n0 + 2] }, { "map handoff forget --root " .. view.root .. " --from e.cpp::tick --to e.cpp::gone",
        "map handoff add --root " .. view.root .. " --from e.cpp::tick --to b.cpp::gone --label a queue" },
        "… a rebind: the old one forgotten by the ids it was kept by, the new one added with its label")
      vim.wait(200, function() return false end)
      Map.desk_work, vim.ui.select = corrected, saved_select
      while #view.stack > depth0 do press("<BS>"); vim.wait(50, function() return false end) end
      ok(vim.wait(1000, function() return #view.stack == depth0 end), "… and back to the trace")
    end
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
    ok(vim.wait(1000, function() return line_with(view.drawn.lines, "══ ring ══") end), "the handoff drawn")
    vim.wait(300, function() return false end)
    local hr, ht = line_with(view.drawn.lines, "══ ring ══")
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
    -- F: the findings of the checkout's findings tools that fall on this route, a page of their own.
    local before_f = #view.stack
    local outer = Map.desk_work
    Map.desk_work = function(args, done)
      if args[1] == "tools" and args[2] == "list" then return done({ ok = true, tools = { { id = "lint", name = "lint", gives = "findings" }, { id = "perf", gives = "figures" } } }) end
      if args[1] == "tools" and args[2] == "result" then return done({ format = "desk-result/1", findings = { { file = "e.cpp", line = 15, severity = "warning", message = "px read twice" } } }) end
      return outer(args, done)
    end
    press("F")
    ok(vim.wait(1000, function() return #view.stack == before_f + 1 and line_with(view.drawn.lines, "px read twice") end), "F: the findings on this path, a page of their own")
    Map.desk_work = outer
    press("<BS>")
    vim.wait(100, function() return false end)
    -- y: the investigation copied, her sentence in it.
    vim.fn.setreg('"', "")
    vim.ui.input = function(opts, done) eq(opts.prompt, "A sentence to add (optional): ", "y asks for her sentence"); done("Checked the live path.") end
    press("y")
    local copied = vim.fn.getreg('"')
    ok(copied:find("## How tick is reached", 1, true) and copied:find("Checked the live path.", 1, true) and copied:find("e.cpp:11 (the function asked about)", 1, true),
      "y: the investigation copied as Markdown: " .. copied:sub(1, 200))
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
-- gP on a function of a way: the same two ends, every way avoiding it (Codex's C3)
do
  local row, text = line_with(view.drawn.lines, "use → M.alpha → M.beta")
  api.nvim_win_set_cursor(view.win, { row, (text:find("M.alpha", 1, true)) })
  press("gP")
  ok(asked[#asked]:find("--q paths --from lua/other.lua::use --to lua/mod.lua::M.beta --avoid lua/mod.lua::M.alpha", 1, true), "gP: the ways again, avoiding it: " .. asked[#asked])
  ok(vim.wait(1000, function() return line_with(view.drawn.lines, "No way from use to M.beta avoids M.alpha in the map.") end), "… none here: said")
  local narrow_no = Map.layout(Map.level_query({ ok = true, q = "paths", from = { id = "a", label = "on_order" }, to = { id = "b", label = "submit" }, depth = 10, paths = {},
    avoided = { id = "v", label = "validate" }, searched = { built_at = os.time(), depth = 10, complete = false } }), 60, false)
  ok(not vim.iter(narrow_no.lines):find(function(x) return vim.fn.strdisplaywidth(x) > 60 end), "… what was searched wraps within the page")
  ok(line_with(view.drawn.lines, "Searched: the map built ") and line_with(view.drawn.lines, "calls, calls matched by name and handoffs"), "… with what was searched")
  press("<BS>")
  ok(vim.wait(1000, function() return line_with(view.drawn.lines, "ways from use to M.beta ·") end), "Backspace: the ways again")
  local some = Map.layout(Map.level_query({ ok = true, q = "paths", from = { id = "a", label = "order" }, to = { id = "b", label = "submit" }, depth = 10,
    avoided = { id = "v", label = "validate" }, paths = { { nodes = { "a", "c", "b" } } }, nodes = { { id = "c", label = "fast_path" } } }), 120, false)
  ok(line_with(some.lines, "1 way reaches submit without going through validate: each is a bypass to look at"), "a bypass found: said, and drawn")
end
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
view.evidence_open = nil
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
eq(remote_ids, { "map.avoid", "map.callers", "map.centre", "map.changes", "map.copy", "map.down", "map.exclude", "map.expand", "map.findings", "map.handoff-add", "map.handoff-drop", "map.handoffs", "map.in", "map.in-binary", "map.include", "map.left", "map.out", "map.paths", "map.reach", "map.read", "map.rebuild", "map.right", "map.symdeps", "map.tests", "map.trace", "map.trace-all", "map.trace-from", "map.trace-to", "map.up", "map.why" },
  "the pop-out keeps its navigation keys (no m: nothing is left out)")
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
  Map.trace_at(repo .. "/shared/nvim_lua/desk/map.lua", 10, { pop = 2, q = "flow" })
  ok(asked and asked.args:find("--q flow --file shared/nvim_lua/desk/map.lua --line 10", 1, true), "… q = flow: the whole trace, by its place: " .. vim.inspect(asked))
  package.loaded["desk.popout"], Map.desk_work = real_P, real_dw
end
-- How an action or a message works: the notebook's g on a failure is the callgraph message — who sends it, the relay,
-- the handler — each with its place.
do
  require("desk.callgraph")
  local repo = vim.fs.root(debug.getinfo(1, "S").source:sub(2), ".git")
  local saved_path = vim.env.PATH
  vim.env.PATH = "/usr/bin:/bin" -- git only (this section keeps every other program off PATH)
  local steps = A.how({ message = "callgraph" }, repo)
  vim.env.PATH = saved_path
  local files = vim.tbl_map(function(st) return st.file and vim.fs.basename(st.file) or "-" end, steps or {})
  ok(vim.tbl_contains(files, "work.ts") and vim.tbl_contains(files, "editor.hpp") and files[#files] == "callgraph.lua",
    "callgraph: sent by the notebook (work.ts), relayed by desk-work (editor.hpp), answered in callgraph.lua: " .. vim.inspect(files))
  local last = steps[#steps]
  ok(last.text:find("answered here: the callgraph handler", 1, true) and last.line and last.line > 0, "… the handler's own line")
  local row_steps = A.how({ row = A.get("map.trace") }, repo)
  eq({ row_steps[1].text:find("you press t on map", 1, true) ~= nil, vim.fs.basename(row_steps[2].file or "") }, { true, "map.lua" }, "a key: what you press, then the function it runs")
  local none, why = A.how({ message = "no-such" }, repo)
  eq({ none, why }, { nil, '"no-such" is not a message this editor takes' }, "an unknown message: said")
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
  eq(Map.strip_text(fn, G), { "tt::tick · e.cpp:11 → bool", "Enter open tt::tick (e.cpp:11)         · t trace · c calls · D reach · U callers · gs inspect" },
    "a function: what it is, then Enter source · t trace · c calls …, gs where symdeps can look (C and C++)")
do
  -- the first slot is one width: what follows Enter starts in the same column for every kind of item (Codex's #9)
  local G = Map.glyphs(false)
  local a = Map.strip_text({ target = { kind = "node", node = { id = "x", label = "x", file = "x.lua", line = 1 } } }, G)[2]
  local b = Map.strip_text({ name = "ring", target = { kind = "handoff", by_hand = false } }, G)[2]
  eq(vim.fn.strdisplaywidth(a:match("^(.-) · ")), vim.fn.strdisplaywidth(b:match("^(.-) · ")), "Enter's slot: the same width on a function and on a handoff")
  -- retro shouts the words, never the code or the key (seen in the VM pass, 2026-11-19: "OPEN DRAIN (ENGINE.CPP:20)")
  local loud = Map.strip_text({ target = { kind = "node", node = { id = "x", label = "tt::tick", file = "src/e.cpp", line = 11 } } }, Map.glyphs(true))[2]
  ok(loud:find("Enter OPEN tt::tick (e.cpp:11)", 1, true), "retro: the name and its place as typed: " .. loud)
  vim.g.desk_style = "retro"
  local foot = Map.footer({ status = { providers = { { name = "syntax", state = "ok" }, { name = "binary", state = "not built", why = "x" } } } }, Map.glyphs(true), false)
  vim.g.desk_style = nil
  eq(foot[1], { "CALLS MATCHED BY NAME · BINARY NOT BUILT · i WHY" }, "… and the footer's key as typed (i, not I)")
end
  eq(Map.strip_text({ name = "layout (2)", open = false, target = { kind = "fold", fold = "x|layout" } }, G), { "layout (2)", "Enter open it" }, "a fold: Enter opens it")
  eq(Map.strip_text({ name = "tick ring", target = { kind = "handoff", by_hand = false } }, G)[2], "Enter open producer or consumer        · x drops it (it is wrong)", "a handoff: Enter either side, x drops it")
  eq(Map.strip_text({ name = "a → b", target = { kind = "call", caller = "a", callee = "b", sites = { { line = 3 }, { line = 9 } } } }, G),
    { "a → b — 2 calls", "Enter open call site (2: pick)" }, "a call with two sites: Enter lists them")
  local payload = P._payload(pv)
  ok(vim.iter(payload.items):any(function(i) return type(i.keys) == "string" and i.keys:find("^Enter ") ~= nil end), "the pop-out's items carry their line, Enter's slot first")
  local line = P._keyline({ id = "v", copy = { index = 1 }, items = { { keys = "Enter open tt::tick (e.cpp:11) · t trace   tt::tick · e.cpp:11" } }, footer = {} })
  ok(line:find("Enter open tt::tick (e.cpp:11)%< · t trace   tt::tick · e.cpp:11", 1, true) and line:find("?%#DeskPopoutWords# keys", 1, true),
    "the key line: Enter's slot, then where a narrow window may cut (%<), then the rest: " .. line)
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
-- T on a trace: the whole trace, asked with that trace's question (its function, and the end and start she chose).
do
  local stack, inner, asked, history = pv.stack, Map.desk_work, {}, vim.deepcopy(P.host.history)
  local routed = vim.deepcopy(trace_answer)
  routed.to = "e.cpp::submit"
  pv.stack = { { kind = "modules" }, { kind = "query", answer = routed, args = { "--q", "trace", "--from", "e.cpp::tick", "--to", "e.cpp::submit" } } }
  Map.desk_work = function(args, done)
    asked[#asked + 1] = table.concat(args, " ")
    if args[2] == "query" then return vim.defer_fn(function() done({ ok = true, q = "flow", focus = "e.cpp::tick", nodes = {}, edges = {}, lane = {} }, { code = 0 }) end, 5) end
    return inner(args, done)
  end
  eq(act("map.trace-all", nil), { true }, "T on a trace, from the pop-out")
  ok(vim.wait(1000, function() return #pv.stack == 3 end), "… its answer a page of its own")
  ok(asked[#asked] and asked[#asked]:find("--q flow --from e.cpp::tick --to e.cpp::submit", 1, true), "… asked with the trace's function and end: " .. tostring(asked[#asked]))
  local fn = { ref = { target = { kind = "node", node = { id = "e.cpp::drain", label = "drain", file = "e.cpp", line = 40 } } } }
  pv.stack = { { kind = "modules" } }
  act("map.trace-all", fn)
  ok(vim.wait(1000, function() return asked[#asked]:find("--q flow --from e.cpp::drain", 1, true) ~= nil end), "T on a function: the whole trace through it")
  pv.stack, Map.desk_work, P.host.history = stack, inner, history
  pv.pinned = false
end
-- y on a trace (Codex's E15): the note names the revision the map read (its build), not HEAD when copied, and its
-- stale reason.
do
  local stack, status, root, path = pv.stack, pv.status, pv.root, vim.env.PATH
  vim.env.PATH = saved_path   -- git, for the copy's own HEAD and status (this section keeps PATH empty otherwise)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function git(...) return vim.system({ "git", "-C", dir, ... }, { text = true }):wait() end
  git("init", "-q")
  vim.fn.writefile({ "x" }, dir .. "/e.cpp")
  git("add", "e.cpp")
  git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "e")
  local now = vim.trim(git("rev-parse", "--short=7", "HEAD").stdout)
  pv.root = dir
  pv.stack = { { kind = "modules" }, { kind = "query", answer = trace_answer, args = { "--q", "trace", "--from", "e.cpp::tick" } } }
  pv.status = { head = "0123456789abcdef0123", built = true, stale = true, stale_why = "2 files changed since the build" }
  vim.fn.setreg('"', "")
  eq(act("map.copy", nil), { true }, "y on a trace, from the pop-out")
  local md = vim.fn.getreg('"')
  ok(md:find("at `0123456` (the revision the map read)", 1, true), "y: the revision the map read, not HEAD: " .. md:sub(1, 300))
  ok(md:find("The checkout is now at `" .. now .. "`: lines may have moved since.", 1, true), "… HEAD said as where the checkout is now")
  ok(md:find("The map was stale: 2 files changed since the build.", 1, true), "… and its stale reason")
  pv.stack, pv.status, pv.root, vim.env.PATH = stack, status, root, path
  vim.fn.delete(dir, "rf")
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
-- Two pop-outs as a pair: gp makes one the preview pane; another's map tells its selection; the pane shows that place.
do
  local real_show = P.preview_show
  P.preview_pop = nil
  eq(P._payload(pv).previewed, nil, "no preview pane: the map's selection is not told")
  P.preview_pop = 99
  eq(P._payload(pv).previewed, true, "… another pop-out previews: it is")
  eq(P._payload(pv).partner, "preview → 99", "… and its header names its partner (Codex's #6)")
  local node_ref = { name = "M.alpha", target = { kind = "node", node = { id = "lua/mod.lua::M.alpha", label = "M.alpha", file = "lua/mod.lua", line = 3 } } }
  eq({ K.place(pv, node_ref) }, { pv.root .. "/lua/mod.lua", 3 }, "a function's place: its file and line")
  eq({ K.place(pv, { target = { kind = "call", file = "e.cpp", sites = { { line = 11 } } } }) }, { pv.root .. "/e.cpp", 11 }, "… a call's: its line")
  eq({ K.place(pv, { target = { kind = "handoff", producer = { file = "e.cpp", line = 7 } } }) }, { pv.root .. "/e.cpp", 7 }, "… a handoff's: its push")
  local shown
  P.preview_show = function(file, line) shown = { file, line } end
  pv.refs, pv.count = { node_ref }, 1
  local answer = P._selected({ pop = pv.pop, view = pv.id, gen = pv.gen, item = 1 })
  ok(answer.shown and vim.wait(500, function() return shown ~= nil end), "a selection told: placed")
  eq(shown, { pv.root .. "/lua/mod.lua", 3 }, "… at its file and line, in the preview pane")
  eq({ P.partner_of({ previewing = true }), P.preview_from.line }, { "following ← " .. tostring(P.preview_from.pop) .. ": M.alpha", 3 }, "… which names what drives it, and the line")
  local mbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(mbuf, 0, -1, false, { "a", "b", "c" })
  P.mark_partner({ buf = mbuf, partner_line = 3, partner = "following ← 1: M.alpha" })
  local marks = vim.api.nvim_buf_get_extmarks(mbuf, -1, 0, -1, { details = true })
  eq(vim.tbl_map(function(m) return { m[2] + 1, m[4].virt_lines and m[4].virt_lines[1][1][1], m[4].virt_lines_above } end, marks), { { 3, "▼ selected in 1: M.alpha", true } },
    "… and the preview marks that line, saying where it is selected")
  vim.api.nvim_buf_delete(mbuf, { force = true })
  eq(P._selected({ pop = pv.pop, view = pv.id, gen = (pv.gen or 0) + 1, item = 1 }), { refused = "this view moved on" }, "… an older drawing's selection refused")
  P.preview_show, P.preview_pop = real_show, nil
  eq({ P.preview_show("/x", 1) }, { nil, "no pop-out previews selections (gp in one)" }, "no preview pane: said")
  -- the code view retargeted: pinned at that line
  local CV = require("desk.codeview")
  local f = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "a", "b", "c" }, f)
  local cv_view = { id = "code.preview", kind = "code" }
  ok(CV.retarget(cv_view, f, 3) and cv_view.pinned == true and cv_view.source_line == 3 and vim.api.nvim_buf_get_name(cv_view.buf) == vim.fn.fnamemodify(f, ":p"),
    "the preview's code view: that file, at that line, pinned")
end
-- The review as a starting point: U (callers, with the note on an older commit), T (a path), M (a commit on the map).
do
  local R = require("desk.review")
  local real = { R.current, Map.walk_at, Map.trace_at, Map.touched_on_map }
  local got = {}
  Map.walk_at = function(q, path, line, opts) got[#got + 1] = { "walk", q, vim.fs.basename(path), line, opts and opts.note } end
  Map.trace_at = function(path, line) got[#got + 1] = { "trace", vim.fs.basename(path), line } end
  Map.touched_on_map = function(root, sha) got[#got + 1] = { "touched", sha } end
  R.current = { files = { { path = "/r/lua/mod.lua", rel = "lua/mod.lua" } }, index = 1, symbol = { name = "M.alpha", line = 4, side = "after" },
    row = { kind = "commit", sha = "abc1234def", short = "abc1234" } }
  R.on_map("callers"); R.on_map("trace"); R.on_map("touched")
  eq(got, { { "walk", "callers", "mod.lua", 4, "These are the callers in the map as it is now (the working tree), not as they were at abc1234." },
    { "trace", "mod.lua", 4 }, { "touched", "abc1234def" } }, "U, T and M from the review: the changed function's line, the note on an older commit, the commit")
  eq(A.get("review.callers").available(), true, "… U there while a changed function is selected")
  R.current.symbol.side = "before"
  eq(A.get("review.callers").available(), "select a changed function first", "… not on a removed one")
  R.current, Map.walk_at, Map.trace_at, Map.touched_on_map = unpack(real)
  -- the note under the page's heading; a commit's page by file
  local stack = pv.stack
  pv.stack = { { kind = "modules" }, { kind = "query", answer = { ok = true, q = "callers", from = { id = "x", label = "M.alpha" }, nodes = {}, steps = {} }, note = "These are the callers in the map as it is now." } }
  ok(vim.iter(K.render(pv, 90, "paper").lines):any(function(l) return l:find("These are the callers in the map as it is now.", 1, true) ~= nil end), "the note shown under the page's heading")
  pv.stack = stack
  local changed = table.concat(Map.layout(Map.level_query({ ok = true, q = "touched", commit = "abc1234def", subject = "Fix the ring",
    nodes = { { id = "lua/mod.lua::M.alpha", label = "M.alpha", file = "lua/mod.lua", line = 3 } }, files = { { file = "lua/mod.lua", nodes = { "lua/mod.lua::M.alpha" }, moved = true } } }), 90, false).lines, "\n")
  ok(changed:find("what abc1234d changed · 1 functions", 1, true) and changed:find("lua/mod.lua  (changed since: its lines may have moved)", 1, true) and changed:find("M.alpha", 1, true),
    "a commit on the map: its functions by file, a moved file said")
  -- K: the known tests of a function's file
  local W = require("desk.work")
  local real_tests, asked_tests = W.suggested_tests, nil
  W.suggested_tests = function(path) asked_tests = path end
  act("map.tests", { ref = { target = { kind = "node", node = { id = "lua/mod.lua::M.alpha", label = "M.alpha", file = "lua/mod.lua", line = 3 } } } })
  W.suggested_tests = real_tests
  eq(asked_tests, pv.root .. "/lua/mod.lua", "K: the known tests of that function's file")
end
do
  local stack, cache = pv.stack, pv.cache
  pv.stack, pv.cache = { { kind = "modules" } }, { modules = many }
  local every = shown()
  ok(item_named(every, "m05") and item_named(every, "m70"), "the pop-out draws all seventy parts too")
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
