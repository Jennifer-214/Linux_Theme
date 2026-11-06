#pragma once
#include <filesystem>

namespace fox_render {
bool finish_paper_assets(const std::filesystem::path& templates,
                         const std::filesystem::path& output);
}
