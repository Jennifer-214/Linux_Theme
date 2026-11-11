#ifndef FOX_INSTALL_CORE_PALETTE_HPP
#define FOX_INSTALL_CORE_PALETTE_HPP

// Runtime read of a theme's palette.sh, for modules that act on a palette
// value outside the renderer (cursor theme, icon theme, hyprlock spans).

#include <filesystem>
#include <fstream>
#include <map>
#include <string>

namespace desk_install::palette {

// KEY=value map; tolerant of comments, quoted values and array lines we don't use.
inline std::map<std::string, std::string> read(const std::filesystem::path& p) {
    std::map<std::string, std::string> m;
    std::ifstream in(p);
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string k = line.substr(0, eq);
        std::string v = line.substr(eq + 1);
        auto hash = v.find(" #");
        if (hash != std::string::npos) v.erase(hash);
        while (!v.empty() && (v.back() == '\r' || v.back() == ' ' || v.back() == '\t'))
            v.pop_back();
        if (v.size() >= 2 && v.front() == '"' && v.back() == '"') v = v.substr(1, v.size() - 2);
        m[k] = v;
    }
    return m;
}

// One value, or `fallback` when the palette or the key is missing.
inline std::string get(const std::filesystem::path& p, const std::string& key,
                       const std::string& fallback) {
    auto m = read(p);
    auto it = m.find(key);
    return (it != m.end() && !it->second.empty()) ? it->second : fallback;
}

}  // namespace desk_install::palette

#endif
