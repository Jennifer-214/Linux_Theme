// modules/amd_gpu.cpp — AMD GPU userspace.
//
// vulkan-radeon (Vulkan ICD) + mesa (VA-API). mesa-vdpau and later
// libva-mesa-driver were both folded into mesa upstream — neither exists
// on current Arch, and an unknown name fails the whole pacman transaction.
//
// Safe to run alongside the Intel and NVIDIA modules — Mesa supports
// multi-vendor in a single userspace.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

namespace fox_install {

void run_amd_gpu(Context& ctx) {
    ui::section("AMD GPU userspace (Vulkan + VA-API)");
    if (!ctx.has_amd_gpu) {
        ui::ok("no AMD GPU detected — skipping (set ctx.has_amd_gpu=true to force)");
        return;
    }
    if (sh::run({"sh", "-c",
                 "pacman -Qi vulkan-radeon mesa >/dev/null 2>&1"}) == 0
        && !ctx.force_reapply) {
        ui::skipped("AMD userspace stack already installed");
        return;
    }
    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }
    int rc = sh::pacman({"vulkan-radeon", "mesa"});   // libva-mesa-driver was merged into mesa
    if (rc == 0) ui::ok("AMD userspace stack installed");
    else         ui::warn("pacman failed — packages may be partial");
}

}  // namespace fox_install
