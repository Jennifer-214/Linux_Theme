# Work integration follow-ups

Implementation scope agreed on 2026-11-13. `desk-work` owns shared data, eligibility and actions; clients own
presentation and unsaved buffers. Installation uses native mapping and deployment helpers. Active agent sessions
must remain open, and validation uses disposable homes instead of the interactive installer.

| Work | Scope |
| --- | --- |
| Loaded update status | Compare source, installed and reported loaded versions; extend existing health checks |
| Watch recovery | Reconnect owned watchers with backoff, polling recovery and visible delayed status |
| Long sessions | Heartbeats, process identity and resume recovery without expiring live processes |
| Installer early input check | Narrow early-input-check exception approved; policy stays shared |
| Complete workflow check | Request, edit, test, review and watcher recovery across clients |
| Attention snoozing | Shared until-time or until-content-change state; preserve underlying records |
| Integration-only update | Native preview, staged deployment, backups and guarded rollback |
| Activity timeline | Shared records with canonical actions |
| Workspace restoration | Extend existing Neovim persistence, preserve notebook place and active project state |
| Cross-agent overlap | Observed edits, correct worktree boundaries, honest attribution |
| Relevant tests | Known captured test commands with freshness and an explanation; explicit run |
| Since-last-look digest | Per-consumer cursors over the same shared events |
| Adaptive notebook | Optional sizing, remembered preference and no background focus changes |
| Project preferences | User requested leaving this untouched; no preferences, symdeps or marker edits |

Additional scope approved after the first push:

| Work | Scope |
| --- | --- |
| Mandatory integration CI | Hosted checks fail on missing dependencies and use the approved generated SDK fixture |
| Interrupted updates | Recorded phases, active writer identity, guarded recovery and refusal to start over an unfinished transaction |
| Refresh diagnostics | Shared last-event/refresh/retry/loaded-version reporting in notebook, Neovim, drawer and health checks |
| Backup growth | Disk inventory, retention reasons, exact cleanup preview and protection of rollback chains and unfinished updates |
| Review and notebook usability | Review-local **Space re** / `:ReviewFiles` toggle the file list independently; preserve Neo-tree's **Space e**, reading positions, notebook page and selection |
