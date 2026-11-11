// modules/catppuccin_cursor.cpp — the palette's Catppuccin cursor theme.
//
// Pulled from the upstream catppuccin/cursors GitHub release. The palette's
// CURSOR_THEME selected by the palette is what
// the rendered Hyprland env + GTK ini name; without it cursors fall back to
// the default Adwaita. A palette with CURSOR_RECOLOR gets a set built from the
// download in its own colours (cursor_recolor.hpp).

#include "../core/context.hpp"
#include "../core/palette.hpp"
#include "../core/backup.hpp"
#include "cursor_recolor.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include "../../desk-common/json.hpp"

#include <filesystem>
#include <fstream>
#include <string>
#include <cstdlib>

namespace fs = std::filesystem;
using json   = nlohmann::json;

namespace desk_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

void sync_cursor_settings(const Context& ctx, const std::string& theme) {
    if (sh::dry_run()) {
        ui::substep("[dry-run] would synchronize GTK and fallback cursor settings");
        return;
    }
    // Clients without a theme environment still consult the default inheritance.
    std::string pattern = (fs::temp_directory_path() / "foxml-cursor-XXXXXX").string();
    if (!::mkdtemp(pattern.data())) {
        ui::warn("could not stage the default cursor theme");
        return;
    }
    const fs::path stage = fs::path(pattern) / "index.theme";
    std::ofstream output(stage);
    output << "[Icon Theme]\nInherits=" << theme << '\n';
    output.close();
    if (output) {
        for (const auto& icons : {ctx.home / ".icons", ctx.home / ".local/share/icons"}) {
            if (!deploy_file_atomic(ctx, stage, icons / "default/index.theme"))
                ui::warn("could not synchronize the fallback cursor in " + icons.string());
        }
    } else {
        ui::warn("could not write the default cursor theme");
    }
    std::error_code ec;
    fs::remove_all(pattern, ec);
    if (have("gsettings")) {
        if (sh::run({"gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", theme}) != 0)
            ui::warn("could not update the desktop cursor preference");
        if (sh::run({"gsettings", "set", "org.gnome.desktop.interface", "cursor-size", "30"}) != 0)
            ui::warn("could not update the desktop cursor size");
    }
}

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

// The directory holding `theme`, downloading it first if needed. Empty when
// it isn't there and can't be fetched (or on a dry run, which says so).
fs::path fetch_theme(const Context& ctx, const std::string& theme) {
    const fs::path user_dir = ctx.home / ".local/share/icons";
    const fs::path sys_dir  = "/usr/share/icons";

    if (fs::is_directory(sys_dir / theme)) return sys_dir / theme;
    if (fs::is_directory(user_dir / theme)) {
        ui::skipped(theme + " already installed");
        return user_dir / theme;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would download " + theme + ".zip from catppuccin/cursors GitHub release");
        return {};
    }
    if (!have("curl")) {
        ui::warn("curl missing — install curl or fetch " + theme + " manually");
        return {};
    }
    if (!have("unzip")) {
        ui::warn("unzip missing — pacman -S unzip then re-run --catppuccin-cursor");
        return {};
    }

    std::string asset = theme + ".zip";
    std::string url   = resolve_asset_url(asset);
    if (url.empty()) {
        ui::warn("couldn't resolve " + asset + " from catppuccin/cursors API — skipping");
        return {};
    }

    fs::path tmp_dir = "/tmp/foxin-cursor";
    fs::create_directories(tmp_dir);
    fs::path zip = tmp_dir / asset;

    if (sh::run({"curl", "-fsSL", "-o", zip.string(), url}) != 0) {
        ui::warn("download failed: " + url);
        fs::remove_all(tmp_dir);
        return {};
    }

    fs::create_directories(user_dir);
    if (sh::run({"unzip", "-q", "-o", zip.string(), "-d", user_dir.string()}) != 0) {
        ui::warn("unzip failed");
        fs::remove_all(tmp_dir);
        return {};
    }
    fs::remove_all(tmp_dir);

    if (!fs::is_directory(user_dir / theme)) {
        ui::warn("extraction didn't produce " + (user_dir / theme).string());
        return {};
    }
    ui::ok(theme + " → " + user_dir.string());
    return user_dir / theme;
}

}  // namespace

void run_catppuccin_cursor(Context& ctx) {
    const std::string theme = palette::get(ctx.palette_path, "CURSOR_THEME",
                                           "catppuccin-mocha-peach-cursors");
    const std::string token = palette::get(ctx.palette_path, "CURSOR_RECOLOR", "none");
    const auto recolor = cursor_recolor::parse_recolor(token);
    if (!recolor && token != "none") ui::warn("ignoring malformed CURSOR_RECOLOR: " + token);

    ui::section("Cursor theme: " + theme);
    const fs::path derived = ctx.home / ".local/share/icons" / theme;
    if (recolor && cursor_recolor::is_current(derived, *recolor)) {
        ui::skipped(theme + " already built");
        sync_cursor_settings(ctx, theme);
        return;
    }

    const fs::path source = fetch_theme(ctx, recolor ? recolor->base : theme);
    if (source.empty()) return;

    if (recolor) {
        if (sh::dry_run()) {
            ui::substep("[dry-run] would build " + theme + " from " + recolor->base);
        } else if (cursor_recolor::build_theme(source, derived, theme, *recolor)) {
            ui::ok(theme + " built from " + recolor->base);
        } else {
            ui::warn("could not build " + theme + " — check " + source.string());
            return;
        }
    }
    sync_cursor_settings(ctx, theme);
}

}  // namespace desk_install
