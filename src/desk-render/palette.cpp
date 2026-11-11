#include "palette.hpp"

#include <cctype>
#include <cstdio>
#include <fstream>
#include <sstream>

namespace fox_render {

namespace {

bool is_upper_ident_start(char c) {
    return c == '_' || (c >= 'A' && c <= 'Z');
}

bool is_upper_ident_rest(char c) {
    return c == '_' || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

void strip_inline_comment_and_quotes(std::string& v) {
    // Trim leading whitespace.
    size_t i = 0;
    while (i < v.size() && (v[i] == ' ' || v[i] == '\t')) ++i;
    v.erase(0, i);

    // Drop inline `#...` comment (matches render.sh's `val=${val%%#*}`).
    size_t hash = v.find('#');
    if (hash != std::string::npos) v.erase(hash);

    // Trim trailing whitespace.
    while (!v.empty() && (v.back() == ' ' || v.back() == '\t' ||
                          v.back() == '\r' || v.back() == '\n')) {
        v.pop_back();
    }

    // Strip one matching pair of surrounding quotes (single or double).
    if (v.size() >= 2 &&
        ((v.front() == '"'  && v.back() == '"') ||
         (v.front() == '\'' && v.back() == '\''))) {
        v.erase(v.size() - 1, 1);
        v.erase(0, 1);
    }
}

bool is_six_char_hex(const std::string& s) {
    if (s.size() != 6) return false;
    for (char c : s) {
        if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
    }
    return true;
}

bool is_skip_name(const std::string& name) {
    return name == "PALETTE_LABELS" ||
           name == "PALETTE_NAME"   ||
           name == "PALETTE_DESCRIPTION";
}

void emit_rgb(std::unordered_map<std::string, std::string>& out,
              const std::string& name, const std::string& hex) {
    auto hex2 = [&](size_t off) -> int {
        char buf[3] = { hex[off], hex[off + 1], 0 };
        return static_cast<int>(std::strtol(buf, nullptr, 16));
    };
    char rbuf[8], gbuf[8], bbuf[8];
    std::snprintf(rbuf, sizeof(rbuf), "%d", hex2(0));
    std::snprintf(gbuf, sizeof(gbuf), "%d", hex2(2));
    std::snprintf(bbuf, sizeof(bbuf), "%d", hex2(4));
    out["{{" + name + "_R}}"] = rbuf;
    out["{{" + name + "_G}}"] = gbuf;
    out["{{" + name + "_B}}"] = bbuf;
}

}  // namespace

std::unordered_map<std::string, std::string>
parse_palette(const std::string& palette_path) {
    std::unordered_map<std::string, std::string> table;
    std::ifstream in(palette_path);
    if (!in) return table;

    std::string line;
    while (std::getline(in, line)) {
        // Skip blank / comment lines.
        size_t lead = 0;
        while (lead < line.size() && (line[lead] == ' ' || line[lead] == '\t')) ++lead;
        if (lead >= line.size()) continue;
        if (line[lead] == '#') continue;

        // Identifier must be ALL_CAPS and followed by `=`.
        if (!is_upper_ident_start(line[lead])) continue;
        size_t p = lead;
        while (p < line.size() && is_upper_ident_rest(line[p])) ++p;
        if (p >= line.size() || line[p] != '=') continue;

        std::string name(line, lead, p - lead);
        if (is_skip_name(name)) continue;

        std::string val(line, p + 1, std::string::npos);
        strip_inline_comment_and_quotes(val);
        if (val.empty()) continue;

        if (is_six_char_hex(val)) {
            table["{{" + name + "}}"] = val;
            emit_rgb(table, name, val);
        } else {
            table["{{" + name + "}}"] = val;

            // Special case: convert *_BG_OPACITY (0.0-1.0) to hex alpha (00-ff).
            // KITTY_BG_OPACITY → {{KITTY_BG_OPACITY_HEX}}  (used by kitty)
            // POPUP_BG_OPACITY → {{POPUP_BG_OPACITY_HEX}}  (used by mako/dunst)
            if (name == "KITTY_BG_OPACITY" || name == "POPUP_BG_OPACITY") {
                double o = std::strtod(val.c_str(), nullptr);
                int alpha = static_cast<int>(o * 255.0 + 0.5);
                if (alpha < 0) alpha = 0;
                if (alpha > 255) alpha = 255;
                char abuf[4];
                std::snprintf(abuf, sizeof(abuf), "%02x", alpha);
                table["{{" + name + "_HEX}}"] = abuf;
            }
        }
    }
    return table;
}

}  // namespace fox_render
