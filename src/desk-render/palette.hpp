#ifndef FOX_RENDER_PALETTE_HPP
#define FOX_RENDER_PALETTE_HPP

#include <string>
#include <unordered_map>

namespace fox_render {

// Parses a palette.sh file: ALL_CAPS shell assignments.
// Skips PALETTE_LABELS / PALETTE_NAME / PALETTE_DESCRIPTION.
// 6-char hex values become hex vars (expanded into VAR, VAR_R, VAR_G, VAR_B).
// Everything else becomes a plain string var (expanded only as VAR).
// Returns the final {{KEY}} -> value substitution map ready for templating.
std::unordered_map<std::string, std::string>
parse_palette(const std::string& palette_path);

}  // namespace fox_render

#endif
