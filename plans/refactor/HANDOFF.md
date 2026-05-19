# Handoff — Architecture Refactor, mid-Phase 6

Resume point for the next session of the FoxML workstation architecture refactor. Originally written 2026-05-19 after Phases 0-4 and Phase 6 Session A. Updated 2026-05-19 after Sessions B + C (Steps 5-11) shipped — the state-driven install path is now end-to-end usable behind `FOX_INSTALL_STATE_DRIVEN=1`.

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
| 6 Session C (first half) — wizard data flow + interactive UI | 3 | Decision to drop ftxui (bootstrap-path risk; minimalist aesthetic wants rofi+hjkl-style modals, not declarative components — see subplan §"Wizard + execution"). `wizard::{Action, ModulePlan, Plan, default_plan, run}` in `core/wizard.{hpp,cpp}`. Interactive ASCII wizard: hjkl navigation, SPACE toggle (binary) / cycle (Conflict), q aborts. `--wizard-demo` CLI flag for manual rendering against the live registry. |
| 6 Session C (second half) — preview + dispatcher integration | 2 | `wizard::preview(plan, ctx)` — section header with counts, per-module list with `+`/`-`/`!` markers, `Apply this plan? [Y/n]` commit prompt. `--wizard-demo` runs wizard + preview together. **Dispatcher integration**: behind `FOX_INSTALL_STATE_DRIVEN=1` the main loop now runs `default_plan → run → preview → translate back to module_enabled`. Legacy flag-driven path is unchanged when the env-var is unset. **Conflict-action modules are run-as-normal**: `conflict_decision` is recorded in the Plan but not yet threaded into modules' file-deploy paths — that's the next session's open design call. |

**Surface live:** `fox help` lists ai/sec/theme/dev/sys. 76 subcommands accessible as `fox <ns> <sub>`. Direct invocations (`fox-ai-doctor`, `fox-firewall`, etc.) still work unchanged. `fox-install --wizard-demo` walks the wizard + preview against the live registry. `FOX_INSTALL_STATE_DRIVEN=1 fox-install --dry-run` runs the state-driven install path end-to-end.

**Test suites (12, all green):** fox-install (registry 52 modules + state_manifest 25 assertions + classifier 14 assertions + state_checks 9 assertions + conflict_resolve 26 assertions + wizard 31 assertions), fox sanity, fox-ai sanity, fox-sec sanity, fox-theme sanity, fox-dev sanity, fox-sys sanity, fox-render, fox-vault.

## What's next — open follow-up + Phase 6 Session D (Steps 12-14)

**Open follow-up (small, before Session D): conflict_decision bridge.** Step 11 ships the state-driven dispatch gate but treats `Action::Conflict` as `Action::Run` for now — the user's `conflict_decision` is recorded in the Plan and rendered in `wizard::preview` but isn't applied to the actual deploy paths. Two viable designs, both noted in Step 11's commit message:

1. **Per-module `deploy_paths` callback** in the `Module` struct: a function that returns `vector<DeployPath{deployed_path, source_path}>`. The dispatcher walks these post-run and calls `conflict::apply(decision, deployed, source)` for each. Pro: dispatcher stays clean. Con: every Conflict-aware module needs a callback added.
2. **In-module dispatch**: each Conflict-aware module reads the active `ModulePlan` (passed via a small thread-local or via expanded `ModuleFn` signature) and calls `conflict::apply` itself during its own deploy step. Pro: no new metadata. Con: spreads the logic across modules; harder to test in isolation.

Pick one before starting Session D — the choice shapes which module signatures get touched.

**Step 12 — Subprocess error absorption.** `sh::run` currently inherits stdio, so error output scrolls past during install. Extend `fox-common/shell.hpp` so `sh::run`/`capture` return `{exit_code, stdout, stderr, duration}`. Route stderr to a log file (somewhere under `~/.local/state/foxml/` or `$XDG_STATE_HOME`) + reformat to a single "X failed: see line Y" line in the UI. Existing modules keep their call sites; the wrapper just adds capture.

**Step 13 — Repair-mode `--full` semantics.** Currently `--full` sets `parsed.module_enabled[*] = true`. State-driven repair mode should also: (a) re-run every module that classifies as Update or Conflict, (b) skip Noop modules with a clear log line, (c) preserve user customizations (BackupThenTakeNew by default for Conflicts under `--full`). Wire when the conflict_decision bridge above is ready.

**Step 14 — Install lockfile (R17).** `flock(LOCK_EX)` on `/run/foxml-install.lock` (or `$XDG_RUNTIME_DIR/foxml-install.lock` if unprivileged) at the top of main(). Second invocation prints a clear "another install is running, PID X" error + fast-fails. Atomic, simple, prevents two interactive wizards from racing each other.

**Manual verification paths now available:**
- `./src/fox-install/fox-install --wizard-demo` — wizard + preview against live registry, no install.
- `FOX_INSTALL_STATE_DRIVEN=1 ./src/fox-install/fox-install --dry-run --yes` — full state-driven flow, no side effects.
- `FOX_INSTALL_STATE_DRIVEN=1 ./src/fox-install/fox-install --dry-run --only render` — interactive wizard against a small subset.

**Already in place to draw from:**
- `wizard::{default_plan, run, preview}` — full Plan lifecycle.
- `conflict::apply(decision, deployed, source)` — atomic file-IO; ready to be called from wherever the dispatcher bridge lands.
- `state::check_{deps,render,etckeeper}` — Classification for those three; other state_checks can be added incrementally as need arises.
- `Module::requires_{root,graphical,network}` — read by the wizard's prereq display, not yet used for gating. D18 in Session E gates on `$XDG_SESSION_TYPE`.

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
- **Caramel push-back pattern.** Caramel will often push past explicit "this is a good stopping point" recommendations to ship more. Session B held at 3 steps (5-7); Session C's first half held at 2 steps (8-9); the second half added 2 more (10-11) and reached a real milestone — the state-driven path is end-to-end usable. **The cleanest next checkpoint is after deciding the conflict_decision bridge design (small but load-bearing) AND finishing Step 12 (subprocess error absorption).** That gets us a usable, low-pain `FOX_INSTALL_STATE_DRIVEN=1` install where errors don't scroll past, before tackling Step 13's repair-mode semantics (which need real test runs against drifted state).

## Reference: session counts

- Long Session 1 (Phases 0-4 + Phase 6 Session A): 33 commits.
- Short Session 2 (Phase 6 Session B): 4 commits including doc — `1d7199b`, `ae42232`, `b9dbdf0`, `a5b7500`.
- Session 3 (Phase 6 Session C, full): 6 commits including docs — `4d48463`, `8ec0d48`, `00b35e5`, `ae47a1b`, `31f5b0b`, `58a3b94`.
- **Cumulative**: ~44 commits past `c3b9b2f` (the pre-refactor tip). All commits atomic, per-step, reversible.
- Each phase has its own subplan in `plans/refactor/0N-<slice>.md`.
- Pattern is established: namespace dispatcher = `src/fox-X/{Makefile, main.cpp, dispatch.def, tests/dispatch_test.sh}`. Use `src/fox-ai/` as the canonical template.

## Start by

```bash
cd /home/caramel/code/Linux_Theme
git log --oneline c33e27c..HEAD     # see everything shipped
cat plans/architecture-refactor.md  # TOC at top, scan structure
cat plans/refactor/06-state-driven-installer.md  # Phase 6 detail
./src/fox-install/fox-install --wizard-demo                          # wizard + preview UI
FOX_INSTALL_STATE_DRIVEN=1 ./src/fox-install/fox-install --dry-run   # state-driven full flow, no side effects
```

Then pick: small follow-up on the conflict_decision bridge (open design question above), or begin Phase 6 Step 12 (subprocess error absorption).
