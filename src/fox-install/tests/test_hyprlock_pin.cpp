// Unit test for the pure hyprlock panel pinner (modules/personalize.cpp).
// Locks: foreground `monitor =` lines get pinned to primary, background
// blocks inside the sentinels stay untouched, indentation is preserved,
// empty primary is a no-op, and near-misses (comments, `monitorx`) are safe.

#include "../modules/personalize.hpp"
#include "../core/splice.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <unistd.h>

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

    // ── splice_sentinel: deterministic + idempotent (Fix 2 no-regression) ──
    // personalize_hyprlock/workspace_rules now also splice the RENDERED copy so a
    // fresh box gets personalized output (not template defaults). Safety proof:
    // splice_sentinel's output region depends ONLY on new_content, never on the
    // input's prior block — so on a re-run, splicing the rendered (template) and
    // the live (already-personalized) with the same layout-derived block converge
    // to the SAME result → the known-good deployed config cannot change.
    {
        namespace fs = std::filesystem;
        using fox_install::splice_sentinel;
        const std::string B = "# foxml:hyprlock-backgrounds-begin";
        const std::string E = "# foxml:hyprlock-backgrounds-end";
        const std::string NEW =
            "background {\n    monitor = DP-1\n    path = ~/.wallpapers/new.png\n}";
        auto wr = [](const fs::path& p, const std::string& s){ std::ofstream o(p); o << s; };
        auto rd = [](const fs::path& p){
            std::ifstream i(p);
            return std::string((std::istreambuf_iterator<char>(i)),
                                std::istreambuf_iterator<char>());
        };
        auto region = [&](const std::string& s){
            auto i = s.find(B), j = s.find(E);
            return (i == std::string::npos || j == std::string::npos)
                       ? std::string() : s.substr(i, j - i);
        };

        // A: already-personalized (live-style) file with a DIFFERENT prior block.
        fs::path a = fs::temp_directory_path() /
                     ("fox_splice_a_" + std::to_string(::getpid()) + ".conf");
        wr(a, "head\n" + B + "\nbackground {\n    monitor = OLD\n"
              "    path = ~/.wallpapers/old.png\n}\n" + E + "\ntail\n");
        check("splice ok", splice_sentinel(a, B, E, NEW));
        std::string a1 = rd(a);
        check("splice replaced block", a1.find("monitor = DP-1") != std::string::npos);
        check("splice dropped old block", a1.find("monitor = OLD") == std::string::npos);
        check("splice kept head+tail",
              a1.find("head\n") != std::string::npos && a1.find("\ntail\n") != std::string::npos);
        splice_sentinel(a, B, E, NEW);
        check("splice idempotent", rd(a) == a1);

        // B: fresh/template-style file (EMPTY prior block). The same NEW must
        // yield the SAME sentinel region → rendered & live converge on a re-run.
        fs::path b = fs::temp_directory_path() /
                     ("fox_splice_b_" + std::to_string(::getpid()) + ".conf");
        wr(b, "head\n" + B + "\n" + E + "\ntail\n");
        splice_sentinel(b, B, E, NEW);
        check("rendered & live converge", region(rd(b)) == region(a1));

        fs::remove(a); fs::remove(b);
    }

    if (failed == 0) std::printf("test_hyprlock_pin: OK\n");
    return failed ? 1 : 0;
}
