// tests/test_firefox_policies.cpp — the Firefox add-on policy merge keeps everything already in policies.json.
#include "../modules/firefox_policies.hpp"

#include <cstdio>
#include <string>

using nlohmann::json;
using namespace fox_install::firefox_policies;

static int failures = 0, passes = 0;
static void check(bool ok, const std::string& what) {
    if (ok) ++passes; else { ++failures; std::fprintf(stderr, "FAIL: %s\n", what.c_str()); }
}

int main() {
    const Addon& vimium = ADDONS[0];
    check(install_url(vimium) == "https://addons.mozilla.org/firefox/downloads/latest/vimium-ff/latest.xpi", "AMO latest link");

    json fresh;
    check(add_extension(fresh, vimium) == Merge::Added, "an absent file gets the add-on");
    check(fresh["policies"]["ExtensionSettings"][vimium.id]["installation_mode"] == "normal_installed", "installed, can be switched off");

    json hers = json::parse(R"({"policies":{"DisableTelemetry":true,"ExtensionSettings":{
        "*":{"installation_mode":"allowed"},"uBlock0@raymondhill.net":{"installation_mode":"force_installed","install_url":"x"}}}})");
    const json before = hers;
    check(add_extension(hers, vimium) == Merge::Added, "an existing file gains the add-on");
    check(hers["policies"]["DisableTelemetry"] == true && hers["policies"]["ExtensionSettings"]["*"] == before["policies"]["ExtensionSettings"]["*"]
          && hers["policies"]["ExtensionSettings"]["uBlock0@raymondhill.net"]["install_url"] == "x", "her own policies kept");
    json again = hers;
    check(add_extension(again, vimium) == Merge::Present && again == hers, "a second install changes nothing");

    json blocked = json::parse(R"({"policies":{"ExtensionSettings":{"{d7742d87-e61d-4b78-b8a1-b469842139fa}":{"installation_mode":"blocked"}}}})");
    const json blocked_before = blocked;
    check(add_extension(blocked, vimium) == Merge::Present && blocked == blocked_before, "an entry she wrote for it is hers to keep");

    for (const char* odd : {R"([1,2])", R"({"policies":[]})", R"({"policies":{"ExtensionSettings":"no"}})"}) {
        json file = json::parse(odd), copy = file;
        check(add_extension(file, vimium) == Merge::Refused && file == copy, std::string("refused, untouched: ") + odd);
    }
    std::printf("test_firefox_policies: %d passed\n", passes);
    return failures ? 1 : 0;
}
