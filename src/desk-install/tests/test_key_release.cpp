// tests/test_key_release.cpp — which machines get the ThinkPad SysRq rule, and reading the kernel's force_release list.

#include "../modules/key_release.hpp"

#include <iostream>
#include <string>

namespace kr = desk_install::key_release;

int main() {
    int failures = 0;
    auto expect = [&](bool ok, const std::string& why) {
        if (!ok) { std::cerr << "FAIL: " << why << '\n'; ++failures; }
    };

    expect(kr::is_thinkpad("LENOVO\n", "ThinkPad P15 Gen 2i\n"), "a ThinkPad gets the rule");
    expect(!kr::is_thinkpad("LENOVO\n", "IdeaPad 5 14ALC05\n"), "an IdeaPad does not");
    expect(!kr::is_thinkpad("Dell Inc.\n", "ThinkPad\n"), "only Lenovo's ThinkPads");
    expect(!kr::is_thinkpad("", ""), "no DMI (a VM or container): no rule");

    expect(!kr::releases("369-370", 0x54), "the stock list leaves SysRq alone");
    expect(kr::releases("84,369-370", 0x54), "84 listed alone");
    expect(kr::releases("369-370,84\n", 0x54), "84 last, with sysfs's newline");
    expect(kr::releases("80-90", 0x54), "84 inside a range");
    expect(!kr::releases("8,184,840", 0x54), "no partial matches on 8, 184, 840");
    expect(!kr::releases("", 0x54), "an empty list");

    if (failures) std::cerr << failures << " failure(s)\n";
    else std::cout << "test_key_release: ok\n";
    return failures ? 1 : 0;
}
