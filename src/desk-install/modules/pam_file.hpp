// modules/pam_file.hpp — the one way the installer edits a file under /etc/pam.d. The new text is built in memory;
// then a single root shell keeps a lasting backup (made once, so it stays the file from before the installer touched
// it), lays the text beside the file, renames it over in one step, compares it with what was built, and puts the
// previous file back on any difference. One shell does all of it, so putting the file back never waits on the PAM
// stack it is replacing. The pure parts are pinned by tests/test_pam_file.
#pragma once

#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <regex>
#include <sstream>
#include <string>

namespace desk_install::pam_file {

// How long pam_fprintd waits for a finger (its own default is 30 s): a reader nobody touches gives way to the
// password after this. A reader that is not there gives way at once, wait or not.
inline constexpr const char* kFprintdWait = "timeout=10";
inline constexpr const char* kFprintdLine = "auth      sufficient  pam_fprintd.so timeout=10";

// "#%PAM-1.0" after any leading blanks.
inline bool is_header(const std::string& line) {
    const auto at = line.find_first_not_of(" \t");
    return at != std::string::npos && line.compare(at, 9, "#%PAM-1.0") == 0;
}

inline bool is_fprintd_line(const std::string& line) {
    static const std::regex wired(R"(^\s*auth\s+(?:\[[^\]]*\]|\S+)\s+pam_fprintd\.so)");
    return std::regex_search(line, wired);
}

inline bool has_fprintd(const std::string& text) {
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line)) if (is_fprintd_line(line)) return true;
    return false;
}

// `text` with the fingerprint line right after its header. With no header: first when `prepend` (greetd), refused
// otherwise (sudo). Refused (nullopt) when pam_fprintd is already there. Every other line stays as it was.
inline std::optional<std::string> with_fprintd(const std::string& text, bool prepend) {
    if (has_fprintd(text)) return std::nullopt;
    std::istringstream in(text);
    std::string line, out;
    bool placed = false;
    while (std::getline(in, line)) {
        out += line + "\n";
        if (!placed && is_header(line)) { out += std::string(kFprintdLine) + "\n"; placed = true; }
    }
    if (placed) return out;
    if (!prepend) return std::nullopt;
    return std::string(kFprintdLine) + "\n" + out;
}

// Every pam_fprintd auth line without a timeout= gains kFprintdWait; nullopt when none needs it.
inline std::optional<std::string> with_fprintd_wait(const std::string& text) {
    std::istringstream in(text);
    std::string line, out;
    bool changed = false;
    while (std::getline(in, line)) {
        if (is_fprintd_line(line) && line.find("timeout=") == std::string::npos) {
            while (!line.empty() && (line.back() == ' ' || line.back() == '\t')) line.pop_back();
            line += std::string(" ") + kFprintdWait;
            changed = true;
        }
        out += line + "\n";
    }
    return changed ? std::optional<std::string>(out) : std::nullopt;
}

// Without its pam_fprintd auth lines; nullopt when it has none.
inline std::optional<std::string> without_fprintd(const std::string& text) {
    std::istringstream in(text);
    std::string line, out;
    bool changed = false;
    while (std::getline(in, line)) {
        if (is_fprintd_line(line)) { changed = true; continue; }
        out += line + "\n";
    }
    return changed ? std::optional<std::string>(out) : std::nullopt;
}

// Whether the stack's auth part includes `name` (auth include / substack name).
inline bool includes(const std::string& text, const std::string& name) {
    const std::regex pat("^\\s*auth\\s+(include|substack)\\s+" + name + "\\s*$");
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line)) if (std::regex_search(line, pat)) return true;
    return false;
}

// The lockout cascade (project_pam_fprintd_lockout): pam_fprintd's empty token is taken by pam_unix's
// `try_first_pass` and counted as a failed password against faillock. Every login stack here reaches system-auth.
inline bool try_first_pass_in(const std::string& system_auth) {
    static const std::regex pat(R"(^\s*auth\s+(?:\[[^\]]*\]|\S+)\s+pam_unix\.so[^\n]*\btry_first_pass\b)");
    std::istringstream in(system_auth);
    std::string line;
    while (std::getline(in, line)) if (std::regex_search(line, pat)) return true;
    return false;
}
inline bool system_auth_has_try_first_pass() {
    std::ifstream f("/etc/pam.d/system-auth");
    return try_first_pass_in(std::string(std::istreambuf_iterator<char>(f), {}));
}

// Run as root with $1 the PAM file and $2 a file holding the new text. Exit 0: in place and identical to $2; 3: it
// came out different and the previous file is back; anything else: the file was not replaced.
inline constexpr const char* kInstallScript = R"sh(set -eu
p=$1
new=$2
trap 'rm -f "$p.foxml-new" "$p.foxml-prev"' EXIT
[ -e "$p.foxml-bak" ] || cp -p "$p" "$p.foxml-bak"
cp -p "$p" "$p.foxml-prev"
cp "$new" "$p.foxml-new"
chmod 0644 "$p.foxml-new"
[ "$(id -u)" -ne 0 ] || chown 0:0 "$p.foxml-new"
mv -f "$p.foxml-new" "$p"
# sha256sum, not cmp: coreutils is in every Arch base, diffutils is not.
if [ "$(sha256sum < "$new")" != "$(sha256sum < "$p")" ]; then mv -f "$p.foxml-prev" "$p"; exit 3; fi
)sh";

// Replaces `path` with `text` through kInstallScript under sudo (warm the cache first). "" when done and read back
// as written; otherwise what went wrong, with the previous file in place.
std::string install(const std::filesystem::path& path, const std::string& text);

}  // namespace desk_install::pam_file
