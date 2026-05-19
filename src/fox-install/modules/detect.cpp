// modules/detect.cpp — hardware auto-detect.
//
// Walks /sys/, lspci (where present), and the chassis DMI to fill the
// hardware flags on Context. Read-only, fast, no privileges needed.
// Other modules (nvidia/amd/intel/fprint/laptop) gate on these.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cctype>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

std::string lower(std::string s) {
    for (auto& c : s) c = std::tolower(static_cast<unsigned char>(c));
    return s;
}

bool lspci_has(const std::string& needle_lower) {
    std::string out;
    if (!sh::capture({"lspci"}, out)) return false;
    return lower(out).find(needle_lower) != std::string::npos;
}

bool laptop_via_dmi() {
    // /sys/class/dmi/id/chassis_type values: 8=Portable, 9=Laptop,
    // 10=Notebook, 14=Sub-Notebook. Anything in that range = laptop.
    std::ifstream f("/sys/class/dmi/id/chassis_type");
    int code = 0;
    if (!(f >> code)) return false;
    return code == 8 || code == 9 || code == 10 || code == 14;
}

bool fprint_via_lsusb() {
    // Common fingerprint reader vendor IDs. Matches what install.sh's
    // bash detect does — Synaptics, Goodix, Validity, Elan, AuthenTec.
    static const char* VENDORS[] = {
        "06cb", "27c6", "138a", "04f3", "08ff", nullptr,
    };
    std::string out;
    if (!sh::capture({"lsusb"}, out)) return false;
    std::string low = lower(out);
    for (auto** v = VENDORS; *v; ++v) {
        if (low.find(std::string("id ") + *v) != std::string::npos) return true;
    }
    return false;
}

}  // namespace

// Default-accept y/n confirmation per detected piece of hardware.
// Goes through ui::ask_yn so the prompt picks up the single-char read +
// stray-key guard from the central helper. Skipped silently under
// --yes / no-TTY.
bool confirm_hw(const Context& ctx, const std::string& msg) {
    return ui::ask_yn(msg, /*default_yes=*/true, ctx.assume_yes);
}

void run_detect(Context& ctx) {
    ui::section("Detecting hardware");

    ctx.has_nvidia    = lspci_has("nvidia");
    ctx.has_amd_gpu   = lspci_has("amd/ati") || lspci_has("radeon");
    ctx.has_intel_gpu = lspci_has("intel corporation") &&
                       (lspci_has("graphics") || lspci_has("vga"));
    ctx.is_laptop     = laptop_via_dmi();
    ctx.has_fprint    = ctx.is_laptop && fprint_via_lsusb();

    ui::ok(std::string("GPU: ") +
           (ctx.has_nvidia ? "NVIDIA " : "") +
           (ctx.has_amd_gpu ? "AMD " : "") +
           (ctx.has_intel_gpu ? "Intel " : "") +
           ((!ctx.has_nvidia && !ctx.has_amd_gpu && !ctx.has_intel_gpu) ? "(none detected)" : ""));
    ui::ok(std::string("Chassis: ") + (ctx.is_laptop ? "laptop" : "desktop"));
    if (ctx.has_fprint) ui::ok("Fingerprint reader present");

    // Interactive confirmation per detected GPU — mirrors install.sh.legacy's
    // _gpu_prompt. Lets the user opt out of e.g. the proprietary NVIDIA
    // driver on a hybrid system without pre-knowing the right flag.
    if (ctx.has_nvidia && !confirm_hw(ctx,
        "NVIDIA detected — install nvidia-open-dkms + Hyprland Aquamarine tweaks?")) {
        ctx.has_nvidia = false;
        ui::ok("NVIDIA hardware acknowledged but install will skip it");
    }
    if (ctx.has_amd_gpu && !confirm_hw(ctx,
        "AMD GPU detected — install vulkan-radeon + libva-mesa-driver?")) {
        ctx.has_amd_gpu = false;
        ui::ok("AMD hardware acknowledged but install will skip it");
    }
    if (ctx.has_intel_gpu && !confirm_hw(ctx,
        "Intel GPU detected — install intel-media-driver + libva-intel-driver?")) {
        ctx.has_intel_gpu = false;
        ui::ok("Intel hardware acknowledged but install will skip it");
    }
    if (ctx.has_fprint && !confirm_hw(ctx,
        "Fingerprint reader detected — install fprintd?")) {
        ctx.has_fprint = false;
        ui::ok("fingerprint hardware acknowledged but install will skip it");
    }
}

}  // namespace fox_install
