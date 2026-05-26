// modules/foxml_health_timer.cpp — daily drift-check safety net.
//
// Phase 7 of plans/health-checks.md. systemd-user timer (per-user,
// no sudo) running the full health-check set daily. Catches drift
// that didn't manifest at pacman-transaction time AND didn't
// trigger the per-boot service — typically manual edits made between
// reboots, or slow degradation (faillock counter creep, disk-space
// shrinkage, journal bloat from an excited unit).
//
// User-scope because the timer needs $USER for the B3 faillock check
// and the boot/pacman halves already cover the system-wide A and
// transaction-time B paths. Keeping it user-scope also means no
// systemctl --user warning when the install runs without a live
// graphical session (e.g. inside the wizard during a fresh boot).

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* SERVICE_BODY =
    "[Unit]\n"
    "Description=foxml-health daily drift probe\n"
    "Documentation=https://github.com/Jennyfirrr/Linux_Theme/blob/main/plans/health-checks.md\n"
    "\n"
    "[Service]\n"
    "Type=oneshot\n"
    "# Full check set, no slow filter (we have time once a day),\n"
    "# verbose so the journal shows fix-hints for any non-pass.\n"
    "ExecStart=/usr/local/bin/fox-sec-health --verbose\n"
    "# All four exit codes (0/1/2/3) reflect findings, not\n"
    "# infrastructure failure — let the daemon report them as\n"
    "# normal completions so `systemctl --user list-timers` doesn't\n"
    "# show a perpetual error state for any user with active warns.\n"
    "SuccessExitStatus=0 1 2 3\n"
    "StandardOutput=journal\n"
    "StandardError=journal\n";

constexpr const char* TIMER_BODY =
    "[Unit]\n"
    "Description=Run foxml-health daily\n"
    "\n"
    "[Timer]\n"
    "# Once a day, at a moderately quiet hour. RandomizedDelaySec\n"
    "# spreads the run across a 30-min window so concurrent multi-\n"
    "# user systems don't all hammer faillock/pacman at the same\n"
    "# second.\n"
    "OnCalendar=daily\n"
    "RandomizedDelaySec=30min\n"
    "# Catch up if the host was off when the calendar window\n"
    "# elapsed — drift detection is more useful when it eventually\n"
    "# runs than when it strictly fires at the right minute.\n"
    "Persistent=true\n"
    "\n"
    "[Install]\n"
    "WantedBy=timers.target\n";

bool write_user_file(const fs::path& dst, const std::string& body) {
    std::error_code ec;
    fs::create_directories(dst.parent_path(), ec);
    fs::path tmp = dst;
    tmp += ".foxin-tmp";
    {
        std::ofstream o(tmp);
        o << body;
        o.close();
        if (!o) {
            fs::remove(tmp, ec);
            return false;
        }
    }
    fs::rename(tmp, dst, ec);
    if (ec) {
        fs::remove(tmp, ec);
        return false;
    }
    return true;
}

}  // namespace

void run_foxml_health_timer(Context& ctx) {
    ui::section("foxml-health.timer (daily drift safety net)");

    fs::path dir   = ctx.config_home / "systemd/user";
    fs::path svc   = dir / "foxml-health.service";
    fs::path timer = dir / "foxml-health.timer";

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write " + svc.string() + " + " +
                    timer.string() + " and enable foxml-health.timer");
        return;
    }

    if (!write_user_file(svc, SERVICE_BODY)) {
        ui::warn("could not write " + svc.string());
        return;
    }
    ui::ok(svc.string());

    if (!write_user_file(timer, TIMER_BODY)) {
        ui::warn("could not write " + timer.string());
        return;
    }
    ui::ok(timer.string());

    // Reload + enable in the user scope. enable --now starts the
    // timer immediately so the user doesn't wait until next reboot
    // for first-fire eligibility.
    sh::run({"systemctl", "--user", "daemon-reload"});
    if (sh::run({"systemctl", "--user", "enable", "--now",
                 "foxml-health.timer"}) == 0) {
        ui::ok("foxml-health.timer enabled (daily drift probe active)");
    } else {
        ui::warn("could not enable foxml-health.timer via systemctl --user");
        ui::substep("if you're in a TTY without a graphical user session, "
                    "`systemctl --user` may need `loginctl enable-linger`");
    }
}

}  // namespace fox_install
