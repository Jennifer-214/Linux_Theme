// modules/fox_moves.hpp — files the installer laid under the old fox names (2026-11), moved or removed so the new
// names take over: the Neovim modules, the drawer's config folder (its menus.json is yours and moves to the new
// folder), the pi extensions (pi loads every .ts in its folder, so an old copy beside the new one would load twice).
// Only files the installer itself put there are touched; anything else stays where it is. Pure (paths in, counts out)
// so tests/test_fox_moves pins it. Remove with the transition.
#pragma once

#include <filesystem>
#include <string>
#include <system_error>
#include <vector>

namespace desk_install {

inline constexpr const char* kOldFoxFolder = "foxml";   // old-fox-name
inline constexpr const char* kOldNvimModules[] = {"claude.lua", "review.lua", "sync.lua", "menu.lua", "work.lua",
                                                  "work_events.lua", "workspace.lua", "build.lua", "planmarks.lua"};
inline constexpr const char* kOldPiExtensions[] = {"fox-budget.ts", "fox-credits.ts", "fox-guard.ts",   // old-fox-name
                                                   "fox-notify.ts", "fox-scope.ts", "fox-trim.ts"};     // old-fox-name

struct FoxMoves { int moved = 0, removed = 0, left = 0; };

namespace fox_moves_detail {
namespace fs = std::filesystem;
// A file or link the installer laid there goes; a folder of that name (not ours) stays.
inline void remove_ours(const fs::path& file, bool dry_run, FoxMoves& n) {
    std::error_code ec;
    const auto status = fs::symlink_status(file, ec);
    if (ec || !fs::exists(status)) return;
    if (!fs::is_regular_file(status) && !fs::is_symlink(status)) { ++n.left; return; }
    if (!dry_run) fs::remove(file, ec);
    if (ec) { ++n.left; return; }
    ++n.removed;
}
inline void remove_if_empty(const fs::path& dir, bool dry_run) {
    std::error_code ec;
    if (!dry_run && fs::is_directory(fs::symlink_status(dir, ec)) && fs::is_empty(dir, ec)) fs::remove(dir, ec);
}
// What stays in a folder that is not removed: files that are not ours.
inline void count_left(const fs::path& dir, FoxMoves& n) {
    std::error_code ec;
    if (fs::is_directory(fs::symlink_status(dir, ec)))
        for (const auto& entry : fs::directory_iterator(dir, ec)) { (void)entry; ++n.left; }
}
}  // namespace fox_moves_detail

// home: $HOME; config: $XDG_CONFIG_HOME; drawer_files: the names the installer lays in the drawer's config folder.
inline FoxMoves move_from_fox(const std::filesystem::path& home, const std::filesystem::path& config,
                              const std::vector<std::string>& drawer_files, bool dry_run) {
    namespace fs = std::filesystem;
    using namespace fox_moves_detail;
    FoxMoves n;
    std::error_code ec;

    const auto nvim = config / "nvim/lua" / kOldFoxFolder;
    for (const char* name : kOldNvimModules) remove_ours(nvim / name, dry_run, n);
    remove_if_empty(nvim, dry_run);
    if (!dry_run) count_left(nvim, n);

    // The menu is yours: it moves to the new folder, unless one is already there (then both stay, the new one in use).
    const auto old_drawer = config / "quickshell" / kOldFoxFolder, new_drawer = config / "quickshell/desk";
    const auto menu = old_drawer / "menus.json";
    if (fs::is_regular_file(fs::symlink_status(menu, ec))) {
        const bool taken = fs::exists(fs::symlink_status(new_drawer / "menus.json", ec));
        ec.clear();   // "not found" above is the answer, not an error
        if (!taken) {
            if (!dry_run) { fs::create_directories(new_drawer, ec); if (!ec) fs::rename(menu, new_drawer / "menus.json", ec); }
            if (ec) ++n.left; else ++n.moved;
        } else ++n.left;
    }
    for (const auto& name : drawer_files) if (name != "menus.json") remove_ours(old_drawer / name, dry_run, n);
    remove_ours(old_drawer / "menus.default.json", dry_run, n);
    remove_if_empty(old_drawer, dry_run);
    if (!dry_run) count_left(old_drawer, n);

    const auto extensions = home / ".pi/agent/extensions";
    for (const char* name : kOldPiExtensions) remove_ours(extensions / name, dry_run, n);
    remove_ours(extensions / kOldFoxFolder / "build.ts", dry_run, n);
    remove_if_empty(extensions / kOldFoxFolder, dry_run);
    if (!dry_run) count_left(extensions / kOldFoxFolder, n);
    return n;
}

// Whether anything is still deployed under the old names: an integration-only update refuses until the installer
// has moved it (it cannot remove files without its own backups, and pi would load old and new extensions together).
inline bool fox_names_deployed(const std::filesystem::path& home, const std::filesystem::path& config) {
    namespace fs = std::filesystem;
    std::error_code ec;
    for (const auto& path : {config / "nvim/lua" / kOldFoxFolder / "review.lua", config / "quickshell" / kOldFoxFolder / "shell.qml",
                             home / ".pi/agent/extensions" / kOldPiExtensions[2]})
        if (fs::exists(fs::symlink_status(path, ec))) return true;
    return false;
}

}  // namespace desk_install
