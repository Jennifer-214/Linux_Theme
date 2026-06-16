#ifndef FOX_INSTALL_MODULES_PERSONALIZE_HPP
#define FOX_INSTALL_MODULES_PERSONALIZE_HPP

// Sub-functions exposed so the monitors module can run the same
// post-layout personalisation steps as the personalize module itself.
// Both bash _personalize_* helpers and configure_monitors's tail call
// the same sequence — keeping it as a public mini-API here mirrors that.

#include "../core/context.hpp"
#include "../core/sidecar.hpp"

#include <cstddef>
#include <string>

namespace fox_install::personalize {

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
