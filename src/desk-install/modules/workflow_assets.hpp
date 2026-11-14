#pragma once
#include <cstddef>
#include "symlinks_data.hpp"
#include <filesystem>
#include <string>
#include <vector>

namespace desk_install::workflow {
namespace fs = std::filesystem;
struct Asset { fs::path source, destination; std::string client; };
inline bool build_stamp(const fs::path& path) {
    const auto name = path.filename().string();
    return name == "build.ts" || name == "build.lua" || name == "Build.js";
}
inline fs::path destination(const fs::path& home, const fs::path& config, const std::string& name) {
    if (name.rfind("~/.config/", 0) == 0) return config / name.substr(10);
    return name.rfind("~/", 0) == 0 ? home / name.substr(2) : fs::path(name);
}
inline std::vector<Asset> assets(const fs::path& repo, const fs::path& home, const fs::path& config) {
    std::vector<Asset> result;
    for (const auto& item : symlinks::SHARED_MAPPINGS) {
        const std::string source = item.src;
        std::string client;
        if (source.rfind("nvim_lua/desk/", 0) == 0) client = "nvim";
        else if (source.rfind("claude/mods/desk-notebook/", 0) == 0) client = "notebook";
        else if (source == "pi/extensions/desk-notify.ts" || source == "pi/extensions/desk/build.ts") client = "pi";
        else if (source == "redzone.json") client = "policy";
        if (!client.empty()) result.push_back({ repo / "shared" / source, destination(home, config, item.dest), client });
    }
    for (const char* tool : {"desk-work", "desk-drawer", "desk-install", "theme-check"})
        result.push_back({repo / "src" / tool / tool, home / ".local/bin" / tool, "backend"});
    for (const char* script : {"desktop-menu", "desk-hl", "desk-credits", "work-notice", "claude-api"})
        result.push_back({repo / "shared/bin" / script, home / ".local/bin" / script, "backend"});
    result.push_back({repo / "shared/zsh_work.zsh", config / "zsh/work.zsh", "shell"});
    std::error_code ec;
    for (const auto& file : fs::directory_iterator(repo / "shared/quickshell/desk", ec))
        if (file.is_regular_file(ec) && file.path().filename() != "menus.json")
            result.push_back({file.path(), config / "quickshell/desk" / file.path().filename(), "desktop"});
    result.push_back({repo / "shared/quickshell/desk/menus.json", config / "quickshell/desk/menus.default.json", "desktop"});
    return result;
}
}
