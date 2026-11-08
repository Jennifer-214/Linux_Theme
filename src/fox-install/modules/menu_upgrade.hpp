// modules/menu_upgrade.hpp — new drawer pages reach a menu the user owns.
//
// ~/.config/quickshell/foxml/menus.json is the user's: an install never replaces it. A page the theme ships later
// is added once, into the same group, after the item it follows in the shipped menu; the ids offered are kept in
// $XDG_STATE_HOME/foxml/menu-offered.json, so a page the user removed stays removed. On a machine with no record
// yet, only the pages introduced with this upgrade path are offered: anything else missing was removed by hand.
#pragma once

#include "../../fox-common/json.hpp"

#include <set>
#include <string>
#include <vector>

namespace fox_install::menu_upgrade {

// Pages shipped since offers were recorded; a machine without a record is offered only these.
inline const std::set<std::string> FIRST_OFFER = {"screenshots", "models", "storage", "backups", "startup", "worktrees", "jobs", "test-results", "reviews", "next-steps", "failures"};

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

}  // namespace fox_install::menu_upgrade
