// modules/vault.cpp — wires the fox-vault binary into the user session.
//
// Two flavours of vault coexist:
//
//   1. `pass` (gpg-encrypted on-disk store). install.sh's bash version
//      handles gpg key gen + git signing config. Skipped here because
//      it needs interactive pinentry — lives in wave 2.
//
//   2. fox-vault (mlock'd in-RAM store with a Unix-socket CLI). That's
//      what this module sets up: install the binary + a systemd user
//      service that starts the daemon on login.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* UNIT_NAME = "fox-vault.service";

// Idempotent: writes the unit only if missing or different.
bool write_unit(const fs::path& unit_path, const std::string& body) {
    if (fs::exists(unit_path)) {
        std::ifstream existing(unit_path);
        std::string current((std::istreambuf_iterator<char>(existing)),
                             std::istreambuf_iterator<char>());
        if (current == body) return false;
    }
    fs::create_directories(unit_path.parent_path());
    std::ofstream out(unit_path);
    out << body;
    return true;
}

}  // namespace

void run_vault(Context& ctx) {
    ui::section("Configuring fox-vault (in-RAM secret store)");

    fs::path bin = ctx.home / ".local/bin/fox-vault";
    if (!fs::exists(bin)) {
        ui::warn("fox-vault binary missing — run `make install` first");
        return;
    }

    fs::path unit_dir  = ctx.config_home / "systemd/user";
    fs::path unit_path = unit_dir / UNIT_NAME;
    // Type=simple + `fox-vault start --foreground` is the right shape.
    // The first attempt (Type=forking with double-fork in the binary)
    // race'd systemd's PID tracking and the service was marked failed
    // even when the daemon was running. With Type=simple, systemd is
    // the daemon's parent and tracks it directly — no PIDFile dance.
    std::string unit =
        "[Unit]\n"
        "Description=fox-vault — mlock()'d in-RAM secret store\n"
        "After=default.target\n\n"
        "[Service]\n"
        "Type=simple\n"
        "ExecStart=%h/.local/bin/fox-vault start --foreground\n"
        "ExecStop=%h/.local/bin/fox-vault stop\n"
        "Restart=on-failure\n"
        "RestartSec=2\n\n"
        "[Install]\n"
        "WantedBy=default.target\n";

    bool wrote = write_unit(unit_path, unit);
    if (wrote) ui::ok("wrote " + unit_path.string());
    else       ui::skipped("unit already current");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would daemon-reload + enable --now " + std::string(UNIT_NAME));
        return;
    }

    sh::systemctl_daemon_reload(/*user=*/true);
    if (sh::systemctl_enable(UNIT_NAME, /*user=*/true) == 0) {
        ui::ok("fox-vault.service enabled and running");
    } else {
        ui::warn("could not enable fox-vault.service — check `journalctl --user -u fox-vault`");
    }
}

}  // namespace fox_install
