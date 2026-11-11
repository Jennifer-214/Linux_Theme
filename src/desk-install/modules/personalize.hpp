#ifndef FOX_INSTALL_MODULES_PERSONALIZE_HPP
#define FOX_INSTALL_MODULES_PERSONALIZE_HPP

// Sub-functions exposed so the monitors module can run the same
// post-layout personalisation steps as the personalize module itself.
// Both bash _personalize_* helpers and configure_monitors's tail call
// the same sequence — keeping it as a public mini-API here mirrors that.

#include "../core/context.hpp"
#include "../../desk-monitor/sidecar.hpp"

#include <cstddef>
#include <functional>
#include <string>
#include <vector>

namespace desk_install::personalize {

namespace sidecar = desk_monitor::sidecar;

// Generates pre-cropped per-monitor wallpaper variants. Returns the
// number of files generated (0 == no-op rerun, not failure). Thin wrapper
// over desk_monitor::variants::generate (the pure planner + executor live in
// libdesk-monitor's variants submodule now).
std::size_t generate_per_monitor_wallpapers(
    const Context& ctx, const sidecar::Layout& layout);

// Rewrites the sentinel-delimited background blocks in hyprlock.conf
// with one block per monitor pointing at its wallpaper variant.
bool personalize_hyprlock(
    const Context& ctx, const sidecar::Layout& layout);

// Pure helpers behind personalize_hyprlock. on_disk(name) says whether
// ~/.wallpapers/<name> exists.
//
// "foxml_paper_x_1080x1920.png" → "foxml_paper_x.png" (a variant back to its source).
std::string lock_source_name(const std::string& name);
// The file for a monitor of size res: active's <stem>_<res> cut, else the theme
// default's cut, else the theme default, else active (is_fallback = not the first).
std::string lock_wallpaper_for(const std::string& active, const std::string& theme_default,
                               const std::string& res,
                               const std::function<bool(const std::string&)>& on_disk,
                               bool& is_fallback);
// The settings lines (all but monitor/path) of the first background block
// between the sentinels; empty when there is none.
std::string background_tail(const std::string& body);
// One `background { monitor, path, <tail> }` block per "name:WxH" entry.
std::string background_blocks(const std::vector<std::string>& monitor_resolutions,
                              const std::string& active, const std::string& theme_default,
                              const std::string& tail,
                              const std::function<bool(const std::string&)>& on_disk,
                              std::size_t& fallbacks);

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

}  // namespace desk_install::personalize

#endif
