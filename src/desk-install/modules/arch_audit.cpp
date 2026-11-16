// modules/arch_audit.cpp — daily arch-audit security advisories timer.
//
// User-scope systemd unit + timer pair (modules/arch_audit_units.hpp).
// Pings notify-send only when a fixed version of an affected package has
// shipped (arch-audit -u).

#include "arch_audit_units.hpp"
#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include <filesystem>

namespace fs = std::filesystem;

namespace desk_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

}  // namespace

void run_arch_audit(Context& ctx) {
    ui::section("arch-audit daily timer");

    if (!have("arch-audit")) {
        ui::ok("arch-audit not installed, skipping");
        return;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would write user systemd service+timer and enable");
        return;
    }

    fs::path unit_dir = ctx.config_home / "systemd/user";

    bool units_up_to_date = !ctx.force_reapply && arch_audit_units_current(unit_dir);
    bool timer_enabled = sh::check_ro({"systemctl", "--user", "is-enabled",
                                       "--quiet", "foxml-arch-audit.timer"}) == 0;
    if (units_up_to_date && timer_enabled) {
        ui::skipped("arch-audit daily timer already installed");
        return;
    }

    if (!idem::write_atomic(unit_dir / "foxml-arch-audit.service", ARCH_AUDIT_SERVICE) ||
        !idem::write_atomic(unit_dir / "foxml-arch-audit.timer", ARCH_AUDIT_TIMER)) {
        ui::warn("could not write the foxml-arch-audit units in " + unit_dir.string());
        return;
    }

    sh::systemctl_daemon_reload(/*user=*/true);
    if (sh::systemctl_enable("foxml-arch-audit.timer", /*user=*/true) == 0) {
        ui::ok("arch-audit daily timer enabled");
    } else {
        ui::warn("could not enable foxml-arch-audit.timer");
    }
}

}  // namespace desk_install
