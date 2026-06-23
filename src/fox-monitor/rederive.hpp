#ifndef FOX_MONITOR_REDERIVE_HPP
#define FOX_MONITOR_REDERIVE_HPP

// Re-derive a sidecar Layout from live Hyprland state — the C++ port of
// fox-monitor-watch.sh's rederive_sidecar(). A submodule of libfox-monitor
// composed by `fox-monitor reconcile`.
//
// hyprctl reports PRE-transform .width/.height; a 90°/270° rotation
// (transform 1 or 3) means the on-screen panel is height×width, so we swap
// once. PRIMARY is sticky: kept if the recorded primary is still present,
// else falls back to the first monitor Hyprland reports (so the sidecar
// never references a ghost monitor).

#include "sidecar.hpp"

#include <string>

namespace fox_monitor::rederive {

// PURE: parse `monitors_json` (the `hyprctl monitors -j` array) into a
// Layout, applying the transform-swap, the portrait/secondary derivation,
// and the sticky-primary rule against `sticky_primary` (the previous
// sidecar's PRIMARY; may be empty). No I/O — testable in isolation.
sidecar::Layout from_hyprctl_json(const std::string& monitors_json,
                                  const std::string& sticky_primary);

// Runs `hyprctl monitors -j` and feeds it to from_hyprctl_json with
// `prev.primary` as the sticky primary. Returns an empty Layout (primary
// empty) when hyprctl is unavailable / returns nothing.
sidecar::Layout from_live(const sidecar::Layout& prev);

}  // namespace fox_monitor::rederive

#endif
