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
