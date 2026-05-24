// modules/no_coredumps.cpp — refuse to write core dumps to disk.
//
// systemd-coredump drop-in (Storage=none + ProcessSizeMax=0) plus a
// belt-and-suspenders /etc/security/limits.d hard core=0 line. Mirrors
// mappings.sh::install_no_coredumps.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* COREDUMP_BODY =
    "# foxml-managed — refuse to write core dumps to disk.\n"
    "[Coredump]\n"
    "Storage=none\n"
    "ProcessSizeMax=0\n";

bool write_root_file(const fs::path& dst, const std::string& body,
                     const std::string& mode = "0644") {
    return sh::write_root_atomic(dst, body, mode);
}

}  // namespace

void run_no_coredumps(Context& ctx) {
    ui::section("Disable core dumps");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write /etc/systemd/coredump.conf.d/foxml-no-coredumps.conf + "
                    "/etc/security/limits.d/99-foxml-no-coredumps.conf");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    fs::path coredump = "/etc/systemd/coredump.conf.d/foxml-no-coredumps.conf";
    fs::path limits_path = "/etc/security/limits.d/99-foxml-no-coredumps.conf";
    constexpr const char* LIMITS_BODY = "* hard core 0\n";
    if (idem::up_to_date(coredump, COREDUMP_BODY, ctx.force_reapply)
        && idem::up_to_date(limits_path, LIMITS_BODY, ctx.force_reapply)) {
        ui::skipped("core dumps already disabled");
        return;
    }

    if (write_root_file(coredump, COREDUMP_BODY)) {
        ui::ok("systemd-coredump set to Storage=none (no crash RAM hits disk)");
    } else {
        ui::warn("could not write " + coredump.string());
    }

    if (write_root_file(limits_path, LIMITS_BODY)) {
        ui::ok("/etc/security/limits.d hard core=0 (applies next login)");
    } else {
        ui::warn("/etc/security/limits.d not writable — systemd-coredump is the primary defense");
    }

    sh::run({"sh", "-c", "sudo systemctl daemon-reexec 2>/dev/null || true"});
}

}  // namespace fox_install
