# Neovim Keybind Reference

Leader: **Space** | Local leader: **Space**

**Space Space** opens the home menu: what applies where the cursor is, in one menu (see *The home menu* below).

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
| `Alt+h/j/k/l` | Focus the desktop window or monitor that way directly; `Ctrl+h/j/k/l` moves between editor splits |
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

The call graph (desk.callgraph); "in a graph" means the graph tab and the live panel both:

<!-- callgraph-keys:begin · generated from shared/nvim_lua/desk/callgraph.lua: python3 tests/test_nvim_keys.py --write -->
| Key | Action |
|---|---|
| `Space cc`, `:CallGraph` | Call graph of the function under the cursor, in a tab: callers above, the function in a double box, what it calls below (the language server's call hierarchy). It opens with the function's box selected. One tab: pressed again anywhere, it brings that tab back on the function under the cursor |
| `Space co`, `:CallGraphPanel` | Live call graph panel: a narrow split on the right that follows the cursor and redraws when the function under it changes. It never takes the focus (`Ctrl+w l` goes into it); `p` in it pins it to the graph it shows (`PINNED`), `p` again follows the cursor |
| `j` / `k` in a graph | The box below / above (the nearest one in that row) |
| `h` / `l` in a graph | The box to the left / right in the same row |
| `Tab` / `Shift+Tab` / `gg` / `G` in a graph | Every box in order, wrapping; the first / last box |
| `s` in a graph | Labels on the boxes on screen, as `s` draws them in code (flash.nvim): typing one selects that box, as `j` and `k` would; `Enter` still goes |
| `Enter` in a graph, a double click | Go to the selected box's function, in the code window the graph came from; the graph stays open (a click, or any motion that lands in a box, selects it) |
| `<BS>` in the graph tab | Back to that code window as it was, the graph left open |
| `c` in a graph | Centre the graph on the selected box: its own callers and callees (in the panel and the pop-out it is pinned there; `p` follows again) |
| `+` in a graph | Read the next level on the selected side. From the centre, expand callees. |
| `-` in a graph | Collapse the outermost level on the selected side, or cancel the level being read |
| `m` in a graph | Draw the callers and callees past the first 24 on each level (where it says "+N more") |
| `r` in a graph | Ask the language server for the graph again (a graph that follows the cursor: for the function under it) |
| `q` in the graph tab | Close the graph tab |
| `gs` in a graph | The selected box's function in symdeps' card (C and C++), shown in the code — in the tab, the panel and the pop-out alike |
| `t` in a graph | The project map's trace through the selected function: up to where it starts, down to where it ends, each step with its parameters and the arguments it is called with |
| `p` in the panel | Pin the panel to the graph it shows (PINNED), or follow the cursor again |
| `q` in the panel | Close the panel |
| `o` in a graph | Move this graph to the pop-out on the other screen (opening it) and close it here; `o` there brings it back as a split |
| `?` in a graph | The keys of this view as a list: `Enter` runs the selected one, `?` or `q` closes the list |
<!-- callgraph-keys:end -->

The pop-out (desk.popout): views in a Neovim window of its own, on the other screen; the call graph is the first.
Space Space → views → "Pop out the call graph" opens it on the function under the cursor, and `o` in a graph sends that
graph there (both need a second monitor; with one, the row says so and the graph stays here). Each view is a tab page:
the tab line is the header (each view by number, `PINNED`, `✱` when something new arrived) and each window's status
line is that view's keys. A view there has the keys of its place here (the graph has the graph tab's: moves, `s`,
Enter, `c`, `r`, `gs`) and the window's own below. Going to a box never closes it: Enter moves this editor there and
the keyboard stays in the pop-out; `f` or Shift+Enter puts the keyboard here too; `Ctrl+o` or Backspace goes back
(this editor too). `Space Tab` in either window puts the keyboard in the other, on whichever screen it is.

<!-- popout-keys:begin · generated from shared/nvim_lua/desk/popout.lua: python3 tests/test_nvim_keys.py --write -->
| Key | Action |
|---|---|
| `Space Tab` | Put the keyboard in the pop-out window, on whichever screen it is (with several, the first); the same key there goes on to the next, and from the last back here |
| `f` / `Shift+Enter` in the pop-out | What `Enter` does (go to the selected box or row in the editor), and the keyboard goes to the editor too; where `Enter` only acts in the view (a zoom, a fold) the keyboard stays |
| `p` in the pop-out | Pin this view (PINNED: it stays as it is while the editor moves, and `Enter` visits its items one by one), or follow the editor's cursor again |
| `o` in the pop-out | This view back to the editor as a split (the call graph as the live panel), pinned if it is pinned here; the pop-out stays open |
| `H` / `L` / `gt` / `gT` in the pop-out | The previous / next tab (`2gt` goes to the second) |
| `<C-o>` / `<BS>` in the pop-out | Back where you were: the view before, the graph before a centre, the code spot before `Enter` (the editor goes back too) |
| `<C-r>` in the pop-out | Forward again, after going back |
| `/` in the pop-out | Every box or row of this view by its whole name, filtered as you type; `Enter` selects it |
| `?` in the pop-out | The keys of this view in the pop-out, in a list |
| `Space Tab` in the pop-out | Put the keyboard in the next pop-out, and from the last one in the editor (with one pop-out: the editor); the same key in the editor comes to the first |
| `q` in the pop-out | Close this view; closing the last one closes the pop-out, and the keyboard comes back to the editor |
| `Space dm` in the pop-out | symdeps' menu key: here, this window's menu for the view in front, as `Space Space` (on symdeps' board, its rows) |
| `Space dd` in the pop-out | symdeps' card key: here it says why not (on symdeps' board, the card is the one drawn; elsewhere symdeps runs in the editor, `Space Tab` away) |
| `Space Space` in the pop-out | The home menu for the selected box or row: the views, what the editor can do with it, and this window |
<!-- popout-keys:end -->

The project map (desk.map): the whole checkout as boxes, rebuilt only when asked. "In the map" means its tab, one per
checkout; `Space cm` from anywhere brings it back as it was. Without desk-work it opens and says "requires desk-work".
`o` moves it to the pop-out (also Space Space › "Pop out the project map"): there `Enter`, `-`, `D`, `U`, `c`, `P`, `r` and `R`
work on the box selected there, `Ctrl+o` and Backspace go back through its zooms, and `o` brings it back as its tab.

<!-- map-keys:begin · generated from shared/nvim_lua/desk/map.lua: python3 tests/test_nvim_keys.py --write -->
| Key | Action |
|---|---|
| `Space cs` | While the debugger is stopped: its stack, frame by frame (`Enter` opens each), and which of the stopped function's callers in the map are on it — the live caller or the replay one |
| `Space cp` | The path through the function at the cursor, up to where it starts and down to where it ends, with each step's parameters and the arguments it is called with (in the pop-out's map when it shows one) |
| `Space cm`, `:ProjectMap` | The whole checkout as boxes, by part, file and function, callers above; queries and a rebuild inside. One tab per checkout: pressed again, it brings that tab back as it was, or the map out in the pop-out back as the tab |
| `Enter` in the map | Zoom into the part, file or class under the cursor; on a function, go to its code (the map stays open) |
| `<BS>` / `-` in the map | Zoom out a level (from a query's answer, back to the page it was asked on); at the top, back to the code, the map left open. On a callers or reach page of more than one level, `-` takes a level off instead |
| `+` in the map | Read another level on the callers or reach page |
| `D` in the map | Everything a function reaches, down the calls (a count before `D` is the depth; 3 without one) |
| `U` in the map | Who calls a function, up the calls, transitively (a count before `U` is the depth) |
| `c` in the map | The call graph centred on the selected function, where the map is: a graph tab here, the call graph in the pop-out (`Ctrl+o` there comes back to the map) |
| `t` in the map | The lane through the selected function: up to where it starts, down to where it ends; each step with its parameters (how each is passed, and whether the callee can change it) and what it is called with. In the pop-out it follows the function at the cursor (`p` pins it) |
| `e` in the map | On a trace: down to the function you name instead of where the chain ends |
| `S` in the map | On a trace: up from the function you name (a thread body, the live path) instead of the farthest start |
| `x` in the map | On a trace, on a `══[ handoff ]══`: the map inferred it wrongly, so it is dropped (one you added is forgotten). Kept by desk-work outside the checkout, in `~/.config/foxml/desk.d/` |
| `a` in the map | On a trace: this function hands its data on to the one you name (a queue or a callback the map missed), so the trace goes on through it |
| `F` in the map | On a trace: the findings of the checkout's tools (desk-work's, docs/desk-tools.md) that fall inside the route's functions, each with its tool; `Enter` opens its line |
| `y` in the map | On a trace: its question, the checkout's revision, each step with its file:line, the handoffs it relies on and a sentence of yours, as Markdown for a review, an issue or the notebook |
| `gs` in the map | The selected function in symdeps' card (C and C++), shown in the code, as `gs` in the call graph |
| `P` in the map | Every way from one function to another, shortest first |
| `m` in the map | Show the boxes and calls left out of this page |
| `M` in the map | Go to a part of the checkout, picked by name |
| `r` in the map | Read this page again, as `r` does in a call graph: desk-work's status and the level shown (a query's answer is asked again); `R` rebuilds the map |
| `R` in the map | Rebuild the map in the background (a desk-work job; its log is in the jobs list) |
| `B` in the map | Rebuild, reading a built binary for its exact calls (remembered for the next builds) |
| `q` in the map | Close the project map |
| `o` in the map | Move this map to the pop-out on the other screen (opening it) and close it here; `o` there brings it back as this tab, as it was |
| `j` / `k` in the map | The box below / above (the nearest one in that row) |
| `h` / `l` in the map | The box to the left / right in the same row |
| `?` in the map | The keys of this view as a list: `Enter` runs the selected one, `?` or `q` closes the list |
<!-- map-keys:end -->

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

### Jupyter notebooks (jupytext · molten)
An `.ipynb` opens as Markdown: code cells are ```` ```python ```` blocks, outputs show in a frame under the cell
when the cursor is in it. These keys exist only in notebooks; the first run starts the notebook's kernel.
`:w` saves the `.ipynb` with its outputs. More: [docs/desktop.md](../docs/desktop.md#jupyter-notebooks).

<!-- jupyter-keys:begin · generated from the desk-jupyter block of templates/nvim/init.lua: python3 tests/test_nvim_keys.py --write -->
| Key in a notebook | Action |
|---|---|
| `Shift+Enter` (also in insert mode) | Run the cell, go to the next |
| `Space jj` | Run the cell |
| `Space ja` | Run all cells |
| `Space jk` | Run the cells above |
| `]j` | Next code cell |
| `[j` | Previous code cell |
| `Space jo` | New code cell below |
| `Space jO` | New code cell above |
| `Space jm` | New Markdown cell below |
| `Space je` | Enter the cell's output (scroll it; q closes) |
| `Space jc` | Clear all outputs |
| `Space jx` | Interrupt the kernel |
| `Space jR` | Restart the kernel |
| `Space ji` | Choose the kernel |
<!-- jupyter-keys:end -->

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

### The home menu (desk.actions)
**Space Space** opens one menu of what applies where the cursor is, in groups: this function (its call graph, the live
panel, and symdeps' card in C and C++), the project map, the review, Claude, work, symdeps (its own menu, or one
"requires symdeps" row when it is not installed), and the views of the pop-out. In a review, the call graph, the map or
the since page, that place's own keys lead. It is drawn like the review's Actions, by symdeps' menu when it is installed and
a built-in one to the same rules otherwise: `j`/`k` select, Enter runs, `/` filters, `q` closes. A row that cannot run
here says why instead of running.
`?` in a review, a call graph, the project map, the since page or a menu lists that place's keys from the same rows
(Enter runs one, `?` or `q` closes the list); in code `?` stays backward search. Every key in the table below, the
review's, the call graph's and the map's is a row of one list, `shared/nvim_lua/desk/actions.lua`, which also gives
which-key its words.

<!-- desk-keys:begin · generated from the action registry (shared/nvim_lua/desk/actions.lua): python3 tests/test_nvim_keys.py --write -->
| Key | Action |
|---|---|
| home menu: Pop out symdeps' board | symdeps' board, its cards at the pop-out's width. symdeps is an optional plugin |
| home menu: Restore the pop-out's views | Open the pop-outs again with the views they had when this editor last closed, pinned as they were, each on the screen it was on |
| home menu: This pop-out to another screen | Asks which screen (every one, this one too); the pop-out (the one this is pressed in; in the editor the one last used) moves there now if it is open, and opens there from now on, this session |
| home menu: Pop out the call graph | The live call graph in the pop-out, a window of its own on the other screen: it follows the function under the cursor (`p` there pins it), and `Enter` there goes to a function here while the keyboard stays there |
| home menu: Review list to the pop-out | The open review's file list in the pop-out on the other screen: the comparison takes this whole screen, and `Enter` there shows a file here while the keyboard stays there |
| `Space cv` | Show a live copy of this file, including unsaved changes |
| home menu: Pop out the project map | The project map in the pop-out, a window of its own on the other screen: `Enter` there zooms in, or goes to a function here while the keyboard stays there; `-` and `Backspace` go back out |
| `Space Space` | Everything that applies where the cursor is, in one menu: this function, the review, Claude, work, symdeps |
| home menu: This function in symdeps | symdeps' card for the unit at the cursor: its layout, uses, callers and calls |
| `Space cc`, `:CallGraph` | Call graph of the function under the cursor, in a tab: callers above, the function in a double box, what it calls below (the language server's call hierarchy). It opens with the function's box selected. One tab: pressed again anywhere, it brings that tab back on the function under the cursor |
| `Space co`, `:CallGraphPanel` | Live call graph panel: a narrow split on the right that follows the cursor and redraws when the function under it changes. It never takes the focus (`Ctrl+w l` goes into it); `p` in it pins it to the graph it shows (`PINNED`), `p` again follows the cursor |
| `Space cs` | While the debugger is stopped: its stack, frame by frame (`Enter` opens each), and which of the stopped function's callers in the map are on it — the live caller or the replay one |
| `Space cp` | The path through the function at the cursor, up to where it starts and down to where it ends, with each step's parameters and the arguments it is called with (in the pop-out's map when it shows one) |
| `Space cm`, `:ProjectMap` | The whole checkout as boxes, by part, file and function, callers above; queries and a rebuild inside. One tab per checkout: pressed again, it brings that tab back as it was, or the map out in the pop-out back as the tab |
| `Space Cw` | Changes tree: working changes (including unsaved drafts), live sessions and the most recent 80 commits |
| `Space Cr`, `:ReviewNext` | Review the next thing that needs you: a requested change whose file has changed, a file edited since you reviewed it, else the oldest unreviewed Claude commit |
| `Space Cd` | Show this file in the current review panes |
| `Space Cq` | Close all Claude review tabs and the file list; stop following |
| `Space CR` | Review the uncommitted changes on API credits, read-only; you choose the model and a budget first |
| `Space Cn` | Note to a Claude: the file, or the selection (visual), and a line of text; it arrives as an envelope and Claude reads it as your words |
| `Space Cj` | Go to the pane of the Claude that edited this buffer |
| `Space Cp`, `:Plan` | The plan the sessions in this repo read last |
| `Space Ca` | Ask about this project on API credits, read-only (a visual selection goes along as an excerpt) |
| `Space Ce`, `:WorkTests` | The last test run's failures as a jump list (its log when it has no locations) |
| `Space Ck` | Pinned next steps for this project: pin one, mark it done, or turn it into a note for Claude |
| `Space Ch`, `:WorkSince` | Since you last looked: new commits, test runs, job runs with how their figures moved, and Claude turns with their files, newest first; `Enter` opens one (a commit's review, the results, the output, the turn's changes, a file). Opening it marks now as looked; with nothing new it shows the last list again |
| home menu: Figures | The newest job's figures against its previous run (desk-work metrics); `Enter` on one opens that job's output |
| home menu: symdeps | symdeps' own menu (`Space dm`): its cards, lists and checks for C and C++ code. symdeps is an optional plugin |
| `Space Tab` | Put the keyboard in the pop-out window, on whichever screen it is (with several, the first); the same key there goes on to the next, and from the last back here |
<!-- desk-keys:end -->

### The other Claudes (desk.claude)
Reads what the paper mod and `desk-drawer` keep in `$XDG_RUNTIME_DIR/foxml-claude`, and git. A buffer a live
Claude edited in the last 15 minutes shows `✎ <session> · 3m` in the statusline and a `✎` in the bufferline; the
first change you make to it says which session to coordinate with. The statusline also shows `gate open ✓` /
`plan first ✎` (repos with a plan gate) and `● <session>` while one needs you. Press `Space C` and wait: which-key
lists the `Space C` keys (the table above, and these) under **Claude**, in normal and visual mode. The statusline's
right side also shows the newest test run of the buffer's checkout as desk-work recorded it: `✓ 128`, `✗ 2 failed` or
`◷ running` (retro: `√ 128`, `2 FAILED`, `☼ RUNNING`), and nothing when there is no run.

| Key | Action |
|-----|--------|
| `:WorkAttention` | Shared project attention list: failed jobs, agents needing input and changes to review; it can set the review backlog aside and bring it back |
| `Space Cm` | Plan marks, by step: the places the plan names |
| `]n` / `[n` | Next / previous plan mark |
| `Space tP`, `:PlanMarksToggle` | Show or hide plan marks; `:PlanMarks [plan.md]` marks the places a plan names |
| `:WorkNext` | Open the first item in the shared attention list |
| `:WorkTimeline` | Project activity with links to files, results and reviews |
| `:WorkDigest` | Changes since your last explicit acknowledgement |
| `:WorkSnooze` / `:WorkUnsnooze` | Hide or restore shared attention items without settling them |
| `:WorkSuggestedTests` | Choose a captured test command and confirm a run in its original folder |
| `:WorkSave` / `:WorkResume` | Save file positions or restore them in new tabs, preserving current buffers and jobs |
| `:WorkHealth` | Shared refresh/connection/version diagnostics and sessions on older code with their reload steps; **r** refreshes, **R** offers guarded update recovery, **F** repairs unreadable records |
| `:WorkRepair` | Preview setting an unreadable work record aside (the original is kept); **D** makes the previewed repair |
| `:WorkBackups` | Preview update backup usage and cleanup; **D** asks before removing the reviewed selection |

In What changed, Enter opens a read-only review tab with a file sidebar and Before / After panes.
Click a commit to expand it, click a file to compare it, or click its checkbox to mark it reviewed.
**Check & next** walks unread files and becomes **Finish & next** when the commit is checked.
Files expand into changed functions/types (or changed line ranges when a parser is unavailable).
Select a child to jump straight to that change. A finished commit advances to the next unchecked commit.
The sidebar is a tree: Working changes, then each plan with its commits oldest first (by branch and day when there
are no plan files), then other commits. Marks: `✓` reviewed, `↻` edited since you reviewed it or since you asked for
a change, `✉` waiting on a change request, `○` not yet, `⚠` needs care; the strip under the list says why.
**Actions** (`a` in the list, its row in Space Space anywhere in the review, or click the title) contains the other
operations; the shortcuts below are optional, and `?` lists them.
Actions uses the symdeps menu style and navigation, with symdeps' own renderer when it is installed and a built-in
menu to the same rules otherwise: `j/k` or arrows select, Enter / `l` runs, `/` filters, and `h`, `q` or Escape
closes. Click a row to run it. Toggles show their state and keep the menu open; the description below the rows
explains the selected action.
Committed reviews compare the exact parent and selected commit; later working changes are excluded.
Live reviews capture the current working copy (including unsaved buffers); `r` refreshes it.
Checking a live file is invalidated when its contents change. Files with missing snapshots cannot be checked.

<!-- review-keys:begin · generated from shared/nvim_lua/desk/review.lua: python3 tests/test_nvim_keys.py --write -->
| Key in the review | Action |
|---|---|
| `Enter` / `l` in the file list | Open the selected file in the comparison panes; on a commit, expand or collapse its changed files |
| `j` / `k` in the file list | The row below / above, over headings and blank lines |
| `h` in the file list | Collapse changed functions first, then the selected commit |
| `]f` / `[f` / `Tab` / `Shift+Tab` | Next / previous file |
| `]c` / `[c` | Next / previous changed block |
| `m` | Check or uncheck the file as reviewed |
| `u` | Resume at the first unchecked file (files with a risk mark or ready for re-review first) |
| `n` (list) / `Space rn` (diff) | Only what is new since you reviewed a file / the whole change (remembered) |
| `c` | Request changes: a note about this file or the selected lines to a Claude session; the file waits on it |
| `a` in the file list | Actions: every action of this review, with what each needs (also a row of `Space Space`) |
| `A` | Open the saved API review of this file (Actions has "API review: file / change" and "Explain this hunk") |
| `P` | Plan coverage: each plan step with the commits that touched it, steps not started, files outside the plan |
| `N` | Note to self on this line; it stays with the file in every later review (`:ReviewNotes` lists them) |
| `R` | Finish after every file is checked, then choose: open the next unchecked commit, close the review, or stay; this clears the finished commit from pending reviews |
| `Space rw` | Show / hide whitespace differences |
| `Space rc` | Six context lines / full-file context |
| `<BS>` in a diff | Back to the file list from a comparison pane, showing it again if it was hidden (or in the pop-out) |
| `Space re`, `:ReviewFiles` | Toggle the review file list, keeping the comparison open; `Space e` keeps its normal Neo-tree binding |
| `s` in the file list | Labels on the rows on screen, as `s` draws them in code (flash.nvim): typing one moves there, as `j` and `k` would; `Esc` stays |
| `gs` / `Space dd` | Inspect the changed C/C++ file in symdeps (current working copy near the reviewed line) |
| `Space dm` | Open symdeps in the working C/C++ file near the reviewed line |
| `gf` | Open the editable working file in a separate tab |
| `S` | Compare the current struct's layout with the selected commit's parent |
| `r` | Refresh the comparison |
| `f` in the file list | Follow the selected live session's edits in a separate tab (`:ClaudeFollow` stops) |
| `o` in the file list | Move the file list to the pop-out on the other screen (it opens): the comparison takes this whole screen, `Enter` there shows a file here while the keyboard stays there; `o` there brings the list back |
| `q` / `Esc` in the file list, `:q` there | Hide the file list; the diff keeps its file, cursor and folds |
| `Esc` in a diff | Clear search highlighting |
| `q` (diff) / `Space bd`, `:q` in a diff, `Space Cq` | Close the whole review and return to your editor |
| `?` | The keys of this view as a list: `Enter` runs the selected one, `?` or `q` closes the list |
<!-- review-keys:end -->

`Space Cn` (normal or visual) sends a note with the real filename, the selected side and both versions of the
changed block.

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
| `Space` | Home menu (Space Space): what applies where the cursor is |
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
| `j …` | Jupyter, in notebooks (see Jupyter notebooks above) |
| `q s` | Restore session (cwd) |
| `q l` | Restore last session |
| `q d` | Stop session recording |
| `s r` | Search & Replace (Spectre) |
| `s w` | Search word / selection |
| `x x` | Diagnostics |
| `x q` | Quickfix |
| `c f` | Format |
| `c c` | Call graph of this function |
| `c o` | Live call graph panel |
| `s s` | Horizontal split |
| `q q` | Close window |
| `/` | Toggle comment |
| `w` | Save file |
| `X` | Make file executable |
| `t d` | Toggle diagnostic virtual text |
