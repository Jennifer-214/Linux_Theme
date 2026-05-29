// modules/fprint.cpp — fingerprint reader (fprintd): install + enroll.
//
// Installs the daemon and enrolls a finger so the PAM-wiring modules
// that run AFTER this one (fprint_pam, greetd_fingerprint,
// sudo_fingerprint) have something to authenticate against — without an
// enrolled finger they all correctly no-op, which on a fresh machine
// means fingerprint silently never works.
//
// This module DOES NOT touch /etc/pam.d itself — that stays the job of
// the dedicated, gated PAM modules (the lockout incident came from a
// careless sudo splice; see memory: project_pam_fprintd_lockout).

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

    // Enroll a finger now so the PAM modules downstream have something to
    // match. fprintd-enroll is inherently interactive (physical touch), so
    // only prompt in an interactive run — skip cleanly under --yes / CI.
    if (sh::dry_run()) {
        ui::substep("[dry-run] would offer to enroll a finger (fprintd-enroll)");
        return;
    }

    bool enrolled = sh::run({"sh", "-c",
        "fprintd-list \"$USER\" 2>/dev/null | grep -q '#[0-9]'"}) == 0;
    if (enrolled) {
        ui::ok("a finger is already enrolled");
        return;
    }

    if (ctx.assume_yes) {
        ui::substep("non-interactive run — enroll later: `fox fingerprint enroll`");
        return;
    }

    if (ui::ask_yn("Enroll a fingerprint now? (touch the reader when it lights up)",
                   /*default_yes=*/true, /*assume_yes=*/false)) {
        sh::run({"fprintd-enroll"});
        ui::substep("add more fingers anytime: `fox fingerprint enroll <name>`");
    } else {
        ui::substep("skipped — the PAM modules will no-op until you run `fox fingerprint enroll`");
    }
}

}  // namespace fox_install
