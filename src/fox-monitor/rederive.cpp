// rederive.cpp — live hyprctl → sidecar::Layout (port of the bash
// rederive_sidecar). The pure from_hyprctl_json does all the work; from_live
// is a thin sh::capture wrapper so the parse + derivation stay unit-testable.

#include "rederive.hpp"

#include "../fox-common/shell.hpp"
#include "../fox-intel/json.hpp"

namespace sh   = fox_install::sh;
using json     = nlohmann::json;

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
    std::string raw;
    if (!sh::capture({"hyprctl", "monitors", "-j"}, raw) || raw.empty())
        return {};
    return from_hyprctl_json(raw, prev.primary);
}

}  // namespace fox_monitor::rederive
