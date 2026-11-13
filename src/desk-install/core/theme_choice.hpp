// core/theme_choice.hpp — which theme a run uses, settled before anything is planned.
//
// Named on the command line, else the saved .active-theme, else the default. It has to happen before the state checks
// read the palette, and run-time modules must not replace a saved theme with the default just because none was named.
#pragma once

#include <filesystem>
#include <fstream>
#include <string>

namespace desk_install {

struct ThemeChoice {
    std::string name;
    std::string source;
};

inline bool theme_exists(const std::filesystem::path& themes_dir, const std::string& name) {
    if (name.empty()) return false;
    std::error_code ec;
    return std::filesystem::exists(themes_dir / name / "palette.sh", ec);
}

// Four themes lost a prefix in 2026-11. An install from before still has the old name saved in .active-theme, and
// people still type it: the old spelling means the theme it became, as long as that theme exists.
inline std::string current_theme_name(const std::filesystem::path& themes_dir, const std::string& name) {
    static const std::string old_prefix = "FoxML_";   // old-theme-name
    if (theme_exists(themes_dir, name) || name.rfind(old_prefix, 0) != 0) return name;
    const std::string renamed = name.substr(old_prefix.size());
    return theme_exists(themes_dir, renamed) ? renamed : name;
}

inline ThemeChoice choose_theme(const std::string& asked, const std::filesystem::path& themes_dir,
                                const std::filesystem::path& script_dir, const std::string& fallback) {
    const std::string requested = current_theme_name(themes_dir, asked);
    if (theme_exists(themes_dir, requested)) return {requested, "command line"};
    const std::string note = asked.empty() ? "" : "'" + asked + "' not found, using ";

    std::string saved;
    if (std::ifstream in{script_dir / ".active-theme"}) std::getline(in, saved);
    saved = current_theme_name(themes_dir, saved);
    if (theme_exists(themes_dir, saved)) return {saved, note + "saved theme"};
    return {fallback, note + "default"};
}

}  // namespace desk_install
