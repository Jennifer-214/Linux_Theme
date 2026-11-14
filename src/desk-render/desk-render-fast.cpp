// desk-render-fast — drop-in C++ replacement for render.sh.
//
// Forward mode (default):
//   desk-render-fast <palette.sh> <template_dir> <output_dir>
//   → applies palette substitutions to every file under template_dir,
//     writing to output_dir.
//
// Reverse mode (--reverse):
//   desk-render-fast --reverse <palette.sh> <src_file> <out_file>
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
        std::fprintf(stderr, "desk-render-fast: palette not found: %s\n",
                     palette_path.c_str());
        return 1;
    }
    if (!fs::exists(src_path)) {
        std::fprintf(stderr, "desk-render-fast: source not found: %s\n",
                     src_path.c_str());
        return 1;
    }

    auto palette = desk_render::parse_palette(palette_path);
    if (palette.empty()) {
        std::fprintf(stderr,
            "desk-render-fast: palette parsed empty (%s)\n",
            palette_path.c_str());
        return 1;
    }

    std::string body = slurp(src_path);
    std::string danger = desk_render::scan_danger(body);
    if (!danger.empty()) {
        std::fprintf(stderr,
            "desk-render-fast: DANGER PATTERN in %s — %s\n"
            "  refusing to reverse-capture (might publish a payload).\n"
            "  edit templates/<file> directly + commit instead.\n",
            src_path.c_str(), danger.c_str());
        return 3;
    }

    auto rules = desk_render::build_reverse_rules(palette);
    std::string out = desk_render::apply_reverse(body, rules);
    if (!write_atomic(out_path, out)) {
        std::fprintf(stderr, "desk-render-fast: write failed: %s\n",
                     out_path.c_str());
        return 1;
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc == 5 && std::string(argv[1]) == "--finish-assets") {
        return desk_render::finish_icon_family(argv[3], argv[4], desk_render::parse_palette(argv[2])) &&
            desk_render::finish_paper_assets(argv[3], argv[4]) ? 0 : 1;
    }
    if (argc == 5 && std::string(argv[1]) == "--finish-icons") {
        return desk_render::finish_icon_family(argv[3],argv[4],desk_render::parse_palette(argv[2])) ? 0 : 1;
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
        std::fprintf(stderr, "desk-render-fast: palette not found: %s\n",
                     palette_path.c_str());
        return 1;
    }
    if (!fs::is_directory(template_dir)) {
        std::fprintf(stderr, "desk-render-fast: not a directory: %s\n",
                     template_dir.c_str());
        return 1;
    }

    // An empty or unreadable palette has nothing to render with: every colour would come out blank ("background #")
    // and be deployed as a good render. Refuse, as the reverse mode does.
    const auto table = desk_render::parse_palette(palette_path);
    if (table.empty()) {
        std::fprintf(stderr, "desk-render-fast: palette parsed empty (%s); refusing to render blank colours\n",
                     palette_path.c_str());
        return 1;
    }

    bool show_progress = isatty(fileno(stderr));
    auto t0 = std::chrono::steady_clock::now();
    const auto result = desk_render::render_tree(template_dir, output_dir, table, show_progress);
    if (result.failed > 0) {
        std::fprintf(stderr, "desk-render-fast: %zu of %zu files could not be written; refusing an incomplete render\n",
                     result.failed, result.failed + result.rendered);
        return 1;
    }
    if (!desk_render::finish_icon_family(template_dir,output_dir,table)) {
        std::fprintf(stderr,"desk-render-fast: icon-family generation failed; refusing an incomplete render\n");
        return 1;
    }
    if (!desk_render::finish_paper_assets(template_dir, output_dir)) {
        std::fprintf(stderr, "desk-render-fast: shared Paper artwork did not render\n");
        return 1;
    }
    auto t1 = std::chrono::steady_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();

    std::fprintf(stderr, "Rendered %zu templates to: %s (%lld ms)\n",
                 result.rendered, output_dir.c_str(), static_cast<long long>(ms));
    return 0;
}
