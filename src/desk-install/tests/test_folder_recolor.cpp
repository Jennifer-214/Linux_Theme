// Unit test for modules/folder_recolor.hpp. Locks: token parsing, single-pass
// case-insensitive hex swaps, which files a build picks up, and the marker.

#include "../modules/folder_recolor.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>

using namespace desk_install::folder_recolor;

namespace {

int failed = 0;

void check(const char* name, bool ok) {
    if (!ok) {
        std::printf("FAIL: %s\n", name);
        ++failed;
    }
}

const char* TOKEN = "base:F5C2E7=edb0c4,E1AED3=d99ab0";

}  // namespace

int main() {
    // ── token ──────────────────────────────────────────────────────────
    const auto rc = parse(TOKEN);
    check("valid token", rc.has_value() && rc->base == "base" && rc->swaps.size() == 2);
    check("swaps are lowercased", rc && rc->swaps[0].first == "f5c2e7");
    check("none is not a recolor", !parse("none"));
    check("no swaps", !parse("base:"));
    check("no base", !parse(":F5C2E7=edb0c4"));
    check("half a swap", !parse("base:F5C2E7"));
    check("bad hex", !parse("base:F5C2E7=zzzzzz"));
    check("trailing comma", !parse("base:F5C2E7=edb0c4,"));
    check("path in base refused", !parse("../evil:F5C2E7=edb0c4"));
    if (!rc) return 1;

    // ── repaint ────────────────────────────────────────────────────────
    check("upper and lower case swapped",
          repaint("fill:#F5C2E7;fill:#f5c2e7", *rc) == "fill:#edb0c4;fill:#edb0c4");
    check("other colours kept", repaint("#123456", *rc) == "#123456");
    check("short tail kept", repaint("end #F5C2", *rc) == "end #F5C2");
    {
        const auto chain = parse("base:111111=222222,222222=333333");
        check("swaps don't chain", chain && repaint("#111111", *chain) == "#222222");
    }

    // ── build ──────────────────────────────────────────────────────────
    {
        const fs::path root = fs::temp_directory_path() / ("fox_folders_" + std::to_string(::getpid()));
        const fs::path papirus = root / "Papirus", stage = root / "stage";
        const fs::path places = papirus / "48x48/places";
        fs::create_directories(places);
        std::ofstream(places / "folder-base.svg") << "<rect fill=\"#F5C2E7\"/>";
        std::ofstream(places / "folder-base-documents.svg") << "#E1AED3";
        std::ofstream(places / "user-base-home.svg") << "#F5C2E7";
        std::ofstream(places / "folder-based-on-nothing.svg") << "#F5C2E7";
        std::ofstream(places / "folder-other.svg") << "#F5C2E7";
        fs::create_symlink("folder-base.svg", places / "folder-base-link.svg");

        check("builds", build(papirus, stage, "blush", *rc));
        const fs::path out = stage / "48x48/places";
        check("folder repainted", desk_install::cursor_recolor::read_file(out / "folder-blush.svg") == "<rect fill=\"#edb0c4\"/>");
        check("kind suffix kept", desk_install::cursor_recolor::read_file(out / "folder-blush-documents.svg") == "#d99ab0");
        check("user icons included", desk_install::cursor_recolor::read_file(out / "user-blush-home.svg") == "#edb0c4");
        check("similar colour names skipped", !fs::exists(out / "folder-blushd-on-nothing.svg"));
        check("other colours skipped", !fs::exists(out / "folder-other.svg"));
        check("symlinks skipped", !fs::exists(out / "folder-blush-link.svg"));
        check("source left alone", desk_install::cursor_recolor::read_file(places / "folder-base.svg").find("F5C2E7") != std::string::npos);
        check("missing base fails", !build(root / "nowhere", root / "stage2", "blush", *rc));
        fs::remove_all(root);
    }

    // ── marker ─────────────────────────────────────────────────────────
    check("stock colour marker unchanged", mark("grey", "none") == "grey");
    check("swaps are part of the marker", mark("blush", TOKEN) != mark("blush", "base:F5C2E7=ffffff"));

    if (failed == 0) std::printf("test_folder_recolor: OK\n");
    return failed ? 1 : 0;
}
