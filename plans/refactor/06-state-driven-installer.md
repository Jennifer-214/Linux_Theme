# Slice 06: State-Driven Installer Rebuild

Implements Phase 6 of `plans/architecture-refactor.md`. The big one — turns fox-install from "run everything every time" into a state-aware installer per D11 + D17 + D18. This is the centerpiece of the refactor.

## Goal

After this slice ships:
- `~/.config/foxml/install-state.json` exists and tracks per-module state (version, hash, deployed_at).
- Each module declares prereqs (`requires_root`, `requires_graphical`, `requires_network`) + a `state_check` callback.
- `fox sys install` runs in three phases: **Config** (interactive wizard, h/l navigation per module) → **Manifest preview** (full plan, one y/n commit) → **Execute** (non-interactive, runs the manifest, errors absorbed).
- `fox sys install --full` becomes *repair mode*: verifies state, fixes drift, never overwrites user edits.
- ftxui TUI replaces the scrolling-prompt-soup. Single-step focus pane + log tail. ASCII fallback for TTY contexts per D17.
- Subprocess errors absorbed → reformatted in TUI + raw output to D14 log.
- All R1-R15 installer-related bugs addressed where in scope (Firefox install gap R4a, preflight math R14, bootstrap compile feedback R15, install lockfile R17).

## Scope reality check

**This is genuinely multi-session work.** The subplan covers the full slice but realistic per-session progress:

- **Session A** (tonight): Steps 1-3 (subplan + state manifest schema + serialization + tests). Foundation layer only.
- **Session B**: Steps 4-6 (state classification, module prereq declaration, three-way conflict diff).
- **Session C**: Steps 7-9 (ftxui TUI scaffolding, wizard config phase, execution view).
- **Session D**: Steps 10-12 (subprocess error absorption, repair mode semantics, install lockfile per R17).
- **Session E**: Steps 13-14 (R4a Firefox install gap, R14 preflight math fix, R15 compile feedback).

Each session ends at a shippable checkpoint. The installer keeps working at every commit boundary — the old fox-install behavior degrades gracefully even if the new state-driven path is only half-built (controlled by a `FOX_INSTALL_STATE_DRIVEN=1` env var until cutover).

## Step Inventory

### Foundation (Session A)

1. **State manifest schema + Read/Write** (`src/fox-install/core/state_manifest.{hpp,cpp}`)
   - Define `Module` + `Manifest` structs
   - JSON serialization (use existing fox-intel/json.hpp if available, or pull header)
   - Atomic write (tmp + rename per CLAUDE.md)
   - Unit tests: round-trip serialization, empty manifest, partial manifest
2. **Hash computation helper** (in same file)
   - `hash_file(path)` → returns SHA256 of file contents
   - `hash_command(cmd)` → returns hash of command output (for non-file modules)
   - Tests
3. **Manifest read/write integration** (no behavior change to fox-install yet)
   - On install start: read manifest if exists, log loaded state
   - On install end: write manifest with what happened
   - Doesn't affect classification or execution yet — just the data plumbing

### Classification & prereqs (Session B)

4. **Module state classification** (`src/fox-install/core/classifier.{hpp,cpp}`)
   - `enum class ModuleState { Noop, Update, Conflict, Fresh, Blocked }`
   - `classify(module, manifest)` → returns state + diagnostic
5. **Prereq declaration** (extend X-macro in `modules.def`)
   - `FOX_MODULE_FULL(name, fn, flag, desc, requires_root, requires_graphical, requires_network)`
   - Backward-compat shim: old `FOX_MODULE(...)` defaults all prereqs to false
6. **state_check callbacks** (one per module, gradually)
   - Start with 3-5 representative modules (deps, render, etckeeper as the most complex)
   - Each module gets a `check_X_state(ctx)` returning `ModuleState`
   - Modules without a callback default to "always Fresh" (current behavior)

### Conflict resolution (Session B)

7. **Three-hash diff helper**
   - `compare(deployed_hash, current_hash, source_hash)` → conflict classification
   - Interactive prompt UI (using fox-common/ui.hpp for now, ftxui in Session C)
   - Options: keep mine / take new / save .foxml-bak then take new / view diff

### Wizard + execution (Session C)

ftxui was the original plan but dropped 2026-05-19 after the bootstrap question — adding a new pacman dependency to the fresh-Arch install path is real risk for marginal UX gain, and the minimalist aesthetic (rofi+hjkl-style modals) doesn't actually want declarative components. The wizard uses pure printf + ANSI redraw + the existing `ui::ask_choice`/`ask_yn` primitives. D17 / D18 work in Session E shrinks correspondingly — no fallback path is needed because the only path is ASCII.

8. **Wizard data types + classification pass** (`core/wizard.{hpp,cpp}`)
   - `wizard::Action { Skip, Run, Conflict }`, `wizard::ModulePlan`, `wizard::Plan` structs.
   - `wizard::default_action_for(Status)` — the rule for "what would the wizard pick if the user just hit Enter through everything?".
   - `wizard::classify_all(modules, ctx, manifest)` — walks the registry, calls each module's `state_check` callback (or defaults to `Fresh` if `nullptr`), returns the pairs the wizard consumes.
   - Unit tests for the helpers. No interactive UI.
9. **Interactive ASCII wizard** (`wizard::run()`)
   - Pure printf + ANSI redraw. hjkl navigation; SPACE to toggle action; q to abort; Enter/l advances forward (with auto-advance once selection settled, per Caramel ask).
   - Conflict-module screen reuses `conflict_resolve::Decision` so the 4 options (keep-mine / take-new / backup-then-take-new / view-diff) stay consistent with the helper from Step 7.
   - Prereq indicators rendered read-only (root[✓] graphical[—] network[✓] style). Actual prereq-based gating is Session D — Step 9 just surfaces the flags.
   - No unit tests (interactive UI); verify by `fox-install --wizard` inspection.
10. **Manifest preview screen**
    - Aggregate the `wizard::Plan` into a scrollable text summary, one row per module showing slug + action + reason.
    - One `ui::ask_yn` to commit the plan.
11. **Execution phase + dispatcher integration**
    - Main loop in `fox-install.cpp` consumes a `Plan`, runs only modules whose action is `Run`, applies `conflict::apply` for conflict-decision modules, skips the rest.
    - Errors get queued (no mid-run prompts); final summary aggregates them per the existing fox-install end-of-install format.
    - Gated behind `FOX_INSTALL_STATE_DRIVEN=1` until Session E cutover.

### Polish & integration (Session D)

12. **Subprocess error absorption** (`src/fox-common/shell.hpp` extension)
    - `sh::run` returns `{exit_code, stdout, stderr, duration}` (already similar; extend if missing)
    - Wrap callers to route stderr to log + reformatted message to TUI
13. **Repair-mode semantics for `--full`**
    - Walk every registered module, run state_check, repair Blocked/Drifted
    - "Repair mode summary" output
14. **Install lockfile** (R17)
    - `flock(LOCK_EX)` on `/run/foxml-install.lock` or `~/.local/run/foxml-install.lock`
    - Second invocation: wait or fast-fail

### Bug fixes & finishing (Session E)

15. **R4a — Firefox install gap**: port `install_specials` from bash to `src/fox-install/modules/specials.cpp`
16. **R14 — Preflight math fix**: audit `preflight.cpp`, fix the boot-partition free-space calc
17. **R15 — Bootstrap compile feedback**: add progress echo to `install.sh` wrapper for the make stage
18. **TTY fallback path** (per D17) — *resolved implicitly* by the ftxui drop in Session C. The wizard already uses pure printf/ANSI, so non-TTY (pipe/redirect) callers hit the same `ui::tty()` guard that `ask_choice`/`ask_yn` already honor. Keep this item open until the Step 11 gate is verified against `fox-install < /dev/null`.
19. **No-graphical-session mode** (skip Wayland-tagged modules with explanation per D18). Reads `Module::requires_graphical` (already in the registry as of Step 5) + `$XDG_SESSION_TYPE`.

### Final (Session E)

20. **Cutover** — flip default to state-driven path (remove env var gate)
21. **Update CLAUDE.md** (install.sh now ≤30 lines, fox-install is state-driven, etc.)
22. **Update plan**: mark Phase 6 complete, R4a/R14/R15/R17 closed

## Exit Criteria (full slice)

- [ ] `fox sys install` works end-to-end (config → preview → execute → summary)
- [ ] `fox sys install --full` runs in repair mode (no spurious prompts, fixes detected drift)
- [ ] Re-running `fox sys install` after a clean install is a near-noop (state manifest accurately reflects what's done)
- [ ] Hand-edited config files are NEVER silently overwritten (conflict prompt shows in every case)
- [ ] TTY install works (D17 fallback path)
- [ ] No-graphical-session install works (D18 deferred-module path)
- [ ] R4a, R14, R15, R17 closed
- [ ] CLAUDE.md updated
- [ ] All existing tests pass + new state-machine tests pass

## Tonight's checkpoint (Session A only)

- [ ] Subplan committed (THIS commit)
- [ ] Step 1: state_manifest.{hpp,cpp} written + tests pass
- [ ] Step 2: hash helpers written + tests pass
- [ ] Step 3: manifest read/write wired into fox-install start/end (still no classification yet)
- [ ] Commit per step
- [ ] No regression in existing fox-install behavior — current install path still works identically (because new state code is read/write-only at this stage; classification + state-driven dispatch is Session B+)

## Risks

| Risk | Mitigation |
| --- | --- |
| **Half-built state code breaks current install path** | All Session A changes are additive — read manifest if present, write manifest after — but classification doesn't gate any execution yet. Old behavior preserved. |
| **Hash function choice locks us in early** | Use SHA256 (standard, in libcrypto). Trivial to swap later if needed; hash field in manifest is just a string. |
| **JSON dependency creep** | Use the json.hpp already vendored in fox-intel/ — no new deps. |
| **Atomicity of manifest writes** | Per CLAUDE.md: tmp + rename. Standard pattern. Mitigation = follow the pattern, test the round-trip. |
| **Going too fast tonight** | Hard cap at end of Session A scope. If I hit Step 3 and quality is degrading, I stop and we resume tomorrow. |
| **New dependency on bootstrap path (ftxui)** | Dropped. The wizard uses pure printf/ANSI + existing `ui::ask_choice`/`ask_yn` primitives. No new pacman package required to build fox-install on a fresh Arch ISO. Decision logged 2026-05-19 after the TTY-bootstrap question. |

## Status

- **Subplan authored:** 2026-05-19
- **Session A scope (shipped 2026-05-19):** Steps 1-4 (state manifest schema/IO + SHA256 helpers + integration + classifier). Step 4 was an overflow from the Session A plan — landed cleanly.
- **Session B scope (shipped 2026-05-19):** Steps 5-7 (FOX_MODULE_FULL prereq + state_check fields; `state_checks::check_{deps,render,etckeeper}`; `conflict_resolve::{prompt,apply,Decision}`). All additive — no dispatcher wiring yet.
- **Session C scope (first half shipped 2026-05-19):** Steps 8-9 (wizard data types + interactive ASCII wizard + `--wizard-demo` flag). Steps 10-11 deferred to next session. ftxui dropped in favour of pure printf/ANSI — see §"Wizard + execution".
- **Steps complete:** 9 / 22
- **Slice complete:** *pending — next session picks up at Step 10 (manifest preview screen)*
