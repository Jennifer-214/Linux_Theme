// modules/makepkg_hardening.cpp — hardened CFLAGS/LDFLAGS for AUR builds.
//
// Drops a file into /etc/makepkg.conf.d/ that appends FORTIFY_SOURCE=3,
// stack-protector-strong, CFI, PIE, RELRO to every AUR build. Doesn't
// help pacman binaries (pre-compiled upstream) but every package the
// user builds locally gets these protections. Mirrors
// mappings.sh::install_makepkg_hardening.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* BODY =
    "# foxml-managed — hardened CFLAGS/LDFLAGS for AUR builds.\n"
    "# Revert: sudo rm /etc/makepkg.conf.d/99-foxml-hardening.conf\n"
    "CFLAGS=\"$CFLAGS -D_FORTIFY_SOURCE=3 -fstack-protector-strong "
        "-fcf-protection -fPIE -fstack-clash-protection\"\n"
    "CXXFLAGS=\"$CXXFLAGS -D_FORTIFY_SOURCE=3 -fstack-protector-strong "
        "-fcf-protection -fPIE -fstack-clash-protection\"\n"
    "LDFLAGS=\"$LDFLAGS -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack "
        "-Wl,--as-needed -pie\"\n"
    "DEBUG_CFLAGS=\"$DEBUG_CFLAGS -fno-omit-frame-pointer\"\n";

bool write_root_file(const fs::path& dst, const std::string& body) {
    fs::path tmp = "/tmp/foxin-makepkg.tmp";
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

void run_makepkg_hardening(Context& ctx) {
    ui::section("makepkg.conf hardening (FORTIFY_SOURCE=3 + stack-protector + PIE)");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write /etc/makepkg.conf.d/99-foxml-hardening.conf");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    fs::path dst = "/etc/makepkg.conf.d/99-foxml-hardening.conf";
    if (idem::up_to_date(dst, BODY, ctx.force_reapply)) {
        ui::skipped("makepkg hardening drop-in already up to date");
        return;
    }
    if (write_root_file(dst, BODY)) {
        ui::ok("makepkg hardening drop-in (applies to every AUR build)");
    } else {
        ui::warn("could not write " + dst.string());
    }
}

}  // namespace fox_install
