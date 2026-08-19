#ifndef FOX_MONITOR_APPLY_HPP
#define FOX_MONITOR_APPLY_HPP

// Re-apply the CURRENT wallpaper per monitor — the C++ port of
// rotate_wallpaper.sh's per-monitor apply loop, with the KEY DIFFERENCE
// that the base comes from the `.current` symlink (a bare filename), NOT a
// time-of-day slot. reconcile RE-APPLIES the current wallpaper; it never
// rotates. A submodule of libfox-monitor composed by `fox-monitor reconcile`.

#include "sidecar.hpp"

#include <cstddef>
#include <filesystem>
#include <string>

namespace fox_monitor::apply {

// readlink(wall_dir/.current) → bare filename (e.g. "foxml_earthy.jpg").
// Empty when the symlink is absent/unreadable or points outside wall_dir.
std::string current_base(const std::filesystem::path& wall_dir);

// PURE-ish helper: returns the per-monitor file to apply for (base, res).
// `<stem>_<res>.<ext>` (the pre-rendered variant) when that file exists in
// wall_dir, else `base` itself with is_fallback=true. Returns just the
// filename (not a full path).
std::string variant_for(const std::string& base, const std::string& res,
                        const std::filesystem::path& wall_dir,
                        bool& is_fallback);

// For each "name:WxH" in layout.monitor_resolutions, apply the current
// wallpaper to that monitor via `awww img -o <name> <variant> --resize
// <fit|crop> --transition-type fade ...`. The variant gets --resize fit
// (exact pixel match); the source-fallback gets --resize crop. Ensures the
// awww-daemon is up first. Returns the number of monitors an image was
// issued for. dry_run guards every side effect (no daemon spawn, no awww).
std::size_t apply_current(const sidecar::Layout& layout,
                          const std::filesystem::path& wall_dir,
                          bool dry_run);

}  // namespace fox_monitor::apply

#endif
