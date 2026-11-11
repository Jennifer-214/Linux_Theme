// modules/wallpaper_mode.hpp — the wallpaper mode already in use, for runs that didn't ask the user.
#pragma once

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../core/palette.hpp"

#include <filesystem>
#include <string>
#include <system_error>

namespace fox_install {

// rotate_wallpaper.sh --static re-applies .current, and a new machine has none, so it would fall back to its midday
// slot instead of the theme's wallpaper. A pick that already exists is left alone.
inline void seed_theme_wallpaper(const Context& ctx) {
    namespace fs = std::filesystem;
    const auto wall_dir = ctx.home / ".wallpapers";
    const auto link = wall_dir / ".current";
    std::error_code ec;
    if (fs::is_symlink(link, ec)) return;
    const std::string name = palette::get(ctx.palette_path, "WALLPAPER", "");
    if (name.empty() || name.find('/') != std::string::npos || !fs::is_regular_file(wall_dir / name, ec)) return;
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

}  // namespace fox_install
