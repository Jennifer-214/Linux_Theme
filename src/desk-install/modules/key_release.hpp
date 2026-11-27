// modules/key_release.hpp — which machines get the ThinkPad SysRq release rule, and whether the kernel applies it.

#pragma once

#include <cctype>
#include <cstdlib>
#include <sstream>
#include <string>

namespace desk_install::key_release {

inline const char* const RULE = "61-desk-key-release.hwdb";
inline const char* const RULE_DIR = "/etc/udev/hwdb.d";
inline const int SYSRQ_SCAN = 0x54;

// /sys/class/dmi/id/sys_vendor and product_version, as read (with their newline).
inline bool is_thinkpad(const std::string& vendor, const std::string& version) {
    return vendor.rfind("LENOVO", 0) == 0 && version.rfind("ThinkPad", 0) == 0;
}

// An atkbd serio's force_release attribute: decimal codes and ranges, "84,369-370".
inline bool releases(const std::string& attr, int code) {
    std::stringstream list(attr);
    for (std::string part; std::getline(list, part, ',');) {
        if (part.empty() || !std::isdigit(static_cast<unsigned char>(part[0]))) continue;
        const auto dash = part.find('-');
        const long lo = std::strtol(part.c_str(), nullptr, 10);
        const long hi = dash == std::string::npos ? lo : std::strtol(part.c_str() + dash + 1, nullptr, 10);
        if (code >= lo && code <= hi) return true;
    }
    return false;
}

}  // namespace desk_install::key_release
