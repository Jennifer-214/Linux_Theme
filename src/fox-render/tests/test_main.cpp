// Minimal unit tests for fox-render's pure functions.
// Run via `make -C src/fox-render test`. Exits non-zero on first failure.

#include <filesystem>
#include <fstream>
#include <unistd.h>
#include "../palette.hpp"
#include "../render.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>

namespace {

int g_failed = 0;

#define EXPECT(cond) do {                                              \
    if (!(cond)) {                                                     \
        std::fprintf(stderr, "FAIL %s:%d  %s\n",                       \
                     __FILE__, __LINE__, #cond);                       \
        ++g_failed;                                                    \
    }                                                                  \
} while (0)

void write_file(const std::string& path, const std::string& body) {
    std::ofstream f(path);
    f << body;
}

void test_palette_basic_hex() {
    write_file("/tmp/foxren_test_palette.sh",
        "BG=1a1214\nFG=d5c4b0\nKITTY_BG_OPACITY=0.6\n"
        "# comment line\n"
        "FONT_FAMILY=\"Hack Nerd Font\"\n"
        "PALETTE_NAME=Skip\n");
    auto t = fox_render::parse_palette("/tmp/foxren_test_palette.sh");
    EXPECT(t["{{BG}}"]   == "1a1214");
    EXPECT(t["{{BG_R}}"] == "26");      // 0x1a
    EXPECT(t["{{BG_G}}"] == "18");      // 0x12
    EXPECT(t["{{BG_B}}"] == "20");      // 0x14
    EXPECT(t["{{FG}}"]   == "d5c4b0");
    EXPECT(t["{{KITTY_BG_OPACITY}}"] == "0.6");
    EXPECT(t["{{FONT_FAMILY}}"] == "Hack Nerd Font");
    EXPECT(t.find("{{PALETTE_NAME}}") == t.end());
}

void test_substitution_unknown_passes_through() {
    std::unordered_map<std::string, std::string> t = { {"{{BG}}", "1a1214"} };
    EXPECT(fox_render::apply_substitutions("c={{BG}}", t) == "c=1a1214");
    EXPECT(fox_render::apply_substitutions("c={{NOPE}}", t) == "c={{NOPE}}");
    EXPECT(fox_render::apply_substitutions("plain", t) == "plain");
}

void test_substitution_overlapping_braces() {
    // Regression: %F{{{BG}}} must resolve to %F{1a1214}, mirroring sed.
    std::unordered_map<std::string, std::string> t = { {"{{BG}}", "1a1214"} };
    EXPECT(fox_render::apply_substitutions("%F{{{BG}}}!", t) == "%F{1a1214}!");
}

void test_substitution_malformed_marker_safe() {
    std::unordered_map<std::string, std::string> t = { {"{{X}}", "ok"} };
    // Whitespace inside marker -> pass through.
    EXPECT(fox_render::apply_substitutions("{{ X }}", t) == "{{ X }}");
    // Unterminated marker -> pass through.
    EXPECT(fox_render::apply_substitutions("tail {{X", t) == "tail {{X");
}

// A file sitting where an output directory belongs: the write fails and the render has to say so.
void test_write_failure_is_reported() {
    namespace fs = std::filesystem;
    char pattern[] = "/tmp/fox-render-write-XXXXXX";
    if (!::mkdtemp(pattern)) { ++g_failed; return; }
    const fs::path root(pattern);
    fs::create_directories(root / "templates/kitty");
    std::ofstream(root / "templates/kitty/kitty.conf") << "x\n";
    std::ofstream(root / "templates/plain.conf") << "y\n";
    fs::create_directories(root / "out");
    std::ofstream(root / "out/kitty") << "in the way\n";

    const auto result = fox_render::render_tree((root / "templates").string(), (root / "out").string(), {}, false);
    if (result.failed != 1 || result.rendered != 1) {
        std::fprintf(stderr, "write failure: rendered %zu, failed %zu\n", result.rendered, result.failed);
        ++g_failed;
    }
    fs::remove_all(root);
}

}  // namespace

int main() {
    test_write_failure_is_reported();
    test_palette_basic_hex();
    test_substitution_unknown_passes_through();
    test_substitution_overlapping_braces();
    test_substitution_malformed_marker_safe();
    if (g_failed == 0) {
        std::printf("fox-render tests: OK\n");
        return 0;
    }
    std::fprintf(stderr, "fox-render tests: %d failure(s)\n", g_failed);
    return 1;
}
