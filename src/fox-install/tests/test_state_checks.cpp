// Tests for state_checks. Scope is intentionally limited to the
// empty-manifest paths: those return without invoking pacman /
// systemctl / filesystem lookups beyond a single fs::exists call,
// so they're safe and deterministic in any environment.
//
// The non-empty-manifest paths invoke external commands and are
// covered by integration testing, not here.

#include "../core/state_checks.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace fox_install;

static int failures = 0;
#define EXPECT(cond) do { \
    if (!(cond)) { \
        std::cerr << "  FAIL: " #cond " at line " << __LINE__ << "\n"; \
        ++failures; \
    } else { \
        std::cout << "  ok: " #cond "\n"; \
    } \
} while (0)

int main() {
    std::cout << "test_state_checks:\n";

    // Common: an empty manifest + a Context whose config_home is a
    // freshly-made temp dir (so hyprland.conf can't possibly exist).
    state::Manifest empty;
    Context ctx;
    fs::path tmp_cfg = fs::temp_directory_path()
        / ("fox_install_state_checks_test_" + std::to_string(::getpid()));
    fs::remove_all(tmp_cfg);
    fs::create_directories(tmp_cfg);
    ctx.config_home = tmp_cfg;

    // T1: deps with no manifest entry → Fresh, no subprocess call.
    {
        auto cls = state::check_deps(ctx, empty);
        EXPECT(cls.status == state::Status::Fresh);
        EXPECT(!cls.reason.empty());
    }

    // T2: render with no manifest entry AND no deployed file → Fresh.
    {
        auto cls = state::check_render(ctx, empty);
        EXPECT(cls.status == state::Status::Fresh);
    }

    // T3: render with no manifest entry but a stray file on disk
    // → Conflict (unsafe to overwrite an untracked file).
    {
        fs::create_directories(tmp_cfg / "hypr");
        std::ofstream(tmp_cfg / "hypr" / "hyprland.conf") << "stray\n";
        auto cls = state::check_render(ctx, empty);
        EXPECT(cls.status == state::Status::Conflict);
    }

    // T4: render with manifest entry whose hash matches the deployed
    // file → Noop.
    {
        state::Manifest m;
        m.modules["render"] = {
            "5.10.x-test",
            state::hash_string("stray\n"),
            "2026-05-19T00:00:00Z",
        };
        auto cls = state::check_render(ctx, m);
        EXPECT(cls.status == state::Status::Noop);
    }

    // T5: render with manifest entry whose hash diverges from the
    // deployed file → Update.
    {
        state::Manifest m;
        m.modules["render"] = {
            "5.10.x-test",
            "deadbeef" + std::string(56, '0'),  // 64 hex chars
            "2026-05-19T00:00:00Z",
        };
        auto cls = state::check_render(ctx, m);
        EXPECT(cls.status == state::Status::Update);
    }

    // T6: render with manifest entry but file missing → Conflict.
    {
        fs::remove_all(tmp_cfg / "hypr");
        state::Manifest m;
        m.modules["render"] = {"v", "anything", "ts"};
        auto cls = state::check_render(ctx, m);
        EXPECT(cls.status == state::Status::Conflict);
    }

    // T7: etckeeper with no manifest entry → Fresh OR Blocked.
    // Blocked only fires if the running system reports the unit masked,
    // which is environment-dependent. Both outcomes are valid here;
    // anything else is a bug.
    {
        auto cls = state::check_etckeeper(ctx, empty);
        const bool ok = (cls.status == state::Status::Fresh
                      || cls.status == state::Status::Blocked);
        if (!ok) {
            std::cerr << "  FAIL: check_etckeeper returned "
                      << state::status_name(cls.status)
                      << " (reason: " << cls.reason << "), expected Fresh or Blocked\n";
            ++failures;
        } else {
            std::cout << "  ok: check_etckeeper returned "
                      << state::status_name(cls.status) << " (acceptable)\n";
        }
    }

    fs::remove_all(tmp_cfg);

    if (failures == 0) {
        std::cout << "state_checks tests: OK\n";
        return 0;
    }
    std::cerr << "state_checks tests: FAILED (" << failures << " failures)\n";
    return 1;
}
