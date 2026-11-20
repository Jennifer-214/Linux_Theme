-- Tag-comment markers: colour the [KEY]_[value] grammar inside // comments by shape (keys, [END_*] closers, values,
-- nested [CHIPS]), never by vocabulary, so it works in any project using the format. Drawn by a decoration provider
-- on the lines being drawn, priority above treesitter (100) and LSP tokens (125).
--
-- Each line's marks are worked out once per change of the buffer (its changedtick) and painted from that on every
-- redraw: scrolling over unchanged text scans nothing (2026-11-19, her profile: 19% of Neovim's time was every visible
-- line re-read and re-scanned on every redraw). A section banner depends on the lines around it, so any edit starts
-- the buffer's marks again.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("foxml_tag_markers")
local KEY = "%[[A-Z][A-Z0-9_]+%]"
local RULE = "^%s*//%s*[-=]+%s*$"
local TAG_FTS = { c = true, cpp = true, cuda = true, objc = true, objcpp = true }
local section_headers = false
M._scans = 0

local function is_rule(l) return l ~= nil and #l >= 10 and l:match(RULE) ~= nil end

--- pure: one line's marks, { { start, end, group, priority } } (columns 1-based, inclusive). above / below: the lines
--- around it (a // title between two // rules is a banner, with section headers on).
function M.scan(line, above, below, headers)
  local out = {}
  local pos = line and line:find("//", 1, true)
  if not pos then return out end
  if headers and line:match("^%s*//") and (is_rule(line) or (is_rule(above) and is_rule(below))) then
    out[#out + 1] = { pos, #line, "FoxSectionRule", 139 }
  end
  if not line:find("[", pos, true) then return out end
  while true do
    local s, e = line:find(KEY, pos)
    if not s then return out end
    pos = e + 1
    if not line:sub(s - 1, s - 1):match("[%w_]") then -- arr[IDX] is code, not a tag
      local closer = line:sub(s + 1, s + 4) == "END_"
      out[#out + 1] = { s, e, closer and "FoxTagEnd" or "FoxTagKey", 140 }
      while line:sub(pos, pos + 1) == "_[" do -- _[value], chained: [ASSERT]_[LAYOUT_LOCK]_[expr]
        local vs, ve = line:find("^%b[]", pos + 1)
        if not vs then break end
        out[#out + 1] = { pos, pos, "FoxTagSep", 140 }
        local chained = line:sub(ve + 1, ve + 2) == "_["
        local subcat = chained and line:sub(vs, ve):match("^" .. KEY .. "$") ~= nil
        out[#out + 1] = { vs, ve, closer and "FoxTagEnd" or (subcat and "FoxTagChip" or "FoxTagValue"), 140 }
        if not closer and not subcat then -- nested chips: [TAG]_[[ENGINE] [ML_INFERENCE]]
          local cs, ce = line:find(KEY, vs + 1)
          while cs and ce < ve do
            out[#out + 1] = { cs, ce, "FoxTagChip", 140 }
            cs, ce = line:find(KEY, ce + 1)
          end
        end
        pos = ve + 1
      end
    end
  end
end

-- buf → { tick, rows = { [row] = marks } }
local kept = {}

function M._on_win(_, _, buf)
  if not TAG_FTS[vim.bo[buf].filetype] then return false end
  local tick = api.nvim_buf_get_changedtick(buf)
  local k = kept[buf]
  if not k or k.tick ~= tick then kept[buf] = { tick = tick, rows = {} } end
end

function M._on_line(_, _, buf, row)
  local k = kept[buf]
  if not k then return end
  local marks = k.rows[row]
  if not marks then
    M._scans = M._scans + 1
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    local above, below
    if section_headers and line and line:match("^%s*//") then
      local around = api.nvim_buf_get_lines(buf, math.max(row - 1, 0), row + 2, false)
      above = row > 0 and around[1] or nil
      below = around[row > 0 and 3 or 2]
    end
    marks = M.scan(line, above, below, section_headers)
    k.rows[row] = marks
  end
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(buf, ns, row, m[1] - 1, { end_col = m[2], hl_group = m[3], ephemeral = true, priority = m[4] })
  end
end

--- opts.section_headers: banners (// rules, and a title between two) drawn too.
function M.setup(opts)
  section_headers = opts and opts.section_headers == true
  api.nvim_set_decoration_provider(ns, { on_win = M._on_win, on_line = M._on_line })
  api.nvim_create_autocmd("BufWipeout", { group = api.nvim_create_augroup("desk_tags", { clear = true }),
    callback = function(a) kept[a.buf] = nil end })
end

return M
