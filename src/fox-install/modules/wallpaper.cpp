#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>

namespace fs = std::filesystem;

namespace fox_install {

void run_wallpaper(Context& ctx) {
    ui::section("Wallpaper configuration");

    // Default the prompt to the user's existing choice if autostart
    // already has a rotate_wallpaper line. Pressing Enter then preserves
    // their last decision instead of silently flipping back to off.
    fs::path autostart = ctx.config_home / "hypr/modules/autostart.conf";
    if (fs::exists(autostart)) {
        std::string body = idem::read_file(autostart);
        if (body.find("rotate_wallpaper.sh") != std::string::npos) {
            ctx.rotate_wallpapers = body.find("rotate_wallpaper.sh --static") == std::string::npos;
        }
    }

    if (!ctx.assume_yes && ui::tty()) {
        ctx.rotate_wallpapers = ui::ask_yn("Enable time-of-day wallpaper rotation?", ctx.rotate_wallpapers, false);
    }

    if (ctx.rotate_wallpapers) {
        ui::ok("Wallpaper mode: rotating (time-of-day buckets)");
    } else {
        ui::ok("Wallpaper mode: static (FoxML Earthy)");
    }
}

}  // namespace fox_install
