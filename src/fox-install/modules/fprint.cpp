// modules/fprint.cpp — fingerprint reader (fprintd) — install only.
//
// DELIBERATELY does not touch /etc/pam.d. Reason:
// pam_fprintd placement in /etc/pam.d/sudo line 1, BEFORE faillock
// preauth, makes the password get "eaten" by the pam stack and the
// account locks out via faillock. Recovery requires `su -` and
// `faillock --reset`. See memory: project_pam_fprintd_lockout.
//
// We install the daemon + enroll instructions; the user wires PAM
// manually (or via a future opt-in module that knows the safe order).

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

namespace fox_install {

void run_fprint(Context& ctx) {
    ui::section("Fingerprint reader (fprintd)");

    if (!ctx.has_fprint) {
        ui::warn("no fingerprint reader detected — skipping (re-run with --fprint to force)");
    }

    bool installed = sh::run({"sh", "-c", "pacman -Qi fprintd >/dev/null 2>&1"}) == 0;
    bool enabled = sh::run({"systemctl", "is-enabled", "--quiet",
                            "fprintd.service"}) == 0;
    if (installed && enabled && !ctx.force_reapply) {
        ui::skipped("fprintd already installed and enabled");
        return;
    }

    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    if (sh::pacman({"fprintd"}) != 0) {
        ui::warn("fprintd install failed");
        return;
    }

    sh::systemctl_enable("fprintd.service", /*user=*/false);

    ui::ok("fprintd installed and enabled");
    ui::substep("enroll a finger: `fprintd-enroll`");
    ui::warn("PAM wiring NOT applied — pam_fprintd before faillock can lock sudo");
    ui::substep("recovery if locked out: `su -`, `faillock --reset`, restore .foxml-bak");
    ui::substep("safe pam_fprintd integration ships in a follow-up module");
}

}  // namespace fox_install
