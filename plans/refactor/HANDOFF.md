# Handoff — Architecture Refactor, mid-Phase 6

Resume point for the next session of the FoxML workstation architecture refactor. Originally written 2026-05-19 after Phases 0-4 and Phase 6 Session A. Updated 2026-05-19 after Sessions B + C-first-half (Steps 5-9) shipped.

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
| 6 Session C (first half) — wizard data flow + interactive UI | 3 | Decision to drop ftxui (bootstrap-path risk; minimalist aesthetic wants rofi+hjkl-style modals, not declarative components — see subplan §"Wizard + execution"). `wizard::{Action, ModulePlan, Plan, default_plan, run}` in `core/wizard.{hpp,cpp}`. Interactive ASCII wizard: hjkl navigation, SPACE toggle (binary) / cycle (Conflict), q aborts. `--wizard-demo` CLI flag for manual rendering against the live registry. **Not wired into the install flow yet** — Steps 10-11 next session. |

**Surface live:** `fox help` lists ai/sec/theme/dev/sys. 76 subcommands accessible as `fox <ns> <sub>`. Direct invocations (`fox-ai-doctor`, `fox-firewall`, etc.) still work unchanged. `fox-install --wizard-demo` renders the new state-driven wizard against the live registry.

**Test suites (12, all green):** fox-install (registry 52 modules + state_manifest 25 assertions + classifier 14 assertions + state_checks 9 assertions + conflict_resolve 26 assertions + wizard 27 assertions), fox sanity, fox-ai sanity, fox-sec sanity, fox-theme sanity, fox-dev sanity, fox-sys sanity, fox-render, fox-vault.

## What's next — Phase 6 Session C (second half: Steps 10-11)

**Step 10 — Manifest preview screen.** After `wizard::run()` returns a Plan, show the user a consolidated overview before touching anything. One row per non-skipped module: slug, action, reason. Final `ui::ask_yn("Apply this plan?", true, ctx.assume_yes)` gates execution. If the user says no, return cleanly without running anything.

Likely fits in `core/wizard.cpp` as `wizard::preview(plan, ctx)` returning bool, or in a new `core/plan_preview.{hpp,cpp}` if the file gets crowded. Keep the rendering ASCII — same printf primitives as `wizard::run`.

**Step 11 — Dispatcher integration.** The existing main loop in `fox-install.cpp` (lines ~220-293) currently iterates `MODULES[i]`, runs each if `parsed.module_enabled[i]`, captures exceptions, writes the state file for `--resume`. Wire the wizard ahead of it:

1. After manifest read + detect, build `wizard::default_plan(MODULES, ctx, manifest)`.
2. If `FOX_INSTALL_STATE_DRIVEN=1` env var set: run `wizard::run()` + `wizard::preview()` (or just the preview when `--yes`), then iterate the Plan instead of `parsed.module_enabled`.
3. For each `ModulePlan` whose action is `Run`, call `m->fn(ctx)` as today.
4. For each whose action is `Conflict`, call `m->fn(ctx)` then `conflict::apply(mp.conflict_decision, deployed_path, source_path)` — but we don't have per-module file paths yet. **Either** add a `deploy_paths` callback to the Module struct (more refactor), **or** push the conflict-apply down into individual module bodies (each Conflict-aware module's `run_X` reads `Plan` and calls `apply`).
5. Skip everything else.

The Plan + Module + decision wiring needs a small piece of glue — probably a `dispatcher::execute(plan, ctx)` function in `core/dispatcher.{hpp,cpp}` so the main loop stays readable.

Env-var gate is per the master plan — keep the legacy flag-driven path working until Session E cutover.

**Manual verification path:** `fox-install --wizard-demo` already builds the plan + runs the wizard against the live registry. Step 10's preview just bolts on the next screen; Step 11's execution unlocks `FOX_INSTALL_STATE_DRIVEN=1 fox-install --dry-run` as the real test.

**Already in place to draw from:**
- `wizard::default_plan + run` — Plan generation + interactive editing.
- `conflict::apply(decision, deployed, source)` — atomic file-IO for diverged files.
- `state::check_{deps,render,etckeeper}` — Classification for those modules; other state_checks can be added incrementally as Step 11's integration surfaces more needs.
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
- **Caramel push-back pattern.** Caramel will often push past explicit "this is a good stopping point" recommendations to ship more. Session B held the line at 3 steps (5-7); Session C's first half held at 2 steps (8-9) with `--wizard-demo` as the verification path. Steps 10-11 are the dispatcher integration — they touch fox-install's hottest code path (the main install loop) and need careful design around the env-var gate + Conflict-module dispatch. **The cleanest next checkpoint is after Step 10 (manifest preview screen): the wizard + preview together give a complete read-only inspection mode. Step 11 — wiring the Plan into actual execution — is where mistakes can break the install flow for everyone, so it deserves its own focused session.**

## Reference: session counts

- Long Session 1 (Phases 0-4 + Phase 6 Session A): 33 commits.
- Short Session 2 (Phase 6 Session B): 4 commits including doc — `1d7199b`, `ae42232`, `b9dbdf0`, `a5b7500`.
- Short Session 3 (Phase 6 Session C, first half): 4 commits including doc — `4d48463`, `8ec0d48`, `00b35e5`, plus this handoff update.
- **Cumulative**: ~42 commits past `c3b9b2f` (the pre-refactor tip). All commits atomic, per-step, reversible.
- Each phase has its own subplan in `plans/refactor/0N-<slice>.md`.
- Pattern is established: namespace dispatcher = `src/fox-X/{Makefile, main.cpp, dispatch.def, tests/dispatch_test.sh}`. Use `src/fox-ai/` as the canonical template.

## Start by

```bash
cd /home/caramel/code/Linux_Theme
git log --oneline c33e27c..HEAD     # see everything shipped
cat plans/architecture-refactor.md  # TOC at top, scan structure
cat plans/refactor/06-state-driven-installer.md  # Phase 6 detail
./src/fox-install/fox-install --wizard-demo  # see the current wizard UI
```

Then begin Phase 6 Step 10 (manifest preview screen).
