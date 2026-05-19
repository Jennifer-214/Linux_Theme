// conflict_resolve.hpp — interactive resolution for Status::Conflict modules.
//
// Phase 6 Step 7. The state classifier flags some modules as Conflict
// when both the deployed file and the source template have diverged
// from what was recorded in the install manifest, or when the live
// state is inconsistent with the manifest (untracked file, missing
// tracked file, …). This helper asks the user how to proceed.
//
// Session C replaces the prompt() function with an ftxui screen. The
// apply() function (pure file IO) survives that transition unchanged.

#pragma once

#include <filesystem>
#include <string>

namespace fox_install::conflict {

enum class Decision {
    KeepMine,           // leave the deployed file alone
    TakeNew,            // overwrite deployed with source
    BackupThenTakeNew,  // copy deployed → <name>.foxml-bak, then overwrite
};

// Prompt the user via ui::section + ui::ask_choice. Loops on the
// "view diff" branch (shells out to `diff -u`) until a non-diff
// option is picked. Returns the decision; the caller invokes apply()
// to act on it.
//
// Under assume_yes or no-TTY this returns Decision::KeepMine — the
// only safe default, since blindly overwriting a live-edited config
// is exactly what state-driven install is supposed to prevent.
Decision prompt(
    const std::string& slug,
    const std::filesystem::path& deployed,
    const std::filesystem::path& source,
    bool assume_yes
);

// Execute a Decision. Writes are atomic (tmp + rename) so a crash
// mid-copy can't leave the deployed file half-written. Returns true
// on success, false on IO failure (e.g. source missing, permission
// denied).
bool apply(
    Decision d,
    const std::filesystem::path& deployed,
    const std::filesystem::path& source
);

// Lowercase, hyphenated name of a Decision ("keep-mine", "take-new",
// "backup-then-take-new"). Used by tests + the install log.
const char* decision_name(Decision d);

}  // namespace fox_install::conflict
