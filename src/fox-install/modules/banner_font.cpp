// modules/banner_font.cpp — half-block name-banner font + constructor.
//
// Pure (no Context/ui/shell deps) so it unit-tests cleanly. The glyph table is
// the single source of truth for the welcome.zsh splash lettering; the
// welcome_banner module bakes the assembled rows into welcome.zsh at install.
// Glyphs are 3 cells wide except M/W (5) and N (4); space is 2.

#include "banner_font.hpp"

#include <cstddef>
#include <vector>

namespace fox_install {
namespace {

struct Glyph { int w; const char* r1; const char* r2; const char* r3; };

const Glyph* glyph_for(char c) {
    switch (c) {
        case 'A': { static const Glyph g{3, "▄▀▄",   "█▀█",   "▀ ▀"};   return &g; }
        case 'B': { static const Glyph g{3, "█▀▄",   "█▀▄",   "▀▀▀"};   return &g; }
        case 'C': { static const Glyph g{3, "▄▀▀",   "█  ",   "▀▀▀"};   return &g; }
        case 'D': { static const Glyph g{3, "█▀▄",   "█ █",   "▀▀ "};   return &g; }
        case 'E': { static const Glyph g{3, "█▀▀",   "█▀▀",   "▀▀▀"};   return &g; }
        case 'F': { static const Glyph g{3, "█▀▀",   "█▀ ",   "▀  "};   return &g; }
        case 'G': { static const Glyph g{3, "▄▀▀",   "█ ▄",   "▀▀▀"};   return &g; }
        case 'H': { static const Glyph g{3, "█ █",   "█▀█",   "▀ ▀"};   return &g; }
        case 'I': { static const Glyph g{3, "▀█▀",   " █ ",   "▀▀▀"};   return &g; }
        case 'J': { static const Glyph g{3, "▀▀█",   "  █",   "▀▀ "};   return &g; }
        case 'K': { static const Glyph g{3, "█ ▄",   "█▀▄",   "▀ ▀"};   return &g; }
        case 'L': { static const Glyph g{3, "█  ",   "█  ",   "▀▀▀"};   return &g; }
        case 'M': { static const Glyph g{5, "█▀▄▀█", "█ ▀ █", "▀   ▀"}; return &g; }
        case 'N': { static const Glyph g{4, "█▄ █",  "█ ▀█",  "▀  ▀"};  return &g; }
        case 'O': { static const Glyph g{3, "█▀█",   "█ █",   "▀▀▀"};   return &g; }
        case 'P': { static const Glyph g{3, "█▀█",   "█▀▀",   "▀  "};   return &g; }
        case 'Q': { static const Glyph g{3, "█▀█",   "█ █",   "▀▀▄"};   return &g; }
        case 'R': { static const Glyph g{3, "█▀█",   "█▀▄",   "▀ ▀"};   return &g; }
        case 'S': { static const Glyph g{3, "▄▀▀",   " ▀▄",   "▀▀ "};   return &g; }
        case 'T': { static const Glyph g{3, "▀█▀",   " █ ",   " ▀ "};   return &g; }
        case 'U': { static const Glyph g{3, "█ █",   "█ █",   "▀▀▀"};   return &g; }
        case 'V': { static const Glyph g{3, "█ █",   "█ █",   " ▀ "};   return &g; }
        case 'W': { static const Glyph g{5, "█   █", "█ ▄ █", "▀▀ ▀▀"}; return &g; }
        case 'X': { static const Glyph g{3, "▀▄▀",   " █ ",   "▀ ▀"};   return &g; }
        case 'Y': { static const Glyph g{3, "█ █",   "▀█▀",   " ▀ "};   return &g; }
        case 'Z': { static const Glyph g{3, "▀▀█",   " ▄▀",   "▀▀▀"};   return &g; }
        case '0': { static const Glyph g{3, "█▀█",   "█▄█",   "▀▀▀"};   return &g; }
        case '1': { static const Glyph g{3, "▀█ ",   " █ ",   "▀▀▀"};   return &g; }
        case '2': { static const Glyph g{3, "▀▀█",   "▄▀▀",   "▀▀▀"};   return &g; }
        case '3': { static const Glyph g{3, "▀▀█",   " ▀█",   "▀▀▀"};   return &g; }
        case '4': { static const Glyph g{3, "█ █",   "▀▀█",   "  ▀"};   return &g; }
        case '5': { static const Glyph g{3, "█▀▀",   "▀▀▄",   "▀▀ "};   return &g; }
        case '6': { static const Glyph g{3, "▄▀▀",   "█▀▄",   "▀▀▀"};   return &g; }
        case '7': { static const Glyph g{3, "▀▀█",   " ▄▀",   "▀  "};   return &g; }
        case '8': { static const Glyph g{3, "▄▀▄",   "█▀█",   "▀▀▀"};   return &g; }
        case '9': { static const Glyph g{3, "▄▀▄",   "▀▀█",   "▀▀▀"};   return &g; }
        case ' ': { static const Glyph g{2, "  ",    "  ",    "  "};    return &g; }
        default:  return nullptr;
    }
}

const char* const COL[4] = {"${c1}", "${c2}", "${c3}", "${c4}"};

// The warm cycle in each surface's native color form (same 4 slots as COL):
// hyprlock = render tokens inside a pango span (## escapes the hyprlang comment
// char); nvim = highlight-group names defined in init.lua's colorscheme.
const char* const HYPR_TOK[4]  = {"{{CLAY}}", "{{WHEAT}}", "{{BLUSH}}", "{{ACCENT}}"};
const char* const SNACKS_HL[4] = {"FoxBannerC1", "FoxBannerC2", "FoxBannerC3", "FoxBannerC4"};

}  // namespace

BannerBlock build_banner(const std::string& text) {
    std::vector<const Glyph*> gs;
    for (char c : text)
        if (const Glyph* g = glyph_for(c)) gs.push_back(g);
    if (gs.empty()) gs.push_back(glyph_for(' '));

    std::string r1, r2, r3;
    int visible = 0;
    for (std::size_t i = 0; i < gs.size(); ++i) {
        const Glyph* g = gs[i];
        const char* col = COL[i % 4];
        if (i) { r1 += ' '; r2 += ' '; r3 += ' '; }
        r1 += col; r1 += g->r1; r1 += "${O}";
        r2 += col; r2 += g->r2; r2 += "${O}";
        r3 += col; r3 += g->r3; r3 += "${O}";
        visible += g->w + (i ? 1 : 0);   // +1 gap before every glyph after the first
    }
    return BannerBlock{visible + 6, r1, r2, r3};
}

std::string sanitize_banner_text(const std::string& in) {
    std::string out;
    for (char c : in) {
        if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ' ')
            out += c;
        if (out.size() >= 12) break;
    }
    std::size_t s = out.find_first_not_of(' ');
    if (s == std::string::npos) return "FOX OS";
    std::size_t e = out.find_last_not_of(' ');
    out = out.substr(s, e - s + 1);
    return out.empty() ? "FOX OS" : out;
}

std::string banner_to_hyprlock_text(const std::string& text) {
    std::string out;
    bool prev_letter = false;
    int i = 0;
    for (char c : text) {
        if (c == ' ') {
            out += "    ";                         // word gap (4 spaces)
        } else {
            if (prev_letter) out += "   ";         // inter-letter tracking (3)
            out += "<span foreground='##";
            out += HYPR_TOK[i % 4];
            out += "'>";
            out += c;
            out += "</span>";
        }
        prev_letter = (c != ' ');
        ++i;                                       // every glyph advances the cycle
    }
    return out;
}

std::string banner_to_snacks_blocks(const std::string& text) {
    std::vector<const Glyph*> gs;
    for (char c : text)
        if (const Glyph* g = glyph_for(c)) gs.push_back(g);
    if (gs.empty()) gs.push_back(glyph_for(' '));

    // Same shape + cycle as build_banner: one colored segment per glyph piece,
    // a separator space between glyphs, three rows split by { "\n" }.
    std::string out;
    for (int row = 0; row < 3; ++row) {
        if (row) out += "          { \"\\n\" },\n";
        for (std::size_t i = 0; i < gs.size(); ++i) {
            const char* p = row == 0 ? gs[i]->r1 : row == 1 ? gs[i]->r2 : gs[i]->r3;
            if (i) out += "          { \" \" },\n";
            out += "          { \"";
            out += p;
            out += "\", hl = \"";
            out += SNACKS_HL[i % 4];
            out += "\" },\n";
        }
    }
    if (!out.empty() && out.back() == '\n') out.pop_back();
    return out;
}

}  // namespace fox_install
