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
vim.opt.colorcolumn = "80"        -- visual ruler only; never reflows text
vim.opt.smoothscroll = {{SHOW_WELCOME}}
vim.opt.cursorline = {{SHOW_WELCOME}}
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
  fg        = "#{{FG}}",
  fg_pastel = "#{{FG_PASTEL}}",
  fg_dim    = "#{{FG_DIM}}",
  comment   = "#{{COMMENT}}",
  peach     = "#{{PRIMARY}}",
  pink      = "#{{SECONDARY}}",
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
  clay      = "#{{CLAY}}",
  diff_add  = "#{{DIFF_ADD}}",
  diff_chg  = "#{{DIFF_CHANGE}}",
  diff_del  = "#{{DIFF_DELETE}}",
  diff_txt  = "#{{DIFF_TEXT}}",
  ts_ctx    = "#{{TMUX_ACTIVE_BG}}",
  none      = "none",
}

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
      return data.model:gsub("^ollama/", "")
    end
  end
  return fallback
end

local global_model = get_global_model("qwen2.5-coder:7b")

local plugins = {
  { "nvim-lualine/lualine.nvim",           dependencies = { "nvim-tree/nvim-web-devicons" } },
  { "lukas-reineke/indent-blankline.nvim", main = "ibl",
    config = function()
      -- Define highlight groups before ibl.setup so they exist at init time
      local hl = vim.api.nvim_set_hl
      hl(0, "RainbowIndent1", { fg = "#4d3a2e" })
      hl(0, "RainbowIndent2", { fg = "#4a3040" })
      hl(0, "RainbowIndent3", { fg = "#2e3d2e" })
      hl(0, "RainbowIndent4", { fg = "#3d3a24" })
      hl(0, "RainbowIndent5", { fg = "#2a3540" })
      hl(0, "RainbowIndent6", { fg = "#402a2a" })
      require("ibl").setup({
        indent = {
          highlight = {
            "RainbowIndent1", "RainbowIndent2", "RainbowIndent3",
            "RainbowIndent4", "RainbowIndent5", "RainbowIndent6",
          },
        },
        scope = { enabled = {{SHOW_WELCOME}}, show_start = false, show_end = false },
      })
    end },

  -- Core editing
  { "numToStr/Comment.nvim",               config = {{SHOW_WELCOME}} },
  { "windwp/nvim-autopairs",               config = {{SHOW_WELCOME}} },
  { "folke/which-key.nvim",                event = "VeryLazy",
    opts = {} },

  -- Fuzzy finding
  {
    "nvim-telescope/telescope.nvim",
    branch = "0.1.x",
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
          folder_closed = "",
          folder_open = "",
          folder_empty = "",
        },
        name = {
          trailing_slash = false,
          use_git_status_colors = {{SHOW_WELCOME}},
        },
        git_status = {
          symbols = {
            added     = "",
            modified  = "",
            deleted   = "",
            renamed   = "",
            untracked = "",
            ignored   = "",
            unstaged  = "",
            staged    = "",
            conflict  = "",
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
        show_buffer_close_icons = false,
        show_close_icon = false,
      },
      highlights = {
        fill = { bg = P.bg_deep },
        background = { fg = P.comment, bg = P.bg_deep },
        buffer_selected = { fg = P.fg, bg = P.bg, bold = {{SHOW_WELCOME}} },
        buffer_visible = { fg = P.comment, bg = P.bg_deep },
        separator = { fg = P.bg_hl, bg = P.bg_deep },
        separator_selected = { fg = P.bg_hl, bg = P.bg },
        separator_visible = { fg = P.bg_hl, bg = P.bg_deep },
        indicator_selected = { fg = P.peach, bg = P.bg },
        modified = { fg = P.yellow, bg = P.bg_deep },
        modified_selected = { fg = P.yellow, bg = P.bg },
        modified_visible = { fg = P.yellow, bg = P.bg_deep },
        tab = { fg = P.comment, bg = P.bg_deep },
        tab_selected = { fg = P.peach, bg = P.bg, bold = {{SHOW_WELCOME}} },
        tab_separator = { fg = P.bg_hl, bg = P.bg_deep },
        tab_separator_selected = { fg = P.bg_hl, bg = P.bg },
        duplicate = { fg = P.comment, bg = P.bg_deep, italic = {{SHOW_WELCOME}} },
        duplicate_selected = { fg = P.fg, bg = P.bg, italic = {{SHOW_WELCOME}} },
        duplicate_visible = { fg = P.comment, bg = P.bg_deep, italic = {{SHOW_WELCOME}} },
        diagnostic_selected = { bold = {{SHOW_WELCOME}} },
      },
    },
  },

  -- Git
  {
    "lewis6991/gitsigns.nvim",
    opts = {
      current_line_blame = {{SHOW_WELCOME}},
      current_line_blame_opts = { delay = 300, virt_text_pos = "eol" },
      current_line_blame_formatter = "  <author>, <author_time:%R> · <summary>",
    },
  },

  -- Syntax / Treesitter
  -- Pin to master: the main branch dropped require("nvim-treesitter.configs") in
  -- favor of a rewritten setup API. master keeps the legacy configs.setup() shape
  -- our init.lua below uses. Same pin on textobjects (its main branch broke too).
  { "nvim-treesitter/nvim-treesitter",  branch = "master", build = ":TSUpdate" },

  -- LSP + Autocomplete
  { "neovim/nvim-lspconfig" },
  { "williamboman/mason.nvim",          build = ":MasonUpdate" },
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
  -- Diagnostic lines (multi-line diagnostics below error, toggled with keybind)
  {
    "https://git.sr.ht/~whynothugo/lsp_lines.nvim",
    event = "LspAttach",
    config = function()
      local lsp_lines = require("lsp_lines")
      lsp_lines.setup()
      -- Start disabled — toggle with <leader>tl
      vim.diagnostic.config({ virtual_lines = false })
    end,
  },

  -- TODO highlights
  { "folke/todo-comments.nvim",         dependencies = { "nvim-lua/plenary.nvim" },       opts = {} },

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

  {
    "stevearc/overseer.nvim",
    cmd = "OverseerRun",
    opts = {},
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
      cmake_compile_commands_options = { action = "soft_link", target = vim.uv.cwd() },
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
      format_on_save = { lsp_format = "fallback", timeout_ms = 500 },
      formatters_by_ft = { c = { "clang-format" }, cpp = { "clang-format" } },
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

  -- LaTeX
  {
    "lervag/vimtex",
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
    branch = "master",
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

  -- Beacon (flash cursor on jump for visual tracking)
  {
    "danilamihailov/beacon.nvim",
    event = { "BufReadPost", "BufWinEnter" },
    config = function()
      vim.g.beacon_size = 30
      vim.g.beacon_fade = {{SHOW_WELCOME}}
      vim.g.beacon_shrink = {{SHOW_WELCOME}}
      vim.g.beacon_minimal_jump = 1
    end,
  },

  -- Illuminate (highlight other occurrences of word under cursor)
  {
    "RRethy/vim-illuminate",
    event = "BufReadPost",
    opts = {
      delay = 200,
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
  },

  -- CodeCompanion (Inline AI, Chat, and Agents using local Ollama)
  {
    "olimorris/codecompanion.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
    config = function()
      require("codecompanion").setup({
        adapters = {
          ollama = function()
            return require("codecompanion.adapters").extend("ollama", {
              schema = {
                model = {
                  default = get_global_model("qwen2.5-coder:14b"), -- Use global or smart default
                },
              },
            })
          end,
        },
        strategies = {
          chat = { adapter = "ollama" },
          inline = { adapter = "ollama" },
          agent = { adapter = "ollama" },
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
        keymap = {
          accept = "<C-l>",       -- Ctrl+l to accept
          accept_word = "<C-;>",  -- Ctrl+; to accept word
          accept_line = "<C-'>",  -- Ctrl+' to accept line
          next = "<C-]>",
          prev = "<C-k>",
          dismiss = "<C-j>",
        },
      },
      panel = { enabled = false },
      filetypes = {
        ["*"] = {{SHOW_WELCOME}},
        ["AvanteInput"] = false,
        ["Avante"] = false,
        ["."] = false,
      },
    },
  },

  -- Avante (Cursor-style AI panel, using Copilot provider)
  {
    "yetone/avante.nvim",
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
      provider = "ollama",
      vendors = {
        ollama = {
          __inherited_from = "openai",
          api_key_name = "",
          endpoint = "http://localhost:11434/v1",
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
            じしˍ,)ノ

    ~ F o x M L ~
          ]],
          keys = {
            { icon = " ", key = "f", desc = "Find File", action = ":Telescope find_files" },
            { icon = " ", key = "g", desc = "Find Text", action = ":Telescope live_grep" },
            { icon = " ", key = "r", desc = "Recent Files", action = ":Telescope oldfiles" },
            { icon = " ", key = "p", desc = "Projects", action = function() require("telescope").extensions.projects.projects({}) end },
            { icon = " ", key = "s", desc = "Restore Session", action = function() require("persistence").load() end },
            { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy" },
            { icon = " ", key = "q", desc = "Quit", action = ":qa" },
          },
        },
      },
      notifier = { enabled = {{SHOW_WELCOME}}, style = "minimal" },
      indent = { enabled = false },
    },
  },

  -- Claude Code (AI terminal integration)
  {
    "coder/claudecode.nvim",
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

  -- Dropbar (breadcrumb navigation)
  {
    "Bekaboo/dropbar.nvim",
    event = { "BufReadPost", "BufNewFile" },
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
          cmdline = { pattern = "^:", icon = " ", lang = "vim" },
          search_down = { kind = "search", pattern = "^/", icon = " ", lang = "regex" },
          search_up = { kind = "search", pattern = "^%?", icon = " ", lang = "regex" },
          filter = { pattern = "^:%s*!", icon = " ", lang = "bash" },
          lua = { pattern = { "^:%s*lua%s+", "^:%s*lua%s*=%s*", "^:%s*=%s*" }, icon = " ", lang = "lua" },
        },
      },
      messages = { enabled = {{SHOW_WELCOME}}, view = "mini", view_search = "virtualtext" },
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
        color = P.bg_hl,
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
    opts = { calm_down = {{SHOW_WELCOME}}, nearest_only = {{SHOW_WELCOME}} },
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
  hl("NormalFloat",  { fg = P.fg, bg = P.bg })
  hl("FloatBorder",  { fg = P.peach, bg = P.none })
  hl("FloatTitle",   { fg = P.peach, bg = P.none, bold = {{SHOW_WELCOME}} })
  hl("CursorLine",  { bg = P.bg_hl })
  hl("CursorColumn", { bg = P.bg_hl })
  hl("ColorColumn",  { bg = P.bg_hl })
  hl("Visual",       { bg = P.sel })
  hl("VisualNOS",    { bg = P.sel })
  hl("LineNr",       { fg = P.surface })
  hl("CursorLineNr", { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("SignColumn",   { fg = P.surface, bg = P.none })
  hl("EndOfBuffer",  { fg = P.bg })
  hl("VertSplit",    { fg = P.yellow_br, bg = P.none })
  hl("WinSeparator", { fg = P.yellow_br, bg = P.none })
  hl("Pmenu",        { fg = P.fg, bg = P.bg })
  hl("PmenuSel",     { bg = P.surface })
  hl("PmenuSbar",    { bg = P.bg_hl })
  hl("PmenuThumb",   { bg = P.comment })
  hl("WildMenu",     { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("StatusLine",   { fg = P.warm, bg = P.none })
  hl("StatusLineNC", { fg = P.surface, bg = P.none })
  hl("TabLine",      { fg = P.comment, bg = P.bg_deep })
  hl("TabLineSel",   { fg = P.peach, bg = P.bg_hl, bold = {{SHOW_WELCOME}} })
  hl("TabLineFill",  { bg = P.bg_deep })
  hl("WinBar",       { fg = P.comment, bg = P.none })
  hl("WinBarNC",     { fg = P.surface, bg = P.none })
  hl("Title",        { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("Directory",    { fg = P.cyan })
  hl("Question",     { fg = P.green })
  hl("SpecialKey",   { fg = P.surface })
  hl("NonText",      { fg = P.surface })
  hl("Conceal",      { fg = P.comment })
  hl("Cursor",       { fg = P.bg, bg = P.fg })
  hl("lCursor",      { fg = P.bg, bg = P.fg })
  hl("CursorIM",     { fg = P.bg, bg = P.fg })

  -- ── Search & Match ──
  hl("Search",       { fg = P.bg, bg = P.peach })
  hl("IncSearch",    { fg = P.bg, bg = P.pink })
  hl("CurSearch",    { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("Substitute",   { fg = P.bg, bg = P.red })
  hl("MatchParen",   { fg = P.pink, bold = {{SHOW_WELCOME}}, underline = {{SHOW_WELCOME}} })

  -- ── Fold ──
  hl("Folded",       { fg = P.comment, bg = P.bg_hl })
  hl("FoldColumn",   { fg = P.surface, bg = P.none })

  -- ── Messages ──
  hl("MsgArea",      { fg = P.warm, bg = P.bg_deep })
  hl("WarningMsg",   { fg = P.wheat, bold = {{SHOW_WELCOME}} })
  hl("ErrorMsg",     { fg = P.clay, bold = {{SHOW_WELCOME}} })
  hl("ModeMsg",      { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("MoreMsg",      { fg = P.green })

  -- ── Built-in syntax groups ──
  hl("Comment",      { fg = P.comment, italic = {{SHOW_WELCOME}} })
  hl("Constant",     { fg = P.peach })
  hl("String",       { fg = P.green })
  hl("Character",    { fg = P.green })
  hl("Number",       { fg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("Boolean",      { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("Float",        { fg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("Identifier",   { fg = P.fg })
  hl("Function",     { fg = P.peach })
  hl("Statement",    { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("Conditional",  { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("Repeat",       { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("Label",        { fg = P.pink })
  hl("Operator",     { fg = P.pink })
  hl("Keyword",      { fg = P.pink, bold = {{SHOW_WELCOME}} })
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
  hl("Todo",         { fg = P.bg, bg = P.yellow, bold = {{SHOW_WELCOME}} })

  -- ── Diagnostics ──
  hl("DiagnosticError",          { fg = P.clay })
  hl("DiagnosticWarn",           { fg = P.wheat })
  hl("DiagnosticInfo",           { fg = P.peach })
  hl("DiagnosticHint",           { fg = P.green })
  hl("DiagnosticOk",             { fg = P.green })
  hl("DiagnosticUnderlineError", { undercurl = {{SHOW_WELCOME}}, sp = P.clay })
  hl("DiagnosticUnderlineWarn",  { undercurl = {{SHOW_WELCOME}}, sp = P.wheat })
  hl("DiagnosticUnderlineInfo",  { undercurl = {{SHOW_WELCOME}}, sp = P.peach })
  hl("DiagnosticUnderlineHint",  { undercurl = {{SHOW_WELCOME}}, sp = P.green })
  hl("DiagnosticUnderlineOk",    { undercurl = {{SHOW_WELCOME}}, sp = P.green })
  hl("DiagnosticVirtualTextError", { fg = P.clay, bg = P.diff_del, bold = {{SHOW_WELCOME}} })
  hl("DiagnosticVirtualTextWarn",  { fg = P.wheat, bg = P.diff_chg })
  hl("DiagnosticVirtualTextInfo",  { fg = P.peach })
  hl("DiagnosticVirtualTextHint",  { fg = P.green })
  hl("DiagnosticSignError",       { fg = P.clay })
  hl("DiagnosticSignWarn",        { fg = P.wheat })
  hl("DiagnosticSignInfo",        { fg = P.peach })
  hl("DiagnosticSignHint",        { fg = P.green })
  hl("DiagnosticLineNrError",    { fg = P.clay, bold = {{SHOW_WELCOME}} })
  hl("DiagnosticLineNrWarn",     { fg = P.wheat, bold = {{SHOW_WELCOME}} })
  hl("DiagnosticLineNrInfo",     { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("DiagnosticLineNrHint",     { fg = P.green, bold = {{SHOW_WELCOME}} })
  hl("DiagnosticLineError",     { bg = "#3d1a1a" })
  hl("DiagnosticLineWarn",      { bg = "#3d2e1a" })
  hl("DiagnosticLineInfo",      { bg = P.bg_hl })
  hl("DiagnosticLineHint",      { bg = P.bg_hl })

  -- ── Treesitter ──
  hl("@variable",            { fg = P.fg })
  hl("@variable.builtin",    { fg = P.pink })
  hl("@variable.parameter",  { fg = P.yellow_br })
  hl("@variable.member",     { fg = P.green })
  hl("@constant",            { fg = P.yellow })
  hl("@constant.builtin",    { fg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("@constant.macro",      { fg = P.yellow })
  hl("@module",              { fg = P.pink })
  hl("@string",              { fg = P.green })
  hl("@string.escape",       { fg = P.cyan })
  hl("@string.regex",        { fg = P.cyan })
  hl("@string.special",      { fg = P.cyan })
  hl("@character",           { fg = P.green })
  hl("@number",              { fg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("@number.float",        { fg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("@number.hex",          { fg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("@boolean",             { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("@type",                { fg = P.cyan })
  hl("@type.builtin",        { fg = P.cyan })
  hl("@type.definition",     { fg = P.cyan })
  hl("@type.qualifier",      { fg = P.pink })
  hl("@attribute",           { fg = P.peach })
  hl("@property",            { fg = P.green })
  hl("@function",            { fg = P.peach })
  hl("@function.call",       { fg = P.peach })
  hl("@function.builtin",    { fg = P.peach })
  hl("@function.macro",      { fg = P.pink })
  hl("@function.method",     { fg = P.peach })
  hl("@function.method.call", { fg = P.peach })
  hl("@constructor",         { fg = P.peach })
  hl("@operator",            { fg = P.lavender })
  hl("@keyword",             { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("@keyword.function",    { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("@keyword.operator",    { fg = P.pink })
  hl("@keyword.return",      { fg = P.lavender, bold = {{SHOW_WELCOME}} })
  hl("@keyword.import",      { fg = P.cyan })
  hl("@keyword.conditional", { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("@keyword.repeat",      { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("@keyword.exception",   { fg = P.pink })
  hl("@punctuation",         { fg = P.fg })
  hl("@punctuation.bracket",  { fg = P.sand })
  hl("@punctuation.delimiter", { fg = P.peach })
  hl("@punctuation.special",  { fg = P.pink })
  hl("@comment",             { fg = P.comment, italic = {{SHOW_WELCOME}} })
  hl("@comment.todo",        { fg = P.bg, bg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("@comment.note",        { fg = P.bg, bg = P.green, bold = {{SHOW_WELCOME}} })
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

  -- ── LSP semantic tokens ──
  hl("@lsp.type.class",         { fg = P.cyan })
  hl("@lsp.type.struct",        { fg = P.cyan })
  hl("@lsp.type.enum",          { fg = P.cyan })
  hl("@lsp.type.enumMember",    { fg = P.cyan })
  hl("@lsp.type.interface",     { fg = P.cyan })
  hl("@lsp.type.function",      { fg = P.peach })
  hl("@lsp.type.method",        { fg = P.peach })
  hl("@lsp.type.macro",         { fg = P.pink })
  hl("@lsp.type.decorator",     { fg = P.pink })
  hl("@lsp.type.variable",      { fg = P.fg })
  hl("@lsp.type.parameter",     { fg = P.peach })
  hl("@lsp.type.property",      { link = "@property" })
  hl("@lsp.type.property.c",    { link = "@property" })
  hl("@lsp.type.property.cpp",  { link = "@property" })
  hl("@lsp.type.member",        { link = "@variable.member" })
  hl("@lsp.type.member.c",      { link = "@variable.member" })
  hl("@lsp.type.member.cpp",    { link = "@variable.member" })
  hl("@lsp.type.namespace",     { fg = P.pink })
  hl("@lsp.type.keyword",       { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("@lsp.type.type",          { fg = P.cyan })
  hl("@lsp.type.typeParameter", { fg = P.cyan })
  hl("@lsp.type.comment",       { fg = P.comment, italic = {{SHOW_WELCOME}} })
  hl("@lsp.mod.deprecated",     { strikethrough = {{SHOW_WELCOME}} })
  hl("@lsp.mod.readonly",       { bold = {{SHOW_WELCOME}} })
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
  hl("SpellBad",     { undercurl = {{SHOW_WELCOME}}, sp = P.red })
  hl("SpellCap",     { undercurl = {{SHOW_WELCOME}}, sp = P.yellow })
  hl("SpellRare",    { undercurl = {{SHOW_WELCOME}}, sp = P.cyan })
  hl("SpellLocal",   { undercurl = {{SHOW_WELCOME}}, sp = P.green })

  -- ── Plugin highlights ──

  -- CmpBorder
  hl("CmpBorder", { fg = P.peach, bg = P.none })

  -- Telescope
  hl("TelescopeBorder",        { fg = P.peach })
  hl("TelescopePromptBorder",  { fg = P.pink })
  hl("TelescopeResultsBorder", { fg = P.peach })
  hl("TelescopePreviewBorder", { fg = P.green })
  hl("TelescopePromptTitle",   { fg = P.bg, bg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("TelescopeResultsTitle",  { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("TelescopePreviewTitle",  { fg = P.bg, bg = P.green, bold = {{SHOW_WELCOME}} })

  -- Snacks dashboard
  hl("SnacksDashboardHeader",  { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("SnacksDashboardKey",     { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("SnacksDashboardDesc",    { fg = P.fg })
  hl("SnacksDashboardIcon",    { fg = P.green })
  hl("SnacksDashboardFooter",  { fg = P.comment, italic = {{SHOW_WELCOME}} })

  -- Git signs
  hl("GitSignsAdd",    { fg = P.green })
  hl("GitSignsChange", { fg = P.yellow })
  hl("GitSignsDelete", { fg = P.red })

  -- Flash.nvim
  hl("FlashLabel",    { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("FlashMatch",    { fg = P.fg, bg = P.bg_hl })
  hl("FlashCurrent",  { fg = P.bg, bg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("FlashBackdrop", { fg = P.surface })

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
  hl("WhichKeySeparator", { fg = P.surface })
  hl("WhichKeyNormal",    { bg = P.bg_deep })
  hl("WhichKeyFloat",     { bg = P.bg_deep })
  hl("WhichKeyBorder",    { fg = P.peach, bg = P.bg_deep })
  hl("WhichKeyTitle",     { fg = P.peach, bg = P.bg_deep })
  hl("WhichKeyValue",     { fg = P.comment })

  -- Indent blankline
  hl("IblIndent", { fg = P.bg_hl })
  hl("IblScope",  { fg = "#e0b878" })

  -- Rainbow indent guides (muted versions of rainbow delimiter colors)
  hl("RainbowIndent1", { fg = "#4d3a2e" })  -- muted peach
  hl("RainbowIndent2", { fg = "#4a3040" })  -- muted pink
  hl("RainbowIndent3", { fg = "#2e3d2e" })  -- muted green
  hl("RainbowIndent4", { fg = "#3d3a24" })  -- muted yellow
  hl("RainbowIndent5", { fg = "#2a3540" })  -- muted cyan
  hl("RainbowIndent6", { fg = "#402a2a" })  -- muted red

  -- Neo-tree
  hl("NeoTreeNormal",        { bg = P.bg_deep })
  hl("NeoTreeNormalNC",      { bg = P.bg_deep })
  hl("NeoTreeEndOfBuffer",   { fg = P.bg_deep, bg = P.bg_deep })
  hl("NeoTreeDirectoryName", { fg = P.peach })
  hl("NeoTreeDirectoryIcon", { fg = P.peach })
  hl("NeoTreeRootName",      { fg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("NeoTreeFileName",      { fg = P.fg })
  hl("NeoTreeFileIcon",      { fg = P.fg })
  hl("NeoTreeGitAdded",      { fg = "#{{GREEN}}" })
  hl("NeoTreeGitModified",   { fg = "#b8a47a" })
  hl("NeoTreeGitDeleted",    { fg = "#a06060" })
  hl("NeoTreeGitUntracked",  { fg = "#a06060" })
  hl("NeoTreeGitConflict",   { fg = P.red, bold = {{SHOW_WELCOME}} })
  hl("NeoTreeIndentMarker",  { fg = P.bg_hl })
  hl("NeoTreeWinSeparator",  { fg = P.bg_deep, bg = P.bg_deep })
  hl("NeoTreeCursorLine",    { bg = P.bg_hl })
  hl("NeoTreeTitleBar",      { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("NeoTreeFloatBorder",   { fg = P.peach })
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
  hl("DapUIBreakpointsDisabledLine", { fg = P.surface })
  hl("DapUIDecoration",              { fg = P.peach })
  hl("DapUIWatchesEmpty",            { fg = P.surface })
  hl("DapUIWatchesValue",            { fg = P.green })
  hl("DapUIWatchesError",            { fg = P.red })
  hl("DapUIModifiedValue",           { fg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("DapUIFloatNormal",             { bg = P.bg_deep })
  hl("DapUIFloatBorder",             { fg = P.peach })

  -- DAP breakpoint/stopped signs
  hl("DapBreakpoint",          { fg = P.red })
  hl("DapBreakpointCondition", { fg = P.yellow })
  hl("DapLogPoint",            { fg = P.cyan })
  hl("DapStopped",             { fg = P.green, bg = P.bg_hl })

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
  hl("NeotestExpandMarker", { fg = P.surface })
  hl("NeotestWinSelect",    { fg = P.peach, bold = {{SHOW_WELCOME}} })

  -- Harpoon
  hl("HarpoonWindow", { bg = P.bg_deep })
  hl("HarpoonBorder", { fg = P.peach })

  -- TODO comments
  hl("TodoBgTODO", { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("TodoFgTODO", { fg = P.peach })
  hl("TodoBgFIX",  { fg = P.bg, bg = P.red, bold = {{SHOW_WELCOME}} })
  hl("TodoFgFIX",  { fg = P.red })
  hl("TodoBgHACK", { fg = P.bg, bg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("TodoFgHACK", { fg = P.yellow })
  hl("TodoBgNOTE", { fg = P.bg, bg = P.green, bold = {{SHOW_WELCOME}} })
  hl("TodoFgNOTE", { fg = P.green })
  hl("TodoBgWARN", { fg = P.bg, bg = P.yellow, bold = {{SHOW_WELCOME}} })
  hl("TodoFgWARN", { fg = P.yellow })
  hl("TodoBgPERF", { fg = P.bg, bg = P.pink, bold = {{SHOW_WELCOME}} })
  hl("TodoFgPERF", { fg = P.pink })

  -- Fidget
  hl("FidgetTitle", { fg = P.peach })
  hl("FidgetTask",  { fg = P.comment })

  -- Treesitter context
  hl("TreesitterContext",           { bg = P.ts_ctx })
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
  hl("LazyProgressTodo",  { fg = P.surface })
  hl("LazyReasonPlugin",  { fg = P.pink })
  hl("LazyReasonEvent",   { fg = P.yellow })
  hl("LazyReasonKeys",    { fg = P.cyan })
  hl("LazyReasonCmd",     { fg = P.green })

  -- Copilot
  hl("CopilotSuggestion", { fg = P.comment, italic = {{SHOW_WELCOME}} })
  hl("CopilotAnnotation", { fg = P.surface })

  -- Beacon (cursor flash on jump)
  hl("BeaconDefault", { bg = P.peach })

  -- Gitsigns blame
  hl("GitSignsCurrentLineBlame", { fg = P.surface, italic = {{SHOW_WELCOME}} })

  -- Rainbow delimiters
  hl("RainbowDelimiterPeach",  { fg = P.peach })
  hl("RainbowDelimiterPink",   { fg = P.pink })
  hl("RainbowDelimiterMint",   { fg = P.green })
  hl("RainbowDelimiterYellow", { fg = P.yellow })
  hl("RainbowDelimiterCyan",   { fg = P.cyan })
  hl("RainbowDelimiterRed",    { fg = P.red })

  -- Noice
  hl("NoiceCmdlinePopup",            { bg = P.bg_deep })
  hl("NoiceCmdlinePopupBorder",      { fg = P.peach })
  hl("NoiceCmdlinePopupTitle",       { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("NoiceCmdlinePopupBorderSearch", { fg = P.yellow })
  hl("NoiceCmdlineIcon",             { fg = P.peach })
  hl("NoiceCmdlineIconSearch",       { fg = P.yellow })
  hl("NoicePopupmenu",               { bg = P.bg_deep })
  hl("NoicePopupmenuBorder",         { fg = P.peach })
  hl("NoicePopupmenuSelected",       { bg = P.bg_hl })
  hl("NoicePopupmenuMatch",          { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("NoiceMini",                    { bg = P.bg_deep })
  hl("NoiceFormatProgressDone",      { fg = P.bg, bg = P.peach })
  hl("NoiceFormatProgressTodo",      { fg = P.comment, bg = P.bg_hl })
  hl("NoiceLspProgressTitle",        { fg = P.peach })
  hl("NoiceConfirm",                 { bg = P.bg_deep })
  hl("NoiceConfirmBorder",           { fg = P.pink })
  hl("NoiceVirtualText",             { fg = P.peach })
  hl("NoiceSplit",                   { bg = P.bg_deep })
  hl("NoiceSplitBorder",             { fg = P.peach, bg = P.bg_deep })

  -- Notify
  hl("NotifyERRORBorder", { fg = P.clay })
  hl("NotifyWARNBorder",  { fg = P.wheat })
  hl("NotifyINFOBorder",  { fg = P.peach })
  hl("NotifyDEBUGBorder", { fg = P.comment })
  hl("NotifyTRACEBorder", { fg = P.pink })
  hl("NotifyERRORIcon",   { fg = P.clay })
  hl("NotifyWARNIcon",    { fg = P.wheat })
  hl("NotifyINFOIcon",    { fg = P.peach })
  hl("NotifyDEBUGIcon",   { fg = P.comment })
  hl("NotifyTRACEIcon",   { fg = P.pink })
  hl("NotifyERRORTitle",  { fg = P.clay })
  hl("NotifyWARNTitle",   { fg = P.wheat })
  hl("NotifyINFOTitle",   { fg = P.peach })
  hl("NotifyDEBUGTitle",  { fg = P.comment })
  hl("NotifyTRACETitle",  { fg = P.pink })
  hl("NotifyBackground",  { bg = P.bg })

  -- Scrollbar
  hl("ScrollbarHandle",          { bg = P.bg_hl })
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
  hl("AvantePromptInputBorder",            { fg = P.peach, bg = P.bg_hl })
  hl("AvanteInlineHint",                   { fg = P.peach, bg = P.bg_deep, bold = {{SHOW_WELCOME}} })
  hl("AvantePopupHint",                    { fg = P.comment, bg = P.bg_deep })
  hl("AvanteConfirmTitle",                 { fg = P.bg, bg = P.red, bold = {{SHOW_WELCOME}} })
  hl("AvanteButtonDefault",               { fg = P.bg, bg = P.comment })
  hl("AvanteButtonDefaultHover",          { fg = P.bg, bg = P.green })
  hl("AvanteButtonPrimary",               { fg = P.bg, bg = P.warm })
  hl("AvanteButtonPrimaryHover",          { fg = P.bg, bg = P.peach })
  hl("AvanteButtonDanger",                { fg = P.bg, bg = P.warm })
  hl("AvanteButtonDangerHover",           { fg = P.bg, bg = P.red })
  hl("AvanteToBeDeleted",                 { bg = "#3d1f23", strikethrough = {{SHOW_WELCOME}} })
  hl("AvanteToBeDeletedWOStrikethrough",  { bg = "#3d1f23" })
  hl("AvanteConflictCurrent",             { bg = "#3d1f23", bold = {{SHOW_WELCOME}} })
  hl("AvanteConflictCurrentLabel",        { bg = "#4d2529" })
  hl("AvanteConflictIncoming",            { bg = "#1a3328", bold = {{SHOW_WELCOME}} })
  hl("AvanteConflictIncomingLabel",       { bg = "#1f3d2e" })
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
  hl("ClaudeCodeBorder",    { fg = P.peach, bg = P.bg_deep })
  hl("ClaudeCodeTitle",     { fg = P.bg, bg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("ClaudeCodeSeparator", { fg = P.bg_deep, bg = P.bg_deep })

  -- vim-illuminate (subtle earthy underline, not distracting)
  hl("IlluminatedWordText",  { bg = "#4a3528" })
  hl("IlluminatedWordRead",  { bg = "#4a3528" })
  hl("IlluminatedWordWrite", { bg = "#4a3528", underline = {{SHOW_WELCOME}} })

  -- nvim-cmp
  hl("CmpItemAbbrMatch",      { fg = P.peach, bold = {{SHOW_WELCOME}} })
  hl("CmpItemAbbrMatchFuzzy", { fg = P.peach })
  hl("CmpItemAbbrDeprecated", { fg = P.surface, strikethrough = {{SHOW_WELCOME}} })
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
end

apply_foxml_theme()

-- Re-apply theme after any colorscheme event (prevents treesitter/plugin overrides)
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function() apply_foxml_theme() end,
})

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
local sidebar_fts = { ["neo-tree"] = {{SHOW_WELCOME}}, ["Avante"] = {{SHOW_WELCOME}}, ["AvanteInput"] = {{SHOW_WELCOME}},
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
  float = { border = border },
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = " ",
      [vim.diagnostic.severity.WARN]  = " ",
      [vim.diagnostic.severity.INFO]  = " ",
      [vim.diagnostic.severity.HINT]  = " ",
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
    linehl = {
      [vim.diagnostic.severity.ERROR] = "DiagnosticLineError",
      [vim.diagnostic.severity.WARN]  = "DiagnosticLineWarn",
      [vim.diagnostic.severity.INFO]  = "DiagnosticLineInfo",
      [vim.diagnostic.severity.HINT]  = "DiagnosticLineHint",
    },
  },
})

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
require("lualine").setup({
  options = {
    theme = {
      normal   = { a = { fg = P.bg, bg = P.peach, gui = "bold" }, b = { fg = P.peach, bg = P.bg_hl }, c = { fg = P.comment, bg = P.bg_deep } },
      insert   = { a = { fg = P.bg, bg = P.green, gui = "bold" }, b = { fg = P.green, bg = P.bg_hl } },
      visual   = { a = { fg = P.bg, bg = P.pink, gui = "bold" }, b = { fg = P.pink, bg = P.bg_hl } },
      replace  = { a = { fg = P.bg, bg = P.red, gui = "bold" }, b = { fg = P.red, bg = P.bg_hl } },
      command  = { a = { fg = P.bg, bg = P.yellow, gui = "bold" }, b = { fg = P.yellow, bg = P.bg_hl } },
      inactive = { a = { fg = P.comment, bg = P.bg_deep }, b = { fg = P.surface, bg = P.bg_deep }, c = { fg = P.surface, bg = P.bg_deep } },
    },
    section_separators = { left = "", right = "" },
    component_separators = { left = "", right = "" },
  },
  sections = {
    lualine_a = { "mode" },
    lualine_b = { "branch", "diff", "diagnostics" },
    lualine_c = { { "filename", path = 1 } },
    lualine_x = {
      {
        function()
          local ok, api = pcall(require, "copilot.api")
          if not ok then return "" end
          local status = api.status.data.status
          if status == "InProgress" then return " " end
          if status == "Warning" then return " " end
          if status == "Normal" then return " " end
          return ""
        end,
        color = function()
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
          local clients = vim.lsp.get_clients({ bufnr = 0 })
          if #clients == 0 then return "" end
          return " " .. clients[1].name
        end,
        color = { fg = P.peach },
      },
      "filetype",
    },
    lualine_y = { "progress" },
    lualine_z = { "location" },
  },
})

-- Treesitter
require("nvim-treesitter.configs").setup({
  -- Dropped "latex" — the parser on this nvim-treesitter line generates from
  -- grammar source via tree-sitter-cli, and 0.26.x changed how `--no-bindings`
  -- is passed (now needs `-- --no-bindings`), so the install errors out.
  -- Add it back when nvim-treesitter ships a compatible build script.
  ensure_installed = { "lua", "python", "c", "cpp", "bash", "json", "yaml", "markdown", "vim", "vimdoc", "java", "javadoc" },
  highlight = { enable = {{SHOW_WELCOME}} },
  incremental_selection = { enable = {{SHOW_WELCOME}} },
  indent = { enable = {{SHOW_WELCOME}} },
  textobjects = {
    select = {
      enable = {{SHOW_WELCOME}},
      lookahead = {{SHOW_WELCOME}},
      keymaps = {
        ["af"] = "@function.outer",
        ["if"] = "@function.inner",
        ["ac"] = "@class.outer",
        ["ic"] = "@class.inner",
        ["aa"] = "@parameter.outer",
        ["ia"] = "@parameter.inner",
        ["ai"] = "@conditional.outer",
        ["ii"] = "@conditional.inner",
        ["al"] = "@loop.outer",
        ["il"] = "@loop.inner",
      },
    },
    move = {
      enable = {{SHOW_WELCOME}},
      set_jumps = {{SHOW_WELCOME}},
      goto_next_start = {
        ["]m"] = "@function.outer",
        ["]]"] = "@class.outer",
        ["]a"] = "@parameter.inner",
      },
      goto_prev_start = {
        ["[m"] = "@function.outer",
        ["[["] = "@class.outer",
        ["[a"] = "@parameter.inner",
      },
    },
    swap = {
      enable = {{SHOW_WELCOME}},
      swap_next = { ["<leader>sa"] = "@parameter.inner" },
      swap_previous = { ["<leader>sA"] = "@parameter.inner" },
    },
  },
})

-- Mason (LSP installer)
require("mason").setup()
require("mason-lspconfig").setup({
  ensure_installed = { "lua_ls", "pyright", "clangd", "bashls", "jsonls", "yamlls", "texlab" },
})

-- format on save


-- nvim-cmp (autocomplete)
local cmp = require("cmp")
local luasnip = require("luasnip")
cmp.setup({
  snippet = { expand = function(args) luasnip.lsp_expand(args.body) end },
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
    { { name = "buffer" }, { name = "path" } }),
})

-- === LSP (Neovim 0.11+ native API) ===
local capabilities = require("cmp_nvim_lsp").default_capabilities()

-- keymaps + format-on-save for all LSP buffers
local on_attach    = function(_, bufnr)
  local map = function(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
  end
  map("n", "gd", vim.lsp.buf.definition, "Go to definition")
  map("n", "gr", vim.lsp.buf.references, "References")
  map("n", "K", vim.lsp.buf.hover, "Hover")
  map("n", "<leader>rn", vim.lsp.buf.rename, "Rename")
  map("n", "<leader>ca", vim.lsp.buf.code_action, "Code Action")
  map("n", "[d", function() vim.diagnostic.jump({ count = -1 }) end, "Prev Diagnostic")
  map("n", "]d", function() vim.diagnostic.jump({ count = 1 }) end, "Next Diagnostic")
  map("n", "<leader>f", function() vim.lsp.buf.format({ async = {{SHOW_WELCOME}} }) end, "Format")

  -- format on save (synchronous so it finishes before write)
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = bufnr,
    callback = function()
      local ft = vim.bo[bufnr].filetype
      if ft ~= "c" and ft ~= "cpp" then
        vim.lsp.buf.format({ async = false })
      end
    end,
  })
end

-- === Native LSP (Neovim 0.11) ===
local lsp          = vim.lsp
local caps         = capabilities -- from cmp_nvim_lsp

-- Common servers
lsp.config.pyright = { capabilities = caps, on_attach = on_attach }
lsp.config.clangd  = {
  capabilities = caps,
  on_attach = on_attach,
  root_markers = { "compile_commands.json", "CMakeLists.txt", "Makefile", ".clangd" },
}
lsp.config.bashls  = { capabilities = caps, on_attach = on_attach }
lsp.config.jsonls  = { capabilities = caps, on_attach = on_attach }
lsp.config.yamlls  = { capabilities = caps, on_attach = on_attach }

-- Lua (tweaks)
lsp.config.lua_ls  = {
  capabilities = caps,
  on_attach = on_attach,
  settings = {
    Lua = {
      diagnostics = { globals = { "vim" } },
      workspace   = { checkThirdParty = false },
    },
  },
  root_markers = { ".luarc.json", ".luarc.jsonc", ".stylua.toml", ".luacheckrc", ".git" },
}

-- Enable all of them (auto-attach for matching filetypes)
lsp.config.texlab = {
  capabilities = caps,
  on_attach = on_attach,
  settings = {
    texlab = {
      build = {
        executable = "latexmk",
        args = { "-pdf", "-interaction=nonstopmode", "-synctex=1", "%f" },
        onSave = {{SHOW_WELCOME}},
      },
    },
  },
}

lsp.enable({ "pyright", "clangd", "bashls", "jsonls", "yamlls", "lua_ls", "texlab" })

-- Keymaps (global)
local map = vim.keymap.set
map("n", "<leader>ff", "<cmd>Telescope find_files<cr>", { desc = "Find files" })
map("n", "<leader>fg", "<cmd>Telescope live_grep<cr>", { desc = "Grep" })
map("n", "<leader>fb", "<cmd>Telescope buffers<cr>", { desc = "Buffers" })
map("n", "<leader>fh", "<cmd>Telescope help_tags<cr>", { desc = "Help" })
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

-- Quality of life
map({ "n", "v" }, "<leader>/", function() require("Comment.api").toggle.linewise.current() end,
  { desc = "Comment toggle" })

-- Harpoon
local harpoon = require("harpoon")
map("n", "<leader>ha", function() harpoon:list():add() end, { desc = "Harpoon add file" })
map("n", "<leader>hh", function() harpoon.ui:toggle_quick_menu(harpoon:list()) end, { desc = "Harpoon menu" })
map("n", "<C-1>", function() harpoon:list():select(1) end, { desc = "Harpoon 1" })
map("n", "<C-2>", function() harpoon:list():select(2) end, { desc = "Harpoon 2" })
map("n", "<C-3>", function() harpoon:list():select(3) end, { desc = "Harpoon 3" })
map("n", "<C-4>", function() harpoon:list():select(4) end, { desc = "Harpoon 4" })

-- Copilot: toggle inline ghost-text vs cmp-menu suggestions
map("n", "<leader>Ci", function()
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
map("n", "<leader>s", "<cmd>split<cr>", { desc = "Horizontal split" })
map("n", "<C-Left>", "<cmd>vertical resize -5<cr>", { desc = "Shrink window" })
map("n", "<C-Right>", "<cmd>vertical resize +5<cr>", { desc = "Grow window" })
map("n", "<C-Up>", "<cmd>resize +3<cr>", { desc = "Grow window height" })
map("n", "<C-Down>", "<cmd>resize -3<cr>", { desc = "Grow window height" })

-- Terminal mode navigation (escape terminal capture to move between splits)
map("t", "<C-h>", "<C-\\><C-n><C-w>h", { desc = "Move to left split" })
map("t", "<C-l>", "<C-\\><C-n><C-w>l", { desc = "Move to right split" })
map("t", "<C-j>", "<C-\\><C-n><C-w>j", { desc = "Move to lower split" })
map("t", "<C-k>", "<C-\\><C-n><C-w>k", { desc = "Move to upper split" })

-- AI (Avante)
map("n", "<leader>aa", "<cmd>AvanteAsk<cr>", { desc = "Avante ask" })
map("v", "<leader>aa", "<cmd>AvanteAsk<cr>", { desc = "Avante ask (selection)" })
map("n", "<leader>at", "<cmd>AvanteToggle<cr>", { desc = "Avante toggle" })
map("n", "<leader>ac", "<cmd>AvanteChat<cr>", { desc = "Avante chat" })
map("v", "<leader>ae", "<cmd>AvanteEdit<cr>", { desc = "Avante edit (selection)" })
map("n", "<leader>ar", "<cmd>AvanteRefresh<cr>", { desc = "Avante refresh" })
map("n", "<leader>aS", "<cmd>AvanteStop<cr>", { desc = "Avante stop" })

-- AI (CodeCompanion)
map({ "n", "v" }, "<leader>cc", "<cmd>CodeCompanionActions<cr>", { desc = "AI Actions (CodeCompanion)" })
map({ "n", "v" }, "<leader>ca", "<cmd>CodeCompanionChat Toggle<cr>", { desc = "AI Chat Toggle" })
map("v", "ga", "<cmd>CodeCompanionChat Add<cr>", { desc = "Add selection to AI chat" })
map("n", "<leader>ci", "<cmd>CodeCompanion<cr>", { desc = "AI Inline (CodeCompanion)" })

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
map("n", "<leader>q", function()
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

-- Yank to end of line (consistent with D and C)
map("n", "Y", "y$", { desc = "Yank to end of line" })

-- Select last paste
map("n", "gp", "`[v`]", { desc = "Select last paste" })

-- Move line up/down in normal mode
map("n", "<A-j>", "<cmd>m .+1<cr>==", { desc = "Move line down" })
map("n", "<A-k>", "<cmd>m .-2<cr>==", { desc = "Move line up" })

-- Make file executable
map("n", "<leader>X", "<cmd>!chmod +x %<cr>", { silent = {{SHOW_WELCOME}}, desc = "Make file executable" })

-- Toggle diagnostic virtual text
local diag_vt_enabled = {{SHOW_WELCOME}}
map("n", "<leader>td", function()
  diag_vt_enabled = not diag_vt_enabled
  vim.diagnostic.config({ virtual_text = diag_vt_enabled })
  vim.notify("Diagnostic virtual text: " .. (diag_vt_enabled and "ON" or "OFF"))
end, { desc = "Toggle diagnostic virtual text" })

-- Toggle lsp_lines (multi-line diagnostics below error lines)
local lsp_lines_enabled = false
map("n", "<leader>tl", function()
  lsp_lines_enabled = not lsp_lines_enabled
  vim.diagnostic.config({
    virtual_lines = lsp_lines_enabled,
    virtual_text = not lsp_lines_enabled,
  })
  vim.notify("Diagnostic lines: " .. (lsp_lines_enabled and "ON" or "OFF"))
end, { desc = "Toggle diagnostic lines" })

-- Highlight on yank (brief flash)
vim.api.nvim_create_autocmd("TextYankPost", {
  callback = function() vim.highlight.on_yank({ timeout = 200 }) end,
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
-- Notify when a file reloads so it's not silent/confusing
vim.api.nvim_create_autocmd("FileChangedShellPost", {
  callback = function() vim.notify("File reloaded (changed on disk)", vim.log.levels.INFO) end,
})
