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
for _, e in ipairs(graph.edges) do ok(e.kind == "call-by-name" or e.kind == "contains", "every edge says it is by name (or a class's member): " .. e.kind) end
eq(graph.complete, true, "complete when nothing was capped")

ok(by_label["square"] and by_label["norm"] and by_label["find"] and by_label["point"], "C: functions, a pointer-returning one, a struct with a body")
ok(not by_label["make"], "a declaration is no unit")
local points = 0
for _, n in ipairs(graph.nodes) do if n.label == "point" then points = points + 1 end end
eq(points, 1, "a struct named in a declaration is not a second struct")
ok(edge("norm", "square") and edge("find", "norm"), "C calls by name")

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
ok(line_with(Map.layout(Map.level_modules(many), 100, false).lines, "+10 more"), "past 60 boxes on a level: +N more")
local retro = Map.layout(page, 70, true)
ok(line_with(retro.lines, "┌") and not line_with(retro.lines, "╭") and line_with(retro.lines, "CALLS BETWEEN PARTS"), "retro: code page 437 boxes and capitals")

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
local way_row, way = line_with(ways.lines, "use → M.alpha → M.beta")
ok(way_row and way:find("(by name)", 1, true), "a way, with the part found by name said")
eq(Map.item_at(ways, way_row, way:find("M.alpha", 1, true)).target.node.id, "lua/mod.lua::M.alpha", "each name on a way is a hit")

-- ─── the view, with a fake desk-work ───────────────────────────────────────────────────────────────────────────
local status = { ok = true, built = true, building = false, stale = true, stale_why = "1 changed file differs from when it was built",
  head = "3789c69aaaaaaaa", built_at = os.time(), complete = true,
  providers = { { name = "syntax", state = "ok" }, { name = "binary", state = "not built", why = "requires a built binary: desk-work map build --binary PATH" } } }
local asked, building = {}, false
Map.desk_work = function(args, done)
  asked[#asked + 1] = table.concat(args, " ")
  local answer
  if args[2] == "status" then answer = vim.tbl_extend("force", status, { building = building })
  elseif args[2] == "build" then building = true; answer = { ok = true, started = true }
  elseif args[2] == "query" and args[6] == "module" and args[9] == "--name" then answer = args[10] == "lua" and contents or { ok = false, message = "No part" }
  elseif args[2] == "query" and args[6] == "module" then answer = modules
  elseif args[2] == "query" and args[6] == "reach" then answer = reach end
  vim.defer_fn(function() done(answer, { code = 0, stdout = "", stderr = "" }) end, 5)   -- never in the caller's path
end
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
ok(line_with(view.drawn.lines, "Enter in · - out · r reach · p paths") and line_with(view.drawn.lines, "B binary · q close"), "the keys, wrapped to the window")
for i, line in ipairs(view.drawn.lines) do ok(api.nvim_strwidth(line) <= api.nvim_win_get_width(view.win), "line " .. i .. " of the view fits its window") end
eq(vim.bo[view.buf].modifiable, false, "the page is read-only")
local function press(key) vim.fn.maparg(key, "n", false, true).callback() end
local function cursor_on(name)
  local row, ln = line_with(view.drawn.lines, "│ " .. name)
  api.nvim_win_set_cursor(view.win, { row, (ln:find(name, 1, true)) })
end
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
api.nvim_set_current_win(view.win)
press("-")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ mod.lua") and not line_with(view.drawn.lines, "│ M.alpha") end), "- goes back out")
press("-")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ lua") and line_with(view.drawn.lines, "│ csrc") end), "… to the parts")
eq(#vim.tbl_filter(function(a) return a:find("--name lua", 1, true) end, asked), 1, "a part read once is drawn from what was read")

-- A query from a key: the box under the cursor is the default, its id what desk-work is asked about.
press("<CR>")   -- back into lua (the cursor stayed on its box)
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ mod.lua") end), "into the part again")
cursor_on("mod.lua")
press("<CR>")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ use") end), "and the file")
cursor_on("use")
local prompt
vim.ui.input = function(opts, done) prompt = opts; done(opts.default) end
press("r")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "║ use") end), "r: what the function reaches")
eq(prompt.default, "use", "the prompt offers the box under the cursor")
ok(asked[#asked]:find("--q reach --from lua/other.lua::use --depth 3", 1, true), "… and asks by its id, at depth 3 without a count")
press("-")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ M.alpha") end), "- leaves the answer")

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

vim.g.desk_style = "retro"
Map.render(view)
ok(line_with(view.drawn.lines, "PROJECT MAP") and line_with(view.drawn.lines, "┌"), "retro: the page in capitals and code page 437 boxes")
ok(line_with(view.drawn.lines, "r reach") and line_with(view.drawn.lines, "R rebuild"), "retro: the keys keep their case (r and R are two keys)")
ok(line_with(view.drawn.lines, "parts » lua » mod.lua") and not line_with(view.drawn.lines, "›") and not line_with(view.drawn.lines, "…"),
  "retro: nothing outside code page 437 (» between the levels, .. for an ellipsis)")
vim.g.desk_style = "paper"
press("q")
eq(Map.views[view.buf], nil, "q closes the map")

-- No desk-work at all: the page says so instead of reading forever.
local real = Map.desk_work
Map.desk_work = function(_, done) vim.schedule(function() done(nil, { code = -1, stdout = "", stderr = "desk-work did not start; is it installed?" }) end) end
local lonely = Map.open(root)
ok(vim.wait(1000, function() return lonely.drawn and line_with(lonely.drawn.lines, "desk-work did not start") end), "without desk-work the page says why")
press("q")
Map.desk_work = real

vim.fn.delete(root, "rf")
print(string.format("test_map: %d passed%s%s", passed, failed > 0 and (", " .. failed .. " failed") or "",
  #skipped > 0 and (" (skipped: " .. table.concat(skipped, ", ") .. ")") or ""))
os.exit(failed > 0 and 1 or 0)
