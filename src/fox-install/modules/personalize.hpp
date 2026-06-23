#ifndef FOX_INSTALL_MODULES_PERSONALIZE_HPP
#define FOX_INSTALL_MODULES_PERSONALIZE_HPP

// Sub-functions exposed so the monitors module can run the same
// post-layout personalisation steps as the personalize module itself.
// Both bash _personalize_* helpers and configure_monitors's tail call
// the same sequence — keeping it as a public mini-API here mirrors that.

#include "../core/context.hpp"
#include "../core/sidecar.hpp"

#include <cstddef>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace fox_install::personalize {

// One planned per-monitor wallpaper-variant operation. The planner emits
// these; generate_per_monitor_wallpapers executes them (magick / fs::remove).
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

// Generates pre-cropped per-monitor wallpaper variants. Returns the
// number of files generated (0 == no-op rerun, not failure).
std::size_t generate_per_monitor_wallpapers(
    const Context& ctx, const sidecar::Layout& layout);

// Rewrites the sentinel-delimited background blocks in hyprlock.conf
// with one block per monitor pointing at its wallpaper variant.
bool personalize_hyprlock(
    const Context& ctx, const sidecar::Layout& layout);

// Rewrites the workspace 1 pin in rules.conf to bind to layout.primary.
bool personalize_workspace_rules(
    const Context& ctx, const sidecar::Layout& layout);

// Pure: rewrite every `monitor =` line OUTSIDE the hyprlock-backgrounds
// sentinel region to `monitor = <primary>` (indentation preserved). The
// background blocks inside the sentinels each name their own monitor and
// are left untouched. Empty primary returns the body unchanged.
std::string pin_foreground_monitors(
    const std::string& body, const std::string& primary);

// Pins the hyprlock login panel (brand/clock/input/...) to layout.primary
// in both the live config and the rendered copy, so it renders on one
// monitor only. No-op when primary is empty. Returns true if any file changed.
bool pin_hyprlock_panel(
    const Context& ctx, const sidecar::Layout& layout);

// Runs all three in order. Used by the monitors module after writing
// monitor-layout.conf, and as the body of the personalize module.
void apply_all(const Context& ctx, const sidecar::Layout& layout);

}  // namespace fox_install::personalize

#endif
