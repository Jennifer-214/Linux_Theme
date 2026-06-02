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

// Uppercase, keep only [A-Z0-9 ], trim ends, cap at 12 chars; ""→"FOX OS".
std::string sanitize_banner_text(const std::string& in);

// Per-surface colorizers over the sanitised text. Both cycle the same 4 warm
// slots (clay·wheat·mauve·sage) by glyph index — matching build_banner, so a
// space consumes a slot but renders uncolored — so every entry surface shares
// one color rhythm from the one WELCOME_TEXT source ([I-06]). Pure → unit-tested.

// hyprlock label value: per-letter pango <span foreground='##{{TOKEN}}'>C</span>,
// wide-tracked (3 spaces between letters, 4 at a word gap). '#'→'##' is the
// hyprlang comment escape; input is [A-Z0-9 ] so there is no &/< to escape.
std::string banner_to_hyprlock_text(const std::string& text);

// nvim Snacks header brand: the SAME half-block art as the zsh welcome
// (build_banner glyphs), as a 3-row Lua segment list — each glyph piece its own
// { "<piece>", hl = "FoxBannerCN" } segment cycling C1..4, rows split by
// { "\n" }. The editor dashboard matches the terminal welcome glyph-for-glyph.
std::string banner_to_snacks_blocks(const std::string& text);

}  // namespace fox_install

#endif
