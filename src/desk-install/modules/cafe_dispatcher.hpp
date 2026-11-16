// modules/cafe_dispatcher.hpp — the security step removes the café dispatcher from before 2026-11-16.
//
// NetworkManager runs /etc/NetworkManager/dispatcher.d/99-foxml-cafe as root at every connection. The one `desk cafe
// --setup` wrote before 2026-11-16 sourced ~/.config/foxml/cafe.conf and ran ~/.local/bin/fox-firewall, two files the
// user owns, so anything running as the user became root at the next Wi-Fi connection. A dispatcher without the v2 mark
// (MARK in shared/bin/desk-cafe) is removed: café mode is off, the firewall stays as it is. A v2 one is never touched.
#pragma once

#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include <filesystem>
#include <string>

namespace desk_install::cafe {

inline constexpr const char* DISPATCHER = "/etc/NetworkManager/dispatcher.d/99-foxml-cafe";
inline constexpr const char* V2_MARK = "# foxml-managed: cafe v2";

enum class Old { None, Kept, Removed, Unread, Failed };

// The dispatcher is root's, so root reads it (sudo -n: the security step has warmed sudo, and nothing here prompts).
inline Old remove_old(const std::filesystem::path& dispatcher = DISPATCHER) {
    namespace fs = std::filesystem;
    const std::string path = dispatcher.string();
    std::error_code ec;
    const auto there = fs::symlink_status(dispatcher, ec);
    if (!ec && !fs::exists(there)) return Old::None;
    std::string text;
    const int read = sh::probe({"sudo", "-n", "sh", "-c", "[ -e \"$1\" ] || [ -L \"$1\" ] || exit 3; cat -- \"$1\"", "sh", path},
                               text);
    if (read == 3) return Old::None;
    if (read != 0) {
        ui::warn("could not read " + path + " as root — left as it is; `desk sec cafe` says whether it is the old one");
        return Old::Unread;
    }
    if (text.find(V2_MARK) != std::string::npos) return Old::Kept;
    if (sh::dry_run()) {
        ui::substep("[dry-run] would remove the café dispatcher from before 2026-11-16 (" + path + "): café mode off");
        return Old::Removed;
    }
    if (sh::run({"sudo", "-n", "rm", "-f", "--", path}) != 0 || fs::exists(fs::symlink_status(dispatcher, ec))) {
        ui::err("could not remove " + path + ", the café dispatcher from before 2026-11-16: it still runs files you own "
                "as root at every Wi-Fi connection. Remove it: sudo rm -f " + path);
        return Old::Failed;
    }
    ui::ok("removed the café dispatcher from before 2026-11-16: it ran files you own as root");
    ui::warn("café mode is now off (the firewall is as it was). To turn it back on: desk sec cafe --setup");
    return Old::Removed;
}

}  // namespace desk_install::cafe
