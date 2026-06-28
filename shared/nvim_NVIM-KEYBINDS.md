# Neovim Keybind Reference

Leader: **Space** | Local leader: **Space**

---

## Core Vim

### Movement
| Key | Action |
|-----|--------|
| `h/j/k/l` | Left / Down / Up / Right |
| `w` / `W` | Next word / WORD start |
| `b` / `B` | Previous word / WORD start |
| `e` / `E` | End of word / WORD |
| `0` / `$` | Start / End of line |
| `^` | First non-blank char |
| `gg` / `G` | Top / Bottom of file |
| `{` / `}` | Previous / Next paragraph |
| `%` | Jump to matching bracket |
| `Ctrl+d` / `Ctrl+u` | Half-page down / up |
| `Ctrl+f` / `Ctrl+b` | Full page down / up |
| `H` / `M` / `L` | Screen top / middle / bottom |
| `f{c}` / `F{c}` | Jump to next / prev char |
| `t{c}` / `T{c}` | Jump before next / prev char |
| `;` / `,` | Repeat / Reverse last f/t |

### Editing
| Key | Action |
|-----|--------|
| `i` / `a` | Insert before / after cursor |
| `I` / `A` | Insert at line start / end |
| `o` / `O` | New line below / above |
| `r{c}` | Replace single char |
| `R` | Enter replace mode |
| `x` | Delete char under cursor |
| `dd` / `D` | Delete line / to end of line |
| `cc` / `C` | Change line / to end of line |
| `yy` | Yank line |
| `Y` | Yank to end of line (like D/C) |
| `p` / `P` | Paste after / before |
| `u` / `Ctrl+r` | Undo / Redo |
| `.` | Repeat last change |
| `J` | Join line below |
| `~` | Toggle case |
| `>>` / `<<` | Indent / Unindent line |
| `gq{motion}` | Reformat text |

### Text Objects (use with d/c/y/v)
| Key | Selects |
|-----|---------|
| `iw` / `aw` | Inner / Around word |
| `i"` / `a"` | Inner / Around double quotes |
| `i'` / `a'` | Inner / Around single quotes |
| `i(` / `a(` | Inner / Around parentheses |
| `i{` / `a{` | Inner / Around braces |
| `i[` / `a[` | Inner / Around brackets |
| `it` / `at` | Inner / Around HTML tag |
| `ip` / `ap` | Inner / Around paragraph |
| `is` / `as` | Inner / Around sentence |

### Treesitter Text Objects
| Key | Selects |
|-----|---------|
| `if` / `af` | Inner / Around function |
| `ic` / `ac` | Inner / Around class |
| `ia` / `aa` | Inner / Around parameter |
| `ii` / `ai` | Inner / Around conditional |
| `il` / `al` | Inner / Around loop |

Examples:
- `daf` — delete entire function
- `vac` — select entire class
- `cia` — change parameter contents
- `yif` — yank function body

### Treesitter Navigation
| Key | Action |
|-----|--------|
| `]m` / `[m` | Next / Prev function start |
| `]]` / `[[` | Next / Prev class start |
| `]a` / `[a` | Next / Prev parameter |
| `Space na` | Swap parameter with next |
| `Space nA` | Swap parameter with previous |

### Search
| Key | Action |
|-----|--------|
| `/{pattern}` | Search forward |
| `?{pattern}` | Search backward |
| `n` / `N` | Next / Previous match |
| `*` / `#` | Search word under cursor fwd / back |
| `:noh` | Clear search highlight |

### Visual Mode
| Key | Action |
|-----|--------|
| `v` | Character-wise visual |
| `V` | Line-wise visual |
| `Ctrl+v` | Block visual |
| `gv` | Reselect last visual |
| `gp` | Select last paste |
| `o` | Jump to other end of selection |

### Marks & Jumps
| Key | Action |
|-----|--------|
| `m{a-z}` | Set local mark |
| `'{a-z}` | Jump to mark line |
| `` `{a-z} `` | Jump to mark position |
| `Ctrl+o` / `Ctrl+i` | Jump back / forward |
| `gi` | Go to last insert position |

### Windows
| Key | Action |
|-----|--------|
| `Space ss` | Horizontal split (leader) |
| `Space qq` | Close window (smart — drops to empty buffer if last) |
| `Ctrl+w s` | Split horizontal |
| `Ctrl+w v` | Split vertical |
| `Ctrl+w h/j/k/l` | Navigate splits |
| `Ctrl+w q` | Close split |
| `Ctrl+w o` | Close all other splits |
| `Ctrl+w =` | Equalize split sizes |
| `Ctrl+w +/-` | Resize height |
| `Ctrl+w >/<` | Resize width |

### Buffers & Tabs
| Key | Action |
|-----|--------|
| `:e {file}` | Edit file |
| `:bn` / `:bp` | Next / Previous buffer |
| `:bd` | Delete (close) buffer |
| `:ls` | List buffers |
| `gt` / `gT` | Next / Previous tab |

### Registers
| Key | Action |
|-----|--------|
| `"{reg}y/d/p` | Yank/delete/paste with register |
| `"+y` | Yank to system clipboard |
| `"+p` | Paste from system clipboard |
| `:reg` | Show all registers |
| `"0p` | Paste last yank (not delete) |

### Macros
| Key | Action |
|-----|--------|
| `q{a-z}` | Start recording macro |
| `q` | Stop recording |
| `@{a-z}` | Play macro |
| `@@` | Replay last macro |
| `{n}@{a-z}` | Play macro n times |

---

## Plugin Keybinds

### Flash (Jump Anywhere)
| Key | Action |
|-----|--------|
| `s{2 chars}` | Flash jump — labels all matches, press label to go |
| `S` | Flash treesitter — select treesitter node |

How to use: press `s`, type 2 characters, then press the highlighted label to jump there. Works in normal, visual, and operator-pending modes.

### Telescope (Fuzzy Finder)
| Key | Action |
|-----|--------|
| `Space ff` | Find files |
| `Space fg` | Live grep (search content) |
| `Space fb` | Open buffers |
| `Space fh` | Help tags |

Inside Telescope:
| Key | Action |
|-----|--------|
| `Ctrl+n` / `Ctrl+p` | Next / Prev result |
| `Ctrl+j` / `Ctrl+k` | Next / Prev result (alt) |
| `Enter` | Open selected |
| `Ctrl+x` | Open in horizontal split |
| `Ctrl+v` | Open in vertical split |
| `Ctrl+t` | Open in new tab |
| `Ctrl+u` / `Ctrl+d` | Scroll preview up / down |
| `Esc` / `Ctrl+c` | Close |
| `Tab` | Toggle selection + move down |

### Neo-tree (File Explorer)
| Key | Action |
|-----|--------|
| `Space e` | Toggle file explorer |
| `-` | Reveal current file in tree |

Inside Neo-tree:
| Key | Action |
|-----|--------|
| `Enter` / `l` | Open file / Expand directory |
| `h` | Collapse node |
| `s` | Open in horizontal split |
| `v` | Open in vertical split |

### Harpoon (File Bookmarks)
| Key | Action |
|-----|--------|
| `Space ha` | Add current file to harpoon list |
| `Space hh` | Open harpoon quick menu |
| `Ctrl+1` | Jump to harpoon file 1 |
| `Ctrl+2` | Jump to harpoon file 2 |
| `Ctrl+3` | Jump to harpoon file 3 |
| `Ctrl+4` | Jump to harpoon file 4 |

How to use: Mark 3-4 files you're bouncing between. `Space ha` to add, `Ctrl+1-4` to jump instantly. Reorder in the menu.

### Surround (nvim-surround)
| Key | Action |
|-----|--------|
| `ysiw"` | Surround word with `"` |
| `ysiw(` | Surround word with `( )` (with spaces) |
| `ysiw)` | Surround word with `()` (no spaces) |
| `ys$"` | Surround to end of line with `"` |
| `yss"` | Surround entire line with `"` |
| `cs"'` | Change surrounding `"` to `'` |
| `cs({` | Change surrounding `()` to `{}` |
| `ds"` | Delete surrounding `"` |
| `ds(` | Delete surrounding `()` |
| `S"` (visual) | Surround selection with `"` |

Pattern: `ys{motion}{char}` = add, `cs{old}{new}` = change, `ds{char}` = delete.

### LSP
| Key | Action |
|-----|--------|
| `gd` | Go to definition |
| `gr` | References |
| `K` | Hover documentation |
| `Space rn` | Rename symbol |
| `Space ca` | Code action |
| `[d` / `]d` | Prev / Next diagnostic |
| `Space cf` | Format buffer |

### C/C++ Specific
| Key | Action |
|-----|--------|
| `Space ch` | Switch header / source (clangd) |

### CMake (cmake-tools.nvim)
| Key | Action |
|-----|--------|
| `Space cg` | CMake generate |
| `Space cb` | CMake build |
| `Space cr` | CMake run target |
| `Space ct` | Select build type (Debug/Release) |
| `Space cl` | Select launch target |

### DAP (Debugger)
| Key | Action |
|-----|--------|
| `F5` | Continue / Start debugging |
| `F9` | Toggle breakpoint |
| `F10` | Step over |
| `F11` | Step into |

DAP UI opens/closes automatically. Variable values show inline (nvim-dap-virtual-text).

### Neotest
| Key | Action |
|-----|--------|
| `Space tn` | Run nearest test |
| `Space ts` | Toggle test summary panel |

### Aerial (Symbol Outline)
| Key | Action |
|-----|--------|
| `Space so` | Toggle symbols outline |

Inside Aerial:
| Key | Action |
|-----|--------|
| `Enter` | Jump to symbol |
| `{` / `}` | Prev / Next symbol |
| `Ctrl+j` / `Ctrl+k` | Prev / Next symbol + scroll code |

### Trouble (Diagnostics Panel)
| Key | Action |
|-----|--------|
| `Space xx` | Toggle diagnostics list |
| `Space xq` | Toggle quickfix list |

Inside Trouble:
| Key | Action |
|-----|--------|
| `Enter` | Jump to item |
| `o` | Jump + close |
| `q` | Close |

### Undotree
| Key | Action |
|-----|--------|
| `Space u` | Toggle undo tree panel |

Inside Undotree:
| Key | Action |
|-----|--------|
| `j/k` | Navigate undo states |
| `Enter` | Switch to state |
| `q` | Close |

### Diffview (Git)
| Key | Action |
|-----|--------|
| `Space gd` | Open git diff view (all changes) |
| `Space gh` | File history (current file) |
| `Space gq` | Close diff view |

Inside Diffview:
| Key | Action |
|-----|--------|
| `Tab` / `Shift+Tab` | Next / Prev file |
| `gf` | Open file |
| `q` | Close |

### Comment.nvim
| Key | Action |
|-----|--------|
| `Space /` | Toggle comment (line) |
| `gcc` | Toggle comment (line, default) |
| `gbc` | Toggle block comment |
| `gc{motion}` | Comment over motion (e.g. `gcap` = comment paragraph) |

In visual mode:
| Key | Action |
|-----|--------|
| `gc` | Toggle comment on selection |
| `gb` | Toggle block comment on selection |

### Gitsigns (in-buffer git)
| Key | Action |
|-----|--------|
| `]c` / `[c` | Next / Prev hunk |
| `:Gitsigns preview_hunk` | Preview change |
| `:Gitsigns stage_hunk` | Stage hunk |
| `:Gitsigns undo_stage_hunk` | Undo stage |
| `:Gitsigns reset_hunk` | Reset hunk |
| `:Gitsigns blame_line` | Show git blame |
| `:Gitsigns diffthis` | Diff against index |

### LazyGit (Git TUI)
| Key | Action |
|-----|--------|
| `Space gg` | Open LazyGit |

Inside LazyGit:
| Key | Action |
|-----|--------|
| `space` | Stage/unstage file |
| `c` | Commit |
| `p` / `P` | Pull / Push |
| `s` | Stash |
| `b` | Branches |
| `enter` | View file / Expand |
| `q` | Quit |
| `?` | Show all keybinds |

Full git workflow without leaving nvim — stage, commit, push, rebase, resolve conflicts, cherry-pick, etc.

### Persistence (Sessions)
| Key | Action |
|-----|--------|
| `Space qs` | Restore session for current directory |
| `Space ql` | Restore last session |
| `Space qd` | Stop auto-saving session |

Automatically saves your session (open buffers, splits, cursor positions) when you quit. Restore it next time you open nvim in the same directory.

### Spectre (Find & Replace)
| Key | Action |
|-----|--------|
| `Space sr` | Toggle Spectre panel |
| `Space sw` | Search current word (normal mode) |
| `Space sw` | Search selection (visual mode) |

Inside Spectre:
| Key | Action |
|-----|--------|
| `Enter` | Go to match |
| `dd` | Toggle exclude for current item |
| `<leader>R` | Replace all |
| `<leader>rc` | Replace current |
| `q` | Close |

Project-wide find and replace with live preview. Supports regex.

### Quality of Life
| Key | Action |
|-----|--------|
| `Space w` | Save file |
| `Space X` | Make file executable (chmod +x) |
| `Space td` | Toggle diagnostic virtual text on/off |
| `Alt+j` / `Alt+k` | Move line up/down (normal + visual) |

### Which-Key
Press **Space** and wait — which-key pops up showing all leader binds and their descriptions.

### Autocomplete (nvim-cmp, Insert Mode)
| Key | Action |
|-----|--------|
| `Tab` | Next completion / Expand snippet / Jump snippet |
| `Shift+Tab` | Previous completion / Jump snippet back |
| `Enter` | Confirm completion |
| `Ctrl+Space` | Trigger completion manually |
| `Ctrl+b` / `Ctrl+f` | Scroll docs up / down |
| `Ctrl+e` | Close completion menu |

### LuaSnip (Snippets)
| Key | Action |
|-----|--------|
| `Tab` | Expand snippet / Jump to next field |
| `Shift+Tab` | Jump to previous field |

### ToggleTerm
| Key | Action |
|-----|--------|
| `:ToggleTerm` | Open/close terminal |
| `Ctrl+\` | Toggle terminal (default) |
| `Ctrl+\ Ctrl+n` | Exit terminal mode (back to normal) |

### VimTeX (LaTeX)
| Key | Action |
|-----|--------|
| `Space ll` | Start/stop continuous compile |
| `Space lv` | View PDF (zathura) |
| `Space lc` | Clean aux files |
| `Space lC` | Clean + PDF |
| `Space lt` | Open ToC |
| `Space le` | Show errors |
| `Space lk` | Stop compilation |

### Projects
| Key | Action |
|-----|--------|
| `Space pp` | Browse recent projects (Telescope) |

---

### Copilot (Inline AI Completions)
| Key | Action |
|-----|--------|
| `Ctrl+l` | Accept suggestion |
| `Ctrl+;` | Accept word |
| `Ctrl+'` | Accept line |
| `Ctrl+]` | Next suggestion |
| `Ctrl+k` | Previous suggestion |
| `Ctrl+j` | Dismiss suggestion |
| `:Copilot auth` | Log in to GitHub |
| `:Copilot status` | Check connection status |

Ghost-text suggestions appear automatically when inline mode is active. Use `Ctrl+l` to accept the full suggestion, or `Ctrl+;` / `Ctrl+'` to accept partially.

| `Space Ci` | Toggle between inline ghost-text and cmp menu mode |

**Modes:** Copilot can run in two modes — **inline** (ghost-text ahead of cursor, accept with `Ctrl+l`) or **cmp menu** (suggestions appear in the autocomplete popup alongside LSP). Toggle with `Space Ci`.

### Claude Code (AI Terminal)
| Key | Action |
|-----|--------|
| `Space Ct` | Toggle Claude terminal (show/hide) |
| `Space Cs` | Send selection to Claude (visual) |

Claude Code sees all open buffers (the ones you cycle with `H`/`L`) automatically via WebSocket — file contents, paths, and diagnostics are shared without pasting. Use `Space Cs` in visual mode to explicitly point Claude at a specific code block.

Commands:
| Command | Action |
|---------|--------|
| `:ClaudeCode` | Simple show/hide toggle |
| `:ClaudeCodeFocus` | Smart focus toggle (swap between code and terminal) |
| `:ClaudeCodeOpen` | Open terminal (no toggle) |
| `:ClaudeCodeSend` | Send visual selection |
| `:ClaudeCodeAdd` | Add file to context |
| `:ClaudeCodeStatus` | Check WebSocket server status |

### Avante (AI Chat Panel)
| Key | Action |
|-----|--------|
| `Space aa` | Ask AI (normal or visual selection) |
| `Space at` | Toggle AI sidebar |
| `Space ac` | Open AI chat |

Inside Avante sidebar:
| Key | Action |
|-----|--------|
| `Ctrl+s` | Submit prompt |
| `q` | Close sidebar |
| `Tab` | Cycle through code suggestions |

Commands:
| Command | Action |
|---------|--------|
| `:AvanteAsk` | Ask a question |
| `:AvanteChat` | Open chat |
| `:AvanteToggle` | Toggle sidebar |
| `:AvanteEdit` | Edit selected code with AI |

Uses **Copilot provider** (routes through your GitHub Copilot subscription — no API keys needed). Default model: Claude Sonnet.

---

## Passive Plugins (no keybinds needed)

| Plugin | What it does |
|--------|--------------|
| **neoscroll** | Smooth scrolling for Ctrl+d/u/f/b, zt, zz, zb |
| **fidget** | Shows LSP progress (indexing, formatting) bottom-right |
| **nvim-dap-virtual-text** | Shows variable values inline while debugging |
| **treesitter-context** | Pins current function/class at top of window |
| **indent-blankline** | Shows indent guides |
| **nvim-autopairs** | Auto-closes brackets, quotes, parens |
| **conform** | Formats C/C++ with clang-format on save |
| **nvim-lint** | Runs clang-tidy on save / insert leave |
| **todo-comments** | Highlights TODO, FIXME, HACK, etc. in comments |
| **vim-illuminate** | Highlights other occurrences of the word under cursor |

---

## Useful Commands

| Command | Action |
|---------|--------|
| `:Lazy` | Plugin manager (install/update/clean) |
| `:Mason` | LSP/DAP/Linter installer |
| `:LspInfo` | Show active LSP servers |
| `:LspLog` | View LSP log |
| `:TSUpdate` | Update treesitter parsers |
| `:checkhealth` | Diagnose issues |
| `:Telescope keymaps` | Search ALL keymaps |
| `:CMake*` | All cmake-tools commands |
| `:Trouble *` | All trouble commands |
| `:OverseerRun` | Run a task |
| `:OverseerToggle` | Toggle task list |

---

## Leader Key Map (Space + ...)

Quick reference of all `Space` binds:

| Key | Action |
|-----|--------|
| `f f` | Find files |
| `f g` | Live grep |
| `f b` | Buffers |
| `f h` | Help tags |
| `r n` | Rename symbol |
| `c a` | Code action |
| `c h` | Switch header/source |
| `c g` | CMake generate |
| `c b` | CMake build |
| `c r` | CMake run |
| `c t` | CMake build type |
| `c l` | CMake launch target |
| `t n` | Test nearest |
| `t s` | Test summary |
| `s o` | Symbols outline |
| `n a` | Swap param next |
| `n A` | Swap param prev |
| `p p` | Projects |
| `h a` | Harpoon add |
| `h h` | Harpoon menu |
| `u` | Undotree |
| `g d` | Git diff view |
| `g h` | Git file history |
| `g q` | Close diff view |
| `C i` | Copilot toggle inline/cmp |
| `C t` | Claude toggle terminal |
| `C s` | Claude send selection |
| `a a` | AI ask |
| `a t` | AI toggle sidebar |
| `a c` | AI chat |
| `g g` | LazyGit |
| `q s` | Restore session (cwd) |
| `q l` | Restore last session |
| `q d` | Stop session recording |
| `s r` | Search & Replace (Spectre) |
| `s w` | Search word / selection |
| `x x` | Diagnostics |
| `x q` | Quickfix |
| `c f` | Format |
| `s s` | Horizontal split |
| `q q` | Close window |
| `/` | Toggle comment |
| `w` | Save file |
| `X` | Make file executable |
| `t d` | Toggle diagnostic virtual text |
