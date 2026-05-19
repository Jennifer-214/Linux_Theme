// modules/intel_gpu.cpp — Intel GPU userspace.
//
// VA-API drivers + Vulkan ICD. Mesa already ships the kernel-side i915
// bits, so no kernel module work needed.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

namespace fox_install {

void run_intel_gpu(Context& ctx) {
    ui::section("Intel GPU userspace (Vulkan + VA-API)");
    if (!ctx.has_intel_gpu) {
        ui::ok("no Intel GPU detected — skipping (set ctx.has_intel_gpu=true to force)");
        return;
    }
    if (sh::run({"sh", "-c",
                 "pacman -Qi intel-media-driver libva-intel-driver vulkan-intel "
                 ">/dev/null 2>&1"}) == 0
        && !ctx.force_reapply) {
        ui::skipped("Intel userspace stack already installed");
        return;
    }
    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }
    int rc = sh::pacman({"intel-media-driver", "libva-intel-driver", "vulkan-intel"});
    if (rc == 0) ui::ok("Intel userspace stack installed");
    else         ui::warn("pacman failed — packages may be partial");
}

}  // namespace fox_install
