// modules/hidepid.cpp — /proc hidepid=2 (other users' processes hidden).
//
// systemd oneshot that remounts /proc with hidepid=2 at boot. Mirrors
// mappings.sh::install_hidepid. Idempotent — re-runs detect the
// `# foxml-managed` sentinel and exit early.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* UNIT_BODY =
    "# foxml-managed — apply hidepid=2 to /proc on boot.\n"
    "[Unit]\n"
    "Description=Remount /proc with hidepid=2 (foxml)\n"
    "DefaultDependencies=no\n"
    "After=local-fs.target\n"
    "Before=systemd-user-sessions.service\n"
    "\n"
    "[Service]\n"
    "Type=oneshot\n"
    "ExecStart=/bin/mount -o remount,hidepid=2 /proc\n"
    "RemainAfterExit=yes\n"
    "\n"
    "[Install]\n"
    "WantedBy=sysinit.target\n";

bool write_root_file(const fs::path& dst, const std::string& body) {
    fs::path tmp = "/tmp/foxin-hidepid.tmp";
    {
        std::ofstream o(tmp);
        o << body;
    }
    int rc = sh::run({"sudo", "install", "-d", dst.parent_path().string()});
    if (rc != 0) { fs::remove(tmp); return false; }
    rc = sh::run({"sudo", "install", "-m", "0644", "-o", "root", "-g", "root",
                  tmp.string(), dst.string()});
    fs::remove(tmp);
    return rc == 0;
}

}  // namespace

void run_hidepid(Context& ctx) {
    ui::section("/proc hidepid=2 (hide other users' processes)");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write /etc/systemd/system/proc-hidepid.service, "
                    "enable it, and remount /proc with hidepid=2 live");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    fs::path unit = "/etc/systemd/system/proc-hidepid.service";
    bool enabled = sh::run({"systemctl", "is-enabled", "--quiet",
                            "proc-hidepid.service"}) == 0;
    bool live_applied = sh::run({"sh", "-c",
                                 "grep -q 'hidepid=2' /proc/mounts"}) == 0;
    if (idem::up_to_date(unit, UNIT_BODY, ctx.force_reapply)
        && enabled && live_applied) {
        ui::skipped("/proc hidepid=2 already enabled and live");
        return;
    }

    if (!write_root_file(unit, UNIT_BODY)) {
        ui::err("could not write " + unit.string());
        return;
    }
    sh::run({"sh", "-c", "sudo systemctl daemon-reload >/dev/null 2>&1 || true"});
    sh::run({"sh", "-c", "sudo systemctl enable proc-hidepid.service >/dev/null 2>&1 || true"});

    // Apply live so the effect is visible without rebooting.
    if (sh::run({"sh", "-c",
                 "sudo mount -o remount,hidepid=2 /proc 2>/dev/null"}) == 0) {
        ui::ok("/proc remounted hidepid=2 (other users' processes hidden)");
    } else {
        ui::ok("/proc hidepid=2 enabled on next boot");
    }
}

}  // namespace fox_install
