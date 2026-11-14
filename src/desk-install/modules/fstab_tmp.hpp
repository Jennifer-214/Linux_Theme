// modules/fstab_tmp.hpp — noexec_tmp's reading and editing of /etc/fstab, in memory and pure, so tests/test_fstab_tmp
// pins it. The /tmp entry is found by its mount point (the second field of an uncommented line): a tmpfs there is
// locked down in place, a partition of its own is left alone (a second /tmp line used to be appended beside it), and
// with none a tmpfs line is appended on a line of its own. The candidate is checked with `findmnt --verify
// --tab-file` before it replaces fstab; only an error the candidate adds counts, so an fstab that already had a
// warning is still checked.
#pragma once

#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace desk_install::fstab_tmp {

inline constexpr const char* kTmpLine = "tmpfs   /tmp        tmpfs   defaults,noexec,nosuid,nodev,size=4G  0 0";

enum class TmpKind { None, Tmpfs, Partition };

inline std::vector<std::string> fields(const std::string& line) {
    std::istringstream in(line);
    std::vector<std::string> out;
    for (std::string f; in >> f;) out.push_back(f);
    return out;
}
inline bool is_tmp_entry(const std::string& line) {
    const auto f = fields(line);
    return f.size() >= 3 && f[0][0] != '#' && f[1] == "/tmp";
}

inline TmpKind tmp_kind(const std::string& fstab) {
    std::istringstream in(fstab);
    for (std::string line; std::getline(in, line);)
        if (is_tmp_entry(line)) return fields(line)[2] == "tmpfs" ? TmpKind::Tmpfs : TmpKind::Partition;
    return TmpKind::None;
}

inline bool has_option(const std::string& options, const std::string& name) {
    std::istringstream in(options);
    for (std::string o; std::getline(in, o, ',');) if (o == name) return true;
    return false;
}

// The /tmp entry carries noexec, nosuid and nodev as options of their own.
inline bool locked_down(const std::string& fstab) {
    std::istringstream in(fstab);
    for (std::string line; std::getline(in, line);) {
        if (!is_tmp_entry(line)) continue;
        const auto f = fields(line);
        return f.size() >= 4 && has_option(f[3], "noexec") && has_option(f[3], "nosuid") && has_option(f[3], "nodev");
    }
    return false;
}

// fstab with /tmp locked down: a tmpfs entry gains the options it lacks (the rest of the line as it was), none gets
// kTmpLine on a line of its own. nullopt when there is nothing to do, or /tmp is a partition of its own.
inline std::optional<std::string> with_tmp_locked(const std::string& fstab) {
    const auto kind = tmp_kind(fstab);
    if (kind == TmpKind::Partition || locked_down(fstab)) return std::nullopt;
    if (kind == TmpKind::None) {
        std::string out = fstab;
        if (!out.empty() && out.back() != '\n') out += '\n';
        return out + kTmpLine + "\n";
    }
    std::istringstream in(fstab);
    std::string out;
    bool done = false;
    for (std::string line; std::getline(in, line);) {
        if (!done && is_tmp_entry(line)) {
            done = true;
            // The fourth field's place in the line: replaced alone, so spacing and the dump/pass fields stay.
            std::size_t at = 0;
            for (int field = 0; field < 3; ++field) {
                at = line.find_first_not_of(" \t", at);
                at = line.find_first_of(" \t", at);
            }
            const auto start = line.find_first_not_of(" \t", at);
            if (start != std::string::npos) {
                const auto end = std::min(line.find_first_of(" \t", start), line.size());
                std::string options = line.substr(start, end - start);
                for (const char* name : {"noexec", "nosuid", "nodev"}) if (!has_option(options, name)) options += std::string(",") + name;
                line = line.substr(0, start) + options + line.substr(end);
            } else {
                line += " defaults,noexec,nosuid,nodev";
            }
        }
        out += line + "\n";
    }
    return out;
}

// The errors in `findmnt --verify` output, each as "mount point: message" (findmnt prints the mount point, then its
// problems indented under it), so an error the candidate adds can be told from one fstab already had.
inline std::set<std::string> verify_errors(const std::string& output) {
    std::set<std::string> out;
    std::istringstream in(output);
    std::string target;
    for (std::string line; std::getline(in, line);) {
        if (line.empty()) continue;
        if (line[0] != ' ' && line[0] != '\t') { target = line; continue; }
        const auto e = line.find("[E]");
        if (e != std::string::npos) out.insert(target + ": " + line.substr(e));
    }
    return out;
}

}  // namespace desk_install::fstab_tmp
