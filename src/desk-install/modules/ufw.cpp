// modules/ufw.cpp — UFW baseline firewall (default-on, runs regardless of --secure).
//
// Mirrors mappings.sh:install_ufw_baseline. Bash ran this unconditionally
// in install.sh (BEFORE install_security) so even a `--no-secure` install
// still gets default-deny inbound. Moving it into its own module keeps
// that contract under the new registry.
//
// Tasks:
//   1. ufw default deny incoming / allow outgoing  (idempotent re-apply).
//   2. Rate-limit the ports sshd listens on (`sshd -T`, ssh_port.hpp) when sshd is running/enabled; 22 open only
//      while endlessh holds it (ssh_follow.hpp). It used to `limit ssh`, port 22, wherever sshd was.
//   3. Interactive port allowlist (TTY-only, --yes silently skips).
//   4. Auto-allow the current SSH session's port to prevent lockout.
//   5. ufw logging low + enable + systemctl enable --now ufw, and on only when `ufw status` says so (ufw_on.hpp):
//      after a kernel upgrade in this run it is set to start at the next boot instead.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "../../desk-health/checks.hpp"
#include "ssh_follow.hpp"
#include "ssh_port.hpp"
#include "ufw_on.hpp"

#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace desk_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }
bool tty_in() { return ::isatty(STDIN_FILENO); }

bool systemctl_active (const std::string& u) {
    return sh::run({"systemctl", "is-active",  "--quiet", u}) == 0;
}
bool systemctl_enabled(const std::string& u) {
    return sh::run({"systemctl", "is-enabled", "--quiet", u}) == 0;
}

// The firewall follows sshd: the ports it listens on rate-limited, 22 open only while sshd or endlessh holds it.
void follow_sshd() {
    if (const auto ports = ssh_port::configured()) {
        ssh_follow::ufw(*ports);
    } else if (systemctl_enabled("sshd") || systemctl_active("sshd")) {
        sh::run({"sudo", "ufw", "limit", "22/tcp"});
        ui::warn("couldn't read sshd's port (`sudo sshd -T` failed) — rate-limited 22, sshd's default");
    }
}

}  // namespace

void run_ufw(Context& ctx) {
    ui::section("UFW firewall baseline (deny incoming, allow outgoing)");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would: ufw default deny incoming, allow outgoing, "
                    "limit the ports sshd listens on (sudo sshd -T) if sshd is present, "
                    "close 22 unless sshd or the endlessh tarpit holds it, interactive port allowlist, "
                    "ufw logging low, ufw enable, systemctl enable --now ufw");
        return;
    }

    if (!have("ufw")) {
        // An error, not a warning: without ufw the firewall is off, and the run must not read as complete.
        ui::err("ufw not installed — the firewall is NOT on; install with --deps, then re-run --ufw");
        return;
    }

    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    std::string status_out;
    sh::capture({"sudo", "ufw", "status", "verbose"}, status_out);
    bool active = status_out.find("Status: active") != std::string::npos;
    bool baseline_set = status_out.find("Default: deny (incoming)") != std::string::npos
                     && status_out.find("allow (outgoing)") != std::string::npos;
    if (active && baseline_set && systemctl_enabled("ufw") && !ctx.force_reapply) {
        follow_sshd();
        ui::skipped("UFW already active with deny-in/allow-out baseline — the rest skipped");
        return;
    }
    if (active) {
        ui::ok("UFW active — re-applying baseline (preserves existing rules)");
    } else {
        ui::substep("applying baseline");
        sh::run({"sh", "-c", "sudo ufw --force reset >/dev/null 2>&1 || true"});
    }
    sh::run({"sudo", "ufw", "default", "deny",  "incoming"});
    sh::run({"sudo", "ufw", "default", "allow", "outgoing"});

    follow_sshd();

    // Interactive port allowlist.
    if (tty_in() && !ctx.assume_yes) {
        std::cout << "\n  Open additional ports? (e.g. 8080 3000/tcp 51820/udp)\n"
                     "  Press Enter to skip, or list ports separated by spaces:\n"
                     "  ports> " << std::flush;
        std::string line;
        std::getline(std::cin, line);
        std::istringstream is(line);
        std::string tok;
        while (is >> tok) {
            while (!tok.empty() && tok.back() == ',') tok.pop_back();
            if (tok.empty()) continue;
            std::string num = tok, proto;
            auto slash = tok.find('/');
            if (slash != std::string::npos) {
                num   = tok.substr(0, slash);
                proto = tok.substr(slash + 1);
                if (proto != "tcp" && proto != "udp") {
                    ui::warn("skipping '" + tok + "' — proto must be tcp or udp");
                    continue;
                }
            }
            try {
                int n = std::stoi(num);
                if (n < 1 || n > 65535) throw std::runtime_error("range");
            } catch (...) {
                ui::warn("skipping '" + tok + "' — not a valid port");
                continue;
            }
            sh::run({"sudo", "ufw", "allow",
                     proto.empty() ? num : (num + "/" + proto)});
            ui::ok("allowed " + (proto.empty() ? num : num + "/" + proto));
        }
    }

    // SSH lockout safety. session_port takes digits only ("22; rm -rf /" is no port): SSH_CONNECTION is set by sshd,
    // but a local shell could spoof it.
    if (const int p = ssh_port::session_port(std::getenv("SSH_CONNECTION")); p > 0) {
        const std::string safe_port = std::to_string(p);
        sh::run({"sudo", "ufw", "limit", safe_port + "/tcp"});
        ui::ok("active SSH session on port " + safe_port + " — rate-limited to avoid lockout");
    }

    sh::run({"sh", "-c", "sudo ufw logging low >/dev/null 2>&1 || true"});
    sh::run({"sh", "-c", "echo y | sudo ufw enable >/dev/null"});

    // Said on only when ufw says so: a failed `ufw enable` used to read as "UFW enabled", with the firewall off.
    std::string status;
    sh::capture({"sudo", "ufw", "status"}, status);
    // Health check A1, the one test for it: the running kernel's module tree is gone (Fail), not merely unknown.
    const bool modules = desk_health::checks::a1_kernel_modules_dep().status != desk_health::Status::Fail;
    switch (ufw_on::after_enable(status, modules)) {
    case ufw_on::Firewall::On:
        if (sh::systemctl_enable("ufw", /*user=*/false) == 0) ui::ok("UFW on (deny incoming + low logging)");
        else ui::warn("UFW is on, but its service did not enable — it will not come back after a reboot; re-run --ufw");
        return;
    case ufw_on::Firewall::AtNextBoot: {
        const auto conf = ufw_on::enabled_at_boot(idem::read_file("/etc/ufw/ufw.conf"));
        const bool set = conf && sh::write_root_atomic("/etc/ufw/ufw.conf", *conf, "0644");
        sh::run({"sudo", "systemctl", "enable", "ufw"});
        if (set) {
            ui::warn("UFW cannot start until a reboot: this run upgraded the kernel, whose modules are gone until "
                     "then — it is set to start at boot with these rules; reboot");
        } else {
            ui::err("UFW is NOT on: the kernel was upgraded in this run, and /etc/ufw/ufw.conf could not be set to "
                    "start it at boot — reboot, then re-run --ufw");
        }
        return;
    }
    case ufw_on::Firewall::Off:
        sh::run({"sudo", "systemctl", "enable", "ufw"});
        ui::err("`ufw enable` failed — the firewall is NOT on; `sudo ufw enable` says why, then re-run --ufw");
        return;
    }
}

}  // namespace desk_install
