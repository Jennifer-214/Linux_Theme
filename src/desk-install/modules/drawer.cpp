#include "../core/context.hpp"
#include "../core/backup.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "../../desk-common/json.hpp"
#include "menu_upgrade.hpp"

#include <filesystem>
#include <cstdlib>
#include <system_error>
#include <fstream>

namespace fs = std::filesystem;

namespace desk_install {

void run_drawer(Context& ctx) {
    ui::section("Installing palette-driven bar and menu drawers");
    if (sh::dry_run()) {
        ui::substep("[dry-run] would build desk-drawer, render the active palette, "
                    "back up and deploy Quickshell, preserve menus.json, and start the shared desktop service");
        return;
    }
    // Every failure below leaves the desktop partly on the old theme.
    auto incomplete = [&](const std::string& why) {
        ctx.deploy_failed = true;
        ui::err(why);
    };
    if (ctx.render_ran && !ctx.render_ok) {
        incomplete("render failed; refusing to install a partial drawer theme");
        return;
    }
    const auto backend = ctx.script_dir / "src/desk-drawer";
    const auto renderer = ctx.script_dir / "src/desk-render";
    const auto work = ctx.script_dir / "src/desk-work";
    if (sh::run({"make", "-C", backend.string()}) != 0 ||
        sh::run({"make", "-C", renderer.string()}) != 0 ||
        sh::run({"make", "-C", work.string()}) != 0) {
        incomplete("drawer build failed; existing menus remain available");
        return;
    }
    const auto output = ctx.rendered_dir / "quickshell/desk";
    if (sh::run({(renderer / "desk-render-fast").string(), ctx.palette_path.string(),
                 (ctx.templates_dir / "quickshell/desk").string(), output.string()}) != 0) {
        incomplete("drawer palette did not render; leaving the installed drawer unchanged");
        return;
    }
    const auto dest = ctx.config_home / "quickshell/desk";
    auto deploy = [&](const fs::path& src, const fs::path& target) {
        if (deploy_file_atomic(ctx, src, target)) return true;
        incomplete("could not back up/deploy " + target.string());
        return false;
    };
    if (!deploy(backend / "desk-drawer", ctx.home / ".local/bin/desk-drawer")) return;
    if (!deploy(work / "desk-work", ctx.home / ".local/bin/desk-work")) return;
    const auto bar_state = ctx.config_home / "waybar/drawer-state.css";
    if (!fs::exists(bar_state) && !deploy(ctx.templates_dir / "waybar/drawer-state.css", bar_state)) return;
    bool ok = true;
    std::error_code ec;
    const auto shared = ctx.shared_dir / "quickshell/desk";
    for (const auto& entry : fs::directory_iterator(shared, ec)) {
        if (!entry.is_regular_file()) continue;
        const auto name = entry.path().filename();
        if (name == "menus.json") {
            ok = deploy(entry.path(), dest / "menus.default.json") && ok;
            // The hierarchy belongs to the user; a recolour must never reset it.
            if (!fs::exists(dest / name)) ok = deploy(entry.path(), dest / name) && ok;
        } else {
            ok = deploy(entry.path(), dest / name) && ok;
        }
    }
    if (ec) { incomplete("could not read drawer configuration: " + ec.message()); return; }
    // New pages reach an existing menu once (menu_upgrade.hpp), without replacing the user's hierarchy, labels,
    // order, favorites or other menu settings; a page they removed stays removed.
    {
        std::ifstream current(dest / "menus.json"), defaults(shared / "menus.json");
        auto menu = nlohmann::json::parse(current, nullptr, false);
        const auto shipped = nlohmann::json::parse(defaults, nullptr, false);
        const auto record = ctx.home / ".local/state/foxml/menu-offered.json";
        std::ifstream seen_file(record);
        const auto seen = nlohmann::json::parse(seen_file, nullptr, false);
        std::set<std::string> offered;
        if (seen.is_array()) for (const auto& id : seen) if (id.is_string()) offered.insert(id.get<std::string>());
        bool relaid = false;
        const auto moved = menu_upgrade::relayout(menu, shipped, offered, relaid);
        bool sectioned = false;
        const auto resorted = menu_upgrade::resection(menu, shipped, offered, sectioned);
        const auto added = menu_upgrade::offer(menu, shipped, offered, !seen.is_array());
        if (relaid || sectioned || !added.empty()) {
            const auto upgraded = output / "menus.upgraded.json";
            std::ofstream file(upgraded); file << menu.dump(2) << '\n'; file.close();
            if (!file) { incomplete("could not prepare the menu upgrade"); return; }
            ok = deploy(upgraded, dest / "menus.json") && ok;
            std::string names;
            for (const auto& id : added) names += (names.empty() ? "" : ", ") + id;
            if (!added.empty()) ui::substep("drawer menu: added " + names);
            if (!moved.empty()) ui::substep("drawer menu: " + std::to_string(moved.size()) + " items moved to Workbench and Comfort (the new layout)");
            else if (relaid) ui::substep("drawer menu: shortcut labels and search words added");
            if (sectioned) ui::substep(resorted.empty() ? "drawer menu: tabs sorted under small headings"
                                                        : "drawer menu: tabs sorted under small headings; Pick a color and Displays moved");
        }
        nlohmann::json list = nlohmann::json::array();
        for (const auto& id : offered) list.push_back(id);
        fs::create_directories(record.parent_path(), ec);
        std::ofstream out(record.string() + ".tmp"); out << list.dump() << '\n'; out.close();
        if (out) fs::rename(record.string() + ".tmp", record, ec);
    }
    ok = deploy(output / "Theme.qml", dest / "Theme.qml") && ok;
    for (const auto& entry : fs::directory_iterator(output, ec)) {
        if (entry.is_regular_file() && entry.path().extension() == ".svg")
            ok = deploy(entry.path(), dest / entry.path().filename()) && ok;
    }
    if (ec) { incomplete("could not read drawer artwork: " + ec.message()); return; }
    for (const char* name : {"desktop-menu", "desk-bar", "desk-hl", "desk-picker", "desk-menu", "desk-cheatsheet", "desk-sandbox",
                            "ai-quick", "desk-wallpaper", "desk-password-copy", "desk-credits", "claude-api"})
        ok = deploy(ctx.shared_dir / "bin" / name, ctx.home / ".local/bin" / name) && ok;
    for (const char* name : {"toggle_rofi.sh", "hub.sh", "network.sh", "bluetooth.sh", "audio_switcher.sh",
                            "powermenu.sh", "clipmanager.sh", "updates_menu.sh", "eww_action.sh",
                            "start_waybar.sh", "startup.sh", "agent_rofi.sh", "panic.sh", "osd.sh", "screenshot.sh"}) {
        ok = deploy(ctx.shared_dir / "hyprland_scripts" / name,
                    ctx.config_home / "hypr/scripts" / name) && ok;
    }
    if (!ok) { incomplete("drawer deployment incomplete; check the paths above before opening it"); return; }
    const auto notifications = ctx.script_dir / "src/desk-mako";
    if (fs::exists(notifications / "Makefile")) {
        if (sh::run({"make", "-C", notifications.string()}) == 0) {
            bool deployed = deploy(notifications / "desk-mako", ctx.home / ".local/bin/desk-mako");
            deployed = deploy(ctx.shared_dir / "bin/desk-notifications", ctx.home / ".local/bin/desk-notifications") && deployed;
            deployed = deploy(ctx.shared_dir / "systemd/user/mako.service.d/50-foxml.conf",
                              ctx.config_home / "systemd/user/mako.service.d/50-foxml.conf") && deployed;
            if (deployed && std::getenv("WAYLAND_DISPLAY")) sh::run({"systemctl", "--user", "daemon-reload"});
            if (!deployed) ui::warn("notification extension deployment incomplete; system Mako remains available");
        } else ui::warn("notification extension did not build; system Mako keeps its regular outline");
    }
    ui::ok("drawer installed; custom menu hierarchy preserved at " + (dest / "menus.json").string());
    if (!sh::have("quickshell")) {
        ui::warn("install Quickshell with --deps (or pacman -S quickshell) to enable desktop menus");
        return;
    }
    if (std::getenv("WAYLAND_DISPLAY")) {
        // Atomic replacements can leave Quickshell watching the old inode.
        // A fresh engine also discovers newly installed component/IPC types.
        std::string running;
        if (sh::capture({"quickshell", "-c", "desk", "ipc", "call", "drawer", "status"}, running))
            sh::run({"quickshell", "-c", "desk", "kill"});
        if (sh::run({(ctx.home / ".local/bin/desktop-menu").string(), "--start"}) != 0)
            ui::warn("drawer startup failed; existing menus remain available");
        else ui::ok("drawer is ready; use desktop-menu or your existing menu shortcut");
    }
}

} // namespace desk_install
