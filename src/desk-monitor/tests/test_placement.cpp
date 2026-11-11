// Pins placement.hpp: screen positions follow scale and rotation, only even scales are offered,
// and rule edits keep each line's mode and extra options.
#include "../placement.hpp"

#include <algorithm>
#include <iostream>

namespace p = desk_monitor::placement;
static int failures = 0;
static void check(const char* what, bool ok) {
    if (!ok) { ++failures; std::cerr << "FAIL: " << what << "\n"; }
}

int main() {
    const p::Screen laptop{"eDP-1", 1920, 1080, 100, 0, "", ""};
    p::Screen tall{"DP-2", 3840, 2160, 125, 3, "left", ""};
    p::Screen side{"HDMI-A-1", 1920, 1080, 75, 3, "right", ""};

    auto boxes = p::place(laptop, {tall, side});
    check("primary at 0x0", p::position_text(boxes["eDP-1"]) == "0x0");
    check("4K portrait at 1.25 sits flush left, centred", p::position_text(boxes["DP-2"]) == "-1728x-996");
    check("1080p portrait at 0.75 sits flush right, centred", p::position_text(boxes["HDMI-A-1"]) == "1920x-740");
    check("logical size follows rotation and scale", boxes["DP-2"].w == 1728 && boxes["DP-2"].h == 3072);

    tall.scale_x100 = 150; side.scale_x100 = 100;
    boxes = p::place(laptop, {tall, side});
    check("the old 1.5 / 1 layout is what the wizard wrote", p::position_text(boxes["DP-2"]) == "-1440x-740"
          && p::position_text(boxes["HDMI-A-1"]) == "1920x-420");

    const p::Screen above{"DP-3", 1920, 1080, 100, 0, "above", "HDMI-A-1"};
    boxes = p::place(laptop, {tall, side, above});
    check("a screen can anchor to an earlier screen", boxes["DP-3"].y == boxes["HDMI-A-1"].y - 1080);

    check("side_of reads live layouts", p::side_of(boxes["eDP-1"], boxes["DP-2"]) == "left"
          && p::side_of(boxes["eDP-1"], boxes["HDMI-A-1"]) == "right");

    const auto scales = p::scales_for(1920, 1080);
    auto has = [&](int s) { return std::find(scales.begin(), scales.end(), s) != scales.end(); };
    check("even scales offered", has(75) && has(100) && has(125) && has(150) && has(200));
    check("uneven scales left out", !has(175));
    check("scale text", p::scale_text(125) == "1.25" && p::scale_text(75) == "0.75" && p::scale_text(150) == "1.5"
          && p::scale_text(100) == "1" && p::scale_text(205) == "2.05");
    check("float scales round", p::to_x100(1.25) == 125 && p::to_x100(0.7500001) == 75);

    const std::string conf =
        "# header\n"
        "monitor = eDP-1, preferred, 0x0, 1\n"
        "monitor = DP-2, preferred, -1440x-740, 1.5, transform, 3\n"
        "monitor = HDMI-A-1,1920x1080@60,1920x-420,1,transform,3,supports_hdr,-1\n"
        "\n"
        "# Catch-all for any unknown/disconnected displays at runtime\n"
        "monitor = , preferred, auto, 1\n";
    auto out = p::set_conf_rule(conf, "HDMI-A-1", "1920x-740", "0.75", 3);
    check("conf keeps mode and extra options",
          out.find("monitor = HDMI-A-1, 1920x1080@60, 1920x-740, 0.75, transform, 3, supports_hdr, -1\n") != std::string::npos);
    out = p::set_conf_rule(out, "DP-2", "-1728x-996", "1.25", 0);
    check("conf drops the rotation for landscape", out.find("monitor = DP-2, preferred, -1728x-996, 1.25\n") != std::string::npos);
    out = p::set_conf_rule(out, "DP-9", "0x1080", "1", 0);
    check("conf adds a missing screen above the catch-all comment",
          out.find("monitor = DP-9, preferred, 0x1080, 1\n# Catch-all") != std::string::npos);
    check("conf leaves other lines alone", out.find("# header\nmonitor = eDP-1, preferred, 0x0, 1\n") == 0);

    const std::string lua =
        "-- header\n"
        "hl.monitor({ output = \"eDP-1\", mode = \"preferred\", position = \"0x0\", scale = 1.00 })\n"
        "hl.monitor({ output = \"DP-2\", mode = \"preferred\", position = \"-1440x-740\", scale = 1.25, transform = 3 })\n"
        "hl.monitor({ output = \"HDMI-A-1\", mode = \"1920x1080@60\", position = \"1920x-420\", scale = 0.75, transform = 3, supports_hdr = -1 })\n"
        "\n"
        "-- Catch-all for any unknown/disconnected displays at runtime\n"
        "hl.monitor({ output = \"\", mode = \"preferred\", position = \"auto\", scale = 1 })\n";
    auto l = p::set_lua_rule(lua, "HDMI-A-1", "1920x-740", "0.75", 3);
    check("lua keeps mode and extra options", l.find("hl.monitor({ output = \"HDMI-A-1\", mode = \"1920x1080@60\", "
          "position = \"1920x-740\", scale = 0.75, transform = 3, supports_hdr = -1 })") != std::string::npos);
    l = p::set_lua_rule(l, "DP-2", "-1728x-996", "1.25", 1);
    check("lua changes the rotation", l.find("position = \"-1728x-996\", scale = 1.25, transform = 1 })") != std::string::npos);
    l = p::set_lua_rule(l, "eDP-1", "0x0", "1.25", 0);
    check("lua landscape has no transform", l.find("\"eDP-1\", mode = \"preferred\", position = \"0x0\", scale = 1.25 })") != std::string::npos);
    l = p::set_lua_rule(l, "DP-9", "0x1080", "1", 0);
    check("lua adds a missing screen above the catch-all comment",
          l.find("position = \"0x1080\", scale = 1 })\n-- Catch-all") != std::string::npos);
    check("lua leaves the catch-all alone", l.find("output = \"\", mode = \"preferred\", position = \"auto\", scale = 1 })") != std::string::npos);

    // A new mode replaces the old one and nothing else; a screen with no rule gets the mode it was given.
    auto m = p::set_conf_rule(conf, "HDMI-A-1", "1920x-740", "0.75", 3, "1600x900@60.00");
    check("conf sets the mode", m.find("monitor = HDMI-A-1, 1600x900@60.00, 1920x-740, 0.75, transform, 3, supports_hdr, -1\n") != std::string::npos);
    m = p::set_conf_rule(m, "DP-9", "0x1080", "1", 0, "2560x1440@59.95");
    check("conf adds a missing screen with its mode", m.find("monitor = DP-9, 2560x1440@59.95, 0x1080, 1\n") != std::string::npos);
    auto ml = p::set_lua_rule(lua, "DP-2", "-1728x-996", "1.25", 3, "2560x1440@59.95");
    check("lua sets the mode", ml.find("output = \"DP-2\", mode = \"2560x1440@59.95\", position = \"-1728x-996\", scale = 1.25, transform = 3 })") != std::string::npos);
    check("lua leaves other screens' modes alone", ml.find("output = \"HDMI-A-1\", mode = \"1920x1080@60\"") != std::string::npos);
    ml = p::set_lua_rule(ml, "DP-9", "0x1080", "1", 0, "1920x1080@60.00");
    check("lua adds a missing screen with its mode", ml.find("output = \"DP-9\", mode = \"1920x1080@60.00\"") != std::string::npos);

    if (failures == 0) std::cout << "test_placement: all checks passed\n";
    return failures == 0 ? 0 : 1;
}
