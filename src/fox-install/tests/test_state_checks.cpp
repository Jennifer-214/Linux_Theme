// Tests for state_checks. Scope is intentionally limited to the
// empty-manifest paths: those return without invoking pacman /
// systemctl / filesystem lookups beyond a single fs::exists call,
// so they're safe and deterministic in any environment.
//
// The non-empty-manifest paths invoke external commands and are
// covered by integration testing, not here.

#include "../core/state_checks.hpp"
#include "../core/deps_list.hpp"
#include "../../fox-common/shell.hpp"

#include <algorithm>
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

    // T1b–e: deps over its whole list (installer audit 2026-10-15), from pacman -T's output as pacman 7.1 gives it.
    {
        auto all = state::deps_classification(0, "", 97);
        EXPECT(all.status == state::Status::Noop);
        auto two = state::deps_classification(127, "difftastic\ngit-absorb\n", 97);
        EXPECT(two.status == state::Status::Update);
        EXPECT(two.reason.find("2 of 97") != std::string::npos);
        EXPECT(two.reason.find("difftastic git-absorb") != std::string::npos);
        auto noexec = state::deps_classification(127, "", 97);   // pacman itself couldn't run
        EXPECT(noexec.status == state::Status::Update);
        EXPECT(noexec.reason.find("couldn't check") != std::string::npos);
        auto other = state::deps_classification(1, "", 97);
        EXPECT(other.status == state::Status::Update);
        // the query covers the whole list, not a few sentinels
        auto argv = state::deps_probe_argv();
        EXPECT(argv.size() == 2 + deps_packages().size());
        EXPECT(deps_packages().size() > 50);
        EXPECT(std::find(argv.begin(), argv.end(), "difftastic") != argv.end());
    }

    // T1f: sh::probe runs a read-only query even in a dry run, and returns the exit code with stdout;
    // sh::run, by contrast, only prints there and answers 0.
    {
        sh::set_dry_run(true);
        std::string out;
        EXPECT(sh::probe({"sh", "-c", "echo hi; exit 3"}, out) == 3);
        EXPECT(out == "hi\n");
        EXPECT(sh::probe({"/nonexistent/fox-probe-test"}, out) == 127);
        EXPECT(sh::run({"sh", "-c", "exit 3"}) == 0);
        sh::set_dry_run(false);
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

    // T6b–f: a stale rendered/ (templates or palette changed since its render) → Update, even though the deployed
    // sentinel still matches the manifest. --full used to keep render "up to date" here and symlinks then shipped a
    // months-old rendered/ over newer live configs (installer audit 2026-10-15, finding 3).
    {
        fs::path repo = tmp_cfg / "repo";
        fs::create_directories(repo / "templates" / "hypr");
        fs::create_directories(repo / "rendered");
        fs::create_directories(repo / "themes" / "Fox");
        std::ofstream(repo / "templates" / "hypr" / "hyprland.conf") << "bg = {{BG}}\n";
        std::ofstream(repo / "themes" / "Fox" / "palette.sh") << "BG=111111\n";
        fs::create_directories(tmp_cfg / "hypr");
        std::ofstream(tmp_cfg / "hypr" / "hyprland.conf") << "bg = 111111\n";
        Context c2 = ctx;
        c2.templates_dir = repo / "templates";
        c2.rendered_dir  = repo / "rendered";
        c2.palette_path  = repo / "themes" / "Fox" / "palette.sh";
        c2.theme_name    = "Fox";
        state::Manifest m;
        m.modules["render"] = {"v", state::hash_string("bg = 111111\n"), "ts"};

        // no stamp (a tree rendered before stamps existed) → stale
        EXPECT(state::check_render(c2, m).status == state::Status::Update);
        EXPECT(!state::rendered_is_current(c2));

        // stamped from today's inputs → Noop
        std::ofstream(state::render_stamp_path(c2)) << state::render_inputs_hash(c2) << '\n';
        EXPECT(state::rendered_is_current(c2));
        EXPECT(state::check_render(c2, m).status == state::Status::Noop);

        // a template edited since → stale
        std::ofstream(repo / "templates" / "hypr" / "hyprland.conf") << "bg = {{BG}}\ngaps = 4\n";
        EXPECT(state::check_render(c2, m).status == state::Status::Update);

        // a new template file → stale
        std::ofstream(repo / "templates" / "hypr" / "hyprland.conf") << "bg = {{BG}}\n";
        EXPECT(state::rendered_is_current(c2));
        std::ofstream(repo / "templates" / "waybar.css") << "x\n";
        EXPECT(!state::rendered_is_current(c2));
        fs::remove(repo / "templates" / "waybar.css");

        // the palette changed → stale; another theme → stale
        std::ofstream(repo / "themes" / "Fox" / "palette.sh") << "BG=222222\n";
        EXPECT(!state::rendered_is_current(c2));
        std::ofstream(repo / "themes" / "Fox" / "palette.sh") << "BG=111111\n";
        EXPECT(state::rendered_is_current(c2));
        c2.theme_name = "Other";
        EXPECT(!state::rendered_is_current(c2));
        fs::remove_all(tmp_cfg / "hypr");
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

    // T8: package_classify — the pure core of check_gaming / check_papirus_icons.
    // Exhaustive over (present × tracked); no pacman invoked.
    {
        // untracked + absent → Fresh ("hasn't run yet")
        EXPECT(state::package_classify(false, false, "gaming", "steam").status
               == state::Status::Fresh);
        // untracked + present → Noop ("already installed, treat as done")
        EXPECT(state::package_classify(true, false, "gaming", "steam").status
               == state::Status::Noop);
        // tracked + present → Noop ("installed")
        EXPECT(state::package_classify(true, true, "gaming", "steam").status
               == state::Status::Noop);
        // tracked + absent → Update ("missing, re-run") — the self-heal case
        // after `pacman -R steam`.
        EXPECT(state::package_classify(false, true, "gaming", "steam").status
               == state::Status::Update);
        // reason is always populated
        EXPECT(!state::package_classify(false, true, "gaming", "steam").reason.empty());
    }

    if (failures == 0) {
        std::cout << "state_checks tests: OK\n";
        return 0;
    }
    std::cerr << "state_checks tests: FAILED (" << failures << " failures)\n";
    return 1;
}
