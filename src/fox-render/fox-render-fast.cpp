// fox-render-fast — drop-in C++ replacement for render.sh.
//
// Forward mode (default):
//   fox-render-fast <palette.sh> <template_dir> <output_dir>
//   → applies palette substitutions to every file under template_dir,
//     writing to output_dir.
//
// Reverse mode (--reverse):
//   fox-render-fast --reverse <palette.sh> <src_file> <out_file>
//   → reads src_file (a live system config), replaces every concrete
//     hex / RGB triple / string-valued palette match with its
//     {{KEY}} placeholder, writes to out_file. Used by update.sh's
//     capture flow.
//   → refuses (non-zero exit, stderr explanation) when the body
//     contains a danger pattern (curl|bash, exec-once, etc.) per
//     update.sh's _DANGER_PATTERNS list.

#include "palette.hpp"
#include "paper_assets.hpp"
#include "render.hpp"
#include "reverse.hpp"
#include "icon_family.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

namespace {

void usage_forward(const char* argv0) {
    std::fprintf(stderr,
        "Usage: %s <palette.sh> <template_dir> <output_dir>\n"
        "       %s --reverse <palette.sh> <src_file> <out_file>\n",
        argv0, argv0);
}

// Hardcoded last-resort fallback. Mirrors render.sh's `hex_vars=(…)`
// + `str_vars=(…)` blocks for the case where _derive_palette_vars
// finds nothing. Used only when parse_palette returns empty AND no
// other route is viable — almost exclusively a test / corrupted-file
// situation. Empty map signals "nothing to do".
//
// We don't synthesise hex VALUES here (we don't know the active theme)
// — we just declare which KEYS exist so the substitution-table caller
// can warn about unbound markers. This matches the bash behaviour
// where the hardcoded list pins KEY NAMES and any missing VALUE is
// substituted as empty.
std::unordered_map<std::string, std::string> hardcoded_fallback() {
    static const char* HEX_VARS[] = {
        "BG","BG_DARK","BG_ALT","BG_HIGHLIGHT","SELECTION",
        "FG","FG_PASTEL","FG_DIM","COMMENT",
        "PRIMARY","SECONDARY","ACCENT","SURFACE",
        "RED","RED_BRIGHT","GREEN","GREEN_BRIGHT",
        "YELLOW","YELLOW_BRIGHT","BLUE","BLUE_BRIGHT",
        "CYAN","CYAN_BRIGHT","WHITE","OK","WARN",
        "BG_DUNST","BG_SPICETIFY","BG_VENCORD_ALT","BG_VENCORD_DEEP","CARD_HOVER",
        "FZF_ACCENT1","FZF_ACCENT2","ZSH_SUGGEST","ZSH_CMD",
        "TMUX_INACTIVE_FG","TMUX_ACTIVE_FG","TMUX_ACTIVE_BG",
        "DIFF_ADD","DIFF_CHANGE","DIFF_DELETE","DIFF_TEXT","TREESITTER_CTX",
        "WARM","SAND","WHEAT","CLAY","NVIM_BG_HL","NVIM_SEL",
        nullptr,
    };
    static const char* STR_VARS[] = {
        "THEME_TYPE","NVIM_STYLE","NVIM_BG","KITTY_BG_OPACITY","POPUP_BG_OPACITY",
        "SHOW_WELCOME","SHOW_BANNER","WALLPAPER",
        "MAKO_ICON_THEME","VSCODE_UI_THEME","FONT_FAMILY",
        "ANSI_ACCENT1","ANSI_ACCENT2","ANSI_ACCENT3","ANSI_ACCENT4","ANSI_ACCENT5",
        "ANSI_TEXT","ANSI_MUTED","ANSI_ERROR","ANSI_OK","ANSI_STANDOUT_BG",
        "ANSI_PROMPT","ANSI_PROMPT2","ANSI_LOAD",
        "GRAD1","GRAD2","GRAD3","GRAD4","GRAD5",
        "TMUX_ACTIVE","TMUX_INACTIVE",
        nullptr,
    };
    std::unordered_map<std::string, std::string> out;
    for (auto** v = HEX_VARS; *v; ++v) {
        out["{{" + std::string(*v) + "}}"] = "";
    }
    for (auto** v = STR_VARS; *v; ++v) {
        out["{{" + std::string(*v) + "}}"] = "";
    }
    return out;
}

std::string slurp(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

bool write_atomic(const fs::path& dest, const std::string& body) {
    std::error_code ec;
    fs::create_directories(dest.parent_path(), ec);
    fs::path tmp = dest;
    tmp += ".foxren.tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out.write(body.data(), static_cast<std::streamsize>(body.size()));
        if (!out) return false;
    }
    fs::rename(tmp, dest, ec);
    if (ec) { fs::remove(tmp, ec); return false; }
    return true;
}

int run_reverse(int argc, char** argv) {
    if (argc < 5) {
        std::fprintf(stderr,
            "Usage: %s --reverse <palette.sh> <src_file> <out_file>\n", argv[0]);
        return 2;
    }
    const std::string palette_path = argv[2];
    const std::string src_path     = argv[3];
    const std::string out_path     = argv[4];

    if (!fs::exists(palette_path)) {
        std::fprintf(stderr, "fox-render-fast: palette not found: %s\n",
                     palette_path.c_str());
        return 1;
    }
    if (!fs::exists(src_path)) {
        std::fprintf(stderr, "fox-render-fast: source not found: %s\n",
                     src_path.c_str());
        return 1;
    }

    auto palette = fox_render::parse_palette(palette_path);
    if (palette.empty()) {
        std::fprintf(stderr,
            "fox-render-fast: palette parsed empty (%s)\n",
            palette_path.c_str());
        return 1;
    }

    std::string body = slurp(src_path);
    std::string danger = fox_render::scan_danger(body);
    if (!danger.empty()) {
        std::fprintf(stderr,
            "fox-render-fast: DANGER PATTERN in %s — %s\n"
            "  refusing to reverse-capture (might publish a payload).\n"
            "  edit templates/<file> directly + commit instead.\n",
            src_path.c_str(), danger.c_str());
        return 3;
    }

    auto rules = fox_render::build_reverse_rules(palette);
    std::string out = fox_render::apply_reverse(body, rules);
    if (!write_atomic(out_path, out)) {
        std::fprintf(stderr, "fox-render-fast: write failed: %s\n",
                     out_path.c_str());
        return 1;
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc == 5 && std::string(argv[1]) == "--finish-assets") {
        return fox_render::finish_icon_family(argv[3], argv[4], fox_render::parse_palette(argv[2])) &&
            fox_render::finish_paper_assets(argv[3], argv[4]) ? 0 : 1;
    }
    if (argc == 5 && std::string(argv[1]) == "--finish-icons") {
        return fox_render::finish_icon_family(argv[3],argv[4],fox_render::parse_palette(argv[2])) ? 0 : 1;
    }
    // Reverse mode dispatch.
    if (argc >= 2 && std::string(argv[1]) == "--reverse") {
        return run_reverse(argc, argv);
    }

    if (argc < 4) { usage_forward(argv[0]); return 2; }

    const std::string palette_path = argv[1];
    const std::string template_dir = argv[2];
    const std::string output_dir   = argv[3];

    if (!fs::exists(palette_path)) {
        std::fprintf(stderr, "fox-render-fast: palette not found: %s\n",
                     palette_path.c_str());
        return 1;
    }
    if (!fs::is_directory(template_dir)) {
        std::fprintf(stderr, "fox-render-fast: not a directory: %s\n",
                     template_dir.c_str());
        return 1;
    }

    auto table = fox_render::parse_palette(palette_path);
    if (table.empty()) {
        // Bash fell back to a hardcoded var list with empty values so
        // unit tests / corrupted palettes don't crash the render. We
        // match that — substitutions become no-ops but the loop runs.
        std::fprintf(stderr,
            "fox-render-fast: palette parsed empty — using hardcoded "
            "fallback var list (substitutions will be no-ops).\n");
        table = hardcoded_fallback();
    }

    bool show_progress = isatty(fileno(stderr));
    auto t0 = std::chrono::steady_clock::now();
    const auto result = fox_render::render_tree(template_dir, output_dir, table, show_progress);
    if (result.failed > 0) {
        std::fprintf(stderr, "fox-render-fast: %zu of %zu files could not be written; refusing an incomplete render\n",
                     result.failed, result.failed + result.rendered);
        return 1;
    }
    if (!fox_render::finish_icon_family(template_dir,output_dir,table)) {
        std::fprintf(stderr,"fox-render-fast: icon-family generation failed; refusing an incomplete render\n");
        return 1;
    }
    if (!fox_render::finish_paper_assets(template_dir, output_dir)) {
        std::fprintf(stderr, "fox-render-fast: shared Paper artwork did not render\n");
        return 1;
    }
    auto t1 = std::chrono::steady_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();

    std::fprintf(stderr, "Rendered %zu templates to: %s (%lld ms)\n",
                 result.rendered, output_dir.c_str(), static_cast<long long>(ms));
    return 0;
}
