# Neovim Keybind Reference

Leader: **Space** | Local leader: **Space**

Paper bookmark ribbons and folded-note bindings are listed in the full reference:
press **Alt+/** and search for **Paper notebook details**.

Files open with their comments folded. **Space tc** switches that off or on (remembered
for new files too) and **Space tC** refolds every comment
in the current window, including after `zR`. **zo** opens one comment, **zc** closes
it, and **zR** opens all. `:CommentRefold` also enables/refolds comments. Turning
comment folding off restores the window's previous folding settings.

API tasks (monthly API credits, read-only): **Space Ca** asks about this project (a visual
selection goes along as an excerpt), **Space CR** reviews its uncommitted changes, and
`:ClaudeApiStop` cancels. In an answer, **Enter** opens a cited `path:line`, **f** asks a
follow-up and **q** closes; every citation is also in the quickfix list (`:copen`).

Useful controls: **Space tw** toggles line wrapping, **Space tf** toggles automatic formatting for the
current file, and **Space ti** toggles type/parameter hints. **Space cf** always formats explicitly.
**Space ff** and **Space fg** include hidden project files while respecting Git ignores and excluding `.git`.
Enter in the completion menu accepts an explicitly selected suggestion; select one with Tab or arrows first.

Outside agents' saves update clean buffers automatically. If you have unsaved edits too, **Space Cu** compares
your buffer with the disk copy, and **Space Cl** merges non-overlapping changes, leaving them unsaved.
Overlapping changes keep both copies. A save waits until you resolve the outside edits;
`:AgentKeepMine` explicitly keeps your buffer for the next save. Text files up to 2 MiB are watched.
You can also click the **outside edits** status to choose Compare, Merge or Keep mine from a menu.

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
| `M` | Middle of screen (H/L switch buffers in this config) |
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

### Multicursor (multicursor.nvim)
| Key | Action |
|-----|--------|
| `↑` / `↓` | Add a cursor on the line above / below |
| `Ctrl+n` | Add a cursor at the next match of the word (or the selection) |
| `Space kn` / `Space kN` | Add at the next / previous match |
| `Space ks` / `Space kS` | Skip the next / previous match |
| `Space ka` | Add a cursor at every match in the file |
| `Space kj` / `Space kk` | Skip the line below / above |
| `Space kl{motion}` | One cursor per line (`Space klip` = each line of the paragraph; in visual: each selected line) |
| `Space kr` | Bring back the cursors you just cleared |
| `Space k=` | Line the cursors up in one column |
| `Ctrl+q` | Add / remove a cursor here (then move, and add another) |
| `Ctrl+click` | Add / remove a cursor at the click |
| `←` / `→` *(with cursors)* | Make the previous / next cursor the main one |
| `Space kx` *(with cursors)* | Delete the main cursor |
| `Esc` *(with cursors)* | Clear the cursors (or turn them back on after `Ctrl+q`) |

Everything you type, delete, paste or run (`.`, macros) happens at every cursor.

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
| `Space gp` / `:Gitsigns preview_hunk` | Preview change |
| `Space gs` / `:Gitsigns stage_hunk` | Stage hunk |
| `Space gu` / `:Gitsigns undo_stage_hunk` | Undo stage |
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
| `Enter` | Confirm a completion selected with Tab/arrows; otherwise insert a newline |
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

Ghost-text suggestions appear automatically when inline mode is active. Use `Ctrl+l` to accept the full suggestion, or `Ctrl+;` / `Ctrl+'` to accept partially. The same keys accept the **local** model's suggestions when that is on (below).

| `Space ag` | Toggle between inline ghost-text and cmp menu mode |
| `Space at` | Completion engine: Copilot ⇄ the local model (one at a time) |

**Modes:** Copilot can run in two modes — **inline** (ghost-text ahead of cursor, accept with `Ctrl+l`) or **cmp menu** (suggestions appear in the autocomplete popup alongside LSP). Toggle with `Space ag`.

### Local AI (llama.cpp — CodeCompanion · pi · local completion)
Everything here runs on your machine through llama.cpp's router; nothing leaves it.

| Key | Action |
|-----|--------|
| `Space aa` | AI actions menu (CodeCompanion) |
| `Space ac` | Toggle the AI chat (the roles file's quick model — qwen3.5:4b) |
| `ga` (visual) | Add the selection to the chat |
| `Space ai` | Inline edit — ask for a change to the selection / at the cursor (the quick model); it comes back as a diff to accept |
| `Space ap` | pi — the local coding agent, in a split (multi-file work; pi's own model, `~/.pi/agent/settings.json`) |
| `Space at` | Ghost-text completion: Copilot ⇄ local (qwen2.5-coder:1.5b) |

In the chat, `#{buffer}` shares the current file, `#{diagnostics}` its errors; `/file` adds another file.
The GPU has 4 GB: a 3B model fits whole (fast), a 7B spills a little to the CPU; the 30B-A3B models (pi's) run
from RAM and are the best at multi-step agent work.

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

### The other Claudes (foxml.claude)
Reads what the paper mod and `desk-drawer` keep in `$XDG_RUNTIME_DIR/foxml-claude`, and git. A buffer a live
Claude edited in the last 15 minutes shows `✎ <session> · 3m` in the statusline and a `✎` in the bufferline; the
first change you make to it says which session to coordinate with. The statusline also shows `gate open ✓` /
`plan first ✎` (repos with a plan gate) and `● <session>` while one needs you.

| Key | Action |
|-----|--------|
| `Space Cw` | Changes tree: working changes (including unsaved drafts), live sessions and the most recent 80 commits |
| `Space Cn` | Note to a Claude: the file, or the selection (visual), and a line of text; it arrives as an envelope and Claude reads it as your words |
| `Space Cj` | Go to the pane of the Claude that edited this buffer |
| `Space Cd` | Show this file in the current review panes |
| `Space Cq` | Close all Claude review tabs and the file list; stop following |
| `Space Cp` | The plan the sessions in this repo read last (`:Plan`) |

In What changed, Enter opens a read-only review tab with a file sidebar and Before / After panes.
Click a commit to expand it, click a file to compare it, or click its checkbox to mark it reviewed.
**Check & next** walks unread files and becomes **Finish & next** when the commit is checked.
Files expand into changed functions/types (or changed line ranges when a parser is unavailable).
Select a child to jump straight to that change. A finished commit advances to the next unchecked commit.
The sidebar is a tree: Working changes, then each plan with its commits oldest first (by branch and day when there
are no plan files), then other commits. Marks: `✓` reviewed, `↻` edited since you reviewed it or since you asked for
a change, `✉` waiting on a change request, `○` not yet, `⚠` needs care; the strip under the list says why.
**Actions** (`a`, or click the title) contains the other operations; the shortcuts below are optional.
Actions uses the symdeps menu style and navigation, with symdeps' own renderer when it is installed and a built-in
menu to the same rules otherwise: `j/k` or arrows select, Enter / `l` runs, `/` filters, and `h`, `q` or Escape
closes. Click a row to run it. Toggles show their state and keep the menu open; the description below the rows
explains the selected action.
Committed reviews compare the exact parent and selected commit; later working changes are excluded.
Live reviews capture the current working copy (including unsaved buffers); `r` refreshes it.
Checking a live file is invalidated when its contents change. Files with missing snapshots cannot be checked.

| Key in the review | Action |
|---|---|
| `Enter` in the sidebar | Open the selected file in the same comparison panes |
| `Enter` / `l` on a commit | Expand / collapse its changed files |
| `h` | Collapse changed functions first, then the selected commit |
| `]f` / `[f`, `Tab` / `Shift+Tab` | Next / previous file |
| `]c` / `[c` | Next / previous changed block |
| `m` | Check or uncheck the current file as reviewed |
| `Space` (in the sidebar) | Check or uncheck the selected file |
| `u` | Resume at the first unchecked file (files with a risk mark or ready for re-review first) |
| `n` (sidebar) / `Space rn` | Only what is new since you reviewed a file / the whole change (remembered) |
| `c` | Request changes: a note about this file or the selected lines to a Claude session; the file waits on it |
| `a` (sidebar) / `?` | Actions |
| `A` | Open the saved API review of this file (Actions has "API review: file / change" and "Explain this hunk") |
| `P` | Plan coverage: each plan step with the commits that touched it, steps not started, files outside the plan |
| `N` | Note to self on this line; it stays with the file in every later review (`:ReviewNotes` lists them) |
| `R` | Finish after every file is checked and open the next unchecked commit; this clears the finished commit from pending reviews |
| `Space rw` | Show / hide whitespace differences |
| `Space rc` | Six context lines / full-file context |
| `Space e` | Focus the review file list |
| `Space Cn` (normal or visual) | Send a note with the real filename, selected side and both versions of the changed block |
| `s` | Inspect the changed C/C++ file in symdeps (current working copy near the reviewed line) |
| `gf` | Open the editable working file in a separate tab |
| `S` | Compare the current struct's layout with the selected commit's parent |
| `r` | Refresh the comparison |
| `?` | Review help |
| `q`, `:q`, `Esc`, `Space Cq` | Close the whole review and return to your editor |

Checkmarks are saved in Neovim's state directory under `foxml-reviews/`; reopening resumes at the first
unchecked file. Opening a commit alone never marks it reviewed. Existing quickfix entries, ordinary
editor keymaps and unsaved buffers are preserved. A viewer launched from the notebook or drawer exits
in one action. `f` on a live session follows its edits in a separate tab; `:ClaudeFollow` stops following.
Blame names the session behind Claude's lines (`✿ <session> · 2h · <summary>`) and marks yours `● you`.


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
| `g p` | Preview Git hunk |
| `g s` | Stage Git hunk / selected lines |
| `g u` | Undo staging Git hunk |
| `t w` | Toggle line wrapping |
| `t f` | Toggle format on save for this file |
| `t i` | Toggle type / parameter hints |
| `a g` | Copilot toggle inline/cmp |
| `a t` | Completion: Copilot in public repos ⇄ local everywhere |
| `a a` | AI actions (CodeCompanion, local) |
| `a c` | AI chat (local) |
| `a i` | AI inline edit (local) |
| `a p` | pi agent (local) |
| `C t` | Claude toggle terminal |
| `C s` | Claude send selection |
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
