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
