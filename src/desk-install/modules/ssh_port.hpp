// modules/ssh_port.hpp — the one source for the SSH port: the ports sshd listens on, as `sshd -T` reports them.
// ssh_harden chooses the port; ufw, fail2ban and endlessh read it from here (desk knock and desk spa read the same
// through shared/bin/desk-ssh-port), so one chosen port is what everything follows. Parsing, the probes' argv and the
// drop-in text are pure; tests/test_ssh_port pins them. ssh_port.cpp holds the two reads that need root.
#pragma once

#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace desk_install::ssh_port {

inline bool has(const std::vector<int>& ports, int port) {
    for (int p : ports) if (p == port) return true;
    return false;
}

// 1..65535, digits only ("22; rm -rf /" and "+22" are not ports).
inline std::optional<int> parse_port(const std::string& s) {
    if (s.empty() || s.size() > 5) return std::nullopt;
    for (char c : s) if (c < '0' || c > '9') return std::nullopt;
    const int n = std::stoi(s);
    if (n < 1 || n > 65535) return std::nullopt;
    return n;
}

// A line's keyword, lower-cased: sshd's keywords are case-insensitive, and its dump changed case with OpenSSH 10
// (`port 22` before, `Port 22` from 10.x — 10.6 on Arch, 2026-11-16, where the lower-case match found no port at all).
inline std::string keyword(std::string key) {
    for (auto& c : key) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c);
    return key;
}

// The ports sshd listens on, from `sshd -T`: its ListenAddress lines (the sockets it binds, `0.0.0.0:2222`,
// `[::]:2222`), else its Port lines. In config order, each once; empty when the text has neither (sshd -T failed).
inline std::vector<int> listen_ports(const std::string& sshd_t) {
    std::vector<int> bound, configured;
    const auto add = [](std::vector<int>& v, int p) { if (!has(v, p)) v.push_back(p); };
    std::istringstream in(sshd_t);
    for (std::string line; std::getline(in, line);) {
        std::istringstream f(line);
        std::string key, value;
        if (!(f >> key >> value)) continue;
        key = keyword(key);
        if (key == "listenaddress") {
            const auto colon = value.rfind(':');
            if (colon == std::string::npos) continue;
            if (const auto p = parse_port(value.substr(colon + 1))) add(bound, *p);
        } else if (key == "port") {
            if (const auto p = parse_port(value)) add(configured, *p);
        }
    }
    return bound.empty() ? configured : bound;
}

// The first of them (the one ssh_harden chose: its drop-in is read before the rest of sshd_config); 22, sshd's
// default, when there is none.
inline int listen_port(const std::string& sshd_t) {
    const auto ports = listen_ports(sshd_t);
    return ports.empty() ? 22 : ports.front();
}

// What sshd does about passwords, whichever file set it: `PasswordAuthentication yes|no` in `sshd -T`.
inline std::optional<bool> password_auth(const std::string& sshd_t) {
    std::istringstream in(sshd_t);
    for (std::string line; std::getline(in, line);) {
        std::istringstream f(line);
        std::string key, value;
        if (f >> key >> value && keyword(key) == "passwordauthentication") {
            if (value == "yes") return true;
            if (value == "no") return false;
        }
    }
    return std::nullopt;
}

// The server port of the SSH session this runs in (SSH_CONNECTION is "<client ip> <client port> <server ip> <server
// port>"); 0 when there is none.
inline int session_port(const char* ssh_connection) {
    if (!ssh_connection) return 0;
    std::istringstream in(ssh_connection);
    std::string client, cport, server, sport;
    if (!(in >> client >> cport >> server >> sport)) return 0;
    const auto p = parse_port(sport);
    return p ? *p : 0;
}

inline std::string join(const std::vector<int>& ports, const char* sep) {
    std::string out;
    for (int p : ports) out += (out.empty() ? "" : sep) + std::to_string(p);
    return out;
}

// BatchMode, no password, publickey only: a 0 exit means a key authenticated, never a password or a keyboard prompt.
inline std::vector<std::string> key_test_argv(const std::string& user, int port) {
    return {"ssh", "-p", std::to_string(port), "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no",
            "-o", "PreferredAuthentications=publickey", "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new", user + "@127.0.0.1", "true"};
}

// sshd answering on a port, without logging in: its host keys.
inline std::vector<std::string> keyscan_argv(int port) {
    return {"ssh-keyscan", "-T", "5", "-p", std::to_string(port), "127.0.0.1"};
}
inline bool answered(const std::string& keyscan_out) {
    std::istringstream in(keyscan_out);
    for (std::string line; std::getline(in, line);) {
        std::istringstream f(line);
        std::string host, type;
        if (f >> host >> type && host[0] != '#' && (type.rfind("ssh-", 0) == 0 || type.rfind("ecdsa-", 0) == 0))
            return true;
    }
    return false;
}

// Who listens on a TCP port, from `ss -tlnpH`: one name per socket ("sshd", "endlessh"), "" when ss could not say
// (run without root it shows no owners).
inline std::vector<std::string> listeners(const std::string& ss_tlnp, int port) {
    std::vector<std::string> out;
    const std::string suffix = ":" + std::to_string(port);
    std::istringstream in(ss_tlnp);
    for (std::string line; std::getline(in, line);) {
        std::istringstream f(line);
        std::string state, recvq, sendq, local;
        if (!(f >> state >> recvq >> sendq >> local)) continue;
        if (local.size() <= suffix.size() || local.compare(local.size() - suffix.size(), suffix.size(), suffix) != 0)
            continue;
        std::string name;
        if (const auto at = line.find("((\""); at != std::string::npos) {
            const auto end = line.find('"', at + 3);
            if (end != std::string::npos) name = line.substr(at + 3, end - at - 3);
        }
        out.push_back(name);
    }
    return out;
}

// The ports ssh_harden writes: the chosen one first, then the port this SSH session came in on, when sshd listens on
// it now and the move would drop it. A remote admin keeps the way they are logged in until they have logged in on
// the new port; a re-run from that session (or the console) drops the old one.
inline std::vector<int> ports_to_write(int chosen, int session, const std::vector<int>& current) {
    std::vector<int> out{chosen};
    if (session > 0 && session != chosen && has(current, session)) out.push_back(session);
    return out;
}

inline constexpr const char* kDropIn = "/etc/ssh/sshd_config.d/50-foxml-hardening.conf";

// The drop-in ssh_harden writes. PasswordAuthentication no only when asked, and the caller asks only after a key
// has logged in on the port sshd listens on.
inline std::string hardening_conf(const std::vector<int>& ports, bool keys_only) {
    std::ostringstream body;
    body << "# FoxML SSH Hardening — generated by desk-install --ssh-harden\n";
    if (ports.size() > 1)
        body << "# The ports after the first are kept for the SSH session this was written from: a re-run from a\n"
                "# session on " << ports.front() << ", or from the console, drops them.\n";
    for (int p : ports) body << "Port " << p << "\n";
    body << "Protocol 2\n"
            "PasswordAuthentication " << (keys_only ? "no" : "yes") << "\n"
            "PubkeyAuthentication yes\n"
            "PermitRootLogin no\n"
            "MaxAuthTries 3\n"
            "KbdInteractiveAuthentication no\n"
            "ChallengeResponseAuthentication no\n"
            "LoginGraceTime 30\n"
            "ClientAliveInterval 300\n"
            "ClientAliveCountMax 2\n";
    return body.str();
}

// ssh_port.cpp: `sudo -n sshd -T` (false when it fails: sshd missing, its config does not parse, sudo cold).
bool sshd_t(std::string& out);
// The ports sshd listens on (listen_ports of sshd_t); nullopt when sshd -T fails or names none. Callers then leave
// SSH alone rather than guess.
std::optional<std::vector<int>> configured();
// Who listens on `port` now (listeners of `sudo -n ss -tlnpH`, or of plain `ss -tlnH`, owners unknown, without root).
std::vector<std::string> listeners_now(int port);

}  // namespace desk_install::ssh_port
