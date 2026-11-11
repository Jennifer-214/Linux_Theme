#ifndef FOX_MONITOR_PLACEMENT_HPP
#define FOX_MONITOR_PLACEMENT_HPP
// Where each screen goes, from its mode, scale, rotation and side of an anchor, plus the
// monitor-rule edits that write it. The install wizard and the drawer's Displays page share
// this, so a scale or rotation change always moves the screens with it (a 1.5 → 1.25 change
// once left a portrait screen overlapping the laptop). Header-only and pure.

#include <cmath>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

namespace desk_monitor::placement {

struct Screen {
    std::string name;
    int width = 0, height = 0;   // the mode, before rotation
    int scale_x100 = 100;
    int transform = 0;           // Hyprland transform; 1, 3, 5 and 7 turn the screen sideways
    std::string side = "right";  // left | right | above | below; unused for the primary
    std::string anchor;          // a screen placed earlier; empty means the primary
};
struct Box { int x = 0, y = 0, w = 0, h = 0; };

inline bool sideways(int transform) { return transform % 2 == 1; }

inline Box logical(const Screen& s) {
    const int w = sideways(s.transform) ? s.height : s.width;
    const int h = sideways(s.transform) ? s.width : s.height;
    const int scale = s.scale_x100 > 0 ? s.scale_x100 : 100;
    return {0, 0, w * 100 / scale, h * 100 / scale};
}

// b's size, moved to touch a on that side, centred along the shared edge.
inline Box beside(const Box& a, Box b, const std::string& side) {
    if (side == "left")       { b.x = a.x - b.w;            b.y = a.y + (a.h - b.h) / 2; }
    else if (side == "above") { b.x = a.x + (a.w - b.w) / 2; b.y = a.y - b.h; }
    else if (side == "below") { b.x = a.x + (a.w - b.w) / 2; b.y = a.y + a.h; }
    else                      { b.x = a.x + a.w;            b.y = a.y + (a.h - b.h) / 2; }
    return b;
}

// The primary sits at 0x0; every other screen, in order, beside its anchor.
inline std::map<std::string, Box> place(const Screen& primary, const std::vector<Screen>& others) {
    std::map<std::string, Box> out;
    out[primary.name] = logical(primary);
    for (const auto& s : others) {
        const auto anchor = out.find(s.anchor.empty() ? primary.name : s.anchor);
        out[s.name] = beside(anchor == out.end() ? out[primary.name] : anchor->second, logical(s), s.side);
    }
    return out;
}

// Which side of a the live screen b is on.
inline std::string side_of(const Box& a, const Box& b) {
    if (b.x + b.w <= a.x) return "left";
    if (b.x >= a.x + a.w) return "right";
    if (b.y + b.h <= a.y) return "above";
    return "below";
}

// Scales that divide the mode evenly both ways, so Hyprland shows them without adjusting.
inline std::vector<int> scales_for(int width, int height) {
    static const int steps[] = {50, 75, 80, 100, 120, 125, 150, 160, 175, 200, 250, 300};
    std::vector<int> out;
    for (int s : steps)
        if (width > 0 && height > 0 && (width * 100) % s == 0 && (height * 100) % s == 0) out.push_back(s);
    return out;
}

inline int to_x100(double scale) { return static_cast<int>(std::lround(scale * 100)); }

inline std::string scale_text(int x100) {
    std::string out = std::to_string(x100 / 100);
    if (x100 % 100 == 0) return out;
    const int rest = x100 % 100;
    return out + "." + (rest % 10 == 0 ? std::to_string(rest / 10) : (rest < 10 ? "0" : "") + std::to_string(rest));
}

inline std::string position_text(const Box& b) { return std::to_string(b.x) + "x" + std::to_string(b.y); }

namespace detail {
inline std::string trim(const std::string& s) {
    const auto a = s.find_first_not_of(" \t"), b = s.find_last_not_of(" \t");
    return a == std::string::npos ? std::string() : s.substr(a, b - a + 1);
}
inline std::vector<std::string> lines(const std::string& text) {
    std::vector<std::string> out;
    std::stringstream in(text);
    for (std::string line; std::getline(in, line);) out.push_back(line);
    return out;
}
inline std::string join(const std::vector<std::string>& lines) {
    std::string out;
    for (const auto& line : lines) out += line + "\n";
    return out;
}
// Index to insert a new rule at: before the catch-all and the comment just above it, else the end.
inline size_t insert_at(const std::vector<std::string>& lines, const std::regex& catch_all, const std::string& comment) {
    for (size_t i = 0; i < lines.size(); ++i) {
        if (!std::regex_search(lines[i], catch_all)) continue;
        return i > 0 && trim(lines[i - 1]).rfind(comment, 0) == 0 ? i - 1 : i;
    }
    return lines.size();
}
}  // namespace detail

// monitors.conf: NAME's `monitor =` line gets this position, scale and rotation, and the mode when one is
// given ("2560x1440@59.95"); any other options stay. A screen with no line gets one before the catch-all.
inline std::string set_conf_rule(const std::string& conf, const std::string& name, const std::string& position,
                                 const std::string& scale, int transform, const std::string& mode = {}) {
    static const std::regex rule(R"(^\s*monitor\s*=\s*(.*)$)");
    auto lines = detail::lines(conf);
    bool found = false;
    for (auto& line : lines) {
        std::smatch m;
        if (!std::regex_match(line, m, rule)) continue;
        std::vector<std::string> f;
        std::stringstream fields(m[1].str());
        for (std::string part; std::getline(fields, part, ',');) f.push_back(detail::trim(part));
        if (f.empty() || f[0] != name || f.size() < 4) continue;
        std::vector<std::string> out{f[0], mode.empty() ? f[1] : mode, position, scale};
        if (transform != 0) { out.push_back("transform"); out.push_back(std::to_string(transform)); }
        for (size_t i = 4; i < f.size(); ++i) {
            if (f[i] == "transform" && i + 1 < f.size()) { ++i; continue; }
            out.push_back(f[i]);
        }
        line = "monitor = " + out[0];
        for (size_t i = 1; i < out.size(); ++i) line += ", " + out[i];
        found = true;
    }
    if (!found) {
        std::string line = "monitor = " + name + ", " + (mode.empty() ? "preferred" : mode) + ", " + position + ", " + scale;
        if (transform != 0) line += ", transform, " + std::to_string(transform);
        const auto at = detail::insert_at(lines, std::regex(R"(^\s*monitor\s*=\s*,)"), "#");
        lines.insert(lines.begin() + static_cast<long>(at), line);
    }
    return detail::join(lines);
}

// monitors.lua: the same edit on NAME's hl.monitor({...}) line.
inline std::string set_lua_rule(const std::string& lua, const std::string& name, const std::string& position,
                                const std::string& scale, int transform, const std::string& mode = {}) {
    const std::string output = "output = \"" + name + "\"";
    static const std::regex pos(R"(position\s*=\s*"[^"]*")"), turn(R"(,\s*transform\s*=\s*-?\d+)"),
                            size(R"(scale\s*=\s*[^,}\s]+)"), shown(R"(mode\s*=\s*"[^"]*")");
    const std::string sized = "scale = " + scale + (transform != 0 ? ", transform = " + std::to_string(transform) : "");
    auto lines = detail::lines(lua);
    bool found = false;
    for (auto& line : lines) {
        if (line.find("hl.monitor(") == std::string::npos || line.find(output) == std::string::npos
            || line.find("disabled = true") != std::string::npos || line.find("--") < line.find("hl.monitor(")) continue;
        line = std::regex_replace(line, turn, "");
        line = std::regex_replace(line, pos, "position = \"" + position + "\"");
        line = std::regex_replace(line, size, sized, std::regex_constants::format_first_only);
        if (!mode.empty()) line = std::regex_replace(line, shown, "mode = \"" + mode + "\"", std::regex_constants::format_first_only);
        found = true;
    }
    if (!found) {
        const auto line = "hl.monitor({ " + output + ", mode = \"" + (mode.empty() ? std::string("preferred") : mode) + "\", position = \"" + position + "\", " + sized + " })";
        const auto at = detail::insert_at(lines, std::regex(R"(output\s*=\s*"")"), "--");
        lines.insert(lines.begin() + static_cast<long>(at), line);
    }
    return detail::join(lines);
}

}  // namespace desk_monitor::placement

#endif
