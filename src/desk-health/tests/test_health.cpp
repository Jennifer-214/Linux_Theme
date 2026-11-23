// Smoke test: every registered check returns a CheckResult (no crashes,
// no exceptions escaping run_all), and worst_exit is consistent with
// the result severity/status combinations.

#include "../health.hpp"
#include "../checks.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace fh = desk_health;

static int g_pass = 0, g_fail = 0;
#define CHECK(cond, msg) do { \
        if (cond) { ++g_pass; } \
        else { ++g_fail; std::fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } \
    } while (0)

int main() {
    // The registry must be non-empty in any build of the library.
    const auto& reg = fh::all_checks();
    CHECK(!reg.empty(), "registry is non-empty");

    // Every entry must have id + title + a non-null fn.
    for (const auto& e : reg) {
        CHECK(e.id != nullptr && e.id[0] != '\0', "entry has non-empty id");
        CHECK(e.title != nullptr && e.title[0] != '\0', "entry has non-empty title");
        CHECK(e.fn != nullptr, "entry has non-null fn");
    }

    // run_all() with default options completes without throwing.
    auto results = fh::run_all({});
    CHECK(results.size() == reg.size(), "run_all returns one result per check");

    // Every result has a valid status and the id matches its registry entry.
    for (size_t i = 0; i < results.size(); ++i) {
        const auto& r = results[i];
        CHECK(r.id == reg[i].id, "result.id matches registry order");
        CHECK(r.status == fh::Status::Pass || r.status == fh::Status::Warn
              || r.status == fh::Status::Fail || r.status == fh::Status::Skip,
              "result.status is a known enum value");
    }

    // worst_exit policy: 0 if no fails, otherwise depends on severity.
    int exit_code = fh::worst_exit(results);
    CHECK(exit_code >= 0 && exit_code <= 3, "worst_exit in [0,3]");

    // --only filter restricts the run.
    fh::CheckOptions only_a;
    only_a.only = {"A1"};
    auto a1_only = fh::run_all(only_a);
    int actually_ran = 0;
    for (const auto& r : a1_only) {
        if (r.status != fh::Status::Skip) ++actually_ran;
    }
    CHECK(actually_ran <= 1, "--only A1 runs at most one check");

    // An ID filter names that check alone: --only A2 is not A21; a letter is still the whole category.
    fh::CheckOptions only_a2;
    only_a2.only = {"A2"};
    only_a2.include_slow = false;
    bool a21_ran = false, a2_ran = false;
    for (const auto& r : fh::run_all(only_a2)) {
        if (r.id == "A21") a21_ran = r.detail != "filtered out by --only";
        if (r.id == "A2")  a2_ran  = r.detail != "slow check disabled";
    }
    CHECK(!a21_ran && !a2_ran, "--only A2 --no-slow runs neither A2 (slow) nor A21");
    fh::CheckOptions only_cat;
    only_cat.only = {"A"};
    bool a21_in_cat = false;
    for (const auto& r : fh::run_all(only_cat)) if (r.id == "A21") a21_in_cat = r.detail != "filtered out by --only";
    CHECK(a21_in_cat, "--only A includes A21");
    fh::CheckOptions ex;
    ex.only = {"A", "B"};
    ex.exclude = {"A21"};
    bool a21_excluded = false, a2_kept = false;
    for (const auto& r : fh::run_all(ex)) {
        if (r.id == "A21") a21_excluded = r.detail == "filtered out by --exclude";
        if (r.id == "A2")  a2_kept = r.detail != "filtered out by --exclude";
    }
    CHECK(a21_excluded && a2_kept, "the pacman hook's --exclude A21 drops A21 only");

    // A3 kernel-currency verdict (pure). The known-good guarantee: a box whose
    // running kernel's module tree is pacman-owned (mainline OR lts/zen alike)
    // → PASS. That is exactly the case the old mainline-only version-compare
    // false-failed on an lts/zen-booted host. Integration (pacman -Qo + the
    // /usr/lib/modules lookup) is characterized against a real box: running
    // 7.0.12-arch1-1 owned by `linux` → owned=true → Pass.
    CHECK(fh::checks::a3_verdict(/*owned=*/true,  /*tree=*/true)  == fh::Status::Pass,
          "A3 owned → pass (mainline + lts/zen, no false-positive)");
    CHECK(fh::checks::a3_verdict(/*owned=*/false, /*tree=*/true)  == fh::Status::Skip,
          "A3 unowned-but-present → skip (custom kernel)");
    CHECK(fh::checks::a3_verdict(/*owned=*/false, /*tree=*/false) == fh::Status::Fail,
          "A3 module tree swept → fail (stale running kernel)");

    // A21 fallback kernel (pure). This machine's shape (linux + linux-lts, an entry for each) passes; one kernel, or
    // a second kernel nothing boots, warns; the recovery entry (another entry on vmlinuz-linux) is not a fallback.
    using V = std::vector<std::string>;
    CHECK(fh::checks::a21_verdict(V{"linux", "linux-lts"}, true, V{"linux", "linux-lts", "linux"}).status
              == fh::Status::Pass, "A21 two kernels, both with entries → pass");
    CHECK(fh::checks::a21_verdict(V{"linux"}, true, V{"linux"}).status == fh::Status::Warn,
          "A21 one kernel → warn");
    CHECK(fh::checks::a21_verdict(V{"linux", "linux-lts"}, true, V{"linux", "linux"}).status == fh::Status::Warn,
          "A21 second kernel without an entry → warn");
    CHECK(fh::checks::a21_verdict(V{"linux", "linux-lts"}, true, V{"linux", "linux"}).detail.find("linux-lts")
              != std::string::npos, "A21 names the kernel with no entry");
    CHECK(fh::checks::a21_verdict(V{"linux", "linux-zen"}, false, V{}).status == fh::Status::Pass,
          "A21 two kernels, entries unreadable (GRUB, ESP mask) → pass on packages");
    CHECK(fh::checks::a21_verdict(V{}, true, V{}).status == fh::Status::Skip, "A21 no pacman kernel → skip");

    // installed_kernels reads each module tree's pkgbase; trees without one (a swept old kernel) are not counted.
    {
        char tmpl[] = "/tmp/desk-health-kernels-XXXXXX";
        const std::string root = ::mkdtemp(tmpl) ? tmpl : "";
        CHECK(!root.empty(), "temp module root");
        auto tree = [&](const std::string& dir, const char* pkgbase) {
            std::filesystem::create_directories(root + "/" + dir);
            if (pkgbase) std::ofstream(root + "/" + dir + "/pkgbase") << pkgbase << "\n";
        };
        tree("7.3.5-arch1-1", "linux");
        tree("6.18.64-1-lts", "linux-lts");
        tree("7.3.4-arch1-1", nullptr);
        CHECK((fh::installed_kernels(root) == V{"linux", "linux-lts"}), "installed_kernels → linux, linux-lts");
        std::filesystem::remove_all(root);
    }

    if (g_fail == 0) {
        std::printf("desk-health tests: OK (%d assertions)\n", g_pass);
        return 0;
    }
    std::fprintf(stderr, "desk-health tests: %d FAILED, %d passed\n", g_fail, g_pass);
    return 1;
}
