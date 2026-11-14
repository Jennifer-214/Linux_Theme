// modules/fox_moves.hpp — files the installer laid under the old fox names (2026-11), cleared once the new names are
// in place: the Neovim modules, the drawer's config folder (its menus.json is yours: it moves to the new folder), the
// pi extensions (pi loads every .ts in its folder, so an old copy beside the new one would load twice). Only files the
// installer itself put there are touched; anything else stays where it is, and a folder of the old name that is itself
// a link (dotfiles, a checkout) is left alone. Pure (paths in, counts out) so tests/test_fox_moves pins it. Remove with
// the transition.
#pragma once

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iterator>
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
inline bool linked(const fs::path& path) {
    std::error_code ec;
    return fs::is_symlink(fs::symlink_status(path, ec));
}
inline bool file_or_link(const fs::path& path) {
    std::error_code ec;
    const auto status = fs::symlink_status(path, ec);
    return !ec && (fs::is_regular_file(status) || fs::is_symlink(status));
}
// A file or link the installer laid there goes; anything else of that name (a folder) stays, counted.
inline void remove_ours(const fs::path& file, bool dry_run, FoxMoves& n) {
    std::error_code ec;
    if (!fs::exists(fs::symlink_status(file, ec))) return;
    if (!file_or_link(file)) { ++n.left; return; }
    if (!dry_run) fs::remove(file, ec);
    if (ec) { ++n.left; return; }
    ++n.removed;
}
inline void remove_if_empty(const fs::path& dir, bool dry_run) {
    std::error_code ec;
    if (!dry_run && fs::is_directory(fs::symlink_status(dir, ec)) && fs::is_empty(dir, ec)) fs::remove(dir, ec);
}
// What stays in a folder: backups and files of your own. The installer's own names are counted where they are handled.
inline void count_left(const fs::path& dir, const std::vector<std::string>& ours, FoxMoves& n) {
    std::error_code ec;
    if (!fs::is_directory(fs::symlink_status(dir, ec))) return;
    for (const auto& entry : fs::directory_iterator(dir, ec))
        if (std::find(ours.begin(), ours.end(), entry.path().filename().string()) == ours.end()) ++n.left;
}
// The same menu: two links to one place, or two files with the same text.
inline bool same_menu(const fs::path& a, const fs::path& b) {
    std::error_code ec;
    if (linked(a) || linked(b)) {
        if (!(linked(a) && linked(b))) return false;
        const auto ta = fs::read_symlink(a, ec);
        if (ec) return false;
        const auto tb = fs::read_symlink(b, ec);
        return !ec && ta == tb;
    }
    std::ifstream fa(a, std::ios::binary), fb(b, std::ios::binary);
    if (!fa || !fb) return false;
    const std::string sa{std::istreambuf_iterator<char>(fa), {}}, sb{std::istreambuf_iterator<char>(fb), {}};
    return sa == sb;
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
    const std::vector<std::string> modules(std::begin(kOldNvimModules), std::end(kOldNvimModules));
    if (linked(nvim)) ++n.left;
    else {
        for (const auto& name : modules) remove_ours(nvim / name, dry_run, n);
        remove_if_empty(nvim, dry_run);
        count_left(nvim, modules, n);
    }

    // The menu is yours. It moves to the new folder when none is there; once the drawer step has seeded the new one
    // from it (same text), the old copy goes; a different menu already there wins, and the old one stays (a link to
    // your own file stays too: the drawer step copied what it points at).
    const auto old_drawer = config / "quickshell" / kOldFoxFolder, new_drawer = config / "quickshell/desk";
    if (linked(old_drawer)) ++n.left;
    else {
        std::vector<std::string> ours;
        for (const auto& name : drawer_files) if (name != "menus.json") ours.push_back(name);
        ours.push_back("menus.default.json");
        const auto menu = old_drawer / "menus.json", new_menu = new_drawer / "menus.json";
        if (file_or_link(menu)) {
            const bool taken = fs::exists(fs::symlink_status(new_menu, ec));
            ec.clear();   // "not found" above is the answer, not an error
            if (!taken) {
                if (!dry_run) { fs::create_directories(new_drawer, ec); if (!ec) fs::rename(menu, new_menu, ec); }
                if (!ec) { ++n.moved; ours.push_back("menus.json"); }
            } else if (same_menu(menu, new_menu)) {
                remove_ours(menu, dry_run, n);
                ours.push_back("menus.json");
            }
        }
        for (const auto& name : ours) if (name != "menus.json") remove_ours(old_drawer / name, dry_run, n);
        remove_if_empty(old_drawer, dry_run);
        count_left(old_drawer, ours, n);
    }

    const auto extensions = home / ".pi/agent/extensions";
    for (const char* name : kOldPiExtensions) remove_ours(extensions / name, dry_run, n);
    const auto stamp = extensions / kOldFoxFolder;
    if (linked(stamp)) ++n.left;
    else {
        remove_ours(stamp / "build.ts", dry_run, n);
        remove_if_empty(stamp, dry_run);
        count_left(stamp, {"build.ts"}, n);
    }
    return n;
}

// Whether anything is still deployed under the old names: an integration-only update refuses until the installer
// has moved it (it cannot remove files without its own backups, and pi would load old and new extensions together).
// An old folder that is itself a link is yours and is left alone, so it holds nothing back.
inline bool fox_names_deployed(const std::filesystem::path& home, const std::filesystem::path& config) {
    using namespace fox_moves_detail;
    const auto nvim = config / "nvim/lua" / kOldFoxFolder, drawer = config / "quickshell" / kOldFoxFolder;
    return (!linked(nvim) && file_or_link(nvim / "review.lua")) || (!linked(drawer) && file_or_link(drawer / "shell.qml"))
        || file_or_link(home / ".pi/agent/extensions" / kOldPiExtensions[2]);
}

}  // namespace desk_install
