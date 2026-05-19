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

15. **R4a — Firefox install gap** ✅ *done* — `install_specials` is in fact fully ported as `modules/specials.cpp::run_specials`: Firefox CSS deploy + `user.js` legacy-stylesheet pref + graceful restart, Cursor/VS Code theme extension, Bat config + cache rebuild, Gemini deep-merge, Claude hooks merge, git-delta include, the hyprland-scripts/waybar-scripts/wallpapers/bin bulk deploys, regreet staging, btop theme. The `plans/native-migration-audit.md` row was stale — refreshed locally. Closed without a code change because the work was already done in a prior commit and just not crossed off.
16. **R14 — Preflight math fix** ✅ *done* — `get_disk_info` was multiplying `f_blocks * f_bsize` instead of `f_blocks * f_frsize`. On filesystems where `f_bsize ≠ f_frsize` (ext4 clusters, ZFS) the free-space numbers were wrong. Fixed; falls back to `f_bsize` when `f_frsize == 0` for old-kernel safety.
17. **R15 — Bootstrap compile feedback** ✅ *done* — install.sh now runs `make -j$(nproc) install` instead of serial + prints "built in Ns (J jobs)" when the build did real work. Avoids the dot-printer / set-e hazards from prior reverted attempts.
18. **TTY fallback path** (per D17) ✅ *verified* — `fox-install --wizard-demo < /dev/null` and `FOX_INSTALL_STATE_DRIVEN=1 fox-install --dry-run --yes --only render < /dev/null` both exit cleanly without trying to render the wizard. The wizard's `if (assume_yes || !ui::tty())` early-return handles non-interactive contexts.
19. **No-graphical-session mode** (skip Wayland-tagged modules with explanation per D18). Reads `Module::requires_graphical` (already in the registry as of Step 5) + `$XDG_SESSION_TYPE`. Open question: most install-time module work is just writing config files, which works without a graphical session — actually NO modules currently set `requires_graphical=true` in modules.def, so this step is currently a no-op. Revisit if/when a module surfaces that genuinely needs Hyprland running at install time (e.g., a future module that calls `hyprctl` to apply settings live).

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
- **Session C scope (shipped 2026-05-19):** Steps 8-11 — wizard data types + interactive ASCII wizard + manifest preview screen + state-driven dispatch gate behind `FOX_INSTALL_STATE_DRIVEN=1`. ftxui dropped in favour of pure printf/ANSI — see §"Wizard + execution". State-driven path is end-to-end usable.
- **Session C follow-up + Step 14 (shipped 2026-05-19):** Three additional state_checks (arch_audit, vault, mac_random), the install lockfile (Step 14 / R17), and the conflict_decision bridge — `wizard::apply_conflict_decisions` turns the user's wizard choice into actual file IO (KeepMine → Skip module; BackupThenTakeNew → write `.foxml-bak`; TakeNew → run normally). Session C is now end-to-end coherent.
- **Session D + Session E partial (shipped 2026-05-19):** Step 12 (subprocess error absorption — per-run install log at `$XDG_STATE_HOME/foxml/install-<ts>.log`, section markers per module, tail-on-failure surfacing), Step 13 (`--full` repair-mode semantics — promotes Conflict to BackupThenTakeNew, short-circuits wizard + preview, prints "Repair mode" header), Step 15 / R4a (verified already done — `install_specials` is `modules/specials.cpp`), Step 16 / R14 (preflight `f_bsize` → `f_frsize` math fix), Step 17 / R15 (parallel make + timing line in install.sh), Step 18 verified (TTY fallback works via existing `ui::tty()` guard).
- **Steps complete:** 18 / 22 — Steps 1-14, 15-18 done. Remaining: Step 19 (no-graphical-session, currently a no-op since no module sets `requires_graphical=true`; revisit when one does), Step 20 (cutover — flip default to state-driven), Step 21 (CLAUDE.md docs update), Step 22 (master plan close-out).
- **Slice complete:** *near complete — only doc/cutover work remains. State-driven path is full-featured and verified end-to-end.*
