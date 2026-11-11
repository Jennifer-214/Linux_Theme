#pragma once
#include <filesystem>

namespace desk_render {
bool finish_paper_assets(const std::filesystem::path& templates,
                         const std::filesystem::path& output);
}
