// modules/ide_settings.hpp — set the colour theme in a VS Code / Cursor settings file.
//
// settings.json is JSONC: comments and trailing commas are normal there and no parser here can round-trip them. A file
// strict JSON can't read is left exactly as it is, because rewriting it would lose everything else the user set.
#pragma once

#include "../core/backup.hpp"
#include "../core/context.hpp"
#include "../../desk-common/json.hpp"

#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <system_error>

namespace fox_install::ide_settings {

enum class Result { Updated, Unchanged, LeftAlone, Failed };

inline Result set_color_theme(const Context& ctx, const std::filesystem::path& settings, const std::string& theme) {
    namespace fs = std::filesystem;
    using json = nlohmann::ordered_json;

    json object = json::object();
    if (fs::exists(settings)) {
        std::ifstream in(settings);
        std::stringstream text;
        text << in.rdbuf();
        const std::string body = text.str();
        if (body.find_first_not_of(" \t\r\n") != std::string::npos) {
            object = json::parse(body, nullptr, /*allow_exceptions=*/false);
            if (object.is_discarded() || !object.is_object()) return Result::LeftAlone;
        }
    }
    const auto current = object.find("workbench.colorTheme");
    if (current != object.end() && *current == theme) return Result::Unchanged;

    object["workbench.colorTheme"] = theme;
    std::error_code ec;
    fs::create_directories(settings.parent_path(), ec);
    const fs::path staged = settings.string() + ".foxml-new";
    { std::ofstream(staged) << object.dump(2) << '\n'; }
    const bool deployed = deploy_file_atomic(ctx, staged, settings);
    fs::remove(staged, ec);
    return deployed ? Result::Updated : Result::Failed;
}

}  // namespace fox_install::ide_settings
