// modules/ssh_follow.cpp — runs ssh_follow.hpp's plans: UFW and fail2ban follow sshd's port.
#include "ssh_follow.hpp"

#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include <cstdlib>
#include <fstream>
#include <sstream>

namespace desk_install::ssh_follow {

namespace {

std::string shown(const Argv& argv) {
    std::string out;
    for (const auto& a : argv) out += (out.empty() ? "" : " ") + a;
    return out;
}

void run_quiet(const Argv& argv) {
    if (sh::dry_run()) {
        ui::substep("[dry-run] $ " + shown(argv));
        return;
    }
    Argv wrapped = {"sh", "-c", "exec \"$@\" >/dev/null 2>&1", "sh"};
    wrapped.insert(wrapped.end(), argv.begin(), argv.end());
    sh::run(wrapped);
}

// Read-only, so it answers in a dry run too.
bool unit_is(const char* verb) {
    std::string out;
    return sh::probe({"systemctl", verb, "--quiet", "sshd"}, out) == 0;
}

}  // namespace

void ufw(const std::vector<int>& ports, const std::vector<int>& left) {
    if (ports.empty() || !sh::have("ufw")) return;
    const bool sshd_on = unit_is("is-enabled") || unit_is("is-active");
    const int session = ssh_port::session_port(std::getenv("SSH_CONNECTION"));
    bool endlessh_on_22 = false;
    for (const auto& who : ssh_port::listeners_now(22)) endlessh_on_22 |= who == "endlessh";

    for (const auto& argv : ufw_commands(ports, left, endlessh_on_22, session, sshd_on)) run_quiet(argv);
    if (sh::dry_run()) return;

    const std::string at = ssh_port::join(ports, ", ");
    if (sshd_on) ui::ok("UFW: sshd's port " + at + " rate-limited");
    for (int p : left)
        if (!has(ports, p) && p != 22 && p != session) ui::ok("UFW: " + std::to_string(p) + " closed (sshd left it)");
    if (!has(ports, 22) && session != 22) {
        if (endlessh_on_22) ui::ok("UFW: 22 open for the endlessh tarpit");
        else ui::ok("UFW: 22 closed — sshd is on " + at + " and no tarpit holds 22");
    }
}

Jail fail2ban(const std::vector<int>& ports) {
    const std::string path = "/etc/fail2ban/jail.local";
    std::ifstream f(path);
    if (!f) return Jail::Missing;
    std::ostringstream ss;
    ss << f.rdbuf();
    const std::string before = ss.str();
    const auto next = jail_with_ports(before, ports);
    if (!next) return Jail::Unchanged;

    const std::string value = ssh_port::join(ports, ",");
    if (sh::dry_run()) {
        ui::substep("[dry-run] would set jail.local's [sshd] port = " + value + ", then check it: fail2ban-client -t");
        return Jail::Updated;
    }
    if (!sh::write_root_atomic(path, *next, "0644")) {
        ui::warn("could not rewrite jail.local's [sshd] port — its bans still miss sshd's port " + value);
        return Jail::Unchanged;
    }
    if (sh::run({"sh", "-c", "sudo fail2ban-client -t >/dev/null 2>&1"}) != 0) {
        sh::write_root_atomic(path, before, "0644");
        ui::warn("fail2ban refused the new [sshd] port — jail.local is back as it was (sudo fail2ban-client -t says why)");
        return Jail::Restored;
    }
    ui::ok("fail2ban: the sshd jail bans on port " + value);
    return Jail::Updated;
}

}  // namespace desk_install::ssh_follow
