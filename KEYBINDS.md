# Keybind Reference

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
| `yy` / `Y` | Yank line |
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
| `if` / `af` | Inner / Around function (treesitter) |
| `ic` / `ac` | Inner / Around class (treesitter) |
| `ia` / `aa` | Inner / Around parameter (treesitter) |
| `ii` / `ai` | Inner / Around conditional (treesitter) |
| `il` / `al` | Inner / Around loop (treesitter) |

### Treesitter Navigation
| Key | Action |
|-----|--------|
| `]m` / `[m` | Next / Prev function start |
| `]]` / `[[` | Next / Prev class start |
| `]a` / `[a` | Next / Prev parameter |
| `Space na` | Swap parameter with next |
| `Space nA` | Swap parameter with previous |

### Flash (Jump Anywhere)
| Key | Action |
|-----|--------|
| `s{2 chars}` | Flash jump (labels all matches) |
| `S` | Flash treesitter select |

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
| `o` | Jump to other end of selection |

### Marks & Jumps
| Key | Action |
|-----|--------|
| `m{a-z}` | Set local mark |
| `'{a-z}` | Jump to mark line |
| `` `{a-z} `` | Jump to mark position |
| `Ctrl+o` / `Ctrl+i` | Jump back / forward |
| `gi` | Go to last insert position |

### Windows & Splits
| Key | Action |
|-----|--------|
| `Space v` | Vertical split |
| `Space ss` | Horizontal split |
| `Space qq` | Close window (smart — drops to empty buffer if last) |
| `Ctrl+w h/j/k/l` | Navigate splits |
| `Ctrl+w q` | Close split |
| `Ctrl+w o` | Close all other splits |
| `Ctrl+w =` | Equalize split sizes |
| `Ctrl+Left` / `Ctrl+Right` | Resize window width (-/+ 5 cols) |
| `Ctrl+Up` / `Ctrl+Down` | Resize window height (+/- 3 rows) |

### Buffers & Tabs
| Key | Action |
|-----|--------|
| `H` (Shift+h) | Previous buffer tab |
| `L` (Shift+l) | Next buffer tab |
| `Space bd` | Close current buffer |
| `Space bo` | Close all other buffers |
| `Space bh` | Close buffers to the left |
| `Space bl` | Close buffers to the right |
| `:e {file}` | Edit file |
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

## Custom Keymaps (init.lua)

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

### Neo-tree (File Tree Sidebar)
| Key | Action |
|-----|--------|
| `Space e` | Toggle file tree sidebar |
| `-` | Reveal current file in tree |
| `Ctrl+h` | Focus into neo-tree (from code) |
| `Ctrl+l` | Focus back to code (from neo-tree) |

Inside Neo-tree — Navigation:
| Key | Action |
|-----|--------|
| `j` / `k` | Move up / down |
| `l` / `Enter` | Open file / Expand folder |
| `h` | Collapse folder |
| `Backspace` | Navigate up a directory |
| `H` | Toggle hidden files |
| `.` | Toggle dotfiles |
| `/` | Filter / search |
| `<` / `>` | Navigate prev/next source (filesystem, buffers, git) |

Inside Neo-tree — Opening Files:
| Key | Action |
|-----|--------|
| `l` / `Enter` | Open in current window |
| `s` | Open in horizontal split |
| `v` | Open in vertical split |
| `t` | Open in new tab |
| `P` | Toggle preview |
| `S` | Open with system default |

Inside Neo-tree — File Operations:
| Key | Action |
|-----|--------|
| `a` | Add file/folder (end name with `/` for folder) |
| `d` | Delete |
| `r` | Rename |
| `y` | Copy file to clipboard |
| `x` | Cut file |
| `p` | Paste file |
| `c` | Copy (prompts for destination) |
| `m` | Move (prompts for destination) |

Inside Neo-tree — Other:
| Key | Action |
|-----|--------|
| `i` | Show file info |
| `R` | Refresh |
| `q` | Close tree |
| `?` | Show full help / all keybinds |

### LSP (active in any LSP buffer)
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

DAP UI opens/closes automatically on debug start/stop.

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

### Surround (nvim-surround)
| Key | Action |
|-----|--------|
| `ysiw"` | Surround word with `"` |
| `ysiw(` | Surround word with `( )` (with spaces) |
| `ysiw)` | Surround word with `()` (no spaces) |
| `ys$"` | Surround to end of line with `"` |
| `yss"` | Surround entire line with `"` |
| `cs"'` | Change `"` to `'` |
| `cs({` | Change `()` to `{}` |
| `ds"` | Delete surrounding `"` |
| `ds(` | Delete surrounding `()` |
| `S"` (visual) | Surround selection with `"` |

### Harpoon (File Bookmarks)
| Key | Action |
|-----|--------|
| `Space ha` | Add current file to harpoon |
| `Space hh` | Open harpoon menu |
| `Ctrl+1` | Jump to harpoon file 1 |
| `Ctrl+2` | Jump to harpoon file 2 |
| `Ctrl+3` | Jump to harpoon file 3 |
| `Ctrl+4` | Jump to harpoon file 4 |

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
| `Space gd` | Open git diff view |
| `Space gh` | File history (current file) |
| `Space gq` | Close diff view |

Inside Diffview:
| Key | Action |
|-----|--------|
| `Tab` | Next file |
| `Shift+Tab` | Prev file |
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

### Which-Key
| Key | Action |
|-----|--------|
| (any prefix, wait) | Shows available continuations |

Press `Space` and wait — which-key will pop up showing all leader binds.

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

Inside terminal:
| Key | Action |
|-----|--------|
| `Ctrl+\ Ctrl+n` | Exit terminal mode (back to normal) |

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

### VimTeX (LaTeX)
| Key | Action |
|-----|--------|
| `\ll` | Start/stop continuous compile |
| `\lv` | View PDF (zathura) |
| `\lc` | Clean aux files |
| `\lC` | Clean + PDF |
| `\lt` | Open ToC |
| `\le` | Show errors |
| `\lk` | Stop compilation |

(`\` = localleader, which is Space in your config — so `Space ll`, etc.)

### Overseer (Task Runner)
| Key | Action |
|-----|--------|
| `:OverseerRun` | Run a task |
| `:OverseerToggle` | Toggle task list |

### Projects
| Key | Action |
|-----|--------|
| `Space pp` | Browse recent projects (Telescope) |

### Fidget (LSP Progress)
Shows LSP indexing/progress automatically in the bottom-right. No keybinds.

### DAP Virtual Text
Shows variable values inline while debugging. Automatic when DAP is running.

### Treesitter Context
Shows the current function/class context at the top of the window automatically. No keybinds needed.

### Indent Blankline
Shows indent guides automatically. No keybinds.

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
| `:Telescope keymaps` | Search all keymaps |
| `:CMake*` | All cmake-tools commands |
| `:Trouble *` | All trouble commands |

---

<!-- BEGIN GENERATED: hypr — fox dev gen-keybinds; edit shared/hyprland_modules/keybinds.conf, not this -->

## Hyprland (ALT = mainMod)

### Applications

| Key | Action |
|-----|--------|
| `ALT + Enter` | Terminal (kitty + tmux) |
| `ALT + F` | Firefox |
| `ALT + Shift + C` | Cursor (code editor) |
| `ALT + Shift + D` | FoxML SysHub — rofi launcher (power, BT, Wi-Fi, wallpapers, themes, apps) |
| `ALT + Shift + M` | Steam |
| `ALT + Shift + Y` | Yazi file manager (toggle) |
| `ALT + Shift + T` | Btop system monitor (toggle) |
| `ALT + Shift + N` | Network / Wi-Fi menu |
| `ALT + Shift + B` | Bluetooth menu |
| `ALT + Shift + A` | Audio output switcher |
| `ALT + Shift + P` | Color picker (hyprpicker) |
| `ALT + Shift + I` | Discord |
| `ALT + Shift + O` | Screenshot (GUI editor) |
| `ALT + Shift + L` | Toggle displays off (DPMS) |
| `ALT + B` | Toggle Waybar |
| `ALT + W` | Cycle wallpaper |
| `ALT + V` | Clipboard history — text |
| `ALT + Shift + V` | Clipboard history — images |
| `ALT + Shift + K` | Panic kill — terminate runaway processes |
| `ALT + Shift + X` | Power menu |
| `ALT + Shift + E` | AI agent triage — pending Claude/Gemini notifications, hjkl, switches tmux to the originating pane |

### Media Keys

| Key | Action |
|-----|--------|
| `Vol +` | Raise output volume |
| `Vol −` | Lower output volume |
| `Mute` | Toggle mute |
| `Bright +` | Raise screen brightness |
| `Bright −` | Lower screen brightness |
| `Play` | Play / pause |
| `Next` | Next track |
| `Prev` | Previous track |
| `Stop` | Stop playback |

### Window Management

| Key | Action |
|-----|--------|
| `ALT + T` | Toggle window group (tabbed stack) |
| `ALT + [` | Previous window in group |
| `ALT + ]` | Next window in group |
| `ALT + P` | Pin window above all workspaces |
| `ALT + S` | Toggle split direction |
| `ALT + Shift + Q` | Close the active window |
| `ALT + Shift + G` | Toggle floating |
| `ALT + Shift + G` | Center the floating window |
| `ALT + Shift + R` | Reload Hyprland |

### Window Focus

| Key | Action |
|-----|--------|
| `ALT + h` | Move focus left |
| `ALT + j` | Move focus down |
| `ALT + k` | Move focus up |
| `ALT + l` | Move focus right |
| `ALT + Shift + Tab` | Cycle to previous window |
| `ALT + Tab` | Jump focus through only floating windows (skip tiled) |
| `ALT + Ctrl + Tab` | Cycle tiled windows |
| `ALT + /` | Searchable keybind cheatsheet — fuzzy-find any binding by description |

### Workspaces

| Key | Action |
|-----|--------|
| `ALT + ,` | Previous workspace |
| `ALT + .` | Next workspace |
| `ALT + 1–9` | Switch to workspace |
| `ALT + Shift + 1–9` | Move window to workspace |

### Sandbox launcher

| Key | Action |
|-----|--------|
| `ALT + Shift + S` | Rofi-driven picker for one-shot sandboxed apps |

### Ghost Mode (boss key)

| Key | Action |
|-----|--------|
| `ALT + G` | Boss key — hide waybar, mute audio, opacify + blur everything |

### Window switcher (rofi)

| Key | Action |
|-----|--------|
| `ALT + Grave` | Active-windows picker (rofi) |

### TTY switch (diagnostics)

| Key | Action |
|-----|--------|
| `Ctrl + ALT + F1–F6` | CTRL+ALT+F1..F6 switches to a kernel TTY while Hyprland is responsive |

### Resize / move submap

| Key | Action |
|-----|--------|
| `ALT + R` | Resize / move mode |
| `h/j/k/l` | Resize the focused window |
| `Shift + h/j/k/l` | Move the focused window |
| `Esc/Enter` | Exit this mode |

<!-- END GENERATED: hypr -->

---

<!-- BEGIN GENERATED: tmux — fox dev gen-keybinds; edit templates/tmux/.tmux.conf, not this -->

## Tmux (Ctrl+a prefix)

| Key | Action |
|-----|--------|
| `Ctrl+a Ctrl+a` | Send a literal Ctrl+a through to the running program |
| `Ctrl+a h/j/k/l` | Navigate panes — vim-style hjkl |
| `Ctrl+a H/J/K/L` | Resize the active pane (repeatable — hold the modifier) |
| `Ctrl+a \|` | Split the active pane left ↔ right |
| `Ctrl+a -` | Split the active pane top ↕ bottom |
| `Ctrl+a c` | New window in the current pane's directory |
| `Ctrl+a Tab` | Jump back to the last-used window |
| `Ctrl+a q` | Show pane numbers — flash the overlay, then press a number to jump to that pane |
| `Ctrl+a w` | Fuzzy session switcher / project launcher (replaces choose-tree) |
| `Ctrl+a G` | Lazygit on the current pane's repo, in a themed float |
| `Ctrl+a a` | Ask your local model (fox-ai-oracle) without leaving the terminal |
| `Ctrl+a e` | Mirror keystrokes to all panes in the current window |
| `Ctrl+a m` | Move current pane to a brand-new session and switch this client to it |
| `Ctrl+a M` | Pop current pane into its OWN kitty window (drag to portrait monitor) |
| `Ctrl+a [` | Enter copy / scrollback mode — vi keys to scroll, search (/), and select |
| `v (copy mode)` | Begin a selection |
| `y (copy mode)` | Copy the selection to the system clipboard (wl-copy) |
| `r (copy mode)` | Block-selection toggle |
| `Y (copy mode)` | Yank the whole line |
| `Ctrl+a r` | Reload config |
| `Ctrl+Shift+a` | Send the prefix through to a nested tmux session |

<!-- END GENERATED: tmux -->
