// What follows sshd's port (modules/ssh_follow.hpp), pinned without a system call. Found on a laptop (2026-11-16):
// sshd on a custom port with a plain allow rule, and a `limit ssh` on 22 where nothing listened; fail2ban's jail
// banned on `port = ssh`, so a ban never covered sshd's port; endlessh, told Port 22, sat on 2222 behind no rule.
#include "../modules/ssh_follow.hpp"

#include <cstdio>

using namespace desk_install::ssh_follow;

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}

static bool has(const std::vector<Argv>& cmds, const Argv& want) {
    for (const auto& c : cmds) if (c == want) return true;
    return false;
}
static bool touches(const std::vector<Argv>& cmds, const std::string& rule) {
    for (const auto& c : cmds) if (!c.empty() && c.back() == rule) return true;
    return false;
}

int main() {
    // UFW
    const auto moved = ufw_commands({4022}, {}, /*endlessh_on_22=*/false, /*session=*/0, /*sshd_on=*/true);
    expect(has(moved, {"sudo", "ufw", "limit", "4022/tcp"}), "the port sshd listens on is rate-limited");
    expect(!has(moved, {"sudo", "ufw", "limit", "ssh"}) && !has(moved, {"sudo", "ufw", "limit", "22/tcp"}),
           "never `limit ssh` (22) for an sshd on 4022");
    expect(has(moved, {"sudo", "ufw", "delete", "limit", "22/tcp"}) && has(moved, {"sudo", "ufw", "delete", "limit", "22"})
           && has(moved, {"sudo", "ufw", "delete", "allow", "22/tcp"}), "22 closed: nothing listens there");

    const auto tarpit = ufw_commands({4022}, {}, true, 0, true);
    expect(has(tarpit, {"sudo", "ufw", "allow", "22/tcp"}), "22 open, plainly, while endlessh holds it");
    expect(!has(tarpit, {"sudo", "ufw", "delete", "allow", "22/tcp"}), "and not closed in the same breath");

    const auto on22 = ufw_commands({22}, {}, false, 0, true);
    expect(has(on22, {"sudo", "ufw", "limit", "22/tcp"}) && !touches(on22, "22") && on22.size() == 1,
           "sshd on 22: 22 rate-limited, nothing deleted");

    const auto session = ufw_commands({4022}, {}, false, /*session=*/22, true);
    expect(!touches(session, "22/tcp") && !touches(session, "22"), "the port this SSH session came in on is never closed");

    const auto left = ufw_commands({4022}, {2200}, false, 0, true);
    expect(has(left, {"sudo", "ufw", "delete", "limit", "2200/tcp"}) && has(left, {"sudo", "ufw", "delete", "allow", "2200/tcp"}),
           "the port sshd left is closed");
    expect(!touches(left, "2200"), "only tcp for a port other than 22");

    const auto off = ufw_commands({4022}, {}, false, 0, /*sshd_on=*/false);
    expect(!has(off, {"sudo", "ufw", "limit", "4022/tcp"}), "sshd off: its port is not opened");
    expect(ufw_commands({}, {22}, false, 0, true).empty(), "sshd's ports unknown: the firewall is left alone");

    // fail2ban
    const std::string jail =
        "# foxml-managed — auto-applied by desk-install --secure.\n[DEFAULT]\nbantime  = 1h\nignoreip = 127.0.0.1/8 ::1\n\n"
        "[sshd]\naction = %(action_)s\n         foxml-dispatch\nenabled  = true\nport     = ssh\nfilter   = sshd\n"
        "journalmatch = _SYSTEMD_UNIT=sshd.service\n";
    const auto to4022 = jail_with_ports(jail, {4022});
    expect(to4022 && to4022->find("[sshd]\naction = %(action_)s\n         foxml-dispatch\nenabled  = true\nport     = 4022\n")
                         != std::string::npos, "the [sshd] port follows sshd; dispatch_hooks' action lines kept");
    expect(to4022 && to4022->find("ignoreip = 127.0.0.1/8 ::1\n") != std::string::npos, "the rest as it was");
    expect(!jail_with_ports(jail, {22}), "port = ssh already is 22: nothing to change");
    expect(!jail_with_ports(*to4022, {4022}), "a second run changes nothing");
    const auto both = jail_with_ports(jail, {4022, 22});
    expect(both && both->find("port     = 4022,22\n") != std::string::npos, "several ports, comma-separated");
    expect(!jail_with_ports(jail, {}), "unknown ports: the jail is left alone");
    expect(!jail_with_ports("[DEFAULT]\nbantime = 1h\n", {4022}), "no [sshd] section: left alone");
    const auto added = jail_with_ports("[sshd]\nenabled = true\n\n[other]\nport = 80\n", {4022});
    expect(added && *added == "[sshd]\nenabled = true\n\nport     = 4022\n[other]\nport = 80\n",
           "a section with no port line gets one, and another section's port is not touched");
    expect(jail_with_ports("[sshd]\nPort=ssh\n", {4022}) == std::optional<std::string>("[sshd]\nPort= 4022\n"),
           "keys are case-insensitive, as fail2ban reads them");
    expect(jail_ports("ssh, 4022") == std::vector<int>{22, 4022} && !jail_ports("1000:2000"), "jail port values");
    const auto fresh = jail_local("4022", nullptr);
    expect(fresh.find("[sshd]\nenabled  = true\nport     = 4022\n") != std::string::npos,
           "a new jail.local bans on sshd's port");
    expect(jail_local("ssh", nullptr).find("port     = ssh\n") != std::string::npos, "and on ssh when it is unknown");
    expect(!jail_with_ports(fresh, {4022}), "a new jail.local needs no follow-up edit");
    expect(fresh.find("ignoreip = 127.0.0.1/8 ::1\n") != std::string::npos, "localhost is never banned");
    expect(jail_local("4022", "203.0.113.4 51022 10.0.0.2 22").find("ignoreip = 127.0.0.1/8 ::1 203.0.113.4\n")
               != std::string::npos, "installing over SSH: the admin's own address is never banned");
    expect(jail_local("4022", "1.2.3.4;id 5 6 7").find("ignoreip = 127.0.0.1/8 ::1\n") != std::string::npos,
           "junk in SSH_CONNECTION never reaches the file");

    // endlessh
    expect(endlessh_blocked(std::vector<int>{4022}, {}).empty(), "sshd on 4022, 22 free: endlessh may take it");
    expect(endlessh_blocked(std::vector<int>{4022}, {"endlessh"}).empty(), "endlessh already holds 22: fine");
    expect(endlessh_blocked(std::vector<int>{22}, {"sshd"}).find("sshd listens on 22") != std::string::npos,
           "sshd on 22: skipped, and says why");
    expect(endlessh_blocked(std::vector<int>{4022, 22}, {"sshd"}).find("kept for the SSH session") != std::string::npos,
           "sshd keeping 22 for a session: says how to drop it");
    expect(endlessh_blocked(std::nullopt, {}).find("sshd -T") != std::string::npos, "sshd's port unknown: not blind");
    expect(endlessh_blocked(std::vector<int>{4022}, {"cowrie"}).find("in use by cowrie") != std::string::npos,
           "22 held by another program");
    expect(endlessh_blocked(std::vector<int>{4022}, {""}).find("in use") != std::string::npos, "an unknown owner counts");
    const auto dropin = endlessh_dropin("/usr/bin/endlessh");
    expect(dropin.find("ExecStart=\nExecStart=/usr/bin/endlessh -f /etc/endlessh/config\n") != std::string::npos,
           "the unit runs endlessh on the installer's config, not the package's /etc/endlessh.conf");

    if (failures == 0) std::printf("test_ssh_follow: ok\n");
    return failures == 0 ? 0 : 1;
}
