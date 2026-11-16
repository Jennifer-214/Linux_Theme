// modules/cursor_drawn.hpp — cursor sets drawn by a script in the repo (shared/cursors/<theme>.py) instead of
// downloaded. Shared by the cursor module and its state check.
#pragma once

#include "../core/context.hpp"
#include "../core/state_manifest.hpp"

#include <filesystem>
#include <fstream>
#include <optional>
#include <string>

namespace desk_install::cursor_drawn {

inline constexpr const char* kStamp = ".foxml-drawn";

inline std::optional<std::filesystem::path> script_for(const Context& ctx, const std::string& theme) {
    const auto script = ctx.shared_dir / "cursors" / (theme + ".py");
    if (theme.empty() || theme.find('/') != std::string::npos || !std::filesystem::is_regular_file(script)) return std::nullopt;
    return script;
}

inline std::string script_hash(const std::filesystem::path& script) {
    try { return state::hash_file(script); } catch (...) { return {}; }
}

// Drawn by this version of the script: the stamp beside the set names the script's hash.
inline bool is_current(const std::filesystem::path& theme_dir, const std::filesystem::path& script) {
    std::ifstream in(theme_dir / kStamp);
    std::string stamped;
    return in && std::getline(in, stamped) && !stamped.empty() && stamped == script_hash(script)
        && std::filesystem::is_directory(theme_dir / "cursors");
}

}  // namespace desk_install::cursor_drawn
