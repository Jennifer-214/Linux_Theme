// modules/hidepid_check.hpp — is /proc's hidepid already in place, so run_hidepid must not touch it?
// Pure (text in, answer out) so tests/test_hidepid pins it. Installer audit 2026-10-15: the module grepped /proc/mounts
// for "hidepid=2", but kernels since 5.8 print the name (hers: "gid=26,hidepid=invisible"), so it never matched and
// every run rewrote the unit with UNIT_BODY, dropping the bash installer's newer gid=proc.
#pragma once

#include <sstream>
#include <string>

namespace fox_install {

// The hidepid value on the live /proc when it hides other users' processes, else "". docs.kernel.org/filesystems/proc:
// "hidepid=invisible or hidepid=2" hides them; "hidepid=ptraceable or hidepid=4" shows only what the caller can ptrace,
// stricter still. Older kernels print the number, 5.8+ the name. The last /proc line wins (it's the one on top).
inline std::string live_hidepid(const std::string& proc_mounts) {
    std::istringstream lines(proc_mounts);
    std::string line, found;
    while (std::getline(lines, line)) {
        std::istringstream f(line);
        std::string dev, mnt, type, opts;
        if (!(f >> dev >> mnt >> type >> opts) || mnt != "/proc" || type != "proc") continue;
        found.clear();
        std::istringstream o(opts);
        for (std::string opt; std::getline(o, opt, ',');) {
            if (opt.rfind("hidepid=", 0) != 0) continue;
            const std::string v = opt.substr(8);
            if (v == "2" || v == "invisible" || v == "4" || v == "ptraceable") found = v;
        }
    }
    return found;
}

// foxml's unit in the bash installer's newer form: the sentinel, and an ExecStart remounting /proc with hidepid and
// gid= (gid=proc, for polkit and logind). Newer than run_hidepid's UNIT_BODY, so it must not be rewritten.
inline bool is_newer_foxml_hidepid_unit(const std::string& unit_text) {
    if (unit_text.find("# foxml-managed") == std::string::npos) return false;
    std::istringstream lines(unit_text);
    for (std::string line; std::getline(lines, line);) {
        if (line.rfind("ExecStart=", 0) == 0 && line.find("remount") != std::string::npos &&
            line.find("hidepid=") != std::string::npos && line.find("gid=") != std::string::npos) {
            return true;
        }
    }
    return false;
}

}  // namespace fox_install
