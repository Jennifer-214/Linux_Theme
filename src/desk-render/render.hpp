#ifndef FOX_RENDER_RENDER_HPP
#define FOX_RENDER_RENDER_HPP

#include <string>
#include <filesystem>
#include <unordered_map>

namespace fox_render {

bool atomic_write(const std::filesystem::path& dest, const std::string& body,
                  std::filesystem::perms source_mode);

// Single-pass {{KEY}} substitution. Unknown {{...}} markers pass through
// untouched (mirrors sed -e 's|{{KNOWN}}|val|g' behaviour for unmatched).
std::string apply_substitutions(
    const std::string& src,
    const std::unordered_map<std::string, std::string>& table);

// Renders every file under `template_dir` into `output_dir`, preserving
// the relative path. Writes are atomic (tmp + rename). Uses a thread pool
// sized to hardware_concurrency(). `failed` counts files that couldn't be written.
struct RenderResult {
    size_t rendered = 0;
    size_t failed = 0;
};

RenderResult render_tree(
    const std::string& template_dir,
    const std::string& output_dir,
    const std::unordered_map<std::string, std::string>& table,
    bool show_progress);

}  // namespace fox_render

#endif
