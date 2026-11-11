// Unit test for the hyprlock background blocks (modules/personalize.cpp).
// Locks: one block per monitor in the layout, each on the active wallpaper's cut
// for that monitor's size; the theme default's cut, then the theme default, when
// that cut is missing; the template block's settings copied into every block;
// variant names walked back to their source.

#include "../modules/personalize.hpp"

#include <cstdio>
#include <set>
#include <string>
#include <vector>

namespace {

std::size_t count(const std::string& hay, const std::string& needle) {
    std::size_t n = 0, pos = 0;
    while ((pos = hay.find(needle, pos)) != std::string::npos) { ++n; pos += needle.size(); }
    return n;
}

// The block for one monitor (from its `monitor =` line to the closing brace).
std::string block_for(const std::string& blocks, const std::string& monitor) {
    auto at = blocks.find("    monitor = " + monitor + "\n");
    if (at == std::string::npos) return {};
    return blocks.substr(at, blocks.find("}", at) - at);
}

const char* TEMPLATE =
    "general {\n"
    "    hide_cursor = true\n"
    "}\n"
    "# foxml:hyprlock-backgrounds-begin\n"
    "background {\n"
    "    monitor =\n"
    "    path = ~/.wallpapers/foxml_paper_botanical_color.png\n"
    "    blur_size = 2\n"
    "    blur_passes = 1\n"
    "    vibrancy = 0.0\n"
    "    brightness = 1.0\n"
    "    contrast = 1.0\n"
    "}\n"
    "# foxml:hyprlock-backgrounds-end\n"
    "background {\n"
    "    monitor =\n"
    "    blur_size = 99\n"
    "}\n";

}  // namespace

int main() {
    using namespace desk_install::personalize;
    int failed = 0;
    auto check = [&](const char* what, bool ok) {
        if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); ++failed; }
    };

    const std::set<std::string> disk = {
        "foxml_paper_botanical_color.png",
        "foxml_paper_botanical_color_1920x1080.png",
        "foxml_paper_botanical_color_1080x1920.png",
        "foxml_paper_botanical_color_2160x3840.png",
        "foxml_paper_nap.jpg",
        "foxml_paper_nap_1920x1080.jpg",
    };
    auto on_disk = [&](const std::string& n) { return disk.count(n) > 0; };
    const std::string def = "foxml_paper_botanical_color.png";

    // Variant names walk back to the source.
    check("source of a variant", lock_source_name("foxml_paper_botanical_color_1080x1920.png") == def);
    check("source unchanged",    lock_source_name(def) == def);
    check("no extension",        lock_source_name("wall_800x600") == "wall");

    // Settings come from the template's first block inside the sentinels only.
    const std::string tail = background_tail(TEMPLATE);
    check("tail keeps blur",       tail.find("    blur_size = 2\n") != std::string::npos);
    check("tail keeps contrast",   tail.find("    contrast = 1.0") != std::string::npos);
    check("tail drops monitor",    tail.find("monitor") == std::string::npos);
    check("tail drops path",       tail.find("path") == std::string::npos);
    check("tail ignores outside",  tail.find("99") == std::string::npos);
    check("no sentinels, no tail", background_tail("background {\n    blur_size = 3\n}\n").empty());

    // The laptop + both portrait screens: one block each, each on its own cut.
    const std::vector<std::string> layout = {"DP-2:2160x3840", "HDMI-A-1:1080x1920", "eDP-1:1920x1080"};
    std::size_t fallbacks = 99;
    const std::string blocks = background_blocks(layout, def, def, tail, on_disk, fallbacks);
    check("one block per monitor", count(blocks, "background {\n") == 3);
    check("balanced braces",       count(blocks, "{") == count(blocks, "}"));
    check("DP-2 on its 4K portrait cut",
          block_for(blocks, "DP-2").find("path = ~/.wallpapers/foxml_paper_botanical_color_2160x3840.png") != std::string::npos);
    check("HDMI-A-1 on its portrait cut",
          block_for(blocks, "HDMI-A-1").find("path = ~/.wallpapers/foxml_paper_botanical_color_1080x1920.png") != std::string::npos);
    check("eDP-1 on its landscape cut",
          block_for(blocks, "eDP-1").find("path = ~/.wallpapers/foxml_paper_botanical_color_1920x1080.png") != std::string::npos);
    check("every block carries the settings", count(blocks, "    blur_size = 2\n") == 3);
    check("no fallbacks", fallbacks == 0);
    check("no trailing newline (splice adds its own)", !blocks.empty() && blocks.back() == '}');

    // An active wallpaper cut only for the laptop: the portrait screens take the
    // theme default's cuts, and count as fallbacks.
    const std::string mixed = background_blocks(layout, "foxml_paper_nap.jpg", def, tail, on_disk, fallbacks);
    check("active cut where it exists",
          block_for(mixed, "eDP-1").find("foxml_paper_nap_1920x1080.jpg") != std::string::npos);
    check("theme default cut elsewhere",
          block_for(mixed, "HDMI-A-1").find("foxml_paper_botanical_color_1080x1920.png") != std::string::npos);
    check("two fallbacks", fallbacks == 2);

    // A size nothing is cut for: the theme default itself.
    bool fb = false;
    check("uncut size → theme default",
          lock_wallpaper_for(def, def, "2560x1440", on_disk, fb) == def && fb);
    // Nothing on disk at all: still names the theme default, never an empty path.
    auto nothing = [](const std::string&) { return false; };
    check("empty disk → theme default", lock_wallpaper_for("x.png", def, "1920x1080", nothing, fb) == def);
    check("no theme default → active",  lock_wallpaper_for("x.png", "", "1920x1080", nothing, fb) == "x.png");

    // Malformed layout entries are skipped, not written as blank monitors.
    const std::string odd = background_blocks({"garbage", "eDP-1:1920x1080"}, def, def, tail, on_disk, fallbacks);
    check("malformed entry skipped", count(odd, "background {\n") == 1);

    if (failed == 0) std::printf("test_hyprlock_backgrounds: OK\n");
    return failed ? 1 : 0;
}
