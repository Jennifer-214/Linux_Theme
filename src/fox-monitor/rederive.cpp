// rederive.cpp — live hyprctl → sidecar::Layout (port of the bash
// rederive_sidecar). The pure from_hyprctl_json does all the work; from_live
// is a thin sh::capture wrapper so the parse + derivation stay unit-testable.

#include "rederive.hpp"

#include "../fox-common/shell.hpp"
#include "../fox-intel/json.hpp"

#include <chrono>
#include <thread>

namespace sh   = fox_install::sh;
using json     = nlohmann::json;

namespace {
// True unless the hyprctl JSON has >=1 monitor reporting a zero dimension
// (a mode not yet committed — worth waiting for). Parse failure / non-array
// -> true (nothing to settle on; from_hyprctl_json handles the empty case).
bool all_monitors_ready(const std::string& monitors_json) {
    json monitors;
    try { monitors = json::parse(monitors_json); }
    catch (const std::exception&) { return true; }
    if (!monitors.is_array()) return true;
    for (auto& m : monitors) {
        if (m.value("width", 0) <= 0 || m.value("height", 0) <= 0) return false;
    }
    return true;
}
}  // namespace

namespace fox_monitor::rederive {

sidecar::Layout from_hyprctl_json(const std::string& monitors_json,
                                  const std::string& sticky_primary) {
    sidecar::Layout out;

    json monitors;
    try {
        monitors = json::parse(monitors_json);
    } catch (const std::exception&) {
        return out;  // unparseable → empty Layout (primary empty)
    }
    if (!monitors.is_array() || monitors.empty()) return out;

    // Sticky PRIMARY: keep the recorded one if that monitor is still
    // present, else fall back to whatever Hyprland reports first.
    std::string primary;
    if (!sticky_primary.empty()) {
        for (auto& m : monitors) {
            if (m.value("name", std::string{}) == sticky_primary) {
                primary = sticky_primary;
                break;
            }
        }
    }
    if (primary.empty())
        primary = monitors.front().value("name", std::string{});
    out.primary = primary;

    for (auto& m : monitors) {
        std::string name = m.value("name", std::string{});
        if (name.empty()) continue;
        int w = m.value("width", 0), h = m.value("height", 0);
        // G1 (reject-zero): a monitor still mid-modeset reports 0 dims (the
        // NVIDIA modeset race). Skip it — never write "NAME:0x0", which
        // downstream turns into a degenerate solid-color wallpaper slab. A
        // later event re-derives it once its mode commits (reconcile is
        // event-driven + idempotent).
        if (w <= 0 || h <= 0) continue;
        int transform = m.value("transform", 0);
        bool portrait = (transform == 1 || transform == 3);

        // hyprctl reports PRE-transform dims; swap once for 90°/270°.
        int ew = portrait ? h : w;
        int eh = portrait ? w : h;
        out.monitor_resolutions.push_back(
            name + ":" + std::to_string(ew) + "x" + std::to_string(eh));

        if (portrait) out.portrait_outputs.push_back(name);
        if (name != primary) out.secondary_outputs.push_back(name);
    }

    return out;
}

sidecar::Layout from_live(const sidecar::Layout& prev) {
    if (!sh::have("hyprctl")) return {};
    // Settle-wait (G2): on NVIDIA the modeset lags the monitoradded event, so
    // hyprctl briefly reports a freshly-plugged monitor at 0x0. Retry until
    // every monitor has committed a nonzero mode (or the ~1s cap elapses)
    // before deriving. G1 in from_hyprctl_json is the backstop if one is still
    // 0x0 after the cap.
    constexpr int  kMaxTries   = 10;
    constexpr auto kRetryDelay = std::chrono::milliseconds(100);
    std::string raw;
    for (int tries = 0; tries < kMaxTries; ++tries) {
        if (!sh::capture({"hyprctl", "monitors", "-j"}, raw) || raw.empty())
            return {};
        if (all_monitors_ready(raw)) break;
        if (tries + 1 < kMaxTries) std::this_thread::sleep_for(kRetryDelay);
    }
    return from_hyprctl_json(raw, prev.primary);
}

}  // namespace fox_monitor::rederive
