# Agent and development workflows

[← Back to the README](../README.md)

Claude session status, notebook controls, supervised jobs, test results and review. For local model setup, see [Local AI](local-ai.md).

Change requests refresh when you return to an open Neovim review, refresh its comparison, or ask for the next
unread file. A request still waiting on a session is shown as waiting. Retrying delivery from the notebook keeps
the original file baseline, so a file already changed remains ready for re-review. Plan coverage says "no matching
edits" or "no commit recorded" when it has no evidence; completion still comes from the plan's own checkboxes.

[Session status](#session-status) · [Desktop integration](#desktop-integration) · [Notebook](#the-notebook-mod) · [Jobs and tests](#jobs-tests-and-next-steps)

## Shared attention and live updates

`desk-work attention --root DIR` is the common list of what needs you: outstanding job failures and agents asking
for input, requested changes ready to read, files edited since review, then unread commits oldest first. The
notebook, the drawer's **Needs you** page, and Neovim's `:WorkAttention` use those identities and that order.
`:WorkNext` opens the first item; `:ReviewNext` uses the same list filtered to reviews. CI and unread mail remain
additional notebook context. On the notebook's front page up to three items show as rows; past three they fold
into one line, **N need you**, with a count by kind under it ("52 commits to review · 2 test runs failed"), so a
long list never pushes the rest of the page away. Enter lists them all on their own page, twenty at a time; **n**
opens the most urgent from anywhere. On that page the commits to review come last, grouped by day under a dated
heading with its count (`── Wed 12-31 ── 52 ──`), the newest day first; **j** / **k** pass over the headings. An unreadable work record is an item of its own, first in the list. `desk-work open --root DIR --action attention --id ID` resolves an item against the
current list before opening it, so a stale button cannot act on a request that was already settled.

What the notebook, the drawer and notices open goes to the Neovim already running on that checkout, in a new tab, and
its tmux pane comes forward; with several, the one focused last. When none is running, or that one declines (you are
typing in it, or the item is a review and one is open there), it opens in a Neovim window of its own, as before.
`desk-work editors --root DIR` lists a checkout's editors with their sockets; `desk-work editor --root DIR --input -`
sends one message (JSON on stdin) through `desk.bridge`, which takes only the types it knows.

The work store publishes a versioned change signal after a successful write. `desk-work watch --root DIR` streams
it to subscribers; the desktop uses `--all yes`. Neovim refreshes a visible live comparison while preserving focus
and scroll position. A comparison of a historical commit stays fixed. Ordinary loaded source files also have
directory watchers, which catch atomic saves from any editor or agent without waiting for window focus. Clean
buffers reload; unsaved buffers retain your work and offer comparison or an explicit three-way merge. `:AgentChanges`
opens that comparison. File watching does not depend on the welcome screen setting.

The review file list toggles with **Space re** or `:ReviewFiles`. Its **q**, **Esc** and native `:q` hide only
the list. The two comparison panes retain their buffers, cursor, folds and reading positions. Reopening restores
the tree's selection; returning to a previously visited file restores its place. **Space e** keeps its ordinary
Neo-tree binding, and independently opened windows are not owned by the review. **Backspace** in a diff pane
goes back to the list, showing it again if it was hidden. **q** in a diff still closes the whole review; **Esc**
clears search highlighting.

A burst of changes (an agent saving file after file) refreshes a view at once and then at most once a second, and
the last change is always read. Committed copies in a review are read once per commit, so a refresh re-reads only
the working copy: fifty change signals over three hundred changed files keep Neovim responsive
(`tests/test_nvim_review.py` measures it). Health, backup and recovery views open at once with a "reading" line and
fill in when `desk-work` answers; a refresh pressed twice shows the newer answer, never the older one arriving late.

Polling remains a recovery path for older integrations and abrupt process exits. Cache reads do not publish
changes, so subscribing cannot create a refresh loop. Closing a view stops only the watcher it owns.
Watchers reconnect with bounded backoff. A delayed stream is identified separately from a failed data refresh;
polling can still provide current results. A wall-clock jump after suspend prompts a fresh projection.

`/notebook health`, `:WorkHealth` and the drawer's **System → Work health** read the backend's shared health
projection. It shows each reporting client's connection, last event, last successful refresh, next retry and
loaded version. A failed refresh keeps its previous successful timestamp. A stopped watcher is distinguished
from a client whose process is still alive; unknown versions and timestamps stay unverified. Health telemetry
does not publish project changes, so reporting a refresh cannot trigger another refresh. Clients report a change of
state, or once a minute while all is well, rather than once per event.

A session still running code from before an installed update is listed in health with the steps that load the new
code and keep its work: a Claude session exits and resumes the same conversation (`/exit`, then
`claude --resume <id>`); Neovim saves, lets its terminal jobs finish and restarts (`:restart`, then `:WorkResume`
reopens the files); pi runs `/reload`; the drawer restarts through `desktop-menu --start`. The notebook shows its
own session's steps on an **update installed** row.

Every refusal says why, in the words `desk-work` gives: a notice is never blank. A record the work store cannot
read (for example a `review-marks.json` cut short) refuses every write rather than overwrite it, names itself in
the refusal, comes first in the attention list, and shows as "unreadable" instead of a count of zero.
`:WorkRepair` (or **F** in `:WorkHealth`) previews the repair: the unreadable file is set aside under a dated name
beside the records and a fresh one starts with the next write; change requests for files that no longer exist can
be tidied away, with the previous copy kept. Finished reviews and plans of rewritten commits are history and stay.
`desk-work records --root DIR` reports the same, and `desk-work records-repair --root DIR` previews it.

The notebook opens recovery controls in Neovim only when requested. **R** in `:WorkHealth` selects an interrupted
update and asks before restoring its guarded backup. **b** or `:WorkBackups` previews backup cleanup, including
disk usage and retention reasons; **D** asks before removing the reviewed selection. A live updater, the current
rollback chain and unfinished transactions are retained. See [installation](installation.md#inspect-and-clean-update-backups)
for the CLI equivalents. Existing buffers, terminal jobs and agent sessions remain open.

## History, digests and attention

The notebook's `/notebook timeline`, Neovim's `:WorkTimeline` and the drawer's **Project timeline** read the same
bounded journal. It records requests, explicitly observed edits, job transitions and reviews from this update
onward; it does not invent earlier activity. Entries carry backend action identities and open the related file,
captured result or historical commit. The journal keeps the latest 500 events per checkout.

`/notebook digest`, `:WorkDigest` and **Since you last looked** summarize that journal, saying when you last caught
up ("Since you last looked this morning: 2 runs passed"). Opening a digest does not
clear it. **Mark caught up** acknowledges its recorded sequence, so later arrivals remain new. Notebook, editor
and desktop have separate reading positions; attention state and review marks remain shared.

Neovim's **since page** (**Space Ch**, `:WorkSince`, or the notebook project page's **since you last looked in
neovim**) lists, newest first, what happened in the checkout after the page was last opened there: new commits,
test runs with their result, job runs with how their figures moved (see "Run-to-run numbers"), and Claude turns
with the files they edited. Enter opens what a line names: a commit's review, a test run's results, a job's
output, a turn's changes in the review, or a file. Unlike the digest, opening it marks now as looked; the first
look lists the last day. The page keeps its list until there is something newer: opened again with nothing new,
it shows the last list it showed ("Nothing new since 14:02 · what that look showed", kept under
`~/.local/state/nvim/desk-since/`), and `Space Ch` while the page is open goes back to it instead of opening another. It is `desk-work since --root DIR [--reader NAME] [--mark yes]`, which keeps the time per
reader beside the digest's positions and lists at most 60 entries. A turn is recorded when a session that was
working goes back to waiting (or ends) having made observed tool edits; a turn that edited nothing records nothing.

To catch up on a review backlog later, **set aside** the commits to review: from the drawer's **Needs you**, the
notebook's needs-you page or `:WorkAttention`. They leave what needs you and stay unreviewed in the review, and
**bring back** undoes it; nothing is stamped reviewed, and a commit made afterwards needs you as usual
(`desk-work set-aside --root DIR`, or `--all yes` for every checkout in use). The drawer folds commits to review into
one row per project, which opens that project's review. Checkouts that no longer exist, or had no commit or
recorded activity in two weeks, stay registered but leave the desktop's lists.

Select a notebook attention row and choose **later**, or use `:WorkSnooze`, to hide it for an hour or until it
changes. The snooze is shared with the drawer and other clients. It never clears a failure, checks a file or
settles a request. A new content version brings it back. `:WorkUnsnooze` and the drawer's **Snoozed items** bring
items back explicitly.

## Resume and relevant tests

`:WorkSave` records a project's saved-file positions; `:WorkResume` opens them in new tabs and keeps existing
windows, unsaved buffers and terminal jobs. From outside a checkout it offers saved projects and worktrees.
Neovim's existing persistence plugin continues to own its full editor-session layout. The notebook remembers its
page and selection per checkout and Claude session; forms and keyboard focus are not restored. Plans remain
owned by the existing plan store, rather than copied into another settings file.

**Tests for this file** in the review, `:WorkSuggestedTests` and the notebook file page offer captured commands.
Each explains whether it ran that test, reported a failure in the source, has an inferred name match or is only
project history. The previous result's freshness is shown; this is not a claim of proven coverage. Running is
explicit and uses the recorded working folder through the same job supervisor as ordinary runs. Older records
without a known execution folder are not offered for rerun.

## Compact notebook and other agents

`/notebook compact` uses a 30-column, four-row summary: the work name, attention count, last tests when present,
and **expand notebook**. `/notebook expand` restores the 42-column pane. `z` switches layouts while the notebook
has focus. The choice is remembered, and background updates do not expand the pane or move the keyboard out of
your conversation. File, project, request and session pages open at the usual width.
`/notebook auto` optionally follows the measured terminal width: compact below 144 columns and expanded above
it. Resizing is applied outside drawing, without requesting keyboard focus, and does not resize an open form.
Explicit compact/expand turns automatic sizing off.

**Hide** or **q** while the notebook has focus hides its pane; `/notebook toggle` brings it back on the same page.
`/notebook close` explicitly hides it. An ordinary close keeps page and selection, while abandoned forms are
discarded. Escape first cancels an open form without closing the notebook. The compact summary keeps its hide
control on the same row, and the expanded key bar is packed into lines that fit the pane, so it never wraps.

`desk-work agents` owns the shared session list. The existing Claude runtime files remain an adapter for sessions
already running, including engine prompts and compaction. The pi extension now reports lifecycle state, observed
write/edit paths, and captured test/job results through the same store. pi can be opened at its recorded terminal;
the notebook does not offer note delivery where that integration has no messaging capability. File attribution
records observed tool edits; it does not claim every dirty file for the active agent.

Another agent can publish the same local protocol without changing editor buffer handling:

```bash
desk-work agent-update --root "$PWD" --agent my-agent --session session-id \
  --pid PARENT_PID --state working --title "Queue work"
desk-work agent-update --root "$PWD" --agent my-agent --session session-id --state done
```

Use the agent process's PID, not a short-lived helper's PID. Identity includes both the agent kind and session ID;
dead processes are excluded. Registered live processes remain listed through long silence; a missing heartbeat
is shown as delayed instead of removing them. Legacy records without verified process identity still expire.
Claude and pi publish heartbeats without changing an input-waiting state. Their overlap warnings consume the
same observed-file registry; separate worktrees remain separate. This provides an adapter API; it does not imply automatic hooks
are installed for every agent.

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

The bar reads those files through `desk-drawer claude-bar`: a pill beside the
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
for the one after. Back from any of these jumps: `ALT+Backspace` returns to the window you were in, `Ctrl+a
Backspace` to the tmux session you were in (press either again to come back). Today shows the time Claude spent working today, a little
meter of the week's plan with how much is left and when it refills (and the five
hours once they run low), and a `✎ 2 working` tag. The time comes from a tally the
hooks keep beside the session files for the day. The lock
screen says `2 still working ✎` under the battery while sessions are busy. The count is Claude only: a build or a
sanitizer run you started yourself can still be busy at zero. Sessions whose pane
went back to a shell are left out. Legacy records without verified process identity also expire after twelve
quiet hours; registered live processes stay listed, with delayed heartbeats identified separately.

## The notebook mod

The installer also adds a Claude Code mod, `~/.claude/mods/desk-notebook`, named in
`CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json` (beside any folders you
list there yourself). It draws in the palette and keeps its session records in private runtime and state folders:

- **The notebook**, a pane beside the chat (`/notebook` opens it; it opens by
  itself in a terminal 144 columns or wider). Its front page has the same rows in
  the same order every time, at most 17, so the pane never grows or shrinks:
  the header (the work's name, `✉ N` for unread notes, `!` when the page is not
  current), then one ruled group each for **needs you** (up to three rows, or the
  folded count), **last turn** (what it changed, ran and committed), **plan** (the
  step in hand and `3/4`; `plan first` on the rule while the gate is closed),
  **review** (files changed, how many reviewed, requests still with a session) and
  **work** (a running job or the last test run, with CI on the push), and the key
  bar's two lines at the bottom. The context meter is in the status line only.
  **p** opens the project page: branch and CI, the pinned plan, tests, next steps,
  project notes, sessions, the marks and keys, the timeline and work health.
  Files and sessions have their own pages. `/notebook files`, `/notebook all`,
  `/notebook project` and `/notebook sessions` open them directly, including in
  narrow terminals. Under retro-amber the notebook uses marks from the DOS font
  (`√` reviewed, `↕` changed, `→` sent, `*` to look over, `‼` red zone, `►` step,
  `≡` plan, `♦` commit; the marks page lists them all), group labels in inverse
  capitals, key words and states in capitals, and `..` for `…`.
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
  list as the drawer's Agents page, from `desk-drawer claude-peers`): name, project, whether
  it is working, waiting or needs you, and how many files it is editing in this repo.
  `go` jumps to its window; `note` opens a one-line box in the notebook, and Enter sends
  the text to that session as a message (`$.session.send`). Without `desk-drawer`, the
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

## Reviewing changes

`Space Cw` in Neovim opens the review: a side panel beside a read-only before / after comparison.

- **The tree**: Working changes first, then each plan with its commits oldest first, then other commits. A commit
  opens to its files and a file to its changed functions. Without plan files the commits group by branch and day.
  `j` / `k` move from row to row, passing over headings and blank lines.
- **Marks**: `✓` reviewed, `↻` edited since you reviewed it, `○` not yet, `⚠` needs care. The strip under the list
  says why: a red-zone path or tool in the added lines (`shared/redzone.json`), a path in the project's
  `.review-risk`, a file the plan never names, or a file edited since the last test run.
- **Only what is new**: a file edited after you checked it opens against the copy you read. `n` shows the whole
  change instead; the choice is remembered.
- **Keys**: Enter or `l` opens, `h` folds, `m` checks (on one of a file's changed functions it only checks the file,
  never unchecks it), `u` goes to the first unread file (risky ones first),
  `a` (or Space Space, in the list or a diff) opens every other action and `?` lists every key. `s` in the list puts
  a label on every row, as `s` does in code (flash.nvim), and typing one moves there; in a diff `s` is the code's
  own. `gs` or `Space dd` shows the changed C or C++ symbol in symdeps; `Space dm` opens its menu. These use the
  working source near the reviewed line, including the cursor's column. `q` in the list
  hides it; `q` in a diff closes the review and returns to your
  editor. Backspace in a diff pane brings the list back, and `Space re` toggles it.
- **On the other screen**: `o` in the list moves it to the pop-out, a window of its own on the second screen, and the
  comparison takes this whole screen. There `j` / `k` move, Enter shows the file here while the keyboard stays there,
  and `m`, `u`, `n`, `h`, `]f` / `[f`, `]c` / `[c`, `r` and `s` work as in the list; `c` and `R` ask their question
  there; `a` opens the actions here, and the keyboard comes with them. `Ctrl+o` there shows the file shown before,
  `Ctrl+r` the next again; its tab is marked when a file joins the list, a request is ready or a checked file changed. `o` there,
  Backspace or `Space re` here, or closing the pop-out bring the list back, on the row selected there; closing the
  review clears it, and the pop-out's Restore after a restart opens that review again with its list there. With one
  screen `o` says "requires a second monitor" and the list stays. "What changed" and "Review the next thing" in the
  pop-out's own `Space Space` open the review with its list there and the comparison here.
- **What a change calls**: each changed function's calls before and after, compared by name (treesitter, in any
  language with a parser). A file whose change adds or removes a call is marked `→`; a changed function's strip reads
  `calls by name: +memcpy −old_copy` and who calls it: the language server attached to the working file when that
  file is open, else the project map (by name) when one is built, else "requires a language server or the project
  map". A session's edits (a Claude turn) get the same check. By name: overloads, macros and virtual calls are not
  told apart.
- **Finishing**: `R` (Shift-R), once every file is checked, records the review and asks **Next commit** (the next
  unchecked one), **Close review** or **Stay**. Close also quits a Neovim that the notebook opened just for the
  review.
- **Request changes**: `c` writes a note about the file or the selected lines to a Claude session. The file waits
  (`✉`) until it changes, then reads "ready for re-review"; checking it settles the request.
- **Your own notes**: `N` on a line leaves a note for yourself. It stays with the file across reviews, follows its
  line when the file shifts, marks the row `✎`, and `:ReviewNotes` lists every one in the project.
- **Plan coverage**: `P` lists each step of the plan with the commits that touched a file it names, steps with no
  matching edits, and changed files no step names. A commit row also says whether tests passed on exactly that commit.
- **Next**: `Space Cr` (`:ReviewNext`) opens the next thing that needs you. A review also reopens on the file and
  line you left it on, while that file still needs reading.
- **Before a push**: the notebook says how many of Claude's commits going out are not reviewed and whether one
  touches the red zone. It never stops the push.
- **Review stamps on the remote**: a finished review is a git note on the commit (`refs/notes/reviews`). It stays
  on this machine unless the repository asks otherwise: `git config desk.pushReviewNotes true` makes the notebook
  push the stamps after each push that goes through. Off by default, because it publishes who reviewed what; it
  never forces, and says so when the remote's stamps differ.
- **API review**: from Actions, send exactly the displayed file, the whole change, or the hunk under the cursor for a
  review on API credits. You choose the model and a budget first, progress shows, and `:ClaudeApiStop` cancels. The
  result is kept beside the file for the version that was sent (`A` opens it), so an older review never covers a
  newer edit. Without the API setup the rows stay and read "needs API".
  The text each file had when it was sent is kept beside the answer: `A` opens the answer, and Enter on a
  `path:line` opens that reviewed version once the file has moved on (`gf` there opens the file as it is now).
- **Shared progress**: checks are kept by `desk-work`, so the notebook shows the same `✓ ↻ ○` and one line such as
  "3 changes to review · 1 changed since you looked". Checking every file of a commit takes it off "to review",
  even before `R`. After a turn that leaves files unreviewed, a quiet "review pending" line sits above the prompt.
- **Stamps**: finishing a commit's review writes a git note on it (`refs/notes/reviews`: who, when, how many
  files). The note alone marks the commit reviewed, so it survives a reinstall;
  `git push origin refs/notes/reviews` shares it. `DESK_REVIEW_NOTES=0` turns the notes off.

None of it needs plan files, symdeps, or a Claude session: those add grouping, symbol context and the overview to
a review that works in any git repository. The look follows [UI style](ui-style.md).

## Call graphs

- **One function**: `Space cc` (`:CallGraph`) opens a tab with the function under the cursor in a double box, what
  calls it above and what it calls below, one level each way. One box is selected (highlighted), the function's own
  when the tab opens: `j` / `k` move to the nearest box in the row below / above, `h` / `l` along the row, `Tab` /
  `Shift+Tab` through every box, `gg` / `G` to the first / last. A click, or any motion that lands in a box, selects
  it. Enter (or a double click) goes to the selected function in the code window the graph came from and leaves the
  tab open behind it; Backspace goes back to that window as it was. `c` centres the graph on the selected box, `r`
  reads again, `q` closes; the last lines list the keys and `?` all of them. There is one graph tab: `Space cc` again, from any window,
  brings it back on the function under the cursor (on the function it shows already, it only switches to it), so a
  call chain is Enter on a callee, then `Space cc` there. The data is the language server's call hierarchy (clangd,
  pyright, lua_ls, ...): while the server starts or indexes the tab says "waiting for the language server" (15
  seconds at most), and a file whose server has no call hierarchy says which server it has. `s` puts a label on
  every box, as `s` does in code (flash.nvim); typing one selects that box. For C and C++, `gs` opens the function in symdeps when that
  plugin is installed (every use by role); without it the line reads "requires symdeps".
- **Call depth**. `+` expands the selected side of the graph, and `-` collapses it or cancels the level being read.
  From the centre, both keys act on the callee side. The gauge shows the depth of the selected box, and `m` reveals
  functions past the first 24 on each level: their line says "+N more · m shows them", and the key line lists `m` while
  any are left out. The language server's first level stays; the built project map adds the level under the last one
  shown when it can match the source location and has read every function of the checkout on that level, and the
  language server reads the level otherwise. The tab, panel, and pop-out share these controls.
- **Live panel**: `Space co` (`:CallGraphPanel`) opens a narrow split on the right that follows the cursor. It redraws
  when the cursor has rested for 300 ms in another function, keeps each answer until that file is saved, asks the
  server one thing at a time and never takes the focus. Inside it (`Ctrl+w l`) the same keys move between boxes and
  Enter goes to the selected one; `q` or closing the last window beside it closes it. `p` pins it: it keeps the graph
  it shows (its first line reads `PINNED`) while the cursor goes elsewhere, Enter goes there without re-centring it,
  and saving that graph's file reads it again. `p` again follows the cursor from where it is. `c` centres it on the
  selected box and pins it there, as in the pop-out; `r` reads it again, `m` draws what "+N more" left out and `gs`
  shows the selected function in symdeps.
- **The pop-out**: with a second monitor, `Space Space` → views → "Pop out the call graph" opens the live graph in a
  window of its own (kitty, class `desk-popout`): it opens without taking the keyboard, at the side of the screen, and
  moves, tiled, to the workspace showing on the other screen (the first one `~/.config/foxml/monitor-layout.conf` lists
  as secondary that does not hold the editor); each move is checked in Hyprland's list of windows, done again when it
  did not take, and said when it never does. `o` in a graph tab or the panel sends that graph there and closes it here;
  `o` in the pop-out brings it back as the live panel. A view there has the keys of its place in the editor (the graph
  has the graph tab's) beside the window's own: Enter goes to the function in the editor and the keyboard stays in the
  pop-out, `f` or Shift+Enter puts the keyboard in the editor too (where Enter only zooms or folds in the view, as on
  a map's part, the keyboard stays). `p` pins the graph (Enter then visits its boxes one by
  one) or follows the editor again, where each place Enter goes centres it; `c` centres it on a box (pinned there), `r`
  reads it again, `s` labels the boxes and `gs` shows the selected function in symdeps (as in the graph tab), `Space Space` there is the
  editor's menu for the selected box (its first group lists the views), `?` lists the keys. Each view is a tab page:
  the tab line is the header (each view by number, `PINNED`, `✱` when something new arrived in a view behind) and the
  status line is that view's keys; `H` and `L` switch views (as they switch buffers in the editor; `gt`, `gT` and `2gt`
  too), `Ctrl+o` or Backspace goes back (the view before, the graph before a centre, the code spot before Enter: the
  editor goes back too) and `Ctrl+r` forward, `q` closes the view
  (the last one closes the pop-out). `Space Tab` in either window puts the keyboard in the other, across screens (with
  several pop-outs: from the editor to the first, on to the next, from the last back to the editor). The
  pop-out is a Neovim of the same theme that only draws what the editor sends: no language server, no work records, no
  saved places; it names boxes by the drawing it was sent, so a press on a graph that has since changed says "this
  view moved on". A warning or error the editor gives while running a key pressed in the pop-out shows in the pop-out
  too (plain information stays in the editor, and so does anything said later, after the key's run). With one monitor
  the row says "requires a second monitor" and graphs stay in the editor. When its
  screen is unplugged it moves to another screen that is not the editor's, or, with one screen left, closes and its
  pinned views come back as splits (one notice says so). Closing the editor (or `:restart`) closes the pop-out
  ("Editor closed"); its views are kept (desk-work `workspace`, client `popout`), and Space Space › views offers
  "Restore 1 view" in the next editor on that checkout.
- **Several pop-outs**: every view goes to the first pop-out; no other opens by itself. In a pop-out, Space Space ›
  "Send to another pop-out" moves the view in front to another open one (listed by number, with its screen and what it
  shows) or to a new one, which asks its screen as every screen question does ("Send to a new pop-out"); that kind's
  views then go there while it is open. "This pop-out to another screen" moves the one it is pressed in (from the
  editor, the one last used). Each pop-out has its own views, its own `Ctrl+o` / `Ctrl+r` and its own screen; one that
  closes or crashes brings back only its own pinned views, and the others go on. Restore brings them all back, each on
  its screen.
- **symdeps' board in the pop-out** (with fox-symdeps installed): Space Space › views › "Pop out symdeps' board". The
  pop-out never loads symdeps: the board's keys are symdeps' own rows, bound there from the editor and run in the
  editor on the row selected there. Enter opens. `h` and `l` fold and open, and `j` and `k` move between rows.
  With the current board adapter, `f` drills into a code entry's unit, `L` adds it beside the current card, and
  Backspace goes back on the board. Shift+Enter goes to the editor, `gt` switches the pop-out tab, and `Ctrl+o`
  goes back in pop-out history. `m` and `Space dm` open the action menu in the pop-out
  (what `Space Space` shows, the board's rows among it). `Space dd` says why its card does not open
  there (on the board it is the card drawn; on another view symdeps runs in the editor, `Space Tab` away).
- **Live code in the pop-out**. Press `Space cv` on a file, or choose **View this file in the pop-out** under Views.
  Each file gets its own tab. Edits appear as you type and `●` (or `*` in retro) marks unsaved changes.
  Use `p` to keep your reading position or resume following the editor. Search with `/` and `n`. Enter takes the
  editor to the selected line, `f` also moves focus there, and `o` brings the file back as a split. The pop-out is
  read-only. It supports up to 50,000 lines and 8 MiB per file and marks individual shortened lines with `…`.
- **Code panes**. With two or more live code tabs in a pop-out, open its home menu with `Space Space` and choose
  **Toggle code panes**. Up to four files share a tab on a wide screen. Use `Ctrl+h/j/k/l` to move between them.
  Each pane keeps its own reading position and pin state. Choose the same action to return the files to their
  own tabs. The layout is saved with the pop-out and switches to separate tabs if the window is too small.
- **What the last turn changed**: when a Claude turn ends, the notebook reads the function or class around each hunk
  it changed (treesitter, as the review's changed functions; a headless Neovim, three seconds at most) and puts the
  count on the last-turn row, `✎ 2 files · 3 functions`. Enter lists them by file; each opens Neovim with its graph
  (`desk-work open --action callgraph`). A language without a treesitter parser shows its hunks as line ranges.
- **From the notebook to the pop-out**: `g` on one of those functions, or on a test failure on the project page (the
  function at the failure's line), shows its graph in the editor already open on the checkout, pinned on it: in the
  pop-out on the other screen when one is open, else in the live panel beside the code (`desk-work editor`, the
  bridge's `callgraph` message). `g` is in the key bar only while the selected row names a function, and a toast
  says where the graph went. While you type in that editor, or with a review open there and no pop-out, it is not
  shown and the toast gives the editor's reason; with no editor on the checkout it reads "no editor open for this
  project", without desk-work "requires desk-work", and with a desk-work from before `desk-work editor` "requires a
  newer desk-work".

## Project map

- **The view**: `Space cm` (`:ProjectMap`) opens the whole checkout as boxes at three zooms: its parts (top-level
  folders, or the folder inside `src/`, `lib/`, `lua/`, `shared/` and the like), a part's files, a file's functions
  and classes. Callers sit above what they call. Enter zooms in, and on a function goes to its code; Backspace (or
  `-`) zooms out, and at the top goes back to the code with the map left open; `q` closes. One tab per checkout:
  `Space cm` again brings it back as it was (one in the pop-out comes back from there). `?` lists every key: they are
  rows of the action registry, as the call graph's are, and so is its keybinds table. A level draws at most 60 boxes (24 on each side) and says "+N more" for
  the rest. Without desk-work the page opens and says "requires desk-work"; before the first build, it says
  "no map built yet · R builds it". Where no reader can build one (a folder that is not a git checkout, and no binary
  given) it says what each reader needs instead, and `R` is greyed with that reason.
- **Queries**: `D` what a function reaches, down the calls (a count before the key sets the depth; 3 without one),
  `U` what calls it, up the calls, transitively, `P` the ways from one function to another (shortest first, at most
  20). Where the map says `+N more`, `m` shows the remaining boxes and connections from the loaded answer.
  `M` picks a part of the checkout from a menu (`/` filters it by name). `r` reads the page again where it is, as in a
  call graph: desk-work's status and the level shown, a query's answer asked again (`R` rebuilds the map). `c` opens
  the call graph centred on the function, as `c` centres a graph: a graph tab here, the call graph in the pop-out. The box
  under the cursor is the default answer to the prompt. On caller and reach pages, `+` reads one more level and `-`
  takes one off; at one level `-` zooms out, as Backspace does, to the previous page. The gauge marks the current
  zoom or the selected call level. A call that is part of recursion reads "in a cycle".
- **In the pop-out**: `o` in the map's tab moves it to the pop-out on the other screen, at the level it was on (Space
  Space › "Pop out the project map" opens this checkout's from anywhere; in the pop-out's own menu it is the only map
  row, so a map asked for there opens there). There it is the same map: `Enter` zooms in,
  or goes to a function in the editor while the keyboard stays in the pop-out. `-` takes a level off a callers or
  reach page of more than one, and otherwise zooms out.
  `m` shows the rest of the loaded boxes and connections here too. `D` and `U` ask about the
  selected function, `c` shows its call graph there (`Ctrl+o` comes back to the map), `P` asks only where to; `r` reads
  it again, `R` rebuilds. `Ctrl+o` and Backspace go back through its zooms, answers and
  the code spots Enter went to; its name in the pop-out's header is marked when an answer or a rebuild lands behind
  another view. `o` there brings it back as its tab, as it was; pinned (`p`), it also comes back when the pop-out
  closes on its own. `m` and `B` stay the tab's.
- **Rebuilt only when asked**: `R`, `:ProjectMapBuild` or `desk-work map build --root .` builds it as a desk-work job
  in the background (its log is in the jobs list; a failure sends the usual notice). The map is kept with the
  checkout's work records (`~/.local/state/foxml/work/projects/<id>/map/`), never in the project. When HEAD moves or a
  mapped file changes, the page says "stale since <commit>" and why; it does not rebuild by itself.
- **Readers**, each with a line in the footer: which answered, and for each that did not, what it requires.
  - *syntax*, in any git checkout: functions and classes per file and the calls between them by name, from
    treesitter in a headless Neovim with the installed parsers. Overloads, macros and virtual dispatch are not
    resolved; a call whose name fits several functions is left out and counted. It skips git-ignored files, vendored
    and build folders and files over 1 MiB, and stops at 4000 files. Requires nvim and a parser per language.
  - *binary*, for an ELF program or library you name: `B` in the view, or `--binary PATH` on the build (remembered
    for the next builds). Direct calls and tail jumps from `objdump -d`: exact for what was compiled, after inlining.
    Library and indirect calls end at leaves. Built with debug info (`-g`), each function's file is known and it
    merges with the syntax reader's by name and file; without, by a name found once on each side (the binary's own
    folder breaks a tie). Requires objdump. Rebuilding the binary makes only its part of the map stale.
- **From the shell**: `desk-work map status --root .` (built, stale and why, each reader), `desk-work map query
  --root . --q reach|callers --from NAME [--depth N]`, `--q paths --from A --to B`, `--q module [--name PART]`,
  `--q touched --commit REV` (the functions a commit's changed lines fall in), `desk-work map show` (the graph, in the
  shape a project's own graph tool prints) and `desk-work map export --format dot` (for Graphviz, if installed).
- **A project's own graph tool** (`ninja -t graph`, a script printing JSON) is declared in `.desk/tools.json`; its
  answer is read with `desk-work tools result`. See [desk-tools.md](desk-tools.md).

## End a session

`/goodnight` (`~/.claude/commands/goodnight.md`) wraps up a session: Claude writes a
short where-we-left-off note to `~/.local/state/foxml/goodnight/<project>.md`, lists
what is uncommitted without touching it, and opens the Power page.

Its code is copied as it is; only `templates/claude/mods/desk-notebook/hooks/theme.ts`
is rendered, so a theme swap recolours it at the next Claude start.

## Jobs, tests and next steps

Desk adds **Jobs**, **Test results**, **Changes to look over**, **Worktree map**,
**Pinned next steps** and **Failures**. Today links to running jobs, jobs finished in
the last 24 hours, today's uninspected Claude commits and your first pinned step.
The failed count is what still fails: a command that failed and then passed in the
same project no longer counts, and failures older than a day leave Today and the
notebook.
The Agents page shows the current command, elapsed time and last activity; Enter
still jumps to that session's terminal. Supervised background jobs remain visible
when Claude goes idle.

The paper mod records Claude's Bash builds, test runs and downloads: a command
counts when one of its steps starts with a build, test or download tool
(`cd src && make`, `python3 -B tests/test_x.py`), not when it only mentions one
(`rg foo cmake/`). The command runs exactly as Claude wrote it, so auto mode
reviews what really runs; the mod records the start, then hands `desk-work` the
exit status and output when the call returns. Jobs carry Claude's one-line
description of the command as their title. Background (`run_in_background`)
calls are not recorded.
In an interactive zsh, ordinary foreground build commands get status tracking;
use **`fjob`** when you also want captured output or a background job:

```sh
fjob make -j4
fjob ctest --test-dir build --output-on-failure
fjob ./build/controller_test &
fjob wget -O model.gguf https://example.org/model.gguf
# Without the shell helper:
desk-work run -- ctest --test-dir build --output-on-failure
```

Start the supervisor around the actual job: a plain `make &`, or a shell script
that detaches its children, cannot report those children's eventual exit status.
Commands with explicit credentials, privileged commands and existing wrappers
are excluded from automatic Claude capture. Existing processes are not adopted.

Failed jobs and user services, Claude completion/input notices, and pi's useful
completion/input notices stay visible until opened or dismissed. Click a notice
to open its result or session; right-click dismisses it. `ALT+N` does what a click does for the newest notice on
screen (`desk-notice-act`), and nothing when none is showing. Mako's middle-click
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

### Run-to-run numbers

A finished job's output is also read for the figures it prints, and each is set against the previous run of the
same job (the same command in the same folder of the same checkout, or the same title). The notebook's project page
lists the last job's figures, such as `p99 412ns (+38)   ↑ worse`; Enter opens its output.

```sh
desk-work metrics --root DIR [--job RUN]   # the newest finished job with figures, or the one named
desk-work metrics-parse --root DIR < LOG   # what a log would give, to try out a checkout's patterns
```

`metrics` answers JSON: `job` (id, title, command, state, ended), `previous` (the run it is compared with) and
`metrics`, each with `name`, `value`, `unit`, `previous`, `change` (in the current unit), `percent`, `delta`
(`"+38"`), `better` (`lower`, `higher` or null) and `verdict` (`better`, `worse`, `same`, `changed`, `new`). Time
units are better lower and rates higher; anything else (`%`, bytes, counts) only says `changed`. Units of one kind
compare across scales (`588ns` then `0.5us` is `-0.088`, better).

Reading is deliberately strict. A line counts only when all of it is `name value unit`, `name: value unit` or
`name=value unit` pairs (separated by spaces, commas, `;` or `|`; a leading `[tag]` or bullet is allowed), with a
unit from: `ns`, `us`/`µs`, `ms`, `s`, `%`, `/s`, `ops/s`, `K`/`M`/`G` before a rate or alone, `B`, `KB`, `MB`, `GB`
(and `KiB`/`MiB`/`GiB`), `B/s`-style byte rates, and `ns/op`-style per-operation times. A name that is itself a unit
reads as one (`ns/op 38.2`). A `name=value` pair with no unit is skipped; any other word or unitless number makes
the whole line no metric, so `Ran 12 tests in 0.4s`, `line 42`, `port=8080` and `version 1.2.3` are never read.
Test counts become `tests passed` and `tests failed`. A name printed twice keeps its last value.

A project with output that reads otherwise declares exact patterns in `.desk/metrics` at its top level, one per
line as `name unit regex`: the regex's first group is the number, and `-` stands for no unit. Blank lines, `#`
comments, unknown units and regexes that do not compile are skipped. Declared patterns read the last 5,000 lines
of a run, and win over the plain reading of the same name.

```
# name    unit  regex
fills     -     ^Filled ([0-9]+) orders
p99       us    ^latency p99 is ([0-9.]+)
```

Figures are recorded when a run finishes; `--job` reads an older run's log once on request. The previous value of
each name comes from the newest earlier run of the job that reported it, looking back 30 runs. A tool that prints its
figures as JSON or toolio is declared in `.desk/tools.json` instead, and each of its runs is set against the last the
same way ([desk-tools.md](desk-tools.md)).

Each captured run records its starting revision and the contents of supported
source/config files, including nonignored untracked files and uncommitted edits.
Comparisons use the most recent successful run of the same command in the same
checkout. Editing those files makes a result stale; changes during a run also
disqualify it as a baseline. Snapshots exclude secret paths, hidden files,
symlinks, binary files and ignored build outputs. They stop at 4,000 files,
1 MiB per file and 32 MiB total; an incomplete snapshot cannot establish a
passing baseline. Repos in `claude-private-repos` get no source copies.
Without a complete snapshot, git's tree ids decide, as they do for the review tree: a run begun on a clean tree
stays current while no source file differs from that tree, and a run begun with uncommitted edits cannot be
checked, which desk-work calls unverified, not stale.
External dependencies and environment changes are outside this source check.
Neovim labels a cached pass **last pass · unavailable** when it cannot refresh
the test records, **last pass · stale** when the recorded source differs from
the checkout and **last pass · unverified** when desk-work cannot tell (the drawer's test results say
"unverified" too). All three use the theme's warning color. The pass count returns when a refresh
verifies the same result or a newer one. A checkout with no recorded run shows nothing there, whether or not
desk-work answers.

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
item, **h** returns to the front page or closes the active field, and **e** edits
the selected file. The key bar shows the keys as `key: word`: on the front page
`j: ↓  k: ↑  l: open  n: next` (`s: later` on a needs-you row that can be snoozed)
over `p: more  d: drawer  z: compact  q: hide`; other pages start with `h: back`,
and the files page adds `e: edit  tests`.

Opening a commit through **Space Cw** or the review tray opens an exact Before / After comparison.
Check each file with **m**: once every file is checked the commit leaves the count of commits to review. **R**
records the review and asks what next (Next commit, Close review or Stay).
Opening it alone leaves it pending; file checkmarks survive closing and reopening the review. The tray considers the most recent
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
`desk dev work help` lists the underlying command interface.
