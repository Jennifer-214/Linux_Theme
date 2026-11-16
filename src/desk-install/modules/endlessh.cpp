// modules/endlessh.cpp — SSH tarpit on port 22.
//
// Bots scanning port 22 get fed slow banners forever. Only once sshd listens elsewhere (ssh_port.hpp, its own
// `sshd -T`): with sshd on 22 the module skips and says why. AUR-installs endlessh from the user's helper (yay/paru),
// writes /etc/endlessh/config and a unit drop-in that makes endlessh read it (the AUR builds read /etc/endlessh.conf,
// Port 2222, which their package puts back on upgrade: the tarpit sat on 2222 with no firewall rule), restarts it,
// checks it holds :22, and only then opens 22 in UFW (ssh_follow.hpp; endlessh wants connections, not blocks).

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "ssh_follow.hpp"
#include "ssh_port.hpp"

#include <filesystem>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

namespace desk_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

std::string aur_helper() {
    if (have("yay"))  return "yay";
    if (have("paru")) return "paru";
    return {};
}

bool aur_install(const std::string& helper, const std::string& pkg) {
    // Probe first, then build. Output not redirected — silent yay during
    // a ~30-60s makepkg run looks like a frozen install.
    if (sh::run({"sh", "-c", helper + " -Si " + pkg + " &>/dev/null"}) != 0) {
        return false;
    }
    return sh::run({helper, "-S", "--needed", "--noconfirm", pkg}) == 0;
}

// Where the package put the binary; "" when endlessh is not installed.
std::string endlessh_binary() {
    for (const char* p : {"/usr/bin/endlessh", "/usr/local/bin/endlessh"})
        if (::access(p, X_OK) == 0) return p;
    return {};
}

bool holds_22() {
    const auto who = ssh_port::listeners_now(22);
    if (who.empty()) return false;
    for (const auto& name : who) if (name != "endlessh") return false;
    return true;
}

constexpr const char* CONF_BODY =
    "# foxml-managed — SSH tarpit on port 22.\n"
    "# Real sshd lives on the custom port set by --ssh-harden.\n"
    "# Bots scanning :22 get fed slow banners forever.\n"
    "Port 22\n"
    "Delay 10000\n"
    "MaxLineLength 32\n"
    "MaxClients 4096\n"
    "LogLevel 1\n"
    "BindFamily 0\n";

}  // namespace

void run_endlessh(Context& ctx) {
    ui::section("Endlessh tarpit — port 22, once sshd is elsewhere");

    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }
    const auto ports = ssh_port::configured();
    if (const auto why = ssh_follow::endlessh_blocked(ports, ssh_port::listeners_now(22)); !why.empty()) {
        ui::ok("Endlessh skipped — " + why);
        return;
    }
    const std::string sshd_at = ssh_port::join(*ports, ", ");

    std::string binary = endlessh_binary();
    if (!binary.empty() && holds_22()
        && idem::up_to_date(ssh_follow::kEndlesshConf, CONF_BODY, ctx.force_reapply)
        && idem::up_to_date(ssh_follow::kEndlesshDropIn, ssh_follow::endlessh_dropin(binary), ctx.force_reapply)) {
        ssh_follow::ufw(*ports);
        ui::skipped("endlessh tarpit already holds :22 (real sshd on " + sshd_at + ")");
        return;
    }

    if (sh::dry_run()) {
        ui::substep(std::string("[dry-run] would AUR-install endlessh if missing, write ") + ssh_follow::kEndlesshConf +
                    " (Port 22) and " + ssh_follow::kEndlesshDropIn + " (run it with -f that file), "
                    "restart endlessh, check it holds :22, then ufw allow 22/tcp — 22 stays closed if it does not");
        return;
    }

    if (binary.empty()) {
        std::string aur = aur_helper();
        if (aur.empty()) {
            ui::warn("endlessh needs an AUR helper (yay or paru) — skipping");
            return;
        }
        ui::substep("installing endlessh from AUR (makepkg build, ~30-60s)");
        bool installed = aur_install(aur, "endlessh") ||
                          aur_install(aur, "endlessh-git");
        binary = endlessh_binary();
        if (!installed || binary.empty()) {
            ui::warn("AUR install of endlessh failed");
            ui::substep("workaround: " + aur + " -S endlessh   (then re-run --endlessh)");
            return;
        }
        ui::ok("endlessh installed via " + aur);
    }

    if (!sh::write_root_atomic(ssh_follow::kEndlesshConf, CONF_BODY)
        || !sh::write_root_atomic(ssh_follow::kEndlesshDropIn, ssh_follow::endlessh_dropin(binary))) {
        ui::err("could not write the endlessh config — the tarpit is unchanged");
        return;
    }
    ui::ok(std::string("endlessh reads ") + ssh_follow::kEndlesshConf + " (drop-in " + ssh_follow::kEndlesshDropIn + ")");

    sh::systemctl_daemon_reload(/*user=*/false);
    sh::run({"sh", "-c", "sudo systemctl enable endlessh.service >/dev/null 2>&1; "
                         "sudo systemctl restart endlessh.service >/dev/null 2>&1"});
    bool held = false;
    for (int i = 0; i < 5 && !held; ++i) {
        if (i) ::sleep(1);
        held = holds_22();
    }
    ssh_follow::ufw(*ports);   // 22 open now only if endlessh holds it
    if (held) {
        ui::ok("endlessh tarpit on :22 (real sshd on " + sshd_at + ")");
    } else {
        ui::warn("endlessh did not take :22, so 22 stays closed — see `journalctl -u endlessh`");
        ui::substep("(continuing; tarpit is nice-to-have, not critical)");
    }
}

}  // namespace desk_install
