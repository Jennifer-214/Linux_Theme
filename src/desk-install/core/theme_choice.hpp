// core/theme_choice.hpp — which theme a run uses, settled before anything is planned.
//
// Named on the command line, else the saved .active-theme, else the default. It has to happen before the state checks
// read the palette, and run-time modules must not replace a saved theme with the default just because none was named.
#pragma once

#include <filesystem>
#include <fstream>
#include <string>

namespace fox_install {

struct ThemeChoice {
    std::string name;
    std::string source;
};

inline bool theme_exists(const std::filesystem::path& themes_dir, const std::string& name) {
    if (name.empty()) return false;
    std::error_code ec;
    return std::filesystem::exists(themes_dir / name / "palette.sh", ec);
}

inline ThemeChoice choose_theme(const std::string& requested, const std::filesystem::path& themes_dir,
                                const std::filesystem::path& script_dir, const std::string& fallback) {
    if (theme_exists(themes_dir, requested)) return {requested, "command line"};
    const std::string note = requested.empty() ? "" : "'" + requested + "' not found, using ";

    std::string saved;
    if (std::ifstream in{script_dir / ".active-theme"}) std::getline(in, saved);
    if (theme_exists(themes_dir, saved)) return {saved, note + "saved theme"};
    return {fallback, note + "default"};
}

}  // namespace fox_install
