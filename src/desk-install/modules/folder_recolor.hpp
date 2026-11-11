// modules/folder_recolor.hpp — derive a Papirus folder colour the upstream set
// doesn't have. A palette names a base colour and the hex swaps to make from it:
//     PAPIRUS_FOLDER_RECOLOR=base:RRGGBB=rrggbb,RRGGBB=rrggbb   (or "none")
// The result sits beside the stock colours, so papirus-folders can select it.

#ifndef FOX_INSTALL_MODULES_FOLDER_RECOLOR_HPP
#define FOX_INSTALL_MODULES_FOLDER_RECOLOR_HPP

#include "cursor_recolor.hpp"

#include <cctype>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

namespace desk_install::folder_recolor {

namespace fs = std::filesystem;

struct Recolor {
    std::string base;
    std::vector<std::pair<std::string, std::string>> swaps;  // lowercase, no '#'
};

inline std::string lower(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

inline std::optional<Recolor> parse(const std::string& token) {
    const auto colon = token.find(':');
    if (colon == std::string::npos || colon == 0) return std::nullopt;
    Recolor out;
    out.base = token.substr(0, colon);
    if (out.base.find('/') != std::string::npos || out.base.find("..") != std::string::npos)
        return std::nullopt;

    size_t start = colon + 1;
    while (start <= token.size()) {
        const auto comma = token.find(',', start);
        const std::string pair = token.substr(start, comma == std::string::npos ? comma : comma - start);
        const auto eq = pair.find('=');
        if (eq == std::string::npos) return std::nullopt;
        const std::string from = pair.substr(0, eq), to = pair.substr(eq + 1);
        if (!cursor_recolor::parse_hex(from) || !cursor_recolor::parse_hex(to)) return std::nullopt;
        out.swaps.emplace_back(lower(from), lower(to));
        if (comma == std::string::npos) break;
        start = comma + 1;
    }
    return out;
}

// One pass over the text, so a swap's output is never swapped again.
inline std::string repaint(const std::string& svg, const Recolor& rc) {
    std::string out;
    out.reserve(svg.size());
    for (size_t i = 0; i < svg.size();) {
        if (svg[i] == '#' && i + 7 <= svg.size()) {
            const std::string hex = lower(svg.substr(i + 1, 6));
            bool swapped = false;
            for (const auto& [from, to] : rc.swaps) {
                if (hex != from) continue;
                out += '#';
                out += to;
                i += 7;
                swapped = true;
                break;
            }
            if (swapped) continue;
        }
        out += svg[i++];
    }
    return out;
}

// Writes the new colour's icons into `stage`, laid out like `papirus` so it can
// be copied straight over the theme. False if the base has nothing to work from.
inline bool build(const fs::path& papirus, const fs::path& stage, const std::string& color,
                  const Recolor& rc) {
    size_t written = 0;
    for (const char* size : {"22x22", "24x24", "32x32", "48x48", "64x64"}) {
        const fs::path places = papirus / size / "places";
        std::error_code ec;
        for (const auto& entry : fs::directory_iterator(places, ec)) {
            const std::string name = entry.path().filename().string();
            std::string renamed;
            for (const std::string prefix : {"folder-", "user-"}) {
                const std::string stem = prefix + rc.base;
                if (name.rfind(stem + "-", 0) == 0 || name == stem + ".svg")
                    renamed = prefix + color + name.substr(stem.size());
            }
            if (renamed.empty() || entry.is_symlink()) continue;

            const fs::path dest = stage / size / "places";
            fs::create_directories(dest, ec);
            if (ec) return false;
            const std::string svg = repaint(cursor_recolor::read_file(entry.path()), rc);
            std::ofstream out(dest / renamed, std::ios::binary);
            out << svg;
            out.close();
            if (!out) return false;
            ++written;
        }
    }
    return written > 0;
}

// What the applied-colour marker records, so changing the swaps re-runs the module.
inline std::string mark(const std::string& color, const std::string& token) {
    return token == "none" ? color : color + "|" + token;
}

}  // namespace desk_install::folder_recolor

#endif
