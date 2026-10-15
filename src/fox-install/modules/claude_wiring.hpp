// modules/claude_wiring.hpp — Claude Code's hook wiring, two ways (2026-10-15, S10 / S10b):
//
//   merge_hook_entries — add the hooks a settings.json lacks, by command; never replace, remove or reorder. The
//     installer's own Claude notification hooks (specials.cpp) and Linux_Theme's project hooks both merge this way:
//     a JSON merge-patch REPLACES each hook list wholesale, erasing any hook she added herself.
//   restore_theme_wiring — Linux_Theme's own .claude/ (the per-session plan gate, the installer guard, the rg typo
//     guard, the settings.json that wires them, the skills link) from the private linux-theme-workspace. .claude/ is
//     git-ignored, so a fresh clone has none of it and a Claude session there would run without the installer guard.
#pragma once

#include "../core/context.hpp"
#include "../../fox-common/json.hpp"

#include <filesystem>
#include <string>
#include <vector>

namespace fox_install {

// Add every hook command in `wanted` (`{"hooks": {event: [{matcher, hooks: [{type, command}]}]}}`) that `settings`
// does not already run for that event: into the group with the same matcher when there is one, else a new group.
// Nothing is removed, replaced or reordered. → the number of commands added, or -1 (nothing changed) when
// `settings` holds a "hooks" that is not an object.
int merge_hook_entries(nlohmann::json& settings, const nlohmann::json& wanted);

// The installer's own Claude notification hooks into her user-level ~/.claude/settings.json (specials.cpp's
// do_claude_hooks): merged by command — a merge-patch replaced each hook list, so a hook she added herself to Stop,
// SubagentStop or Notification was erased by the next install — and the theme set to dark-ansi on every run, as
// before. → false when its "hooks" is not an object (they are then left exactly as they are; the theme is still set).
bool merge_user_settings(nlohmann::json& existing, const nlohmann::json& hooks);

struct WiringReport {
    std::vector<std::string> done;     // each change, one line
    std::vector<std::string> skipped;  // each thing left alone, and why
    std::string refused;               // non-empty: nothing was written, and this is why
};

// Restore <repo>/.claude from <workspace>:
//   .claude/skills          a link to <workspace>/claude-skills, made only when nothing is there;
//   .claude/hooks/<name>    a COPY of <workspace>/tools/hooks/<name> for each hook <workspace>/tools/hooks/settings.json
//                           wires — never a link, so editing the workspace never changes the live guard; a different
//                           one is backed up into the run's backup folder first (snapshot_one), and kept if that fails;
//   .claude/settings.json   the workspace's file when absent; when present, merged by command (merge_hook_entries).
// Refused when <repo> is a git checkout whose .claude/ is not ignored (private wiring never enters a public repo).
// .claude/.plan-approved and .claude/settings.local.json are never touched.
WiringReport restore_theme_wiring(const Context& ctx, const std::filesystem::path& repo,
                                  const std::filesystem::path& workspace);

}  // namespace fox_install
