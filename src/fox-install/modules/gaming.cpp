// modules/gaming.cpp — opt-in Steam + [multilib] (32-bit gaming).
//
// Lifted out of deps so the base install no longer force-enables a
// 32-bit repo or pulls a game client onto every workstation. Default-
// off; the user opts in via --gaming (or a preset). check_gaming reports
// Noop once steam is installed, so updates/re-runs never reinstall and a
// later `pacman -R steam` self-heals back to Fresh.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

namespace fox_install {

// enable_multilib — uncomment the [multilib] block in /etc/pacman.conf
// (Steam needs 32-bit libs). Idempotent: no-op if already enabled.
// Returns true on a state change (file was edited).
static bool enable_multilib() {
    if (sh::run({"sh", "-c", "grep -q '^\\[multilib\\]' /etc/pacman.conf"}) == 0) {
        return false;        // already enabled
    }
    int rc = sh::run({"sudo", "sed", "-i",
        "/#\\[multilib\\]/,/#Include = \\/etc\\/pacman.d\\/mirrorlist/ s/^#//",
        "/etc/pacman.conf"});
    if (rc != 0) return false;
    // Refresh pacman's db so the newly-enabled repo's packages resolve.
    sh::run({"sudo", "pacman", "-Sy"});
    return true;
}

void run_gaming(Context& ctx) {
    (void)ctx;
    ui::section("Installing Steam (gaming)");

    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold and no TTY — run `sudo -v` first");
        return;
    }

    if (!sh::dry_run()) {
        if (enable_multilib()) {
            ui::ok("[multilib] enabled in /etc/pacman.conf (Steam install ready)");
        }
    }

    if (sh::pacman({"steam"}) == 0) {
        ui::ok("Steam installed");
    } else {
        ui::warn("Steam install failed — confirm [multilib] is enabled, then retry with --gaming --reapply");
    }
}

}  // namespace fox_install
