-- Tag-comment markers: colour the [KEY]_[value] grammar inside // comments by shape (keys, [END_*] closers, values,
-- nested [CHIPS]), never by vocabulary, so it works in any project using the format. Priority above treesitter (100)
-- and LSP tokens (125).
--
-- The marks are stored on the buffer (extmarks): scanned once when a C or C++ buffer opens, and after an edit only the
-- lines it changed are scanned again, with a line either side (a banner depends on its neighbours). Redraws, scrolling
-- and j cost nothing here (2026-11-19, her profiles: 19% of Neovim's time with every visible line scanned on every
-- redraw, then 21% with the scans kept but every mark painted again on every redraw, hundreds a j on a 4K screen).
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

M.ns = ns
local attached = {}

-- rows first..last (0-based, inclusive): their marks cleared and placed again from their text
local function paint(buf, first, last)
  local count = api.nvim_buf_line_count(buf)
  first, last = math.max(0, first), math.min(count - 1, last)
  if last < first then return end
  local from = math.max(0, first - 1)
  local around = api.nvim_buf_get_lines(buf, from, math.min(count, last + 2), false)
  api.nvim_buf_clear_namespace(buf, ns, first, last + 1)
  for row = first, last do
    local i = row - from + 1
    M._scans = M._scans + 1
    for _, m in ipairs(M.scan(around[i], around[i - 1], around[i + 1], section_headers)) do
      pcall(api.nvim_buf_set_extmark, buf, ns, row, m[1] - 1, { end_col = m[2], hl_group = m[3], priority = m[4] })
    end
  end
end

-- edits arrive inside the change: the rows they touched are gathered and painted once it is done
local pending = {}
local function later(buf, first, last)
  local p = pending[buf]
  if p then p[1], p[2] = math.min(p[1], first), math.max(p[2], last); return end
  pending[buf] = { first, last }
  vim.schedule(function()
    local q = pending[buf]
    pending[buf] = nil
    if q and attached[buf] and api.nvim_buf_is_valid(buf) then paint(buf, q[1], q[2]) end
  end)
end

--- Marks a C or C++ buffer's tags and keeps them as it is edited (once per buffer).
function M.attach(buf)
  buf = buf or api.nvim_get_current_buf()
  if attached[buf] or not api.nvim_buf_is_valid(buf) or not TAG_FTS[vim.bo[buf].filetype] then return end
  attached[buf] = true
  paint(buf, 0, api.nvim_buf_line_count(buf) - 1)
  api.nvim_buf_attach(buf, false, {
    on_lines = function(_, b, _, first, _, last_new)
      if not attached[b] then return true end
      later(b, first - 1, last_new)
    end,
    on_reload = function(_, b) if attached[b] then later(b, 0, api.nvim_buf_line_count(b)) end end,
    on_detach = function(_, b) attached[b] = nil end,
  })
end

local function forget(buf)
  if not attached[buf] then return end
  attached[buf] = nil
  pcall(api.nvim_buf_clear_namespace, buf, ns, 0, -1)
end

--- opts.section_headers: banners (// rules, and a title between two) drawn too.
function M.setup(opts)
  section_headers = opts and opts.section_headers == true
  local group = api.nvim_create_augroup("desk_tags", { clear = true })
  api.nvim_create_autocmd("FileType", { group = group, callback = function(a)
    if TAG_FTS[vim.bo[a.buf].filetype] then M.attach(a.buf) else forget(a.buf) end
  end })
  for _, b in ipairs(api.nvim_list_bufs()) do if api.nvim_buf_is_loaded(b) then M.attach(b) end end
end

return M
