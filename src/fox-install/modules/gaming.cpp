// modules/gaming.cpp — opt-in Steam + [multilib] (32-bit gaming).
//
// Lifted out of deps so the base install no longer force-enables a
// 32-bit repo or pulls a game client onto every workstation. Default-
// off; the user opts in via --gaming (or a preset). check_gaming reports
// Noop once steam is installed, so updates/re-runs never reinstall and a
// later `pacman -R steam` self-heals back to Fresh.

#include "gaming.hpp"

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

namespace fox_install {

// The idempotency guard — exposed via gaming.hpp + matched to what the sed
// writes (an uncommented `[multilib]`). Pass the path as $1 (positional) so
// it stays out of shell parsing.
bool multilib_already_enabled(const std::string& conf_path) {
    return sh::run({"sh", "-c",
                    "grep -q '^\\[multilib\\]' \"$1\"", "sh", conf_path}) == 0;
}

// enable_multilib — uncomment the [multilib] block in /etc/pacman.conf
// (Steam needs 32-bit libs). Idempotent two ways: the guard short-circuits
// when already enabled, AND MULTILIB_UNCOMMENT_SED is a fixed point even if
// the guard is bypassed. Returns true on a state change (file was edited).
static bool enable_multilib() {
    if (multilib_already_enabled("/etc/pacman.conf")) {
        return false;        // already enabled
    }
    // idempotent: MULTILIB_UNCOMMENT_SED is trigger-destroying (gaming.hpp)
    int rc = sh::run({"sudo", "sed", "-i", MULTILIB_UNCOMMENT_SED,
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
