// modules/catppuccin_cursor.cpp — the palette's Catppuccin cursor theme.
//
// Pulled from the upstream catppuccin/cursors GitHub release. The palette's
// CURSOR_THEME selected by the palette is what
// the rendered Hyprland env + GTK ini name; without it cursors fall back to
// the default Adwaita.

#include "../core/context.hpp"
#include "../core/palette.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include "../../fox-common/json.hpp"

#include <filesystem>
#include <fstream>
#include <string>

namespace fs = std::filesystem;
using json   = nlohmann::json;

namespace fox_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

// Resolve the GitHub release asset URL via the API. Returns empty on
// any failure (no network, asset renamed, etc.) — caller skips silently.
std::string resolve_asset_url(const std::string& asset) {
    std::string body;
    if (!sh::capture({"curl", "-fsSL",
                      "https://api.github.com/repos/catppuccin/cursors/releases/latest"},
                     body)) return {};
    try {
        json j = json::parse(body);
        if (j.contains("assets") && j["assets"].is_array()) {
            for (auto& a : j["assets"]) {
                std::string name = a.value("name", "");
                if (name == asset) return a.value("browser_download_url", "");
            }
        }
    } catch (...) {}
    return {};
}

}  // namespace

void run_catppuccin_cursor(Context& ctx) {
    const std::string theme = palette::get(ctx.palette_path, "CURSOR_THEME",
                                           "catppuccin-mocha-peach-cursors");
    ui::section("Cursor theme: " + theme);
    fs::path user_dir = ctx.home / ".local/share/icons";
    fs::path sys_dir  = "/usr/share/icons";

    if (fs::is_directory(sys_dir / theme) || fs::is_directory(user_dir / theme)) {
        ui::skipped(theme + " already installed");
        return;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would download " + theme + ".zip from catppuccin/cursors GitHub release");
        return;
    }
    if (!have("curl")) {
        ui::warn("curl missing — install curl or fetch " + theme + " manually");
        return;
    }
    if (!have("unzip")) {
        ui::warn("unzip missing — pacman -S unzip then re-run --catppuccin-cursor");
        return;
    }

    std::string asset = theme + ".zip";
    std::string url   = resolve_asset_url(asset);
    if (url.empty()) {
        ui::warn("couldn't resolve " + asset + " from catppuccin/cursors API — skipping");
        return;
    }

    fs::path tmp_dir = "/tmp/foxin-cursor";
    fs::create_directories(tmp_dir);
    fs::path zip = tmp_dir / asset;

    if (sh::run({"curl", "-fsSL", "-o", zip.string(), url}) != 0) {
        ui::warn("download failed: " + url);
        fs::remove_all(tmp_dir);
        return;
    }

    fs::create_directories(user_dir);
    if (sh::run({"unzip", "-q", "-o", zip.string(), "-d", user_dir.string()}) != 0) {
        ui::warn("unzip failed");
        fs::remove_all(tmp_dir);
        return;
    }
    fs::remove_all(tmp_dir);

    if (fs::is_directory(user_dir / theme)) {
        ui::ok(theme + " → " + user_dir.string());
        if (have("gsettings")) {
            sh::run({"sh", "-c",
                     "gsettings set org.gnome.desktop.interface cursor-theme \"" +
                     theme + "\" 2>/dev/null || true"});
            sh::run({"sh", "-c",
                     "gsettings set org.gnome.desktop.interface cursor-size 30 2>/dev/null || true"});
        }
    } else {
        ui::warn("extraction didn't produce " + (user_dir / theme).string());
    }
}

}  // namespace fox_install
