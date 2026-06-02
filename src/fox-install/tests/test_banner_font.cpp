// Unit test for the pure banner constructor (modules/banner_font.cpp).
// Locks the FOX OS default + the builder output and the sanitiser contract.

#include "../modules/banner_font.hpp"

#include <cstdio>
#include <string>

int main() {
    using namespace fox_install;
    int failed = 0;

    auto eq = [&](const char* what, const std::string& got, const std::string& exp) {
        if (got != exp) {
            std::fprintf(stderr, "FAIL %s:\n  got: %s\n  exp: %s\n",
                         what, got.c_str(), exp.c_str());
            ++failed;
        }
    };

    // ── sanitiser ──
    eq("sanitize lower",     sanitize_banner_text("fox os"), "FOX OS");
    eq("sanitize strip",     sanitize_banner_text("a@b!c"),  "ABC");
    eq("sanitize blank",     sanitize_banner_text("   "),    "FOX OS");
    eq("sanitize trim",      sanitize_banner_text("  hi "),  "HI");
    if (sanitize_banner_text("ABCDEFGHIJKLMNOP").size() != 12) {
        std::fprintf(stderr, "FAIL sanitize cap: len=%zu\n",
                     sanitize_banner_text("ABCDEFGHIJKLMNOP").size());
        ++failed;
    }

    // ── FOXML banner: width + row 1 (per-letter c1..c4 cycle, M is 5-wide) ──
    BannerBlock b = build_banner("FOXML");
    if (b.width != 27) { std::fprintf(stderr, "FAIL width: %d\n", b.width); ++failed; }
    eq("FOXML r1", b.r1,
       "${c1}█▀▀${O} ${c2}█▀█${O} ${c3}▀▄▀${O} ${c4}█▀▄▀█${O} ${c1}█  ${O}");

    // ── FOX OS default: width 28, space glyph (c4, 2-wide blank), cycle continues O→c1 S→c2 ──
    BannerBlock f = build_banner("FOX OS");
    if (f.width != 28) { std::fprintf(stderr, "FAIL FOX OS width: %d\n", f.width); ++failed; }
    eq("FOX OS r1", f.r1,
       "${c1}█▀▀${O} ${c2}█▀█${O} ${c3}▀▄▀${O} ${c4}  ${O} ${c1}█▀█${O} ${c2}▄▀▀${O}");

    // ── colour cycle wraps past 4 (5th glyph back to c1) ──
    BannerBlock e = build_banner("ABCDE");
    // E is the 5th glyph → c1; its row1 glyph is "█▀▀"
    if (e.r1.rfind("${c1}█▀▀${O}") == std::string::npos) {
        std::fprintf(stderr, "FAIL colour-cycle wrap (E should be c1)\n");
        ++failed;
    }

    auto has = [&](const char* what, const std::string& hay, const std::string& needle) {
        if (hay.find(needle) == std::string::npos) {
            std::fprintf(stderr, "FAIL %s:\n  needle absent: %s\n  in: %s\n",
                         what, needle.c_str(), hay.c_str());
            ++failed;
        }
    };
    auto lacks = [&](const char* what, const std::string& hay, const std::string& needle) {
        if (hay.find(needle) != std::string::npos) {
            std::fprintf(stderr, "FAIL %s:\n  needle present (should be absent): %s\n  in: %s\n",
                         what, needle.c_str(), hay.c_str());
            ++failed;
        }
    };

    // ── hyprlock colorizer: exact pango spans, ## escaping, FOX OS cycle ──
    // F=c1 O=c2 X=c3 (space=c4, uncolored) O=c1 S=c2; 3-space track, 4 at word gap.
    eq("hyprlock FOX OS", banner_to_hyprlock_text("FOX OS"),
       "<span foreground='##{{CLAY}}'>F</span>   "
       "<span foreground='##{{WHEAT}}'>O</span>   "
       "<span foreground='##{{BLUSH}}'>X</span>    "
       "<span foreground='##{{CLAY}}'>O</span>   "
       "<span foreground='##{{WHEAT}}'>S</span>");
    lacks("hyprlock single-# (must escape as ##)", banner_to_hyprlock_text("FOX OS"), "'#{{");
    // JANE has no space → the 4th glyph exercises c4/ACCENT (FOX OS never does).
    has("hyprlock c4=ACCENT on 4th glyph", banner_to_hyprlock_text("JANE"),
        "<span foreground='##{{ACCENT}}'>E</span>");

    // ── nvim Snacks half-block: SAME glyphs as build_banner (zsh welcome), 3 rows,
    //    per-glyph C1..4 cycle (F=c1 O=c2 X=c3 space=c4 O=c1 S=c2) ──
    std::string snk = banner_to_snacks_blocks("FOX OS");
    has("snacks F r1 c1",         snk, "{ \"█▀▀\", hl = \"FoxBannerC1\" },");
    has("snacks O r1 c2",         snk, "{ \"█▀█\", hl = \"FoxBannerC2\" },");
    has("snacks X r1 c3",         snk, "{ \"▀▄▀\", hl = \"FoxBannerC3\" },");
    has("snacks space glyph c4",  snk, "{ \"  \", hl = \"FoxBannerC4\" },");
    has("snacks post-space O c1", snk, "{ \"█▀█\", hl = \"FoxBannerC1\" },");
    has("snacks F r2 c1",         snk, "{ \"█▀ \", hl = \"FoxBannerC1\" },");
    has("snacks F r3 c1",         snk, "{ \"▀  \", hl = \"FoxBannerC1\" },");
    has("snacks row break",       snk, "{ \"\\n\" },");
    has("snacks glyph separator", snk, "{ \" \" },");
    // cross-check: row1 glyph pieces match build_banner's r1 (one shared source)
    {
        BannerBlock z = build_banner("FOX OS");
        for (const char* piece : {"█▀▀", "█▀█", "▀▄▀", "▄▀▀"})
            if (z.r1.find(piece) == std::string::npos) {
                std::fprintf(stderr, "FAIL snacks/zsh glyph mismatch: %s\n", piece);
                ++failed;
            }
    }

    if (failed == 0) {
        std::printf("banner_font tests: OK\n");
        return 0;
    }
    return 1;
}
