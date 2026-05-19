// wizard.hpp — state-driven install configuration phase.
//
// Phase 6 Step 8 + 9 of plans/refactor/06-state-driven-installer.md.
// Step 8 builds the data types + the default-plan generator that drives
// the wizard. Step 9 adds the interactive run() function that lets the
// user edit the plan before commit.
//
// Flow:
//   default_plan(modules, ctx, manifest)   ← computes per-module Classification + default Action
//   run(plan, ctx)                          ← interactive UI; user toggles actions, hjkl navigates
//   apply(plan, ctx)                        ← later steps consume the final Plan
//
// No ftxui — pure printf + ANSI redraw + the same ui::ask_choice
// pattern conflict_resolve::prompt uses. Works in any TTY including
// the bare Linux console (TERM=linux).

#pragma once

#include "classifier.hpp"
#include "conflict_resolve.hpp"
#include "context.hpp"
#include "module.hpp"
#include "state_manifest.hpp"

#include <vector>

namespace fox_install::wizard {

// User-chosen disposition for one module.
//   Skip     — leave the module alone this run.
//   Run      — execute the module's run_X(ctx).
//   Conflict — execute, but route diverged files through conflict::apply
//              with conflict_decision (the user's choice for that file).
enum class Action { Skip, Run, Conflict };

// Lowercase name ("skip", "run", "conflict"). For logs + tests.
const char* action_name(Action a);

// Default Action for a Classification. The wizard starts every module
// at this value; the user toggles from there.
//   Fresh    → Run     (never deployed; deploy now)
//   Update   → Run     (source bumped, deployed copy clean — safe)
//   Noop     → Skip    (already current)
//   Conflict → Conflict (force user decision)
//   Blocked  → Skip    (prereq unmet — running would fail)
Action default_action_for(state::Status status);

// One module's contribution to the plan.
struct ModulePlan {
    const Module*         module;
    state::Classification classification;
    Action                action;
    // Only meaningful when action == Conflict. Mirrors the default
    // conflict_resolve::prompt picks under assume_yes / no-TTY: keep
    // the user's live edits unless they explicitly say otherwise.
    conflict::Decision    conflict_decision = conflict::Decision::KeepMine;
};

// Full plan — what the installer is about to do.
struct Plan {
    std::vector<ModulePlan> modules;
    bool                    aborted = false;  // user pressed q in the wizard
};

// Build a default Plan. Walks `modules`, calls each one's state_check
// (or treats it as Fresh if state_check is nullptr — legacy
// FOX_MODULE entries), wraps into a ModulePlan with the default
// Action. Pure function over its inputs — no IO beyond what the
// state_check callbacks themselves do.
Plan default_plan(
    const std::vector<const Module*>& modules,
    const Context& ctx,
    const state::Manifest& manifest
);

// Step 9 (interactive). Walks the user through `plan`, lets them
// toggle Run/Skip and pick conflict_decision values, returns the
// edited Plan. Under assume_yes or no-TTY returns `plan` unchanged.
Plan run(Plan plan, const Context& ctx);

// Step 10 — manifest preview. Prints the Plan as a per-module list
// with +/-/! markers (run / skip / conflict), then asks the user to
// commit via `ui::ask_yn`. Returns true on commit, false on decline.
// Under assume_yes or no-TTY returns true — the dispatcher proceeds
// with the plan as-configured, which is the safe default for
// non-interactive contexts (the wizard already returned a Plan with
// conservative defaults).
bool preview(const Plan& plan, const Context& ctx);

// Resolve each Action::Conflict ModulePlan into a Run or Skip per
// the user's conflict_decision. Called by the dispatcher BEFORE
// translating Plan → module_enabled[] so the right thing happens at
// the file-overwrite level:
//
//   KeepMine          — flipped to Action::Skip; the module doesn't
//                       run, so its run_X never gets a chance to
//                       overwrite the user-edited file.
//   TakeNew           — left as Conflict (treated as Run by the
//                       caller); the module's normal write proceeds.
//   BackupThenTakeNew — copies the sentinel file to .foxml-bak
//                       (best-effort; logs a warning on failure),
//                       then leaves the module as Conflict/Run.
//
// Sentinel paths come from a small per-slug lookup; modules without
// a known sentinel skip the resolve step entirely (their
// conflict_decision is recorded in the manifest but not yet applied
// — finer-grained per-file resolution is its own follow-up).
void apply_conflict_decisions(Plan& plan, const Context& ctx);

}  // namespace fox_install::wizard
