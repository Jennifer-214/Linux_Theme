# Slice 03: `fox sec *` Namespace Migration

Implements Phase 3 of `plans/architecture-refactor.md`. Same shape as Phase 2 (Slice 02) with two wrinkles: (a) existing `fox-sec` binary is the security dashboard and collides with the new namespace dispatcher name, (b) 29 subcommands instead of 23.

## Goal

After this slice ships:
- `src/fox-sec/` exists as a namespace dispatcher binary, mirroring `src/fox-ai/`.
- Existing `fox-sec` dashboard renamed to `fox-sec-dashboard` (in `shared/bin/`); new dispatcher takes the `fox-sec` name. Dispatch.def has a `dashboard` subcommand pointing at it so behavior is preserved.
- 30 subcommands registered: the 29 security tools per the master plan + `dashboard` for the moved-aside dashboard.
- `fox sec` is wired into `src/fox/dispatch.def`.
- Verified collision-free against `fox ai` namespace (e.g., `fox ai snitch` vs `fox sec snitch` route to different leaves).

## Collision Handling

| Today's name | Today's role | New name | New invocation |
| --- | --- | --- | --- |
| `fox-sec` (in shared/bin/) | security dashboard | `fox-sec-dashboard` | `fox sec dashboard` |
| (new) `fox-sec` | namespace dispatcher | unchanged | `fox sec <subcommand>` |

Confirmed pre-flight: only my own comment in `src/fox/main.cpp` references `fox-sec` by name. No live waybar/hyprland configs, no other shared scripts call it. Rename is safe.

## Inventory — subcommands to register

29 from master plan + 1 dashboard:

**Auditing / monitoring:** audit, snitch, sentry-audit, overwatch, tripwire, dispatch, audit-timer
**Network:** firewall, vpn, dns-shield, dnssec, ports, knock, spa, offline
**Identity:** fingerprint, mac
**Isolation:** jail, sandbox, allowlist
**Device:** usb, bouncer, deadman, proximity
**State / posture:** arm, harden, cafe, backup
**Honeypots:** honey, honeypot
**Dashboard:** dashboard

All leaves are bash scripts in `shared/bin/fox-*`. No C++ binaries in the security namespace.

## Implementation Order

| Step | Action | Commit |
| --- | --- | --- |
| 1 | Rename `shared/bin/fox-sec` → `shared/bin/fox-sec-dashboard`. Same content, just new name. Live binary in ~/.local/bin stays put until next install. | `refactor(shared/bin): rename fox-sec → fox-sec-dashboard (dispatcher takes the name)` |
| 2 | Create `src/fox-sec/` with Makefile, main.cpp, dispatch.def (full 30 entries). Mirrors src/fox-ai/. Add tests/dispatch_test.sh. Verify build + tests green. | `feat(fox-sec): scaffold namespace dispatcher with 30 subcommands + tests` |
| 3 | Update `src/fox/dispatch.def` to add `FOX_NAMESPACE(sec, fox-sec, "...")`. Rebuild fox. Verify `fox help` lists ai + sec, `fox sec help` lists subcommands, `fox sec dashboard` routes to fox-sec-dashboard, `fox sec snitch` routes to fox-snitch (NOT fox-ai-snitch). | `feat(fox): wire fox-sec namespace into top-level dispatcher` |
| 4 | Update CLAUDE.md: add fox-sec row to tools table, update status to "Phase 3 complete". | `docs(claude.md): document fox-sec namespace dispatcher (Phase 3)` |
| 5 | Update gitignore for src/fox-sec/fox-sec binary artifact. | (folded into step 2) |

## Exit Criteria

- [ ] `make` from root builds (fox + fox-ai + fox-sec + fox-common + fox-install)
- [ ] `make test` passes all 5+ suites
- [ ] `fox help` lists `ai` AND `sec` as namespaces
- [ ] `fox sec help` lists all 30 subcommands
- [ ] `fox sec dashboard` executes fox-sec-dashboard (= the old fox-sec dashboard logic)
- [ ] `fox ai snitch` and `fox sec snitch` route to DIFFERENT leaves (collision resolution demo)
- [ ] No regressions in fox-ai namespace or fox-install
- [ ] CLAUDE.md updated

## Risks

| Risk | Mitigation |
| --- | --- |
| Renaming fox-sec breaks a caller I missed in pre-flight grep | Pre-flight only found my own comment. Re-grep all .sh + .conf + .json + .tmpl for `fox-sec\b` (word boundary) before commit. If anything is found, update those callers in the same commit as the rename. |
| Live `~/.local/bin/fox-sec` keeps the old dashboard content until next install | Acceptable — tonight's testing is via build-tree paths, not live binaries. Document in Step 1 commit message that install is required to sync. |
| Two new dispatcher binaries (fox-ai + fox-sec) share ~90% of the code | Acknowledged. Future DRY-it-up slice can extract to a `fox-common/namespace_dispatcher.hpp` if the duplication grows past 2-3 instances. Not yet. |

## Status

- **Subplan authored:** 2026-05-19
- **Steps complete:** 0 / 4
- **Slice complete:** *pending*
