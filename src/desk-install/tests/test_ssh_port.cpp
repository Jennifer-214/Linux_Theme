// The one SSH port source (modules/ssh_port.hpp): the ports sshd listens on, read from `sshd -T`, and the probes that
// prove a login on them. The key self-test always tried 22, so a re-run after a move failed it and turned passwords
// back on; UFW, fail2ban and endlessh each assumed 22 too. OpenSSH 10's dump names its keywords in mixed case
// (`Port 22`, `ListenAddress 0.0.0.0:22`); read as lower case only, a VM's working `sshd -T` gave no port at all.
#include "../modules/ssh_port.hpp"

#include <cstdio>

using namespace desk_install::ssh_port;

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}

static bool has_port(const std::vector<std::string>& argv, const std::string& port) {
    for (std::size_t i = 0; i + 1 < argv.size(); ++i)
        if (argv[i] == "-p") return argv[i + 1] == port;
    return false;
}
static bool has_arg(const std::vector<std::string>& argv, const std::string& want) {
    for (const auto& a : argv) if (a == want) return true;
    return false;
}

int main() {
    // `sshd -T` as OpenSSH prints it: port lines, then the sockets as listenaddress lines.
    const std::string moved = "addressfamily any\nport 2222\nlistenaddress [::]:2222\nlistenaddress 0.0.0.0:2222\n"
                              "passwordauthentication no\n";
    expect(listen_port(moved) == 2222, "the port sshd -T reports");
    expect(listen_ports(moved) == std::vector<int>{2222}, "one port, though v4 and v6 both list it");
    expect(listen_port("port 2222\nport 2223\n") == 2222, "the first of several");
    expect((listen_ports("port 4022\nport 22\nlistenaddress 0.0.0.0:4022\nlistenaddress 0.0.0.0:22\n")
            == std::vector<int>{4022, 22}), "several, in config order");
    expect((listen_ports("port 22\nlistenaddress 192.168.1.5:2200\n") == std::vector<int>{2200}),
           "a ListenAddress with its own port: the socket sshd binds wins over Port");
    expect(listen_port("") == 22 && listen_ports("").empty(), "no output (sshd -T failed): empty, 22 by default");
    expect(listen_port("passwordauthentication yes\n") == 22, "no port line: 22");
    expect(listen_port("port 0\n") == 22 && listen_port("port 70000\n") == 22, "not a port: 22");
    expect(listen_port("ports 2222\n") == 22, "a key is a whole word");
    expect(listen_ports("port 22x\nport -5\n").empty(), "digits only");

    // `sudo sshd -T` from OpenSSH 10.6 (Arch, the test VM, 2026-11-16), its first lines and the password one, as printed.
    const std::string openssh106 = "Port 22\nAddressFamily any\nListenAddress [::]:22\nListenAddress 0.0.0.0:22\n"
                                   "UsePAM yes\nPAMServiceName sshd\nPermitRootLogin prohibit-password\n"
                                   "PubkeyAuthentication yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication no\n";
    expect(listen_ports(openssh106) == std::vector<int>{22}, "OpenSSH 10's mixed-case dump: the port it binds");
    expect(password_auth(openssh106) == true, "and its PasswordAuthentication");
    const std::string moved106 = "Port 4022\nAddressFamily any\nListenAddress [::]:4022\nListenAddress 0.0.0.0:4022\n"
                                 "PasswordAuthentication no\n";
    expect(listen_ports(moved106) == std::vector<int>{4022} && password_auth(moved106) == false,
           "a moved, keys-only sshd in OpenSSH 10's case");
    expect((listen_ports("Port 22\nlistenaddress 0.0.0.0:2200\n") == std::vector<int>{2200}), "either case, mixed");
    expect((listen_ports("Port 22\nListenAddress 192.168.1.5:2200\n") == std::vector<int>{2200}),
           "OpenSSH 10: a ListenAddress with its own port wins over Port");

    expect(parse_port("4022") == 4022 && !parse_port("22; rm -rf /") && !parse_port("+22") && !parse_port("")
           && !parse_port("65536") && !parse_port("0") && parse_port("65535") == 65535, "parse_port: 1..65535, digits");
    expect(password_auth(moved) == false && password_auth("passwordauthentication yes\n") == true
           && !password_auth(""), "what sshd does about passwords");
    // A re-run on a keys-only sshd with no key logging in here (none on the machine, no forwarded agent) wrote
    // PasswordAuthentication yes back; unattended it only said so (review, 2026-11-16). Now that needs her yes.
    expect(would_weaken(password_auth(moved106), /*key_ok=*/false), "keys only now and no key here: ask first");
    expect(!would_weaken(password_auth(moved106), true), "a key logged in: keys only is proven again");
    expect(!would_weaken(password_auth(openssh106), false) && !would_weaken(std::nullopt, false),
           "passwords on already, or unknown: nothing to weaken");
    expect(session_port("203.0.113.4 51022 10.0.0.2 4022") == 4022, "the server port of this SSH session");
    expect(session_port(nullptr) == 0 && session_port("") == 0 && session_port("1.2.3.4 5 6.7.8.9 22;x") == 0,
           "no session, or junk: 0");

    const auto argv = key_test_argv("alice", 2222);
    expect(has_port(argv, "2222"), "the key test connects on the port sshd listens on");
    expect(has_port(key_test_argv("alice", 22), "22"), "and on 22 when that is the port");
    expect(!argv.empty() && argv.front() == "ssh" && argv.back() == "true", "ssh ... true");
    expect(has_arg(argv, "BatchMode=yes") && has_arg(argv, "PasswordAuthentication=no")
           && has_arg(argv, "PreferredAuthentications=publickey"), "a key only: never a password or a prompt");
    expect(has_arg(argv, "alice@127.0.0.1"), "logs in as the user on 127.0.0.1");
    // ~/.ssh/config was read: a ControlMaster (the pre-change test left one open), a ProxyJump or a HostName for
    // 127.0.0.1 made the post-reload proof pass with no new login to this sshd (security review M2, 2026-11-16).
    bool no_config = false;
    for (std::size_t i = 0; i + 1 < argv.size(); ++i) no_config |= argv[i] == "-F" && argv[i + 1] == "none";
    expect(no_config, "the key test reads no ssh config file (-F none)");
    expect(has_arg(argv, "ControlMaster=no") && has_arg(argv, "ControlPath=none"), "and never shares a connection");
    expect(has_arg(argv, "ProxyJump=none"), "nor goes through another machine");
    expect(has_arg(argv, "IdentitiesOnly=no"), "the agent's keys count: a forwarded agent is how a remote key gets here");

    expect(has_port(keyscan_argv(4022), "4022") && keyscan_argv(4022).back() == "127.0.0.1", "keyscan on the port");
    expect(answered("127.0.0.1 ssh-ed25519 AAAAC3Nza\n") && answered("[127.0.0.1]:4022 ecdsa-sha2-nistp256 AAAA\n"),
           "host keys back: sshd answers");
    expect(!answered("") && !answered("# 127.0.0.1:4022 SSH-2.0-OpenSSH_10.0\n"), "only a banner comment: no keys");

    const std::string ss = "LISTEN 0 128 0.0.0.0:4022 0.0.0.0:* users:((\"sshd\",pid=611,fd=6))\n"
                           "LISTEN 0 4096 *:22 *:* users:((\"endlessh\",pid=88,fd=3))\n"
                           "LISTEN 0 4096 *:2222 *:* users:((\"endlessh\",pid=90,fd=3))\n"
                           "LISTEN 0 512 127.0.0.1:8080 0.0.0.0:*\n";
    expect(listeners(ss, 22) == std::vector<std::string>{"endlessh"}, "22: endlessh, and not 2222's line");
    expect(listeners(ss, 4022) == std::vector<std::string>{"sshd"}, "4022: sshd");
    expect(listeners(ss, 8080) == std::vector<std::string>{""}, "ss without root shows no owner");
    expect(listeners(ss, 2200).empty(), "nothing on 2200");

    expect(ports_to_write(4022, 0, {22}) == std::vector<int>{4022}, "from the console: the chosen port alone");
    expect((ports_to_write(4022, 22, {22}) == std::vector<int>{4022, 22}),
           "logged in on 22: sshd keeps 22 until a login on 4022");
    expect(ports_to_write(4022, 4022, {4022, 22}) == std::vector<int>{4022}, "re-run from a session on 4022 drops 22");
    expect(ports_to_write(4022, 2223, {22}) == std::vector<int>{4022}, "a session port sshd does not listen on: ignored");

    const auto keys_only = hardening_conf({4022}, true);
    const auto passwords = hardening_conf({4022}, false);
    expect(keys_only.find("Port 4022\n") != std::string::npos, "the drop-in names the port");
    expect(keys_only.find("PasswordAuthentication no\n") != std::string::npos
           && passwords.find("PasswordAuthentication yes\n") != std::string::npos, "keys only only when asked");
    expect(passwords.find("PermitRootLogin no\n") != std::string::npos, "and the hardening");
    const auto kept = hardening_conf({4022, 22}, false);
    expect(kept.find("Port 4022\nPort 22\n") != std::string::npos, "the chosen port first, the session's after");
    expect(listen_port(std::string("port ") + "4022\nport 22\n") == 4022, "so sshd -T's first port is the chosen one");
    // The text an earlier run wrote, byte for byte: a re-run with the same answers changes nothing.
    expect(passwords == "# FoxML SSH Hardening — generated by desk-install --ssh-harden\nPort 4022\nProtocol 2\n"
                        "PasswordAuthentication yes\nPubkeyAuthentication yes\nPermitRootLogin no\nMaxAuthTries 3\n"
                        "KbdInteractiveAuthentication no\nChallengeResponseAuthentication no\nLoginGraceTime 30\n"
                        "ClientAliveInterval 300\nClientAliveCountMax 2\n",
           "the single-port drop-in is the one earlier runs wrote");

    if (failures == 0) std::printf("test_ssh_port: ok\n");
    return failures == 0 ? 0 : 1;
}
