// modules/ufw.cpp — UFW baseline firewall (default-on, runs regardless of --secure).
//
// Mirrors mappings.sh:install_ufw_baseline. Bash ran this unconditionally
// in install.sh (BEFORE install_security) so even a `--no-secure` install
// still gets default-deny inbound. Moving it into its own module keeps
// that contract under the new registry.
//
// Tasks:
//   1. ufw default deny incoming / allow outgoing  (idempotent re-apply).
//   2. ufw limit ssh  if sshd is running/enabled.
//   3. Interactive port allowlist (TTY-only, --yes silently skips).
//   4. Auto-allow the current SSH session's port to prevent lockout.
//   5. ufw logging low + enable + systemctl enable --now ufw.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fox_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }
bool tty_in() { return ::isatty(STDIN_FILENO); }

bool systemctl_active (const std::string& u) {
    return sh::run({"systemctl", "is-active",  "--quiet", u}) == 0;
}
bool systemctl_enabled(const std::string& u) {
    return sh::run({"systemctl", "is-enabled", "--quiet", u}) == 0;
}

}  // namespace

void run_ufw(Context& ctx) {
    ui::section("UFW firewall baseline (deny incoming, allow outgoing)");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would: ufw default deny incoming, allow outgoing, "
                    "limit ssh if sshd present, interactive port allowlist, "
                    "ufw logging low, ufw enable, systemctl enable --now ufw");
        return;
    }

    if (!have("ufw")) {
        ui::warn("ufw not installed — install with --deps then re-run --ufw");
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
        ui::skipped("UFW already active with deny-in/allow-out baseline — skipping");
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

    if (systemctl_enabled("sshd") || systemctl_active("sshd")) {
        sh::run({"sudo", "ufw", "limit", "ssh"});
        ui::ok("sshd detected — port 22 allowed with rate-limit");
    }

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

    // SSH lockout safety.
    if (const char* conn = std::getenv("SSH_CONNECTION"); conn && *conn) {
        std::istringstream is(conn);
        std::string client_ip, client_port, server_ip, server_port;
        is >> client_ip >> client_port >> server_ip >> server_port;
        try {
            int p = std::stoi(server_port);
            if (p > 0 && p < 65536) {
                // Re-stringify from the validated int — stoi accepts trailing
                // garbage ("22; rm -rf /" → 22) and would otherwise carry that
                // garbage straight into the shell. SSH_CONNECTION is set by
                // sshd, but a local malicious shell could still spoof it.
                std::string safe_port = std::to_string(p);
                sh::run({"sudo", "ufw", "limit", safe_port + "/tcp"});
                ui::ok("active SSH session on port " + safe_port +
                       " — rate-limited to avoid lockout");
            }
        } catch (...) {}
    }

    sh::run({"sh", "-c", "sudo ufw logging low >/dev/null 2>&1 || true"});
    sh::run({"sh", "-c", "echo y | sudo ufw enable >/dev/null"});
    if (sh::systemctl_enable("ufw", /*user=*/false) == 0) {
        ui::ok("UFW enabled (deny incoming + low logging)");
    } else {
        ui::warn("ufw service enable failed — re-run after `sudo -v`");
    }
}

}  // namespace fox_install
