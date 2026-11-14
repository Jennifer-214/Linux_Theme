#ifndef FOX_INSTALL_RESUME_POINT_HPP
#define FOX_INSTALL_RESUME_POINT_HPP

// The --resume state file: what is written after each module succeeds, and where the next
// --resume starts from it. It holds the module's slug, not its registry index, so a resume
// still lands on the right module after modules.def gains or loses entries between runs.

#include "module.hpp"

#include <cstddef>
#include <optional>
#include <string>

namespace desk_install::resume {

inline std::string record(const Module* mods, std::size_t i) { return mods[i].slug; }

// Index to start at: the module after the saved one. nullopt when the saved text names no
// module in this registry (a removed slug, or an index written by an older build).
inline std::optional<std::size_t> start_after(std::string saved, const Module* mods, std::size_t n) {
    while (!saved.empty() && (saved.back() == '\n' || saved.back() == '\r' || saved.back() == ' '))
        saved.pop_back();
    for (std::size_t i = 0; i < n; ++i)
        if (saved == mods[i].slug) return i + 1;
    return std::nullopt;
}

}  // namespace desk_install::resume

#endif
