# Slice 04: `fox theme` + `fox dev` + `fox sys` Namespaces

Implements Phase 4 of `plans/architecture-refactor.md`. Three more namespaces using the now-established src/fox-ai/ + src/fox-sec/ template. Terser subplan because the pattern is mechanical at this point.

## Goal

After this slice ships, the full set of intended namespaces is live:
- `fox theme` (3 subcommands)
- `fox dev` (12 subcommands)
- `fox sys` (8 subcommands)

Plus `fox ai` + `fox sec` from prior phases = **5 namespaces, ~76 subcommands total** under `fox <ns> <sub>`.

## Subcommand inventory

**fox theme:** tweak, wallpaper, develop

**fox dev:** new-project, init, build-verify, test, word-count, distro-build, distro-flash, distro-guide, generate-module, template-lint, aider, tail

**fox sys:** install, uninstall, lock, hw-info, doctor, rollback, menu, cheatsheet

(`fox sys font` is intentionally NOT registered here — that's Phase 5's new-tool slice.)

## Implementation Order

Each namespace is one commit (dispatcher + dispatch.def + Makefile + tests). Same template as src/fox-sec/. Final commit wires all three into src/fox/dispatch.def + updates CLAUDE.md.

| Step | Action | Commit |
| --- | --- | --- |
| 1 | Create src/fox-theme/ (full scaffold + 3 entries + tests) | `feat(fox-theme): scaffold namespace dispatcher (3 subcommands)` |
| 2 | Create src/fox-dev/ (full scaffold + 12 entries + tests) | `feat(fox-dev): scaffold namespace dispatcher (12 subcommands)` |
| 3 | Create src/fox-sys/ (full scaffold + 8 entries + tests) | `feat(fox-sys): scaffold namespace dispatcher (8 subcommands)` |
| 4 | Wire all 3 into src/fox/dispatch.def + update CLAUDE.md + final verification | `feat(fox): wire theme/dev/sys namespaces + Phase 4 docs` |

## Collision notes

- `fox-doctor` (sys) coexists with `fox-ai-doctor` (ai). Dispatched as `fox sys doctor` vs `fox ai doctor`. Same pattern as snitch/audit/bouncer.
- `fox-test` (dev) coexists with `fox-ai-test` (ai). `fox dev test` vs `fox ai test`.
- No binary renames needed in this slice.

## Exit Criteria

- [ ] All 3 new dispatchers build clean
- [ ] All 3 have passing sanity tests (help/version/unknown + registry spot-checks)
- [ ] `fox help` lists all 5 namespaces
- [ ] `fox theme help`, `fox dev help`, `fox sys help` each work
- [ ] No regressions in fox-ai, fox-sec, fox-install
- [ ] CLAUDE.md updated with new tool table entries + status line bumped to "Phase 4 complete, Phase 5 (fox sys font new tool) next"
- [ ] .gitignore entries added for 3 new binaries

## Status

- **Subplan authored:** 2026-05-19
- **Steps complete:** 0 / 4
- **Slice complete:** *pending*
