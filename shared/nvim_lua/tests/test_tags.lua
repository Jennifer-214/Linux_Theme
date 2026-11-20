-- nvim --headless --clean -l shared/nvim_lua/tests/test_tags.lua : desk.tags, the tag-comment colours in C and C++.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
table.insert(package.loaders, 2, function(name)
  local file = here .. "../" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
local T = require("desk.tags")
local api = vim.api
local passed, failed = 0, 0
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want)) end
end
local function ok(cond, what) eq(not not cond, true, what) end
local function groups(spans) return vim.tbl_map(function(s) return s[3] end, spans) end

-- what one line gets: by shape, never by vocabulary
eq(groups(T.scan("int x = 1; // [HOT_PATH]_[tick]")), { "FoxTagKey", "FoxTagSep", "FoxTagValue" }, "a key and its value")
eq(groups(T.scan("// [END_HOT_PATH]")), { "FoxTagEnd" }, "a closer")
eq(groups(T.scan("// [ASSERT]_[LAYOUT_LOCK]_[x]")), { "FoxTagKey", "FoxTagSep", "FoxTagChip", "FoxTagSep", "FoxTagValue" }, "chained")
eq(groups(T.scan("// [TAG]_[[ENGINE] [ML]]")), { "FoxTagKey", "FoxTagSep", "FoxTagValue", "FoxTagChip", "FoxTagChip" }, "nested chips")
eq(T.scan("a[IDX] = 2; // plain words"), {}, "arr[IDX] is code, not a tag; no tag in the comment")
eq(T.scan("no comment here [KEY]"), {}, "no // on the line: nothing")
local first = T.scan("int x = 1; // [HOT_PATH]_[tick]")[1]
eq({ first[1], first[2] }, { 15, 24 }, "the key's columns (1-based start, end)")
local rule = string.rep("-", 20)
eq(groups(T.scan("// " .. rule, nil, nil, true)), { "FoxSectionRule" }, "a rule line, with section headers on")
eq(groups(T.scan("// Title", "// " .. rule, "// " .. rule, true)), { "FoxSectionRule" }, "a title between two rules")
eq(T.scan("// Title", "// " .. rule, "// " .. rule, false), {}, "… nothing with section headers off")

-- Scrolling over unchanged text scans nothing again (2026-11-19, her profile: 19% of Neovim's time was this, every
-- visible line re-read and re-scanned on every redraw); an edit scans again.
local buf = api.nvim_create_buf(true, false)
local lines = {}
for i = 1, 200 do lines[i] = ("int v%d = %d; // [HOT_PATH]_[v%d]"):format(i, i, i) end
api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo[buf].filetype = "cpp"
local painted = {}
local real_set = api.nvim_buf_set_extmark
api.nvim_buf_set_extmark = function(b, ns, row, col, opts) painted[#painted + 1] = { row, col, opts.hl_group }; return 1 end
local function draw(first_row, last_row)
  if T._on_win(nil, nil, buf) == false then return end
  for row = first_row, last_row do T._on_line(nil, nil, buf, row) end
end
T._scans = 0
draw(0, 49)
local after_first = T._scans
ok(after_first == 50 and #painted == 150, "the first draw: 50 lines scanned, 3 marks each (" .. T._scans .. " scans, " .. #painted .. " marks)")
painted = {}
draw(0, 49); draw(10, 59)
eq({ T._scans, #painted }, { 60, 300 }, "drawn again and scrolled 10: only the 10 new lines scanned, every line still painted")
api.nvim_buf_set_lines(buf, 5, 6, false, { "int changed = 1; // [END_HOT_PATH]" })
painted = {}
draw(5, 5)
eq({ T._scans, painted[1] and painted[1][3] }, { 61, "FoxTagEnd" }, "an edit: the line scanned again, its new mark painted")
vim.bo[buf].filetype = "lua"
eq(T._on_win(nil, nil, buf), false, "a Lua buffer: not drawn at all")
api.nvim_buf_set_extmark = real_set

print(string.format("test_tags: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
