# Handoff — Architecture Refactor, mid-Phase 6

Resume point for the next session of the FoxML workstation architecture refactor. Originally written 2026-05-19 after Phases 0-4 and Phase 6 Session A. Updated 2026-05-19 after Phase 6 Session B (Steps 5-7) shipped.

## Read these first, in this order

1. `CLAUDE.md` — overall conventions + native tool layout
2. `plans/architecture-refactor.md` — master plan: 19 architectural decisions (D1-D19), 25 related work items (R1-R25), phase table. TOC at the top makes the 1100+ lines navigable.
3. `plans/refactor/06-state-driven-installer.md` — the slice in progress. Session A is **done** (Steps 1-4). Session B starts at Step 5.

## What's done

| Phase | Commits | Result |
| ----- | ------- | ------ |
| 0 — master plan | 1 | `plans/architecture-refactor.md` written + gitignore exception added |
| 1 — fox-common + fox skeleton | 8 | `src/fox-common/` (ui+shell+dispatch helpers, libfox-common.a). `src/fox/` top-level dispatcher binary. `fox-install` relinked. **Note: args.{hpp,cpp} was NOT promoted** because args.hpp `#include`s context.hpp and args.cpp `#include`s module.hpp (both fox-install-specific). Args promotion is its own future slice. |
| 2 — fox ai namespace | 6 | `src/fox-ai/` dispatcher, 23 subcommands registered via dispatch.def |
| 3 — fox sec namespace | 5 | `src/fox-sec/` dispatcher, 30 subcommands. **Existing fox-sec dashboard was renamed to fox-sec-dashboard** (`shared/bin/fox-sec-dashboard`) to free up the namespace name. Reachable as `fox sec dashboard`. |
| 4 — theme/dev/sys namespaces | 4 | `src/fox-theme/` (3), `src/fox-dev/` (12), `src/fox-sys/` (8). All wired into `src/fox/dispatch.def`. |
| 6 Session A — state-driven installer foundation | 4 | `src/fox-install/core/state_manifest.{hpp,cpp}` + `classifier.{hpp,cpp}` + tests. Manifest read/write integrated into fox-install — fully additive, no behavior change yet. |
| 6 Session B — classification & prereqs + conflict resolve | 3 | `FOX_MODULE_FULL` X-macro (prereqs + state_check fields, legacy `FOX_MODULE` defaults the new fields to false/nullptr). `state_checks::check_{deps,render,etckeeper}` (only deps/render/etckeeper are converted; the other 47 modules stay legacy). `conflict_resolve::{prompt, apply, Decision}` with file-IO test coverage. **Not wired into the dispatcher yet** — pure plumbing this session. |

**Surface live:** `fox help` lists ai/sec/theme/dev/sys. 76 subcommands accessible as `fox <ns> <sub>`. Direct invocations (`fox-ai-doctor`, `fox-firewall`, etc.) still work unchanged.

**Test suites (11, all green):** fox-install (registry 52 modules + state_manifest 25 assertions + classifier 14 assertions + state_checks 9 assertions + conflict_resolve 26 assertions), fox sanity, fox-ai sanity, fox-sec sanity, fox-theme sanity, fox-dev sanity, fox-sys sanity, fox-render, fox-vault.

## What's next — Phase 6 Session C (Steps 8-11)

Now that the foundation (manifest, classifier, state_checks, conflict resolve) is built and tested, the next session wires it into a user-facing flow. From the subplan:

**Step 8 — ftxui dependency.** Pacman has it (`pacman -S ftxui`); add to the deps module's package list and link `-lftxui-screen -lftxui-dom -lftxui-component` from a new `Makefile` target. Don't vendor it — the AUR/extra version is fine.

**Step 9 — Wizard config phase.** One-screen-per-module ftxui UI showing description, current Classification (Fresh / Noop / Update / Conflict / Blocked), and options. h/l (vim) navigation; q aborts. Caramel asked for forward-only auto-advance once selections are made — implement that.

**Step 10 — Manifest preview screen.** Aggregate all selections from Step 9, show the full plan as a single scrollable list, and ask for one y/n commit. This is the "review your plan before I touch anything" gate.

**Step 11 — Execution phase.** Live TUI during run: current module name, progress bar, log tail (last N lines from each module's stdout). No prompts during execution — errors get queued for end-of-run review (Session D Step 12 builds the absorption layer). Preserve the existing fox-install end-of-install summary format per Caramel's earlier feedback.

The dispatcher in `fox-install.cpp` is where these get integrated. The existing main loop becomes the "execute" phase from Step 11; Steps 9-10 happen ahead of it (gated on a `FOX_INSTALL_STATE_DRIVEN=1` env var until the cutover in Session E).

**Already in place to draw from:**
- `state::check_{deps,render,etckeeper}` produces Classification for any module that opts in (slot for more state_checks as needed).
- `Module::requires_{root,graphical,network}` is wired but unused — Session C's wizard should read these and either skip (when prereqs unmet) or show a "Blocked: needs X" indicator.
- `conflict::prompt()` is the v1 prompt UI; Session C swaps it for an ftxui screen, but the `apply()` function stays as-is.

## Quality bars (per D19)

- Build clean under `-Wall -Wextra -Wpedantic` (no exceptions, no warnings)
- All existing tests must stay green — run `make test` from repo root before each commit
- One commit per logical step, descriptive messages, include `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
- No raw `new`/`delete`, RAII everywhere, `std::optional<T>` over nullable pointers
- Atomic file writes (tmp + rename — pattern already used in `state_manifest.cpp`)
- Subprocess via `sh::run`/`sh::capture` only, never raw `system()`/`popen()`

## Load-bearing context

- **Mid-refactor state.** `install.sh` is still a thin bash wrapper that builds fox-install + execs it. The state-driven installer rewrite (Phase 6) eventually replaces this — but Phase 6 is multi-session, so for now the OLD install path still works and is the active one. The state manifest plumbing is non-gated additive code.
- **Leaf binaries not renamed.** Per D4 (language-agnostic leaves), `fox-ai-doctor`, `fox-firewall`, etc. keep their existing names. The dispatcher just `execvp`s to them. No mass rename in this refactor.
- **gitignore exceptions.** `plans/architecture-refactor.md` AND `plans/refactor/**` are explicitly excepted from `plans/*` in `.gitignore`. Other plan files in `plans/` (e.g., `fox-intel-modernization.md`) stay local-only per existing convention.
- **C++ build dependency chain.** Each namespace dispatcher's Makefile links `../fox-common/libfox-common.a`. The fox-install Makefile also links `-lcrypto` (OpenSSL, for SHA256 in state_manifest).
- **JSON dependency.** Use the vendored `src/fox-intel/json.hpp` (nlohmann/json 3.12.0). Don't add a new JSON dep.
- **Caramel push-back pattern.** Caramel will often push past explicit "this is a good stopping point" recommendations to ship more. Session B held the line at the planned 3 steps (5-7); Session C is harder to defer mid-step because Steps 9-11 are visibly *the new install UI* and the temptation to "just finish it" is real. **The cleanest checkpoint inside Session C is after Step 9 (wizard config phase) — once that's done, the user has something to look at. Steps 10-11 can run the next session without anything feeling half-finished.**

## Reference: session counts

- Long Session 1 (Phases 0-4 + Phase 6 Session A): 33 commits.
- Short Session 2 (Phase 6 Session B): 3 commits — `1d7199b`, `ae42232`, `b9dbdf0`.
- **Cumulative**: 36 commits past `c3b9b2f` (the pre-refactor tip). All commits atomic, per-step, reversible.
- Each phase has its own subplan in `plans/refactor/0N-<slice>.md`.
- Pattern is established: namespace dispatcher = `src/fox-X/{Makefile, main.cpp, dispatch.def, tests/dispatch_test.sh}`. Use `src/fox-ai/` as the canonical template.

## Start by

```bash
cd /home/caramel/code/Linux_Theme
git log --oneline c33e27c..HEAD     # see everything shipped
cat plans/architecture-refactor.md  # TOC at top, scan structure
cat plans/refactor/06-state-driven-installer.md  # Phase 6 detail
```

Then begin Phase 6 Step 8 (ftxui dependency wiring).
