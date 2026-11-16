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
//      while endlessh holds it (ssh_follow.hpp). It used to `limit ssh`, port 22, wherever sshd was. A port UFW
//      denies (desk knock / desk spa) or narrows is left as it is.
//   3. Interactive port allowlist (TTY-only, --yes silently skips).
//   4. Auto-allow the current SSH session's port to prevent lockout (not over a deny: the session came in through it).
//   5. ufw logging low + enable + systemctl enable --now ufw, and on only when `ufw status` says so (ufw_on.hpp):
//      after a kernel upgrade in this run it is set to start at the next boot instead, once SSH's ports have their
//      IPv6 rules too.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "../../desk-health/checks.hpp"
#include "ssh_follow.hpp"
#include "ssh_port.hpp"
#include "ufw_on.hpp"

#include <cstdlib>
#include <filesystem>
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
// Returns the ports it rate-limited.
std::vector<int> follow_sshd() {
    if (const auto ports = ssh_port::configured()) return ssh_follow::ufw(*ports);
    if (!systemctl_enabled("sshd") && !systemctl_active("sshd")) return {};
    const auto rules = ssh_follow::ufw_rules();
    const auto h = rules ? ssh_follow::hold(*rules, 22) : ssh_follow::Hold::None;
    if (!rules || !ssh_follow::may_open(h)) {
        ui::warn("couldn't read sshd's port (`sudo sshd -T` failed); 22, sshd's default, left as UFW has it — " +
                 (rules ? ssh_follow::held(h) : std::string("its rules could not be read either")));
        return {};
    }
    sh::run({"sudo", "ufw", "limit", "22/tcp"});
    ui::warn("couldn't read sshd's port (`sudo sshd -T` failed) — rate-limited 22, sshd's default");
    return {22};
}

// UFW about to start at the next boot must let SSH in over IPv6 as well: ufw skipped the IPv6 half of every `limit`
// this run (ssh_follow::v6_missing). Written before ufw.conf says ENABLED=yes — once it does, ufw stops on the failed
// netfilter probe instead of writing rules. True when each rate-limited port has an IPv6 rule now, or UFW does not
// filter IPv6.
bool ipv6_ssh_ready(const std::vector<int>& limited) {
    if (limited.empty() || !std::filesystem::exists("/proc/sys/net/ipv6")
        || !ufw_on::ipv6_on(idem::read_file("/etc/default/ufw")))
        return true;
    auto v6 = ssh_follow::read_rules(ssh_follow::kUser6Rules);
    if (!v6) return false;
    const auto missing = ssh_follow::v6_missing(*v6, limited);
    if (missing.empty()) return true;
    for (auto argv : ssh_follow::v6_commands(missing)) {
        argv.insert(argv.begin(), {"sh", "-c", "exec \"$@\" >/dev/null 2>&1", "sh"});
        sh::run(argv);
    }
    v6 = ssh_follow::read_rules(ssh_follow::kUser6Rules);
    return v6 && ssh_follow::v6_missing(*v6, limited).empty();
}

}  // namespace

void run_ufw(Context& ctx) {
    ui::section("UFW firewall baseline (deny incoming, allow outgoing)");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would: ufw default deny incoming, allow outgoing, "
                    "limit the ports sshd listens on (sudo sshd -T) if sshd is present (not one UFW denies), "
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

    std::vector<int> limited = follow_sshd();

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
    // but a local shell could spoof it. A port UFW denies or narrows stays so (the session came in through that, a
    // knock say); with its rules unreadable the port is rate-limited anyway, a lockout being the worse outcome.
    if (const int p = ssh_port::session_port(std::getenv("SSH_CONNECTION")); p > 0) {
        const std::string safe_port = std::to_string(p);
        const auto rules = ssh_follow::ufw_rules();
        const auto h = rules ? ssh_follow::hold(*rules, p) : ssh_follow::Hold::None;
        if (ssh_follow::may_open(h)) {
            sh::run({"sudo", "ufw", "limit", safe_port + "/tcp"});
            ui::ok("active SSH session on port " + safe_port + " — rate-limited to avoid lockout");
            if (!ssh_port::has(limited, p)) limited.push_back(p);
        } else {
            ui::ok("active SSH session on port " + safe_port + " — left as UFW has it: " + ssh_follow::held(h));
        }
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
        // Not armed without SSH's IPv6 rules: started at boot, it would lock an IPv6 login out (2026-11-16).
        const bool v6 = ipv6_ssh_ready(limited);
        const auto conf = v6 ? ufw_on::enabled_at_boot(idem::read_file("/etc/ufw/ufw.conf")) : std::nullopt;
        const bool set = conf && sh::write_root_atomic("/etc/ufw/ufw.conf", *conf, "0644");
        sh::run({"sudo", "systemctl", "enable", "ufw"});
        if (set) {
            ui::warn("UFW cannot start until a reboot: this run upgraded the kernel, whose modules are gone until "
                     "then — it is set to start at boot with these rules (SSH over IPv4 and IPv6); reboot");
        } else if (!v6) {
            ui::err("UFW is NOT on: the kernel was upgraded in this run, and SSH's IPv6 rule (port " +
                    ssh_port::join(limited, ", ") + ") could not be written, so it is not set to start at boot, "
                    "where it would lock an IPv6 login out — reboot, then re-run --ufw");
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
