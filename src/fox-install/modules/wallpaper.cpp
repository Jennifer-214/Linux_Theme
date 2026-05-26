#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool pacman_has(const char* pkg) {
    return sh::run({"sh", "-c",
                    std::string("pacman -Qi ") + pkg + " >/dev/null 2>&1"}) == 0;
}

// Real-ESRGAN ncnn-vulkan binary, used by `fox-wallpaper --add` for
// the 4K-upscale path. Optional — fox-wallpaper falls back to
// ImageMagick Lanczos when missing, just with softer results.
void ensure_realesrgan() {
    if (pacman_has("realesrgan-ncnn-vulkan-bin")) {
        ui::skipped("realesrgan-ncnn-vulkan-bin already installed");
        return;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would AUR-install realesrgan-ncnn-vulkan-bin");
        return;
    }
    std::string helper;
    if      (sh::have("yay"))  helper = "yay";
    else if (sh::have("paru")) helper = "paru";
    else {
        ui::warn("no AUR helper on PATH — skipping realesrgan-ncnn-vulkan-bin");
        ui::substep("install later with: yay -S realesrgan-ncnn-vulkan-bin");
        return;
    }
    if (sh::run({helper, "-S", "--needed", "--noconfirm",
                 "realesrgan-ncnn-vulkan-bin"}) == 0) {
        ui::ok("realesrgan-ncnn-vulkan-bin (used by `fox-wallpaper --add` for 4K upscales)");
    } else {
        ui::warn("realesrgan-ncnn-vulkan-bin install failed — fox-wallpaper "
                 "--add will fall back to ImageMagick Lanczos");
    }
}

}  // namespace

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

    ensure_realesrgan();
}

}  // namespace fox_install
