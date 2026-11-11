// classifier.hpp — three-hash module state classifier.
//
// Phase 6 Step 4 of plans/refactor/06-state-driven-installer.md.
//
// Given three hashes (stored in manifest, currently deployed on disk,
// new source from template), classify each module's state for the
// install plan. This is pure function logic — no IO, no side effects —
// so it's easy to unit-test and easy for the wizard UI (Session C) to
// consume.

#pragma once

#include <string>

namespace fox_install::state {

// The state-transition the installer needs to apply for one module.
enum class Status {
    Fresh,     // Never deployed (not in manifest, no deployed file).
    Noop,      // Already current — no action needed.
    Update,    // Source has changed; deployed copy is unmodified → safe overwrite.
    Conflict,  // Both source AND deployed copy have changed → user decision needed.
    Blocked,   // Module prereq not met (e.g., masked unit) → can't even try.
};

struct Classification {
    Status      status;
    std::string reason;  // Short human-readable explanation, especially useful for Conflict + Blocked.
};

// String name for a Status, lowercase ("fresh", "noop", "update", "conflict", "blocked").
// Used by the JSON manifest, the wizard UI, and the logs.
const char* status_name(Status s);

// Three-hash classifier.
//
// Inputs (all hex SHA256, empty string = "not present"):
//   stored_hash    — what's recorded in the manifest from the prior install
//   deployed_hash  — what's on disk right now
//   source_hash    — what the source template would produce now
//
// Decision table:
//
//   stored | deployed | source | result        meaning
//   -------+----------+--------+-----------------------------------------
//   ""     | ""       | any    | Fresh         — never deployed
//   ""     | non-""   | any    | Conflict      — file exists but not tracked
//   non-"" | ""       | any    | Conflict      — tracked but file gone (manual delete?)
//   = stored = source  →        | Noop          — already current
//   = stored, source ≠ stored  →| Update        — clean source bump
//   ≠ stored, source = stored  →| Noop          — user customized; source unchanged
//   ≠ stored, source ≠ stored  →| Conflict      — both changed; 3-way merge
//
// Note: this function does NOT classify Blocked — that requires prereq
// checks (network/root/graphical) which live in module state_check
// callbacks (Session B Step 6). The classifier handles only the
// hash-based dimension; a separate composition step combines Blocked
// from prereq failures with the hash-based result.
Classification classify(
    const std::string& stored_hash,
    const std::string& deployed_hash,
    const std::string& source_hash
);

}  // namespace fox_install::state
