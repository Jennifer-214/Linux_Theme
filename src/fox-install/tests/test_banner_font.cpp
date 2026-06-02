// Unit test for the pure banner constructor (modules/banner_font.cpp).
// Locks the FOXML output + width and the sanitiser contract.

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
    eq("sanitize lower",     sanitize_banner_text("fox ml"), "FOX ML");
    eq("sanitize strip",     sanitize_banner_text("a@b!c"),  "ABC");
    eq("sanitize blank",     sanitize_banner_text("   "),    "FOXML");
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

    // ── colour cycle wraps past 4 (5th glyph back to c1) ──
    BannerBlock e = build_banner("ABCDE");
    // E is the 5th glyph → c1; its row1 glyph is "█▀▀"
    if (e.r1.rfind("${c1}█▀▀${O}") == std::string::npos) {
        std::fprintf(stderr, "FAIL colour-cycle wrap (E should be c1)\n");
        ++failed;
    }

    if (failed == 0) {
        std::printf("banner_font tests: OK\n");
        return 0;
    }
    return 1;
}
