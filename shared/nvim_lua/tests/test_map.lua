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

-- ─── its keys: rows of the action registry ─────────────────────────────────────────────────────────────────────
local A = require("desk.actions")
local Menu = require("desk.menu")
eq(A.problems, {}, "every map row was taken")
local function keys_of(surface) return vim.tbl_map(function(k) return k.key end, A.keys(surface)) end
eq(keys_of("map"), { "?", "<CR>", "<BS>", "-", "r", "c", "P", "m", "R", "B", "q", "o", "j", "k", "h", "l" },
  "the map's keys, in order (? is the shared row; the box moves last)")
local opener = A.get("map.open")
eq(opener and { opener.key, opener.on, opener.remote, opener.group }, { "<leader>cm", "editor", true, "Project map" },
  "Space cm, a global row the pop-out may ask for")
local empty_bin = root .. "/empty-bin"   -- a PATH with no desk-work on it
vim.fn.mkdir(empty_bin, "p")
local saved_path = vim.env.PATH
vim.env.PATH = empty_bin
eq(A.available(opener, { surface = "editor" }), true, "Space cm opens the map without desk-work too (the page says what it needs)")
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
  elseif args[2] == "query" and args[6] == "reach" then answer = reach
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
ok(line_with(view.drawn.lines, "Enter in · BS out · r reach · c callers · P paths · ? keys · q close"),
  "the key line: the keys that matter, as their rows have them, and ? for the rest")
for i, line in ipairs(view.drawn.lines) do ok(api.nvim_strwidth(line) <= api.nvim_win_get_width(view.win), "line " .. i .. " of the view fits its window") end
eq(vim.bo[view.buf].modifiable, false, "the page is read-only")
local mapped = {}
for _, m in ipairs(api.nvim_buf_get_keymap(view.buf, "n")) do mapped[m.lhs] = m.desc end
eq({ mapped["?"], mapped["<BS>"], mapped["-"], mapped["P"] }, { "The keys here", "Zoom out, or back to the code", "Zoom out", "The ways between two functions" },
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

-- m: the parts in the desk menu, not a numbered list (VM test 2026-11-16): / filters them by name, Enter goes there.
local numbered, real_select = 0, vim.ui.select
vim.ui.select = function(_, _, done) numbered = numbered + 1; done(nil) end
press("m")
vim.ui.select = real_select
eq(numbered, 0, "m does not ask with vim.ui.select's numbered list")
local parts_menu = Menu._last
ok(parts_menu and parts_menu ~= list and api.nvim_win_is_valid(parts_menu.win)
  and vim.inspect(api.nvim_win_get_config(parts_menu.win).title):find("Part of the checkout", 1, true), "m opens the parts in a menu")
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
press("r")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "║ use") end), "r: what the function reaches")
eq(prompt.default, "use", "the prompt offers the box under the cursor")
ok(asked[#asked]:find("--q reach --from lua/other.lua::use --depth 3", 1, true), "… and asks by its id, at depth 3 without a count")
press("<BS>")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ M.alpha") end), "Backspace leaves the answer")
api.nvim_feedkeys("2r", "x", false)
ok(asked[#asked]:find("--q reach --from lua/other.lua::use --depth 2", 1, true), "a count reaches the key through the registry: 2r is depth 2")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "║ use") end), "… and shows its answer")
press("-")
ok(vim.wait(1000, function() return line_with(view.drawn.lines, "│ M.alpha") end), "- leaves it too")
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
  "… and so do the functions a query names:\n" .. retro_reach:sub(1, 300))ok(line_with(view.drawn.lines, "Enter IN · BS OUT · r REACH · c CALLERS · P PATHS · ? KEYS · q CLOSE"),
  "retro: the keys as typed (r and R are two keys), the words in capitals")
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
eq(remote_ids, { "map.callers", "map.down", "map.in", "map.left", "map.out", "map.paths", "map.reach", "map.rebuild", "map.right", "map.up" },
  "in the pop-out Enter, -, r, c, P and R run here and hjkl move its selection; Backspace, q, m, B and o stay the tab's")
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
ok(not table.concat(d.lines, "\n"):find("Enter in", 1, true), "no key line in its lines: the pop-out's window has its own")
eq(table.concat(vim.tbl_map(function(p) return p[1] .. " " .. p[2] end, P.key_pairs(d.footer)), " · "), "Enter in · - out · r reach · c callers · ? keys",
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
eq(A.available(A.get("map.reach"), ctx_on(file_item)), "select a function first", "r there needs a function selected")
eq(A.available(A.get("map.in"), ctx_on(nil)), "nothing is selected", "… and Enter something selected")
act("map.in", file_item)
ok(vim.wait(1000, function() return item_named(shown(), "M.alpha") ~= nil end), "into the file again")
local alpha = item_named(shown(), "M.alpha")
local code = ctx_on(alpha).origin
eq(act("map.in", alpha), { true }, "Enter on a function, from the pop-out")
eq({ api.nvim_get_current_win(), api.nvim_buf_get_name(0), api.nvim_win_get_cursor(0)[1] }, { code, root .. "/lua/mod.lua", 3 },
  "… goes to its code here, in the file window")
pv.news = nil
local prompted = 0
local real_input = vim.ui.input
vim.ui.input = function(opts, done) prompted = prompted + 1; real_input(opts, done) end
eq(act("map.reach", alpha), { true }, "r on a function, from the pop-out")
ok(asked[#asked]:find("--q reach --from lua/mod.lua::M.alpha --depth 3", 1, true), "… asks what the selected function reaches, at depth 3")
eq(prompted, 0, "… without asking anything here: the keyboard is in the pop-out")
vim.ui.input = real_input
ok(vim.wait(1000, function() return table.concat(shown().lines, "\n"):find("what use reaches", 1, true) end), "… and shows the answer there")
eq({ pv.news, shown().news }, { true, true }, "… news in the pop-out's header until she looks")
local saved = K.save(pv)
eq({ saved.step, #saved.stack, saved.target.root, #saved.target.levels }, { true, 4, tab_root, 3 },
  "save: all of it for the history; for the layout record its checkout and zoom, not a query's answer")
ok(pcall(vim.json.encode, saved.target), "… plain data")
act("map.out")
ok(vim.wait(1000, function() return item_named(shown(), "M.alpha") ~= nil end), "- leaves the answer")
eq(act("map.paths", alpha, { text = "M.beta" }), { true }, "P from the pop-out, with the words it asked there")
ok(asked[#asked]:find("--q paths --from lua/mod.lua::M.alpha --to M.beta", 1, true), "… the ways from the selected function to the one named")
ok(vim.wait(1000, function() return table.concat(shown().lines, "\n"):find("ways from use to M.beta", 1, true) end), "… shown there")
eq(act("map.paths", alpha), { false, "The ways between two functions: needs its words" }, "… and without them it does not run")
act("map.out")
ok(vim.wait(1000, function() return item_named(shown(), "M.alpha") ~= nil end), "- leaves the ways")
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
press("r")
eq({ asked_for, said[#said] }, { 0, "Requires desk-work." }, "r says so instead of asking for a function")
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
press("r")
eq({ asked_for, said[#said] }, { 0, "No map built yet · R builds it." }, "r says so instead of asking")
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
