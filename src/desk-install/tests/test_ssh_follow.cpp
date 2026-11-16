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
    const auto moved = ufw_commands({4022}, {}, /*endlessh_on_22=*/false, /*session=*/0, /*sshd_on=*/true, "");
    expect(has(moved, {"sudo", "ufw", "limit", "4022/tcp"}), "the port sshd listens on is rate-limited");
    expect(!has(moved, {"sudo", "ufw", "limit", "ssh"}) && !has(moved, {"sudo", "ufw", "limit", "22/tcp"}),
           "never `limit ssh` (22) for an sshd on 4022");
    expect(has(moved, {"sudo", "ufw", "delete", "limit", "22/tcp"}) && has(moved, {"sudo", "ufw", "delete", "limit", "22"})
           && has(moved, {"sudo", "ufw", "delete", "allow", "22/tcp"}), "22 closed: nothing listens there");

    const auto tarpit = ufw_commands({4022}, {}, true, 0, true, "");
    expect(has(tarpit, {"sudo", "ufw", "allow", "22/tcp"}), "22 open, plainly, while endlessh holds it");
    expect(!has(tarpit, {"sudo", "ufw", "delete", "allow", "22/tcp"}), "and not closed in the same breath");

    const auto on22 = ufw_commands({22}, {}, false, 0, true, "");
    expect(has(on22, {"sudo", "ufw", "limit", "22/tcp"}) && !touches(on22, "22") && on22.size() == 1,
           "sshd on 22: 22 rate-limited, nothing deleted");

    const auto session = ufw_commands({4022}, {}, false, /*session=*/22, true, "");
    expect(!touches(session, "22/tcp") && !touches(session, "22"), "the port this SSH session came in on is never closed");

    const auto left = ufw_commands({4022}, {2200}, false, 0, true, "");
    expect(has(left, {"sudo", "ufw", "delete", "limit", "2200/tcp"}) && has(left, {"sudo", "ufw", "delete", "allow", "2200/tcp"}),
           "the port sshd left is closed");
    expect(!touches(left, "2200"), "only tcp for a port other than 22");

    const auto off = ufw_commands({4022}, {}, false, 0, /*sshd_on=*/false, "");
    expect(!has(off, {"sudo", "ufw", "limit", "4022/tcp"}), "sshd off: its port is not opened");
    expect(ufw_commands({}, {22}, false, 0, true, "").empty(), "sshd's ports unknown: the firewall is left alone");

    // UFW's own rules, as user.rules and user6.rules keep them. desk knock / desk spa gate sshd's port with
    // `ufw deny 4022/tcp`; `ufw limit 4022/tcp` replaced that deny (a rule differing only in its action) with a LIMIT
    // answering everyone, on every run of ufw, the SSH wizard or endlessh (2026-11-16).
    const std::string gated = "*filter\n:ufw-user-input - [0:0]\n### RULES ###\n\n"
                              "### tuple ### limit tcp 22 0.0.0.0/0 any 0.0.0.0/0 in\n"
                              "-A ufw-user-input -p tcp --dport 22 -j ufw-user-limit-accept\n\n"
                              "### tuple ### deny tcp 4022 0.0.0.0/0 any 0.0.0.0/0 in\n"
                              "-A ufw-user-input -p tcp --dport 4022 -j DROP\n\n"
                              "### tuple ### allow tcp 4022 0.0.0.0/0 any 203.0.113.4 in\n"   // a knock let one address in
                              "-A ufw-user-input -p tcp --dport 4022 -s 203.0.113.4 -j ACCEPT\n\n"
                              "### END RULES ###\n"
                              "### tuple ### deny tcp 4022 ::/0 any ::/0 in\n";
    expect(hold(gated, 4022) == Hold::Denied, "a knock-gated port reads as denied");
    const auto knock = ufw_commands({4022}, {}, false, 0, true, gated);
    expect(!touches(knock, "4022/tcp"), "the knock gate's deny is never turned into a limit");
    expect(to_open({4022}, {22}, gated).empty(), "nor opened before the SSH wizard moves sshd there");
    expect(!may_open(Hold::Denied) && !may_open(Hold::Narrowed) && may_open(Hold::None) && may_open(Hold::Open),
           "only a port with no rule, or plain ones, is opened");
    expect(hold(gated, 22) == Hold::Open && hold("", 4022) == Hold::None, "a plain limit is open; no rule is none");

    const auto tuple = [](const std::string& rest) { return "### tuple ### " + rest + "\n"; };
    expect(hold(tuple("reject tcp 4022 0.0.0.0/0 any 0.0.0.0/0 in"), 4022) == Hold::Denied, "reject denies too");
    expect(hold(tuple("deny any 4022 0.0.0.0/0 any 0.0.0.0/0 in"), 4022) == Hold::Denied, "a deny for any protocol");
    expect(hold(tuple("deny_log tcp 4022 0.0.0.0/0 any 0.0.0.0/0 in"), 4022) == Hold::Denied, "a logged deny");
    expect(hold(tuple("deny tcp 4022 0.0.0.0/0 any 0.0.0.0/0 in comment=6b6e6f636b"), 4022) == Hold::Denied,
           "a deny with a comment");
    expect(hold(tuple("deny tcp 4000:5000 0.0.0.0/0 any 0.0.0.0/0 in"), 4022) == Hold::Denied
           && hold(tuple("deny tcp 4000:5000 0.0.0.0/0 any 0.0.0.0/0 in"), 3999) == Hold::None, "a range");
    expect(hold(tuple("deny tcp 80,4022 0.0.0.0/0 any 0.0.0.0/0 in"), 4022) == Hold::Denied, "a list of ports");
    expect(hold(tuple("deny tcp 40222 0.0.0.0/0 any 0.0.0.0/0 in"), 4022) == Hold::None, "a whole port, not a prefix");
    expect(hold(tuple("deny udp 4022 0.0.0.0/0 any 0.0.0.0/0 in"), 4022) == Hold::None, "udp does not gate sshd");
    expect(hold(tuple("deny tcp 4022 0.0.0.0/0 any 0.0.0.0/0 out"), 4022) == Hold::None, "nor an outgoing rule");
    expect(hold(tuple("route:deny tcp 4022 0.0.0.0/0 any 0.0.0.0/0 in"), 4022) == Hold::None, "nor a routed one");
    expect(hold(tuple("deny any any 0.0.0.0/0 any 203.0.113.9 in"), 4022) == Hold::None,
           "a rule for every port is not about this one");
    expect(hold(tuple("deny tcp 4022 0.0.0.0/0 any 0.0.0.0/0"), 4022) == Hold::Denied, "ufw's old six-field form");
    expect(hold(tuple("allow tcp 4022 0.0.0.0/0 any 192.168.1.0/24 in"), 4022) == Hold::Narrowed, "a LAN-only allow");
    expect(hold(tuple("allow tcp 4022 0.0.0.0/0 any 0.0.0.0/0 in_wg0"), 4022) == Hold::Narrowed, "one interface");
    expect(hold(tuple("allow tcp 22 0.0.0.0/0 any 0.0.0.0/0 OpenSSH - in"), 22) == Hold::Open, "an app rule, plain");
    expect(!touches(ufw_commands({4022}, {}, false, 0, true, tuple("allow tcp 4022 0.0.0.0/0 any 10.0.0.0/8 in")),
                    "4022/tcp"), "a narrowed port is not opened to everyone");
    const std::string plain = tuple("allow tcp 4022 0.0.0.0/0 any 0.0.0.0/0 in");
    expect(has(ufw_commands({4022}, {}, false, 0, true, plain), {"sudo", "ufw", "limit", "4022/tcp"}),
           "a plain allow becomes a rate limit");
    const auto tarpit_denied = ufw_commands({4022}, {}, true, 0, true, tuple("deny tcp 22 0.0.0.0/0 any 0.0.0.0/0 in"));
    expect(!has(tarpit_denied, {"sudo", "ufw", "allow", "22/tcp"}), "the tarpit never undoes a deny on 22");

    // The SSH wizard opens only a port UFW holds no rule for, and a failed move closes only those: a rule that was
    // there before the run is never deleted.
    expect(to_open({4022}, {22}, "") == std::vector<int>{4022}, "a port with no rule is opened before the move");
    expect(to_open({4022}, {22}, plain).empty(), "a port UFW already allows is left to that rule");
    expect(to_open({4022, 22}, {22}, "") == std::vector<int>{4022}, "the port sshd is on already is not reopened");

    // A kernel upgraded in the same run: ufw cannot probe netfilter, skips every IPv6 `limit` and exits 0, so UFW armed
    // for the next boot had SSH rules for IPv4 only, an IPv6-only login locked out (security review M1, 2026-11-16).
    const std::string v6_none = "*filter\n:ufw6-user-input - [0:0]\n### RULES ###\n\n### END RULES ###\n";
    expect((v6_missing(v6_none, {22, 4022}) == std::vector<int>{22, 4022}), "the limited ports user6.rules lacks");
    expect(v6_missing(tuple("allow tcp 22 ::/0 any ::/0 in"), {22}).empty()
           && v6_missing(tuple("limit tcp 22 ::/0 any ::/0 in"), {22}).empty(), "an IPv6 allow or limit is there");
    expect(v6_missing(tuple("deny tcp 4022 ::/0 any ::/0 in"), {4022}).empty(), "an IPv6 deny is never undone");
    expect((v6_commands({22}) == std::vector<Argv>{{"sudo", "ufw", "allow", "22/tcp"}, {"sudo", "ufw", "limit", "22/tcp"}}),
           "an allow writes the IPv6 rule (no netfilter probe needed), then the IPv4 rate limit is put back");
    expect(v6_commands({}).empty(), "nothing missing, nothing run");

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
    // A value it cannot read as ports was replaced by sshd's, narrowing a broader ban (security review L5, 2026-11-16).
    std::string kept;
    expect(!jail_with_ports("[sshd]\nport = 0:65535\n", {4022}, &kept) && kept == "0:65535",
           "a range is left as it is (never narrowed to sshd's port), and said");
    expect(!jail_with_ports("[sshd]\nport = ssh,sftp\n", {4022}), "so is another service's name");
    expect(jail_with_ports("[sshd]\nport = 0:65535\nenabled = true\n[other]\nport = 80\n", {4022}) == std::nullopt,
           "and no second port line is added for it");
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
