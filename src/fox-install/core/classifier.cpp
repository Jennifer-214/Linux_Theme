#include "classifier.hpp"

namespace fox_install::state {

const char* status_name(Status s) {
    switch (s) {
        case Status::Fresh:    return "fresh";
        case Status::Noop:     return "noop";
        case Status::Update:   return "update";
        case Status::Conflict: return "conflict";
        case Status::Blocked:  return "blocked";
    }
    return "unknown";  // unreachable, silences -Wreturn-type
}

Classification classify(
    const std::string& stored,
    const std::string& deployed,
    const std::string& source
) {
    const bool has_stored   = !stored.empty();
    const bool has_deployed = !deployed.empty();

    // Case 1: nothing tracked, nothing on disk → first-ever deployment.
    if (!has_stored && !has_deployed) {
        return {Status::Fresh, "never deployed"};
    }

    // Case 2: not tracked but file on disk → suspicious. Could be a
    // leftover from a manual edit, an old install before we tracked
    // state, or a name collision. Surface as a conflict so the user
    // decides — never silently overwrite.
    if (!has_stored && has_deployed) {
        return {Status::Conflict, "file exists on disk but not tracked in manifest"};
    }

    // Case 3: tracked but file is gone → user (or something) deleted the
    // deployed file. Re-deploying without asking would overwrite an
    // intentional removal, so flag as conflict.
    if (has_stored && !has_deployed) {
        return {Status::Conflict, "deployed file missing (was tracked at " + stored + ")"};
    }

    // All three present (or stored+deployed, with empty source meaning
    // "no source change to consider"). Now compare.
    const bool deployed_matches_stored = (deployed == stored);
    const bool source_matches_stored   = (source == stored);

    if (deployed_matches_stored && source_matches_stored) {
        return {Status::Noop, "already current"};
    }

    if (deployed_matches_stored && !source_matches_stored) {
        return {Status::Update, "source updated; deployed copy unchanged → safe overwrite"};
    }

    if (!deployed_matches_stored && source_matches_stored) {
        // User customized the deployed file; source hasn't changed
        // since last install. Don't touch — respecting user edits.
        return {Status::Noop, "user customized; source unchanged"};
    }

    // Both deployed and source differ from stored → real conflict.
    return {Status::Conflict, "both deployed and source diverged from last install"};
}

}  // namespace fox_install::state
