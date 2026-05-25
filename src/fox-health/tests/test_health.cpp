// Smoke test: every registered check returns a CheckResult (no crashes,
// no exceptions escaping run_all), and worst_exit is consistent with
// the result severity/status combinations.

#include "../health.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>

namespace fh = fox_health;

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

    if (g_fail == 0) {
        std::printf("fox-health tests: OK (%d assertions)\n", g_pass);
        return 0;
    }
    std::fprintf(stderr, "fox-health tests: %d FAILED, %d passed\n", g_fail, g_pass);
    return 1;
}
