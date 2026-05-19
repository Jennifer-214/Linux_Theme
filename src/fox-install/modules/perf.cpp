// modules/perf.cpp — performance tuning.
//
// Mirrors install_performance() in mappings.sh: swap systemd-timesyncd
// for chrony (high-precision time sync). Idempotent — re-runs are
// cheap no-ops once chronyd is already active.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

namespace fox_install {

void run_perf(Context& ctx) {
    ui::section("Performance tuning");

    bool chrony_installed = sh::run({"sh", "-c",
                                     "pacman -Qi chrony >/dev/null 2>&1"}) == 0;
    bool chrony_active = sh::run({"systemctl", "is-active", "--quiet",
                                  "chronyd"}) == 0;
    if (chrony_installed && chrony_active && !ctx.force_reapply) {
        ui::skipped("chronyd already active (replaces timesyncd)");
        return;
    }

    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    // chrony comes from the perf package addition in --deps; install
    // it on demand here so --perf works standalone (without --deps).
    if (sh::pacman({"chrony"}) != 0) {
        ui::warn("could not install chrony — perf tuning skipped");
        return;
    }

    // Disable timesyncd first; chrony and timesyncd conflict over UDP/123.
    sh::run({"sudo", "systemctl", "disable", "--now", "systemd-timesyncd"});

    if (sh::systemctl_enable("chronyd", /*user=*/false) == 0) {
        ui::ok("chronyd active (replaces timesyncd)");
        ui::substep("verify drift with `chronyc tracking`");
    } else {
        ui::warn("chronyd enable failed — time may drift; re-run after `sudo -v`");
    }
}

}  // namespace fox_install
