// Characterization of fox_monitor::apply's PURE helpers — current_base + variant_for.
//
// W1 (monitor-polish): personalize::apply_all now re-applies the live wallpaper
// after a layout change (the wizard-rotation letterbox fix), GATED on current_base()
// being non-empty. This pins the two contracts that gate + decision depend on:
//   - current_base(): bare .current → bare name; absent/outside-dir → "" (the no-op
//     gate apply_all relies on so a fresh box, with no .current yet, stays silent).
//   - variant_for(): exact _WxH variant present → is_fallback=false (→ --resize fit);
//     absent → is_fallback=true returns base (→ --resize crop). The fit/crop choice
//     that makes a portrait variant FILL instead of letterbox.
//
// Links apply.o + libfox-common (apply.o carries ui::/sh:: refs from apply_current,
// even though the pure helpers under test touch none of them) — mirrors test_variants.

#include "../apply.hpp"

#include <cstdio>
#include <filesystem>
#include <string>

namespace fs = std::filesystem;
using namespace fox_monitor::apply;

namespace {

int failed = 0;

void check(const char* what, bool ok) {
    if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); ++failed; }
}

void touch(const fs::path& p) {
    std::FILE* f = std::fopen(p.c_str(), "w");
    if (f) { std::fputs("x", f); std::fclose(f); }
}

}  // namespace

int main() {
    fs::path dir = fs::temp_directory_path() / "fox-monitor-apply-test";
    std::error_code ec;
    fs::remove_all(dir, ec);
    fs::create_directories(dir, ec);

    // ── (1) current_base: bare .current symlink → bare filename ──────────
    {
        fs::path wall = dir / "wall1";
        fs::create_directories(wall, ec);
        fs::create_symlink("foxml_earthy.jpg", wall / ".current", ec);
        check("(1) bare .current → bare name", current_base(wall) == "foxml_earthy.jpg");
    }

    // ── (2) current_base: absent .current → "" (the no-op gate) ──────────
    {
        fs::path wall = dir / "wall2";
        fs::create_directories(wall, ec);
        check("(2) absent .current → empty (apply_all skips on fresh box)",
              current_base(wall).empty());
    }

    // ── (3) current_base: target carrying a path separator → "" ──────────
    // Pins CURRENT behavior (reject any '/'). NOTE: W5.2 will widen this to accept
    // an absolute target resolving inside wall_dir — update this case when W5.2 lands.
    {
        fs::path wall = dir / "wall3";
        fs::create_directories(wall, ec);
        fs::create_symlink("/abs/path/foo.jpg", wall / ".current", ec);
        check("(3) absolute .current → empty (today's reject-any-slash)",
              current_base(wall).empty());
    }

    // ── (4) variant_for: exact _WxH variant exists → fit (not fallback) ──
    {
        fs::path wall = dir / "wall4";
        fs::create_directories(wall, ec);
        touch(wall / "foxml_earthy_1080x1920.jpg");
        bool fb = true;
        std::string got = variant_for("foxml_earthy.jpg", "1080x1920", wall, fb);
        check("(4) variant present → returns the variant", got == "foxml_earthy_1080x1920.jpg");
        check("(4) variant present → is_fallback=false (→ --resize fit)", fb == false);
    }

    // ── (5) variant_for: no matching variant → crop fallback to source ───
    {
        fs::path wall = dir / "wall5";
        fs::create_directories(wall, ec);
        bool fb = false;
        std::string got = variant_for("foxml_earthy.jpg", "1080x1920", wall, fb);
        check("(5) variant absent → returns the base source", got == "foxml_earthy.jpg");
        check("(5) variant absent → is_fallback=true (→ --resize crop)", fb == true);
    }

    fs::remove_all(dir, ec);

    if (failed == 0) std::printf("test_apply: OK\n");
    return failed ? 1 : 0;
}
