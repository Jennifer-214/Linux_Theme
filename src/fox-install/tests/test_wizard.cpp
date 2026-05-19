// Tests for wizard data types + default_plan. The interactive run()
// function is Step 9 work and not unit-testable from a non-TTY test
// runner; that's verified by inspection during the next session.

#include "../core/wizard.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace fox_install;
using namespace fox_install::wizard;

static int failures = 0;
#define EXPECT(cond) do { \
    if (!(cond)) { \
        std::cerr << "  FAIL: " #cond " at line " << __LINE__ << "\n"; \
        ++failures; \
    } else { \
        std::cout << "  ok: " #cond "\n"; \
    } \
} while (0)

namespace {

void run_stub(Context&) {}

state::Classification check_fresh   (const Context&, const state::Manifest&) { return {state::Status::Fresh,    "stub fresh"}; }
state::Classification check_noop    (const Context&, const state::Manifest&) { return {state::Status::Noop,     "stub noop"}; }
state::Classification check_update  (const Context&, const state::Manifest&) { return {state::Status::Update,   "stub update"}; }
state::Classification check_conflict(const Context&, const state::Manifest&) { return {state::Status::Conflict, "stub conflict"}; }
state::Classification check_blocked (const Context&, const state::Manifest&) { return {state::Status::Blocked,  "stub blocked"}; }

Module make_module(const char* slug, StateCheckFn sc) {
    return Module{
        slug, &run_stub, "--stub", "stub module", false,
        false, false, false,
        sc,
    };
}

}  // namespace

int main() {
    std::cout << "test_wizard:\n";

    // action_name covers every enum value.
    EXPECT(std::string(action_name(Action::Skip))     == "skip");
    EXPECT(std::string(action_name(Action::Run))      == "run");
    EXPECT(std::string(action_name(Action::Conflict)) == "conflict");

    // default_action_for covers every Status.
    EXPECT(default_action_for(state::Status::Fresh)    == Action::Run);
    EXPECT(default_action_for(state::Status::Update)   == Action::Run);
    EXPECT(default_action_for(state::Status::Noop)     == Action::Skip);
    EXPECT(default_action_for(state::Status::Conflict) == Action::Conflict);
    EXPECT(default_action_for(state::Status::Blocked)  == Action::Skip);

    // default_plan: empty input → empty Plan, not aborted.
    {
        Context ctx;
        state::Manifest m;
        Plan p = default_plan({}, ctx, m);
        EXPECT(p.modules.empty());
        EXPECT(!p.aborted);
    }

    // default_plan: mixed modules → each gets the right Action.
    {
        Context ctx;
        state::Manifest manifest;

        Module mods[] = {
            make_module("a_fresh",    &check_fresh),
            make_module("b_noop",     &check_noop),
            make_module("c_update",   &check_update),
            make_module("d_conflict", &check_conflict),
            make_module("e_blocked",  &check_blocked),
            make_module("f_legacy",   nullptr),   // no state_check
        };
        std::vector<const Module*> ptrs;
        for (auto& m : mods) ptrs.push_back(&m);

        Plan p = default_plan(ptrs, ctx, manifest);
        EXPECT(p.modules.size() == 6);

        EXPECT(p.modules[0].classification.status == state::Status::Fresh);
        EXPECT(p.modules[0].action == Action::Run);

        EXPECT(p.modules[1].classification.status == state::Status::Noop);
        EXPECT(p.modules[1].action == Action::Skip);

        EXPECT(p.modules[2].classification.status == state::Status::Update);
        EXPECT(p.modules[2].action == Action::Run);

        EXPECT(p.modules[3].classification.status == state::Status::Conflict);
        EXPECT(p.modules[3].action == Action::Conflict);
        EXPECT(p.modules[3].conflict_decision == conflict::Decision::KeepMine);

        EXPECT(p.modules[4].classification.status == state::Status::Blocked);
        EXPECT(p.modules[4].action == Action::Skip);

        // Legacy entry: nullptr state_check → defaults to Fresh + Run.
        EXPECT(p.modules[5].classification.status == state::Status::Fresh);
        EXPECT(p.modules[5].action == Action::Run);
        EXPECT(p.modules[5].classification.reason.find("no state_check") != std::string::npos);
    }

    // run() honors the assume_yes / non-TTY short-circuit: returns the
    // input plan unchanged without touching termios or rendering. The
    // contract that "this is safe to call from any context" is what
    // lets the dispatcher invoke it unconditionally.
    {
        Plan p;
        Context ctx;
        Plan q = run(p, ctx);
        EXPECT(q.modules.empty());
        EXPECT(!q.aborted);
    }
    {
        // Non-empty plan with assume_yes set: defaults preserved.
        Context ctx;
        ctx.assume_yes = true;
        state::Manifest manifest;
        Module mods[] = {
            make_module("a_fresh",   &check_fresh),
            make_module("b_noop",    &check_noop),
            make_module("c_blocked", &check_blocked),
        };
        std::vector<const Module*> ptrs;
        for (auto& m : mods) ptrs.push_back(&m);
        Plan p = run(default_plan(ptrs, ctx, manifest), ctx);
        EXPECT(p.modules.size() == 3);
        EXPECT(!p.aborted);
        EXPECT(p.modules[0].action == Action::Run);
        EXPECT(p.modules[1].action == Action::Skip);
        EXPECT(p.modules[2].action == Action::Skip);
    }

    // preview() — under assume_yes / no-TTY it must return true so the
    // dispatcher runs the plan as configured rather than stalling on
    // a y/n prompt that no one's there to answer.
    {
        Plan p;
        Context ctx;
        // No TTY in the test runner → ask_yn returns default_yes=true.
        EXPECT(preview(p, ctx) == true);
    }
    {
        Context ctx;
        ctx.assume_yes = true;
        state::Manifest manifest;
        Module mods[] = {
            make_module("a_fresh",    &check_fresh),
            make_module("b_noop",     &check_noop),
            make_module("c_conflict", &check_conflict),
        };
        std::vector<const Module*> ptrs;
        for (auto& m : mods) ptrs.push_back(&m);
        Plan p = default_plan(ptrs, ctx, manifest);
        // Sanity: the plan is what we expect before preview.
        EXPECT(p.modules.size() == 3);
        EXPECT(p.modules[0].action == Action::Run);
        EXPECT(p.modules[1].action == Action::Skip);
        EXPECT(p.modules[2].action == Action::Conflict);
        // preview proceeds non-interactively → true.
        EXPECT(preview(p, ctx) == true);
    }

    // apply_conflict_decisions — KeepMine flips Conflict to Skip,
    // BackupThenTakeNew writes a .foxml-bak (when there's a real
    // file to back up), TakeNew is a no-op. Sentinel-less modules
    // are left as Conflict for the dispatcher to treat as Run.
    {
        Plan p;
        Context ctx;
        fs::path tmp_cfg = fs::temp_directory_path()
            / ("fox_wizard_conflict_test_" + std::to_string(::getpid()));
        fs::remove_all(tmp_cfg);
        fs::create_directories(tmp_cfg / "hypr");
        std::ofstream(tmp_cfg / "hypr" / "hyprland.conf") << "user-edited\n";
        ctx.config_home = tmp_cfg;

        // We can't reach the real Module table from this test, so we
        // synthesise a few ModulePlans with slug pointers into a tiny
        // local Module fixture (the only field apply_conflict_decisions
        // reads off the Module is slug).
        Module m_render_keep   {"render",   &run_stub, "--render",   "stub", false, false, false, false, &check_conflict};
        Module m_render_take   {"render",   &run_stub, "--render",   "stub", false, false, false, false, &check_conflict};
        Module m_render_backup {"render",   &run_stub, "--render",   "stub", false, false, false, false, &check_conflict};
        Module m_unknown       {"my_module",&run_stub, "--my",       "stub", false, false, false, false, &check_conflict};

        ModulePlan mp_keep{&m_render_keep,     {state::Status::Conflict, "test"}, Action::Conflict, conflict::Decision::KeepMine};
        ModulePlan mp_take{&m_render_take,     {state::Status::Conflict, "test"}, Action::Conflict, conflict::Decision::TakeNew};
        ModulePlan mp_back{&m_render_backup,   {state::Status::Conflict, "test"}, Action::Conflict, conflict::Decision::BackupThenTakeNew};
        ModulePlan mp_unk {&m_unknown,         {state::Status::Conflict, "test"}, Action::Conflict, conflict::Decision::KeepMine};

        p.modules = {mp_keep, mp_take, mp_back, mp_unk};
        apply_conflict_decisions(p, ctx);

        // KeepMine on a known sentinel → Action::Skip.
        EXPECT(p.modules[0].action == Action::Skip);
        // TakeNew → unchanged Action::Conflict.
        EXPECT(p.modules[1].action == Action::Conflict);
        // BackupThenTakeNew → unchanged Action::Conflict, but a
        // .foxml-bak now exists alongside the sentinel.
        EXPECT(p.modules[2].action == Action::Conflict);
        EXPECT(fs::exists(tmp_cfg / "hypr" / "hyprland.conf.foxml-bak"));
        {
            std::ifstream bak(tmp_cfg / "hypr" / "hyprland.conf.foxml-bak");
            std::string contents((std::istreambuf_iterator<char>(bak)),
                                  std::istreambuf_iterator<char>());
            EXPECT(contents == "user-edited\n");
        }
        // Unknown slug — left as Conflict (no sentinel to act on).
        EXPECT(p.modules[3].action == Action::Conflict);

        fs::remove_all(tmp_cfg);
    }

    if (failures == 0) {
        std::cout << "wizard tests: OK\n";
        return 0;
    }
    std::cerr << "wizard tests: FAILED (" << failures << " failures)\n";
    return 1;
}
