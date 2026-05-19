# Slice 02: `fox ai *` Namespace Migration

Implements Phase 2 of `plans/architecture-refactor.md`. First real CLI surface change: `fox ai <subcommand>` becomes the canonical entry for AI-augmented tools.

## Goal

After this slice ships:
- `src/fox-ai/` exists as a namespace dispatcher binary, mirroring `src/fox/`'s pattern.
- 23 fox-ai-* leaf binaries (7 C++ + ~16 bash, deduped) are wired into `src/fox-ai/dispatch.def`.
- `src/fox/dispatch.def` has one new line: `FOX_NAMESPACE(ai, fox-ai, "AI-augmented tools")`.
- `fox ai` → lists subcommands. `fox ai doctor` → execs `fox-ai-doctor` with remaining args. `fox ai bogus` → "unknown subcommand", exit 2.
- Leaf binaries are **NOT renamed or moved** — per D4 (language-agnostic leaves), dispatcher just execvps to the existing binary by name. No mass rename to fox-doctor / fox-ai-doctor confusion.
- Existing direct invocations (`fox-ai-doctor`, `fox-ai-snitch`) still work — old surface stays alive during transition. Phase 5+ deprecates the direct names per D5.

## Inventory

### Files to CREATE

| Path | Purpose |
| --- | --- |
| `src/fox-ai/Makefile` | Builds fox-ai binary, links libfox-common.a. Mirrors src/fox/Makefile. |
| `src/fox-ai/main.cpp` | Namespace dispatcher entry. Same shape as src/fox/main.cpp but reads its own dispatch.def. |
| `src/fox-ai/dispatch.def` | X-macro registry: 23 `FOX_SUBCMD(name, binary, description)` lines. |
| `src/fox-ai/tests/dispatch_test.sh` | Sanity test: `fox-ai help` works, `fox-ai bogus` exits 2, all registered subcommands are listed. |

### Files to MODIFY

| Path | Change |
| --- | --- |
| `src/fox/dispatch.def` | Add `FOX_NAMESPACE(ai, fox-ai, "AI-augmented tools (doctor, snitch, review, ...)")` |
| `.gitignore` | Add `src/fox-ai/fox-ai` (binary artifact). |
| `CLAUDE.md` | Add `fox-ai` row to native tools table; brief note on the namespace dispatcher pattern now having a live example. |

### Subcommands to register

**From C++ binaries (`src/fox-ai-*/`):**
- audit, bouncer, doctor, oracle, review, snitch, swap

**From bash scripts (`shared/bin/fox-ai-*`), deduping collisions where C++ wins:**
- bench, cmd, commit, default, explain, find, history, log, purge, quick, setup-project, status, strategy, test, trace, watch

**Collisions handled:** `review` and `swap` exist as both C++ and bash. Dispatcher just calls `fox-ai-review` / `fox-ai-swap` by name; whichever binary is on $PATH wins. Standard install behavior puts the C++ binary in `~/.local/bin` so C++ wins by default.

**Skipped from this slice:** `fask`, `findex`, `fhelp` — these don't start with `fox-ai-` so they're separate. Either they get their own slice or get added later as `fox ai ask` / `fox ai index` / `fox ai help` aliases.

## Implementation Order

| Step | Action | Commit message |
| --- | --- | --- |
| 1 | Refactor `src/fox/main.cpp` to extract the dispatcher core into a reusable form so `src/fox-ai/main.cpp` can use it. *OR* duplicate the pattern (cheaper for now). **Choice: duplicate.** Future cleanup slice can DRY them if it becomes painful. | *(no commit yet — design choice noted)* |
| 2 | Create `src/fox-ai/` with Makefile, main.cpp, empty dispatch.def. Verify `make` builds, `fox-ai help` works with empty registry. | `feat(fox-ai): scaffold namespace dispatcher binary (empty registry)` |
| 3 | Populate `src/fox-ai/dispatch.def` with all 23 subcommands. Rebuild. Verify `fox-ai help` lists them all. | `feat(fox-ai): register 23 subcommands in dispatch.def` |
| 4 | Add `FOX_NAMESPACE(ai, fox-ai, "...")` to `src/fox/dispatch.def`. Rebuild fox. Verify `fox help` lists ai, `fox ai help` lists subcommands, `fox ai doctor` execs fox-ai-doctor. | `feat(fox): wire fox-ai namespace into top-level dispatcher` |
| 5 | Add `src/fox-ai/tests/dispatch_test.sh` covering: help works, unknown subcommand exits 2, every registered subcommand shows up in help output. Wire into Makefile's test target. | `test(fox-ai): sanity tests for dispatcher` |
| 6 | Update CLAUDE.md: add fox-ai row to tools table, note that the namespace dispatcher pattern now has a live example to reference. | `docs(claude.md): document fox-ai namespace dispatcher (Phase 2)` |
| 7 | Update gitignore for src/fox-ai/fox-ai binary. | (folded into step 2 or 4 if untracked) |

## Exit Criteria

- [ ] `make` from root builds (fox + fox-ai + fox-common + fox-install all green)
- [ ] `make test` passes (fox + fox-ai + fox-install + fox-render + fox-vault)
- [ ] `fox help` lists `ai` as a namespace
- [ ] `fox ai help` lists all 23 subcommands with descriptions
- [ ] `fox ai doctor --help` execs fox-ai-doctor with --help (verifying execvp path)
- [ ] `fox ai bogus` → "unknown subcommand", exit 2
- [ ] Direct calls (`fox-ai-doctor`, etc.) still work unchanged
- [ ] CLAUDE.md updated with fox-ai entry
- [ ] No regressions in any other tool

## Risks

| Risk | Mitigation |
| --- | --- |
| **Description text drift.** Pulled from binary listing; some may not match what each tool actually does. | Use the existing `fox-help` output (or each binary's own `--help`) as authoritative; cross-check before commit. Imperfect descriptions are acceptable and fixable in follow-up — better than blocking on perfection. |
| **`fox-ai` shadows an existing `fox-ai-*` binary** if PATH ordering puts `~/.local/bin/fox-ai` after a directory with `fox-ai-doctor`. | Use exact binary names in dispatch.def (`fox-ai-doctor` not `doctor`); rely on PATH lookup. Verify nothing else owns the exact name `fox-ai`. |
| **Bash scripts call `fox-ai-*` by name internally**, expecting the old direct surface. | Since direct names stay alive during transition (D4 — language-agnostic leaves), internal scripts keep working. Audit happens later when we drop direct names (D5/Phase 5+). |
| **Subcommand name collisions across namespaces** (e.g., `fox ai snitch` vs eventual `fox sec snitch`). | This is the whole point of namespacing — both can coexist. Each namespace owns its own dispatch.def. |

## Status

- **Subplan authored:** 2026-05-18
- **Steps complete:** 0 / 6
- **Slice complete:** *pending*
