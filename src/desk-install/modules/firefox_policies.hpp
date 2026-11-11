// modules/firefox_policies.hpp — add-ons the theme expects, installed through Firefox's own enterprise policy.
//
// /etc/firefox/policies/policies.json is the file Firefox reads at start. Its ExtensionSettings entry installs an
// add-on from addons.mozilla.org on the next launch; normal_installed lets her switch it off, not remove it. Anything
// she or another tool already wrote there is kept: only an add-on with no entry of its own is added.
#pragma once

#include "../../desk-common/json.hpp"

#include <string>

namespace desk_install::firefox_policies {

struct Addon { const char* id; const char* slug; const char* name; };

// Vimium: the keyboard hints userContent.css themes (templates/firefox/userContent.css, "Vimium").
inline constexpr Addon ADDONS[] = {
    {"{d7742d87-e61d-4b78-b8a1-b469842139fa}", "vimium-ff", "Vimium"},
};

inline std::string install_url(const Addon& addon) {
    return std::string("https://addons.mozilla.org/firefox/downloads/latest/") + addon.slug + "/latest.xpi";
}

enum class Merge { Added, Present, Refused };

// Adds `addon` to ExtensionSettings when it has no entry. Refused (nothing changed) when the file's shape is not
// the one Firefox reads: a top level, "policies" or "ExtensionSettings" that is not an object.
inline Merge add_extension(nlohmann::json& file, const Addon& addon) {
    if (file.is_null()) file = nlohmann::json::object();
    if (!file.is_object()) return Merge::Refused;
    if (file.contains("policies") && !file["policies"].is_object()) return Merge::Refused;
    auto& policies = file["policies"];
    if (policies.is_null()) policies = nlohmann::json::object();
    if (policies.contains("ExtensionSettings") && !policies["ExtensionSettings"].is_object()) return Merge::Refused;
    auto& settings = policies["ExtensionSettings"];
    if (settings.is_null()) settings = nlohmann::json::object();
    if (settings.contains(addon.id)) return Merge::Present;
    settings[addon.id] = {{"installation_mode", "normal_installed"}, {"install_url", install_url(addon)}};
    return Merge::Added;
}

}  // namespace desk_install::firefox_policies
