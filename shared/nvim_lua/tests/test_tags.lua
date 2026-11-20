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

-- Scrolling and j cost nothing (2026-11-19, her profiles: 19%, then 21% with the scans kept but every mark painted
-- again on every redraw, hundreds a j on her 4K screen): the marks are stored on the buffer once, and an edit
-- scans only the lines it changed, with a line either side (a banner depends on its neighbours).
local buf = api.nvim_create_buf(true, false)
local lines = {}
for i = 1, 200 do lines[i] = ("int v%d = %d; // [HOT_PATH]_[v%d]"):format(i, i, i) end
api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo[buf].filetype = "cpp"
local function marks(first, last)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, T.ns, { first or 0, 0 }, { last or -1, -1 }, { details = true })) do
    out[#out + 1] = { m[2], m[3], m[4].hl_group }
  end
  return out
end
T._scans = 0
T.attach(buf)
eq({ #marks(), T._scans }, { 600, 200 }, "attached: every line scanned once, 3 marks each stored on the buffer")
local stored = #marks()
T.attach(buf)
eq({ #marks(), T._scans }, { stored, 200 }, "… attaching again does nothing")
api.nvim_buf_set_lines(buf, 5, 6, false, { "int changed = 1; // [END_HOT_PATH]" })
ok(vim.wait(1000, function() return T._scans > 200 end), "an edit: scanned again")
vim.wait(50)
local row5 = marks(5, 5)
eq({ #row5, row5[1] and row5[1][3] }, { 1, "FoxTagEnd" }, "… the changed line's old marks replaced by its new one")
ok(T._scans - 200 <= 3, "… only the changed line and its neighbours scanned (" .. (T._scans - 200) .. ")")
eq(#marks(), stored - 2, "… the rest untouched")
api.nvim_buf_set_lines(buf, 0, 0, false, { "// new first line, no tag" })
vim.wait(200)
local moved = marks(51, 51)
local text51 = api.nvim_buf_get_lines(buf, 51, 52, false)[1]
eq({ #moved, moved[1] and moved[1][2] }, { 3, text51:find("[HOT_PATH]", 1, true) - 1 }, "a line inserted above: the marks below moved with their text")
local lua = api.nvim_create_buf(true, false)
api.nvim_buf_set_lines(lua, 0, -1, false, { "-- [HOT_PATH]_[x]" })
vim.bo[lua].filetype = "lua"
T.attach(lua)
eq(#api.nvim_buf_get_extmarks(lua, T.ns, 0, -1, {}), 0, "a Lua buffer: nothing")

print(string.format("test_tags: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
