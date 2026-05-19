# Handoff — Architecture Refactor, Phase 6 ✅ closed

Resume point for the next session of the FoxML workstation architecture refactor. **Phase 6 is done.** Cutover landed 2026-05-19 (commit `3598930`); the state-driven install path (wizard + preview + manifest + per-run log) is now the default, with `FOX_INSTALL_LEGACY=1` as the escape hatch. 21 of 22 steps shipped; Step 19 (no-graphical-session gate) is deferred because no module currently declares `requires_graphical=true`.

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
| Polish round — 5 more state_checks + 2 bug fixes | 3 | `state::check_{ufw, endlessh, greetd, papirus_icons, catppuccin_cursor}` — wizard accuracy now covers 11 of 52 modules (was 6). Extracted `unit_check`/`package_check` helpers. **Fixed `source_hash` regression**: dispatcher used to stamp `""` for every module, which meant hash-based state_checks classified every subsequent install as Conflict. Now hashes the sentinel post-run via `wizard::conflict_sentinel` (promoted from anonymous namespace to a public function in wizard.hpp). **Wired `--resume` + `--phase`**: both were parsed but never read in main(). --resume reads `~/.local/share/foxml/install_state`; --phase looks up the slug and sets `ctx.resume_idx`; unknown slug → exit 2. |

**Surface live:** `fox help` lists ai/sec/theme/dev/sys. 76 subcommands accessible as `fox <ns> <sub>`. Direct invocations (`fox-ai-doctor`, `fox-firewall`, etc.) still work unchanged. `fox-install --wizard-demo` walks the wizard + preview against the live registry. `FOX_INSTALL_STATE_DRIVEN=1 fox-install --dry-run` runs the state-driven install path end-to-end (verified with both `--full` repair-mode and `--only <slug>`). Two concurrent real installs are correctly serialized via the lockfile. Failed modules surface their stderr tail from `$XDG_STATE_HOME/foxml/install-<ts>.log`. install.sh builds in parallel and reports wall-clock time.

**Test suites (14, all green):** fox-install (registry 52 modules + state_manifest 25 assertions + classifier 14 assertions + state_checks 9 assertions + conflict_resolve 26 assertions + wizard 38 assertions + install_lock 11 assertions + subprocess_log 17 assertions), fox sanity, fox-ai sanity, fox-sec sanity, fox-theme sanity, fox-dev sanity, fox-sys sanity, fox-render, fox-vault.

**state_check coverage (11/52 modules):** `deps`, `render`, `etckeeper`, `arch_audit`, `vault`, `mac_random`, `ufw`, `endlessh`, `greetd`, `papirus_icons`, `catppuccin_cursor`. Legacy `FOX_MODULE` entries default to `Status::Fresh` and run unconditionally — adding more state_checks is incremental and the pattern is documented in CLAUDE.md.

## What's next — post-Phase-6

Three natural follow-ups, no particular ordering:

**(a) Real-install pass.** The state-driven path has end-to-end dry-run miles but hasn't been used for a real install yet. A `./install.sh` run from a fresh checkout (or a fresh VM) is the only thing that exercises actual pacman / systemctl / sudo side effects and catches anything `--dry-run` can't. After it passes, the legacy code path can be deleted (currently kept as the `FOX_INSTALL_LEGACY=1` escape hatch); that's a ~50-line deletion in `fox-install.cpp` plus the `!state_driven` guards.

**(b) Step 19 follow-up (no-graphical-session gate).** Currently a no-op since no module in `modules.def` declares `requires_graphical=true`. Revisit if/when a module surfaces that genuinely needs Hyprland live at install time (e.g., a `hyprctl reload` step). Plumbing is in place: read `$XDG_SESSION_TYPE`, gate `parsed.module_enabled[i] = false` for graphical-required modules under a TTY session.

**(c) Phase 5 — new `fox sys font` tool.** Maple Mono + Monaspace alongside Hack. Subplan at `plans/refactor/05-font-tool.md`. Independent of Phase 6 — this is its own slice with its own design call.

**Incremental quality wins** (no slice required):
- More `state_check` callbacks. Coverage is 14 / 52 modules; the remaining 38 are mostly small system-config touches that re-run rarely, so marginal value drops. Pattern documented in CLAUDE.md.
- More entries in `wizard::conflict_sentinel` if future state_checks produce Conflict status involving files.

**Manual verification paths available right now:**
- `./src/fox-install/fox-install --wizard-demo` — wizard + preview against live registry, no install.
- `./src/fox-install/fox-install --dry-run --yes` — full state-driven flow (default path now).
- `./src/fox-install/fox-install --dry-run --full` — repair mode.
- `FOX_INSTALL_LEGACY=1 ./src/fox-install/fox-install --dry-run --yes --only render` — escape hatch (legacy path).
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
- **Caramel push-back pattern.** Recent cadence kept compounding: Session B 3 steps; Session C first half 2 steps; Session C second half 2 steps; polish round added 3 (state-checks expansion + Step 14 + conflict bridge); the next round closed out the rest of Sessions D + most of E (Steps 12, 13, 15-18, 21) for 6 commits; the final round shipped the cutover + Step 22 close-out. **Phase 6 is closed without real-install miles** — at Caramel's explicit "finish this off" request, the cutover landed with the legacy code path retained as an escape hatch (`FOX_INSTALL_LEGACY=1`). Mitigation: if anything regresses, drop into legacy mode and file a bug. The legacy code-path deletion is held back as a separate commit until real-install passes confirm no regressions.

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
./src/fox-install/fox-install --wizard-demo                          # wizard + preview UI
./src/fox-install/fox-install --dry-run --yes                        # full state-driven dry-run
```

Then pick a follow-up from §"What's next" — real-install pass, Phase 5 (`fox sys font`), or adding state_checks for more modules. None is blocking; Phase 6 is closed.
