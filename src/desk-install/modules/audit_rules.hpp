// modules/audit_rules.hpp — security's edit of /etc/audit/rules.d/99-foxml.rules, in memory and pure, so
// tests/test_audit_rules pins it. Other tools add their own watches to the same file (desk-honey and desk-sentry-audit
// append foxml_honey lines), so the installer replaces only its own block and keeps every other line. Its block sits
// between kBegin and kEnd; a file from before the markers is read by the installer's exact lines (kLegacy).
#pragma once

#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace desk_install::audit_rules {

inline constexpr const char* kBegin = "# >>> foxml-managed: desk-install --secure rewrites this block; lines outside it are kept >>>";
inline constexpr const char* kEnd = "# <<< foxml-managed <<<";

inline constexpr const char* kWatches =
    "# Watches credential + sshd config files for modifications.\n"
    "-w /etc/passwd -p wa -k passwd_changes\n"
    "-w /etc/shadow -p wa -k shadow_changes\n"
    "-w /etc/ssh/sshd_config -p wa -k sshd_config_changes\n"
    "-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config_changes\n"
    "-w /etc/sudoers -p wa -k sudoers_changes\n"
    "-w /etc/sudoers.d/ -p wa -k sudoers_changes\n";

// The whole file the installer wrote before the markers: its header line, then kWatches.
inline constexpr const char* kLegacyHeader = "# foxml-managed — auto-applied by desk-install --secure.";

inline std::string block() { return std::string(kBegin) + "\n" + kWatches + kEnd + "\n"; }

inline std::vector<std::string> lines_of(const std::string& text) {
    std::istringstream in(text);
    std::vector<std::string> out;
    for (std::string line; std::getline(in, line);) out.push_back(line);
    return out;
}

inline bool is_own_line(const std::string& line) {
    if (line == kBegin || line == kEnd || line == kLegacyHeader) return true;
    for (const auto& own : lines_of(kWatches)) if (line == own) return true;
    return false;
}

// `existing` with the installer's block replaced: the lines between the markers and any of the installer's exact
// lines elsewhere go, and one block takes the place of the first of them (appended when there is none). Every other
// line stays in its order; an exact repeat of a non-empty line is dropped, since auditctl refuses a rule that exists
// and audit-rules.service then fails at boot. Applied to its own output it changes nothing.
inline std::string merged(const std::string& existing) {
    const auto lines = lines_of(existing);
    std::size_t begin = lines.size(), end = lines.size();
    for (std::size_t i = 0; i < lines.size(); ++i) {
        if (begin == lines.size() && lines[i] == kBegin) begin = i;
        else if (begin != lines.size() && lines[i] == kEnd) { end = i; break; }
    }
    if (end == lines.size()) begin = lines.size();  // no closed block: only exact own lines count

    std::string out;
    bool placed = false;
    std::set<std::string> seen;
    for (std::size_t i = 0; i < lines.size(); ++i) {
        const bool own = (i >= begin && i <= end) || is_own_line(lines[i]);
        if (own) {
            if (!placed) { out += block(); placed = true; }
            continue;
        }
        if (!lines[i].empty() && !seen.insert(lines[i]).second) continue;
        out += lines[i] + "\n";
    }
    if (!placed) out += block();
    return out;
}

}  // namespace desk_install::audit_rules
