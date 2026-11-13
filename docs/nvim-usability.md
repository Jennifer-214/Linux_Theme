# Neovim usability review

The configuration already provides project-scoped search, an explorer, named leader groups, persistent undo,
session restoration, diagnostic lists, a single formatting pipeline, local completion and Claude notes.
This pass concentrates on making those tools easier to trust and find.

## Changes made

- Reviews use one reusable tab with a file sidebar, exact committed snapshots and explicit Before / After labels.
  Additions, deletions and renames are represented directly. Both panes are read-only.
- `Space Cw` opens a commit tree: Enter or `l` expands a commit, its files appear underneath, and `h` collapses it.
  Selecting a file reuses the comparison panes; different commits keep separate checkmarks.
- **Working changes** comes first and includes staged changes, unstaged files, untracked files and unsaved drafts.
  Its comparison is HEAD against the current buffer or disk. Files expand into their changed functions or types;
  when a parser is unavailable, changed line ranges remain available. Choosing a child jumps to that exact snapshot.
- Commits and files are clickable. The checkbox marks a file; **Check & next** moves to the next unread file,
  then becomes **Finish & next** when the commit is checked, advancing to the next unchecked commit in the same view.
  **Actions** stays in the sidebar title and opens
  a plain-language menu. Paper's choice dialogs use consistent floating menus with click, Enter and Escape.
- Changes and Outside edits use symdeps' own menu renderer when installed: grouped rows, aligned state/shortcut
  columns, a description strip, remembered selection, `/` filtering and the same back/close keys. Mouse support
  remains available, including after toggles reopen the menu. The ordinary choice menu remains the fallback.
- `s` from a C/C++ review opens the real working file near the reviewed line and invokes symdeps.
  `S` compares the current struct with the selected commit's parent through symdeps' revision comparison.
  The latter uses that version of the file with the current project's other headers, as symdeps labels it.
- File checkmarks persist, reopening resumes at the first unread file, and finishing is a deliberate action.
  Live changes invalidate stale checkmarks. Merely opening a commit no longer clears its pending status.
- Native `:q`, `:q!`, `:close`, `:tabclose`, `:bd` and buffer-close shortcuts close the review as one view.
  Closing a choice menu with `:q` cancels it once. The original editor, unsaved buffers and quickfix list remain intact.
  `gf` or **Open working file** opens an editable file in a separate tab while retaining the review.
- Notes from either snapshot retain the real source path, selected side and both versions of the changed block.
  Recipient selection and sending remain explicit.
- Git changes have working next/previous, preview, stage and undo-stage shortcuts in ordinary buffers.
- Completion no longer accepts the first unselected suggestion when you press Enter.
- Project file search and text search include hidden configuration files, respect ignore rules and exclude `.git`.
- Wrapping, format on save and type/parameter hints have discoverable toggles. Manual formatting still works.
- Comment folding targets the window that opened the file and skips diff windows.
- Saving Markdown preserves deliberate trailing double spaces. Cleaning code whitespace preserves your search and view.
- Loaded text files refresh on directory events, including atomic saves by outside agents, while you keep typing.
  Unsaved buffers keep both copies and show a clickable **outside edits** status. `Space Cu` compares the copies;
  `Space Cl` merges non-overlapping edits without saving. Overlaps are left untouched.
  Saves are blocked while outside changes are unresolved; `:AgentKeepMine` explicitly chooses your buffer for the next save.
  A disk revision is acknowledged only after the buffer actually contains it; a blocked reload stays pending.
- Diffview closes with `q` from its comparison or file panels. The shortcut reference now matches the active AI tools;
  the retired Avante section and obsolete AI bindings have been removed.

The [shortcut reference](../shared/nvim_NVIM-KEYBINDS.md) documents the controls.

## Further choices worth considering

- The current `autowriteall` preference saves when switching buffers or leaving. If that ever surprises you,
  explicit saves would make the boundary between experiments and saved changes clearer.
- Swap files are disabled. Persistent undo helps after saves, while recovery of edits made since the last save
  would benefit from a dedicated recovery directory or optional swap files.

Those two preferences affect your everyday editing behavior and were retained in this pass.

## Validation

Temporary Git repositories exercise exact revisions, later working edits, unsaved buffers, renamed/deleted/added
files, unusual filenames, review resumption, explicit completion and note delivery. Tests verify that reviewing
preserves source files and the Git index, returns to the original editor, and keeps its existing quickfix list.
The ordinary editing test uses the installed Git plugin to stage and undo a hunk in a temporary repository.
Existing Paper, formatting, notebook and real Diffview merge checks cover the shared theme configuration.
