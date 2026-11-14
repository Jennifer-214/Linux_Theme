// modules/wallpaper_mode.hpp — the wallpaper mode already in use, for runs that didn't ask the user.
#pragma once

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../core/palette.hpp"

#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>

namespace desk_install {

// rotate_wallpaper.sh --static re-applies .current, and a new machine has none, so it would fall back to its midday
// slot instead of the theme's wallpaper. A pick that already exists is kept while the theme stays the same; a change
// of theme brings that theme's wallpaper, which the login screen then copies. .active-theme still names the previous
// theme here: post_install writes the new one at the end of the run.
inline void seed_theme_wallpaper(const Context& ctx) {
    namespace fs = std::filesystem;
    const auto wall_dir = ctx.home / ".wallpapers";
    const auto link = wall_dir / ".current";
    std::error_code ec;
    std::string saved;
    if (std::ifstream in{ctx.script_dir / ".active-theme"}) std::getline(in, saved);
    const bool theme_changed = !saved.empty() && saved != ctx.theme_name;
    if (fs::is_symlink(link, ec) && !theme_changed) return;
    const std::string name = palette::get(ctx.palette_path, "WALLPAPER", "");
    if (name.empty() || name.find('/') != std::string::npos || !fs::is_regular_file(wall_dir / name, ec)) return;
    fs::remove(link, ec);
    fs::create_symlink(name, link, ec);
}

// Specials enables or disables the rotation timer from ctx.rotate_wallpapers, so a run that skipped the wallpaper
// module has to start from what's live or it switches rotation off.
inline void keep_live_wallpaper_mode(Context& ctx) {
    if (ctx.rotate_decided) return;
    const auto autostart = ctx.config_home / "hypr/modules/autostart.conf";
    if (!std::filesystem::exists(autostart)) return;
    const std::string body = idem::read_file(autostart);
    if (body.find("rotate_wallpaper.sh") == std::string::npos) return;
    ctx.rotate_wallpapers = body.find("rotate_wallpaper.sh --static") == std::string::npos;
}

}  // namespace desk_install
