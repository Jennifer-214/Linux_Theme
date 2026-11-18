-- nvim --headless --clean -l shared/nvim_lua/tests/test_retro_style.lua : every desk view drawn in retro-amber keeps the
-- theme's two rules a reader sees at once (her ask, 2026-11-18: "verify that it all matches the theme and general
-- style for retro amber"): only characters Big Blue Term draws (code page 437, as the bar's own test holds), and its
-- headings in capitals, the theme's voice. A view that breaks either fails here, not on her screen.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
table.insert(package.loaders, 2, function(name)
  local file = here .. "../" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
vim.g.desk_style = "retro"
-- As the config sets it in retro (templates/nvim/init.lua, desk-border): the DOS double-line box.
vim.g.desk_border = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" }
vim.notify = function() end
local passed, failed = 0, 0
local function ok(cond, what)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. what) end
end

-- Code page 437 as Big Blue Term draws it: printable ASCII, the upper half, and DOS's glyphs for the control codes
-- (tests/test_retro_bar_qml.py's set).
local CP437 = {}
do
  local upper = { "Ç","ü","é","â","ä","à","å","ç","ê","ë","è","ï","î","ì","Ä","Å","É","æ","Æ","ô","ö","ò","û","ù","ÿ","Ö","Ü",
    "¢","£","¥","₧","ƒ","á","í","ó","ú","ñ","Ñ","ª","º","¿","⌐","¬","½","¼","¡","«","»","░","▒","▓","│","┤","╡","╢","╖",
    "╕","╣","║","╗","╝","╜","╛","┐","└","┴","┬","├","─","┼","╞","╟","╚","╔","╩","╦","╠","═","╬","╧","╨","╤","╥","╙","╘",
    "╒","╓","╫","╪","┘","┌","█","▄","▌","▐","▀","α","ß","Γ","π","Σ","σ","µ","τ","Φ","Θ","Ω","δ","∞","φ","ε","∩","≡","±",
    "≥","≤","⌠","⌡","÷","≈","°","∙","·","√","ⁿ","²","■"," " }
  local low = { "☺","☻","♥","♦","♣","♠","•","◘","○","◙","♂","♀","♪","♫","☼","►","◄","↕","‼","¶","§","▬","↨","↑","↓","→","←",
    "∟","↔","▲","▼","⌂" }
  for b = 0x20, 0x7e do CP437[string.char(b)] = true end
  for _, c in ipairs(upper) do CP437[c] = true end
  for _, c in ipairs(low) do CP437[c] = true end
end
local function outside(lines)
  local bad = {}
  for _, line in ipairs(lines) do
    for _, c in ipairs(vim.fn.split(line, "\\zs")) do if not CP437[c] then bad[c] = true end end
  end
  return vim.tbl_keys(bad)
end
local function check(name, lines, headings)
  local bad = outside(lines)
  ok(#bad == 0, name .. ": only code page 437 (Big Blue Term's characters); outside it: " .. table.concat(bad, " ")
    .. "\n" .. table.concat(lines, "\n"))
  for _, pattern in ipairs(headings or {}) do
    local found
    for _, line in ipairs(lines) do if line:upper():find(pattern:upper(), 1, true) then found = line end end
    ok(found and found:find(pattern:upper(), 1, true), name .. ": the heading " .. pattern .. " in capitals: " .. tostring(found))
  end
end

local function item(n) return { name = n, detail = n .. ".cpp:1" } end

-- The call graph, with its layers and their gauge, wide and narrow.
local G = require("desk.callgraph")
local graph = { center = item("process"), callers = { item("main"), item("run_queue") }, callees = { item("drain"), item("pop_front") },
  layers = { callers = { { item("main") }, { item("start"), item("a_rather_long_function_name_for_the_box") } },
             callees = { { item("drain") }, { item("free_block") }, { item("very_deep") } } },
  keys = G.VIEW_KEYS, notes = { "edited since it was read" } }
for _, width in ipairs({ 100, 44 }) do
  check("call graph at " .. width .. " columns", G.layout(vim.deepcopy(graph), width, true).lines, { "LAYERS" })
end

-- The project map: its parts page, a zoom, and the callers / reach pages with their gauge.
local Map = require("desk.map")
local modules = { ok = true, q = "module", modules = {
  { name = "lua", files = 4, functions = 9, types = 0 }, { name = "csrc", files = 2, functions = 6, types = 2 },
  { name = "(library)", files = 0, functions = 3, types = 0 } },
  edges = { { from = "lua", to = "csrc", count = 2 }, { from = "csrc", to = "(library)", count = 5 } } }
local page = Map.level_modules(modules)
check("project map parts", Map.layout(page, 70, true).lines, { "CALLS BETWEEN PARTS" })
check("project map zoom", Map.layout(vim.tbl_extend("force", page, { zoom = 2 }), 70, true).lines)
local function node(id, label, depth) return { id = id, label = label, file = "lua/mod.lua", line = 3, kind = "function", depth = depth } end
local reach = { ok = true, q = "reach", depth = 3, from = node("lua/a.lua::use", "use"),
  nodes = { node("lua/a.lua::use", "use", 0), node("lua/mod.lua::M.alpha", "M.alpha", 1), node("lua/mod.lua::M.beta", "M.beta", 2),
            node("lua/mod.lua::M.gamma_with_a_long_name", "M.gamma_with_a_long_name", 3) },
  steps = { { from = "lua/a.lua::use", to = "lua/mod.lua::M.alpha", depth = 1 }, { from = "lua/mod.lua::M.alpha", to = "lua/mod.lua::M.beta", depth = 2 },
            { from = "lua/mod.lua::M.beta", to = "lua/mod.lua::M.gamma_with_a_long_name", depth = 3, mark = "capped" } }, more = 0 }
check("project map reach", Map.layout(Map.level_query(reach), 80, true).lines)
check("project map callers", Map.layout(Map.level_query(vim.tbl_extend("force", reach, { q = "callers" })), 80, true).lines)

-- The screen map.
local Scr = require("desk.screens")
local screens = {
  { id = "eDP-1", name = "eDP-1 (this screen)", here = true, x = 0, y = 0, width = 1920, height = 1080, scale = 1, transform = 0 },
  { id = "DP-2", name = "DP-2 · Acer", x = 1920, y = 0, width = 3840, height = 2160, scale = 1.5, transform = 0 },
  { id = "HDMI-A-1", name = "HDMI-A-1 · Dell", x = 4480, y = 0, width = 1920, height = 1080, scale = 1, transform = 1 } }
check("screen map", Scr.layout(screens, Scr.places(screens), 2, 64, 14, true).lines)

-- A menu, in the theme's voice.
local A = require("desk.actions")
local Menu = require("desk.menu")
local said = Menu.voice(true)
local items = { { name = "Pop out the call graph", about = "The live call graph in the pop-out", group = "views" },
  { name = "What changed", about = "The review of the working changes", group = "review", bind = "<leader>Cw" } }
check("menu", Menu.layout(items, { title = "Home", heads = said }).lines)
-- Enter as every view draws it (the menu footer, the review's key hints): one glyph, the font's.
check("Enter, as drawn", { Menu.enter() })

-- The since page.
local Since = require("desk.since")
local since = Since.layout({ items = { { kind = "commit", at = 1794800000, sha = string.rep("a", 40), author = "Caramel", label = "queue: drain before stop" },
  { kind = "tests", at = 1794799000, id = string.rep("t", 32), label = "make test", state = "failed", passed = 126, failed = 2 } },
  first = false, since = "this morning", at = 1794800100 }, "retro", "/r")
check("since page", type(since) == "table" and since or vim.split(tostring(since), "\n"))

print(string.format("test_retro_style: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
