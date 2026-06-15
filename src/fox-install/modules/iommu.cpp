// modules/iommu.cpp — IOMMU + kernel lockdown=integrity.
//
// Adds intel_iommu=on / amd_iommu=on iommu=pt + lockdown=integrity to
// the kernel cmdline. Bootloader-aware (systemd-boot / GRUB). Reboot
// required for the new cmdline to take effect.
//
// Mirrors mappings.sh::install_iommu. Detects CPU vendor from
// /proc/cpuinfo so Intel and AMD hosts get the right knob.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

std::string read_text(const fs::path& p) {
    std::ifstream f(p);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

std::string detect_vendor() {
    std::string cpu = read_text("/proc/cpuinfo");
    if (cpu.find("GenuineIntel") != std::string::npos) return "intel";
    if (cpu.find("AuthenticAMD") != std::string::npos) return "amd";
    return {};
}

}  // namespace

void run_iommu(Context& ctx) {
    (void)ctx;
    ui::section("IOMMU + lockdown=integrity (DMA protection)");

    fs::path bootloader_systemd = "/boot/loader/entries/arch.conf";
    fs::path bootloader_grub    = "/etc/default/grub";

    fs::path cmdline_file;
    bool is_systemd_boot = false;
    if (fs::exists(bootloader_systemd)) {
        cmdline_file   = bootloader_systemd;
        is_systemd_boot = true;
    } else if (fs::exists(bootloader_grub)) {
        cmdline_file = bootloader_grub;
    } else {
        // rEFInd / UKI / kernel-install / EFISTUB users get here. Don't
        // silently no-op — surface a clear "add manually" path so they
        // know IOMMU wasn't enabled on their system.
        std::string vendor = detect_vendor();
        std::string args = (vendor == "intel" ? "intel_iommu=on iommu=pt"
                          : vendor == "amd"   ? "amd_iommu=on iommu=pt"
                          : "<vendor>_iommu=on iommu=pt");
        ui::warn("no systemd-boot / GRUB config detected — IOMMU not auto-enabled");
        ui::substep("if you use rEFInd / UKI / EFISTUB, add manually to your kernel cmdline:");
        ui::substep("    " + args + " lockdown=integrity");
        return;
    }

    std::string vendor = detect_vendor();
    if (vendor.empty()) {
        ui::warn("unknown CPU vendor — skipping IOMMU");
        return;
    }

    std::string iommu_args =
        (vendor == "intel" ? "intel_iommu=on iommu=pt" : "amd_iommu=on iommu=pt") +
        std::string(" lockdown=integrity");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would append \"" + iommu_args + "\" to " +
                    cmdline_file.string());
        return;
    }

    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    // Args-already-present is a hard skip regardless of force_reapply —
    // the sed below is a blind prepend (`s|^options |options <args> |`),
    // so re-running it stacks another copy of <args> onto the line.
    // --full means "reapply", not "duplicate".
    if (sh::run({"sh", "-c",
                 "sudo grep -q \"" + iommu_args + "\" " + cmdline_file.string()}) == 0) {
        ui::skipped("IOMMU already enabled in " + cmdline_file.string());
        return;
    }

    // Only back up if no backup exists — preserves the true pre-FoxML
    // original across repeat --full runs.
    sh::run({"sh", "-c",
             "[ -e " + cmdline_file.string() + ".foxml-bak ] || "
             "sudo cp " + cmdline_file.string() + " " +
             cmdline_file.string() + ".foxml-bak"});

    if (is_systemd_boot) {
        // idempotent: guarded by the `grep -q "$iommu_args"` hard-skip above —
        // without it this ^options prepend re-stacks → cmdline corruption.
        sh::run({"sudo", "sed", "-i",
                 "s|^options |options " + iommu_args + " |",
                 cmdline_file.string()});
    } else {
        sh::run({"sudo", "sed", "-i",
                 "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|"
                 "GRUB_CMDLINE_LINUX_DEFAULT=\"" + iommu_args + " |",
                 cmdline_file.string()});
        sh::run({"sh", "-c",
                 "sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true"});
    }
    ui::ok("IOMMU enabled (" + iommu_args + ") — REBOOT to activate");
}

}  // namespace fox_install
