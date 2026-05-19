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
        ui::warn("no recognised bootloader config — skipping IOMMU enable");
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

    // Idempotency: bail if the args are already present (unless --full
    // wants to force-reapply, in which case appending is a no-op edit
    // since the matched-substring sed below won't double-add).
    if (sh::run({"sh", "-c",
                 "sudo grep -q \"" + iommu_args + "\" " + cmdline_file.string()}) == 0
        && !ctx.force_reapply) {
        ui::skipped("IOMMU already enabled in " + cmdline_file.string());
        return;
    }

    sh::run({"sh", "-c",
             "sudo cp " + cmdline_file.string() + " " +
             cmdline_file.string() + ".foxml-bak 2>/dev/null"});

    if (is_systemd_boot) {
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
