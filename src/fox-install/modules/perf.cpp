// modules/perf.cpp — performance tuning.
//
// Mirrors install_performance() in mappings.sh: swap systemd-timesyncd
// for chrony (high-precision time sync). Idempotent — re-runs are
// cheap no-ops once chronyd is already active.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <string>

namespace fox_install {

namespace {

// Give chrony DNS-independent NTP sources so the clock still syncs on a network
// that blocks outbound DNS (port 53) — where the stock `pool` line never
// resolves (0 sources → never synced → the 5h-slow-clock failure). Idempotent
// (sentinel-guarded) and atomic. Never creates a stub: if /etc/chrony.conf
// isn't there yet it skips rather than writing a config missing
// makestep/rtcsync/pool. Returns true iff it wrote (caller restarts chronyd).
bool ensure_chrony_fallback_servers() {
    static const char* kSentinel = "# foxml: DNS-independent NTP fallback";

    if (sh::dry_run()) {
        ui::substep("[dry-run] would add DNS-independent NTP fallback servers to /etc/chrony.conf");
        return false;
    }

    std::string body;
    if (!sh::capture({"cat", "/etc/chrony.conf"}, body) || body.empty())
        return false;                          // not present yet — never write a stub
    if (body.find(kSentinel) != std::string::npos)
        return false;                          // already added — idempotent no-op

    if (body.back() != '\n') body.push_back('\n');
    body += "\n";
    body += kSentinel;
    body += "\n";
    body += "server 162.159.200.123 iburst\n"; // time.cloudflare.com
    body += "server 162.159.200.1 iburst\n";   // time.cloudflare.com
    body += "server 216.239.35.0 iburst\n";    // time.google.com
    body += "server 216.239.35.4 iburst\n";    // time.google.com

    if (!sh::sudo_warmup()) {
        ui::warn("sudo cache cold — NTP fallback not persisted (re-run after `sudo -v`)");
        return false;
    }
    if (!sh::write_root_atomic("/etc/chrony.conf", body)) {
        ui::warn("could not write /etc/chrony.conf — NTP fallback not persisted");
        return false;
    }
    ui::ok("DNS-independent NTP fallback added (chrony syncs even when DNS is blocked)");
    return true;
}

}  // namespace

void run_perf(Context& ctx) {
    ui::section("Performance tuning");

    bool chrony_installed = sh::run({"sh", "-c",
                                     "pacman -Qi chrony >/dev/null 2>&1"}) == 0;
    bool chrony_active = sh::run({"systemctl", "is-active", "--quiet",
                                  "chronyd"}) == 0;
    if (chrony_installed && chrony_active && !ctx.force_reapply) {
        ui::skipped("chronyd already active (replaces timesyncd)");
        // chrony.conf exists here — keep an already-set-up box self-healing.
        if (ensure_chrony_fallback_servers())
            sh::run({"sudo", "systemctl", "restart", "chronyd"});
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

    // chrony.conf now exists (shipped by the package) — persist the fallback
    // so a reinstall on a DNS-blocked network still syncs without manual edits.
    if (ensure_chrony_fallback_servers())
        sh::run({"sudo", "systemctl", "restart", "chronyd"});
}

}  // namespace fox_install
