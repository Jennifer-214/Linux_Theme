#include "wizard.hpp"

#include <utility>

namespace fox_install::wizard {

const char* action_name(Action a) {
    switch (a) {
        case Action::Skip:     return "skip";
        case Action::Run:      return "run";
        case Action::Conflict: return "conflict";
    }
    return "unknown";
}

Action default_action_for(state::Status status) {
    switch (status) {
        case state::Status::Fresh:    return Action::Run;
        case state::Status::Update:   return Action::Run;
        case state::Status::Noop:     return Action::Skip;
        case state::Status::Conflict: return Action::Conflict;
        case state::Status::Blocked:  return Action::Skip;
    }
    return Action::Skip;
}

Plan default_plan(
    const std::vector<const Module*>& modules,
    const Context& ctx,
    const state::Manifest& manifest
) {
    Plan p;
    p.modules.reserve(modules.size());
    for (const Module* m : modules) {
        ModulePlan mp{};
        mp.module = m;
        if (m->state_check) {
            mp.classification = m->state_check(ctx, manifest);
        } else {
            // Legacy FOX_MODULE entries: no introspection callback.
            // Until each one gets a check_X, the wizard treats them
            // as Fresh (run by default — current behavior).
            mp.classification = {state::Status::Fresh,
                                 "no state_check — assumed fresh"};
        }
        mp.action            = default_action_for(mp.classification.status);
        mp.conflict_decision = conflict::Decision::KeepMine;
        p.modules.push_back(std::move(mp));
    }
    return p;
}

// run() body lives in Step 9's commit. Until then this is a no-op
// passthrough so callers can wire the data flow now and visualize the
// interactive UI in the next step.
Plan run(Plan plan, const Context& /*ctx*/) {
    return plan;
}

}  // namespace fox_install::wizard
