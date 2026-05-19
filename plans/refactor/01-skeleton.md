# Slice 01: `fox-common/` Extraction + `src/fox/` Skeleton

Implements Phase 1 of `plans/architecture-refactor.md`. First concrete code change. No behavior change to existing tools — pure structural scaffolding so subsequent slices have somewhere to land.

## Goal

After this slice ships:
- `src/fox-common/` exists with promoted shared headers (`ui`, `shell`, `args`) + new `dispatch.hpp`, built as `libfox-common.a` per the existing fox-intel pattern.
- `src/fox/` exists as a thin top-level dispatcher binary. `fox help` prints "no namespaces registered yet."
- `src/fox-install/` updated to link against `libfox-common.a` instead of compiling those .cpp files directly. Still builds. Still runs identically.
- Root `Makefile` auto-discovers both new directories (no root edits needed per existing convention).
- `make test` continues to pass.

## Inventory

### Files to CREATE

| Path | Purpose |
| --- | --- |
| `src/fox-common/Makefile` | Produces `libfox-common.a`. Pattern matches `src/fox-intel/Makefile`. |
| `src/fox-common/ui.hpp` | (moved from fox-install/core/) |
| `src/fox-common/ui.cpp` | (moved from fox-install/core/) |
| `src/fox-common/shell.hpp` | (moved from fox-install/core/) |
| `src/fox-common/shell.cpp` | (moved from fox-install/core/) |
| `src/fox-common/args.hpp` | (moved from fox-install/core/) |
| `src/fox-common/args.cpp` | (moved from fox-install/core/) |
| `src/fox-common/dispatch.hpp` | NEW — header-only dispatcher helpers: namespace registry walking + `execvp` to leaf. Used by `src/fox/` and every future namespace dispatcher. |
| `src/fox/Makefile` | Builds `fox` binary, links against `libfox-common.a`. |
| `src/fox/main.cpp` | Top-level dispatcher entry. Parses argv[1] as namespace, dispatches via X-macro registry. |
| `src/fox/dispatch.def` | X-macro registry. Empty for this slice — `FOX_NAMESPACE(name, binary, description)` lines added in later phases. |
| `src/fox/tests/help_test.cpp` | Minimal test: `fox help` exits 0 and prints non-empty stdout. |
| `src/fox/tests/Makefile` (or fold into src/fox/Makefile) | `test` target invoked by root `make test`. |

### Files to MODIFY

| Path | Change |
| --- | --- |
| `src/fox-install/Makefile` | Stop compiling `core/ui.cpp`, `core/shell.cpp`, `core/args.cpp`. Link against `../fox-common/libfox-common.a` instead. |
| `src/fox-install/core/*.cpp` (all that `#include "ui.hpp"` etc) | Update `#include "ui.hpp"` → `#include "../../fox-common/ui.hpp"` (or via -I flag in Makefile, simpler). Same for shell, args. |
| `src/fox-install/modules/*.cpp` | Same include updates. |

### Files to DELETE (after move verified)

| Path | Why |
| --- | --- |
| `src/fox-install/core/ui.hpp` | Now lives in fox-common/ |
| `src/fox-install/core/ui.cpp` | Now lives in fox-common/ |
| `src/fox-install/core/shell.hpp` | Now lives in fox-common/ |
| `src/fox-install/core/shell.cpp` | Now lives in fox-common/ |
| `src/fox-install/core/args.hpp` | Now lives in fox-common/ |
| `src/fox-install/core/args.cpp` | Now lives in fox-common/ |

### Files staying put (fox-install-specific, NOT promoted)

These are intentionally NOT moved to fox-common — they're install-specific abstractions:
- `src/fox-install/core/context.hpp` (install Context struct)
- `src/fox-install/core/idempotency.hpp` (install state markers)
- `src/fox-install/core/module.hpp` (install module interface)
- `src/fox-install/core/modules.def` (X-macro install module registry)
- `src/fox-install/core/registry.cpp` (registry impl)
- `src/fox-install/core/sidecar.hpp/.cpp` (monitor-layout sidecar reader — install-specific for now; may promote in a later slice if other tools need it)

## Implementation Order

Each step is independently committable. Build + test runs between every step.

| Step | Action | Commit message |
| --- | --- | --- |
| 1 | Create `src/fox-common/` with Makefile producing `libfox-common.a`. Copy `ui.{hpp,cpp}`, `shell.{hpp,cpp}`, `args.{hpp,cpp}` from `src/fox-install/core/`. Verify `make -C src/fox-common` builds `libfox-common.a`. | `refactor(fox-common): scaffold shared core library (copy ui/shell/args from fox-install)` |
| 2 | Update `src/fox-install/Makefile` to add `-I../fox-common` and link `../fox-common/libfox-common.a`. Stop compiling the duplicate .cpp files in `core/`. Verify `make -C src/fox-install` builds and `--dry-run --full` runs identically. | `refactor(fox-install): link against libfox-common.a (no duplicate compile)` |
| 3 | Delete the now-duplicated files in `src/fox-install/core/`: `ui.{hpp,cpp}`, `shell.{hpp,cpp}`, `args.{hpp,cpp}`. Verify fox-install still builds + runs. | `refactor(fox-install): drop duplicate shared sources (moved to fox-common)` |
| 4 | Create `src/fox-common/dispatch.hpp` — header-only namespace registry + execvp helper. ~50 lines. | `feat(fox-common): add dispatch.hpp (namespace registry + execvp helper)` |
| 5 | Create `src/fox/` with `Makefile`, `main.cpp`, empty `dispatch.def`. Implement `fox help` (prints "No namespaces registered yet — this is Phase 1 scaffolding.") and `fox --version`. | `feat(fox): scaffold top-level dispatcher binary (fox help works)` |
| 6 | Add `src/fox/tests/help_test.cpp` + wire into `src/fox/Makefile`'s `test` target. Verify `make test` runs the new test green. | `test(fox): minimal help command sanity test` |
| 7 | Update `CLAUDE.md` to document `src/fox-common/` layout + the dispatcher contract. Update the "Adding a new tool" section to mention the fox-common headers. | `docs(claude.md): document fox-common + fox dispatcher pattern (Phase 1)` |

## Exit Criteria

- [ ] `make` from repo root builds successfully (all existing tools + fox-common + fox)
- [ ] `make test` passes (existing tests still green + new fox help test green)
- [ ] `./src/fox/fox help` runs, exits 0, prints non-empty stdout
- [ ] `./src/fox/fox --version` prints something useful
- [ ] `./src/fox-install/fox-install --dry-run --full` works identically to pre-refactor
- [ ] `src/fox-common/libfox-common.a` exists post-build
- [ ] `src/fox-install/core/` is reduced — only context.hpp, idempotency.hpp, module.hpp, modules.def, registry.cpp, sidecar.hpp/cpp remain
- [ ] CLAUDE.md updated with new src/fox-common/ layout

## Risks

| Risk | Mitigation |
| --- | --- |
| **Breaking fox-install during the move.** Subtle include-path bugs, missed .cpp files. | Build + run `fox-install --dry-run --full` after every step. If anything regresses, revert that step's commit immediately. |
| **Static lib link issues.** Wrong order, missing symbols, ABI mismatch. | Match the proven pattern from `src/fox-intel/Makefile` (libfox-intel.a). Don't invent new linking conventions. |
| **Header guards / include cycles.** Promoting headers can expose latent ordering bugs. | Compile with `-Wall -Wextra -Wpedantic` (per D19). Treat warnings as flags to investigate, not noise to ignore. |
| **Root Makefile picks up `src/fox-common/`** as a "tool" and tries `install` on it. | Verify `make install` doesn't try to copy `libfox-common.a` to `~/.local/bin` (it's a build-time dep, not a binary). Either make fox-common's `install` target a no-op OR document that lib-style components ship with a no-op install. |
| **Tests for fox don't pick up the right binary path.** | Use absolute-from-test-dir path in the test (`../fox` or invoke via the test runner's PWD). |

## Rollback Strategy

Each step is its own commit. If anything goes wrong:
- `git reset --hard HEAD~1` (or to the slice's parent commit) restores the previous working state.
- The plan file (`plans/architecture-refactor.md`) and this subplan stay committed — only the code changes revert.
- Re-attempt the failed step with whatever the diagnostic revealed.

No destructive operations (no `git push --force`, no shared-branch rewrites, no DB migrations). All-local-all-reversible.

## Status

- **Subplan authored:** 2026-05-18
- **Slice started:** *pending*
- **Steps complete:** 0 / 7
- **Slice complete:** *pending*
