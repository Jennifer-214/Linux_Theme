# Handoff — Architecture Refactor, mid-Phase 6

Resume point for the next session of the FoxML workstation architecture refactor. Originally written 2026-05-19 after Phases 0-4 and Phase 6 Session A. **Latest update 2026-05-19 after Sessions B-E shipped through Step 21.** Phase 6 is at 19/22 — only Step 19 (deferred; no-op today), Step 20 (cutover), and Step 22 (master-plan close-out) remain, and all three are gated on real-install miles + the cutover decision.

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
| 6 Session C (second half) — preview + dispatcher integration | 2 | `wizard::preview(plan, ctx)` — section header with counts, per-module list with `+`/`-`/`!` markers, `Apply this plan? [Y/n]` commit prompt. `--wizard-demo` runs wizard + preview together. **Dispatcher integration**: behind `FOX_INSTALL_STATE_DRIVEN=1` the main loop now runs `default_plan → run → preview → translate back to module_enabled`. Legacy flag-driven path is unchanged when the env-var is unset. |
| 6 Session C follow-up + Step 14 + state-checks expansion | 3 | `state::check_{arch_audit, vault, mac_random}` — three more modules graduate from FOX_MODULE to FOX_MODULE_FULL. `lockfile::acquire()` per-uid flock under `$XDG_RUNTIME_DIR` (Step 14 / R17) — two concurrent real installs report PID + exit 1; dry-runs and `--wizard-demo` are exempt. `wizard::apply_conflict_decisions(plan, ctx)` — KeepMine flips Conflict → Skip; BackupThenTakeNew copies the sentinel to `.foxml-bak`; TakeNew runs normally. Sentinels for render + mac_random are wired; others are recorded-but-unapplied. Phase 6 Session C is now end-to-end coherent. |
| 6 Sessions D + E (most of) — Steps 12, 13, 16, 17, 21 + 15/18 verified | 6 | Step 13 `--full` repair mode (promotes Conflict to BackupThenTakeNew, sets `ctx.assume_yes = true`, prints "Repair mode" section). Step 12 subprocess error absorption (`sh::set_stderr_log` + `sh::log_section` + `sh::tail_log`; per-run log at `$XDG_STATE_HOME/foxml/install-<ts>.log`; failed-module summary tails 20 lines from the log). Step 16 / R14 preflight `f_bsize` → `f_frsize` math fix. Step 17 / R15 install.sh `make -j$(nproc)` + timing line. Step 15 / R4a verified done by inspection (`modules/specials.cpp` already ports `install_specials`). Step 18 TTY fallback verified (`fox-install --wizard-demo < /dev/null` exits 0; state-driven dry-run with no stdin also clean). Step 21 CLAUDE.md updated with state-driven install path docs + state_check authoring guide. |

**Surface live:** `fox help` lists ai/sec/theme/dev/sys. 76 subcommands accessible as `fox <ns> <sub>`. Direct invocations (`fox-ai-doctor`, `fox-firewall`, etc.) still work unchanged. `fox-install --wizard-demo` walks the wizard + preview against the live registry. `FOX_INSTALL_STATE_DRIVEN=1 fox-install --dry-run` runs the state-driven install path end-to-end (verified with both `--full` repair-mode and `--only <slug>`). Two concurrent real installs are correctly serialized via the lockfile. Failed modules surface their stderr tail from `$XDG_STATE_HOME/foxml/install-<ts>.log`. install.sh builds in parallel and reports wall-clock time.

**Test suites (14, all green):** fox-install (registry 52 modules + state_manifest 25 assertions + classifier 14 assertions + state_checks 9 assertions + conflict_resolve 26 assertions + wizard 38 assertions + install_lock 11 assertions + subprocess_log 17 assertions), fox sanity, fox-ai sanity, fox-sec sanity, fox-theme sanity, fox-dev sanity, fox-sys sanity, fox-render, fox-vault.

## What's next — Phase 6 closing items + Phase 7

Phase 6 is functionally complete behind the `FOX_INSTALL_STATE_DRIVEN=1` env-var gate. The remaining three steps are all gated on the cutover decision:

**Step 19 — No-graphical-session mode.** Currently a *no-op* because no module in `modules.def` sets `requires_graphical=true` — most install-time work is writing config files, which works without a graphical session. Revisit if/when a module surfaces that genuinely needs Hyprland running at install time (e.g., a future module that calls `hyprctl` to apply settings live). The plumbing is already in place: `Module::requires_graphical` is in the registry and the wizard displays the flag; the wizard would just need to consult `$XDG_SESSION_TYPE` to gate Run/Skip.

**Step 20 — Cutover.** Flip the default from legacy flag-driven to state-driven by removing the `FOX_INSTALL_STATE_DRIVEN` env-var gate from `fox-install.cpp::main()`. **Hold off until the state-driven path has been used end-to-end on a real install at least once** (not just dry-runs). The risk of regressing the install path for everyone outweighs the tidiness win of removing the gate. Once cutover lands, the legacy inline-prompt block in main() can also be deleted, saving ~50 lines.

**Step 22 — Master plan close-out.** Update `plans/architecture-refactor.md` phase table to mark Phase 6 ✅ done. Trivial doc edit, do alongside Step 20.

**Other open work outside Phase 6:**
- **Phase 5** in the master plan: new `fox sys font` tool (Maple Mono + Monaspace alongside Hack). Still pending.
- **D18 audit**: which modules really should declare `requires_graphical=true`? Probably none, but worth a deliberate pass once a real graphical-session-dependent module ships.

**Manual verification paths available right now:**
- `./src/fox-install/fox-install --wizard-demo` — wizard + preview against live registry, no install.
- `FOX_INSTALL_STATE_DRIVEN=1 ./src/fox-install/fox-install --dry-run --yes` — full state-driven flow.
- `FOX_INSTALL_STATE_DRIVEN=1 ./src/fox-install/fox-install --dry-run --full` — repair mode.
- `FOX_INSTALL_STATE_DRIVEN=1 ./src/fox-install/fox-install --dry-run --only render` — interactive wizard against a small subset.
- `(./src/fox-install/fox-install --yes &) && ./src/fox-install/fox-install --yes` — second instance reports holding PID + exits 1.
- `cat $XDG_STATE_HOME/foxml/install-*.log` — per-run install log with section markers + captured child stderr.

**Already in place to draw from:**
- `wizard::{default_plan, run, preview, apply_conflict_decisions}` — full Plan lifecycle with file-IO side effects wired.
- `conflict::{prompt, apply, decision_name}` — atomic file-IO for diverged files.
- `state::check_{deps, render, etckeeper, arch_audit, vault, mac_random}` — six modules with real introspection; legacy entries default to Fresh.
- `lockfile::acquire()` — per-uid flock; second invocation reports holder PID + exits 1.
- `sh::{set_stderr_log, log_section, tail_log}` — per-run install log infrastructure (fox-common).
- `Module::requires_{root,graphical,network}` — read by the wizard's prereq display; not yet used for gating.

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
- **Caramel push-back pattern.** Caramel will often push past explicit "this is a good stopping point" recommendations to ship more. Recent cadence kept compounding: Session B 3 steps; Session C first half 2 steps; Session C second half 2 steps; round 4 added 3 (state-checks expansion + Step 14 + conflict bridge); round 5 closed out the rest of Sessions D + most of E (Steps 12, 13, 15-18, 21) for 6 commits. **Real install needed before Step 20 (cutover).** The state-driven path has been exercised only in dry-run + wizard-demo so far; the only path to confidence is a real install on this dev box (or a fresh VM) with the env-var set.

## Reference: session counts

- Long Session 1 (Phases 0-4 + Phase 6 Session A): 33 commits.
- Short Session 2 (Phase 6 Session B): 4 commits including doc.
- Session 3 (Phase 6 Session C, full): 7 commits including docs.
- Session 4 (state_checks expansion + Step 14 + conflict bridge + docs): 4 commits.
- Session 5 (Steps 12, 13, 15-18, 21 + docs): 7 commits — `1558254`, `0007236`, `0dc673f`, `75c592c`, `53218b0`, `0db6964`, plus this handoff update.
- **Cumulative**: ~55 commits past `c3b9b2f` (the pre-refactor tip). All commits atomic, per-step, reversible.
- Each phase has its own subplan in `plans/refactor/0N-<slice>.md`.
- Pattern is established: namespace dispatcher = `src/fox-X/{Makefile, main.cpp, dispatch.def, tests/dispatch_test.sh}`. Use `src/fox-ai/` as the canonical template.

## Start by

```bash
cd /home/caramel/code/Linux_Theme
git log --oneline c33e27c..HEAD     # see everything shipped
cat plans/architecture-refactor.md  # TOC at top, scan structure
cat plans/refactor/06-state-driven-installer.md  # Phase 6 detail
./src/fox-install/fox-install --wizard-demo                          # wizard + preview UI
FOX_INSTALL_STATE_DRIVEN=1 ./src/fox-install/fox-install --dry-run   # state-driven full flow
```

Then: do a real-install pass with `FOX_INSTALL_STATE_DRIVEN=1 ./install.sh` (or the same with `--full` for repair mode), confirm everything works, THEN run Step 20 (cutover) + Step 22 (master plan close-out). Phase 6 is otherwise done.
