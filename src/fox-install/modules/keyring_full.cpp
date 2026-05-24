// modules/keyring_full.cpp — mask gnome-keyring autostart units.
//
// systemd auto-generates app-gnome-keyring-*@autostart.service from the
// XDG autostart .desktop files. Those auto-launch a *limited* keyring
// (no SSH, no GPG components). Masking them lets Hyprland's autostart
// run gnome-keyring-daemon with --components=ssh,secrets,pkcs11 instead.
//
// Also removes /usr/local/bin/ssh if firejail symlinked it there (the
// default firejail ssh profile breaks ssh-agent forwarding + GUI prompts).
//
// Mirrors mappings.sh::install_keyring_full_components.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* AUTOSTART_UNITS[] = {
    "app-gnome-keyring-pkcs11@autostart.service",
    "app-gnome-keyring-secrets@autostart.service",
    "gnome-keyring-daemon.service",
    "gnome-keyring-daemon.socket",
};

bool is_masked(const std::string& unit) {
    std::string out;
    sh::capture({"systemctl", "--user", "is-enabled", unit}, out);
    while (!out.empty() && (out.back() == '\n' || out.back() == ' ')) out.pop_back();
    return out == "masked";
}

}  // namespace

void run_keyring_full(Context& ctx) {
    ui::section("gnome-keyring — mask limited-autostart units");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would mask 4 gnome-keyring autostart units + "
                    "remove firejail-symlinked /usr/local/bin/ssh if present");
        return;
    }

    int masked = 0;
    for (auto u : AUTOSTART_UNITS) {
        if (is_masked(u) && !ctx.force_reapply) continue;
        if (sh::run({"systemctl", "--user", "mask", u}) == 0) ++masked;
    }
    if (masked > 0) {
        ui::ok("masked " + std::to_string(masked) + " gnome-keyring autostart unit(s)");
    } else {
        ui::skipped("gnome-keyring limited autostart units already masked");
    }

    // Bridge the current session. Masking the limited units stops new
    // sessions from starting them, and the daemon that was holding
    // SSH_AUTH_SOCK alive will go away on logout — but the user's
    // current shells still point at /run/user/$UID/keyring/ssh and
    // will appear broken until next Hyprland login.
    //
    // --replace makes a running gnome-keyring-daemon hand its socket
    // over to the new full-components one in-place, so SSH agent
    // stays live without re-login.
    if (sh::have("gnome-keyring-daemon")) {
        sh::run({"sh", "-c",
                 "/usr/bin/gnome-keyring-daemon --start --replace "
                 "--components=pkcs11,secrets,ssh,gpg "
                 ">/dev/null 2>&1 &"});
        ui::ok("started gnome-keyring (ssh+gpg+secrets+pkcs11) — SSH agent live now");
    } else {
        ui::ok("on next login Hyprland will start gnome-keyring with ssh+gpg components");
    }

    // De-jail ssh if firejail symlinked /usr/local/bin/ssh.
    fs::path ssh_link = "/usr/local/bin/ssh";
    std::error_code ec;
    if (fs::is_symlink(ssh_link, ec)) {
        fs::path target = fs::read_symlink(ssh_link, ec);
        if (target.string().find("firejail") != std::string::npos) {
            if (sh::run({"sudo", "rm", ssh_link.string()}) == 0) {
                ui::ok("de-jailed ssh (restored native ssh-agent + UI prompts)");
            }
        }
    }
}

}  // namespace fox_install
