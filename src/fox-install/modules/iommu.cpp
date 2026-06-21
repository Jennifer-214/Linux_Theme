// modules/iommu.cpp — IOMMU DMA protection + conditional kernel lockdown.
//
// Adds intel_iommu=on / amd_iommu=on iommu=pt to the kernel cmdline, and
// lockdown=integrity ONLY on hosts where it won't brick a module (see the
// gate in run_iommu). Bootloader-aware (systemd-boot / GRUB). Reboot
// required for the new cmdline to take effect.
//
// Detects CPU vendor from /proc/cpuinfo so Intel and AMD hosts get the
// right knob.

#include "iommu.hpp"
#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cctype>
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

// True if any DKMS module is currently registered. These are unsigned
// out-of-tree modules (zfs, virtualbox, v4l2loopback, …) that lockdown=
// integrity would refuse to load. Returns false when dkms isn't installed.
// Exposed in iommu.hpp so the lockdown-heal module reuses the same probe.
bool dkms_has_modules() {
    if (!sh::have("dkms")) return false;
    std::string out;
    sh::capture({"dkms", "status"}, out);
    for (char c : out)
        if (!std::isspace(static_cast<unsigned char>(c))) return true;
    return false;
}

std::string build_iommu_args(const std::string& vendor, bool add_lockdown) {
    std::string base = (vendor == "intel") ? "intel_iommu=on iommu=pt"
                     : (vendor == "amd")   ? "amd_iommu=on iommu=pt"
                     :                       "<vendor>_iommu=on iommu=pt";
    return add_lockdown ? base + " lockdown=integrity" : base;
}

bool cmdline_options_sane(const std::string& options_line) {
    if (options_line.find("root=") == std::string::npos) return false;
    const std::string padded = " " + options_line + " ";
    return padded.find(" rw ") != std::string::npos;
}

bool needs_prepend(const std::string& cmdline_text, const std::string& base_args) {
    return cmdline_text.find(base_args) == std::string::npos;
}

bool grub_cfg_sane(const std::string& grub_cfg) {
    if (grub_cfg.empty()) return false;
    return grub_cfg.find("menuentry") != std::string::npos;
}

std::string grub_prepend_sed(const std::string& args) {
    return "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|"
           "GRUB_CMDLINE_LINUX_DEFAULT=\"" + args + " |";
}

void run_iommu(Context& ctx) {
    ui::section("IOMMU + kernel lockdown (DMA protection)");

    // Gate lockdown=integrity on "would it block a module on THIS host?".
    // It enforces signed-modules-only; an unsigned out-of-tree module then
    // silently fails to insert, and a GPU that can't load its driver drops
    // to llvmpipe software rendering → the runaway-CPU storm this module
    // once shipped on every nvidia box.
    //   - has_nvidia: set by `detect` in phase 0, BEFORE the driver is
    //     installed (nvidia is phase 4) — so a `dkms status` probe alone
    //     misses a fresh nvidia box; the hardware flag is what catches it.
    //     (Stock Arch doesn't enrol a module-signing key, so even the
    //     prebuilt `nvidia` package is unsigned w.r.t. lockdown, not just
    //     -dkms.)
    //   - dkms_has_modules(): catches already-installed non-nvidia DKMS on
    //     a re-run.
    // Intel/AMD use in-tree (signed) drivers → lockdown stays; they get the
    // hardening and nothing breaks. Per the engineering gradient,
    // frictionless-reinstall + correctness outrank the lockdown knob when
    // they conflict — IOMMU/DMA protection is applied either way.
    bool unsigned_oot = ctx.has_nvidia || dkms_has_modules();
    bool add_lockdown = !unsigned_oot;

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
        ui::warn("no systemd-boot / GRUB config detected — IOMMU not auto-enabled");
        ui::substep("if you use rEFInd / UKI / EFISTUB, add manually to your kernel cmdline:");
        ui::substep("    " + build_iommu_args(vendor, add_lockdown));
        if (!add_lockdown)
            ui::substep("    (lockdown=integrity omitted — your nvidia/DKMS modules "
                        "are unsigned and it would stop them loading)");
        return;
    }

    std::string vendor = detect_vendor();
    if (vendor.empty()) {
        ui::warn("unknown CPU vendor — skipping IOMMU");
        return;
    }

    std::string iommu_args = build_iommu_args(vendor, add_lockdown);
    std::string base_args  = build_iommu_args(vendor, /*add_lockdown=*/false);

    if (!add_lockdown)
        ui::substep("unsigned out-of-tree modules present (nvidia/DKMS) — skipping "
                    "lockdown=integrity (it would block them → software-render CPU "
                    "storm); IOMMU still applied");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would ensure \"" + base_args + "\" on " +
                    cmdline_file.string() +
                    (add_lockdown ? " (with lockdown=integrity)" : " (no lockdown)"));
        if (!add_lockdown)
            ui::substep("[dry-run] would strip any existing lockdown=integrity (self-heal)");
        return;
    }

    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    // Probe the relevant cmdline line. The prepend decision runs through the
    // pure needs_prepend() (guarded on base_args, NOT the full iommu_args) so a
    // host that already has the IOMMU knobs but a stale lockdown=integrity still
    // gets the strip below — and so the prepend never stacks a duplicate on a
    // re-run. lockdown stays a direct grep.
    std::string cur_line;
    sh::capture({"sudo", "grep",
                 is_systemd_boot ? "^options " : "^GRUB_CMDLINE_LINUX_DEFAULT=",
                 cmdline_file.string()}, cur_line);
    bool lockdown_present =
        sh::run({"sudo", "grep", "-q", "lockdown=integrity", cmdline_file.c_str()}) == 0;
    bool need_prepend = needs_prepend(cur_line, base_args);
    bool need_strip   = !add_lockdown && lockdown_present;

    if (!need_prepend && !need_strip) {
        ui::skipped("IOMMU already enabled" +
                    std::string(add_lockdown ? "" : " (lockdown correctly absent)") +
                    " in " + cmdline_file.string());
        return;
    }

    // Two backups, two purposes: .foxml-bak is the pre-FoxML original
    // (created once, survives repeat --full runs → clean uninstall);
    // .foxml-preedit is THIS run's revert point for the self-check below.
    sh::run({"sh", "-c",
             "[ -e " + cmdline_file.string() + ".foxml-bak ] || "
             "sudo cp " + cmdline_file.string() + " " +
             cmdline_file.string() + ".foxml-bak"});
    std::string preedit = cmdline_file.string() + ".foxml-preedit";
    sh::run({"sudo", "cp", cmdline_file.string(), preedit});

    if (is_systemd_boot) {
        // idempotent: prepend gated on need_prepend (needs_prepend greps base_args) — no re-stack on re-run.
        if (need_prepend)
            sh::run({"sudo", "sed", "-i",
                     "s|^options |options " + iommu_args + " |",
                     cmdline_file.string()});
        if (need_strip)
            sh::run({"sudo", "sed", "-i", LOCKDOWN_STRIP_SED, cmdline_file.string()});
    } else {
        // idempotent: same prepend under the same need_prepend guard (see grub_prepend_sed).
        if (need_prepend)
            sh::run({"sudo", "sed", "-i", grub_prepend_sed(iommu_args),
                     cmdline_file.string()});
        if (need_strip)
            sh::run({"sudo", "sed", "-i", LOCKDOWN_STRIP_SED, cmdline_file.string()});
    }

    // Self-check the edit didn't mangle the boot line; auto-revert if it
    // did. A boot entry that lost root=/rw is unbootable — never ship one.
    bool ok = true;
    if (is_systemd_boot) {
        std::string line;
        sh::capture({"sudo", "grep", "^options ", cmdline_file.string()}, line);
        ok = cmdline_options_sane(line);
    } else {
        ok = sh::run({"sudo", "grep", "-q",
                      "^GRUB_CMDLINE_LINUX_DEFAULT=", cmdline_file.c_str()}) == 0;
    }

    if (!ok) {
        sh::run({"sudo", "mv", preedit, cmdline_file.string()});
        ui::err("cmdline edit failed self-check (root=/rw missing) — reverted; "
                "IOMMU left unchanged");
        return;
    }

    // GRUB needs a grub.cfg regen for the new cmdline to take effect. Generate
    // to a temp on the same filesystem, validate it, and only atomically swap
    // it in when it's sane — a failed/garbled regen then leaves the working
    // grub.cfg untouched (fail-safe by construction; needs no boot test to
    // trust). On failure, restore /etc/default/grub from this run's preedit so
    // the change is all-or-nothing and a re-run retries cleanly. systemd-boot
    // needs no regen, so it just drops the preedit.
    if (!is_systemd_boot) {
        const std::string cfg     = "/boot/grub/grub.cfg";
        const std::string cfg_new = cfg + ".foxml-new";
        int rc = sh::run({"sh", "-c",
                          "sudo grub-mkconfig -o " + cfg_new + " 2>/dev/null"});
        std::string generated;
        sh::capture({"sudo", "cat", cfg_new}, generated);
        if (rc == 0 && grub_cfg_sane(generated)) {
            sh::run({"sudo", "mv", cfg_new, cfg});
            sh::run({"sudo", "rm", "-f", preedit});
        } else {
            sh::run({"sudo", "rm", "-f", cfg_new});
            sh::run({"sudo", "mv", preedit, cmdline_file.string()});
            ui::err("grub-mkconfig failed or produced an invalid grub.cfg — kept "
                    "the existing grub.cfg and reverted /etc/default/grub; "
                    "IOMMU not applied");
            return;
        }
    } else {
        sh::run({"sudo", "rm", "-f", preedit});
    }

    ui::ok("IOMMU enabled (" + iommu_args + ")" +
           (need_strip ? " — stripped stale lockdown=integrity" : "") +
           " — REBOOT to activate");
}

}  // namespace fox_install
