# Agent and development workflows

[← Back to FoxML](../README.md)

Claude session status, notebook controls, supervised jobs, test results and review. For local model setup, see [Local AI](local-ai.md).

[Session status](#session-status) · [Desktop integration](#desktop-integration) · [Notebook](#the-notebook-mod) · [Jobs and tests](#jobs-tests-and-next-steps)

## Session status

Claude Code's status line comes from `templates/claude/statusline.sh`, set as
`statusLine` only when you have none of your own. It shows the model, a five-segment context meter on Paper
for how full the context is, your 5-hour and weekly plan usage (Pro and Max
plans; berry and bold from 80%, with the reset time), the git branch, and
`gate open` once a repo's `.claude/.plan-approved` lists the session. Paper shows `ready` or `needs input` while the session waits; `tidying ✧` shows while it
compacts, and `✧ a fresh page` for a minute and a half after. Narrow panes drop the
branch first, then the readiness label, then the weekly figure. Each run also leaves a small
snapshot of the session in `$XDG_RUNTIME_DIR/foxml-claude/`, and the installer's
hooks record beside it whether the session is working, waiting, needs you,
compacting or stopped on an error; a session that ends removes both. Nothing
there leaves the machine.

## Desktop integration

The bar reads those files through `fox-drawer claude-bar`: a pill beside the
local-model status shows `✎` sessions working, `◇` sessions waiting and `!` ones
stopped, and folds away when none are open. Its text turns berry past 80% of a
plan limit, and its ribbon hangs lower while a session is asking for you. Hover
for each session's project, model, context and state with the plan usage, as a
banner on whichever monitor you are on. When the last busy session finishes, every
bar says `✓ all done` for a few seconds; click to open the Agents page (or, while a session asks for you, to go straight to it), where each
session has its context meters (a brief reset indicator follows compaction) and Enter
goes to its tmux pane: to the kitty window already showing that tmux session, on
whichever monitor it is, with the keyboard moved there once the drawer closes, or to a new
terminal attached to it when no window shows it. Each tmux pane footer starts with `!` while its session needs
you and `✿` while it works. Sessions go by
the title Claude Code gives them, with the folder beside it. `ALT+Ctrl+E` goes
straight to the next session waiting on you, the one asking first; press it again
for the one after. Today shows the time Claude spent working today, a little
meter of the week's plan with how much is left and when it refills (and the five
hours once they run low), and a `✎ 2 working` tag. The time comes from a tally the
hooks keep beside the session files for the day. The lock
screen says `2 still working ✎` under the battery while sessions are busy. The count is Claude only: a build or a
sanitizer run you started yourself can still be busy at zero. Sessions whose pane
went back to a shell, and anything quiet for twelve hours, are left out.

## The notebook mod

The installer also adds a Claude Code mod, `~/.claude/mods/foxml-paper`, named in
`CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json` (beside any folders you
list there yourself). It draws in the palette and keeps its session records in private runtime and state folders:

- **The notebook**, a pane beside the chat (`/notebook` opens it; it opens by
  itself in a terminal 144 columns or wider): the context meters, the session's
  title, the plan you last read or wrote under a `plans/` folder, the plan gate,
  and the files changed since the last commit with their `+`/`−` counts.
  It starts with a compact overview; files, project and sessions have their own
  pages. `/notebook files`, `/notebook all`, `/notebook project` and
  `/notebook sessions` open them directly, including in narrow terminals.
  The file page switches between recorded edits by this session and the whole
  working tree. Counts are working-tree totals; shared files name the other live
  sessions that edited them, and changes without a recorded author stay
  unattributed. Counts align in columns, with readable sage and terracotta ink.
  Selected rows use blush with dark ink under keyboard focus and pointer hover.
  Enter or `l` opens a file's diff, and `e` opens the selected file in nvim.
  In the session view the diff uses a before-copy when the file already had
  uncommitted edits; other edits made since that copy can still appear.
  Selection stays in the notebook while an editor window is open.
  The project page pins an active Markdown plan and its current step for this
  session, saved across reloads and restarts; reading another plan does not
  replace the pin. Its test result reports how many captured source files have
  changed, or says freshness is unknown when the snapshot is incomplete.
  Tests, failures, changed source files, worktrees and project documents open
  their corresponding editor view. An overview row leads to failed job logs,
  unread notes or the session involved in an overlapping edit. Adding a next
  step opens a field only when asked.
- **A red-zone band** above the prompt when Claude edits, or runs with `sudo`
  against, PAM, fstab, the greeter, sudoers, the boot loader, the kernel command
  line, sysctl, USBGuard or the firewall: `red zone · /etc/pam.d · brick-safety
  first`. It only warns; the next prompt clears it.
- **Toasts** for 60% context used, the plan gate opening and a commit landing
  (`a seed planted ❦`).
- **Spinner words** in the terminal: reading, checking, tracing, writing and reviewing.
- **A hello** by the hour when a session starts.
- **Two sessions, one file:** each session notes the files it edits in
  `$XDG_RUNTIME_DIR/foxml-claude/edits/` (private, gone at reboot). Before an edit, if
  another live session changed the same file in the last 15 minutes, a band says
  `coordinate with the active session that last edited main.cpp · <its title> (pane %2),
  4 minutes ago`, and Claude gets the same note once so it can message that session
  (Claude Code's peer list shows each session's tmux pane) or read its changes first. It only
  warns. Worktrees are separate files, so they never match; edits made through shell
  commands are not seen.
- **Other Claudes:** the notebook lists the other live sessions on this machine (the same
  list as the drawer's Agents page, from `fox-drawer claude-peers`): name, project, whether
  it is working, waiting or needs you, and how many files it is editing in this repo.
  `go` jumps to its window; `note` opens a one-line box in the notebook, and Enter sends
  the text to that session as a message (`$.session.send`). Without `fox-drawer`, the
  notebook lists only the sessions editing in the same repo.
- **Envelopes:** a note sent from nvim (`<Space>Cn`, left in
  `$XDG_RUNTIME_DIR/foxml-claude/inbox/<session>/`) or by another Claude shows as `✉ from …` in the notebook,
  with `✉ 2` beside the meter while any are unread. **Mark read** removes one and
  updates the count; **mark all notes read** clears the current list. Read markers
  survive plugin reloads, suppressing identical peer retries for 15 minutes; a later
  identical note can be new. Peer identity uses the full body, so two messages with
  the same preview stay distinct. A note from nvim goes to Claude as your own words
  once the session is idle.
- **For nvim:** the mod keeps what nvim's review needs: each session's full list of edited files and, before its
  first edit of a file that already had uncommitted changes, a copy of that file (`edits/<session>/before/`,
  private, at most 1 MiB, gone when the session ends); the plan the session read last; and, after a Claude
  commit, the session's title for its `Claude-Session:` trailer (`$XDG_STATE_HOME/foxml/claude-sessions.jsonl`).
  Repos listed one per line in `~/.config/foxml/claude-private-repos` get no before-copies.
- **Cards:** another mod can leave a card for a session in
  `$XDG_RUNTIME_DIR/foxml-claude/cards/<session>.json` (`title`, `rows` of `mark`/`text`/`tone`,
  an optional `alert`); the notebook draws it, and its alert takes the band.
  A row may also carry an `action`: `{kind: "file" | "file-diff", file: "relative/path"}`
  or `{kind: "log" | "tests" | "compare", id: "run-id"}`. These rows are selectable
  on the project page; actions open local editor views and never execute card-supplied commands.

## End a session

`/goodnight` (`~/.claude/commands/goodnight.md`) wraps up a session: Claude writes a
short where-we-left-off note to `~/.local/state/foxml/goodnight/<project>.md`, lists
what is uncommitted without touching it, and opens the Power page.

Its code is copied as it is; only `templates/claude/mods/foxml-paper/hooks/theme.ts`
is rendered, so a theme swap recolours it at the next Claude start.

## Jobs, tests and next steps

Desk adds **Jobs**, **Test results**, **Changes to look over**, **Worktree map**,
**Pinned next steps** and **Failures**. Today links to running jobs, jobs finished in
the last 24 hours, today's uninspected Claude commits and your first pinned step.
The Agents page shows the current command, elapsed time and last activity; Enter
still jumps to that session's terminal. Supervised background jobs remain visible
when Claude goes idle.

The paper mod supervises recognized Claude Bash builds, test runs and downloads.
It keeps the original command's exit status and streams its output to the terminal.
In an interactive zsh, ordinary foreground build commands get status tracking;
use **`fjob`** when you also want captured output or a background job:

```sh
fjob make -j4
fjob ctest --test-dir build --output-on-failure
fjob ./build/controller_test &
fjob wget -O model.gguf https://example.org/model.gguf
# Without the shell helper:
fox-work run -- ctest --test-dir build --output-on-failure
```

Start the supervisor around the actual job: a plain `make &`, or a shell script
that detaches its children, cannot report those children's eventual exit status.
Commands with explicit credentials, privileged commands and existing wrappers
are excluded from automatic Claude capture. Existing processes are not adopted.

Failed jobs and user services, Claude completion/input notices, and pi's useful
completion/input notices stay visible until opened or dismissed. Click a notice
to open its result or session; right-click dismisses it. Mako's middle-click
action menu offers alternatives such as the log, review, or a draft for Claude.
Test failures open the first recorded source location when one is available.
Agent notices replace the previous notice from the same tmux pane. Ordinary
desktop notices keep their short lifetime, and Do Not Disturb still hides them.

Captured gtest, CTest, pytest and unittest output supplies reported counts and
source locations. The notebook shows the result, its failures and **since last
pass**. Select a failure to open its exact quickfix entry in Neovim, using Trouble
when available; **Space Ce** opens the latest results. Logs with no source
locations open as text. Unknown totals remain unknown; interrupted jobs never
count as passes. Logs retain at most their newest 4 MiB and mark truncation.
CTest's enclosing totals take precedence over child summaries.

Each captured run records its starting revision and the contents of supported
source/config files, including nonignored untracked files and uncommitted edits.
Comparisons use the most recent successful run of the same command in the same
checkout. Editing those files makes a result stale; changes during a run also
disqualify it as a baseline. Snapshots exclude secret paths, hidden files,
symlinks, binary files and ignored build outputs. They stop at 4,000 files,
1 MiB per file and 32 MiB total; an incomplete snapshot cannot establish a
passing baseline. Repos in `claude-private-repos` get no source copies.
External dependencies and environment changes are outside this source check.

Project cards have a **worktrees button**, or **w** on the keyboard; **n** opens
their next steps. Worktrees show their branch, dirty/untracked files, unpushed
commits and the sessions using each checkout. Open an editor or terminal there,
or jump to a listed Claude. Next steps are shared with the notebook and Today;
**Space Ck** or `:WorkTasks` adds, completes or reopens them. Selecting **prepare**
opens an editable note. In that note, **Space ws** chooses a Claude and sends it;
closing the note sends nothing.

In Claude's notebook, press **Ctrl+X, then Tab** to give the pane the keyboard.
**Tab / Shift+Tab** walk its controls, **Enter** activates the selected control,
and **Up / Down** scroll a short pane. **Esc** returns to the prompt. Printable
keys, including `hjkl`, type normally inside an input; the notebook uses Claude's
native inputs. Outside a field, **j / k** select rows, **l** opens the selected
item, **h** returns to the overview or closes the active field, and **e** edits
the selected file. The shortcut row shows those keys while the notebook has focus.

Opening a commit through **Space Cw** or the review tray records it as inspected
and removes it from Today's pending count. The tray considers the most recent
80 commits and recognizes `Claude-Session` or Claude coauthor trailers; it does
not infer authorship from message wording. Inspection does not stage or commit.

A failed job offers **Open log**, **Jump to terminal** when it has a tmux pane,
and **Ask Claude**. Ask opens an editable error excerpt with the same explicit
recipient selection. Failures also lists failed user services. A user timer
checks for newly failed services once a minute and offers their recent journal
and a draft; it never restarts a service. Set `FOXML_WORK_NOTIFY=0` to mute job
popups. Work records, private logs, deduplicated source versions, next steps and
inspection marks live in `$XDG_STATE_HOME/foxml/work/` (default
`~/.local/state/foxml/work/`), with directories mode 0700 and files mode 0600.
`fox dev work help` lists the underlying command interface.
