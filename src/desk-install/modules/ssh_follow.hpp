// modules/ssh_follow.hpp — what follows sshd's port (ssh_port::listen_ports). UFW rate-limits every port sshd listens
// on and closes the ports it left; 22 is open, as a plain allow, only while endlessh holds it. fail2ban's [sshd] jail
// bans on sshd's ports (`port = ssh` covered only 22, so bans never reached a moved sshd).
// The plans and the text edit are pure, pinned by tests/test_ssh_follow; ssh_follow.cpp runs them.
#pragma once

#include "ssh_port.hpp"

#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace desk_install::ssh_follow {

using Argv = std::vector<std::string>;
using ssh_port::has;

// UFW argv. `ports`: where sshd listens; `left`: ports it listened on before this change. Each port sshd listens on
// is rate-limited while sshd runs (`sshd_on`). A port it left is closed (its limit and allow rules deleted), and so is
// 22 whenever sshd is off it — unless endlessh holds 22, which gets a plain allow (a tarpit wants connections), or
// the SSH session this runs in came in on it. Nothing at all when sshd's ports are unknown (empty).
inline std::vector<Argv> ufw_commands(const std::vector<int>& ports, const std::vector<int>& left,
                                      bool endlessh_on_22, int session_port, bool sshd_on) {
    std::vector<Argv> out;
    if (ports.empty()) return out;
    if (sshd_on)
        for (int p : ports) out.push_back({"sudo", "ufw", "limit", std::to_string(p) + "/tcp"});
    std::vector<int> closing = left;
    if (!has(closing, 22)) closing.push_back(22);
    for (int p : closing) {
        if (has(ports, p) || p == session_port) continue;
        if (p == 22 && endlessh_on_22) {
            out.push_back({"sudo", "ufw", "allow", "22/tcp"});
            continue;
        }
        for (const char* action : {"limit", "allow"}) {
            out.push_back({"sudo", "ufw", "delete", action, std::to_string(p) + "/tcp"});
            // `ufw limit ssh` made a rule for 22 on any protocol: /etc/services lists ssh for udp too.
            if (p == 22) out.push_back({"sudo", "ufw", "delete", action, "22"});
        }
    }
    return out;
}

inline std::string trim(const std::string& s) {
    const auto a = s.find_first_not_of(" \t\r");
    if (a == std::string::npos) return {};
    const auto b = s.find_last_not_of(" \t\r");
    return s.substr(a, b - a + 1);
}

// The key of a `key = value` (or `key: value`) line, lower-cased as fail2ban's parser reads it; "" for a comment, a
// continuation line or a line with no key.
inline std::string key_of(const std::string& line) {
    if (line.empty() || line[0] == ' ' || line[0] == '\t' || line[0] == '#' || line[0] == ';') return {};
    const auto eq = line.find_first_of("=:");
    if (eq == std::string::npos) return {};
    std::string key = trim(line.substr(0, eq));
    for (auto& c : key) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c);
    return key;
}

// The ports a jail's `port =` value names ("ssh" is 22); nullopt for anything else (a range, another service).
inline std::optional<std::vector<int>> jail_ports(const std::string& value) {
    std::vector<int> out;
    std::istringstream in(value);
    for (std::string item; std::getline(in, item, ',');) {
        item = trim(item);
        if (item.empty()) continue;
        if (item == "ssh") {
            if (!has(out, 22)) out.push_back(22);
            continue;
        }
        const auto p = ssh_port::parse_port(item);
        if (!p) return std::nullopt;
        if (!has(out, *p)) out.push_back(*p);
    }
    return out;
}

inline bool same_ports(const std::vector<int>& a, const std::vector<int>& b) {
    if (a.size() != b.size()) return false;
    for (int p : a) if (!has(b, p)) return false;
    return true;
}

// A new jail.local, its [sshd] jail on `port` (ssh_port::join of sshd's ports; "ssh" when they are unknown).
// ignoreip starts at localhost; run over SSH (`ssh_connection`, SSH_CONNECTION) it adds the admin's own source IP, so
// a fumbled password during the install cannot ban them out of a headless box — only a plain IPv4/IPv6 literal,
// never arbitrary text.
inline std::string jail_local(const std::string& port, const char* ssh_connection) {
    std::string ignore = "127.0.0.1/8 ::1";
    if (ssh_connection && *ssh_connection) {
        std::istringstream is(ssh_connection);
        std::string client_ip;
        is >> client_ip;
        if (!client_ip.empty() && client_ip.find_first_not_of("0123456789abcdefABCDEF.:") == std::string::npos)
            ignore += " " + client_ip;
    }
    return "# foxml-managed — auto-applied by desk-install --secure.\n"
           "# Delete this file to revert to the stock fail2ban defaults.\n"
           "[DEFAULT]\n"
           "bantime  = 1h\n"
           "findtime = 10m\n"
           "maxretry = 5\n"
           "backend  = systemd\n"
           "ignoreip = " + ignore + "\n\n"
           "[sshd]\n"
           "enabled  = true\n"
           "port     = " + port + "\n"
           "filter   = sshd\n"
           "journalmatch = _SYSTEMD_UNIT=sshd.service\n";
}

// jail.local with its [sshd] section banning on `ports`: the port line's value replaced (one added at the end of the
// section when it has none), every other line as it was — dispatch_hooks' action lines included. nullopt when there
// is no [sshd] section, no ports, or the port line already names exactly those ports.
inline std::optional<std::string> jail_with_ports(const std::string& jail, const std::vector<int>& ports) {
    if (ports.empty()) return std::nullopt;
    const std::string value = ssh_port::join(ports, ",");
    std::istringstream in(jail);
    std::string out, section;
    bool found = false, done = false, changed = false;
    for (std::string line; std::getline(in, line);) {
        const std::string t = trim(line);
        if (t.size() >= 2 && t.front() == '[' && t.back() == ']') {
            if (section == "sshd" && !done) {
                out += "port     = " + value + "\n";
                done = changed = true;
            }
            section = t.substr(1, t.size() - 2);
            found |= section == "sshd";
            out += line + "\n";
            continue;
        }
        if (section == "sshd" && !done && key_of(line) == "port") {
            done = true;
            const auto eq = line.find_first_of("=:");
            const auto named = jail_ports(line.substr(eq + 1));
            if (named && same_ports(*named, ports)) {
                out += line + "\n";
            } else {
                out += line.substr(0, eq + 1) + " " + value + "\n";
                changed = true;
            }
            continue;
        }
        out += line + "\n";
    }
    if (section == "sshd" && !done) {
        out += "port     = " + value + "\n";
        changed = true;
    }
    if (!found || !changed) return std::nullopt;
    return out;
}

// ssh_follow.cpp — run them, reading sshd's state, this session's port and endlessh's hold on 22 live, and say what
// changed. Each ufw command runs quietly: deleting a rule that is not there is not an error.
void ufw(const std::vector<int>& ports, const std::vector<int>& left = {});

enum class Jail { Unchanged, Updated, Restored, Missing };
// jail.local's [sshd] port set to `ports`, checked with `fail2ban-client -t`; the previous file back when the check
// fails. The caller reloads fail2ban on Updated.
Jail fail2ban(const std::vector<int>& ports);

}  // namespace desk_install::ssh_follow
