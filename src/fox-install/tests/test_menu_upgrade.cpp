// New drawer pages reach a menu the user owns, once, and a page they removed stays removed.
#include "../modules/menu_upgrade.hpp"

#include <cstdio>

using nlohmann::json;
using namespace fox_install::menu_upgrade;

static int failures = 0, passed = 0;
static void check(bool ok, const char* what) {
    if (ok) ++passed; else { ++failures; std::printf("FAIL: %s\n", what); }
}

static json shipped() {
    return json::parse(R"({"groups":[
      {"id":"desk","items":[{"id":"apps","page":"apps"},{"id":"garden","page":"garden"},{"id":"models","page":"models"},{"id":"screenshots","page":"screenshots"}]},
      {"id":"system","items":[{"id":"updates","page":"updates"},{"id":"storage","page":"storage"},{"id":"backups","page":"backups"},{"id":"power","page":"power"}]}]})");
}

int main() {
    // A machine with no record: only the pages introduced with offers come in, each after its shipped neighbour.
    auto mine = json::parse(R"({"groups":[
      {"id":"desk","items":[{"id":"garden","page":"garden"},{"id":"apps","page":"apps"}]},
      {"id":"system","items":[{"id":"updates","page":"updates"},{"id":"power","page":"power"}]}]})");
    std::set<std::string> offered;
    auto added = offer(mine, shipped(), offered, true);
    check(added == std::vector<std::string>{"models", "screenshots", "storage", "backups"}, "the new pages are added");
    check(mine["groups"][0]["items"][1]["id"] == "models", "models lands after garden, where the shipped menu has it");
    std::vector<std::string> desk;
    for (const auto& item : mine["groups"][0]["items"]) desk.push_back(item["id"]);
    check(desk == std::vector<std::string>{"garden", "models", "screenshots", "apps"}, "the user's own order is kept around them");
    check(mine["groups"][1]["items"][1]["id"] == "storage" && mine["groups"][1]["items"][2]["id"] == "backups", "storage then backups after updates");
    check(offered.count("apps") && offered.count("power"), "everything shipped is now on record");

    // She removes storage; a later install doesn't bring it back.
    auto& system = mine["groups"][1]["items"];
    system.erase(system.begin() + 1);
    check(offer(mine, shipped(), offered, false).empty(), "a removed page stays removed");

    // A page shipped later is offered once.
    auto later = shipped();
    later["groups"][1]["items"].push_back(json::parse(R"({"id":"startup","page":"startup"})"));
    check(offer(mine, later, offered, false) == std::vector<std::string>{"startup"}, "a newer page is offered");
    check(offer(mine, later, offered, false).empty(), "…once");

    // An old item missing on a machine with no record was removed by hand: not resurrected.
    auto bare = json::parse(R"({"groups":[{"id":"desk","items":[{"id":"garden","page":"garden"}]},{"id":"system","items":[]}]})");
    std::set<std::string> none;
    const auto first = offer(bare, shipped(), none, true);
    check(std::find(first.begin(), first.end(), "apps") == first.end(), "apps (an old page) is not put back");
    check(offer(bare, json::parse("[]"), none, true).empty() && offer(bare, json::parse(R"({"groups":"x"})"), none, true).empty(),
          "a broken shipped menu changes nothing");

    std::printf("test_menu_upgrade: %d passed\n", passed);
    return failures ? 1 : 0;
}
