-- =========================
-- Neovim Starter (minimal but powerful)
-- Leader = Space, plugin manager = lazy.nvim
-- =========================

-- Leader
vim.g.mapleader = " "
vim.g.maplocalleader = " "
vim.g.python3_host_prog = vim.fn.expand("~/.venvs/nvim/bin/python")

-- Suppress deprecation warnings from plugins we don't control (project.nvim, telescope)
local _orig_deprecate = vim.deprecate
vim.deprecate = function(name, alternative, version, plugin, backtrace)
  if name and name:match("buf_get_clients") then return end
  return _orig_deprecate(name, alternative, version, plugin, backtrace)
end

-- Basics
vim.opt.number = {{SHOW_WELCOME}}
vim.opt.relativenumber = {{SHOW_WELCOME}}
vim.opt.expandtab = {{SHOW_WELCOME}}
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.termguicolors = {{SHOW_WELCOME}}
vim.opt.signcolumn = "yes:2"
vim.opt.splitbelow = {{SHOW_WELCOME}}
vim.opt.splitright = {{SHOW_WELCOME}}
vim.opt.updatetime = 250
vim.opt.scrolloff = 8
vim.opt.colorcolumn = ""          -- ruler off; soft-wrap below adapts to window width
vim.opt.wrap = true               -- wrap long lines/comments instead of running off-screen
vim.opt.linebreak = true          -- break at word boundaries, not mid-word
vim.opt.breakindent = true        -- wrapped lines keep the code's indent
vim.opt.showbreak = "↪ "          -- mark wrapped continuation lines

-- Hard-wrap comment prose at 80 (clean GitHub rendering). A FileType autocmd, not a
-- global opt, because ftplugins reset textwidth=0 after init.lua runs. Strip 't' so
-- only comments wrap, never code (python's default formatoptions includes it).
-- Never a tag line, though ("// [KEY]_[value]", "//   - [KEY]_[...]"): its value must stay on
-- ONE line or every parser reads it empty, and the tag validator can't tell. 'c' is dropped
-- while typing on one and put back on the next ordinary line (only if we took it away).
local function tag_line(line) return line:match("^%s*[/#;%-]+%s*%-?%s*%[%u[%u%d_]*%]") ~= nil end
local tag_nowrap = vim.api.nvim_create_augroup("foxml_tag_nowrap", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "cpp", "c", "asm", "cuda", "python", "lua", "rust", "sh", "zsh" },
  callback = function(args)
    vim.opt_local.textwidth = 80
    vim.opt_local.formatoptions:remove("t")
    vim.api.nvim_clear_autocmds({ group = tag_nowrap, buffer = args.buf })
    vim.api.nvim_create_autocmd("InsertCharPre", {
      group = tag_nowrap,
      buffer = args.buf,
      callback = function()
        local fo = vim.bo.formatoptions
        if tag_line(vim.api.nvim_get_current_line()) then
          if fo:find("c", 1, true) then -- checked every key: a reloaded ftplugin may have put it back
            vim.bo.formatoptions = fo:gsub("c", "")
            vim.b.foxml_tag_nowrap = true
          end
        elseif vim.b.foxml_tag_nowrap then
          if not fo:find("c", 1, true) then vim.bo.formatoptions = fo .. "c" end
          vim.b.foxml_tag_nowrap = nil
        end
      end,
    })
  end,
})
vim.opt.smoothscroll = {{SHOW_WELCOME}}
vim.opt.cursorline = {{SHOW_WELCOME}}
vim.opt.cursorlineopt = "number"
vim.opt.guicursor = "n-v-c:block,i-ci-ve:ver25,r-cr:hor20,o:hor50"
vim.opt.clipboard = "unnamedplus"
vim.opt.autoread = {{SHOW_WELCOME}}           -- reload files changed outside nvim
vim.opt.swapfile = false          -- no .swp clutter (git is the safety net)
vim.opt.undofile = {{SHOW_WELCOME}}           -- persistent undo across sessions
vim.opt.writebackup = false       -- avoid "file changed" prompts from backup writes
vim.opt.autowriteall = {{SHOW_WELCOME}}       -- auto-save when switching buffers / leaving

-- FoxML palette (single source of truth)
local P = {
  bg_deep   = "#{{BG_DARK}}",
  bg        = "#{{BG}}",
  bg_alt    = "#{{BG_ALT}}",
  bg_hl     = "#{{TMUX_ACTIVE_BG}}",
  sel       = "#{{NVIM_SEL}}",
  list_sel  = "#{{NVIM_LIST_SEL}}",  -- the selected row in lists, trees and pickers
  menu_sel  = "#{{NVIM_MENU_SEL}}",  -- the selected row in completion / popup menus
  fg        = "#{{FG}}",
  fg_pastel = "#{{FG_PASTEL}}",
  fg_dim    = "#{{FG_DIM}}",
  comment   = "#{{COMMENT}}",
  peach     = "#{{PRIMARY}}",
  float_border = "#{{NVIM_FLOAT_BORDER}}",  -- popup/float frames (a hairline on Paper)
  float_bg  = "#{{NVIM_FLOAT_BG}}",  -- hover / signature / completion cards (a shade darker than the page on Paper)
  pink      = "#{{SECONDARY}}",
  blush     = "#{{BLUSH}}",
  bookmark  = "#{{WAYBAR_WS_ACTIVE}}",
  lavender  = "#{{ACCENT}}",
  surface   = "#{{SURFACE}}",
  red       = "#{{RED}}",
  red_br    = "#{{RED_BRIGHT}}",
  green     = "#{{GREEN}}",
  green_br  = "#{{GREEN_BRIGHT}}",
  yellow    = "#{{YELLOW}}",
  yellow_br = "#{{YELLOW_BRIGHT}}",
  blue      = "#{{BLUE}}",
  blue_br   = "#{{BLUE_BRIGHT}}",
  cyan      = "#{{CYAN}}",
  cyan_br   = "#{{CYAN_BRIGHT}}",
  white     = "#{{WHITE}}",
  warm      = "#{{WARM}}",
  sand      = "#{{SAND}}",
  wheat     = "#{{WHEAT}}",
  warn      = "#{{NVIM_WARN}}",   -- warnings everywhere (the darkest ink on Paper)
  clay      = "#{{CLAY}}",
  diff_add  = "#{{DIFF_ADD}}",
  diff_chg  = "#{{DIFF_CHANGE}}",
  diff_del  = "#{{DIFF_DELETE}}",
  diff_txt  = "#{{DIFF_TEXT}}",
  ts_ctx    = "#{{TMUX_ACTIVE_BG}}",
  rainbow   = { "#{{NVIM_RAINBOW1}}", "#{{NVIM_RAINBOW2}}", "#{{NVIM_RAINBOW3}}",
                "#{{NVIM_RAINBOW4}}", "#{{NVIM_RAINBOW5}}", "#{{NVIM_RAINBOW6}}" },
  indent    = { "#{{NVIM_INDENT1}}", "#{{NVIM_INDENT2}}", "#{{NVIM_INDENT3}}",
                "#{{NVIM_INDENT4}}", "#{{NVIM_INDENT5}}", "#{{NVIM_INDENT6}}" },
  ibl_scope = "#{{NVIM_IBL_SCOPE}}",
  diag_err_bg  = "#{{NVIM_DIAG_ERR_BG}}",
  diag_warn_bg = "#{{NVIM_DIAG_WARN_BG}}",
  git_mod   = "#{{NVIM_GIT_MOD}}",
  git_del   = "#{{NVIM_GIT_DEL}}",
  conflict_cur       = "#{{NVIM_CONFLICT_CUR}}",
  conflict_cur_label = "#{{NVIM_CONFLICT_CUR_LABEL}}",
  conflict_inc       = "#{{NVIM_CONFLICT_INC}}",
  conflict_inc_label = "#{{NVIM_CONFLICT_INC_LABEL}}",
  illuminate = "#{{NVIM_ILLUMINATE}}",
  fn_def    = "#{{NVIM_FN_DEF}}",
  search    = { fg = "#{{NVIM_SEARCH_FG}}", bg = "#{{NVIM_SEARCH_BG}}", cur_fg = "#{{NVIM_CURSEARCH_FG}}",
                cur_bg = "#{{NVIM_CURSEARCH_BG}}", inc_fg = "#{{NVIM_INCSEARCH_FG}}", inc_bg = "#{{NVIM_INCSEARCH_BG}}" },
  pen       = "#{{NVIM_RED_PEN}}",     -- errors: the red pen correcting the page (CLAY on dark themes)
  faint     = "#{{NVIM_FAINT_FG}}",   -- dim text (line numbers, whitespace, blame); SURFACE on dark themes
  syn       = { var = "#{{NVIM_SYN_VAR}}", member = "#{{NVIM_SYN_MEMBER}}", param = "#{{NVIM_SYN_PARAM}}",
                type = "#{{NVIM_SYN_TYPE}}", string = "#{{NVIM_SYN_STRING}}", number = "#{{NVIM_SYN_NUMBER}}",
                call = "#{{NVIM_SYN_CALL}}", operator = "#{{NVIM_SYN_OPERATOR}}", ret = "#{{NVIM_SYN_RETURN}}",
                comment = "#{{NVIM_SYN_COMMENT}}", header = "#{{NVIM_SYN_HEADER}}" },
  banner    = { "#{{NVIM_BANNER1}}", "#{{NVIM_BANNER2}}", "#{{NVIM_BANNER3}}", "#{{NVIM_BANNER4}}" },
  symdeps   = { sel = "#{{NVIM_SYMDEPS_SEL}}", sync = "#{{NVIM_SYMDEPS_SYNC}}", warn = "#{{NVIM_SYMDEPS_WARN}}",
                alarm = "#{{NVIM_SYMDEPS_ALARM}}", ok = "#{{NVIM_SYMDEPS_OK}}" },
  none      = "none",
}

-- >>> fox-paper-details
local Paper = { enabled = "{{LITTLE_DETAILS}}" == "fox-little-details-on" }

-- The cover is a native Snacks dashboard: its normal actions and recent-file
-- history remain available, with no new plugin or writes to project files.
function Paper.notebook_sections(dashboard)
  local width = math.min(dashboard.opts.width, math.max(28, vim.o.columns - 8))
  local inner = width - 10
  local rows = {}
  local function clean(text, limit)
    text = tostring(text):gsub("[%c]", " ")
    while vim.fn.strdisplaywidth(text) > limit do text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1) end
    return text
  end
  local function page(text, group, key, action)
    text = clean(text, inner)
    local parts = { { "│  ◦  │ ", hl = "FoxNotebookRule" } }
    if key then
      parts[#parts + 1] = { key, hl = "FoxNotebookKey" }
      parts[#parts + 1] = { text:sub(#key + 1), hl = group or "FoxNotebookText" }
    else parts[#parts + 1] = { text, hl = group or "FoxNotebookText" } end
    parts[#parts + 1] = { string.rep(" ", inner - vim.fn.strdisplaywidth(text)) .. " │", hl = "FoxNotebookRule" }
    rows[#rows + 1] = { text = parts, key = key, action = action }
  end
  rows[#rows + 1] = { text = { { "╭" .. string.rep("─", width - 2) .. "╮", hl = "FoxNotebookRule" } } }
  page("", "FoxNotebookText")
  page("a notebook for", "FoxNotebookNote")
  page(vim.fn.fnamemodify(vim.fn.getcwd(), ":t"), "FoxNotebookTitle")
  page(os.date("%A, %B %d  ·  %Y"):lower(), "FoxNotebookNote")
  page("", "FoxNotebookText")
  page("CONTENTS", "FoxNotebookNote")
  local descriptions = { f = "find a page", g = "look for a little word", r = "recent pages",
    p = "other notebooks", s = "pick up where you left off", l = "care for your tools", q = "close the notebook" }
  page("n   a fresh page", "FoxNotebookText", "n", ":ene | startinsert")
  for _, item in ipairs(dashboard.opts.preset.keys) do
    page(item.key .. "   " .. (descriptions[item.key] or item.desc), "FoxNotebookText", item.key, item.action)
  end
  page("", "FoxNotebookText")
  page("PAGES FROM YOUR LAST VISIT", "FoxNotebookNote")
  local count = 0
  for file in require("snacks.dashboard").oldfiles() do
    if vim.fn.filereadable(file) == 1 then
      count = count + 1
      local path = file
      page(tostring(count) .. "   " .. vim.fn.fnamemodify(path, ":~:."), "FoxNotebookText", tostring(count),
        function() vim.cmd.edit(vim.fn.fnameescape(path)) end)
      if count == 3 then break end
    end
  end
  if count == 0 then page("your next little idea starts here.", "FoxNotebookNote") end
  page("", "FoxNotebookText")
  page("  /  ·  field notes", "FoxNotebookNote")
  page(" /", "FoxNotebookNote")
  rows[#rows + 1] = { text = { { "╰" .. string.rep("─", width - 2) .. "╯", hl = "FoxNotebookRule" } } }
  return rows
end
Paper.completion_icons = {
  Text = "󰉿", Method = "󰆧", Function = "󰊕", Constructor = "", Field = "󰜢",
  Variable = "󰀫", Class = "󰠱", Interface = "", Module = "", Property = "󰜢",
  Unit = "󰑭", Value = "󰎠", Enum = "", Keyword = "󰌋", Snippet = "",
  Color = "󰏘", File = "󰈙", Reference = "󰈇", Folder = "󰉋", EnumMember = "",
  Constant = "󰏿", Struct = "󰙅", Event = "", Operator = "󰆕", TypeParameter = "󰊄",
}
if Paper.enabled then
  vim.opt.cursorlineopt = "line,number"
  vim.opt.inccommand = "nosplit"
  -- hlslens owns the one search count beside the current match.
  vim.opt.shortmess:append("S")
end
function Paper.search_lens(render, positions, nearest, index)
  local position = positions[index]
  if not nearest or not position then return end
  render.setVirt(0, position[1] - 1, position[2] - 1,
    { { "  " .. index .. " of " .. #positions .. "  ", "HlSearchLensNear" } }, true)
end
function Paper.completion_format(entry, item)
  item.icon = Paper.completion_icons[item.kind] or "·"
  item.icon_hl_group = "FoxPaperCompletionIcon"
  local completion = entry:get_completion_item()
  local detail = item.menu and item.menu ~= "" and item.menu or completion.detail or ""
  detail = vim.trim(detail:gsub("%s+", " "))
  local budget = math.min(52, math.max(18, math.floor(vim.o.columns * .32)))
  if vim.fn.strdisplaywidth(detail) > budget then
    detail = vim.fn.strcharpart(detail, 0, budget - 1)
    while vim.fn.strdisplaywidth(detail) > budget - 1 do
      detail = vim.fn.strcharpart(detail, 0, vim.fn.strchars(detail) - 1)
    end
    detail = detail .. "…"
  end
  item.menu = detail
  return item
end
function Paper.merge_label(buf, win, context)
  if not Paper.enabled or not vim.api.nvim_win_is_valid(win) or not context
      or not (context.layout_name or ""):match("^diff[134]") then return end
  local labels = { a = "current · ours", b = "result · working tree", c = "incoming · theirs", d = "base" }
  local label = labels[context.symbol]
  if not label then return end
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"):gsub("%%", "%%%%")
  local group = context.symbol == "a" and "FoxPaperMergeCurrent" or "FoxPaperMergeOther"
  vim.wo[win].winbar = "%#" .. group .. "#  " .. label .. " · %<" .. name .. "  %*"
end
Paper.virtual_text = Paper.enabled and { current_line = true } or true
Paper.namespace = vim.api.nvim_create_namespace("foxml_paper_bookmarks")
Paper.quote_namespace = vim.api.nvim_create_namespace("foxml_paper_quotes")
local paper_signatures, paper_pending, paper_scheduled = {}, {}, false
local paper_quote_ticks, paper_quote_query = {}, nil

function Paper.file_buffer(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].buflisted
    and not vim.bo[buf].filetype:match("^fox%-symdeps")
end

function Paper.enable_hints(buf, client)
  if not Paper.enabled or not Paper.file_buffer(buf) or client.name ~= "clangd" then return end
  local ft = vim.bo[buf].filetype
  if (ft == "c" or ft == "cpp") and client:supports_method("textDocument/inlayHint", buf) then
    vim.lsp.inlay_hint.enable(true, { bufnr = buf })
  end
end

function Paper.setup_tmux_footer()
  local pane = vim.env.TMUX_PANE
  local socket = (vim.env.TMUX or ""):match("^(.*),%d+,%d+$")
  if not Paper.enabled or not socket or not pane or not pane:match("^%%%d+$") then return end
  local saved, window
  local function tmux(args)
    local ok, result = pcall(function()
      return vim.system(vim.list_extend({"tmux", "-S", socket}, args), {text = true}):wait(1000)
    end)
    if ok and result.code == 0 then return vim.trim(result.stdout or "") end
  end
  local function restore()
    if saved == nil or not window then return end
    -- Respect a manual option change made while the editor was open.
    if tmux({"show-options", "-wqv", "-t", window, "pane-border-status"}) == "off" then
      if saved == "" then tmux({"set-option", "-wu", "-t", window, "pane-border-status"})
      else tmux({"set-option", "-w", "-t", window, "pane-border-status", saved}) end
    end
    saved, window = nil, nil
  end
  local function refresh()
    local info = tmux({"display-message", "-p", "-t", pane, "#{window_id} #{window_panes}"})
    if not info then return end
    local id, count = info:match("^(@%d+) (%d+)$")
    if not id then return end
    if window and window ~= id then restore() end
    if tonumber(count) ~= 1 then restore(); return end
    if saved ~= nil then return end
    local previous = tmux({"show-options", "-wqv", "-t", id, "pane-border-status"})
    if previous == nil or previous == "off" then return end
    saved, window = previous, id
    if tmux({"set-option", "-w", "-t", id, "pane-border-status", "off"}) == nil then saved, window = nil, nil end
  end
  local group = vim.api.nvim_create_augroup("foxml_paper_tmux_footer", {clear = true})
  vim.api.nvim_create_autocmd({"VimEnter", "VimResized", "FocusGained"}, {
    group = group, callback = function() vim.schedule(refresh) end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {group = group, callback = restore})
  vim.schedule(refresh)
  return {refresh = refresh, restore = restore}
end

function Paper.whitespace()
  if not Paper.enabled then return end
  local code = { c=true, cpp=true, cuda=true, python=true, lua=true, rust=true, go=true, sh=true, zsh=true,
    javascript=true, typescript=true, javascriptreact=true, typescriptreact=true, json=true, yaml=true, toml=true }
  local style = "tab:  ,trail:·,nbsp:␣"
  if code[vim.bo.filetype] and Paper.file_buffer(vim.api.nvim_get_current_buf()) then
    if not vim.w.foxml_paper_whitespace then
      vim.w.foxml_paper_whitespace = { list = vim.wo.list, chars = vim.wo.listchars }
    end
    vim.wo.listchars, vim.wo.list = style, true
  elseif vim.w.foxml_paper_whitespace then
    local saved = vim.w.foxml_paper_whitespace
    if vim.wo.listchars == style then vim.wo.listchars = saved.chars end
    if vim.wo.list then vim.wo.list = saved.list end
    vim.w.foxml_paper_whitespace = nil
  end
end

function Paper.spelling()
  if not Paper.enabled then return end
  local buf = vim.api.nvim_get_current_buf()
  local prose = vim.bo.filetype == "markdown"
  local syntax_prose = vim.treesitter.highlighter.active[buf] ~= nil
  local saved = vim.w.foxml_paper_spelling
  if Paper.file_buffer(buf) and (prose or syntax_prose) then
    -- Tree-sitter's @spell / @nospell regions keep identifiers, URLs and code spans clear.
    if not saved then
      vim.w.foxml_paper_spelling = {previous = vim.wo.spell}
      vim.wo.spell = true
    end
  elseif saved then
    vim.wo.spell = saved.previous
    vim.w.foxml_paper_spelling = nil
  elseif not Paper.file_buffer(buf) then
    vim.wo.spell = false
  end
end

-- Keep transient marks separate from bookmarks and diagnostics.
Paper.paste_namespace = vim.api.nvim_create_namespace("foxml_paper_paste")
Paper.edit_namespace = vim.api.nvim_create_namespace("foxml_paper_last_edit")
Paper.invisible_namespace = vim.api.nvim_create_namespace("foxml_paper_invisibles")
local invisible_ticks = {}

function Paper.flash_paste()
  local buf = vim.api.nvim_get_current_buf()
  if not Paper.enabled or not Paper.file_buffer(buf) then return end
  local first, last = vim.fn.getpos("'["), vim.fn.getpos("']")
  if first[2] < 1 or last[2] < first[2] then return end
  vim.hl.range(buf, Paper.paste_namespace, "FoxPaperYank",
    {first[2] - 1, first[3] - 1}, {last[2] - 1, last[3] - 1}, {inclusive = true, timeout = 200})
end
_G.FoxPaperPasteFlash = Paper.flash_paste

function Paper.last_edit(buf)
  if not Paper.file_buffer(buf) then return end
  local pos = vim.api.nvim_buf_get_mark(buf, ".")
  vim.api.nvim_buf_clear_namespace(buf, Paper.edit_namespace, 0, -1)
  if pos[1] > 0 and pos[1] <= vim.api.nvim_buf_line_count(buf) then
    vim.api.nvim_buf_set_extmark(buf, Paper.edit_namespace, pos[1] - 1, 0,
      {sign_text = "✎ ", sign_hl_group = "FoxPaperLastEdit", priority = 0})
  end
end

function Paper.invisibles(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local tick = tostring(vim.api.nvim_buf_get_changedtick(buf)) .. ":" .. vim.bo[buf].filetype
  if invisible_ticks[buf] == tick then return end
  invisible_ticks[buf] = tick
  vim.api.nvim_buf_clear_namespace(buf, Paper.invisible_namespace, 0, -1)
  if not Paper.file_buffer(buf) or not vim.tbl_contains({"c", "cpp", "cuda", "python", "lua", "rust", "go",
      "sh", "zsh", "javascript", "typescript", "javascriptreact", "typescriptreact", "json", "jsonc", "yaml", "toml"}, vim.bo[buf].filetype) then return end
  -- These markers expose hidden bytes without rewriting text or enabling conceal.
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find("[\226\239]") then
      for _, codepoint in ipairs({0x200b, 0x200c, 0x200d, 0x2060, 0xfeff}) do
        local char = vim.fn.nr2char(codepoint)
        local from = 1
        while true do
          local col = line:find(char, from, true)
          if not col then break end
          vim.api.nvim_buf_set_extmark(buf, Paper.invisible_namespace, row - 1, col - 1,
            {virt_text = {{"⟨zw⟩", "FoxPaperInvisible"}}, virt_text_pos = "inline", priority = 90})
          from = col + #char
        end
      end
    end
  end
end

function Paper.setup_popup_styles()
  if not Paper.enabled then return end
  local api = vim.api
  local ns = api.nvim_create_namespace("foxml_paper_symdeps_counts")
  local pending = false
  local active_title = api.nvim_create_namespace("foxml_paper_active_title")
  local inactive_title = api.nvim_create_namespace("foxml_paper_inactive_title")
  local function owned(win)
    if not api.nvim_win_is_valid(win) then return false end
    return vim.wo[win].winhighlight:find("FoxSymdeps", 1, true) ~= nil
  end
  local function countable(buf)
    return vim.b[buf].fox_symdeps_menu or vim.bo[buf].filetype:match("^fox%-symdeps")
  end
  local function refresh()
    pending = false
    api.nvim_set_hl(0, "FoxSymdepsText", { fg = P.fg, bg = "NONE" })
    api.nvim_set_hl(0, "FoxSymdepsDim", { fg = P.comment, bg = "NONE", italic = false })
    api.nvim_set_hl(0, "FoxSymdepsSelection", { fg = P.fg, bg = P.sel, bold = true })
    api.nvim_set_hl(0, "FoxPaperSymdepsFocusTitle", { fg = P.fg, bg = P.sel, bold = true })
    api.nvim_set_hl(active_title, "FloatTitle", { fg = P.fg, bg = P.sel, bold = true })
    api.nvim_set_hl(inactive_title, "FloatTitle", { fg = P.fg, bg = "NONE", bold = true })
    api.nvim_set_hl(active_title, "EndOfBuffer", {})
    api.nvim_set_hl(inactive_title, "EndOfBuffer", {})
    local current = api.nvim_get_current_win()
    local documents = {}
    for _, win in ipairs(api.nvim_list_wins()) do
      local config = api.nvim_win_get_config(win)
      local ft = vim.bo[api.nvim_win_get_buf(win)].filetype
      if config.relative ~= "" and (vim.w[win].lsp_floating_bufnr or ft == "help" or ft == "markdown" or ft == "noice") then
        documents[win] = win
        -- Padded NUI popups draw their title in a separate parent frame.
        if config.relative == "win" and config.win and api.nvim_win_is_valid(config.win)
            and api.nvim_win_get_config(config.win).relative ~= "" then documents[config.win] = win end
      end
    end
    for _, win in ipairs(api.nvim_list_wins()) do
      if documents[win] then
        local namespace = api.nvim_get_hl_ns({ winid = win })
        local simple = namespace <= 0 or namespace == active_title or namespace == inactive_title
        if not simple then
          -- NUI uses a namespace solely to hide end-of-buffer markers.
          local groups = api.nvim_get_hl(namespace, {})
          simple = vim.tbl_count(groups) == 1 and groups.EndOfBuffer ~= nil
        end
        if simple then
          api.nvim_win_set_hl_ns(win, documents[win] == current and active_title or inactive_title)
        end
      end
      if owned(win) then
        local title = win == current and "FoxPaperSymdepsFocusTitle" or "FoxSymdepsTitle"
        local config = api.nvim_win_get_config(win)
        if type(config.title) == "table" then
          local changed = false
          for _, chunk in ipairs(config.title) do
            if chunk[2] == "FoxSymdepsTitle" or chunk[2] == "FoxPaperSymdepsFocusTitle" then
              if chunk[2] ~= title then chunk[2], changed = title, true end
            end
          end
          if changed then api.nvim_win_set_config(win, { title = config.title }) end
        end
        local bar = vim.wo[win].winbar:gsub("%%#FoxSymdepsTitle#", "%%#" .. title .. "#")
          :gsub("%%#FoxPaperSymdepsFocusTitle#", "%%#" .. title .. "#")
        if bar ~= vim.wo[win].winbar then vim.wo[win].winbar = bar end
        local buf = api.nvim_win_get_buf(win)
        -- Source and assembly panes may be large; count accents belong to the UI buffers.
        if countable(buf) then
          api.nvim_buf_clear_namespace(buf, ns, 0, -1)
          for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
            local first, last = line:find("%d+ actions?")
            if not first then first, last = line:find("%(%d+%)%s*$") end
            if first then
              api.nvim_buf_set_extmark(buf, ns, row - 1, first - 1,
                { end_col = last, hl_group = "FoxSymdepsDim", priority = 150 })
            end
          end
        end
      end
    end
  end
  local function queue(args)
    if args and (args.event == "CursorMoved" or args.event == "TextChanged")
        and not (owned(api.nvim_get_current_win()) and countable(api.nvim_get_current_buf())) then return end
    if pending then return end
    pending = true
    vim.schedule(refresh)
  end
  local group = api.nvim_create_augroup("foxml_paper_symdeps", { clear = true })
  api.nvim_create_autocmd({ "WinEnter", "WinLeave", "BufWinEnter", "ColorScheme", "CursorMoved", "TextChanged" },
    { group = group, callback = queue })
  refresh()
end
Paper.setup_symdeps = Paper.setup_popup_styles

function Paper.refresh(buf)
  if not Paper.enabled or not vim.api.nvim_buf_is_valid(buf) then return end
  if not Paper.file_buffer(buf) then
    vim.api.nvim_buf_clear_namespace(buf, Paper.namespace, 0, -1)
    paper_signatures[buf] = nil
    return
  end
  local rows = {}
  local marks = vim.fn.getmarklist(buf)
  vim.list_extend(marks, vim.fn.getmarklist())
  for _, mark in ipairs(marks) do
    local letter = mark.mark:match("^'([a-zA-Z])$")
    local pos = mark.pos
    if letter and pos[1] == buf and pos[2] > 0 and pos[2] <= vim.api.nvim_buf_line_count(buf) then
      if not rows[pos[2]] or letter < rows[pos[2]] then rows[pos[2]] = letter end
    end
  end
  local signature = {}
  for row, letter in pairs(rows) do signature[#signature + 1] = row .. ":" .. letter end
  table.sort(signature)
  signature = table.concat(signature, ",")
  if paper_signatures[buf] == signature then return end
  paper_signatures[buf] = signature
  vim.api.nvim_buf_clear_namespace(buf, Paper.namespace, 0, -1)
  for row, letter in pairs(rows) do
    -- One sign per line, below diagnostic/git/breakpoint priorities; never resize the gutter.
    vim.api.nvim_buf_set_extmark(buf, Paper.namespace, row - 1, 0,
      { sign_text = "󰃀" .. letter, sign_hl_group = "FoxPaperBookmark", priority = 1 })
  end
end

function Paper.refresh_quotes(buf)
  if not Paper.enabled or not vim.api.nvim_buf_is_valid(buf) then return end
  if not Paper.file_buffer(buf) or vim.bo[buf].filetype ~= "markdown"
      or vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.api.nvim_buf_clear_namespace(buf, Paper.quote_namespace, 0, -1)
    paper_quote_ticks[buf] = nil
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if paper_quote_ticks[buf] == tick then return end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok then return end
  local tree = parser:parse(true)[1]
  if not tree then return end
  paper_quote_query = paper_quote_query or vim.treesitter.query.parse("markdown",
    "(block_quote_marker) @opening (block_continuation) @rule (atx_heading) @heading (setext_heading) @heading")
  vim.api.nvim_buf_clear_namespace(buf, Paper.quote_namespace, 0, -1)
  local titled = false
  for id, node in paper_quote_query:iter_captures(tree:root(), buf) do
    local row, col = node:range()
    local capture = paper_quote_query.captures[id]
    if capture == "heading" then
      if not titled then
        local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
        local first = (line:match("^%s*#+%s+()") or 1) - 1
        local last = #line:gsub("%s+#+%s*$", "")
        if last > first then
          vim.api.nvim_buf_set_extmark(buf, Paper.quote_namespace, row, first, {
            end_col = last, hl_group = "FoxPaperMarkdownTitle", priority = 120,
          })
        end
        titled = true
      end
    else
    local opening = paper_quote_query.captures[id] == "opening"
    -- Overlay only syntax markers: source, text width, and fenced examples stay intact.
    for offset in vim.treesitter.get_node_text(node, buf):gmatch("()>") do
      vim.api.nvim_buf_set_extmark(buf, Paper.quote_namespace, row, col + offset - 1, {
        virt_text = { { opening and "“" or "│", opening and "FoxPaperQuoteOpen" or "FoxPaperQuoteRule" } },
        virt_text_pos = "overlay", virt_text_hide = true, hl_mode = "combine", priority = 110,
      })
    end
    end
  end
  if not Paper.footnote_query then
    local ok_inline, query = pcall(vim.treesitter.query.parse, "markdown_inline", "(shortcut_link) @reference")
    if ok_inline then Paper.footnote_query = query end
  end
  if Paper.footnote_query then
    local query = Paper.footnote_query
    parser:for_each_tree(function(inline_tree, language)
      if language:lang() ~= "markdown_inline" or language:parent() ~= parser then return end
      for _, node in query:iter_captures(inline_tree:root(), buf) do
        local text = vim.treesitter.get_node_text(node, buf)
        if text:match("^%[%^[^%s%]]+%]$") then
          local row, col, last_row, last_col = node:range()
          vim.api.nvim_buf_set_extmark(buf, Paper.quote_namespace, row, col,
            {end_row=last_row, end_col=last_col, hl_group="FoxPaperFootnote", priority=120})
        end
      end
    end)
  end
  paper_quote_ticks[buf] = tick
end

function Paper.correction_slip(opts, on_confirm)
  local ok_popup, Popup = pcall(require, "nui.popup")
  local ok_input, Input = pcall(require, "nui.input")
  if not ok_popup or not ok_input or vim.o.columns < 36 then return false end
  if Paper.active_correction then Paper.active_correction.finish(nil) end
  local origin = vim.api.nvim_get_current_win()
  local width = math.min(49, vim.o.columns - 12)
  local slip = Popup({relative="editor", position="50%", size={width=width,height=4}, enter=false,
    border={style="rounded",padding={0,2},text={
      top={{" ✎ correction ","FoxPaperSlipTitle"}},top_align="left",
      bottom={{" Enter applies · Esc cancels ","FoxPaperSlipOld"}},bottom_align="left"}},
    win_options={winhighlight="Normal:FoxPaperSlip,FloatBorder:FoxPaperSlipBorder",winblend=0}})
  local input, finished
  local function finish(value)
    if finished then return end
    finished = true
    local restore = input and vim.api.nvim_get_current_win() == input.winid
    Paper.active_correction = nil
    -- Let NUI finish its queued mount before tearing a superseded prompt down.
    vim.schedule(function()
      if input then input:unmount() end
      slip:unmount()
      if restore and vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
      on_confirm(value)
    end)
  end
  slip:mount()
  vim.api.nvim_buf_set_lines(slip.bufnr,0,-1,false,{opts.default or "","","",""})
  vim.api.nvim_buf_add_highlight(slip.bufnr,-1,"FoxPaperSlipOld",0,0,-1)
  input = Input({relative={type="win",winid=slip.winid},position={row=2,col=0},
    size={width=width,height=1},border={style="none"},
    win_options={winhighlight="Normal:FoxPaperSlipInput,NormalNC:FoxPaperSlipInput",winblend=0}},
    {prompt="→ ",default_value=opts.default or "",on_submit=finish,on_close=function()finish(nil)end})
  Paper.active_correction = {input=input,slip=slip,finish=finish}
  input:mount()
  for _, mode in ipairs({"i","n"}) do
    input:map(mode,"<Esc>",function()finish(nil)end,{noremap=true})
  end
  vim.api.nvim_create_autocmd("WinClosed",{pattern=tostring(slip.winid),once=true,callback=function()finish(nil)end})
  return true
end

function Paper.setup_correction_input()
  if not Paper.enabled then return end
  local previous = vim.ui.input
  vim.ui.input = function(opts, on_confirm)
    local rename = type(opts.prompt) == "string" and opts.prompt:lower():match("^new name:%s*$")
    if rename and Paper.correction_slip(opts,on_confirm) then return end
    return previous(opts,on_confirm)
  end
end

function Paper.queue(buf)
  paper_pending[buf] = true
  if paper_scheduled then return end
  paper_scheduled = true
  vim.schedule(function()
    local pending = paper_pending
    paper_pending, paper_scheduled = {}, false
    for buffer in pairs(pending) do Paper.refresh(buffer); Paper.refresh_quotes(buffer); Paper.invisibles(buffer) end
  end)
end

function Paper.foldtext()
  local first = vim.trim(vim.fn.getline(vim.v.foldstart))
  return { { "▸  ", "FoxPaperFoldArrow" }, { first, "FoxPaperFoldText" },
           { ("  · %d lines"):format(vim.v.foldend - vim.v.foldstart + 1), "FoxPaperFoldCount" } }
end
_G.FoxPaperFoldText = Paper.foldtext

if Paper.enabled then
  local group = vim.api.nvim_create_augroup("foxml_paper_details", { clear = true })
  vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "WinEnter" }, {
    group = group,
    callback = function(args)
      if args.buf == vim.api.nvim_get_current_buf() then Paper.whitespace() end
      vim.schedule(Paper.spelling)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "CursorHold", "TextChanged", "TextChangedI",
      "BufWritePost", "CmdlineLeave", "FileType", "InsertEnter", "InsertLeave" }, {
    group = group, callback = function(args) Paper.queue(args.buf) end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = group, callback = function(args) Paper.last_edit(args.buf) end,
  })
  -- The native put executes first, preserving registers, counts and dot-repeat.
  for _, key in ipairs({"p", "P"}) do
    vim.keymap.set("n", key, key .. "<Cmd>lua FoxPaperPasteFlash()<CR>", {silent = true, desc = "Put with blush flash"})
  end
  local native_paste, paste_start, paste_buf = vim.paste, nil, nil
  vim.paste = function(lines, phase)
    local result = native_paste(lines, phase)
    local buf = vim.api.nvim_get_current_buf()
    if result and Paper.file_buffer(buf) then
      if phase < 2 then paste_start, paste_buf = vim.fn.getpos("'["), buf end
      if (phase == -1 or phase == 3) and paste_start and paste_buf == buf then
        local last = vim.fn.getpos("']")
        if paste_start[2] > 0 and last[2] >= paste_start[2] then
          vim.hl.range(buf, Paper.paste_namespace, "FoxPaperYank",
            {paste_start[2] - 1, paste_start[3] - 1}, {last[2] - 1, last[3] - 1}, {inclusive = true, timeout = 200})
        end
      end
    end
    if phase == -1 or phase == 3 or not result then paste_start, paste_buf = nil, nil end
    return result
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group, callback = function(args)
      paper_signatures[args.buf], paper_pending[args.buf], paper_quote_ticks[args.buf], invisible_ticks[args.buf] = nil, nil, nil, nil
    end,
  })
end
-- <<< fox-paper-details

Paper.setup_tmux_footer()

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- === AI ===

-- Helper to read global AI model preference
local function get_global_model(fallback)
  local path = vim.fn.expand("~/.config/opencode/opencode.json")
  if vim.fn.filereadable(path) == 1 then
    local content = table.concat(vim.fn.readfile(path), "")
    local ok, data = pcall(vim.fn.json_decode, content)
    if ok and data.model then
      return (data.model:gsub("^ollama/", ""):gsub("^llamacpp/", "")) -- a provider prefix opencode adds; the bare name is the server's
    end
  end
  return fallback
end

-- The model a ROLE names in the roles file — the same lookup as fox-llm-serve and fox-llm-run: the FIRST of
-- $XDG_CONFIG_HOME/foxml/llm/roles.conf, ~/code/custom_models/roles.conf, $XDG_CONFIG_HOME/foxml/llm/roles.default that
-- exists decides, read whole (no fall-through to the next file); a line is `role model [engine]`, `#` a comment. So a
-- swap of CodeCompanion's model is one line there.
local function role_model(role, fallback)
  local xdg = vim.env.XDG_CONFIG_HOME
  local llm_dir = ((xdg and xdg ~= "") and xdg or (vim.env.HOME .. "/.config")) .. "/foxml/llm"
  for _, f in ipairs({ llm_dir .. "/roles.conf", vim.env.HOME .. "/code/custom_models/roles.conf", llm_dir .. "/roles.default" }) do
    if vim.fn.filereadable(f) == 1 then
      for _, l in ipairs(vim.fn.readfile(f)) do
        local r, m = l:match("^%s*(%S+)%s+(%S+)")
        if r == role and not r:match("^#") then return m end
      end
      return fallback
    end
  end
  return fallback
end

-- the quick role: CodeCompanion's chat, inline edits and commands. Measured on her laptop 2026-10-14 (the same 1.5k-token
-- C++ prompt + a compile-and-run C++ task): qwen3.5:4b passed and reads 147 tok/s; qwen2.5-coder:3b was faster but got
-- the task wrong; qwen2.5-coder:7b passed but reads 89 tok/s
local quick_model = role_model("quick", "qwen3.5:4b")
local global_model = get_global_model(quick_model)

-- >>> fox-repo-visibility
-- Copilot only where the code is public (2026-10-15): Copilot sends what you type to GitHub, so it attaches only to a
-- buffer whose repo GitHub reports public. Everything else (a private repo, no remote, another host, no `gh`, an
-- answer not in yet) gets the local model. The answer comes from `gh`, in the background, once a day per repo (cached
-- in stdpath("cache")); a definite answer is kept, "unknown" is asked again after ten minutes. Nothing here blocks.
-- tests/test_nvim_repo_visibility.py runs this block on its own: it starts and ends at these two sentinel lines.
local RepoVis = { ttl = 24 * 3600, retry = 600, cache = nil, asking = {}, unknown = {} }
RepoVis.path = vim.fn.stdpath("cache") .. "/fox-repo-visibility.json"

-- "owner/name" from a GitHub remote URL (git@…:, https://…, ssh://git@…), or nil for anything else
function RepoVis.github(url)
  url = vim.trim(url or "")
  local o, n = url:match("^git@github%.com:([%w._-]+)/([%w._-]+)$")
  if not o then o, n = url:match("^https://github%.com/([%w._-]+)/([%w._-]+)/?$") end
  if not o then o, n = url:match("^ssh://git@github%.com/([%w._-]+)/([%w._-]+)/?$") end
  if not o then return nil end
  n = n:gsub("%.git$", "")
  if n == "" then return nil end
  return o .. "/" .. n
end

function RepoVis.load()
  if RepoVis.cache then return RepoVis.cache end
  local ok, data = pcall(function()
    local f = io.open(RepoVis.path, "r")
    if not f then return {} end
    local text = f:read("*a")
    f:close()
    return vim.json.decode(text)
  end)
  RepoVis.cache = (ok and type(data) == "table") and data or {}
  return RepoVis.cache
end

function RepoVis.save()
  vim.fn.mkdir(vim.fs.dirname(RepoVis.path), "p")
  local tmp = RepoVis.path .. ".tmp" .. vim.fn.getpid()
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(vim.json.encode(RepoVis.cache or {}))
  f:close()
  os.rename(tmp, RepoVis.path) -- atomic: a reader sees the old file or the new one
end

-- a repo's visibility → cb("public" | "private" | "internal" | "unknown"), on the main loop
function RepoVis.ask(repo, cb)
  local c = RepoVis.load()[repo]
  if type(c) == "table" and type(c.t) == "number" and os.time() - c.t < RepoVis.ttl then return cb(c.v) end
  if RepoVis.unknown[repo] and os.time() - RepoVis.unknown[repo] < RepoVis.retry then return cb("unknown") end
  if RepoVis.asking[repo] then table.insert(RepoVis.asking[repo], cb); return end
  RepoVis.asking[repo] = { cb }
  local function done(v)
    vim.schedule(function()
      if v == "public" or v == "private" or v == "internal" then
        RepoVis.load()[repo] = { v = v, t = os.time() }
        RepoVis.save()
        RepoVis.unknown[repo] = nil
      else
        v = "unknown"
        RepoVis.unknown[repo] = os.time()
      end
      local cbs = RepoVis.asking[repo] or {}
      RepoVis.asking[repo] = nil
      for _, f in ipairs(cbs) do f(v) end
    end)
  end
  -- vim.system throws when gh is not installed: that is "unknown" too
  local ok = pcall(vim.system, { "gh", "api", "repos/" .. repo, "--jq", ".visibility" }, { text = true, timeout = 15000 },
    function(r) done(r.code == 0 and vim.trim(r.stdout or "") or "unknown") end)
  if not ok then done("unknown") end
end

-- a file's repo visibility → cb(...), as RepoVis.ask; a file outside git, or with no GitHub origin, is "unknown"
function RepoVis.lookup(file, cb)
  local dir = vim.fs.dirname(file)
  if not dir or vim.fn.isdirectory(dir) == 0 then return cb("unknown") end
  -- `remote get-url` applies the url.insteadOf rewrites, as git itself would when pushing
  local ok = pcall(vim.system, { "git", "-C", dir, "remote", "get-url", "origin" }, { text = true, timeout = 5000 },
    function(r)
      vim.schedule(function()
        local repo = r.code == 0 and RepoVis.github(r.stdout) or nil
        if repo then RepoVis.ask(repo, cb) else cb("unknown") end
      end)
    end)
  if not ok then cb("unknown") end
end

-- a buffer's engine: "copilot" only for a repo GitHub reports public, while the mode is per repo
function RepoVis.engine(buf)
  if vim.g.fox_completion == "local" then return "local" end
  return vim.b[buf].fox_visibility == "public" and "copilot" or "local"
end
-- <<< fox-repo-visibility

local plugins = {
  { "nvim-lualine/lualine.nvim",           dependencies = { "nvim-tree/nvim-web-devicons" } },
  { "lukas-reineke/indent-blankline.nvim", main = "ibl",
    config = function()
      -- Define highlight groups before ibl.setup so they exist at init time
      local hl = vim.api.nvim_set_hl
      hl(0, "RainbowIndent1", { fg = P.indent[1] })
      hl(0, "RainbowIndent2", { fg = P.indent[2] })
      hl(0, "RainbowIndent3", { fg = P.indent[3] })
      hl(0, "RainbowIndent4", { fg = P.indent[4] })
      hl(0, "RainbowIndent5", { fg = P.indent[5] })
      hl(0, "RainbowIndent6", { fg = P.indent[6] })
      hl(0, "IblScope", { fg = Paper.enabled and P.bookmark or P.ibl_scope })
      require("ibl").setup({
        indent = {
          highlight = {
            "RainbowIndent1", "RainbowIndent2", "RainbowIndent3",
            "RainbowIndent4", "RainbowIndent5", "RainbowIndent6",
          },
        },
        scope = { enabled = {{SHOW_WELCOME}}, highlight = "IblScope", show_start = false, show_end = false },
      })
      if Paper.enabled then
        local hooks = require("ibl.hooks")
        hooks.register(hooks.type.ACTIVE, Paper.file_buffer)
      end
    end },

  -- Core editing (commenting is core gc/gcc since nvim 0.10 — see <leader>/ below)
  { "windwp/nvim-autopairs",               config = {{SHOW_WELCOME}} },
  { "folke/which-key.nvim",                event = "VeryLazy",
    opts = {
      -- named leader groups (the popup showed a bare "+4 keymaps" for each)
      spec = {
        { "<leader>b", group = "buffers" },
        { "<leader>C", group = "claude" },
        { "<leader>c", group = "code / cmake" },
        { "<leader>d", group = "symdeps" },      -- fox-symdeps: labelled before the plugin loads (it loads on first press)
        { "<leader>f", group = "find" },
        { "<leader>g", group = "git" },
        { "<leader>h", group = "harpoon" },
        { "<leader>k", group = "multicursor" },
        { "<leader>m", group = "tasks" },
        { "<leader>n", group = "swap params" },
        { "<leader>p", group = "projects" },
        { "<leader>q", group = "session / quit" },
        { "<leader>r", group = "refactor" },
        { "<leader>s", group = "search / split" },
        { "<leader>t", group = "toggle / test" },
        { "<leader>x", group = "diagnostics" },
      },
    } },

  -- Fuzzy finding (default branch: the pinned 0.1.x (2024) called nvim-treesitter's removed configs
  -- module, so every file preview errored and lost its syntax colors)
  {
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim", "nvim-tree/nvim-web-devicons" }
  },
  -- Neo-tree (file tree sidebar)
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    cmd = "Neotree",
    keys = {
      { "<leader>e", "<cmd>Neotree toggle<cr>", desc = "File Explorer (Neo-tree)" },
    },
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-tree/nvim-web-devicons",
      "MunifTanjim/nui.nvim",
    },
    opts = {
      close_if_last_window = {{SHOW_WELCOME}},
      popup_border_style = "rounded",
      enable_git_status = {{SHOW_WELCOME}},
      enable_diagnostics = {{SHOW_WELCOME}},
      window = {
        width = 45,
        mappings = {
          ["<space>"] = "none",
          ["l"] = "open",
          ["h"] = "close_node",
          ["<cr>"] = "open",
          ["s"] = "open_split",
          ["v"] = "open_vsplit",
        },
      },
      filesystem = {
        follow_current_file = { enabled = {{SHOW_WELCOME}} },
        use_libuv_file_watcher = {{SHOW_WELCOME}},
        group_empty_dirs = {{SHOW_WELCOME}},
        filtered_items = {
          visible = false,
          hide_dotfiles = false,
          hide_gitignored = false,
          hide_by_name = { ".git", "node_modules", ".cache" },
        },
      },
      default_component_configs = {
        indent = {
          indent_size = 2,
          padding = 1,
          with_markers = {{SHOW_WELCOME}},
          indent_marker = "│",
          last_indent_marker = "└",
        },
        icon = {
          -- foxml:tree-folders-begin
          folder_closed = "",
          folder_open = "",
          folder_empty = "󰉖",
          folder_empty_open = "",
          -- foxml:tree-folders-end
          provider = Paper.enabled and function(icon, node, state)
            -- Keep Neo-tree's file/terminal icons; decorate only expanded directories.
            require("neo-tree.defaults").default_component_configs.icon.provider(icon, node, state)
            if node.type == "directory" and node:is_expanded() then
              icon.highlight = "FoxPaperOpenFolder"
            end
            return icon
          end or nil,
        },
        name = {
          trailing_slash = false,
          use_git_status_colors = {{SHOW_WELCOME}},
        },
        git_status = {
          symbols = {
            added     = "",
            modified  = "",
            deleted   = "",
            renamed   = "󰁕",
            untracked = "",
            ignored   = "",
            unstaged  = "󰄱",
            staged    = "",
            conflict  = "",
          },
        },
      },
    },
  },

  -- Bufferline (buffer tabs)
  {
    "akinsho/bufferline.nvim",
    version = "*",
    event = "BufReadPost",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      options = {
        diagnostics = "nvim_lsp",
        offsets = {
          { filetype = "neo-tree", text = "  File Explorer", text_align = "left", highlight = "Directory", separator = {{SHOW_WELCOME}} },
        },
        separator_style = "thin",
        modified_icon = Paper.enabled and "✎" or "●",
        -- a ✎ after a buffer a live Claude edited lately (foxml.claude)
        name_formatter = function(buf)
          local ok, claude = pcall(require, "foxml.claude")
          return ok and claude.bufferline_name(buf) or buf.name
        end,
        show_buffer_close_icons = false,
        show_close_icon = false,
      },
      highlights = {
        -- Keep visible file names steady when focus moves to the sidebar.
        fill = { bg = P.none },
        background = { fg = P.comment, bg = P.none },
        buffer_selected = { fg = P.fg, bg = Paper.enabled and P.sel or P.none, bold = {{SHOW_WELCOME}}, italic = not Paper.enabled and {{SHOW_WELCOME}} },
        buffer_visible = { fg = Paper.enabled and P.fg or P.comment, bg = P.none, bold = Paper.enabled or nil, italic = false },
        separator = { fg = P.bg_hl, bg = P.none },
        separator_selected = { fg = P.bg_hl, bg = Paper.enabled and P.sel or P.none },
        separator_visible = { fg = P.bg_hl, bg = P.none },
        indicator_selected = { fg = P.peach, bg = Paper.enabled and P.sel or P.none },
        modified = { fg = Paper.enabled and P.comment or P.yellow, bg = P.none },
        modified_selected = { fg = Paper.enabled and P.comment or P.yellow, bg = Paper.enabled and P.sel or P.none },
        modified_visible = { fg = Paper.enabled and P.comment or P.yellow, bg = P.none },
        tab = { fg = P.comment, bg = P.none },
        tab_selected = { fg = P.peach, bg = P.none, bold = {{SHOW_WELCOME}} },
        tab_separator = { fg = P.bg_hl, bg = P.none },
        tab_separator_selected = { fg = P.bg_hl, bg = P.none },
        duplicate = { fg = P.comment, bg = P.none, italic = {{SHOW_WELCOME}} },
        duplicate_selected = { fg = P.fg, bg = Paper.enabled and P.sel or P.none, bold = Paper.enabled or nil, italic = not Paper.enabled and {{SHOW_WELCOME}} },
        duplicate_visible = { fg = Paper.enabled and P.fg or P.comment, bg = P.none, bold = Paper.enabled or nil, italic = false },
        diagnostic_selected = { bold = {{SHOW_WELCOME}} },
      },
    },
  },

  -- Git
  {
    "lewis6991/gitsigns.nvim",
    opts = {
      signs = Paper.enabled and {
        add = { text = "│" }, change = { text = "│" }, delete = { text = "▁" },
        topdelete = { text = "▔" }, changedelete = { text = "┆" }, untracked = { text = "┆" },
      } or nil,
      signs_staged = Paper.enabled and {
        add = { text = "┊" }, change = { text = "┊" }, delete = { text = "▁" },
        topdelete = { text = "▔" }, changedelete = { text = "┊" }, untracked = { text = "┊" },
      } or nil,
      current_line_blame = {{SHOW_WELCOME}},
      current_line_blame_opts = { delay = 300, virt_text_pos = "eol" },
      -- ✿ the Claude session behind a line (its commit's Claude-Session trailer), ● you (foxml.claude)
      current_line_blame_formatter = function(user, info)
        local ok, claude = pcall(require, "foxml.claude")
        if ok then return claude.blame_formatter(user, info) end
        return { { "  " .. (info.author or "") .. " · " .. (info.summary or ""), "GitSignsCurrentLineBlame" } }
      end,
    },
  },

  -- Syntax / Treesitter — main branch (required by nvim 0.12; master is frozen and
  -- hard-errors on 0.12). The rewrite dropped require("nvim-treesitter.configs") for
  -- setup()/install() + core vim.treesitter APIs (wired near the bottom of this file).
  -- Compiles parsers locally → needs the tree-sitter CLI + a C compiler on PATH.
  { "nvim-treesitter/nvim-treesitter",  branch = "main", build = ":TSUpdate" },

  -- LSP + Autocomplete
  { "neovim/nvim-lspconfig" },
  { "williamboman/mason.nvim" },        -- mason 2.x: :MasonUpdate gone, registry auto-updates
  { "williamboman/mason-lspconfig.nvim" },
  { "hrsh7th/nvim-cmp" },
  { "hrsh7th/cmp-nvim-lsp" },
  { "hrsh7th/cmp-buffer" },
  { "hrsh7th/cmp-path" },
  { "L3MON4D3/LuaSnip",                 build = "make install_jsregexp" },
  { "saadparwaiz1/cmp_luasnip" },
  { "echasnovski/mini.icons",           version = false },

  -- Diagnostics UI
  {
    "folke/trouble.nvim",
    cmd = "Trouble",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {},
  },
  -- TODO highlights
  {
    "folke/todo-comments.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = Paper.enabled and {
      keywords = { NOTE = { alt = { "INFO", "IDEA" } } },
      highlight = { keyword = "bg", after = "", multiline = false },
    } or {},
  },

  -- Projects
  {
    "coffebar/project.nvim",
    pin = {{SHOW_WELCOME}},
    event = "VeryLazy",
    opts = {
      detection_methods = { "lsp", "pattern" },
      patterns = { ".git", "compile_commands.json", "CMakeLists.txt", "Makefile" },
      silent_chdir = {{SHOW_WELCOME}},
    },
    config = function(_, opts)
      require("project_nvim").setup(opts)
      require("telescope").load_extension("projects")
    end,
  },

  -- Task menu (<leader>m): a project's own build.sh lanes, CMake configure/build/CTest for CMake projects
  -- without a build.sh, plus overseer's builtin make/npm/cargo/just providers. Compiler errors land in
  -- quickfix (<leader>xq), which opens by itself when a task fails.
  {
    "stevearc/overseer.nvim",
    cmd = { "OverseerRun", "OverseerToggle", "OverseerTaskAction" },
    keys = {
      { "<leader>mm", "<cmd>OverseerRun<cr>", desc = "Run task" },
      { "<leader>mt", function()
        if #require("overseer").list_tasks() == 0 then
          vim.notify("No tasks yet: <leader>mm runs one") -- not an empty "--no task buffer--" panel
        else
          vim.cmd("OverseerToggle")
        end
      end, desc = "Task list" },
      { "<leader>ml", function()
        local overseer = require("overseer")
        local last = overseer.list_tasks({ sort = function(a, b) return a.id > b.id end })[1]
        if last then overseer.run_action(last, "restart") else vim.notify("No task has run yet") end
      end, desc = "Rerun last task" },
    },
    opts = {},
    config = function(_, opts)
      local overseer = require("overseer")
      overseer.setup(opts)
      -- Raw (non-terminal) output: a terminal buffer hard-wraps long lines at its width, splitting gcc
      -- diagnostics so the quickfix parser only sees fragments ("warning: no").
      local function build_task(task)
        task.strategy = { "jobstart", use_terminal = false }
        task.components = { { "on_output_quickfix", open_on_exit = "failure", items_only = true }, "default" }
        return task
      end

      -- Lanes are the arms of build.sh's first `case "$VAR" in` dispatch: the code is the truth (the
      -- trader's usage comment lists 10 lanes, its dispatch has 14). Descriptions come from the usage
      -- block where a lane has one.
      local function buildsh_lanes(path)
        local lanes, desc, seen, in_case = {}, {}, {}, false
        for line in io.lines(path) do
          local name, text = line:match("^#%s+([%w_-]+)%s%s+(%S.*)$")
          if name and not desc[name] then desc[name] = text end
          if not in_case then
            in_case = line:match('^%s*case%s+"?%${?[%w_]+}?"?%s+in') ~= nil
          elseif line:match("^%s*esac") then
            break
          else
            for arm in (line:match("^%s*([%w_|-]+)%)") or ""):gmatch("[^|]+") do
              if not arm:match("^%-") and not seen[arm] then seen[arm] = true; lanes[#lanes + 1] = arm end
            end
          end
        end
        return lanes, desc
      end

      overseer.register_template({
        name = "build.sh",
        generator = function(search)
          local script = vim.fs.find("build.sh", { upward = true, path = search.dir, type = "file", stop = vim.env.HOME })[1]
          if not script then return "no build.sh above " .. search.dir end
          local root = vim.fs.dirname(script)
          local lanes, desc = buildsh_lanes(script)
          return vim.tbl_map(function(lane)
            return {
              name = "build.sh " .. lane,
              desc = desc[lane] or "(not in build.sh's usage text)",
              builder = function() return build_task({ cmd = { "./build.sh", lane }, cwd = root }) end,
            }
          end, lanes)
        end,
        cache_key = function(search)
          return vim.fs.find("build.sh", { upward = true, path = search.dir, type = "file", stop = vim.env.HOME })[1]
        end,
      })

      -- CMake projects WITHOUT their own build.sh driver (a driver pins lanes/flags, so it owns the build).
      overseer.register_template({
        name = "cmake",
        generator = function(search)
          local found = vim.fs.find("CMakeLists.txt", { upward = true, path = search.dir, type = "file", stop = vim.env.HOME, limit = math.huge })
          if #found == 0 then return "no CMakeLists.txt above " .. search.dir end
          local root = vim.fs.dirname(found[#found]) -- topmost: nested CMakeLists.txt are subdirectories
          if vim.uv.fs_stat(root .. "/build.sh") then return "project builds via its own build.sh" end
          local build = root .. "/build"
          return {
            { name = "cmake: configure", builder = function()
              return build_task({ cmd = { "cmake", "-S", root, "-B", build, "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON" } })
            end },
            { name = "cmake: build", builder = function() return build_task({ cmd = { "cmake", "--build", build, "-j" } }) end },
            { name = "ctest", builder = function()
              return build_task({ cmd = { "ctest", "--test-dir", build, "--output-on-failure" } })
            end },
          }
        end,
      })
    end,
  },
  {
    "akinsho/toggleterm.nvim",
    cmd = "ToggleTerm",
    keys = {
      { "<C-\\>", "<cmd>ToggleTerm<cr>", desc = "Toggle Terminal" },
    },
    opts = {
      open_mapping = [[<C-\>]],
    },
  },

  {
    "Civitasv/cmake-tools.nvim",
    ft = { "c", "cpp", "cmake" },
    dependencies = { "nvim-lua/plenary.nvim", "stevearc/overseer.nvim", "akinsho/toggleterm.nvim" },
    opts = {
      cmake_use_preset = {{SHOW_WELCOME}},
      cmake_regenerate_on_save = {{SHOW_WELCOME}},
      cmake_generate_options = { "-DCMAKE_EXPORT_COMPILE_COMMANDS=1" },
      -- target is a function so cmake-tools resolves it at generate time; a plain vim.uv.cwd() froze the
      -- launch dir, and a stray ~/code/compile_commands.json would hijack clangd's root for every project
      cmake_compile_commands_options = { action = "soft_link", target = function() return vim.uv.cwd() end },
      -- preset DAP integration (we'll install codelldb via Mason)
      cmake_dap_configuration = { name = "cpp", type = "codelldb", request = "launch", runInTerminal = {{SHOW_WELCOME}} },
    },
  },

  {
    "mfussenegger/nvim-dap",
    keys = {
      { "<F5>", function() require("dap").continue() end, desc = "DAP Continue" },
      { "<F9>", function() require("dap").toggle_breakpoint() end, desc = "DAP Toggle Breakpoint" },
      { "<F10>", function() require("dap").step_over() end, desc = "DAP Step Over" },
      { "<F11>", function() require("dap").step_into() end, desc = "DAP Step Into" },
    },
  },
  { "nvim-neotest/nvim-nio",             lazy = {{SHOW_WELCOME}} },
  {
    "rcarriga/nvim-dap-ui",
    dependencies = { "mfussenegger/nvim-dap", "nvim-neotest/nvim-nio" },
    lazy = {{SHOW_WELCOME}},
    config = function()
      local dap, dapui = require("dap"), require("dapui")
      dapui.setup()
      dap.listeners.after.event_initialized["dapui"] = function() dapui.open() end
      dap.listeners.before.event_terminated["dapui"] = function() dapui.close() end
      dap.listeners.before.event_exited["dapui"] = function() dapui.close() end
    end,
  },
  {
    "jay-babu/mason-nvim-dap.nvim",
    lazy = {{SHOW_WELCOME}},
    opts = {
      automatic_installation = {{SHOW_WELCOME}},
      ensure_installed = { "codelldb" },
    },
  },
  {
    "theHamsta/nvim-dap-virtual-text",
    dependencies = { "mfussenegger/nvim-dap", "nvim-treesitter/nvim-treesitter" },
    lazy = {{SHOW_WELCOME}},
    opts = {},
  },

  {
    "stevearc/conform.nvim",
    opts = {
      format_on_save = function(buf)
        local ft = vim.bo[buf].filetype
        if ft == "json" and not pcall(vim.json.decode, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")) then return nil end
        return {lsp_format = "fallback", timeout_ms = (ft == "python" or ft == "json" or ft == "jsonc") and 1500 or 500}
      end,
      formatters_by_ft = {
        c = {"clang-format"}, cpp = {"clang-format"},
        python = function(buf)
          local path = vim.api.nvim_buf_get_name(buf)
          local config = vim.fs.find("pyproject.toml", {path = vim.fs.dirname(path), upward = true})[1]
          if config then
            local body = table.concat(vim.fn.readfile(config), "\n")
            if ("\n" .. body .. "\n"):match("\n%s*%[tool%.black%]%s*[#\n]") then return {"black"} end
          end
          if require("conform").get_formatter_info("ruff_format", buf).available then return {"ruff_format"} end
          return {"black"}
        end,
        -- Prettier is used when available; the already-installed JSON LSP is the fallback.
        json = {"prettier"}, jsonc = {"prettier"},
      },
      formatters = {
        -- Resolved at format time: lazy.nvim reads this spec before conform is on the runtimepath.
        ruff_format = {command = function(self, ctx)
          return require("conform.util").find_executable({".venv/bin/ruff", "venv/bin/ruff"}, "ruff")(self, ctx)
        end},
        black = {command = function(self, ctx)
          return require("conform.util").find_executable({".venv/bin/black", "venv/bin/black"}, "black")(self, ctx)
        end},
      },
    },
  },

  {
    "mfussenegger/nvim-lint",
    config = function()
      local lint = require("lint")
      lint.linters_by_ft = { c = { "clangtidy" }, cpp = { "clangtidy" } }
      vim.api.nvim_create_autocmd({ "BufWritePost", "InsertLeave" }, {
        callback = function() require("lint").try_lint() end,
      })
    end,
  },

  -- LaTeX — DISABLED: no LaTeX in use.
  {
    "lervag/vimtex",
    enabled = false,
    ft = "tex",
    init = function()
      vim.g.vimtex_view_method = "zathura"
      vim.g.vimtex_compiler_method = "latexmk"
      vim.g.vimtex_quickfix_mode = 0
    end,
  },

  {
    "stevearc/aerial.nvim",
    cmd = "AerialToggle",
    opts = {},
  },
  { "nvim-treesitter/nvim-treesitter-context", opts = {} },

  -- Neotest core + GTest adapter (lazy-loaded)
  {
    "nvim-neotest/neotest",
    cmd = "Neotest",
    dependencies = { "nvim-lua/plenary.nvim", "nvim-treesitter/nvim-treesitter", "nvim-neotest/nvim-nio", "alfaix/neotest-gtest" },
    config = function()
      require("neotest").setup({
        adapters = {
          require("neotest-gtest").setup({}),
        },
      })
    end,
  },
  { "alfaix/neotest-gtest", lazy = {{SHOW_WELCOME}} },

  -- Treesitter textobjects (daf = delete a function, vac = select a class, etc.)
  {
    "nvim-treesitter/nvim-treesitter-textobjects",
    branch = "main",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
  },

  -- Flash.nvim (jump anywhere with s + 2 chars)
  {
    "folke/flash.nvim",
    event = "VeryLazy",
    opts = {},
    keys = {
      { "s", mode = { "n", "x", "o" }, function() require("flash").jump() end, desc = "Flash" },
      { "S", mode = { "n", "x", "o" }, function() require("flash").treesitter() end, desc = "Flash Treesitter" },
    },
  },

  -- Surround (ysiw" to wrap word in quotes, cs"' to change, ds" to delete)
  { "kylechui/nvim-surround", version = "*", event = "VeryLazy", opts = {} },

  -- Multicursor (multicursor.nvim): type on several lines at once. Its own keys sit around the existing ones —
  -- <leader>n / s / m / a / x, <C-Up> / <C-Down>, <A-j> / <A-k> and visual ga are taken — under <leader>k ("kursors").
  -- <Left> / <Right> / <leader>kx / <Esc> are a layer: they act only while there are several cursors.
  {
    "jake-stewart/multicursor.nvim",
    branch = "1.0",
    event = "VeryLazy",
    config = function()
      local mc = require("multicursor-nvim")
      mc.setup()
      local set = function(mode, lhs, rhs, desc) vim.keymap.set(mode, lhs, rhs, { desc = desc }) end
      set({ "n", "x" }, "<Up>", function() mc.lineAddCursor(-1) end, "Cursor: add on the line above")
      set({ "n", "x" }, "<Down>", function() mc.lineAddCursor(1) end, "Cursor: add on the line below")
      set({ "n", "x" }, "<C-n>", function() mc.matchAddCursor(1) end, "Cursor: add at the next match")
      set({ "n", "x" }, "<leader>kn", function() mc.matchAddCursor(1) end, "Add at the next match")
      set({ "n", "x" }, "<leader>kN", function() mc.matchAddCursor(-1) end, "Add at the previous match")
      set({ "n", "x" }, "<leader>ks", function() mc.matchSkipCursor(1) end, "Skip the next match")
      set({ "n", "x" }, "<leader>kS", function() mc.matchSkipCursor(-1) end, "Skip the previous match")
      set({ "n", "x" }, "<leader>ka", mc.matchAllAddCursors, "Add at every match in the file")
      set({ "n", "x" }, "<leader>kj", function() mc.lineSkipCursor(1) end, "Skip the line below")
      set({ "n", "x" }, "<leader>kk", function() mc.lineSkipCursor(-1) end, "Skip the line above")
      set({ "n", "x" }, "<leader>kl", mc.addCursorOperator, "One per line (a motion, or the selection)")
      set("n", "<leader>kr", mc.restoreCursors, "Bring back the cleared cursors")
      set("n", "<leader>k=", mc.alignCursors, "Line the cursors up in one column")
      set({ "n", "x" }, "<C-q>", mc.toggleCursor, "Cursor: add / remove here")
      set("n", "<C-LeftMouse>", mc.handleMouse, "Cursor: add / remove at the click")
      set("n", "<C-LeftDrag>", mc.handleMouseDrag, "Cursor: drag")
      set("n", "<C-LeftRelease>", mc.handleMouseRelease, "Cursor: drop")
      mc.addKeymapLayer(function(layer)
        layer({ "n", "x" }, "<Left>", mc.prevCursor)
        layer({ "n", "x" }, "<Right>", mc.nextCursor)
        layer({ "n", "x" }, "<leader>kx", mc.deleteCursor)
        layer("n", "<Esc>", function()
          if not mc.cursorsEnabled() then mc.enableCursors() else mc.clearCursors() end
        end)
      end)
      local hl = vim.api.nvim_set_hl
      hl(0, "MultiCursorCursor", { fg = P.bg_deep, bg = P.peach })
      hl(0, "MultiCursorVisual", { link = "Visual" })
      hl(0, "MultiCursorSign", { fg = P.peach })
      hl(0, "MultiCursorMainSign", { fg = P.blush })
      hl(0, "MultiCursorMatchPreview", { link = "Search" })
      hl(0, "MultiCursorDisabledCursor", { fg = P.bg_deep, bg = P.surface })
      hl(0, "MultiCursorDisabledVisual", { link = "Visual" })
      hl(0, "MultiCursorDisabledSign", { fg = P.faint })
    end,
  },

  -- Illuminate (highlight other occurrences of word under cursor)
  {
    "RRethy/vim-illuminate",
    event = "BufReadPost",
    opts = {
      delay = 200,
      providers = Paper.enabled and { "lsp" } or nil,
      filetypes_denylist = { "neo-tree", "Trouble", "aerial", "toggleterm", "lazy", "mason" },
    },
    config = function(_, opts)
      require("illuminate").configure(opts)
    end,
  },

  -- Harpoon (bookmark files, jump with Ctrl+1-4)
  {
    "ThePrimeagen/harpoon",
    branch = "harpoon2",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local harpoon = require("harpoon")
      harpoon:setup()
    end,
  },

  -- Undotree (visual undo history)
  { "mbbill/undotree", cmd = "UndotreeToggle" },

  -- Fidget (LSP progress spinner — route through noice instead)
  {
    "j-hui/fidget.nvim",
    opts = {
      notification = { override_vim_notify = false },
    },
  },

  -- Diffview (full git diff/merge viewer)
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = { hooks = { diff_buf_win_enter = Paper.enabled and Paper.merge_label or nil } },
  },

  -- CodeCompanion — chat, inline edits and agents on the LOCAL models, through llama.cpp's router (127.0.0.1:8080,
  -- every chat model it serves, by its name:tag; the downloads are Hugging Face GGUFs). Chat, inline edits and commands
  -- all use the roles file's quick model (quick_model above — one line there swaps it; qwen3.5:4b measured best on the
  -- 4 GB GPU, 2026-10-14); the 14B was too slow here.
  -- pi runs as its CLI agent (:CodeCompanionCLI, <leader>cp) — agentic multi-file work on pi's own model (its settings:
  -- ~/.pi/agent). Edits come back as a diff to accept. Config in the v19 shape (`interactions`, `adapters.http`).
  {
    "olimorris/codecompanion.nvim",
    -- keys live here (not as global maps) so they only exist while the plugin is enabled
    keys = {
      { "<leader>cc", "<cmd>CodeCompanionActions<cr>", mode = { "n", "v" }, desc = "AI Actions (CodeCompanion)" },
      { "<leader>cC", "<cmd>CodeCompanionChat Toggle<cr>", mode = { "n", "v" }, desc = "AI Chat Toggle" },
      { "ga", "<cmd>CodeCompanionChat Add<cr>", mode = "v", desc = "Add selection to AI chat" },
      { "<leader>ci", "<cmd>CodeCompanion<cr>", mode = { "n", "v" }, desc = "AI Inline (CodeCompanion)" },
      { "<leader>cp", "<cmd>CodeCompanionCLI<cr>", mode = { "n", "v" }, desc = "AI agent: pi (CodeCompanion CLI)" },
    },
    cmd = { "CodeCompanion", "CodeCompanionChat", "CodeCompanionActions", "CodeCompanionCLI" },
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
    config = function()
      require("codecompanion").setup({
        adapters = {
          http = {
            -- the router speaks OpenAI's API on loopback and needs no key; CodeCompanion sends one anyway, and "none" is
            -- a literal to it (no variable has that name)
            llamacpp = function()
              return require("codecompanion.adapters").extend("openai_compatible", {
                name = "llamacpp",
                formatted_name = "llama.cpp",
                env = { url = "http://127.0.0.1:8080", api_key = "none" },
                -- the model list is the roles file's, never fetched: CodeCompanion fetches it SYNCHRONOUSLY (plenary
                -- curl, sync = true), and when the router is down or busy that froze the editor ~20 s, then threw an
                -- error from a callback its pcall cannot catch (2026-10-14: chat → :q → "it stopped working")
                schema = { model = { default = quick_model, choices = { quick_model, role_model("agent", quick_model) } } },
              })
            end,
          },
        },
        interactions = {
          chat = { adapter = { name = "llamacpp", model = quick_model } },
          inline = { adapter = { name = "llamacpp", model = quick_model } },
          cmd = { adapter = { name = "llamacpp", model = quick_model } },
          cli = {
            agent = "pi",
            agents = {
              pi = { cmd = "pi", args = {}, description = "pi — the local coding agent" },
            },
          },
          -- #symdeps in a chat: fox-symdeps' facts for what is under the cursor — a struct's layout (size, padding,
          -- cache-line straddles), or a function's fields read / written and its callers. Only where the plugin is.
          shared = vim.fn.isdirectory(vim.fn.expand("~/code/tick-trader-percore-workspace/tools/plugins/fox-symdeps.nvim")) == 1 and {
            editor_context = {
              symdeps = {
                path = "fox-symdeps.codecompanion",
                description = "fox-symdeps facts for the symbol under the cursor (struct layout · fields touched · callers)",
                opts = { contains_code = true },
              },
            },
          } or nil,
        },
        display = {
          chat = {
            window = {
              layout = "vertical", -- Vertical split for chat
              width = 0.4,
            },
          },
        },
      })
    end,
  },

  -- Copilot (inline ghost-text completions)
  {
    "zbirenbaum/copilot.lua",
    cmd = "Copilot",
    event = "VeryLazy",
    opts = {
      suggestion = {
        enabled = {{SHOW_WELCOME}},
        auto_trigger = {{SHOW_WELCOME}},
        debounce = 150,
        -- the keys (Ctrl+l accept, Ctrl+; word, Ctrl+' line, Ctrl+] / Ctrl+k cycle, Ctrl+j dismiss) are mapped once, below,
        -- for whichever engine shows a suggestion — Copilot or the local one (minuet)
        keymap = { accept = false, accept_word = false, accept_line = false, next = false, prev = false, dismiss = false },
      },
      panel = { enabled = false },
      -- its own rule (listed, normal buffers) AND a public repo (RepoVis, above the plugin list)
      should_attach = function(buf, name)
        return require("copilot.config.should_attach").default(buf, name) and RepoVis.engine(buf) == "copilot"
      end,
      filetypes = {
        ["*"] = {{SHOW_WELCOME}},
        ["AvanteInput"] = false,
        ["Avante"] = false,
        ["."] = false,
      },
    },
  },

  -- Local completion (minuet.nvim) — Copilot-style ghost text from a LOCAL model through llama.cpp's router, the model
  -- the router already keeps loaded for this (a second copy in another server would double the VRAM). The router's
  -- /v1/completions ignores `suffix` (measured 2026-10-14: it rambles), so the gap goes in the prompt with the model's
  -- own fill-in-the-middle tokens. The BASE coder model (fill-in-the-middle trained) fits the 4 GB GPU with room to spare; `:Minuet` can
  -- point it at 3b. On in every buffer whose repo is not public (RepoVis, above the plugin list), and everywhere
  -- after <leader>ta. One engine per buffer: the two never show at once.
  -- Measured 2026-10-13: these models don't reliably stop at the gap — given `return ` before the cursor and `}`
  -- after, they wrote `a + b;` and then repeated the `}` and invented new functions. Two settings stop that: `stop` at
  -- the first blank line (no run-on), and after_cursor_filter_length = 1 (minuet's default is 0 — OFF — for this
  -- provider; at 1 a suggestion never repeats what is already after the cursor: the `}`, a closing `)`).
  {
    "milanglacier/minuet-ai.nvim",
    event = "InsertEnter",
    config = function()
      require("minuet").setup({
        provider = "openai_fim_compatible",
        n_completions = 1,
        context_window = 1024,
        after_cursor_filter_length = 1,
        provider_options = {
          openai_fim_compatible = {
            api_key = "TERM", -- the router needs no key; minuet wants a set variable's name
            name = "llama.cpp",
            end_point = "http://127.0.0.1:8080/v1/completions",
            model = "qwen2.5-coder:1.5b-base",
            optional = { max_tokens = 64, top_p = 0.9, stop = { "\n\n" } },
            -- Qwen2.5-Coder's FIM tokens around the gap, and no `suffix` sent (minuet's documented llama.cpp form)
            template = {
              prompt = function(before, after, _)
                return "<|fim_prefix|>" .. before .. "<|fim_suffix|>" .. after .. "<|fim_middle|>"
              end,
              suffix = false,
            },
          },
        },
        virtualtext = { auto_trigger_ft = {}, keymap = {} }, -- keys: the shared dispatcher below
      })
    end,
  },

  -- Avante (Cursor-style AI panel) — DISABLED: relying on Copilot for inline suggestions instead.
  {
    "yetone/avante.nvim",
    enabled = false,
    -- keys live here (not as global maps) so they only exist while the plugin is enabled
    keys = {
      { "<leader>aa", "<cmd>AvanteAsk<cr>", mode = { "n", "v" }, desc = "Avante ask" },
      { "<leader>at", "<cmd>AvanteToggle<cr>", desc = "Avante toggle" },
      { "<leader>ac", "<cmd>AvanteChat<cr>", desc = "Avante chat" },
      { "<leader>ae", "<cmd>AvanteEdit<cr>", mode = "v", desc = "Avante edit (selection)" },
      { "<leader>ar", "<cmd>AvanteRefresh<cr>", desc = "Avante refresh" },
      { "<leader>aS", "<cmd>AvanteStop<cr>", desc = "Avante stop" },
    },
    event = "VeryLazy",
    version = false,
    build = "make",
    dependencies = {
      "nvim-treesitter/nvim-treesitter",
      "stevearc/dressing.nvim",
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      "zbirenbaum/copilot.lua",
    },
    opts = {
      provider = "llamacpp",
      providers = {
        llamacpp = {
          __inherited_from = "openai",
          api_key_name = "",
          endpoint = "http://127.0.0.1:8080/v1", -- llama.cpp's router (Avante is disabled; kept right for a re-enable)
          model = global_model,
        },
      },
      behaviour = {
        auto_suggestions = false,
        auto_set_keymaps = {{SHOW_WELCOME}},
        auto_add_current_file = false,
        auto_apply_diff_after_generation = {{SHOW_WELCOME}},
      },
      history = {
        max_tokens = 8192,
      },
      windows = {
        width = 30,
        sidebar_header = {
          rounded = {{SHOW_WELCOME}},
          include_model = {{SHOW_WELCOME}},
        },
      },
    },
  },
  { "MunifTanjim/nui.nvim" },

  -- mini.ai (enhanced text objects)
  {
    "echasnovski/mini.ai",
    event = "VeryLazy",
    opts = { n_lines = 500 },
  },

  -- Snacks (dashboard)
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      dashboard = {
        enabled = {{SHOW_WELCOME}},
        preset = {
          header = [[
 /\_/\
(˚ˎ 。7
 |、^ 〵
    じしˍ,)ノ]],
          keys = {
            { icon = " ", key = "f", desc = "Find File", action = ":Telescope find_files" },
            { icon = " ", key = "g", desc = "Find Text", action = ":Telescope live_grep" },
            { icon = " ", key = "r", desc = "Recent Files", action = ":Telescope oldfiles" },
            { icon = " ", key = "p", desc = "Projects", action = function() require("telescope").extensions.projects.projects({}) end },
            { icon = " ", key = "s", desc = "Restore Session", action = function() require("persistence").load() end },
            { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy" },
            { icon = " ", key = "q", desc = "Quit", action = ":qa" },
          },
        },
        -- Brand banner — per-letter multicolor, generated by welcome_banner.cpp
        -- from WELCOME_TEXT (cycles FoxBannerC1..4). The segments between the
        -- sentinels are re-spliced on every install; edit there, not here.
        sections = function(dashboard)
          if Paper.enabled then return Paper.notebook_sections(dashboard) end
          return {
          { section = "header", align = "center" },
          {
            text = {
              -- foxml:nvim-banner-begin
          { "█▀▀", hl = "FoxBannerC1" },
          { " " },
          { "█▀█", hl = "FoxBannerC2" },
          { " " },
          { "▀▄▀", hl = "FoxBannerC3" },
          { " " },
          { "  ", hl = "FoxBannerC4" },
          { " " },
          { "█▀█", hl = "FoxBannerC1" },
          { " " },
          { "▄▀▀", hl = "FoxBannerC2" },
          { "\n" },
          { "█▀ ", hl = "FoxBannerC1" },
          { " " },
          { "█ █", hl = "FoxBannerC2" },
          { " " },
          { " █ ", hl = "FoxBannerC3" },
          { " " },
          { "  ", hl = "FoxBannerC4" },
          { " " },
          { "█ █", hl = "FoxBannerC1" },
          { " " },
          { " ▀▄", hl = "FoxBannerC2" },
          { "\n" },
          { "▀  ", hl = "FoxBannerC1" },
          { " " },
          { "▀▀▀", hl = "FoxBannerC2" },
          { " " },
          { "▀ ▀", hl = "FoxBannerC3" },
          { " " },
          { "  ", hl = "FoxBannerC4" },
          { " " },
          { "▀▀▀", hl = "FoxBannerC1" },
          { " " },
          { "▀▀ ", hl = "FoxBannerC2" },
              -- foxml:nvim-banner-end
            },
            align = "center",
            padding = 1,
          },
          { section = "keys", gap = 1, padding = 1 },
          { section = "startup" },
          }
        end,
      },
      -- Toasts: a card whose border, icon and title carry the level colour (theme block: SnacksNotifier*).
      -- noice forwards errors and vim.notify here titled "Notification"; untitled ones show their level.
      notifier = {
        enabled = {{SHOW_WELCOME}},
        timeout = 4000,
        width = { min = 36, max = 0.4 },
        margin = { top = 1, right = 2, bottom = 1 },
        style = function(buf, notif, ctx)
          local untitled = notif.title == nil or notif.title == "" or notif.title == "Notification" or notif.title == "Notify"
          local label = untitled and ({ error = "Error", warn = "Warning", info = "Info", debug = "Debug", trace = "Trace" })[notif.level] or notif.title
          ctx.opts.title = { { " " .. vim.trim(notif.icon) .. "  " .. label .. " ", ctx.hl.title } }
          ctx.opts.title_pos = "left"
          -- noice repaints message text in its source group (ErrorMsg/WarningMsg); the border already says it
          ctx.opts.wo.winhighlight = ctx.opts.wo.winhighlight .. ",ErrorMsg:SnacksNotifierBody,WarningMsg:SnacksNotifierBody"
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(notif.msg, "\n"))
        end,
      },
      styles = {
        notification = { border = "rounded", wo = { wrap = {{SHOW_WELCOME}}, winblend = 0 } },
        notification_history = { border = "rounded", title = " Notifications ", title_pos = "center" },
      },
      indent = { enabled = false },
    },
  },

  -- Claude Code (AI terminal integration) — DISABLED: debloat, not in regular use.
  {
    "coder/claudecode.nvim",
    enabled = false,
    dependencies = { "folke/snacks.nvim" },
    event = "VeryLazy",
    keys = {
      { "<leader>Ct", "<cmd>ClaudeCode<cr>", desc = "Claude toggle" },
      { "<leader>Cs", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Claude send selection" },
    },
    opts = {
      terminal = {
        snacks_win_opts = {
          position = "right",
          width = 0.4,
          border = "rounded",
        },
      },
    },
  },

  -- Dropbar (breadcrumb navigation) — DISABLED: winbar reserved for the fox-symdeps size-chip.
  {
    "Bekaboo/dropbar.nvim",
    enabled = false,
    event = { "BufReadPost", "BufNewFile" },
    opts = {
      bar = {
        -- symbols only — drop the path/filename crumb (filename already lives in
        -- the bufferline tab + statusline; no need for a third copy up top)
        sources = function(buf, _)
          local sources = require("dropbar.sources")
          local utils = require("dropbar.utils")
          if vim.bo[buf].ft == "markdown" then
            return { sources.markdown }
          end
          if vim.bo[buf].buftype == "terminal" then
            return { sources.terminal }
          end
          return { utils.source.fallback({ sources.lsp, sources.treesitter }) }
        end,
      },
    },
  },

  -- Clangd extensions (inlay hints, AST, type hierarchy for C++)
  {
    "p00f/clangd_extensions.nvim",
    ft = { "c", "cpp" },
    opts = {
      inlay_hints = {
        inline = {{SHOW_WELCOME}},
        only_current_line = false,
        show_parameter_hints = {{SHOW_WELCOME}},
        parameter_hints_prefix = "← ",
        other_hints_prefix = "→ ",
        highlight = "Comment",
      },
      ast = {
        role_icons = {
          type = "",
          declaration = "",
          expression = "",
          specifier = "",
          statement = "",
          ["template argument"] = "",
        },
      },
    },
  },

  -- fox-symdeps.nvim — compiled-reality HUD for C++ (private repo Jennifer-214/fox-symdeps.nvim).
  -- <leader>dd float / <leader>dD panel: layout · Uses · Calls · cascade · false-sharing (s) · notes (n).
  -- HOME: lives in the private trader workspace (tools/plugins/), its own gitignored repo — see the
  -- plugin's DOCS/DECISIONS.md. `enabled` guards on the dir so this degrades gracefully if absent.
  {
    dir = vim.fn.expand("~/code/tick-trader-percore-workspace/tools/plugins/fox-symdeps.nvim"),
    enabled = function()
      return vim.fn.isdirectory(vim.fn.expand("~/code/tick-trader-percore-workspace/tools/plugins/fox-symdeps.nvim")) == 1
    end,
    name = "fox-symdeps",
    ft = { "c", "cpp" },
    -- the menu and the HUD from ANY buffer (her ask, 2026-10-21: "it would be nice to have everywhere"): lazy maps these
    -- two keys in every buffer and loads the plugin on the first press, then replays the key — setup maps them for
    -- real (globally). C/C++ files still load it on open; no other session pays for it until a key is pressed.
    keys = {
      { "<leader>dm", desc = "fox-symdeps: menu" },
      { "<leader>dd", desc = "fox-symdeps: HUD" },
    },
    opts = {
      palette = { header = P.peach, title = Paper.enabled and P.fg or P.blush, border = P.float_border,
                  badge = Paper.enabled and P.fg or P.warm, winblend = 0,
                  selection = P.symdeps.sel, sync = P.symdeps.sync, warn = P.symdeps.warn,
                  alarm = P.symdeps.alarm, ok = P.symdeps.ok, ground = P.bg },
      doc_dirs = { vim.fn.expand("~/code/tick-trader-percore-workspace") }, -- `n` also greps the private workspace docs
      -- Engine's canonical instantiation (FPN_Binary<64> — the production F). Sizeof probes on
      -- dependent spellings (`ExecutionCore<F>` via a variable hover) compile @ F=64, labeled in the HUD.
      template_args = { F = "64" },
      -- Explain cards (`e`) ask the AGENT, not the quick model (her call, 2026-10-18): on a 4 GB GPU the quick 4B runs on
      -- the CPU (~38 read / 5.6 write tok/s) while the agent reads ~138 and writes ~20 — faster, and better answers. The
      -- cost she accepted: the agent has one slot, so a card waits while pi answers, and it thinks before it answers.
      -- role_model follows the roles file, so a new agent model moves the cards too; nil keeps the plugin's own default.
      explain = { model = role_model("agent") },
    },
    config = function(_, opts)
      require("fox-symdeps").setup(opts)
      Paper.setup_symdeps()
      -- E.1.2.A: install the codified [TAG]_ grammar adapter → the tags lens + [DERIVED] gen/verify
      -- light up on tagged C++ units. pcall so an adapter hiccup can never break plugin load.
      pcall(function()
        require("fox-symdeps.tagadapter").install(require("fox-symdeps.tag_grammar_adapter"))
      end)
    end,
  },

  -- Friendly snippets (community snippet collection for LuaSnip)
  {
    "rafamadriz/friendly-snippets",
    config = function()
      require("luasnip.loaders.from_vscode").lazy_load()
    end,
  },

  -- Zen mode (distraction-free writing, great for LaTeX)
  {
    "folke/zen-mode.nvim",
    cmd = "ZenMode",
    opts = {
      window = {
        backdrop = 0.93,
        width = 100,
        options = { signcolumn = "no", number = false, relativenumber = false },
      },
    },
  },

  -- === Quality of Life ===

  -- Lazygit (full git TUI inside nvim)
  {
    "kdheepak/lazygit.nvim",
    cmd = { "LazyGit", "LazyGitConfig", "LazyGitCurrentFile" },
    dependencies = { "nvim-lua/plenary.nvim" },
  },

  -- Persistence (auto session save/restore)
  {
    "folke/persistence.nvim",
    event = "BufReadPre",
    opts = {},
  },

  -- Spectre (project-wide find and replace)
  {
    "nvim-pack/nvim-spectre",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = Paper.enabled and { lnum_for_results = true } or {},
    keys = {
      { "<leader>sr", function() require("spectre").toggle() end, desc = "Search & Replace (Spectre)" },
      { "<leader>sw", function() require("spectre").open_visual({ select_word = {{SHOW_WELCOME}} }) end, desc = "Search current word" },
      { "<leader>sw", function() require("spectre").open_visual() end, desc = "Search selection", mode = "v" },
    },
  },

  -- === Visual Polish ===

  -- Noice (floating cmdline, messages, search popup)
  {
    "folke/noice.nvim",
    event = "VeryLazy",
    dependencies = { "MunifTanjim/nui.nvim" },
    opts = {
      cmdline = {
        enabled = {{SHOW_WELCOME}},
        view = "cmdline_popup",
        format = {
          cmdline = { pattern = "^:", icon = " ", lang = "vim" },
          search_down = { kind = "search", pattern = "^/", icon = "  ", lang = "regex" },
          search_up = { kind = "search", pattern = "^%?", icon = "  ", lang = "regex" },
          filter = { pattern = "^:%s*!", icon = "$ ", lang = "bash" },
          lua = { pattern = { "^:%s*lua%s+", "^:%s*lua%s*=%s*", "^:%s*=%s*" }, icon = " ", lang = "lua" },
        },
      },
      messages = { enabled = {{SHOW_WELCOME}}, view = "mini", view_search = not Paper.enabled and "virtualtext" or false },
      popupmenu = { enabled = {{SHOW_WELCOME}}, backend = "nui" },
      lsp = {
        override = {
          ["vim.lsp.util.convert_input_to_markdown_lines"] = {{SHOW_WELCOME}},
          ["vim.lsp.util.stylize_markdown"] = {{SHOW_WELCOME}},
          ["cmp.entry.get_documentation"] = {{SHOW_WELCOME}},
        },
        hover = { enabled = {{SHOW_WELCOME}} },
        signature = { enabled = {{SHOW_WELCOME}} },
        progress = { enabled = false }, -- fidget handles this
      },
      presets = {
        bottom_search = false,
        command_palette = {{SHOW_WELCOME}},
        long_message_to_split = {{SHOW_WELCOME}},
        lsp_doc_border = {{SHOW_WELCOME}},
      },
    },
  },


  -- Colorizer (show hex colors inline — skip C/C++ where 0x constants aren't colors)
  {
    "NvChad/nvim-colorizer.lua",
    event = "BufReadPost",
    opts = {
      filetypes = { "*", "!c", "!cpp", "!h" },
      user_default_options = {
        RGB = {{SHOW_WELCOME}},
        RRGGBB = {{SHOW_WELCOME}},
        names = false,
        RRGGBBAA = {{SHOW_WELCOME}},
        css = {{SHOW_WELCOME}},
        css_fn = {{SHOW_WELCOME}},
        mode = "background",
        virtualtext = "  ",
      },
    },
  },

  -- Rainbow delimiters (colored nested brackets)
  {
    "HiPhish/rainbow-delimiters.nvim",
    event = "BufReadPost",
    config = function()
      local rd = require("rainbow-delimiters")
      require("rainbow-delimiters.setup").setup({
        strategy = { [""] = rd.strategy["global"] },
        query = { [""] = "rainbow-delimiters" },
        highlight = {
          "RainbowDelimiterPeach",
          "RainbowDelimiterPink",
          "RainbowDelimiterMint",
          "RainbowDelimiterYellow",
          "RainbowDelimiterCyan",
          "RainbowDelimiterRed",
        },
      })
    end,
  },

  -- Colorful window separator (highlight active window border)
  {
    "nvim-zh/colorful-winsep.nvim",
    event = "WinNew",
    opts = {
      highlight = P.yellow_br,
      border = "rounded",
    },
  },

  -- Scrollbar (diagnostics, search, git marks)
  {
    "petertriho/nvim-scrollbar",
    event = "BufReadPost",
    opts = {
      handle = {
        color = P.peach,
        highlight = "ScrollbarHandle",
      },
      marks = {
        Search = { color = P.peach },
        Error = { color = P.red },
        Warn = { color = P.yellow },
        Info = { color = P.cyan },
        Hint = { color = P.green },
        Misc = { color = P.pink },
        GitAdd = { color = P.green },
        GitChange = { color = P.yellow },
        GitDelete = { color = P.red },
      },
      excluded_filetypes = { "neo-tree", "dashboard", "lazy", "mason", "notify" },
    },
    config = function(_, opts)
      require("scrollbar").setup(opts)
      require("scrollbar.handlers.gitsigns").setup()
      require("scrollbar.handlers.search").setup()
    end,
    dependencies = { "lewis6991/gitsigns.nvim", "kevinhwang91/nvim-hlslens" },
  },

  -- hlslens (search result count/index, used by scrollbar)
  {
    "kevinhwang91/nvim-hlslens",
    event = "BufReadPost",
    opts = {
      calm_down = {{SHOW_WELCOME}}, nearest_only = {{SHOW_WELCOME}},
      override_lens = Paper.enabled and Paper.search_lens or nil,
    },
  },

}

-- lazy.nvim setup
require("lazy").setup(plugins, {
  rocks = { enabled = false },
})

-- setup optional
vim.opt.fillchars:append({ eob = " ", vert = " " })

-- Popup menu transparency only (winblend left at 0 so splits stay solid)
vim.opt.pumblend = 15

-- ═══════════════════════════════════════════════════════════════
-- FoxML custom colorscheme (no external theme dependency)
-- ═══════════════════════════════════════════════════════════════
local function apply_foxml_theme()
  vim.o.background = "{{THEME_TYPE}}"
  vim.g.colors_name = "foxml"

  local hl = function(name, opts) vim.api.nvim_set_hl(0, name, opts) end

  -- ── Terminal colors (16 ANSI) ──
  vim.g.terminal_color_0  = P.bg_deep
  vim.g.terminal_color_1  = P.red
  vim.g.terminal_color_2  = P.green
  vim.g.terminal_color_3  = P.yellow
  vim.g.terminal_color_4  = P.blue
  vim.g.terminal_color_5  = P.pink
  vim.g.terminal_color_6  = P.cyan
  vim.g.terminal_color_7  = P.fg
  vim.g.terminal_color_8  = P.surface
  vim.g.terminal_color_9  = P.red_br
  vim.g.terminal_color_10 = P.green_br
  vim.g.terminal_color_11 = P.yellow_br
  vim.g.terminal_color_12 = P.blue_br
  vim.g.terminal_color_13 = P.fg_pastel
  vim.g.terminal_color_14 = P.cyan_br
  vim.g.terminal_color_15 = P.white

  -- ── Editor UI ──
  hl("Normal",        { fg = P.fg, bg = P.none })
  hl("NormalSidebar", { fg = P.fg, bg = P.bg_deep })
  hl("NormalNC",     { fg = P.fg, bg = P.none })
  hl("NormalFloat",  { fg = P.fg, bg = P.float_bg })
  hl("FloatBorder",  { fg = P.float_border, bg = P.none })
  hl("FloatTitle",   { fg = Paper.enabled and P.fg or P.peach, bg = P.none, bold = {{SHOW_WELCOME}} })
  hl("CursorLine",  { bg = P.list_sel })  -- Paper carries the existing pink list selection across the cursor's line.
  hl("CursorColumn", { bg = P.bg_hl })
  hl("ColorColumn",  { bg = P.bg_hl })
  hl("Visual",       { bg = P.sel })
  hl("VisualNOS",    { bg = P.sel })
  hl("LineNr",       { fg = P.faint })
  hl("CursorLineNr", { fg = Paper.enabled and P.bookmark or P.peach, bold = {{SHOW_WELCOME}} })
  hl("SignColumn",   { fg = P.faint, bg = P.none })
  if Paper.enabled then hl("LspInlayHint", { fg = P.comment, bg = P.none, italic = false }) end
  hl("EndOfBuffer",  { fg = P.bg })
  hl("VertSplit",    { fg = P.yellow_br, bg = P.none })
  hl("WinSeparator", { fg = P.yellow_br, bg = P.none })
  hl("Pmenu",        { fg = P.fg, bg = P.float_bg })
  hl("PmenuSel",     { fg = Paper.enabled and P.fg or nil, bg = P.menu_sel })
  hl("PmenuSbar",    { bg = P.bg_hl })
  hl("PmenuThumb",   { bg = P.comment })
  hl("WildMenu",     { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("StatusLine",   { fg = P.warm, bg = P.none })
  hl("StatusLineNC", { fg = P.faint, bg = P.none })
  hl("TabLine",      { fg = P.comment, bg = P.bg_deep })
  hl("TabLineSel",   { fg = P.peach, bg = P.bg_hl, bold = {{SHOW_WELCOME}} })
  hl("TabLineFill",  { bg = P.bg_deep })
  hl("WinBar",       { fg = P.comment, bg = P.none })
  hl("WinBarNC",     { fg = P.faint, bg = P.none })
  hl("Title",        { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("Directory",    { fg = P.cyan })
  hl("Question",     { fg = P.green })
  hl("SpecialKey",   { fg = P.faint })
  hl("NonText",      { fg = P.faint })
  if Paper.enabled then hl("Whitespace", { fg = P.faint }) end
  hl("Conceal",      { fg = P.comment })
  hl("Cursor",       { fg = P.bg, bg = P.fg })
  hl("lCursor",      { fg = P.bg, bg = P.fg })
  hl("CursorIM",     { fg = P.bg, bg = P.fg })

  -- ── Search & Match ──
  hl("Search",       { fg = P.search.fg, bg = P.search.bg })
  hl("IncSearch",    { fg = P.search.inc_fg, bg = P.search.inc_bg })
  hl("CurSearch",    { fg = P.search.cur_fg, bg = P.search.cur_bg, bold = {{SHOW_WELCOME}} })
  if Paper.enabled then
    hl("Search", { bg = P.none, underline = true, sp = P.comment })
    hl("IncSearch", { fg = P.fg, bg = P.sel, bold = true })
    hl("CurSearch", { fg = P.fg, bg = P.sel, bold = true })
  end
  hl("Substitute",   { fg = P.bg, bg = P.red })
  hl("MatchParen",   { fg = Paper.enabled and P.bookmark or P.pink, bold = not Paper.enabled and {{SHOW_WELCOME}}, underline = {{SHOW_WELCOME}} })
  if Paper.enabled then
    hl("Substitute", { fg = P.fg, bg = P.sel, bold = true })
    hl("MatchParen", { fg = P.fg, bg = P.sel, bold = true })
  end

  -- ── Fold ──
  hl("Folded",       { fg = P.comment, bg = P.bg_hl })
  hl("FoldColumn",   { fg = P.faint, bg = P.none })
  hl("FoxPaperBookmark", { fg = P.bookmark })
  hl("FoxPaperYank", { fg = P.fg, bg = P.sel })
  hl("FoxPaperLastEdit", { fg = P.comment })
  hl("FoxPaperInvisible", { fg = P.warn, bg = P.sel, underline = true })
  if Paper.enabled then
    hl("LspSignatureActiveParameter", { fg = P.fg, bg = P.sel, bold = true })
    hl("NoiceLspSignatureActiveParameter", { link = "LspSignatureActiveParameter" })
  end
  hl("FoxPaperFoldArrow", { fg = P.bookmark, bg = P.bg_hl })
  hl("FoxPaperFoldText", { fg = Paper.enabled and P.syn.comment or P.comment, bg = P.bg_hl })
  hl("FoxPaperFoldCount", { fg = P.faint, bg = P.bg_hl })

  -- ── Messages ──
  hl("MsgArea",      { fg = P.warm, bg = P.bg_deep })
  hl("WarningMsg",   { fg = P.warn, bold = {{SHOW_WELCOME}} })
  hl("ErrorMsg",     { fg = P.pen, bold = {{SHOW_WELCOME}} })
  hl("ModeMsg",      { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("MoreMsg",      { fg = P.green })

  -- ── Built-in syntax groups ──
  hl("Comment",      { fg = P.syn.comment, italic = {{SHOW_WELCOME}} })
  hl("Constant",     { fg = P.peach })
  hl("String",       { fg = P.syn.string })
  hl("Character",    { fg = P.syn.string })
  hl("Number",       { fg = P.syn.number, bg = Paper.enabled and P.sel or nil, bold = {{SHOW_WELCOME}} })
  hl("Boolean",      { fg = Paper.enabled and P.syn.number or P.peach, bg = Paper.enabled and P.sel or nil, bold = {{SHOW_WELCOME}} })
  hl("Float",        { fg = P.syn.number, bg = Paper.enabled and P.sel or nil, bold = {{SHOW_WELCOME}} })
  hl("Identifier",   { fg = P.syn.var })
  hl("Function",     { fg = P.peach })
  hl("Statement",    { fg = P.pink, bold = {{NVIM_KW_BOLD}} })
  hl("Conditional",  { fg = P.pink, bold = {{NVIM_KW_BOLD}} })
  hl("Repeat",       { fg = P.pink, bold = {{NVIM_KW_BOLD}} })
  hl("Label",        { fg = P.pink })
  hl("Operator",     { fg = P.pink })
  hl("Keyword",      { fg = P.pink, bold = {{NVIM_KW_BOLD}} })
  hl("Exception",    { fg = P.pink })
  hl("PreProc",      { fg = P.cyan })
  hl("Include",      { fg = P.cyan })
  hl("Define",       { fg = P.pink })
  hl("Macro",        { fg = P.pink })
  hl("PreCondit",    { fg = P.cyan })
  hl("Type",         { fg = P.peach })
  hl("StorageClass", { fg = P.pink })
  hl("Structure",    { fg = P.peach })
  hl("Typedef",      { fg = P.peach })
  hl("Special",      { fg = P.peach })
  hl("SpecialChar",  { fg = P.green })
  hl("Tag",          { fg = P.peach })
  hl("Delimiter",    { fg = P.peach })
  hl("SpecialComment", { fg = P.comment, bold = {{SHOW_WELCOME}} })
  hl("Debug",        { fg = P.red })
  hl("Underlined",   { underline = {{SHOW_WELCOME}} })
  hl("Bold",         { bold = {{SHOW_WELCOME}} })
  hl("Italic",       { italic = {{SHOW_WELCOME}} })
  hl("Ignore",       {})
  hl("Error",        { fg = P.red })
  hl("Todo",         { fg = Paper.enabled and P.fg or P.bg, bg = Paper.enabled and P.sel or P.yellow, bold = {{SHOW_WELCOME}} })

  -- ── Diagnostics ──
  hl("DiagnosticError",          { fg = P.pen })
  hl("DiagnosticWarn",           { fg = P.warn })
  hl("DiagnosticInfo",           { fg = P.peach })
  hl("DiagnosticHint",           { fg = P.green })
  hl("DiagnosticOk",             { fg = P.green })
  if Paper.enabled then
    -- Fade only server-tagged unnecessary code; leave severity marks and text intact.
    hl("DiagnosticUnnecessary", { fg = P.comment, italic = false })
    hl("@lsp.mod.unused", { link = "DiagnosticUnnecessary" })
  end
  hl("DiagnosticUnderlineError", { undercurl = {{SHOW_WELCOME}}, sp = P.pen })
  hl("DiagnosticUnderlineWarn",  { undercurl = {{NVIM_WARN_CURL}}, underdashed = {{NVIM_WARN_DASH}}, sp = P.warn })  -- Paper: dashed, so it never reads as the red squiggle
  hl("DiagnosticUnderlineInfo",  { undercurl = {{SHOW_WELCOME}}, sp = P.peach })
  hl("DiagnosticUnderlineHint",  { undercurl = {{SHOW_WELCOME}}, sp = P.green })
  hl("DiagnosticUnderlineOk",    { undercurl = {{SHOW_WELCOME}}, sp = P.green })
  hl("DiagnosticVirtualTextError", { fg = P.pen, bg = P.diff_del, bold = {{SHOW_WELCOME}} })
  hl("DiagnosticVirtualTextWarn",  { fg = P.warn, bg = P.diff_chg })
  hl("DiagnosticVirtualTextInfo",  { fg = P.peach })
  hl("DiagnosticVirtualTextHint",  { fg = P.green })
  hl("DiagnosticSignError",       { fg = P.pen })
  hl("DiagnosticSignWarn",        { fg = P.warn })
  hl("DiagnosticSignInfo",        { fg = P.peach })
  hl("DiagnosticSignHint",        { fg = P.green })
  hl("DiagnosticLineNrError",    { fg = P.pen, bold = {{SHOW_WELCOME}} })
  hl("DiagnosticLineNrWarn",     { fg = P.warn, bold = {{SHOW_WELCOME}} })
  hl("DiagnosticLineNrInfo",     { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("DiagnosticLineNrHint",     { fg = P.green, bold = {{SHOW_WELCOME}} })
  hl("DiagnosticLineError",     { bg = P.diag_err_bg })
  hl("DiagnosticLineWarn",      { bg = P.diag_warn_bg })
  hl("DiagnosticLineInfo",      { bg = P.bg_hl })
  hl("DiagnosticLineHint",      { bg = P.bg_hl })

  -- ── Treesitter ──
  hl("@variable",            { fg = P.syn.var })
  hl("@variable.builtin",    { fg = P.pink })
  hl("@variable.parameter",  { fg = P.syn.param })
  hl("@variable.member",     { fg = P.syn.member, bold = {{NVIM_MEMBER_BOLD}} })
  hl("@constant",            { fg = P.syn.number })
  hl("@constant.builtin",    { fg = P.syn.number, bold = {{SHOW_WELCOME}} })
  hl("@constant.macro",      { fg = P.syn.number })
  hl("@module",              { fg = P.pink })
  hl("@string",              { fg = P.syn.string })
  hl("@string.escape",       { fg = P.cyan })
  hl("@string.regex",        { fg = P.cyan })
  hl("@string.special",      { fg = P.cyan })
  hl("@character",           { fg = P.syn.string })
  hl("@number",              { fg = P.syn.number, bg = Paper.enabled and P.sel or nil, bold = {{SHOW_WELCOME}} })
  hl("@number.float",        { fg = P.syn.number, bg = Paper.enabled and P.sel or nil, bold = {{SHOW_WELCOME}} })
  hl("@number.hex",          { fg = Paper.enabled and P.syn.number or P.yellow, bg = Paper.enabled and P.sel or nil, bold = {{SHOW_WELCOME}} })
  hl("@boolean",             { fg = Paper.enabled and P.syn.number or P.peach, bg = Paper.enabled and P.sel or nil, bold = {{SHOW_WELCOME}} })
  hl("@type",                { fg = P.syn.type })
  hl("@type.builtin",        { fg = P.syn.type })
  hl("@type.definition",     { fg = P.syn.type })
  hl("@type.qualifier",      { fg = P.pink })
  hl("@attribute",           { fg = P.peach })
  hl("@property",            { fg = P.syn.member, bold = {{NVIM_MEMBER_BOLD}} })
  hl("@function",            { fg = P.fn_def, bg = Paper.enabled and P.sel or nil, bold = {{NVIM_FN_DEF_BOLD}} })
  hl("@function.call",       { fg = P.syn.call })
  hl("@function.builtin",    { fg = P.syn.call })
  hl("@function.macro",      { fg = P.pink })
  hl("@function.method",     { fg = P.fn_def, bg = Paper.enabled and P.sel or nil, bold = {{NVIM_FN_DEF_BOLD}} })
  hl("@function.method.call", { fg = P.syn.call })
  hl("@constructor",         { fg = P.peach })
  hl("@operator",            { fg = P.syn.operator })
  hl("@keyword",             { fg = P.pink, bold = {{NVIM_KW_BOLD}} })
  hl("@keyword.function",    { fg = P.pink, bold = {{NVIM_KW_BOLD}} })
  hl("@keyword.operator",    { fg = P.pink })
  hl("@keyword.return",      { fg = P.syn.ret, bold = {{NVIM_KW_BOLD}} })
  hl("@keyword.import",      { fg = P.cyan })
  hl("@keyword.conditional", { fg = P.pink, bold = {{NVIM_KW_BOLD}} })
  hl("@keyword.repeat",      { fg = P.pink, bold = {{NVIM_KW_BOLD}} })
  hl("@keyword.exception",   { fg = P.pink })
  hl("@punctuation",         { fg = P.fg })
  hl("@punctuation.bracket",  { fg = P.sand })
  hl("@punctuation.delimiter", { fg = P.peach })
  hl("@punctuation.special",  { fg = P.pink })
  hl("@comment",             { fg = P.syn.comment, italic = {{SHOW_WELCOME}} })
  hl("@comment.todo",        { fg = Paper.enabled and P.fg or P.bg, bg = Paper.enabled and P.sel or P.yellow, bold = {{SHOW_WELCOME}} })
  hl("@comment.note",        { fg = Paper.enabled and P.fg or P.bg, bg = Paper.enabled and P.sel or P.green, bold = {{SHOW_WELCOME}} })
  hl("@comment.warning",     { fg = P.bg, bg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("@comment.error",       { fg = P.bg, bg = P.red, bold = {{SHOW_WELCOME}} })
  hl("@tag",                 { fg = P.peach })
  hl("@tag.attribute",       { fg = P.pink })
  hl("@tag.delimiter",       { fg = P.fg })
  hl("@markup.heading",      { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("@markup.italic",       { italic = {{SHOW_WELCOME}} })
  hl("@markup.strong",       { bold = {{SHOW_WELCOME}} })
  hl("@markup.strikethrough", { strikethrough = {{SHOW_WELCOME}} })
  hl("@markup.underline",    { underline = {{SHOW_WELCOME}} })
  hl("@markup.link",         { fg = P.cyan, underline = {{SHOW_WELCOME}} })
  hl("@markup.link.url",     { fg = P.cyan, underline = {{SHOW_WELCOME}} })
  hl("@markup.raw",          { fg = P.green })
  hl("@markup.list",         { fg = P.pink })

  if Paper.enabled then
    hl("FoxPaperQuoteOpen", { fg = P.fg, bg = P.sel })
    hl("FoxPaperQuoteRule", { fg = P.faint })
    hl("FoxPaperFootnote", { fg = P.fg, bg = P.sel })
    hl("FoxPaperSlip", { fg = P.fg, bg = P.bg })
    hl("FoxPaperSlipBorder", { fg = P.float_border, bg = P.bg })
    hl("FoxPaperSlipTitle", { fg = P.fg, bg = P.sel, bold = true })
    hl("FoxPaperSlipOld", { fg = P.fg_dim, bg = P.bg })
    hl("FoxPaperSlipInput", { fg = P.fg, bg = P.sel })
    hl("@markup.quote.markdown", { fg = P.fg_dim, italic = true })
    hl("@markup.raw.markdown_inline", { fg = P.fg, bg = P.sel })
    hl("FoxPaperMarkdownTitle", { fg = P.fg, bold = true, underline = true, sp = P.search.cur_bg })
    hl("@markup.heading.markdown", { fg = P.fg, bold = true })
    for level = 1, 6 do
      hl("@markup.heading." .. level .. ".markdown", { fg = P.fg, bold = true })
      hl("markdownH" .. level, { fg = P.fg, bold = true })
    end
    hl("markdownHeadingDelimiter", { fg = P.faint })
    hl("@markup.list.checked.markdown", { fg = P.bookmark })
    hl("@markup.list.unchecked.markdown", { fg = P.faint })
    hl("@markup.list.checked.text.markdown", { fg = P.comment })
    hl("@markup.link.markdown_inline", { fg = P.comment })
    hl("@markup.link.label.markdown_inline", { fg = P.fg, underline = true, sp = P.search.cur_bg })
    hl("@markup.link.url.markdown_inline", { fg = P.comment })
    hl("markdownLinkText", { fg = P.fg, underline = true, sp = P.search.cur_bg })
    hl("markdownUrl", { fg = P.comment })
  end

  -- ── LSP semantic tokens ──
  hl("@lsp.type.class",         { fg = P.syn.type })
  hl("@lsp.type.struct",        { fg = P.syn.type })
  hl("@lsp.type.enum",          { fg = P.syn.type })
  hl("@lsp.type.enumMember",    { fg = P.cyan })
  hl("@lsp.type.interface",     { fg = P.syn.type })
  hl("@lsp.type.function",      { fg = P.syn.call })
  hl("@lsp.type.method",        { fg = P.syn.call })
  hl("@lsp.type.macro",         { fg = P.pink })
  hl("@lsp.type.decorator",     { fg = P.pink })
  hl("@lsp.type.variable",      { fg = P.syn.var })
  hl("@lsp.type.parameter",     { fg = Paper.enabled and P.syn.param or P.peach })
  hl("@lsp.type.property",      { link = "@property" })
  hl("@lsp.type.property.c",    { link = "@property" })
  hl("@lsp.type.property.cpp",  { link = "@property" })
  hl("@lsp.type.member",        { link = "@variable.member" })
  hl("@lsp.type.member.c",      { link = "@variable.member" })
  hl("@lsp.type.member.cpp",    { link = "@variable.member" })
  hl("@lsp.type.namespace",     { fg = P.pink })
  hl("@lsp.type.keyword",       { fg = P.pink, bold = {{NVIM_KW_BOLD}} })
  hl("@lsp.type.type",          { fg = P.syn.type })
  hl("@lsp.type.typeParameter", { fg = P.syn.type })
  hl("@lsp.type.comment",       { fg = P.syn.comment, italic = {{SHOW_WELCOME}} })
  hl("@lsp.mod.deprecated",     { strikethrough = {{SHOW_WELCOME}} })
  hl("@lsp.mod.readonly",       { bold = {{NVIM_READONLY_BOLD}} })
  -- clangd tags the name in a signature declaration/definition; keep it on the @function look, not the call look
  hl("@lsp.typemod.function.declaration",   { link = "@function" })
  hl("@lsp.typemod.function.definition",    { link = "@function" })
  hl("@lsp.typemod.method.declaration",     { link = "@function.method" })
  hl("@lsp.typemod.method.definition",      { link = "@function.method" })
  hl("@lsp.typemod.function.defaultLibrary", { fg = P.peach })
  hl("@lsp.typemod.variable.defaultLibrary", { fg = P.pink })
  hl("@lsp.typemod.variable.member",         { link = "@variable.member" })
  hl("@lsp.typemod.variable.member.c",       { link = "@variable.member" })
  hl("@lsp.typemod.variable.member.cpp",     { link = "@variable.member" })

  -- ── Diff & Spell ──
  hl("DiffAdd",      { bg = P.diff_add })
  hl("DiffChange",   { bg = P.diff_chg })
  hl("DiffDelete",   { bg = P.diff_del })
  hl("DiffText",     { bg = P.diff_txt })
  if Paper.enabled then hl("DiffText", { fg = P.fg, bg = P.sel, bold = true }) end
  hl("SpellBad",     { undercurl = {{SHOW_WELCOME}}, sp = P.red })
  hl("SpellCap",     { undercurl = {{SHOW_WELCOME}}, sp = P.yellow })
  hl("SpellRare",    { undercurl = {{SHOW_WELCOME}}, sp = P.cyan })
  hl("SpellLocal",   { undercurl = {{SHOW_WELCOME}}, sp = P.green })
  if Paper.enabled then
    for _, group in ipairs({"SpellBad", "SpellCap", "SpellRare", "SpellLocal"}) do
      hl(group, { underdotted = true, sp = P.search.cur_bg })
    end
  end

  -- ── Plugin highlights ──
  if Paper.enabled then
    hl("SpectreHeader", { fg = P.comment })
    hl("SpectreBody", { fg = P.fg })
    hl("SpectreFile", { fg = P.fg, bold = true })
    hl("SpectreDir", { fg = P.fg_dim })
    hl("SpectreBorder", { fg = P.faint })
    hl("SpectreSearch", { fg = P.fg_dim, bg = P.bg_alt, strikethrough = true })
    hl("SpectreReplace", { fg = P.fg, bg = P.sel, bold = true })
    hl("QuickFixLine", { fg = P.fg, bg = P.sel })
    hl("qfFileName", { fg = P.fg, bold = true })
    hl("qfLineNr", { fg = P.fg_dim })
    hl("qfSeparator", { fg = P.faint })
    hl("FoxPaperMergeCurrent", { fg = P.fg, bg = P.sel, bold = true })
    hl("FoxPaperMergeOther", { fg = P.fg, bg = P.bg_alt, bold = true })
  end

  -- CmpBorder
  hl("CmpBorder", { fg = P.float_border, bg = P.none })

  -- Telescope
  hl("TelescopeBorder",        { fg = P.float_border })
  hl("TelescopePromptBorder",  { fg = P.pink })
  hl("TelescopeResultsBorder", { fg = P.float_border })
  hl("TelescopePreviewBorder", { fg = P.green })
  hl("TelescopePromptTitle",   { fg = P.bg, bg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("TelescopeResultsTitle",  { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("TelescopePreviewTitle",  { fg = P.bg, bg = P.green, bold = {{SHOW_WELCOME}} })

  if Paper.enabled then
    hl("TelescopeSelection", { fg = P.fg, bg = P.sel })
    hl("TelescopeSelectionCaret", { fg = P.bookmark, bg = P.sel })
    hl("TelescopeMatching", { fg = P.fg, underline = true, sp = P.comment })
    hl("TelescopeResultsComment", { fg = P.comment })
    hl("TelescopeResultsLineNr", { fg = P.comment })
    for _, section in ipairs({"Prompt", "Results", "Preview"}) do
      hl("Telescope" .. section .. "Border", { fg = P.float_border })
      hl("Telescope" .. section .. "Title", { fg = P.fg, bg = P.sel })
    end
    -- Filetype overrides keep JSON keys and Python decorators distinct from prose.
    hl("@property.json", { fg = P.syn.member, bold = true })
    hl("@string.json", { fg = P.syn.string })
    hl("@constant.builtin.json", { fg = P.syn.param, italic = false })
    hl("@punctuation.bracket.json", { fg = P.syn.operator })
    hl("@punctuation.delimiter.json", { fg = P.comment })
    hl("@attribute.python", { fg = P.fg, underline = true, sp = P.comment })
    hl("@attribute.builtin.python", { link = "@attribute.python" })
    hl("@string.documentation.python", { fg = P.syn.comment, italic = true })
    hl("@lsp.type.decorator.python", { link = "@attribute.python" })
  end

  -- Snacks dashboard
  hl("FoxNotebookRule", { fg = P.float_border })
  hl("FoxNotebookText", { fg = P.fg })
  hl("FoxNotebookNote", { fg = P.comment, italic = true })
  hl("FoxNotebookTitle", { fg = P.fg, bg = P.sel, bold = true, italic = true })
  hl("FoxNotebookKey", { fg = P.bookmark, bold = true })
  hl("SnacksDashboardHeader",  { fg = P.pink, bold = {{SHOW_WELCOME}} })
  -- Banner brand cycle (clay·wheat·mauve·sage) — mirrors welcome.zsh ${c1..c4}
  -- and hyprlock's pango spans; the one WELCOME_TEXT source colors all three.
  hl("FoxBannerC1",            { fg = P.banner[1], bold = {{SHOW_WELCOME}} })
  hl("FoxBannerC2",            { fg = P.banner[2], bold = {{SHOW_WELCOME}} })
  hl("FoxBannerC3",            { fg = P.banner[3], bold = {{SHOW_WELCOME}} })
  hl("FoxBannerC4",            { fg = P.banner[4], bold = {{SHOW_WELCOME}} })
  hl("SnacksDashboardKey",     { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("SnacksDashboardDesc",    { fg = P.fg })
  hl("SnacksDashboardIcon",    { fg = P.green })
  hl("SnacksDashboardFooter",  { fg = P.comment, italic = {{SHOW_WELCOME}} })

  -- Git signs
  hl("GitSignsAdd",    { fg = P.green })
  hl("GitSignsChange", { fg = P.yellow })
  hl("GitSignsDelete", { fg = P.red })
  if Paper.enabled then
    for kind, color in pairs({ Add = P.comment, Change = P.bookmark, Delete = P.git_del,
        Topdelete = P.git_del, Changedelete = P.bookmark, Untracked = P.faint }) do
      hl("GitSigns" .. kind, { fg = color, bg = P.none })
      hl("GitSigns" .. kind .. "Cul", { fg = color, bg = P.none })
      hl("GitSignsStaged" .. kind, { fg = P.faint, bg = P.none })
      hl("GitSignsStaged" .. kind .. "Cul", { fg = P.faint, bg = P.none })
    end
  end

  -- Flash.nvim
  hl("FlashLabel",    { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("FlashMatch",    { fg = P.fg, bg = P.bg_hl })
  hl("FlashCurrent",  { fg = P.bg, bg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("FlashBackdrop", { fg = P.faint })
  if Paper.enabled then
    hl("FlashLabel", { fg = P.fg, bg = P.sel, bold = true })
    hl("FlashCurrent", { fg = P.fg, bg = P.sel, underline = true, sp = P.search.cur_bg })
  end

  -- Trouble.nvim
  hl("TroubleNormal",   { bg = P.bg_deep })
  hl("TroubleNormalNC", { bg = P.bg_deep })
  hl("TroubleText",     { fg = P.fg })
  hl("TroubleCount",    { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("TroubleFile",     { fg = P.peach })
  hl("TroubleFoldIcon", { fg = P.pink })
  hl("TroubleLocation", { fg = P.comment })

  -- Which-key
  hl("WhichKey",          { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("WhichKeyGroup",     { fg = P.pink })
  hl("WhichKeyDesc",      { fg = P.fg })
  hl("WhichKeySeparator", { fg = P.faint })
  hl("WhichKeyNormal",    { bg = P.none })
  hl("WhichKeyFloat",     { bg = P.none })
  hl("WhichKeyBorder",    { fg = P.float_border, bg = P.none })
  hl("WhichKeyTitle",     { fg = P.peach, bg = P.none })
  hl("WhichKeyValue",     { fg = P.comment })

  -- Indent blankline
  hl("IblIndent", { fg = P.bg_hl })
  hl("IblScope",  { fg = Paper.enabled and P.bookmark or P.ibl_scope })

  -- Rainbow indent guides (muted versions of rainbow delimiter colors)
  hl("RainbowIndent1", { fg = P.indent[1] })
  hl("RainbowIndent2", { fg = P.indent[2] })
  hl("RainbowIndent3", { fg = P.indent[3] })
  hl("RainbowIndent4", { fg = P.indent[4] })
  hl("RainbowIndent5", { fg = P.indent[5] })
  hl("RainbowIndent6", { fg = P.indent[6] })

  -- Neo-tree
  hl("NeoTreeNormal",        { bg = P.none })
  hl("NeoTreeNormalNC",      { bg = P.none })
  hl("NeoTreeEndOfBuffer",   { fg = P.bg_deep, bg = P.none })
  hl("NeoTreeDirectoryName", { fg = P.peach })
  hl("NeoTreeDirectoryIcon", { fg = P.peach })
  if Paper.enabled then hl("FoxPaperOpenFolder", { fg = P.fg, bg = P.sel }) end
  hl("NeoTreeRootName",      { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("NeoTreeFileName",      { fg = P.fg })
  hl("NeoTreeFileIcon",      { fg = P.fg })
  hl("NeoTreeGitAdded",      { fg = "#{{GREEN}}" })
  hl("NeoTreeGitModified",   { fg = P.git_mod })
  hl("NeoTreeGitDeleted",    { fg = P.git_del })
  hl("NeoTreeGitUntracked",  { fg = P.git_del })
  hl("NeoTreeGitConflict",   { fg = P.red, bold = {{SHOW_WELCOME}} })
  hl("NeoTreeIndentMarker",  { fg = P.bg_hl })
  hl("NeoTreeWinSeparator",  { fg = P.bg_deep, bg = P.none })
  hl("NeoTreeCursorLine",    { bg = P.list_sel })
  hl("NeoTreeTitleBar",      { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("NeoTreeFloatBorder",   { fg = P.float_border })
  hl("NeoTreeFloatTitle",    { fg = P.peach, bold = {{SHOW_WELCOME}} })

  -- DAP UI
  hl("DapUIScope",                   { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("DapUIType",                    { fg = P.pink })
  hl("DapUIValue",                   { fg = P.green })
  hl("DapUIVariable",                { fg = P.fg })
  hl("DapUIThread",                  { fg = P.green })
  hl("DapUIStoppedThread",           { fg = P.peach })
  hl("DapUIFrameName",               { fg = P.fg })
  hl("DapUISource",                  { fg = P.pink })
  hl("DapUIBreakpointsPath",         { fg = P.peach })
  hl("DapUIBreakpointsInfo",         { fg = P.cyan })
  hl("DapUIBreakpointsCurrentLine",  { fg = P.green, bold = {{SHOW_WELCOME}} })
  hl("DapUIBreakpointsLine",         { fg = P.peach })
  hl("DapUIBreakpointsDisabledLine", { fg = P.faint })
  hl("DapUIDecoration",              { fg = P.peach })
  hl("DapUIWatchesEmpty",            { fg = P.faint })
  hl("DapUIWatchesValue",            { fg = P.green })
  hl("DapUIWatchesError",            { fg = P.red })
  hl("DapUIModifiedValue",           { fg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("DapUIFloatNormal",             { bg = P.bg_deep })
  hl("DapUIFloatBorder",             { fg = P.float_border })

  -- DAP breakpoint/stopped signs
  hl("DapBreakpoint",          { fg = P.red })
  hl("DapBreakpointCondition", { fg = P.yellow })
  hl("DapLogPoint",            { fg = P.cyan })
  hl("DapStopped",             { fg = P.green, bg = P.bg_hl })
  if Paper.enabled then
    hl("FoxPaperDebugLine", { fg = P.fg, bg = P.sel })
    hl("DapStopped", { fg = P.bookmark })
    hl("DapBreakpoint", { fg = P.comment })
    vim.fn.sign_define("DapStopped", { text = "→", texthl = "DapStopped", linehl = "FoxPaperDebugLine" })
    vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DapBreakpoint" })
  end

  -- Aerial
  hl("AerialLine",         { bg = P.bg_hl })
  hl("AerialGuide",        { fg = P.bg_hl })
  hl("AerialFunctionIcon", { fg = P.peach })
  hl("AerialClassIcon",    { fg = P.pink })
  hl("AerialVariableIcon", { fg = P.fg })

  -- Diffview
  hl("DiffviewFilePanelTitle",   { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("DiffviewFilePanelCounter", { fg = P.pink })
  hl("DiffviewFilePanelFileName", { fg = P.fg })
  hl("DiffviewNormal",           { bg = P.bg_deep })

  -- Neotest
  hl("NeotestPassed",       { fg = P.green })
  hl("NeotestFailed",       { fg = P.red })
  hl("NeotestRunning",      { fg = P.yellow })
  hl("NeotestSkipped",      { fg = P.comment })
  hl("NeotestNamespace",    { fg = P.pink })
  hl("NeotestFile",         { fg = P.peach })
  hl("NeotestDir",          { fg = P.peach })
  hl("NeotestAdapterName",  { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("NeotestFocused",      { bold = {{SHOW_WELCOME}}, underline = {{SHOW_WELCOME}} })
  hl("NeotestIndent",       { fg = P.bg_hl })
  hl("NeotestExpandMarker", { fg = P.faint })
  hl("NeotestWinSelect",    { fg = P.peach, bold = {{SHOW_WELCOME}} })

  -- Harpoon
  hl("HarpoonWindow", { bg = P.bg_deep })
  hl("HarpoonBorder", { fg = P.float_border })

  -- TODO comments
  hl("TodoBgTODO", { fg = Paper.enabled and P.fg or P.bg, bg = Paper.enabled and P.sel or P.peach, bold = {{SHOW_WELCOME}} })
  hl("TodoFgTODO", { fg = Paper.enabled and P.fg or P.peach })
  hl("TodoBgFIX",  { fg = P.bg, bg = P.red, bold = {{SHOW_WELCOME}} })
  hl("TodoFgFIX",  { fg = P.red })
  hl("TodoBgHACK", { fg = P.bg, bg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("TodoFgHACK", { fg = P.yellow })
  hl("TodoBgNOTE", { fg = Paper.enabled and P.fg or P.bg, bg = Paper.enabled and P.sel or P.green, bold = {{SHOW_WELCOME}} })
  hl("TodoFgNOTE", { fg = Paper.enabled and P.fg or P.green })
  hl("TodoBgWARN", { fg = P.bg, bg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("TodoFgWARN", { fg = P.yellow })
  hl("TodoBgPERF", { fg = P.bg, bg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("TodoFgPERF", { fg = P.pink })

  -- Fidget
  hl("FidgetTitle", { fg = P.peach })
  hl("FidgetTask",  { fg = P.comment })

  -- Treesitter context
  hl("TreesitterContext",           { bg = P.none })
  hl("TreesitterContextLineNumber", { fg = P.peach })
  hl("TreesitterContextBottom",     { underline = {{SHOW_WELCOME}}, sp = P.bg_hl })

  -- Mason
  hl("MasonHeader",             { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("MasonHighlight",          { fg = P.peach })
  hl("MasonHighlightBlock",     { fg = P.bg, bg = P.peach })
  hl("MasonHighlightBlockBold", { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("MasonMuted",              { fg = P.comment })
  hl("MasonMutedBlock",         { fg = P.bg, bg = P.surface })

  -- Lazy.nvim
  hl("LazyH1",            { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("LazyH2",            { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("LazyButton",        { bg = P.bg_hl })
  hl("LazyButtonActive",  { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("LazySpecial",       { fg = P.pink })
  hl("LazyComment",       { fg = P.comment })
  hl("LazyProgressDone",  { fg = P.peach })
  hl("LazyProgressTodo",  { fg = P.faint })
  hl("LazyReasonPlugin",  { fg = P.pink })
  hl("LazyReasonEvent",   { fg = P.yellow })
  hl("LazyReasonKeys",    { fg = P.cyan })
  hl("LazyReasonCmd",     { fg = P.green })

  -- Copilot
  hl("CopilotSuggestion", { fg = P.comment, italic = {{SHOW_WELCOME}} })
  hl("CopilotAnnotation", { fg = P.faint })


  -- Gitsigns blame
  hl("GitSignsCurrentLineBlame", { fg = P.faint, italic = {{SHOW_WELCOME}} })

  -- Rainbow delimiters
  hl("RainbowDelimiterPeach",  { fg = P.rainbow[1] })
  hl("RainbowDelimiterPink",   { fg = P.rainbow[2] })
  hl("RainbowDelimiterMint",   { fg = P.rainbow[3] })
  hl("RainbowDelimiterYellow", { fg = P.rainbow[4] })
  hl("RainbowDelimiterCyan",   { fg = P.rainbow[5] })
  hl("RainbowDelimiterRed",    { fg = P.rainbow[6] })

  -- Noice
  hl("NoiceCmdlinePopup",            { bg = P.bg_deep })
  hl("NoiceCmdlinePopupBorder",      { fg = P.float_border })
  hl("NoiceCmdlinePopupTitle",       { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("NoiceCmdlinePopupBorderSearch", { fg = P.yellow })
  hl("NoiceCmdlineIcon",             { fg = P.peach })
  hl("NoiceCmdlineIconSearch",       { fg = P.yellow })
  hl("NoicePopupmenu",               { bg = P.bg_deep })
  hl("NoicePopupmenuBorder",         { fg = P.float_border })
  hl("NoicePopupmenuSelected",       { bg = P.list_sel })
  hl("NoicePopupmenuMatch",          { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("NoiceMini",                    { bg = P.bg_deep })
  hl("NoiceFormatProgressDone",      { fg = P.bg, bg = P.peach })
  hl("NoiceFormatProgressTodo",      { fg = P.comment, bg = P.bg_hl })
  hl("NoiceLspProgressTitle",        { fg = P.peach })
  hl("NoiceConfirm",                 { bg = P.bg_deep })
  hl("NoiceConfirmBorder",           { fg = P.pink })
  hl("NoiceVirtualText",             { fg = P.peach })
  hl("NoiceSplit",                   { bg = P.bg_deep })
  hl("NoiceSplitBorder",             { fg = P.float_border, bg = P.bg_deep })

  -- Notify
  hl("NotifyERRORBorder", { fg = P.clay })
  hl("NotifyWARNBorder",  { fg = P.warn })
  hl("NotifyINFOBorder",  { fg = P.float_border })
  hl("NotifyDEBUGBorder", { fg = P.comment })
  hl("NotifyTRACEBorder", { fg = P.pink })
  hl("NotifyERRORIcon",   { fg = P.clay })
  hl("NotifyWARNIcon",    { fg = P.warn })
  hl("NotifyINFOIcon",    { fg = P.peach })
  hl("NotifyDEBUGIcon",   { fg = P.comment })
  hl("NotifyTRACEIcon",   { fg = P.pink })
  hl("NotifyERRORTitle",  { fg = P.clay })
  hl("NotifyWARNTitle",   { fg = P.warn })
  hl("NotifyINFOTitle",   { fg = P.peach })
  hl("NotifyDEBUGTitle",  { fg = P.comment })
  hl("NotifyTRACETitle",  { fg = P.pink })
  hl("NotifyBackground",  { bg = P.bg })

  -- Scrollbar
  hl("ScrollbarHandle",          { bg = P.peach })
  hl("ScrollbarSearchHandle",    { fg = P.peach, bg = P.bg_hl })
  hl("ScrollbarSearch",          { fg = P.peach })
  hl("ScrollbarErrorHandle",     { fg = P.red, bg = P.bg_hl })
  hl("ScrollbarError",           { fg = P.red })
  hl("ScrollbarWarnHandle",      { fg = P.yellow, bg = P.bg_hl })
  hl("ScrollbarWarn",            { fg = P.yellow })
  hl("ScrollbarInfoHandle",      { fg = P.cyan, bg = P.bg_hl })
  hl("ScrollbarInfo",            { fg = P.cyan })
  hl("ScrollbarHintHandle",      { fg = P.green, bg = P.bg_hl })
  hl("ScrollbarHint",            { fg = P.green })
  hl("ScrollbarGitAddHandle",    { fg = P.green, bg = P.bg_hl })
  hl("ScrollbarGitAdd",          { fg = P.green })
  hl("ScrollbarGitChangeHandle", { fg = P.yellow, bg = P.bg_hl })
  hl("ScrollbarGitChange",       { fg = P.yellow })
  hl("ScrollbarGitDeleteHandle", { fg = P.red, bg = P.bg_hl })
  hl("ScrollbarGitDelete",       { fg = P.red })

  -- hlslens
  hl("HlSearchNear",     { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("HlSearchLens",     { fg = P.comment })
  hl("HlSearchLensNear", { fg = P.bg, bg = P.peach })
  if Paper.enabled then
    hl("HlSearchNear", { link = "CurSearch" })
    hl("HlSearchLensNear", { fg = P.fg, bg = P.sel })
  end

  -- Avante
  hl("AvanteTitle",                        { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("AvanteReversedTitle",                { fg = P.peach, bg = P.bg_deep })
  hl("AvanteSubtitle",                     { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("AvanteReversedSubtitle",             { fg = P.peach, bg = P.bg_deep })
  hl("AvanteThirdTitle",                   { fg = P.warm, bg = P.bg_hl })
  hl("AvanteReversedThirdTitle",           { fg = P.bg_hl, bg = P.bg_deep })
  hl("AvanteSidebarNormal",                { bg = P.bg_deep })
  hl("AvanteSidebarWinSeparator",          { fg = P.bg_deep, bg = P.bg_deep })
  hl("AvanteSidebarWinHorizontalSeparator", { fg = P.bg_hl })
  hl("AvantePromptInput",                  { fg = P.fg, bg = P.bg_hl })
  hl("AvantePromptInputBorder",            { fg = P.float_border, bg = P.bg_hl })
  hl("AvanteInlineHint",                   { fg = P.peach, bg = P.bg_deep, bold = {{SHOW_WELCOME}} })
  hl("AvantePopupHint",                    { fg = P.comment, bg = P.bg_deep })
  hl("AvanteConfirmTitle",                 { fg = P.bg, bg = P.red, bold = {{SHOW_WELCOME}} })
  hl("AvanteButtonDefault",               { fg = P.bg, bg = P.comment })
  hl("AvanteButtonDefaultHover",          { fg = P.bg, bg = P.green })
  hl("AvanteButtonPrimary",               { fg = P.bg, bg = P.warm })
  hl("AvanteButtonPrimaryHover",          { fg = P.bg, bg = P.peach })
  hl("AvanteButtonDanger",                { fg = P.bg, bg = P.warm })
  hl("AvanteButtonDangerHover",           { fg = P.bg, bg = P.red })
  hl("AvanteToBeDeleted",                 { bg = P.conflict_cur, strikethrough = {{SHOW_WELCOME}} })
  hl("AvanteToBeDeletedWOStrikethrough",  { bg = P.conflict_cur })
  hl("AvanteConflictCurrent",             { bg = P.conflict_cur, bold = {{SHOW_WELCOME}} })
  hl("AvanteConflictCurrentLabel",        { bg = P.conflict_cur_label })
  hl("AvanteConflictIncoming",            { bg = P.conflict_inc, bold = {{SHOW_WELCOME}} })
  hl("AvanteConflictIncomingLabel",       { bg = P.conflict_inc_label })
  hl("AvanteStateSpinnerGenerating",      { fg = P.bg, bg = P.pink })
  hl("AvanteStateSpinnerToolCalling",     { fg = P.bg, bg = P.peach })
  hl("AvanteStateSpinnerFailed",          { fg = P.bg, bg = P.red })
  hl("AvanteStateSpinnerSucceeded",       { fg = P.bg, bg = P.green })
  hl("AvanteStateSpinnerSearching",       { fg = P.bg, bg = P.yellow })
  hl("AvanteStateSpinnerThinking",        { fg = P.bg, bg = P.pink })
  hl("AvanteStateSpinnerCompacting",      { fg = P.bg, bg = P.yellow })
  hl("AvanteTaskRunning",                 { fg = P.pink })
  hl("AvanteTaskCompleted",               { fg = P.green })
  hl("AvanteTaskFailed",                  { fg = P.red })
  hl("AvanteThinking",                    { fg = P.pink, italic = {{SHOW_WELCOME}} })

  -- Claude Code
  hl("ClaudeCodeNormal",    { fg = P.fg, bg = P.bg_deep })
  hl("ClaudeCodeBorder",    { fg = P.float_border, bg = P.bg_deep })
  hl("ClaudeCodeTitle",     { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("ClaudeCodeSeparator", { fg = P.bg_deep, bg = P.bg_deep })

  -- vim-illuminate (subtle earthy underline, not distracting)
  hl("IlluminatedWordText",  { bg = P.illuminate })
  hl("IlluminatedWordRead",  { bg = P.illuminate })
  hl("IlluminatedWordWrite", { bg = P.illuminate, underline = {{SHOW_WELCOME}} })
  if Paper.enabled then
    for _, name in ipairs({ "IlluminatedWordText", "IlluminatedWordRead", "IlluminatedWordWrite" }) do
      hl(name, { underline = true, sp = P.comment })
    end
  end

  -- nvim-cmp
  hl("CmpItemAbbrMatch",      { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("CmpItemAbbrMatchFuzzy", { fg = P.peach })
  hl("CmpItemAbbrDeprecated", { fg = P.faint, strikethrough = {{SHOW_WELCOME}} })
  hl("CmpItemKindFunction",   { fg = P.peach })
  hl("CmpItemKindMethod",     { fg = P.peach })
  hl("CmpItemKindVariable",   { fg = P.fg })
  hl("CmpItemKindKeyword",    { fg = P.pink })
  hl("CmpItemKindClass",      { fg = P.peach })
  hl("CmpItemKindStruct",     { fg = P.peach })
  hl("CmpItemKindInterface",  { fg = P.peach })
  hl("CmpItemKindModule",     { fg = P.pink })
  hl("CmpItemKindProperty",   { fg = P.peach })
  hl("CmpItemKindField",      { fg = P.peach })
  hl("CmpItemKindEnum",       { fg = P.peach })
  hl("CmpItemKindEnumMember", { fg = P.cyan })
  hl("CmpItemKindConstant",   { fg = P.yellow })
  hl("CmpItemKindSnippet",    { fg = P.green })
  hl("CmpItemKindText",       { fg = P.comment })
  hl("CmpItemKindFile",       { fg = P.fg })
  hl("CmpItemKindFolder",     { fg = P.peach })
  hl("CmpItemMenu",           { fg = P.comment, italic = {{SHOW_WELCOME}} })
  if Paper.enabled then
    hl("CmpItemAbbr", { fg = P.fg })
    hl("CmpItemAbbrMatch", { fg = P.fg, bold = true })
    hl("CmpItemAbbrMatchFuzzy", { fg = P.fg })
    hl("CmpItemMenu", { fg = P.fg_dim, italic = false })
    hl("FoxPaperCompletionIcon", { fg = P.bookmark })
    for kind in pairs(Paper.completion_icons) do
      hl("CmpItemKind" .. kind, { fg = P.fg_dim })
    end
  end

  -- Notification toasts (snacks): the dark panel of every other float; the level colour rides on the
  -- border, icon and title in the theme's own diagnostic colours (info = the peach of every float border)
  for level, c in pairs({ Error = P.pen, Warn = P.warn, Info = P.peach, Debug = P.comment, Trace = P.lavender }) do
    hl("SnacksNotifier" .. level,       { fg = P.fg, bg = P.bg_deep })
    hl("SnacksNotifierBorder" .. level, { fg = c, bg = P.bg_deep })
    hl("SnacksNotifierTitle" .. level,  { fg = c, bg = P.bg_deep, bold = {{SHOW_WELCOME}} })
    hl("SnacksNotifierIcon" .. level,   { fg = c, bg = P.bg_deep })
    hl("SnacksNotifierFooter" .. level, { fg = P.comment, bg = P.bg_deep })
  end
  hl("SnacksNotifierBody",            { fg = P.fg, bg = P.bg_deep })
  hl("SnacksNotifierHistory",         { fg = P.fg, bg = P.bg_deep })
  hl("SnacksNotifierHistoryTitle",    { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("SnacksNotifierHistoryDateTime", { fg = P.comment })

  -- Tag-comment markers ([KEY]_[value] in // comments; the decoration provider is below)
  hl("FoxTagKey",   { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("FoxTagEnd",   { fg = P.lavender })
  hl("FoxTagSep",   { fg = P.surface })
  hl("FoxTagValue", { fg = P.fg_pastel })
  hl("FoxTagChip",  { fg = P.blush })
  -- Section banners (//---- rule, title, rule): typed and inked, never the handwritten comment italic
  hl("FoxSectionRule", { fg = P.syn.header, bold = {{SHOW_WELCOME}}, nocombine = {{SHOW_WELCOME}} })
end

apply_foxml_theme()
Paper.setup_popup_styles()

-- Re-apply theme after any colorscheme event (prevents treesitter/plugin overrides)
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function() apply_foxml_theme() end,
})

-- Paper keeps its rose page number; other palettes follow the mode pill.
local mode_nr = { n = P.peach, i = P.green, v = P.pink, V = P.pink, ["\22"] = P.pink, s = P.pink, S = P.pink,
  ["\19"] = P.pink, R = P.red, r = P.red, c = P.yellow, t = P.green }
vim.api.nvim_create_autocmd({ "ModeChanged", "ColorScheme" }, {
  group = vim.api.nvim_create_augroup("foxml_mode_nr", {}),
  callback = function()
    local fg = Paper.enabled and P.bookmark or mode_nr[vim.api.nvim_get_mode().mode:sub(1, 1)] or P.peach
    vim.api.nvim_set_hl(0, "CursorLineNr", { fg = fg, bold = {{SHOW_WELCOME}} })
  end,
})

-- Tag-comment markers: colour the [KEY]_[value] grammar inside // comments by shape (keys, [END_*]
-- closers, values, nested [CHIPS]), never by vocabulary, so it works in any project using the format.
-- Ephemeral extmarks on visible lines only; priority above treesitter (100) and LSP tokens (125).
do
  local ns = vim.api.nvim_create_namespace("foxml_tag_markers")
  local tag_fts = { c = true, cpp = true, cuda = true, objc = true, objcpp = true }
  local KEY = "%[[A-Z][A-Z0-9_]+%]"
  local function paint(buf, row, s, e, group, prio)
    vim.api.nvim_buf_set_extmark(buf, ns, row, s - 1, { end_col = e, hl_group = group, ephemeral = true, priority = prio or 140 })
  end
  -- A section banner is a //---- rule line, or a // title line sandwiched between two of them.
  local section_headers = {{NVIM_SECTION_HEADERS}}
  local RULE = "^%s*//%s*[-=]+%s*$"
  local function is_rule(l) return l ~= nil and #l >= 10 and l:match(RULE) ~= nil end
  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, buf) return tag_fts[vim.bo[buf].filetype] == true end,
    on_line = function(_, _, buf, row)
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      local pos = line and line:find("//", 1, true)
      if not pos then return end
      if section_headers and line:match("^%s*//") then
        local around = vim.api.nvim_buf_get_lines(buf, math.max(row - 1, 0), row + 2, false)
        local above = row > 0 and around[1] or nil
        local below = around[row > 0 and 3 or 2]
        if is_rule(line) or (is_rule(above) and is_rule(below)) then
          paint(buf, row, pos, #line, "FoxSectionRule", 139)
        end
      end
      if not line:find("[", pos, true) then return end
      while true do
        local s, e = line:find(KEY, pos)
        if not s then return end
        pos = e + 1
        if not line:sub(s - 1, s - 1):match("[%w_]") then -- arr[IDX] is code, not a tag
          local closer = line:sub(s + 1, s + 4) == "END_"
          paint(buf, row, s, e, closer and "FoxTagEnd" or "FoxTagKey")
          while line:sub(pos, pos + 1) == "_[" do -- _[value], chained: [ASSERT]_[LAYOUT_LOCK]_[expr]
            local vs, ve = line:find("^%b[]", pos + 1)
            if not vs then break end
            paint(buf, row, pos, pos, "FoxTagSep")
            local chained = line:sub(ve + 1, ve + 2) == "_["
            local subcat = chained and line:sub(vs, ve):match("^" .. KEY .. "$") ~= nil
            paint(buf, row, vs, ve, closer and "FoxTagEnd" or (subcat and "FoxTagChip" or "FoxTagValue"))
            if not closer and not subcat then -- nested chips: [TAG]_[[ENGINE] [ML_INFERENCE]]
              local cs, ce = line:find(KEY, vs + 1)
              while cs and ce < ve do
                paint(buf, row, cs, ce, "FoxTagChip")
                cs, ce = line:find(KEY, ce + 1)
              end
            end
            pos = ve + 1
          end
        end
      end
    end,
  })
end

-- Override devicon colors to match FoxML palette (peach only in file tree)
vim.defer_fn(function()
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok then
    local icons = devicons.get_icons()
    local overrides = {}
    for name, icon in pairs(icons) do
      overrides[name] = { icon = icon.icon, color = P.peach, name = icon.name }
    end
    devicons.set_icon(overrides)
    devicons.set_default_icon("", P.peach)
  end
end, 100)

-- Force solid background on sidebar/panel filetypes
-- (uses vim.schedule so it runs AFTER plugins set their own winhighlight)
local sidebar_fts = { ["Avante"] = {{SHOW_WELCOME}}, ["AvanteInput"] = {{SHOW_WELCOME}},
  ["AvantePrompt"] = {{SHOW_WELCOME}}, ["Trouble"] = {{SHOW_WELCOME}}, ["aerial"] = {{SHOW_WELCOME}}, ["markdown"] = false }
vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
  callback = function()
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(0) then return end
      local ft = vim.bo.filetype
      if not sidebar_fts[ft] then return end
      local whl = vim.wo.winhighlight
      if not whl:find("NormalSidebar") then
        vim.wo.winhighlight = whl .. (whl ~= "" and "," or "")
          .. "Normal:NormalSidebar,NormalNC:NormalSidebar,EndOfBuffer:NormalSidebar"
      end
    end)
  end,
})

-- Unified rounded borders for all LSP floats (hover, signature, diagnostics)
local border = "rounded"

-- Diagnostics config
vim.diagnostic.config({
  virtual_text = Paper.virtual_text, -- Paper shows messages only on the current line.
  virtual_lines = false,  -- core handler (replaced lsp_lines.nvim); <leader>tl toggles
  float = { border = border },
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = " ",
      [vim.diagnostic.severity.WARN]  = " ",
      [vim.diagnostic.severity.INFO]  = " ",
      [vim.diagnostic.severity.HINT]  = " ",
    },
    texthl = {
      [vim.diagnostic.severity.ERROR] = "DiagnosticSignError",
      [vim.diagnostic.severity.WARN]  = "DiagnosticSignWarn",
      [vim.diagnostic.severity.INFO]  = "DiagnosticSignInfo",
      [vim.diagnostic.severity.HINT]  = "DiagnosticSignHint",
    },
    numhl = {
      [vim.diagnostic.severity.ERROR] = "DiagnosticLineNrError",
      [vim.diagnostic.severity.WARN]  = "DiagnosticLineNrWarn",
      [vim.diagnostic.severity.INFO]  = "DiagnosticLineNrInfo",
      [vim.diagnostic.severity.HINT]  = "DiagnosticLineNrHint",
    },
    linehl = not Paper.enabled and {
      [vim.diagnostic.severity.ERROR] = "DiagnosticLineError",
      [vim.diagnostic.severity.WARN]  = "DiagnosticLineWarn",
      [vim.diagnostic.severity.INFO]  = "DiagnosticLineInfo",
      [vim.diagnostic.severity.HINT]  = "DiagnosticLineHint",
    } or {},
  },
})

Paper.setup_correction_input()

-- Patch the common float helper used by LSP UIs (fallback when noice isn't active)
do
  local _open = vim.lsp.util.open_floating_preview
  function vim.lsp.util.open_floating_preview(contents, syntax, opts, ...)
    opts = opts or {}
    opts.border = opts.border or border
    return _open(contents, syntax, opts, ...)
  end
end

--
-- Lualine theme sync (noice integration removed)
local function paper_footer_mode(ink)
  return { a = { fg = ink, bg = P.bg_deep, gui = "none" },
           b = { fg = P.comment, bg = P.bg_deep }, c = { fg = P.comment, bg = P.bg_deep } }
end
-- Sidebar focus must not shorten the editor path to the tree's narrower width.
local filename_component = { "filename", path = 1, shorting_target = Paper.enabled and 0 or nil,
  color = Paper.enabled and { fg = P.fg } or nil,
  file_status = not Paper.enabled,
  fmt = Paper.enabled and function(filename)
    local buf = vim.api.nvim_get_current_buf()
    if not Paper.file_buffer(buf) then return filename end
    local icon = (vim.bo[buf].readonly or not vim.bo[buf].modifiable) and "" or "✎"
    return icon .. "  " .. filename
  end or nil,
  symbols = Paper.enabled and { modified = "✎", readonly = "", unnamed = "[No Name]", newfile = "[New]" } or nil }
local draft_component = {
  function() return "draft" end,
  cond = function() return Paper.enabled and Paper.file_buffer(0) and vim.bo.modified end,
  color = { fg = P.fg, bg = P.sel }, padding = { left = 1, right = 1 },
}
require("lualine").setup({
  options = {
    ignore_focus = Paper.enabled and { "neo-tree" } or {},
    theme = Paper.enabled and {
      normal = paper_footer_mode(P.fg), insert = paper_footer_mode(P.green),
      visual = paper_footer_mode(P.pink), replace = paper_footer_mode(P.red),
      command = paper_footer_mode(P.yellow), inactive = paper_footer_mode(P.faint),
    } or {
      normal   = { a = { fg = P.bg, bg = P.peach, gui = "bold" }, b = { fg = P.peach, bg = P.bg_hl }, c = { fg = P.comment, bg = P.bg_deep } },
      insert   = { a = { fg = P.bg, bg = P.green, gui = "bold" }, b = { fg = P.green, bg = P.bg_hl } },
      visual   = { a = { fg = P.bg, bg = P.pink, gui = "bold" }, b = { fg = P.pink, bg = P.bg_hl } },
      replace  = { a = { fg = P.bg, bg = P.red, gui = "bold" }, b = { fg = P.red, bg = P.bg_hl } },
      command  = { a = { fg = P.bg, bg = P.yellow, gui = "bold" }, b = { fg = P.yellow, bg = P.bg_hl } },
      inactive = { a = { fg = P.comment, bg = P.bg_deep }, b = { fg = P.faint, bg = P.bg_deep }, c = { fg = P.faint, bg = P.bg_deep } },
    },
    section_separators = { left = "", right = "" },
    component_separators = { left = "", right = "" },
  },
  sections = {
    lualine_a = { "mode" },
    lualine_b = { "branch", "diff", "diagnostics" },
    lualine_c = { filename_component, draft_component },
    lualine_x = {
      -- the other Claudes (foxml.claude): reviewing/following, who needs you, the plan gate, who edited this buffer
      { function() local ok, c = pcall(require, "foxml.claude"); return ok and c.status_mode() or "" end, color = { fg = P.peach } },
      { function() local ok, c = pcall(require, "foxml.claude"); return ok and c.status_needs() or "" end, color = { fg = P.red } },
      {
        function() local ok, c = pcall(require, "foxml.claude"); return ok and c.status_gate() or "" end,
        color = function()
          local ok, c = pcall(require, "foxml.claude")
          return { fg = ok and c.status_gate():find("open") and P.green or P.comment }
        end,
      },
      { function() local ok, c = pcall(require, "foxml.claude"); return ok and c.status_footprint() or "" end, color = { fg = P.pink } },
      {
        -- this buffer's engine: Copilot's icon only where Copilot is attached (a public repo), else the local model's
        function()
          if #vim.lsp.get_clients({ name = "copilot", bufnr = 0 }) == 0 then
            return vim.b.minuet_virtual_text_auto_trigger and "󰚩 " or ""
          end
          local ok, api = pcall(require, "copilot.api")
          if not ok then return "" end
          local status = api.status.data.status
          if status == "InProgress" then return " " end
          if status == "Warning" then return " " end
          if status == "Normal" then return " " end
          return ""
        end,
        color = function()
          if #vim.lsp.get_clients({ name = "copilot", bufnr = 0 }) == 0 then return { fg = P.cyan } end
          local ok, api = pcall(require, "copilot.api")
          if not ok then return { fg = P.comment } end
          local status = api.status.data.status
          if status == "InProgress" then return { fg = P.yellow } end
          if status == "Warning" then return { fg = P.red } end
          return { fg = P.green }
        end,
      },
      {
        function()
          -- the language server(s) for this buffer; copilot is an LSP client too, and whichever
          -- attached first used to win the slot
          local names = {}
          for _, c in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
            if c.name ~= "copilot" then names[#names + 1] = c.name end
          end
          if #names == 0 then return "" end
          return " " .. table.concat(names, " · ")
        end,
        color = { fg = P.peach },
      },
      "filetype",
    },
    lualine_y = { "progress" },
    lualine_z = { "location" },
  },
  inactive_sections = Paper.enabled and {
    lualine_a = {}, lualine_b = {}, lualine_c = { filename_component, draft_component },
    lualine_x = { "location" }, lualine_y = {}, lualine_z = {},
  } or nil,
})

-- Treesitter — main branch (nvim 0.12). The legacy require("nvim-treesitter.configs")
-- module is gone; parsers install via install(), and highlight/indent/textobjects are
-- wired with core vim.treesitter + the textobjects companion. (Migrated from the master
-- configs.setup() shape — workspace plan W2, 2026-06-28. UNTESTED until a 0.12 run.)
local ts_parsers = { "lua", "python", "c", "cpp", "asm", "bash", "json", "yaml", "markdown", "vim", "vimdoc", "java", "javadoc" }
-- "latex" stays dropped — its parser build still trips the tree-sitter-cli
-- --no-bindings change; add it back when upstream ships a compatible build script.

-- install_dir passed explicitly so nvim-treesitter prepends it to runtimepath
-- (lazy.nvim resets rtp and drops stdpath('data')/site; main only adds the dir
-- to rtp when install_dir is set — empty setup() leaves parsers unreachable).
require("nvim-treesitter").setup({
  install_dir = vim.fn.stdpath("data") .. "/site",
})

if Paper.enabled then
  vim.treesitter.query.set("markdown", "highlights", [[; extends
    (list_item
      (task_list_marker_checked)
      (paragraph) @markup.list.checked.text
      (#set! priority 110))
  ]])
end

-- Install only the parsers we don't already have (main has NO auto-install).
-- VERIFY-ON-0.12: get_installed() is the documented listing helper but wasn't
-- confirmed verbatim from a 2026 source — if it's absent on your build this block
-- skips silently and you install once with `:TSUpdate` / `:TSInstall <lang>`.
do
  local okc, cfg = pcall(require, "nvim-treesitter.config")
  if okc and cfg.get_installed then
    local have = {}
    for _, l in ipairs(cfg.get_installed()) do have[l] = {{SHOW_WELCOME}} end
    local missing = {}
    for _, l in ipairs(ts_parsers) do
      if not have[l] then missing[#missing + 1] = l end
    end
    if #missing > 0 then require("nvim-treesitter").install(missing) end
  end
end

-- Highlight + indent: master's `highlight`/`indent = { enable = true }` are gone.
-- Start treesitter per-buffer in a FileType autocmd (core API), only when a parser
-- exists, and drive indentexpr off the plugin (experimental on main — keep quoting).
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("foxml_ts", { clear = {{SHOW_WELCOME}} }),
  callback = function(args)
    local lang = vim.treesitter.language.get_lang(vim.bo[args.buf].filetype)
    if lang and pcall(vim.treesitter.language.add, lang) then
      pcall(vim.treesitter.start, args.buf, lang)
      vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
    end
  end,
})

-- Incremental selection: the master module was removed with no main equivalent.
-- nvim 0.12 ships it in core visual mode — `an` expand to parent node, `in` shrink
-- to child (VERIFY-ON-0.12: `]n`/`[n` to siblings exist on some builds). No setup
-- needed; remap here if you want the old gnn/grn feel.

-- Textobjects (companion main branch): setup() + manual keymaps — the module that
-- auto-wired keymaps on master is gone. Mirrors the old select/move/swap binds.
require("nvim-treesitter-textobjects").setup({
  select = { lookahead = {{SHOW_WELCOME}} },
  move = { set_jumps = {{SHOW_WELCOME}} },
})
local ts_select = require("nvim-treesitter-textobjects.select")
local ts_move   = require("nvim-treesitter-textobjects.move")
local ts_swap   = require("nvim-treesitter-textobjects.swap")
for lhs, query in pairs({
  ["af"] = "@function.outer",    ["if"] = "@function.inner",
  ["ac"] = "@class.outer",       ["ic"] = "@class.inner",
  ["aa"] = "@parameter.outer",   ["ia"] = "@parameter.inner",
  ["ai"] = "@conditional.outer", ["ii"] = "@conditional.inner",
  ["al"] = "@loop.outer",        ["il"] = "@loop.inner",
}) do
  vim.keymap.set({ "x", "o" }, lhs, function()
    ts_select.select_textobject(query, "textobjects")
  end, { desc = "TS select " .. query })
end
local function ts_goto(fn, query) return function() fn(query, "textobjects") end end
vim.keymap.set({ "n", "x", "o" }, "]m", ts_goto(ts_move.goto_next_start,     "@function.outer"),  { desc = "TS next fn start" })
vim.keymap.set({ "n", "x", "o" }, "]]", ts_goto(ts_move.goto_next_start,     "@class.outer"),     { desc = "TS next class start" })
vim.keymap.set({ "n", "x", "o" }, "]a", ts_goto(ts_move.goto_next_start,     "@parameter.inner"), { desc = "TS next param" })
vim.keymap.set({ "n", "x", "o" }, "[m", ts_goto(ts_move.goto_previous_start, "@function.outer"),  { desc = "TS prev fn start" })
vim.keymap.set({ "n", "x", "o" }, "[[", ts_goto(ts_move.goto_previous_start, "@class.outer"),     { desc = "TS prev class start" })
vim.keymap.set({ "n", "x", "o" }, "[a", ts_goto(ts_move.goto_previous_start, "@parameter.inner"), { desc = "TS prev param" })
vim.keymap.set("n", "<leader>na", function() ts_swap.swap_next("@parameter.inner") end,     { desc = "TS swap next param" })
vim.keymap.set("n", "<leader>nA", function() ts_swap.swap_previous("@parameter.inner") end, { desc = "TS swap prev param" })

-- Sticky context skips include guards: a header's whole body sits inside `#ifndef X_HPP`, so the guard was
-- pinned as the top context line in every header. Other preprocessor blocks (#ifdef MULTICORE_TUI,
-- #if defined(__AVX512F__)) still show. Patches only that one pattern of nvim-treesitter-context's C query
-- (C++ inherits it), and only when the patched query parses, so a plugin update can't break context.
-- Run at the first C / C++ buffer, not at startup: compiling the C++ query costs ~80 ms (measured
-- 2026-10-04), which every launch paid, even for a file that isn't C or C++.
local context_patched = {}
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "c", "cpp" },
  callback = function(ev)
    local lang = ev.match
    if context_patched[lang] then return end
    context_patched[lang] = true
    local parts = {}
    for _, f in ipairs(vim.treesitter.query.get_files(lang, "context")) do
      parts[#parts + 1] = table.concat(vim.fn.readfile(f), "\n")
    end
    local src, hits = table.concat(parts, "\n"):gsub("(%(preproc_ifdef%s+name:%s*%(identifier%))",
      '%1 @_guard (#not-lua-match? @_guard "_H[P]*_*$")', 1)
    if hits == 1 and pcall(vim.treesitter.query.parse, lang, src) then
      vim.treesitter.query.set(lang, "context", src)
    end
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = {"json", "jsonc"}, callback = function() vim.wo.conceallevel = 0 end,
})

-- Mason (LSP installer). clangd comes from the system (pacman `clang`, fox-install --cpp-pro) so the
-- editor matches the clang++/clang-tidy toolchain; Mason installs it only on a machine without one.
local system_clangd = vim.fn.executable("/usr/bin/clangd") == 1
require("mason").setup()
require("mason-lspconfig").setup({
  ensure_installed = vim.list_extend({ "lua_ls", "pyright", "bashls", "jsonls", "yamlls" },
    system_clangd and {} or { "clangd" }),
})

-- format on save


-- nvim-cmp (autocomplete)
local cmp = require("cmp")
local luasnip = require("luasnip")
cmp.setup({
  snippet = { expand = function(args) luasnip.lsp_expand(args.body) end },
  formatting = Paper.enabled and { format = Paper.completion_format } or nil,
  mapping = cmp.mapping.preset.insert({
    ["<C-b>"] = cmp.mapping.scroll_docs(-4),
    ["<C-f>"] = cmp.mapping.scroll_docs(4),
    ["<C-Space>"] = cmp.mapping.complete(),
    ["<CR>"] = cmp.mapping.confirm({ select = {{SHOW_WELCOME}} }),
    ["<Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_next_item()
      elseif luasnip.expand_or_jumpable() then
        luasnip.expand_or_jump()
      else
        fallback()
      end
    end, { "i", "s" }),
    ["<S-Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_prev_item()
      elseif luasnip.jumpable(-1) then
        luasnip.jump(-1)
      else
        fallback()
      end
    end, { "i", "s" }),
  }),
  sources = cmp.config.sources({ { name = "nvim_lsp" }, { name = "luasnip" } },
    { { name = "buffer" }, {
      name = "path",
      -- only where a path is actually being typed: inside quotes (#include "engine/…", "assets/…") or after
      -- ./ ../ ~/ — never on a bare `/` (division, a `//` comment), which listed /bin /dev /etc … every time
      entry_filter = function(_, ctx)
        local before = ctx.cursor_before_line
        local _, dq = before:gsub('"', "")
        local _, sq = before:gsub("'", "")
        if dq % 2 == 1 or sq % 2 == 1 then return true end
        return before:match("[~%.]+/[^%s]*$") ~= nil
      end,
    } }),
})

-- === LSP (Neovim 0.11+ native API) ===
-- No on_attach in these configs: 0.12 merges per-server configs with tbl_deep_extend("force"), so
-- one here REPLACES nvim-lspconfig's own (losing :LspClangdSwitchSourceHeader, :LspPyrightOrganizeImports,
-- ...). Keymaps go in the LspAttach autocmd below; format-on-save is conform's job alone.
local lsp = vim.lsp
lsp.config("*", { capabilities = require("cmp_nvim_lsp").default_capabilities() })

lsp.config.clangd  = {
  -- absolute path: Mason prepends its bin to PATH, so a bare "clangd" could pick a stale Mason copy
  -- --log=error: nvim's LSP log keeps every line clangd writes to its stderr, and at clangd's default level that grew the
  -- log to 215 MB in a day (2026-10-15); errors are still logged
  cmd = { system_clangd and "/usr/bin/clangd" or "clangd", "--log=error" },
  root_markers = { "compile_commands.json", "CMakeLists.txt", "Makefile", ".clangd" },
}

-- Lua (tweaks)
lsp.config.lua_ls  = {
  settings = {
    Lua = {
      diagnostics = { globals = { "vim" } },
      workspace   = { checkThirdParty = false },
    },
  },
  root_markers = { ".luarc.json", ".luarc.jsonc", ".stylua.toml", ".luacheckrc", ".git" },
}

-- Enable all of them (auto-attach for matching filetypes)
lsp.enable({ "pyright", "clangd", "bashls", "jsonls", "yamlls", "lua_ls" })

-- grr/grn/gra/gri/grt, K and [d/]d are core defaults (0.11+), so only what core lacks is mapped here.
-- No buffer-local `gr`: it prefixes the core gr* maps, so every press waited out timeoutlen.
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("foxml_lsp_keys", { clear = true }),
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not client or client.name == "copilot" then return end
    Paper.enable_hints(args.buf, client)
    local map = function(mode, lhs, rhs, desc)
      vim.keymap.set(mode, lhs, rhs, { buffer = args.buf, desc = desc })
    end
    map("n", "gd", vim.lsp.buf.definition, "Go to definition")
    map("n", "<leader>rn", vim.lsp.buf.rename, "Rename")
    map("n", "<leader>ca", vim.lsp.buf.code_action, "Code Action")
    -- through conform (LSP as fallback), so manual formats follow the same project rules as format-on-save
    map("n", "<leader>cf", function() require("conform").format({ async = true, lsp_format = "fallback" }) end, "Format")
  end,
})

-- Keymaps (global)
local map = vim.keymap.set
-- <leader>ff / <leader>fg are project-scoped: defined with the per-project settings below
map("n", "<leader>fb", "<cmd>Telescope buffers<cr>", { desc = "Buffers" })
map("n", "<leader>fh", "<cmd>Telescope help_tags<cr>", { desc = "Help" })
map("n", "<leader>fn", function() Snacks.notifier.show_history() end, { desc = "Notification history" })
-- === Projects / CMake / DAP / Tests / Symbols ===
local function safe_call(mod, fn)
  local ok, m = pcall(require, mod)
  if not ok then
    vim.notify(("Module not loaded: %s"):format(mod), vim.log.levels.WARN)
    return
  end
  return fn(m)
end

-- Projects (Telescope projects extension)
map("n", "<leader>pp", function()
  safe_call("telescope", function(t) t.extensions.projects.projects({}) end)
end, { desc = "Projects" })

-- CMake (cmake-tools.nvim)
map("n", "<leader>cg", function() safe_call("cmake-tools", function(c) c.generate() end) end, { desc = "CMake Generate" })
map("n", "<leader>cb", function() safe_call("cmake-tools", function(c) c.build() end) end, { desc = "CMake Build" })
map("n", "<leader>cr", function() safe_call("cmake-tools", function(c) c.run() end) end, { desc = "CMake Run target" })
map("n", "<leader>ct", function() safe_call("cmake-tools", function(c) c.select_build_type() end) end,
  { desc = "CMake Build Type" })
map("n", "<leader>cl", function() safe_call("cmake-tools", function(c) c.select_launch_target() end) end,
  { desc = "CMake Launch Target" })

-- Neotest (pick gtest or ctest adapter in your setup)
map("n", "<leader>tn", function() safe_call("neotest", function(n) n.run.run() end) end, { desc = "Test Nearest" })
map("n", "<leader>ts", function() safe_call("neotest", function(n) n.summary.toggle() end) end, { desc = "Test Summary" })

-- Symbols outline (aerial.nvim)
map("n", "<leader>so", function() safe_call("aerial", function(a) a.toggle() end) end, { desc = "Symbols (Aerial)" })

-- C/C++ header ⇄ source (works when clangd is attached)
local function switch_header_source()
  local params = { uri = vim.uri_from_bufnr(0) }
  vim.lsp.buf_request(0, "textDocument/switchSourceHeader", params, function(err, result)
    if err or not result then return end
    vim.cmd.edit(vim.uri_to_fname(result))
  end)
end
map("n", "<leader>ch", switch_header_source, { desc = "C/C++ Switch header/source" })


-- Open neo-tree at current file's directory
map("n", "-", "<cmd>Neotree reveal<cr>", { desc = "Reveal file in tree" })

-- Trouble diagnostics
map("n", "<leader>xx", "<cmd>Trouble diagnostics toggle<cr>", { desc = "Diagnostics (Trouble)" })
map("n", "<leader>xq", "<cmd>Trouble quickfix toggle<cr>", { desc = "Quickfix (Trouble)" })

-- Quality of life — comment toggle rides core gc/gcc (0.10+), so visual mode covers the whole selection
map("n", "<leader>/", "gcc", { remap = true, desc = "Comment toggle" })
map("x", "<leader>/", "gc", { remap = true, desc = "Comment toggle (selection)" })

-- Harpoon
local harpoon = require("harpoon")
map("n", "<leader>ha", function() harpoon:list():add() end, { desc = "Harpoon add file" })
map("n", "<leader>hh", function() harpoon.ui:toggle_quick_menu(harpoon:list()) end, { desc = "Harpoon menu" })
map("n", "<C-1>", function() harpoon:list():select(1) end, { desc = "Harpoon 1" })
map("n", "<C-2>", function() harpoon:list():select(2) end, { desc = "Harpoon 2" })
map("n", "<C-3>", function() harpoon:list():select(3) end, { desc = "Harpoon 3" })
map("n", "<C-4>", function() harpoon:list():select(4) end, { desc = "Harpoon 4" })

-- Ghost-text completion: ONE set of keys for whichever engine is showing a suggestion — Copilot, or the local model
-- (minuet). With no suggestion showing, the key does what it would anyway.
local function ghost(copilot_fn, minuet_fn, key)
  return function()
    local okm, mv = pcall(require, "minuet.virtualtext")
    if okm and mv.action.is_visible() then mv.action[minuet_fn](); return "" end
    local okc, cs = pcall(require, "copilot.suggestion")
    if okc and cs.is_visible() then cs[copilot_fn](); return "" end
    return vim.keycode(key)
  end
end
map("i", "<C-l>", ghost("accept", "accept", "<C-l>"), { expr = true, desc = "Accept the suggestion" })
map("i", "<C-;>", ghost("accept_word", "accept_line", "<C-;>"), { expr = true, desc = "Accept a word (local: a line)" })
map("i", "<C-'>", ghost("accept_line", "accept_line", "<C-'>"), { expr = true, desc = "Accept a line" })
map("i", "<C-]>", ghost("next", "next", "<C-]>"), { expr = true, desc = "Next suggestion" })
map("i", "<C-k>", ghost("prev", "prev", "<C-k>"), { expr = true, desc = "Previous suggestion" })
map("i", "<C-j>", ghost("dismiss", "dismiss", "<C-j>"), { expr = true, desc = "Dismiss the suggestion" })

-- Copilot ⇄ the local model: one engine per buffer, never both (their ghost text would overlap). "auto" (the default):
-- Copilot where GitHub reports the repo public, the local model everywhere else (RepoVis, above the plugin list).
-- "local": the local model everywhere. Neither mode puts Copilot on a private or unknown repo; `:Copilot attach` is
-- the explicit override.
if vim.g.fox_completion ~= "local" then vim.g.fox_completion = "auto" end
local function apply_engine(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local copilot = RepoVis.engine(buf) == "copilot"
  vim.b[buf].minuet_virtual_text_auto_trigger = not copilot
  if copilot then
    local ok, client = pcall(require, "copilot.client")
    if ok and client.buf_attach then pcall(client.buf_attach, false, buf) end -- asks should_attach again
  else
    for _, c in ipairs(vim.lsp.get_clients({ name = "copilot", bufnr = buf })) do pcall(vim.lsp.buf_detach_client, buf, c.id) end
  end
end
vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("FoxLocalCompletion", { clear = true }),
  callback = function(ev)
    local buf, name = ev.buf, vim.api.nvim_buf_get_name(ev.buf)
    if vim.bo[buf].buftype ~= "" or name == "" then return end
    if vim.b[buf].fox_visibility == nil then
      vim.b[buf].fox_visibility = "asking" -- the local model until the answer is in
      RepoVis.lookup(name, function(v)
        if vim.api.nvim_buf_is_valid(buf) then
          vim.b[buf].fox_visibility = v
          apply_engine(buf)
        end
      end)
    end
    apply_engine(buf)
  end,
})
map("n", "<leader>ta", function()
  vim.g.fox_completion = vim.g.fox_completion == "local" and "auto" or "local"
  for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_is_loaded(b) then apply_engine(b) end end
  vim.notify(vim.g.fox_completion == "local" and "Completion: the local model everywhere"
    or "Completion: Copilot in public repos, the local model elsewhere", vim.log.levels.INFO)
end, { desc = "Completion: per repo ⇄ the local model everywhere" })

-- Copilot: toggle inline ghost-text vs cmp-menu suggestions
map("n", "<leader>tp", function()
  local suggestion = require("copilot.suggestion")
  local cfg = require("copilot.config").suggestion
  if cfg.enabled then
    cfg.enabled = false
    cfg.auto_trigger = false
    suggestion.dismiss()
    suggestion.teardown()
    vim.notify("Copilot: cmp menu mode", vim.log.levels.INFO)
  else
    cfg.enabled = {{SHOW_WELCOME}}
    cfg.auto_trigger = {{SHOW_WELCOME}}
    suggestion.setup()
    vim.notify("Copilot: inline suggestions mode", vim.log.levels.INFO)
  end
end, { desc = "Copilot toggle inline/cmp" })

-- Undotree
map("n", "<leader>u", "<cmd>UndotreeToggle<cr>", { desc = "Undotree" })

-- Diffview
map("n", "<leader>gd", "<cmd>DiffviewOpen<cr>", { desc = "Git diff view" })
map("n", "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", { desc = "Git file history" })
map("n", "<leader>gq", "<cmd>DiffviewClose<cr>", { desc = "Close diff view" })

-- Bufferline navigation
map("n", "H", "<cmd>BufferLineCyclePrev<cr>", { desc = "Prev buffer" })
map("n", "L", "<cmd>BufferLineCycleNext<cr>", { desc = "Next buffer" })
map("n", "<leader>bd", function()
  local cur = vim.api.nvim_get_current_buf()
  local bufs = vim.iter(vim.api.nvim_list_bufs()):filter(function(b)
    return vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted
  end):totable()
  if #bufs <= 1 then
    vim.cmd("enew")
    if vim.api.nvim_buf_is_valid(cur) and cur ~= vim.api.nvim_get_current_buf() then
      vim.cmd("bdelete " .. cur)
    end
  else
    vim.cmd("bprevious | bdelete #")
  end
end, { desc = "Close buffer" })
map("n", "<leader>bo", "<cmd>BufferLineCloseOthers<cr>", { desc = "Close other buffers" })
map("n", "<leader>bl", "<cmd>BufferLineCloseRight<cr>", { desc = "Close buffers to right" })
map("n", "<leader>bh", "<cmd>BufferLineCloseLeft<cr>", { desc = "Close buffers to left" })

-- Window management
map("n", "<leader>v", "<cmd>vsplit<cr>", { desc = "Vertical split" })
map("n", "<leader>ss", "<cmd>split<cr>", { desc = "Horizontal split" })
map("n", "<C-Left>", "<cmd>vertical resize -5<cr>", { desc = "Shrink window" })
map("n", "<C-Right>", "<cmd>vertical resize +5<cr>", { desc = "Grow window" })
map("n", "<C-Up>", "<cmd>resize +3<cr>", { desc = "Grow window height" })
map("n", "<C-Down>", "<cmd>resize -3<cr>", { desc = "Grow window height" })

-- Terminal mode navigation (escape terminal capture to move between splits)
map("t", "<C-h>", "<C-\\><C-n><C-w>h", { desc = "Move to left split" })
map("t", "<C-l>", "<C-\\><C-n><C-w>l", { desc = "Move to right split" })
map("t", "<C-j>", "<C-\\><C-n><C-w>j", { desc = "Move to lower split" })
map("t", "<C-k>", "<C-\\><C-n><C-w>k", { desc = "Move to upper split" })

-- AI keymaps (Avante / CodeCompanion) live in those plugin specs' `keys`, so they exist only when enabled

-- Lazygit
map("n", "<leader>gg", "<cmd>LazyGit<cr>", { desc = "LazyGit" })

-- Persistence (sessions)
map("n", "<leader>qs", function() require("persistence").load() end, { desc = "Restore session (cwd)" })
map("n", "<leader>ql", function() require("persistence").load({ last = {{SHOW_WELCOME}} }) end, { desc = "Restore last session" })
map("n", "<leader>qd", function() require("persistence").stop() end, { desc = "Stop session recording" })

-- Zen mode
map("n", "<leader>z", "<cmd>ZenMode<cr>", { desc = "Zen Mode" })

-- === QoL ===

-- Navigate splits with Ctrl+hjkl (no Ctrl+w prefix needed)
map("n", "<C-h>", "<C-w>h", { desc = "Focus left split" })
map("n", "<C-j>", "<C-w>j", { desc = "Focus below split" })
map("n", "<C-k>", "<C-w>k", { desc = "Focus above split" })
map("n", "<C-l>", "<C-w>l", { desc = "Focus right split" })

-- Quick close window
map("n", "<leader>qq", function()
  local wins = vim.iter(vim.api.nvim_tabpage_list_wins(0)):filter(function(w)
    local buf = vim.api.nvim_win_get_buf(w)
    return vim.bo[buf].filetype ~= "neo-tree"
  end):totable()
  if #wins <= 1 then
    -- last file window: close the buffer instead of the window
    vim.cmd("enew")
  else
    vim.cmd("close")
  end
end, { desc = "Close window" })
map("n", "<leader>o", "<cmd>only<cr>", { desc = "Unsplit (keep only this window)" })

-- Esc clears search highlights
map("n", "<Esc>", "<cmd>nohlsearch<cr>", { desc = "Clear search highlight" })

-- Esc exits terminal mode
map("t", "<Esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })

-- Move selected lines up/down with Alt+j/k
map("v", "<A-j>", ":m '>+1<cr>gv=gv", { desc = "Move selection down" })
map("v", "<A-k>", ":m '<-2<cr>gv=gv", { desc = "Move selection up" })

-- Keep visual selection when indenting
map("v", "<", "<gv", { desc = "Indent left and reselect" })
map("v", ">", ">gv", { desc = "Indent right and reselect" })

-- Centered scrolling (cursor stays mid-screen)
map("n", "<C-d>", "<C-d>zz", { desc = "Scroll down (centered)" })
map("n", "<C-u>", "<C-u>zz", { desc = "Scroll up (centered)" })
map("n", "n", "nzzzv", { desc = "Next search result (centered)" })
map("n", "N", "Nzzzv", { desc = "Prev search result (centered)" })

-- Quick save
map("n", "<leader>w", "<cmd>w<cr>", { desc = "Save file" })

-- Select last paste
map("n", "gp", "`[v`]", { desc = "Select last paste" })

-- Move line up/down in normal mode
map("n", "<A-j>", "<cmd>m .+1<cr>==", { desc = "Move line down" })
map("n", "<A-k>", "<cmd>m .-2<cr>==", { desc = "Move line up" })

-- Make file executable
map("n", "<leader>X", "<cmd>!chmod +x %<cr>", { silent = {{SHOW_WELCOME}}, desc = "Make file executable" })

-- Toggle diagnostic virtual text. Both toggles read state back from vim.diagnostic.config() rather
-- than shadow booleans, so they can't drift from the real config (or from each other).
map("n", "<leader>td", function()
  local on = not vim.diagnostic.config().virtual_text
  vim.diagnostic.config({ virtual_text = on and Paper.virtual_text or false })
  vim.notify("Diagnostic virtual text: " .. (on and "ON" or "OFF"))
end, { desc = "Toggle diagnostic virtual text" })

-- Toggle diagnostic lines (core virtual_lines: multi-line diagnostics below error lines)
map("n", "<leader>tl", function()
  local on = not vim.diagnostic.config().virtual_lines
  vim.diagnostic.config({ virtual_lines = on, virtual_text = not on and Paper.virtual_text or false })
  vim.notify("Diagnostic lines: " .. (on and "ON" or "OFF"))
end, { desc = "Toggle diagnostic lines" })

-- Comment folding: collapse comment blocks (// runs + /* */ walls) so the logic is readable —
-- the engine's comment walls can eat most of the screen. Treesitter-driven. On by default: every
-- file you open arrives with its comments folded; Space tc switches that off (and back on) for
-- this window and every file after, and the choice is remembered. zo/za peeks one, zR opens all,
-- Space tC refolds all. Code lines never fold. Off restores the window's previous folding options.
function _G.FoxCommentFoldExpr()
  local first = (vim.fn.getline(vim.v.lnum):find("%S") or 1) - 1
  local ok, node = pcall(vim.treesitter.get_node, { pos = { vim.v.lnum - 1, first } })
  if ok and node then
    while node do
      if node:type():find("comment") then return "1" end
      node = node:parent()
    end
  end
  return "0"
end
local comment_fold_state = vim.fn.stdpath("state") .. "/fox-comment-fold"
local comment_fold_auto = vim.fn.filereadable(comment_fold_state) == 0 or vim.fn.readfile(comment_fold_state)[1] ~= "off"
local function save_comment_fold_auto(on)
  comment_fold_auto = on
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(comment_fold_state, ":h"), "p")
  local temp = comment_fold_state .. ".tmp"
  if vim.fn.writefile({ on and "on" or "off" }, temp) == 0 then (vim.uv or vim.loop).fs_rename(temp, comment_fold_state) end
end
local fold_options = { "foldmethod", "foldexpr", "foldenable", "foldlevel", "foldtext" }
local function refold_comments(silent)
  if Paper.enabled and not Paper.file_buffer(vim.api.nvim_get_current_buf()) then return end
  -- Reparse edits before rebuilding folds; an opened comment can otherwise
  -- retain the old range until Treesitter's next update.
  pcall(function() vim.treesitter.get_parser():parse() end)
  if not vim.w.fox_comment_fold then
    -- A split copies its parent's comment-fold options; restoring those would leave it folded.
    local inherited = vim.wo.foldexpr == "v:lua.FoxCommentFoldExpr()"
    local previous = {}
    for _, option in ipairs(fold_options) do
      previous[option] = inherited and vim.go[option] or vim.wo[option]
    end
    vim.w.fox_comment_fold_previous = previous
  end
  vim.w.fox_comment_fold = true
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.FoxCommentFoldExpr()"
  if Paper.enabled then vim.wo.foldtext = "v:lua.FoxPaperFoldText()" end
  vim.wo.foldlevel = 0
  vim.wo.foldenable = true
  vim.cmd("normal! zX") -- zx would immediately reopen the fold containing the cursor.
  if silent ~= true then vim.notify("Comments refolded · zo opens one · zR opens all · Space tC refolds") end
end
local function unfold_comments()
  local previous = vim.w.fox_comment_fold_previous
  vim.w.fox_comment_fold = false
  if previous then
    for _, option in ipairs({ "foldexpr", "foldtext", "foldlevel", "foldmethod", "foldenable" }) do
      vim.wo[option] = previous[option]
    end
  end
  vim.w.fox_comment_fold_previous = nil
end
map("n", "<leader>tc", function()
  if Paper.enabled and not Paper.file_buffer(vim.api.nvim_get_current_buf()) then return end
  if vim.w.fox_comment_fold then
    unfold_comments()
    save_comment_fold_auto(false)
    vim.notify("Comment folding: OFF · new files open unfolded")
  else
    save_comment_fold_auto(true)
    refold_comments(true)
    vim.notify("Comment folding: ON · new files open folded")
  end
end, { desc = "Toggle comment folding" })
map("n", "<leader>tC", refold_comments, { desc = "Refold all comments" })
vim.api.nvim_create_user_command("CommentRefold", function() refold_comments() end, { desc = "Enable and refold all comments in this window" })
-- Prefold: the first time a file is shown in a window, once Treesitter has its parser. Coming back
-- to a file keeps whatever you opened. Very large files are skipped (foldexpr asks Treesitter per line).
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("foxml_comment_prefold", { clear = true }),
  callback = function(args)
    local buf = args.buf
    vim.schedule(function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) ~= buf or not vim.api.nvim_buf_is_valid(buf) then return end
      if vim.bo[buf].buftype ~= "" or not vim.bo[buf].buflisted or vim.bo[buf].filetype:match("^fox%-symdeps") then return end
      local seen = vim.w[win].fox_comment_fold_seen or {}
      if seen[tostring(buf)] then return end
      seen[tostring(buf)] = true
      vim.w[win].fox_comment_fold_seen = seen
      if not comment_fold_auto then
        if vim.w[win].fox_comment_fold then unfold_comments() end
        return
      end
      if vim.api.nvim_buf_line_count(buf) > 20000 then return end
      local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
      if ok and parser then refold_comments(true) end
    end)
  end,
})

-- === Per-project settings ===

-- Indentation follows each file, not one global default. Precedence: .editorconfig (core) > the file's own
-- existing indentation > for an empty C/C++ file, the project's clang-format style unless that project
-- disables formatting > the ftplugin default. (The trader's .clang-format is DisableFormat: true, yet
-- clang-format still reports a nominal LLVM 2-space style there, so that style must not be applied.)
local function sniff_indent(buf)
  local tab_lines, space_lines, deltas, prev = 0, 0, {}, 0
  local lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(vim.api.nvim_buf_line_count(buf), 2000), false)
  for _, line in ipairs(lines) do
    local ws = line:match("^(%s*)%S")
    -- skip blank lines and " * " block-comment continuations (1-space offsets, not nesting)
    if ws and not line:match("^%s+%*") then
      if ws:find("\t", 1, true) then
        tab_lines = tab_lines + 1
      else
        if #ws > 0 then space_lines = space_lines + 1 end
        local d = #ws - prev
        if d == 2 or d == 3 or d == 4 or d == 8 then deltas[d] = (deltas[d] or 0) + 1 end
        prev = #ws
      end
    end
  end
  if tab_lines >= 3 and tab_lines > space_lines then return { expandtab = false } end
  local best, n = nil, 2 -- need 3+ indent steps of the same width before trusting it
  for _, d in ipairs({ 4, 2, 8, 3 }) do
    if (deltas[d] or 0) > n then best, n = d, deltas[d] end
  end
  return best and { expandtab = true, shiftwidth = best } or nil
end

local clang_format_style = {} -- per directory; false = no usable style (absent tool, error, DisableFormat)
local function clang_format_indent(file)
  local dir = vim.fs.dirname(file)
  if clang_format_style[dir] == nil then
    clang_format_style[dir] = false
    if vim.fn.executable("clang-format") == 1 then
      local res = vim.system({ "clang-format", "--dump-config", "--assume-filename=" .. file }, { text = true }):wait(2000)
      local cfg = res.code == 0 and res.stdout or ""
      local width = tonumber(cfg:match("\nIndentWidth:%s*(%d+)"))
      if width and not cfg:match("\nDisableFormat:%s*true") then
        clang_format_style[dir] = { expandtab = cfg:match("\nUseTab:%s*Never") ~= nil, shiftwidth = width }
      end
    end
  end
  return clang_format_style[dir] or nil
end

vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
  group = vim.api.nvim_create_augroup("foxml_indent", { clear = true }),
  callback = function(args)
    local buf = args.buf
    if vim.bo[buf].buftype ~= "" then return end
    -- scheduled: the ftplugin (FileType) and core editorconfig both run later in this same read
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local ec = vim.b[buf].editorconfig
      if ec and (ec.indent_style or ec.indent_size) then return end
      local got = sniff_indent(buf)
      if not got and (vim.bo[buf].filetype == "c" or vim.bo[buf].filetype == "cpp") then
        got = clang_format_indent(vim.api.nvim_buf_get_name(buf))
      end
      if not got then return end
      vim.bo[buf].expandtab = got.expandtab
      if got.shiftwidth then
        vim.bo[buf].shiftwidth = got.shiftwidth
        vim.bo[buf].tabstop = got.shiftwidth
      end
    end)
  end,
})

-- Per-project config: the nearest .nvim.lua above a file runs once per session when trusted. nvim 0.12's
-- trust prompt has no "allow" for files (only view, then :trust), and every edit revokes trust, so this
-- replaces that blocking prompt: an untrusted (new or changed) file gets one notice per session,
-- :ProjectTrust trusts and loads it, and saving a .nvim.lua in nvim trusts it (you just wrote it).
-- Core 'exrc' only runs at startup from the launch dir, so it never sees a project opened later.
local project_rc_ran = {} -- rc path -> true (ran) | false (noticed, untrusted)
local function project_rc(file)
  return vim.fs.find(".nvim.lua", { upward = true, path = vim.fs.dirname(file), type = "file", stop = vim.env.HOME })[1]
end
-- reads nvim's trust db ("<sha256> <path>" or "! <path>" lines); anything unexpected counts as untrusted
local function rc_trust(rc)
  local real = vim.uv.fs_realpath(rc)
  local okd, lines = pcall(vim.fn.readfile, vim.fn.stdpath("state") .. "/trust")
  local okb, blob = pcall(vim.fn.readblob, rc)
  if not (real and okd and okb) then return "untrusted" end
  local hash = vim.fn.sha256(blob)
  for _, line in ipairs(lines) do
    if line == hash .. " " .. real then return "trusted" end
    if line == "! " .. real then return "denied" end
  end
  return "untrusted"
end
local function run_project_rc(rc)
  project_rc_ran[rc] = true
  local chunk, err = loadfile(rc)
  if chunk then
    local ok, run_err = pcall(chunk)
    err = not ok and run_err or nil
  end
  if err then vim.notify(".nvim.lua: " .. tostring(err), vim.log.levels.ERROR) end
end
vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("foxml_project_rc", { clear = true }),
  callback = function(args)
    local file = vim.api.nvim_buf_get_name(args.buf)
    if vim.bo[args.buf].buftype ~= "" or file == "" then return end
    local rc = project_rc(file)
    if not rc or project_rc_ran[rc] ~= nil then return end
    local state = rc_trust(rc)
    if state == "trusted" then return run_project_rc(rc) end
    project_rc_ran[rc] = false
    if state == "untrusted" then
      vim.notify(rc .. " is new or changed. Look it over, then :ProjectTrust to load it.", vim.log.levels.WARN)
    end
  end,
})
vim.api.nvim_create_user_command("ProjectTrust", function()
  local file = vim.api.nvim_buf_get_name(0)
  local rc = vim.fs.basename(file) == ".nvim.lua" and file or (file ~= "" and project_rc(file))
  if not rc then return vim.notify("No .nvim.lua above this file", vim.log.levels.WARN) end
  vim.secure.trust({ action = "allow", path = rc })
  run_project_rc(rc)
  vim.notify("Trusted and loaded " .. rc)
end, { desc = "Trust and load this project's .nvim.lua" })
vim.api.nvim_create_autocmd("BufWritePost", {
  group = "foxml_project_rc",
  pattern = ".nvim.lua",
  callback = function(args)
    vim.secure.trust({ action = "allow", path = args.file })
    vim.notify("Trusted " .. args.file .. " (you just saved it). :ProjectTrust applies it now.")
  end,
})

-- Files under a project's shortcut folder (the trader's tests/ tools/ plans/ are symlinks into its workspace
-- repo) get realpath buffer names: nvim resolves symlinked dirs, so even opening FoxML_Trader_v2/tests/x.cpp
-- names the buffer .../tick-trader-percore-workspace/tests/x.cpp. clang-format then misses the trader's
-- .clang-format (DisableFormat) and a save would reflow engine test code (365 lines of test_common.hpp,
-- measured). Formatting such a file as its project path keeps the project's rules.
local alias_dirs -- realpath of a symlinked top-level project folder -> the same folder through the project
local function project_path(file)
  if not alias_dirs then
    alias_dirs = {}
    local code = vim.fn.expand("~/code")
    for proj, kind in vim.fs.dir(code) do
      if kind == "directory" then
        for name, k in vim.fs.dir(code .. "/" .. proj) do
          local link = code .. "/" .. proj .. "/" .. name
          local real = k == "link" and vim.uv.fs_realpath(link)
          local st = real and vim.uv.fs_stat(real)
          if st and st.type == "directory" then
            alias_dirs[real] = alias_dirs[real] == nil and link or false -- linked twice: ambiguous, leave it
          end
        end
      end
    end
  end
  for real, link in pairs(alias_dirs) do
    if link and vim.startswith(file, real .. "/") then return link .. file:sub(#real + 1) end
  end
end

-- conform's clang-format args, with the project path standing in for a realpath filename
local function format_name(ctx) return project_path(ctx.filename) or ctx.filename end
require("conform").formatters["clang-format"] = {
  args = function(_, ctx) return { "-assume-filename", format_name(ctx) } end,
  range_args = function(_, ctx)
    local from, to = require("conform.util").get_offsets_from_range(ctx.buf, ctx.range)
    return { "-assume-filename", format_name(ctx), "--offset", tostring(from), "--length", tostring(to - from) }
  end,
}

vim.keymap.set({"n", "v"}, "<leader>cf", function()
  require("conform").format({async = true, lsp_format = "fallback"})
end, {desc = "Format"})

-- Find files / grep search the CURRENT file's project (its .git, else a build marker), not nvim's cwd:
-- `nvim <file>` launched from ~/code searched all of ~/code (9k files incl. old copies), because
-- project.nvim loads after the first buffer. A file in a project's shortcut folder counts as that project.
local function file_project()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then return vim.uv.cwd() end
  return vim.fs.root(project_path(name) or name, { ".git", "compile_commands.json", "CMakeLists.txt", "Makefile" })
    or vim.uv.cwd()
end
map("n", "<leader>ff", function() require("telescope.builtin").find_files({ cwd = file_project() }) end,
  { desc = "Find files (this project)" })
map("n", "<leader>fg", function() require("telescope.builtin").live_grep({ cwd = file_project() }) end,
  { desc = "Grep (this project)" })

-- Highlight on yank (brief flash)
vim.api.nvim_create_autocmd("TextYankPost", {
  callback = function(args)
    if Paper.enabled and not Paper.file_buffer(args.buf) then return end
    vim.highlight.on_yank({ higroup = Paper.enabled and "FoxPaperYank" or "IncSearch", timeout = 200 })
  end,
})

-- Remember cursor position when reopening files
vim.api.nvim_create_autocmd("BufReadPost", {
  callback = function()
    local mark = vim.api.nvim_buf_get_mark(0, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(0) then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Strip trailing whitespace on save
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*",
  callback = function()
    local pos = vim.api.nvim_win_get_cursor(0)
    vim.cmd([[%s/\s\+$//e]])
    pcall(vim.api.nvim_win_set_cursor, 0, pos)
  end,
})

-- Auto-reload buffers changed on disk (Claude Code, git checkout, etc.)
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
  command = "if mode() != 'c' | checktime | endif",
})
-- The other Claudes on this machine: footprints, notes, what changed, follow (shared/nvim_lua/foxml/claude.lua)
pcall(function() require("foxml.claude").setup() end)

-- Notify when a file reloads so it's not silent/confusing
vim.api.nvim_create_autocmd("FileChangedShellPost", {
  callback = function() vim.notify("File reloaded (changed on disk)", vim.log.levels.INFO) end,
})
