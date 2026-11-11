#pragma once
#include "render.hpp"

namespace desk_render {
bool finish_icon_family(const std::filesystem::path& templates,
                        const std::filesystem::path& output,
                        const std::unordered_map<std::string,std::string>& palette);
}
