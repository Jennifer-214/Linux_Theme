#ifndef FOX_INSTALL_MODULES_BANNER_FONT_HPP
#define FOX_INSTALL_MODULES_BANNER_FONT_HPP

#include <string>

namespace fox_install {

// Three assembled rows of the half-block name banner plus the right-anchor
// span the welcome.zsh splash uses to position it (rc = COLUMNS - width).
struct BannerBlock {
    int         width;        // visible glyph span + 6 margin (FOXML → 27)
    std::string r1, r2, r3;   // shell strings carrying ${c1..c4}/${O} colour refs
};

// Build the banner for `text` (sanitise first). Each glyph cycles c1..c4.
BannerBlock build_banner(const std::string& text);

// Uppercase, keep only [A-Z0-9 ], trim ends, cap at 12 chars; ""→"FOXML".
std::string sanitize_banner_text(const std::string& in);

}  // namespace fox_install

#endif
