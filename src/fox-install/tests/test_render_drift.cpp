// The early drift stop (installer audit 2026-10-15, finding 19; batch 3a): under -y / no TTY, live ~/.config edits stop
// the install before any module — never in an interactive, --full or dry run, and never without drift.

#include "../modules/render_drift.hpp"

#include <cstdio>
#include <string>

using namespace fox_install;

int main() {
    int failed = 0;
    auto expect = [&](const std::string& what, bool ok) {
        if (!ok) { std::fprintf(stderr, "FAIL %s\n", what.c_str()); ++failed; }
    };
    // (render_will_run, dry_run, force_reapply, assume_yes, tty, drift)
    expect("-y + drift → stop", drift_stops_before_install(true, false, false, true, true, true));
    expect("no TTY + drift → stop", drift_stops_before_install(true, false, false, false, false, true));
    expect("interactive (TTY, no -y) → never stop: render asks there", !drift_stops_before_install(true, false, false, false, true, true));
    expect("--full → never stop: an explicit overwrite", !drift_stops_before_install(true, false, true, true, true, true));
    expect("dry run → never stop: it only previews", !drift_stops_before_install(true, true, false, true, false, true));
    expect("no drift → never stop", !drift_stops_before_install(true, false, false, true, false, false));
    expect("render not running → never stop", !drift_stops_before_install(false, false, false, true, false, true));
    // every combination: a stop needs ALL of render, no dry run, no --full, (-y or no TTY), drift
    int stops = 0;
    for (int m = 0; m < 64; ++m) {
        bool r = m & 1, d = m & 2, f = m & 4, y = m & 8, t = m & 16, x = m & 32;
        if (drift_stops_before_install(r, d, f, y, t, x)) {
            ++stops;
            expect("a stop only with render, drift, no dry run, no --full, and -y or no TTY", r && x && !d && !f && (y || !t));
        }
    }
    expect("exactly the 3 stopping combinations (-y+TTY, -y+no TTY, no -y+no TTY)", stops == 3);
    if (failed) { std::fprintf(stderr, "render_drift tests: %d FAILED\n", failed); return 1; }
    std::printf("render_drift tests: OK\n");
    return 0;
}
