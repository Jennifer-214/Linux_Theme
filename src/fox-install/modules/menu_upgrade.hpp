// modules/menu_upgrade.hpp — new drawer pages reach a menu the user owns.
//
// ~/.config/quickshell/foxml/menus.json is the user's: an install never replaces it. A page the theme ships later
// is added once, into the same group, after the item it follows in the shipped menu; the ids offered are kept in
// $XDG_STATE_HOME/foxml/menu-offered.json, so a page the user removed stays removed. On a machine with no record
// yet, only the pages introduced with this upgrade path are offered: anything else missing was removed by hand.
#pragma once

#include "../../fox-common/json.hpp"

#include <algorithm>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace fox_install::menu_upgrade {

// Pages shipped since offers were recorded; a machine without a record is offered only these.
inline const std::set<std::string> FIRST_OFFER = {"screenshots", "models", "storage", "backups", "startup", "worktrees", "jobs", "test-results", "reviews", "next-steps", "failures",
                                                  "displays", "api-tasks", "api-credits", "calendar", "earlier-notes"};

inline std::string field(const nlohmann::json& object, const char* key) {
    if (!object.is_object() || !object.contains(key) || !object[key].is_string()) return {};
    return object[key].get<std::string>();
}

inline std::set<std::string> ids_in(const nlohmann::json& menu) {
    std::set<std::string> ids;
    if (!menu.is_object() || !menu.contains("groups") || !menu["groups"].is_array()) return ids;
    for (const auto& group : menu["groups"])
        if (group.contains("items") && group["items"].is_array())
            for (const auto& item : group["items"]) {
                if (!field(item, "id").empty()) ids.insert(field(item, "id"));
                if (!field(item, "page").empty()) ids.insert(field(item, "page"));
            }
    return ids;
}

// Adds what the user's menu lacks and was never offered. `offered` is the record (empty set + `first_time`
// for a machine without one); it gains every shipped id. Returns the ids added.
inline std::vector<std::string> offer(nlohmann::json& menu, const nlohmann::json& shipped, std::set<std::string>& offered,
                                      bool first_time) {
    std::vector<std::string> added;
    if (!menu.is_object() || !menu.contains("groups") || !menu["groups"].is_array()
        || !shipped.is_object() || !shipped.contains("groups") || !shipped["groups"].is_array()) return added;
    const auto present = ids_in(menu);
    for (const auto& source : shipped["groups"]) {
        if (!source.contains("items") || !source["items"].is_array()) continue;
        std::string previous;
        for (const auto& item : source["items"]) {
            const auto id = field(item, "id");
            const bool known = present.count(id) || (!field(item, "page").empty() && present.count(field(item, "page")));
            const bool offer_it = !id.empty() && !known && !offered.count(id) && (!first_time || FIRST_OFFER.count(id));
            if (!id.empty()) offered.insert(id);
            if (offer_it) {
                for (auto& group : menu["groups"]) {
                    if (field(group, "id") != field(source, "id") || !group.contains("items") || !group["items"].is_array()) continue;
                    auto& items = group["items"];
                    std::size_t at = items.size();
                    for (std::size_t i = 0; i < items.size(); ++i) if (!previous.empty() && field(items[i], "id") == previous) at = i + 1;
                    items.insert(items.begin() + static_cast<long>(at), item);
                    added.push_back(id);
                    break;
                }
            }
            if (!id.empty()) previous = id;
        }
    }
    return added;
}

// The Workbench layout (2026-11): Desk kept apps and papers; work moved to a new Workbench group, appearance to
// Comfort. Applied once (a marker in the offer record), and only to items still where the old menu shipped them:
// anything she moved herself stays put. Favorites follow the items they name, and rows gain the shipped shortcut
// labels and search words they lack.
inline const char* LAYOUT_MARKER = "@layout:workbench";
struct Move { const char* id; const char* from; const char* to; };
inline const std::vector<Move> WORKBENCH_MOVES = {
    {"projects", "desk", "workbench"}, {"worktrees", "desk", "workbench"}, {"agents", "desk", "workbench"},
    {"jobs", "desk", "workbench"}, {"test-results", "desk", "workbench"}, {"reviews", "desk", "workbench"},
    {"next-steps", "desk", "workbench"}, {"failures", "desk", "workbench"}, {"models", "desk", "workbench"},
    {"api-tasks", "desk", "workbench"}, {"api-credits", "system", "workbench"}, {"garden", "desk", "workbench"},
    {"wallpapers", "desk", "comfort"}, {"themes", "desk", "comfort"}, {"wallpaper-next", "desk", "comfort"},
    {"wallpaper-sync", "desk", "comfort"}, {"color-picker", "desk", "comfort"}};

inline nlohmann::json* group_of(nlohmann::json& menu, const std::string& id) {
    for (auto& group : menu["groups"])
        if (field(group, "id") == id && group.contains("items") && group["items"].is_array()) return &group;
    return nullptr;
}

// Returns the ids moved; `changed` reports any edit (a new group, favorites, labels) even when nothing moved.
inline std::vector<std::string> relayout(nlohmann::json& menu, const nlohmann::json& shipped, std::set<std::string>& offered,
                                         bool& changed) {
    std::vector<std::string> moved;
    changed = false;
    if (offered.count(LAYOUT_MARKER) || !menu.is_object() || !menu.contains("groups") || !menu["groups"].is_array()
        || !shipped.is_object() || !shipped.contains("groups") || !shipped["groups"].is_array()) return moved;
    offered.insert(LAYOUT_MARKER);
    auto& groups = menu["groups"];
    if (!group_of(menu, "workbench")) {
        for (const auto& source : shipped["groups"]) {
            if (field(source, "id") != "workbench") continue;
            auto header = source; header["items"] = nlohmann::json::array();
            std::size_t at = groups.size();
            for (std::size_t i = 0; i < groups.size(); ++i) if (field(groups[i], "id") == "desk") at = i + 1;
            groups.insert(groups.begin() + static_cast<long>(at), header);
            changed = true;
        }
    }
    // The shipped order of each destination group, to place a moved item after its nearest shipped neighbour.
    auto shipped_order = [&](const std::string& group) {
        std::vector<std::string> order;
        for (const auto& source : shipped["groups"])
            if (field(source, "id") == group && source.contains("items") && source["items"].is_array())
                for (const auto& item : source["items"]) order.push_back(field(item, "id"));
        return order;
    };
    for (const auto& move : WORKBENCH_MOVES) {
        auto* from = group_of(menu, move.from); auto* to = group_of(menu, move.to);
        if (!from || !to) continue;
        auto& items = (*from)["items"];
        auto found = std::find_if(items.begin(), items.end(), [&](const nlohmann::json& item) { return field(item, "id") == move.id; });
        if (found == items.end()) continue;
        auto item = *found; items.erase(found);
        auto& target = (*to)["items"];
        const auto order = shipped_order(move.to);
        std::size_t at = target.size();
        const auto self = std::find(order.begin(), order.end(), std::string(move.id));
        for (auto before = self; self != order.end() && before != order.begin();) {
            --before;
            const auto there = std::find_if(target.begin(), target.end(), [&](const nlohmann::json& i) { return field(i, "id") == *before; });
            if (there != target.end()) { at = static_cast<std::size_t>(there - target.begin()) + 1; break; }
        }
        if (self != order.end() && at == target.size()) {
            // No earlier neighbour here: go before the first later one, so the shipped order still reads top to bottom.
            for (auto after = self + 1; after != order.end(); ++after) {
                const auto there = std::find_if(target.begin(), target.end(), [&](const nlohmann::json& i) { return field(i, "id") == *after; });
                if (there != target.end()) { at = static_cast<std::size_t>(there - target.begin()); break; }
            }
        }
        target.insert(target.begin() + static_cast<long>(at), item);
        moved.push_back(move.id);
        if (menu.contains("favorites") && menu["favorites"].is_array())
            for (auto& favorite : menu["favorites"])
                if (favorite.is_string() && favorite.get<std::string>() == std::string(move.from) + "/" + move.id)
                    favorite = std::string(move.to) + "/" + move.id;
        changed = true;
    }
    // Desk itself was reordered. Only a Desk that still reads in the old shipped order, with nothing of her own in
    // it, takes the new order; any Desk she arranged keeps hers.
    static const std::vector<std::string> OLD_DESK = {"apps", "bookmarks", "library", "downloads", "screenshots", "windows",
                                                      "clipboard-text", "clipboard-images"};
    if (auto* desk = group_of(menu, "desk")) {
        auto& items = (*desk)["items"];
        std::vector<std::string> now;
        for (const auto& item : items) now.push_back(field(item, "id"));
        std::vector<std::string> expected;
        for (const auto& id : OLD_DESK) if (std::find(now.begin(), now.end(), id) != now.end()) expected.push_back(id);
        if (!now.empty() && now == expected) {
            const auto order = shipped_order("desk");
            auto rank = [&](const nlohmann::json& item) {
                const auto at = std::find(order.begin(), order.end(), field(item, "id"));
                return static_cast<std::size_t>(at - order.begin());
            };
            auto sorted = items;
            std::stable_sort(sorted.begin(), sorted.end(), [&](const nlohmann::json& x, const nlohmann::json& y) { return rank(x) < rank(y); });
            if (sorted != items) { items = sorted; changed = true; }
        }
    }
    std::map<std::string, nlohmann::json> shipped_items;
    for (const auto& source : shipped["groups"])
        if (source.contains("items") && source["items"].is_array())
            for (const auto& item : source["items"]) if (!field(item, "id").empty()) shipped_items[field(item, "id")] = item;
    for (auto& group : groups) {
        if (!group.contains("items") || !group["items"].is_array()) continue;
        for (auto& item : group["items"]) {
            const auto at = shipped_items.find(field(item, "id"));
            if (at == shipped_items.end()) continue;
            for (const char* key : {"keys", "keywords"})
                if (!item.contains(key) && at->second.contains(key)) { item[key] = at->second[key]; changed = true; }
        }
    }
    return moved;
}

}  // namespace fox_install::menu_upgrade
