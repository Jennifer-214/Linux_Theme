// Characterization test for the PURE live-state re-derivation
// (rederive.cpp:from_hyprctl_json) — the C++ port of the bash
// rederive_sidecar.
//
// Pins: hyprctl's PRE-transform .width/.height get swapped ONCE for a
// 90°/270° rotation (transform 1 or 3) → MONITOR_RESOLUTIONS is the
// on-screen WxH; PORTRAIT_OUTPUTS = the rotated outputs; SECONDARY_OUTPUTS =
// every name != primary; and PRIMARY is sticky — preserved when the recorded
// monitor is still present, else falls back to the FIRST monitor reported.
//
// No hyprctl, no filesystem — the fixture is an in-memory JSON string.

#include "../rederive.hpp"

#include <cstdio>
#include <string>
#include <vector>

using namespace fox_monitor;

namespace {

int failed = 0;

void check(const char* what, bool ok) {
    if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); ++failed; }
}

std::string join_ws(const std::vector<std::string>& v) {
    std::string out;
    for (size_t i = 0; i < v.size(); ++i) { if (i) out += ' '; out += v[i]; }
    return out;
}

// Two monitors: eDP-1 landscape (transform 0, 1920x1080) and DP-2 portrait
// (transform 3, hyprctl reports PRE-transform width=3840 height=2160 → the
// on-screen panel is 2160x3840). jq order is preserved (eDP-1 first).
const char* kFixture = R"([
  {"name":"eDP-1","width":1920,"height":1080,"transform":0,"focused":true,"scale":1.0},
  {"name":"DP-2","width":3840,"height":2160,"transform":3,"focused":false,"scale":1.0}
])";

}  // namespace

int main() {
    // (a) transform-swap + derivation, sticky PRIMARY present.
    {
        sidecar::Layout l = rederive::from_hyprctl_json(kFixture, "eDP-1");
        check("(a) primary preserved (eDP-1 present)", l.primary == "eDP-1");
        // landscape kept as-is; portrait swapped height x width → 2160x3840.
        check("(a) MONITOR_RESOLUTIONS swapped portrait",
              join_ws(l.monitor_resolutions) == "eDP-1:1920x1080 DP-2:2160x3840");
        check("(a) PORTRAIT_OUTPUTS = DP-2",
              join_ws(l.portrait_outputs) == "DP-2");
        // SECONDARY = every name != primary (eDP-1).
        check("(a) SECONDARY_OUTPUTS = DP-2",
              join_ws(l.secondary_outputs) == "DP-2");
    }

    // (b) sticky PRIMARY = DP-2 (still present) → preserved; SECONDARY flips.
    {
        sidecar::Layout l = rederive::from_hyprctl_json(kFixture, "DP-2");
        check("(b) primary preserved (DP-2 present)", l.primary == "DP-2");
        check("(b) SECONDARY = eDP-1 when DP-2 is primary",
              join_ws(l.secondary_outputs) == "eDP-1");
        // resolution/portrait derivation is independent of which is primary.
        check("(b) MONITOR_RESOLUTIONS unchanged by primary pick",
              join_ws(l.monitor_resolutions) == "eDP-1:1920x1080 DP-2:2160x3840");
        check("(b) PORTRAIT_OUTPUTS unchanged by primary pick",
              join_ws(l.portrait_outputs) == "DP-2");
    }

    // (c) sticky name ABSENT (ghost monitor) → fall back to the FIRST monitor.
    {
        sidecar::Layout l = rederive::from_hyprctl_json(kFixture, "HDMI-A-99");
        check("(c) absent sticky → fallback to first (eDP-1)",
              l.primary == "eDP-1");
        check("(c) SECONDARY = DP-2 after fallback",
              join_ws(l.secondary_outputs) == "DP-2");
    }

    // (d) empty sticky → fall back to the FIRST monitor.
    {
        sidecar::Layout l = rederive::from_hyprctl_json(kFixture, "");
        check("(d) empty sticky → first (eDP-1)", l.primary == "eDP-1");
    }

    // (e) malformed / empty JSON → empty Layout (primary empty).
    {
        sidecar::Layout bad = rederive::from_hyprctl_json("not json", "eDP-1");
        check("(e) unparseable → empty primary", bad.primary.empty());
        sidecar::Layout empty = rederive::from_hyprctl_json("[]", "eDP-1");
        check("(e) empty array → empty primary", empty.primary.empty());
    }

    if (failed == 0) std::printf("test_rederive: OK\n");
    return failed ? 1 : 0;
}
