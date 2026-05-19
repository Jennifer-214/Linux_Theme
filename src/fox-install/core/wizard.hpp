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
//
// Implementation is in Step 9's commit — declared here so the API
// is stable and tests can mock around it.
Plan run(Plan plan, const Context& ctx);

}  // namespace fox_install::wizard
