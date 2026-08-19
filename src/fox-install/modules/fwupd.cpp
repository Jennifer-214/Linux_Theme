// modules/fwupd.cpp — firmware/UEFI updates via fwupd + LVFS.
//
// Installs fwupd and enables its refresh timer so firmware-level vulnerabilities
// get patched (matters most on a laptop). Non-destructive: a package + a refresh
// timer; no system-config edits, so brick-safe (non-red-zone).

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

namespace fox_install {

void run_fwupd(Context& ctx) {
    (void)ctx;
    ui::section("Firmware updates (fwupd)");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would install fwupd + enable fwupd-refresh.timer");
        return;
    }

    sh::pacman({"fwupd"});
    sh::systemctl_enable("fwupd-refresh.timer", /*user=*/false);
    ui::ok("fwupd installed; fwupd-refresh.timer enabled (check: fwupdmgr get-updates)");
}

}  // namespace fox_install
