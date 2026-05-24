// modules/arch_audit.cpp — daily arch-audit security advisories timer.
//
// User-scope systemd unit + timer pair. Pings notify-send only when
// there are upgradable CVEs (--uf upgrades-only flag).

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

constexpr const char* SERVICE_BODY =
    "[Unit]\n"
    "Description=FoxML — daily arch-audit check against Arch Linux security advisories\n"
    "After=network-online.target\n"
    "\n"
    "[Service]\n"
    "Type=oneshot\n"
    "# -uf : upgrades-only — only CVEs with a fix available.\n"
    "ExecStart=/bin/sh -c 'out=$(arch-audit -uf 2>/dev/null); "
        "if [ -n \"$out\" ]; then "
        "count=$(printf \"%s\" \"$out\" | wc -l); "
        "notify-send -u critical -t 30000 "
        "\"arch-audit: $count package(s) with available fixes\" "
        "\"$(printf \"%s\" \"$out\" | head -10)\"; "
        "fi'\n";

constexpr const char* TIMER_BODY =
    "[Unit]\n"
    "Description=Run arch-audit daily\n"
    "\n"
    "[Timer]\n"
    "OnCalendar=daily\n"
    "Persistent=true\n"
    "RandomizedDelaySec=600\n"
    "\n"
    "[Install]\n"
    "WantedBy=timers.target\n";

void write_file(const fs::path& p, const char* body) {
    fs::create_directories(p.parent_path());
    std::ofstream o(p);
    o << body;
}

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
    fs::path service_unit = unit_dir / "foxml-arch-audit.service";
    fs::path timer_unit   = unit_dir / "foxml-arch-audit.timer";

    bool units_up_to_date =
        idem::up_to_date(service_unit, SERVICE_BODY, ctx.force_reapply) &&
        idem::up_to_date(timer_unit,   TIMER_BODY,   ctx.force_reapply);
    bool timer_enabled = sh::run({"systemctl", "--user", "is-enabled",
                                  "--quiet", "foxml-arch-audit.timer"}) == 0;
    if (units_up_to_date && timer_enabled) {
        ui::skipped("arch-audit daily timer already installed");
        return;
    }

    write_file(service_unit, SERVICE_BODY);
    write_file(timer_unit,   TIMER_BODY);

    sh::systemctl_daemon_reload(/*user=*/true);
    if (sh::systemctl_enable("foxml-arch-audit.timer", /*user=*/true) == 0) {
        ui::ok("arch-audit daily timer enabled");
    } else {
        ui::warn("could not enable foxml-arch-audit.timer");
    }
}

}  // namespace fox_install
