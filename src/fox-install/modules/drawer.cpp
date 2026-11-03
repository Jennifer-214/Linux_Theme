#include "../core/context.hpp"
#include "../core/backup.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <cstdlib>
#include <system_error>

namespace fs = std::filesystem;

namespace fox_install {

void run_drawer(Context& ctx) {
    ui::section("Installing palette-driven menu drawers");
    if (sh::dry_run()) {
        ui::substep("[dry-run] would build fox-drawer, render the active palette, "
                    "back up and deploy Quickshell, preserve menus.json, and start the hidden drawer service");
        return;
    }
    if (ctx.render_ran && !ctx.render_ok) {
        ui::warn("render failed; refusing to install a partial drawer theme");
        return;
    }
    const auto backend = ctx.script_dir / "src/fox-drawer";
    const auto renderer = ctx.script_dir / "src/fox-render";
    if (sh::run({"make", "-C", backend.string()}) != 0 ||
        sh::run({"make", "-C", renderer.string()}) != 0) {
        ui::warn("drawer build failed; existing menus remain available");
        return;
    }
    const auto output = ctx.rendered_dir / "quickshell/foxml";
    if (sh::run({(renderer / "fox-render-fast").string(), ctx.palette_path.string(),
                 (ctx.templates_dir / "quickshell/foxml").string(), output.string()}) != 0) {
        ui::warn("drawer palette did not render; leaving the installed drawer unchanged");
        return;
    }
    const auto dest = ctx.config_home / "quickshell/foxml";
    auto deploy = [&](const fs::path& src, const fs::path& target) {
        if (deploy_file_atomic(ctx, src, target)) return true;
        ui::warn("could not back up/deploy " + target.string());
        return false;
    };
    if (!deploy(backend / "fox-drawer", ctx.home / ".local/bin/fox-drawer")) return;
    const auto bar_state = ctx.config_home / "waybar/drawer-state.css";
    if (!fs::exists(bar_state) && !deploy(ctx.templates_dir / "waybar/drawer-state.css", bar_state)) return;
    bool ok = true;
    std::error_code ec;
    const auto shared = ctx.shared_dir / "quickshell/foxml";
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
    if (ec) { ui::warn("could not read drawer configuration: " + ec.message()); return; }
    ok = deploy(output / "Theme.qml", dest / "Theme.qml") && ok;
    for (const char* name : {"fox-desktop-menu", "fox-hl", "fox-picker", "fox-menu", "fox-cheatsheet", "fox-sandbox",
                            "fox-ai-quick", "fox-wallpaper", "fox-password-copy"})
        ok = deploy(ctx.shared_dir / "bin" / name, ctx.home / ".local/bin" / name) && ok;
    for (const char* name : {"toggle_rofi.sh", "hub.sh", "network.sh", "bluetooth.sh", "audio_switcher.sh",
                            "powermenu.sh", "clipmanager.sh", "updates_menu.sh", "eww_action.sh",
                            "start_waybar.sh", "startup.sh", "agent_rofi.sh", "panic.sh"}) {
        ok = deploy(ctx.shared_dir / "hyprland_scripts" / name,
                    ctx.config_home / "hypr/scripts" / name) && ok;
    }
    if (!ok) { ui::warn("drawer deployment incomplete; check the paths above before opening it"); return; }
    ui::ok("drawer installed; custom menu hierarchy preserved at " + (dest / "menus.json").string());
    if (!sh::have("quickshell")) {
        ui::warn("install Quickshell with --deps (or pacman -S quickshell) to enable desktop menus");
        return;
    }
    if (std::getenv("WAYLAND_DISPLAY")) {
        if (sh::run({(ctx.home / ".local/bin/fox-desktop-menu").string(), "--start"}) != 0)
            ui::warn("drawer startup failed; existing menus remain available");
        else ui::ok("drawer is ready; use fox-desktop-menu or your existing menu shortcut");
    }
}

} // namespace fox_install
