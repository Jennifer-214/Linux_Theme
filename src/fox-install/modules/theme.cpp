// modules/theme.cpp — interactive theme selection.
//
// Resolution order:
//   1. ctx.theme_name was set on the command line → use it.
//   2. .active-theme file at script_dir → use last installed theme.
//   3. Interactive prompt over stdin (skipped with --yes / no-TTY).
//   4. Fall back to FoxML_Classic.
//
// Runs early so render / symlinks / personalize all see a resolved
// theme. Registered with default_on=true so it's part of every install.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

std::vector<std::string> available_themes(const fs::path& themes_dir) {
    std::vector<std::string> out;
    if (!fs::is_directory(themes_dir)) return out;
    for (auto& entry : fs::directory_iterator(themes_dir)) {
        if (!entry.is_directory()) continue;
        if (fs::exists(entry.path() / "palette.sh")) {
            out.push_back(entry.path().filename().string());
        }
    }
    std::sort(out.begin(), out.end());
    return out;
}

std::string read_active_file(const fs::path& script_dir) {
    fs::path p = script_dir / ".active-theme";
    if (!fs::exists(p)) return {};
    std::ifstream f(p);
    std::string s;
    std::getline(f, s);
    return s;
}

bool theme_is_valid(const fs::path& themes_dir, const std::string& name) {
    if (name.empty()) return false;
    return fs::exists(themes_dir / name / "palette.sh");
}

}  // namespace

void run_theme(Context& ctx) {
    auto themes = available_themes(ctx.themes_dir);
    if (themes.empty()) {
        ui::err("no themes found under " + ctx.themes_dir.string());
        return;
    }

    // 1. Command-line override beats everything.
    if (!ctx.theme_name.empty() && theme_is_valid(ctx.themes_dir, ctx.theme_name)) {
        ui::section("Theme: " + ctx.theme_name + " (CLI argument)");
        ctx.palette_path = ctx.themes_dir / ctx.theme_name / "palette.sh";
        return;
    }

    // 2. .active-theme from prior install.
    std::string active = read_active_file(ctx.script_dir);
    if (theme_is_valid(ctx.themes_dir, active)) {
        ctx.theme_name   = active;
        ctx.palette_path = ctx.themes_dir / active / "palette.sh";
        ui::section("Theme: " + active + " (from .active-theme)");
        return;
    }

    // 3. Interactive prompt unless --yes or no TTY.
    if (!ctx.assume_yes && ::isatty(STDIN_FILENO)) {
        ui::section("Theme selection");
        for (std::size_t i = 0; i < themes.size(); ++i) {
            std::printf("  %2zu) %s\n", i + 1, themes[i].c_str());
        }
        std::printf("Pick a theme [1-%zu, default 1]: ", themes.size());
        std::fflush(stdout);
        std::string line;
        std::getline(std::cin, line);
        std::size_t pick = 1;
        if (!line.empty()) {
            try { pick = std::stoul(line); }
            catch (...) { pick = 1; }
        }
        if (pick < 1 || pick > themes.size()) pick = 1;
        ctx.theme_name   = themes[pick - 1];
        ctx.palette_path = ctx.themes_dir / ctx.theme_name / "palette.sh";
        return;
    }

    // 4. Fallback.
    ctx.theme_name   = themes[0];
    ctx.palette_path = ctx.themes_dir / ctx.theme_name / "palette.sh";
    ui::section("Theme: " + ctx.theme_name + " (fallback default)");
}

}  // namespace fox_install
