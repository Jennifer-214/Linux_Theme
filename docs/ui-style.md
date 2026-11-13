# UI style

[← Back to the README](../README.md)

One look for every menu, list and panel. The reference is the symdeps plugin's menu: where symdeps is installed its
own renderer draws the Neovim menus; everywhere else the same rules are followed by hand, so a screen looks the same
with or without it.

## The base works anywhere; your ways add to it

Nothing here may need a plan file, symdeps, the work tool, a Claude session or this repo's layout. Each of those only
adds to a base that works in any project.

| Layer | Works in any project | Added when present |
| --- | --- | --- |
| Reading changes | commits, working changes, before / after, checkmarks | |
| Grouping | by branch and day | by plan, when the commit was made under one |
| Risk marks | the shared red-zone list (`shared/redzone.json`) | "outside the plan", the project's `.review-risk`, "not tested since this edit" |
| Menus | the built-in menu, drawn to these rules | symdeps' renderer |
| Symbols | the row stays, dimmed: "requires symdeps" | callers, uses, layout, layout against a commit |
| Overview | | the Claude Code notebook |

A feature that is missing says what it needs ("requires symdeps", "requires API setup"); it never errors and never
disappears. `tests/test_nvim_review.py` runs the review in a bare project to hold this.

## A panel or menu

- **Title line**: the name on the left, the count or mode on the right (`Review                1 of 3 · new`).
- **Groups** under a rule line: ` ── Label ─────────── 1 of 3 ──`. A blank line between groups. One group alone needs
  no rule.
- **A row**: mark · name · counts, the counts right-aligned in one column. Marks: `✓` done, `↻` changed since,
  `○` not yet, `⚠` needs care, `▸` / `▾` folds. Never a bracketed pseudo-button, never help prose in the list.
- **The description strip**: a rounded box of two lines under the list, saying what the selected row is and where
  it stands. It follows the cursor. Reasons go here ("⚠ touches /etc/pam.d · outside the plan"), not in the row.
- **One footer line**: the three or four keys that matter (`⏎ open · m check · a actions · q close`). Everything
  else lives in the actions menu.
- **Keys**: `j` / `k` move, `⏎` or `l` opens, `h` folds or goes back, `/` filters, `?` or `a` opens actions,
  `q` / `Esc` closes. The same key means the same thing on every screen.
- **Every action three ways**: a key, a click and a row in the actions menu, with the same words.

## Colour

Use the symdeps highlight groups when they exist and fall back to the theme's own: title and group rules
(`FoxSymdepsTitle`, `FoxSymdepsHeader` → `Title`), the selected row (`FoxSymdepsSelection` → `Visual`), done
(`FoxSymdepsOk` → `DiagnosticOk`), needs care (`FoxSymdepsWarn` → `DiagnosticWarn`), quiet text
(`FoxSymdepsDim` → `Comment`). Those names belong to the plugin and stay as they are.

## Behaviour

- A panel updates in place: the selection and scroll position stay, and it does not resize while you read.
- Anything slower than about a tenth of a second shows that it is working, in place; typing never waits.
- Empty, loading, unavailable and failed each have their own wording. A blank panel is a bug.
- Lists you read through in order (changes to review) run oldest first, with the live state pinned on top. Lists of
  what needs you now (failures, due dates) run newest first.
- No row is cut mid-word without `…`, and nothing wraps.

## Seeing the notebook without installing it

`python3 tests/notebook_preview.py` prints the Claude notebook as it would be drawn, in the theme's colours, from
sample data: the front page, the files page, a request thread, the marks page and a quiet page. The scenes are in
`shared/claude/mods/foxml-paper/tests/preview.test.tsx` and go through the mod's real drawing code under Claude
Code's own test kit, so what it prints is what the pane shows. `--scene WORDS` picks one, `--theme NAME` another
palette, `--plain` drops the colour. Add a scene there when a page changes.
