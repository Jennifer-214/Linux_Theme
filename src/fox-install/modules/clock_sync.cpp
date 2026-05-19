// modules/clock_sync.cpp — one-shot NTP correction at install time.
//
// Direct UDP/123 to Cloudflare → Google fallback. Bypasses DNS so a
// wedged clock doesn't deadlock on DNSSEC validation. Mirrors
// mappings.sh::install_clock_sync.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <string>

namespace fox_install {

namespace {

bool have(const std::string& bin) {
    std::string out;
    return sh::capture({"sh", "-c", "command -v " + bin}, out) && !out.empty();
}

bool systemctl_active(const std::string& u) {
    return sh::run({"systemctl", "is-active", "--quiet", u}) == 0;
}

bool one_shot(const std::string& server) {
    std::string out;
    sh::capture({"sh", "-c",
                 "sudo chronyd -q -t 8 'server " + server + " iburst' 2>&1"}, out);
    return out.find("System clock") != std::string::npos;
}

}  // namespace

void run_clock_sync(Context&) {
    ui::section("One-shot NTP clock correction");

    if (!have("chronyd")) {
        ui::ok("chrony not installed, skipping one-shot clock sync");
        return;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would stop chronyd, run one-shot sync via "
                    "Cloudflare→Google NTP, update RTC, restart chronyd");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    bool was_running = systemctl_active("chronyd");
    if (was_running) sh::run({"sudo", "systemctl", "stop", "chronyd"});

    bool synced = false;
    if (one_shot("162.159.200.1")) {
        synced = true;
        ui::ok("clock corrected via Cloudflare NTP (162.159.200.1)");
    } else if (one_shot("216.239.35.0")) {
        synced = true;
        ui::ok("clock corrected via Google NTP (216.239.35.0)");
    } else {
        ui::warn("one-shot NTP failed — UDP/123 may be blocked on this network");
    }

    if (synced) {
        if (sh::run({"sudo", "hwclock", "--systohc"}) == 0) {
            ui::ok("RTC updated to match");
        }
    }

    if (was_running) sh::run({"sudo", "systemctl", "start", "chronyd"});
}

}  // namespace fox_install
