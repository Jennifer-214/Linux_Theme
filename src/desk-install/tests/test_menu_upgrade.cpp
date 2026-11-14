// New drawer pages reach a menu the user owns, once, and a page they removed stays removed.
#include "../modules/menu_upgrade.hpp"

#include <cstdio>

using nlohmann::json;
using namespace desk_install::menu_upgrade;

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

    // The Workbench layout reaches an upgraded menu once; her own moves and additions stay where she put them.
    const auto layout = json::parse(R"({"favorites":["desk/apps"],"groups":[
      {"id":"desk","items":[{"id":"apps","page":"apps","keys":"alt a"},{"id":"calendar","kind":"action"}]},
      {"id":"workbench","label":"Workbench","icon":"terminal","description":"Your projects","items":[
        {"id":"projects","page":"projects"},{"id":"jobs","page":"jobs"},{"id":"garden","page":"garden"}]},
      {"id":"comfort","items":[{"id":"dnd"},{"id":"wallpapers","page":"wallpapers"},{"id":"themes","page":"themes"}]},
      {"id":"system","items":[{"id":"updates","page":"updates","keywords":["upgrade"]}]}]})");
    auto old = json::parse(R"({"favorites":["desk/apps","desk/jobs","desk/themes"],"groups":[
      {"id":"desk","items":[{"id":"apps","page":"apps"},{"id":"jobs","page":"jobs","label":"My jobs"},{"id":"mine","label":"Mine"},
        {"id":"themes","page":"themes"},{"id":"projects","page":"projects"}]},
      {"id":"comfort","items":[{"id":"dnd"},{"id":"garden","page":"garden"}]},
      {"id":"system","items":[{"id":"updates","page":"updates"}]}]})");
    std::set<std::string> record{"apps", "jobs"};
    bool changed = false;
    const auto moved = relayout(old, layout, record, changed);
    check(changed && moved == std::vector<std::string>{"projects", "jobs", "themes"}, "work and appearance items move once");
    check(old["groups"][1]["id"] == "workbench" && old["groups"][1]["label"] == "Workbench", "Workbench appears right after Desk");
    std::vector<std::string> bench, desk2, comfort;
    for (const auto& item : old["groups"][1]["items"]) bench.push_back(item["id"]);
    for (const auto& item : old["groups"][0]["items"]) desk2.push_back(item["id"]);
    for (const auto& item : old["groups"][2]["items"]) comfort.push_back(item["id"]);
    check(bench == std::vector<std::string>{"projects", "jobs"}, "moved items keep the shipped order");
    check(old["groups"][1]["items"][1]["label"] == "My jobs", "her own label travels with the item");
    check(desk2 == std::vector<std::string>{"apps", "mine"}, "her own item stays on Desk");
    check(comfort == std::vector<std::string>{"dnd", "themes", "garden"}, "themes lands after its shipped neighbour; garden she put in Comfort stays there");
    check(old["favorites"] == json::parse(R"(["desk/apps","workbench/jobs","comfort/themes"])"), "favorites follow their items");
    check(old["groups"][0]["items"][0]["keys"] == "alt a" && old["groups"][3]["items"][0]["keywords"][0] == "upgrade",
          "rows gain the shipped shortcut labels and search words");
    bool again = true;
    check(relayout(old, layout, record, again).empty() && !again, "the layout is applied once");
    auto current = layout; std::set<std::string> fresh; bool touched = true;
    check(relayout(current, layout, fresh, touched).empty() && !touched && current == layout, "a menu already in the layout is left alone");

    // Desk in the old shipped order takes the new one; a Desk she arranged keeps hers.
    const auto deskShipped = json::parse(R"({"groups":[{"id":"desk","items":[{"id":"apps"},{"id":"windows"},{"id":"downloads"},{"id":"bookmarks"}]}]})");
    auto untouched = json::parse(R"({"groups":[{"id":"desk","items":[{"id":"apps"},{"id":"bookmarks"},{"id":"downloads"},{"id":"windows"}]}]})");
    std::set<std::string> r1; bool c1 = false;
    relayout(untouched, deskShipped, r1, c1);
    check(c1 && untouched == deskShipped, "an untouched Desk reads in the new order");
    auto arranged = json::parse(R"({"groups":[{"id":"desk","items":[{"id":"windows"},{"id":"apps"},{"id":"bookmarks"}]}]})");
    const auto before = arranged; std::set<std::string> r2; bool c2 = true;
    relayout(arranged, deskShipped, r2, c2);
    check(!c2 && arranged == before, "a Desk she arranged keeps her order");

    // Sections: each row gains its heading, Pick a color and Displays move once, and the two API rows become one page.
    const auto sections = json::parse(R"({"groups":[
      {"id":"desk","items":[{"id":"apps","section":"open"},{"id":"color-picker","section":"collected"}]},
      {"id":"workbench","items":[{"id":"models","section":"AI"},{"id":"api-credits","label":"API","detail":"Usage and asking","section":"AI"}]},
      {"id":"comfort","items":[{"id":"brightness","section":"screen"},{"id":"displays","section":"screen"},{"id":"themes","section":"look"}]},
      {"id":"system","items":[{"id":"updates","section":"upkeep"}]}]})");
    auto before_sections = json::parse(R"({"favorites":["workbench/api-tasks","comfort/color-picker"],"groups":[
      {"id":"desk","items":[{"id":"apps"},{"id":"mine","label":"Mine"}]},
      {"id":"workbench","items":[{"id":"models"},{"id":"api-tasks","label":"Review with API credits"},{"id":"api-credits","label":"API usage"}]},
      {"id":"comfort","items":[{"id":"brightness"},{"id":"themes"},{"id":"color-picker"}]},
      {"id":"system","items":[{"id":"updates"},{"id":"displays"}]}]})");
    std::set<std::string> sectionRecord{"@layout:workbench"}; bool sectionChanged = false;
    const auto sectionMoves = resection(before_sections, sections, sectionRecord, sectionChanged);
    check(sectionChanged && sectionMoves == std::vector<std::string>{"color-picker", "displays"}, "Pick a color and Displays move");
    check(before_sections["groups"][0]["items"][1]["id"] == "color-picker", "Pick a color joins Desk, after Apps as shipped");
    check(before_sections["groups"][2]["items"][1]["id"] == "displays", "Displays lands after brightness, its shipped neighbour");
    check(before_sections["groups"][1]["items"].size() == 2 && before_sections["groups"][1]["items"][1]["label"] == "API",
          "the old ask row goes, and the usage row takes the API page's name");
    check(before_sections["favorites"] == json::parse(R"(["workbench/api-credits","desk/color-picker"])"), "favorites follow");
    check(before_sections["groups"][0]["items"][0]["section"] == "open" && !before_sections["groups"][0]["items"][2].contains("section"),
          "shipped rows gain their heading; her own row has none");
    bool sectionAgain = true;
    check(resection(before_sections, sections, sectionRecord, sectionAgain).empty() && !sectionAgain, "sections are applied once");
    auto renamed = json::parse(R"({"groups":[{"id":"workbench","items":[{"id":"api-tasks","label":"Ask Claude"},{"id":"api-credits","label":"Spend"}]},
      {"id":"system","items":[{"id":"color-picker"}]},{"id":"desk","items":[]},{"id":"comfort","items":[]}]})");
    std::set<std::string> r3; bool c3 = false;
    resection(renamed, sections, r3, c3);
    check(renamed["groups"][0]["items"].size() == 2 && renamed["groups"][0]["items"][0]["label"] == "Ask Claude"
          && renamed["groups"][0]["items"][1]["label"] == "Spend" && renamed["groups"][1]["items"][0]["id"] == "color-picker",
          "rows she renamed or moved herself stay as they are");

    {
        auto menu = nlohmann::json::parse(R"({"favorites":["comfort/wallpaper-sync","desk/apps"],"groups":[{"id":"comfort","label":"Comfort","items":[
            {"id":"wallpaper-sync","label":"Colors from wallpaper","kind":"action"},{"id":"themes","label":"Themes","kind":"page","page":"themes"}]}]})");
        check(retire(menu), "a retired row leaves the menu");
        check(menu["groups"][0]["items"].size() == 1 && menu["favorites"].size() == 1 && menu["favorites"][0] == "desk/apps",
              "its row and its favorite go; the rest stay");
        check(!retire(menu), "a second pass changes nothing");
    }

    std::printf("test_menu_upgrade: %d passed\n", passed);
    return failures ? 1 : 0;
}
