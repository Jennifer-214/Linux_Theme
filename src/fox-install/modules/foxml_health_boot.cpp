// modules/foxml_health_boot.cpp — per-boot health-check service.
//
// Phase 4 of plans/health-checks.md: a Type=oneshot systemd-system
// unit that runs the A-category (boot path) checks once per boot,
// before graphical.target. Catches drift that didn't go through
// pacman — manual edits, AUR scripts, foreign installers — and
// surfaces the result in two places:
//   1. journalctl -u foxml-health-boot.service
//   2. /var/log/foxml/last-boot-health.txt — readable without
//      systemd tooling, useful when the boot itself is broken.
//
// The service never fails boot. fox-sec-health's non-zero exit codes
// (1, 2, 3) all get swallowed by the wrapper script and the service
// reports success regardless. The OUTPUT is the value, not the
// service status.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

// Helper script invoked by the unit. Bash, not C++ — it just needs to
// log + exec + always exit 0. Lives in /usr/local/lib/foxml/ alongside
// boot_sync's esp-sync helper.
constexpr const char* BOOT_HEALTH_SCRIPT =
    "#!/bin/bash\n"
    "# foxml-managed — per-boot health probe.\n"
    "# Runs the A-category (boot path) checks once at boot, logs to\n"
    "# both journal AND /var/log/foxml/last-boot-health.txt so the\n"
    "# user can read it even when journald is unhappy. Always exits 0\n"
    "# so a critical fail doesn't break boot — the LOG is the signal.\n"
    "set -u\n"
    "LOG_DIR=/var/log/foxml\n"
    "LOG_FILE=\"$LOG_DIR/last-boot-health.txt\"\n"
    "install -d -m 0755 \"$LOG_DIR\"\n"
    "{\n"
    "    echo \"foxml-health-boot at $(date -Iseconds)\"\n"
    "    echo \"running kernel: $(uname -r)\"\n"
    "    echo \"---\"\n"
    "    /usr/local/bin/fox-sec-health --only A --no-slow --verbose 2>&1 || true\n"
    "    echo \"---\"\n"
    "    echo \"finished at $(date -Iseconds)\"\n"
    "} | tee \"$LOG_FILE\"\n"
    "exit 0\n";

constexpr const char* BOOT_HEALTH_UNIT =
    "[Unit]\n"
    "Description=foxml-health A-category check (boot path probe)\n"
    "Documentation=https://github.com/Jennyfirrr/FoxML_Workstation/blob/main/plans/health-checks.md\n"
    "# Run after the system is mostly up (filesystems mounted, dbus\n"
    "# active) but before the graphical target spawns a DM. That\n"
    "# window is the sweet spot — late enough to read /etc/pam.d\n"
    "# cleanly, early enough to surface results before the user\n"
    "# attempts to log in.\n"
    "After=local-fs.target\n"
    "Before=graphical.target\n"
    "\n"
    "[Service]\n"
    "Type=oneshot\n"
    "RemainAfterExit=yes\n"
    "ExecStart=/usr/local/lib/foxml/foxml-health-boot\n"
    "# Wrapper script always exits 0, but leave SuccessExitStatus open\n"
    "# in case a future revision returns codes 1/2/3 to surface severity\n"
    "# directly in `systemctl status`.\n"
    "SuccessExitStatus=0 1 2 3\n"
    "StandardOutput=journal+console\n"
    "StandardError=journal+console\n"
    "\n"
    "[Install]\n"
    "WantedBy=multi-user.target\n";

}  // namespace

void run_foxml_health_boot(Context& ctx) {
    (void)ctx;
    ui::section("foxml-health-boot.service (per-boot probe)");

    fs::path script = "/usr/local/lib/foxml/foxml-health-boot";
    fs::path unit   = "/etc/systemd/system/foxml-health-boot.service";

    if (sh::dry_run()) {
        ui::substep("[dry-run] would install " + script.string() + " + " +
                    unit.string() + " and enable the unit");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    if (!sh::write_root_atomic(script, BOOT_HEALTH_SCRIPT, "0755")) {
        ui::warn("could not install " + script.string());
        return;
    }
    ui::ok(script.string() + " (per-boot probe helper)");

    if (!sh::write_root_atomic(unit, BOOT_HEALTH_UNIT, "0644")) {
        ui::warn("could not write " + unit.string());
        return;
    }
    ui::ok(unit.string());

    // Reload systemd's view of unit files then enable. enable is
    // idempotent so re-runs are safe.
    sh::run({"sudo", "systemctl", "daemon-reload"});
    if (sh::run({"sudo", "systemctl", "enable", "foxml-health-boot.service"}) == 0) {
        ui::ok("foxml-health-boot.service enabled (fires once per boot)");
    } else {
        ui::warn("could not enable foxml-health-boot.service via systemctl");
    }
}

}  // namespace fox_install
