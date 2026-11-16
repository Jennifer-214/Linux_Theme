// modules/ssh_follow.hpp — what follows sshd's port (ssh_port::listen_ports). UFW rate-limits every port sshd listens
// on and closes the ports it left; 22 is open, as a plain allow, only while endlessh holds it. A port UFW denies
// (desk knock / desk spa's gate, or her own) or narrows is never opened. fail2ban's [sshd] jail bans on sshd's ports
// (`port = ssh` covered only 22, so bans never reached a moved sshd). endlessh takes 22 only when sshd is elsewhere.
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

// UFW's rules as its files keep them: one `### tuple ###` line per rule, `<action>[_log] <proto> <dport> <dst>
// <sport> <src> [<dapp> <sapp>] <direction>[_<iface>]`, a routed rule's action as `route:<action>`
// (ufw/backend_iptables.py, _write_rules and _read_rules). Read from the files, not `ufw status`, which lists nothing
// while UFW is off.
inline constexpr const char* kUserRules = "/etc/ufw/user.rules";
inline constexpr const char* kUser6Rules = "/etc/ufw/user6.rules";

struct Rule {
    std::string action, proto, dport, dst, sport, src, dir;
};

inline std::optional<Rule> tuple_rule(const std::string& line) {
    static const std::string tag = "### tuple ###";
    if (line.compare(0, tag.size(), tag) != 0) return std::nullopt;
    std::string rest = line.substr(tag.size());
    if (const auto c = rest.find(" comment="); c != std::string::npos) rest.erase(c);
    std::istringstream in(rest);
    std::vector<std::string> f;
    for (std::string w; in >> w;) f.push_back(w);
    if (f.size() < 6 || f.size() > 9) return std::nullopt;
    // 6 or 8 fields: ufw's old format, always inbound; 8 or 9: an application rule, its app names before the direction.
    return Rule{f[0], f[1], f[2], f[3], f[4], f[5], f.size() == 7 || f.size() == 9 ? f.back() : "in"};
}

// A dport field names `port`: "4022", a list "80,4022", a range "4000:5000". "any" names no one port.
inline bool names_port(const std::string& dport, int port) {
    std::istringstream in(dport);
    for (std::string item; std::getline(in, item, ',');) {
        const auto colon = item.find(':');
        if (colon == std::string::npos) {
            if (ssh_port::parse_port(item) == port) return true;
            continue;
        }
        const auto lo = ssh_port::parse_port(item.substr(0, colon)), hi = ssh_port::parse_port(item.substr(colon + 1));
        if (lo && hi && *lo <= port && port <= *hi) return true;
    }
    return false;
}

enum class Hold {
    None,      // no rule names the port: UFW's default (deny incoming) keeps it closed
    Open,      // plain allow or limit rules only: from anywhere, on any interface
    Denied,    // a deny or reject rule names it: desk knock / desk spa's gate, or her own
    Narrowed,  // an allow or limit for some addresses, one interface or a source port: her own
};

// What UFW's rules (the text of both files) hold for incoming TCP on `port`. Outgoing and routed rules, and rules for
// every port (`deny from <address>`), do not count.
inline Hold hold(const std::string& rules, int port) {
    const auto anywhere = [](const std::string& a) { return a == "0.0.0.0/0" || a == "::/0" || a == "any"; };
    Hold out = Hold::None;
    std::istringstream in(rules);
    for (std::string line; std::getline(in, line);) {
        const auto r = tuple_rule(line);
        if (!r || r->action.rfind("route:", 0) == 0) continue;
        if (r->dir != "in" && r->dir.rfind("in_", 0) != 0) continue;
        if ((r->proto != "tcp" && r->proto != "any") || !names_port(r->dport, port)) continue;
        const std::string action = r->action.substr(0, r->action.find('_'));
        if (action != "allow" && action != "limit") return Hold::Denied;
        if (anywhere(r->dst) && anywhere(r->src) && r->sport == "any" && r->dir == "in") {
            if (out == Hold::None) out = Hold::Open;
        } else {
            out = Hold::Narrowed;
        }
    }
    return out;
}

// A port this may open (rate-limit, or allow for the tarpit): one with no rule, or plain ones only. A deny is never
// loosened: `ufw limit` replaces a rule that differs only in its action, so it turned desk knock's `deny 4022/tcp`
// into a LIMIT that answers everyone (2026-11-16). A narrowed port is not opened to everyone either.
inline bool may_open(Hold h) { return h == Hold::None || h == Hold::Open; }

// Why a port was left as UFW has it, for the run's output.
inline std::string held(Hold h) {
    return h == Hold::Denied ? "a deny rule gates it (desk knock / desk spa, or your own)"
                             : "your rules let in only some addresses or one interface";
}

// The ports ssh_harden opens before sshd moves to them (`ports`; sshd is on `current` now): only those UFW holds no
// rule for. A failed move closes exactly these again, so it never deletes a rule that was there before the run; a
// port UFW allows plainly answers already, and a denied or narrowed one stays as it is.
inline std::vector<int> to_open(const std::vector<int>& ports, const std::vector<int>& current, const std::string& rules) {
    std::vector<int> out;
    for (int p : ports)
        if (!has(current, p) && hold(rules, p) == Hold::None) out.push_back(p);
    return out;
}

// UFW argv. `ports`: where sshd listens; `left`: ports it listened on before this change; `rules`: UFW's rules now.
// Each port sshd listens on is rate-limited while sshd runs (`sshd_on`), unless UFW denies or narrows it. A port it
// left is closed (its limit and allow rules deleted; a deny stays), and so is 22 whenever sshd is off it — unless
// endlessh holds 22, which gets a plain allow (a tarpit wants connections) where UFW does not deny it, or the SSH
// session this runs in came in on it. Nothing at all when sshd's ports are unknown (empty).
inline std::vector<Argv> ufw_commands(const std::vector<int>& ports, const std::vector<int>& left,
                                      bool endlessh_on_22, int session_port, bool sshd_on, const std::string& rules) {
    std::vector<Argv> out;
    if (ports.empty()) return out;
    if (sshd_on)
        for (int p : ports)
            if (may_open(hold(rules, p))) out.push_back({"sudo", "ufw", "limit", std::to_string(p) + "/tcp"});
    std::vector<int> closing = left;
    if (!has(closing, 22)) closing.push_back(22);
    for (int p : closing) {
        if (has(ports, p) || p == session_port) continue;
        if (p == 22 && endlessh_on_22) {
            if (may_open(hold(rules, 22))) out.push_back({"sudo", "ufw", "allow", "22/tcp"});
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

inline constexpr const char* kEndlesshConf = "/etc/endlessh/config";
inline constexpr const char* kEndlesshDropIn = "/etc/systemd/system/endlessh.service.d/foxml.conf";

// Why endlessh may not take 22 now; "" when it may. sshd's ports unknown, sshd on 22, or 22 held by another program.
inline std::string endlessh_blocked(const std::optional<std::vector<int>>& sshd_ports,
                                    const std::vector<std::string>& on_22) {
    if (!sshd_ports) return "couldn't read sshd's port (`sudo sshd -T` failed), so 22 is not taken blind";
    if (has(*sshd_ports, 22)) {
        if (sshd_ports->size() > 1)
            return "sshd still listens on 22, kept for the SSH session it was moved from: re-run --ssh-harden from a "
                   "session on " + std::to_string(sshd_ports->front()) + " (or the console), then --endlessh";
        return "sshd listens on 22, and the tarpit would take its port: move sshd first (--ssh-harden)";
    }
    for (const auto& who : on_22)
        if (who != "endlessh") return "port 22 is in use" + (who.empty() ? std::string() : " by " + who);
    return {};
}

// endlessh.service run with the installer's config. The AUR builds read /etc/endlessh.conf, a package file an upgrade
// puts back (Port 2222), so the /etc/endlessh/config this module wrote was never read and the tarpit sat on 2222.
// PrivateUsers=false: upstream's unit sets it true, which keeps a root service off ports below 1024.
inline std::string endlessh_dropin(const std::string& binary) {
    return std::string("# foxml-managed — endlessh reads the installer's ") + kEndlesshConf + " (Port 22).\n"
           "[Service]\n"
           "ExecStart=\n"
           "ExecStart=" + binary + " -f " + kEndlesshConf + "\n"
           "PrivateUsers=false\n";
}

// ssh_follow.cpp — one of UFW's rules files (`sudo -n cat`: the caller warmed sudo); nullopt when it cannot be read.
std::optional<std::string> read_rules(const char* path);
// Both, IPv4 then IPv6: what `hold` reads. nullopt when either cannot be read: then no port is opened blind.
std::optional<std::string> ufw_rules();

// Run ufw_commands, reading UFW's rules, sshd's state, this session's port and endlessh's hold on 22 live, and say
// what changed and what was left as it is. Each ufw command runs quietly: deleting a rule that is not there is not an
// error. Returns the ports it rate-limited.
std::vector<int> ufw(const std::vector<int>& ports, const std::vector<int>& left = {});

enum class Jail { Unchanged, Updated, Restored, Missing };
// jail.local's [sshd] port set to `ports`, checked with `fail2ban-client -t`; the previous file back when the check
// fails. The caller reloads fail2ban on Updated.
Jail fail2ban(const std::vector<int>& ports);

}  // namespace desk_install::ssh_follow
