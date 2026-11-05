// modules/wallpaper_mode.hpp — the wallpaper mode already in use, for runs that didn't ask the user.
#pragma once

#include "../core/context.hpp"
#include "../core/idempotency.hpp"

#include <filesystem>
#include <string>

namespace fox_install {

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
