// Tests for the three-hash classifier. Pure-function logic, so the
// tests are straightforward: enumerate every entry in the decision
// table and verify the right Status comes out.

#include "../core/classifier.hpp"

#include <cassert>
#include <iostream>
#include <string>

using namespace fox_install::state;

static int failures = 0;
#define EXPECT_STATUS(stored, deployed, source, expected) do { \
    Classification c = classify((stored), (deployed), (source)); \
    if (c.status != (expected)) { \
        std::cerr << "  FAIL: classify('" << (stored) << "','" << (deployed) << "','" \
                  << (source) << "') = " << status_name(c.status) \
                  << ", expected " << status_name(expected) \
                  << " (reason: " << c.reason << ") at line " << __LINE__ << "\n"; \
        ++failures; \
    } else { \
        std::cout << "  ok: " << status_name(expected) \
                  << " for stored='" << (stored).substr(0, 6) << "', deployed='" \
                  << (deployed).substr(0, 6) << "', source='" \
                  << (source).substr(0, 6) << "'\n"; \
    } \
} while (0)

int main() {
    std::cout << "test_classifier:\n";

    const std::string A = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111";
    const std::string B = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222";
    const std::string C = "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333";
    const std::string E = "";  // empty = "not present"

    // ───── Empty-input cases ─────
    EXPECT_STATUS(E, E, E, Status::Fresh);              // truly fresh
    EXPECT_STATUS(E, E, A, Status::Fresh);              // fresh, source exists
    EXPECT_STATUS(E, A, E, Status::Conflict);           // untracked file
    EXPECT_STATUS(E, A, A, Status::Conflict);           // untracked file (source matches)
    EXPECT_STATUS(A, E, E, Status::Conflict);           // tracked but file missing
    EXPECT_STATUS(A, E, A, Status::Conflict);           // tracked but file missing
    EXPECT_STATUS(A, E, B, Status::Conflict);           // tracked but file missing

    // ───── All-three-present cases (the four real classifications) ─────

    // Noop: everything matches
    EXPECT_STATUS(A, A, A, Status::Noop);

    // Update: deployed matches stored, source diverged
    EXPECT_STATUS(A, A, B, Status::Update);

    // Noop (user-customized): deployed diverged, source unchanged
    EXPECT_STATUS(A, B, A, Status::Noop);

    // Conflict: both deployed and source diverged from stored
    EXPECT_STATUS(A, B, C, Status::Conflict);

    // Edge: deployed and source happen to match each other but neither matches stored.
    // This is technically "Update" because the new source IS what's on disk —
    // BUT it could also mean the user happened to apply the same change manually.
    // Current classifier treats this as Conflict (both diverged from stored), which
    // is the safe answer. A future enhancement could detect deployed==source as
    // "Noop, already matching the new source" but the prompt-the-user behavior
    // is fine for now (user can choose 'take new' = no-op).
    EXPECT_STATUS(A, B, B, Status::Conflict);

    // ───── status_name returns the right string for each enum value ─────
    if (std::string(status_name(Status::Fresh))    != "fresh")    { std::cerr << "  FAIL: status_name Fresh\n"; ++failures; }
    if (std::string(status_name(Status::Noop))     != "noop")     { std::cerr << "  FAIL: status_name Noop\n"; ++failures; }
    if (std::string(status_name(Status::Update))   != "update")   { std::cerr << "  FAIL: status_name Update\n"; ++failures; }
    if (std::string(status_name(Status::Conflict)) != "conflict") { std::cerr << "  FAIL: status_name Conflict\n"; ++failures; }
    if (std::string(status_name(Status::Blocked))  != "blocked")  { std::cerr << "  FAIL: status_name Blocked\n"; ++failures; }
    std::cout << "  ok: status_name covers all enum values\n";

    // ───── Reason strings are non-empty for non-trivial cases ─────
    {
        Classification c = classify(A, B, C);
        if (c.reason.empty()) { std::cerr << "  FAIL: Conflict reason is empty\n"; ++failures; }
        else std::cout << "  ok: Conflict reason populated: '" << c.reason << "'\n";
    }

    if (failures == 0) {
        std::cout << "classifier tests: OK\n";
        return 0;
    }
    std::cerr << "classifier tests: FAILED (" << failures << " failures)\n";
    return 1;
}
