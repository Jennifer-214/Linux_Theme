// modules/endlessh.cpp — SSH tarpit on port 22.
//
// Bots scanning port 22 get fed slow banners forever. Only meaningful
// AFTER the SSH wizard has moved the real sshd off port 22 (otherwise
// we'd boot ourselves off our own SSH service).
//
// Mirrors mappings.sh::install_endlessh_tarpit. AUR-installs endlessh
// from the user's available helper (yay/paru), drops config at
// /etc/endlessh/config, enables the service, and adds a UFW allow rule
// for port 22 (endlessh wants connections, not blocks).

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) {
    std::string out;
    return sh::capture({"sh", "-c", "command -v " + bin}, out) && !out.empty();
}

// Returns the port from /etc/ssh/sshd_config.d/50-foxml-hardening.conf
// or empty string if the SSH wizard hasn't run yet.
std::string real_ssh_port() {
    fs::path p = "/etc/ssh/sshd_config.d/50-foxml-hardening.conf";
    std::ifstream f(p);
    if (!f) return {};
    std::regex pat(R"(^Port\s+(\d+))");
    std::string line;
    while (std::getline(f, line)) {
        std::smatch m;
        if (std::regex_search(line, m, pat)) return m[1];
    }
    return {};
}

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

bool write_root_file(const fs::path& dst, const std::string& body) {
    fs::path tmp = "/tmp/foxin-endlessh.tmp";
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

void run_endlessh(Context& ctx) {
    ui::section("Endlessh tarpit — port 22 honeypot");

    std::string port = real_ssh_port();
    if (port.empty() || port == "22") {
        ui::ok("Endlessh skipped — real sshd on port 22 (run --ssh-harden first to move it)");
        return;
    }

    bool active = sh::run({"sh", "-c",
                           "sudo systemctl is-active --quiet endlessh 2>/dev/null "
                           "|| sudo systemctl is-active --quiet endlessh-go 2>/dev/null"}) == 0;
    if (have("endlessh")
        && idem::up_to_date("/etc/endlessh/config", CONF_BODY, ctx.force_reapply)
        && active) {
        ui::skipped("endlessh tarpit already running on :22 (real sshd on " + port + ")");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would AUR-install endlessh, write /etc/endlessh/config, "
                    "ufw allow 22/tcp, systemctl enable --now endlessh");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    if (!have("endlessh")) {
        std::string aur = aur_helper();
        if (aur.empty()) {
            ui::warn("endlessh needs an AUR helper (yay or paru) — skipping");
            return;
        }
        ui::substep("installing endlessh from AUR (makepkg build, ~30-60s)");
        bool installed = aur_install(aur, "endlessh") ||
                          aur_install(aur, "endlessh-git");
        if (!installed) {
            ui::warn("AUR install of endlessh failed");
            ui::substep("workaround: " + aur + " -S endlessh   (then re-run --endlessh)");
            return;
        }
        ui::ok("endlessh installed via " + aur);
    }

    if (write_root_file("/etc/endlessh/config", CONF_BODY)) {
        ui::ok("endlessh config written to /etc/endlessh/config");
    }
    sh::run({"sh", "-c", "sudo ufw allow 22/tcp >/dev/null 2>&1 || true"});
    ui::ok("UFW: port 22 allowed for endlessh (real sshd on " + port + " stays limited)");

    sh::run({"sh", "-c",
             "sudo systemctl enable --now endlessh.service >/dev/null 2>&1 "
             "|| sudo systemctl enable --now endlessh-go.service >/dev/null 2>&1 "
             "|| true"});
    if (sh::run({"sh", "-c",
                 "sudo systemctl is-active --quiet endlessh 2>/dev/null "
                 "|| sudo systemctl is-active --quiet endlessh-go 2>/dev/null"}) == 0) {
        ui::ok("endlessh tarpit active on :22");
    } else {
        ui::warn("endlessh didn't start — check `systemctl status endlessh`");
        ui::substep("(continuing; tarpit is nice-to-have, not critical)");
    }
}

}  // namespace fox_install
