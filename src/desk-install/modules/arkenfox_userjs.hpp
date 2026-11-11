#pragma once
// arkenfox's user.js, and what has to survive it. Firefox reads user.js alone and never opens user-overrides.js, so
// the overrides are copied in after arkenfox (later lines win), and the lines other steps wrote there before
// (stylesheets, vertical tabs, find colours) follow them.

#include <string>

namespace desk_install::arkenfox {

inline constexpr const char* NAME_MARK = "arkenfox user.js";
inline constexpr const char* LAST_LINE = "\"_user.js.parrot\", \"SUCCESS";
inline constexpr const char* OVERRIDES_BEGIN = "// >>> FoxML: user-overrides.js";
inline constexpr const char* OVERRIDES_END = "// <<< FoxML: user-overrides.js";

inline bool is_arkenfox(const std::string& body) { return body.find(NAME_MARK) != std::string::npos; }

inline bool has_overrides(const std::string& body) {
    const auto begin = body.find(OVERRIDES_BEGIN);
    return begin != std::string::npos && body.find(OVERRIDES_END, begin) != std::string::npos;
}

// arkenfox's own text, through its last line; empty when it is missing or cut off.
inline std::string arkenfox_part(const std::string& body) {
    if (!is_arkenfox(body)) return {};
    const auto last = body.find(LAST_LINE);
    if (last == std::string::npos) return {};
    const auto nl = body.find('\n', last);
    return nl == std::string::npos ? body + "\n" : body.substr(0, nl + 1);
}

// A download is installed only when it names itself and reaches arkenfox's last line.
inline bool complete(const std::string& download) { return !arkenfox_part(download).empty(); }

// What an old user.js carries forward: all of it before arkenfox arrived, else what follows the overrides block,
// else what follows arkenfox's last line (the layout before overrides were copied in).
inline std::string carried(const std::string& old) {
    if (!is_arkenfox(old)) return old;
    std::string rest;
    if (const auto end = old.rfind(OVERRIDES_END); end != std::string::npos) {
        const auto nl = old.find('\n', end);
        if (nl != std::string::npos) rest = old.substr(nl + 1);
    } else if (const auto part = arkenfox_part(old); !part.empty()) {
        rest = old.substr(part.size());
    }
    return rest;
}

inline std::string compose(const std::string& download, const std::string& overrides, const std::string& old) {
    std::string out = arkenfox_part(download);
    out += "\n";
    out += OVERRIDES_BEGIN;
    out += "\n";
    out += overrides;
    if (!overrides.empty() && overrides.back() != '\n') out += "\n";
    out += OVERRIDES_END;
    out += "\n";
    std::string rest = carried(old);
    rest.erase(0, rest.find_first_not_of('\n') == std::string::npos ? rest.size() : rest.find_first_not_of('\n'));
    if (!rest.empty()) out += "\n" + rest;
    return out;
}

}  // namespace desk_install::arkenfox
