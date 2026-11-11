// modules/private_extras.hpp — the checks that decide whether the owner's private extras may run.
//
// The private_extras step runs ~/code/linux-theme-workspace/private-extras.sh, a script in the owner's private repo,
// only when all of these hold: the GitHub login is the owner, the checkout's origin is the owner's private
// linux-theme-workspace (and GitHub still serves it to this login), the commit about to run is on GitHub, the script
// is the committed one, and that commit is signed by the owner's key. Pure parsing here; the step does the asking.
#pragma once

#include <string>

namespace desk_install::private_extras {

// Public facts, safe to publish: the GitHub account and the fingerprint of its commit-signing key.
inline constexpr const char* OWNER = "Jennifer-214";
inline constexpr const char* OWNER_SIGNING_KEY = "7197A1F26A7DA15BBCB3DBD51B1217DD23B57785";
inline constexpr const char* WORKSPACE_REPO = "linux-theme-workspace";
inline constexpr const char* SCRIPT = "private-extras.sh";

inline std::string trim(std::string s) {
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ')) s.pop_back();
    const auto first = s.find_first_not_of(" \n");
    return first == std::string::npos ? std::string() : s.substr(first);
}

// git@github.com:OWNER/linux-theme-workspace(.git) or https://github.com/OWNER/linux-theme-workspace(.git)
inline bool origin_is_owners(const std::string& url) {
    const std::string tail = std::string(OWNER) + "/" + WORKSPACE_REPO;
    const auto u = trim(url);
    for (const std::string& head : {std::string("git@github.com:"), std::string("https://github.com/"),
                                    std::string("ssh://git@github.com/")})
        if (u == head + tail || u == head + tail + ".git") return true;
    return false;
}

// `git verify-commit --raw` status lines: a good signature whose primary-key or subkey fingerprint is the owner's.
// An expired or revoked key, a bad signature or another key all fail.
inline bool signed_by_owner(const std::string& raw) {
    bool good = false, ours = false;
    std::string::size_type at = 0;
    while (at < raw.size()) {
        auto end = raw.find('\n', at);
        if (end == std::string::npos) end = raw.size();
        const auto line = raw.substr(at, end - at);
        at = end + 1;
        if (line.rfind("[GNUPG:] GOODSIG ", 0) == 0) good = true;
        if (line.rfind("[GNUPG:] BADSIG ", 0) == 0 || line.rfind("[GNUPG:] EXPKEYSIG ", 0) == 0
            || line.rfind("[GNUPG:] REVKEYSIG ", 0) == 0 || line.rfind("[GNUPG:] ERRSIG ", 0) == 0) return false;
        if (line.rfind("[GNUPG:] VALIDSIG ", 0) == 0) {
            // VALIDSIG <signing fpr> <date> <ts> <expire> <ver> <rsv> <pk-algo> <hash> <class> <primary fpr>
            std::string rest = line.substr(std::string("[GNUPG:] VALIDSIG ").size()), word;
            int field = 0;
            std::string::size_type p = 0;
            while (p <= rest.size()) {
                const auto q = std::min(rest.find(' ', p), rest.size());
                word = rest.substr(p, q - p);
                if ((field == 0 || field == 9) && word == OWNER_SIGNING_KEY) ours = true;
                ++field;
                p = q + 1;
            }
        }
    }
    return good && ours;
}

}  // namespace desk_install::private_extras
