// modules/lockdown_heal.cpp — default-on auto-repair for the lockdown brick.
//
// Distinct from the opt-in `iommu` hardening module: this NEVER adds anything.
// On every install it STRIPS a brick-causing `lockdown=integrity` from the
// kernel cmdline — but ONLY when the host is nvidia or has DKMS modules (where
// lockdown silently blocks the unsigned module → llvmpipe CPU storm) AND a
// stale lockdown is actually present. On an in-tree-only host a present lockdown
// is intentional, harmless hardening, so it's left alone (this never undoes a
// deliberate `--iommu`).
//
// Why it's safe (strip-only): a strip can only REMOVE a token; the post-edit
// cmdline_options_sane() check guards root=/rw with an auto-revert on any
// mangle; and removing lockdown can never make a machine LESS bootable (it
// yields the default cmdline). Reuses the proven iommu helpers — no
// reimplementation, no drift.

#include "lockdown_heal.hpp"
#include "iommu.hpp"
#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

void run_lockdown_heal(Context& ctx) {
    ui::section("Lockdown self-heal (strip a brick-causing lockdown=integrity)");

    // Only nvidia/DKMS hosts are bricked by lockdown; elsewhere it's safe.
    bool unsigned_oot = ctx.has_nvidia || dkms_has_modules();
    if (!unsigned_oot) {
        ui::skipped("in-tree drivers only — a present lockdown is safe here, nothing to heal");
        return;
    }

    fs::path systemd_boot = "/boot/loader/entries/arch.conf";
    fs::path grub         = "/etc/default/grub";
    fs::path cmdline_file;
    bool is_systemd_boot = false;
    if (fs::exists(systemd_boot)) { cmdline_file = systemd_boot; is_systemd_boot = true; }
    else if (fs::exists(grub))    { cmdline_file = grub; }
    else {
        ui::skipped("no systemd-boot / GRUB cmdline file — nothing to heal");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would strip any lockdown=integrity from " +
                    cmdline_file.string() + " (nvidia/DKMS host — it bricks the unsigned module)");
        return;
    }

    if (!sh::sudo_warmup()) { ui::err("sudo cache cold — `sudo -v` first"); return; }

    bool lockdown_present =
        sh::run({"sudo", "grep", "-q", "lockdown=integrity", cmdline_file.c_str()}) == 0;
    if (!lockdown_is_bricking(unsigned_oot, lockdown_present)) {
        ui::skipped("no brick-causing lockdown=integrity present — nothing to heal");
        return;
    }

    // .foxml-bak = pre-FoxML original (create-once); .foxml-preedit = this run's revert point.
    sh::run({"sh", "-c",
             "[ -e " + cmdline_file.string() + ".foxml-bak ] || "
             "sudo cp " + cmdline_file.string() + " " + cmdline_file.string() + ".foxml-bak"});
    std::string preedit = cmdline_file.string() + ".foxml-preedit";
    sh::run({"sudo", "cp", cmdline_file.string(), preedit});

    sh::run({"sudo", "sed", "-i", LOCKDOWN_STRIP_SED, cmdline_file.string()});

    // Self-check: a strip can't drop root=/rw, but verify + revert anyway —
    // never ship a mangled boot line.
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
        ui::err("cmdline self-check failed after strip — reverted; left unchanged");
        return;
    }

    // GRUB needs a grub.cfg regen; validate-before-swap (same fail-safe as iommu).
    if (!is_systemd_boot) {
        const std::string cfg = "/boot/grub/grub.cfg";
        const std::string cfg_new = cfg + ".foxml-new";
        int rc = sh::run({"sh", "-c", "sudo grub-mkconfig -o " + cfg_new + " 2>/dev/null"});
        std::string gen;
        sh::capture({"sudo", "cat", cfg_new}, gen);
        if (rc == 0 && grub_cfg_sane(gen)) {
            sh::run({"sudo", "mv", cfg_new, cfg});
            sh::run({"sudo", "rm", "-f", preedit});
        } else {
            sh::run({"sudo", "rm", "-f", cfg_new});
            sh::run({"sudo", "mv", preedit, cmdline_file.string()});
            ui::err("grub-mkconfig failed/invalid — kept grub.cfg, reverted cmdline; heal not applied");
            return;
        }
    } else {
        sh::run({"sudo", "rm", "-f", preedit});
    }

    ui::ok("stripped brick-causing lockdown=integrity from " + cmdline_file.string() +
           " — REBOOT to activate");
}

}  // namespace fox_install
