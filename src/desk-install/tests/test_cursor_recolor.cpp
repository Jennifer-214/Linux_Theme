// Unit test for modules/cursor_recolor.hpp. Locks: token parsing, premultiplied
// pixel repainting, every-frame coverage, rejection of malformed files, and the
// build's atomicity + stamp.

#include "../modules/cursor_recolor.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>
#include <vector>

using namespace fox_install::cursor_recolor;

namespace {

int failed = 0;

void check(const char* name, bool ok) {
    if (!ok) {
        std::printf("FAIL: %s\n", name);
        ++failed;
    }
}

void put(std::string& s, uint32_t v) { s.append(reinterpret_cast<const char*>(&v), 4); }

struct Px {
    unsigned char b, g, r, a;
};

// One image chunk per frame, the shape xcursorgen writes.
std::string xcursor(const std::vector<std::vector<Px>>& frames) {
    const uint32_t n = static_cast<uint32_t>(frames.size());
    std::string s = "Xcur";
    put(s, 16); put(s, 0x10000); put(s, n);
    uint32_t pos = 16 + n * 12;
    for (const auto& f : frames) {
        put(s, 0xfffd0002); put(s, 24); put(s, pos);
        pos += 36 + static_cast<uint32_t>(f.size()) * 4;
    }
    for (const auto& f : frames) {
        put(s, 36); put(s, 0xfffd0002); put(s, 24); put(s, 1);
        put(s, static_cast<uint32_t>(f.size())); put(s, 1); put(s, 0); put(s, 0); put(s, 50);
        for (const Px& p : f) s.append(reinterpret_cast<const char*>(&p), 4);
    }
    return s;
}

Px pixel(const std::string& s, size_t frames, size_t frame, size_t width, size_t index) {
    const size_t at = 16 + frames * 12 + (frame + 1) * 36 + frame * width * 4 + index * 4;
    return {static_cast<unsigned char>(s[at]), static_cast<unsigned char>(s[at + 1]),
            static_cast<unsigned char>(s[at + 2]), static_cast<unsigned char>(s[at + 3])};
}

bool is(Px p, int r, int g, int b, int a) { return p.r == r && p.g == g && p.b == b && p.a == a; }

const char* TOKEN = "base-cursors:f5c2e7:1e1e2e:edb0c4:3c3c40";

}  // namespace

int main() {
    // ── token ──────────────────────────────────────────────────────────
    const auto rc = parse_recolor(TOKEN);
    check("valid token", rc.has_value() && rc->base == "base-cursors");
    check("none is not a recolor", !parse_recolor("none"));
    check("missing field", !parse_recolor("base:f5c2e7:1e1e2e:edb0c4"));
    check("bad hex", !parse_recolor("base:f5c2e7:1e1e2e:edb0c4:zzzzzz"));
    check("short hex", !parse_recolor("base:f5c2e7:1e1e2e:edb0c4:3c3"));
    check("path in base refused", !parse_recolor("../evil:f5c2e7:1e1e2e:edb0c4:3c3c40"));
    check("no flower by default", !rc->flower);
    check("flower option", parse_recolor(std::string(TOKEN) + ":flower")->flower);
    check("unknown option refused", !parse_recolor(std::string(TOKEN) + ":sparkles"));
    if (!rc) return 1;

    // ── pixels ─────────────────────────────────────────────────────────
    {
        const std::vector<Px> frame = {
            {0xe7, 0xc2, 0xf5, 255},  // fill
            {0x2e, 0x1e, 0x1e, 255},  // outline
            {0, 0, 0, 0},             // transparent stays
            {0x74, 0x61, 0x7b, 128},  // fill at half alpha, premultiplied
        };
        std::string s = xcursor({frame, frame});
        const size_t size = s.size();
        check("well-formed file accepted", recolor_xcursor(s, *rc));
        check("size unchanged", s.size() == size);
        check("fill repainted", is(pixel(s, 2, 0, 4, 0), 0xed, 0xb0, 0xc4, 255));
        check("outline repainted", is(pixel(s, 2, 0, 4, 1), 0x3c, 0x3c, 0x40, 255));
        check("transparent untouched", is(pixel(s, 2, 0, 4, 2), 0, 0, 0, 0));
        const Px half = pixel(s, 2, 0, 4, 3);
        check("premultiplied alpha kept", half.a == 128);
        check("premultiplied colour scaled",
              std::abs(half.r - 0xed / 2) <= 2 && std::abs(half.g - 0xb0 / 2) <= 2 &&
              std::abs(half.b - 0xc4 / 2) <= 2);
        check("later animation frames repainted", is(pixel(s, 2, 1, 4, 0), 0xed, 0xb0, 0xc4, 255));
    }
    {
        std::string bad = "not a cursor at all";
        check("wrong magic rejected", !recolor_xcursor(bad, *rc));
        std::string truncated = xcursor({{{0, 0, 0, 255}}});
        truncated.resize(truncated.size() - 2);
        check("truncated rejected", !recolor_xcursor(truncated, *rc));
        std::string huge_toc = xcursor({{{0, 0, 0, 255}}});
        const uint32_t many = 0xffffff;
        std::memcpy(&huge_toc[12], &many, 4);
        check("oversized toc rejected", !recolor_xcursor(huge_toc, *rc));
    }

    // ── theme build ────────────────────────────────────────────────────
    {
        const fs::path root = fs::temp_directory_path() / ("fox_cursor_" + std::to_string(::getpid()));
        const fs::path src = root / "base-cursors", dest = root / "derived-cursors";
        fs::create_directories(src / "cursors");
        std::ofstream(src / "cursors/default", std::ios::binary) << xcursor({{{0xe7, 0xc2, 0xf5, 255}}});
        fs::create_symlink("default", src / "cursors/left_ptr");
        std::ofstream(src / "LICENSE") << "license\n";

        check("not current before build", !is_current(dest, *rc));
        check("build succeeds", build_theme(src, dest, "derived-cursors", *rc));
        check("stamp matches", is_current(dest, *rc));
        check("different colours are stale",
              !is_current(dest, *parse_recolor("base-cursors:f5c2e7:1e1e2e:ffffff:3c3c40")));
        check("cursor repainted", is(pixel(read_file(dest / "cursors/default"), 1, 0, 1, 0), 0xed, 0xb0, 0xc4, 255));
        check("alias stays a symlink", fs::is_symlink(dest / "cursors/left_ptr"));
        check("licence carried", fs::exists(dest / "LICENSE"));
        check("named theme", read_file(dest / "index.theme").find("Name=derived-cursors\n") != std::string::npos);

        std::ofstream(src / "cursors/broken", std::ios::binary) << "garbage";
        const std::string before = read_file(dest / "cursors/default");
        check("corrupt source fails the build", !build_theme(src, dest, "derived-cursors", *rc));
        check("failed build keeps the old set", read_file(dest / "cursors/default") == before);
        check("failed build leaves no temp dir", !fs::exists(root / "derived-cursors.foxin-tmp"));
        fs::remove_all(root);
    }

    // ── flower ─────────────────────────────────────────────────────────
    {
        const auto flower = parse_recolor(std::string(TOKEN) + ":flower");
        const fs::path root = fs::temp_directory_path() / ("fox_flower_" + std::to_string(::getpid()));
        const fs::path src = root / "base-cursors", dest = root / "derived-cursors";
        fs::create_directories(src / "cursors");
        const auto arrow = [](uint32_t nominal, uint32_t edge) {
            Image image{nominal, edge, edge, 2, 3, 0, std::vector<unsigned char>(edge * edge * 4, 0)};
            image.bgra[0] = 0x2e; image.bgra[1] = 0x1e; image.bgra[2] = 0x1e; image.bgra[3] = 255;
            return image;
        };
        std::ofstream(src / "cursors/default", std::ios::binary) << write_images({arrow(24, 32), arrow(48, 64)});
        std::ofstream(src / "cursors/wait", std::ios::binary) << xcursor({{{0xe7, 0xc2, 0xf5, 255}}});
        fs::create_symlink("default", src / "cursors/progress");  // must not write through to default

        check("flower build succeeds", build_theme(src, dest, "derived-cursors", *flower));
        const auto wait = read_images(read_file(dest / "cursors/wait"));
        const auto busy = read_images(read_file(dest / "cursors/progress"));
        check("twelve frames per size", wait.size() == 24 && busy.size() == 24);
        check("sizes kept", !wait.empty() && wait.front().nominal == 24 && wait.back().nominal == 48);
        if (wait.size() == 24 && busy.size() == 24) {
            check("wait is centred", wait[0].xhot == 16 && wait[0].yhot == 16 && wait[12].xhot == 32);
            check("progress keeps the arrow's tip", busy[0].xhot == 2 && busy[0].yhot == 3);
            check("frames turn", wait[0].bgra != wait[1].bgra);
            check("frames have a delay", wait[0].delay > 0 && busy[0].delay > 0);
            size_t fill = 0, ink = 0, clear_corner = wait[0].bgra[3] == 0;
            for (size_t p = 0; p + 3 < wait[0].bgra.size(); p += 4) {
                const auto* px = &wait[0].bgra[p];
                if (px[3] == 255 && px[2] == 0xed && px[1] == 0xb0 && px[0] == 0xc4) ++fill;
                if (px[3] == 255 && px[2] == 0x3c && px[1] == 0x3c && px[0] == 0x40) ++ink;
            }
            check("petals use the fill", fill > 50);
            check("outline uses the ink", ink > 10);
            check("corners stay clear", clear_corner);
            check("the centre has no hole", wait[0].bgra[(16 * 32 + 16) * 4 + 3] == 255);
            check("arrow survives under the small flower", busy[0].bgra[3] == 255);
        }
        check("default isn't written through a link", read_images(read_file(dest / "cursors/default")).size() == 2);
        check("no flower without the option", [&] {
            const fs::path plain = root / "plain-cursors";
            return build_theme(src, plain, "plain-cursors", *rc) &&
                   read_images(read_file(plain / "cursors/wait")).size() == 1;
        }());

        std::ofstream(src / "cursors/default", std::ios::binary) << "garbage";
        check("a broken default fails the flower build", !build_theme(src, root / "broken", "broken", *flower));
        fs::remove_all(root);
    }

    if (failed == 0) std::printf("test_cursor_recolor: OK\n");
    return failed ? 1 : 0;
}
