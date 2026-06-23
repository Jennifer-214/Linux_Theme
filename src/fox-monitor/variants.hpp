#ifndef FOX_MONITOR_VARIANTS_HPP
#define FOX_MONITOR_VARIANTS_HPP

// Per-monitor wallpaper-variant generator — the path-parameterized
// "variants" submodule of libfox-monitor. fox-install's personalize module
// is a thin wrapper over generate(); the pure planner is reused by tests.
//
// A variant is `<base>_<WxH>.<ext>` rendered at NATIVE pixel dims so each
// monitor gets a wallpaper pre-cropped to its exact reported resolution.

#include <cstddef>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace fox_monitor::variants {

// One planned per-monitor wallpaper-variant operation. The planner emits
// these; generate() executes them (magick / fs::remove).
struct VariantAction {
    enum Kind { Generate, Prune } kind;
    std::string src_base_file;  // "wall.jpg"   (Generate) — source to render from
    std::string out_file;       // "wall_1920x1080.jpg" — variant filename to write/remove
    int w = 0;                  // NATIVE target dims (Generate); 0 for Prune
    int h = 0;
};

// Pure planner — no filesystem, no imagemagick. Decides, per (base, res),
// whether a variant must be (re)generated at NATIVE w×h, and which existing
// `<base>_<WxH>` variants should be pruned because their res left the set.
//
//   resolutions      — dedup'd monitor resolutions ("1920x1080", "2160x3840")
//   base_files       — base wallpaper filenames+ext, ALREADY excluding
//                      `_portrait` and `_WxH`-suffixed inputs
//   existing_variants— map of existing-variant-filename → its current (w,h)
//
// Returns Generate at NATIVE dims when a variant is missing OR its existing
// dims != native target (force-regen / size-class convergence); no action when
// an existing variant already matches native dims; Prune for existing
// `<base>_<WxH>` variants whose `<WxH>` is NOT in the resolution set.
std::vector<VariantAction> plan_variants(
    const std::set<std::string>& resolutions,
    const std::vector<std::string>& base_files,
    const std::map<std::string, std::pair<int, int>>& existing_variants);

// Generates pre-cropped per-monitor wallpaper variants under `wall_dir`.
//
//   wall_dir            — the wallpaper directory (~/.wallpapers)
//   monitor_resolutions — entries shaped "<name>:<WxH>" (sidecar field);
//                         deduped internally to the underlying res set
//   dry_run             — when true, no magick/remove runs and existing
//                         variants are not probed (planner previews every
//                         variant as a Generate — the honest "what would
//                         happen" output)
//
// Returns the number of files generated (0 == no-op rerun, not failure).
std::size_t generate(const std::filesystem::path& wall_dir,
                     const std::vector<std::string>& monitor_resolutions,
                     bool dry_run);

}  // namespace fox_monitor::variants

#endif
