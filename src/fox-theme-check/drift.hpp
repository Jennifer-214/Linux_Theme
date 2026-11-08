// drift.hpp — how a deployed file is compared with what the theme would ship now. Pure text, no I/O.
//
// Some files are meant to differ per machine; those differences are folded away before comparing:
//   Hyprlock  the per-monitor background block and brand splice (written at install), and `monitor =` pins;
//   Rules     a workspace pinned to a monitor (`monitor:eDP-1`, `monitor = "eDP-1"`);
//   Autostart the wallpaper mode flag (`--static`).
// Lines you added yourself keep a file "yours": every shipped line is still there, in order.
#pragma once

#include <sstream>
#include <string>
#include <vector>

namespace fox_theme_check {

enum class Kind { Plain, Hyprlock, Rules, Autostart };
enum class Verdict { Same, Yours, Drift };

inline std::vector<std::string> split_lines(const std::string& text) {
    std::vector<std::string> out;
    std::istringstream in(text);
    for (std::string line; std::getline(in, line);) {
        while (!line.empty() && (line.back() == ' ' || line.back() == '\t' || line.back() == '\r')) line.pop_back();
        out.push_back(line);
    }
    while (!out.empty() && out.back().empty()) out.pop_back();
    return out;
}

inline std::string erase_all(std::string line, const std::string& marker, char until) {
    for (std::size_t at; (at = line.find(marker)) != std::string::npos;) {
        std::size_t end = line.find(until, at + marker.size());
        end = end == std::string::npos ? line.size() : end + 1;
        while (end < line.size() && line[end] == ' ') ++end;
        line.erase(at, end - at);
    }
    return line;
}

inline std::vector<std::string> normalize(const std::string& text, Kind kind) {
    std::vector<std::string> out;
    bool skipping = false;
    for (auto line : split_lines(text)) {
        if (kind == Kind::Hyprlock) {
            if (line.find("# foxml:hyprlock-backgrounds-begin") != std::string::npos
                || line.find("# foxml:hyprlock-brand-begin") != std::string::npos) { skipping = true; continue; }
            if (line.find("# foxml:hyprlock-backgrounds-end") != std::string::npos
                || line.find("# foxml:hyprlock-brand-end") != std::string::npos) { skipping = false; continue; }
            if (skipping) continue;
            const auto first = line.find_first_not_of(" \t");
            if (first != std::string::npos && line.compare(first, 7, "monitor") == 0
                && line.find('=', first) != std::string::npos)
                line = line.substr(0, first) + "monitor =";
        } else if (kind == Kind::Rules) {
            line = erase_all(line, "monitor:", ',');
            line = erase_all(line, "monitor = \"", ',');
        } else if (kind == Kind::Autostart) {
            for (std::size_t at; (at = line.find("rotate_wallpaper.sh --static")) != std::string::npos;)
                line.erase(at + 19, 9);
        }
        out.push_back(line);
    }
    return out;
}

// Every shipped line appears in the live file, in the same order.
inline bool contains_in_order(const std::vector<std::string>& shipped, const std::vector<std::string>& live) {
    std::size_t at = 0;
    for (const auto& line : live)
        if (at < shipped.size() && line == shipped[at]) ++at;
    return at == shipped.size();
}

inline Verdict compare(const std::string& shipped, const std::string& live, Kind kind) {
    const auto a = normalize(shipped, kind), b = normalize(live, kind);
    if (a == b) return Verdict::Same;
    return contains_in_order(a, b) ? Verdict::Yours : Verdict::Drift;
}

}  // namespace fox_theme_check
