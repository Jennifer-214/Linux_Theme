// Unit test for the pure hyprlock panel pinner (modules/personalize.cpp).
// Locks: foreground `monitor =` lines get pinned to primary, background
// blocks inside the sentinels stay untouched, indentation is preserved,
// empty primary is a no-op, and near-misses (comments, `monitorx`) are safe.

#include "../modules/personalize.hpp"

#include <cstdio>
#include <string>

namespace {

std::size_t count(const std::string& hay, const std::string& needle) {
    std::size_t n = 0, pos = 0;
    while ((pos = hay.find(needle, pos)) != std::string::npos) { ++n; pos += needle.size(); }
    return n;
}

const char* SAMPLE =
    "general {\n"
    "    hide_cursor = true\n"
    "}\n"
    "# foxml:hyprlock-backgrounds-begin\n"
    "background {\n"
    "    monitor = eDP-1\n"
    "    path = /x.jpg\n"
    "}\n"
    "background {\n"
    "    monitor = HDMI-A-1\n"
    "    path = /y.jpg\n"
    "}\n"
    "# foxml:hyprlock-backgrounds-end\n"
    "# a comment mentioning monitor here\n"
    "label {\n"
    "    monitor =\n"
    "    text = hi\n"
    "}\n"
    "input-field {\n"
    "    monitor =\n"
    "    size = 280, 46\n"
    "    monitorx = keep-me\n"
    "}\n";

}  // namespace

int main() {
    using namespace fox_install::personalize;
    int failed = 0;

    auto check = [&](const char* what, bool ok) {
        if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); ++failed; }
    };

    std::string in = SAMPLE;
    std::string out = pin_foreground_monitors(in, "eDP-1");

    // Background blocks inside the sentinels are untouched.
    check("bg eDP-1 preserved",  count(out, "    monitor = eDP-1") >= 1);
    check("bg HDMI-A-1 preserved", count(out, "    monitor = HDMI-A-1") == 1);

    // Both empty foreground `monitor =` lines pinned (1 bg + 2 fg == 3 total).
    check("foreground pinned to eDP-1", count(out, "    monitor = eDP-1") == 3);

    // No bare empty `monitor =` left anywhere.
    check("no empty monitor= remains", count(out, "monitor =\n") == 0);

    // Indentation preserved on a pinned line.
    check("indent preserved", out.find("    monitor = eDP-1") != std::string::npos);

    // Near-misses untouched: comment + `monitorx`.
    check("comment untouched", out.find("# a comment mentioning monitor here") != std::string::npos);
    check("monitorx untouched", out.find("    monitorx = keep-me") != std::string::npos);

    // Empty primary is a no-op.
    check("empty primary no-op", pin_foreground_monitors(in, "") == in);

    // Idempotent: re-pinning an already-pinned body is stable.
    check("idempotent", pin_foreground_monitors(out, "eDP-1") == out);

    // No trailing-newline corruption (input ends in '\n').
    check("trailing newline kept", !out.empty() && out.back() == '\n');

    if (failed == 0) std::printf("test_hyprlock_pin: OK\n");
    return failed ? 1 : 0;
}
