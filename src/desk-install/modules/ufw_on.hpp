// modules/ufw_on.hpp — whether `ufw enable` left the firewall on, and what to do when it did not. An install that
// upgrades the kernel (pacman -Syu) leaves the running kernel without its module tree until a reboot, so netfilter
// cannot load: `ufw enable` failed ("Could not fetch rule set generation id"), /etc/ufw/ufw.conf kept ENABLED=no, and
// the firewall stayed off after the reboot while the module said "UFW enabled" (the test VM, 2026-11-16). Pure, pinned
// by tests/test_ufw_on.
#pragma once

#include <optional>
#include <sstream>
#include <string>

namespace desk_install::ufw_on {

inline bool active(const std::string& ufw_status) { return ufw_status.find("Status: active") != std::string::npos; }

enum class Firewall { On, AtNextBoot, Off };

// After `ufw enable`: On when ufw says so. Not on while the running kernel has lost its modules (this run upgraded it):
// AtNextBoot, since its rules load at boot once ufw.conf says ENABLED=yes. Not on for any other reason: Off.
inline Firewall after_enable(const std::string& ufw_status, bool kernel_modules_present) {
    if (active(ufw_status)) return Firewall::On;
    return kernel_modules_present ? Firewall::Off : Firewall::AtNextBoot;
}

// UFW filters IPv6: /etc/default/ufw's IPV6 is yes, read as ufw reads it (a line starting with the word, the last one
// winning, any case, quotes dropped). With the file unreadable or the line missing, yes: ufw ships it so, and a wrong
// yes costs a firewall left off until a re-run, a wrong no an IPv6 login locked out.
inline bool ipv6_on(const std::string& defaults) {
    std::optional<std::string> value;
    std::istringstream in(defaults);
    for (std::string line; std::getline(in, line);) {
        const auto eq = line.find('=');
        if (eq == std::string::npos || eq == 0) continue;
        std::string key = line.substr(0, eq), v = line.substr(eq + 1);
        for (auto& c : key) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c);
        if (key != "ipv6") continue;
        while (!v.empty() && (v.back() == ' ' || v.back() == '\t' || v.back() == '\r')) v.pop_back();
        for (auto& c : v) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c);
        if (v.size() >= 2 && (v.front() == '"' || v.front() == '\'')) v = v.substr(1, v.size() - 2);
        value = v;
    }
    return !value || *value == "yes";
}

// ufw.conf with ENABLED=yes, the line ufw-init reads at boot; nullopt when it already says so or has no such line.
inline std::optional<std::string> enabled_at_boot(const std::string& conf) {
    std::istringstream in(conf);
    std::string out;
    bool seen = false, changed = false;
    for (std::string line; std::getline(in, line);) {
        if (line.rfind("ENABLED=", 0) == 0) {
            seen = true;
            if (line != "ENABLED=yes") {
                line = "ENABLED=yes";
                changed = true;
            }
        }
        out += line + "\n";
    }
    if (!seen || !changed) return std::nullopt;
    return out;
}

}  // namespace desk_install::ufw_on
