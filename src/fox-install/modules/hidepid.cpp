// modules/hidepid.cpp — /proc hidepid=2 (other users' processes hidden).
//
// systemd oneshot that remounts /proc with hidepid=2 at boot. Mirrors
// mappings.sh::install_hidepid. Idempotent — re-runs detect the
// `# foxml-managed` sentinel and exit early.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "hidepid_check.hpp"
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
    return sh::write_root_atomic(dst, body);
}

}  // namespace

void run_hidepid(Context& /*ctx*/) {
    ui::section("/proc hidepid=2 (hide other users' processes)");

    // Never downgrade (installer audit 2026-10-15): already live, or foxml's newer unit (gid=proc) in place, means
    // nothing here is written, enabled or remounted, even under --full. Both reads are plain files, so a dry run
    // reports the same. The full gid=proc port is a mount change (red zone): plan batch 3.
    fs::path unit = "/etc/systemd/system/proc-hidepid.service";
    const std::string live = live_hidepid(idem::read_file("/proc/mounts"));
    if (!live.empty()) {
        ui::skipped("/proc already hides other users' processes (hidepid=" + live + ") — nothing to change");
        return;
    }
    if (is_newer_foxml_hidepid_unit(idem::read_file(unit))) {
        ui::skipped(unit.string() + " is foxml's newer form (gid=proc) — leaving it as is");
        ui::substep("not live now; `sudo systemctl start proc-hidepid.service` applies it");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write /etc/systemd/system/proc-hidepid.service, "
                    "enable it, and remount /proc with hidepid=2 live");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
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
