// modules/nvim_lock.hpp — is Neovim's deployed lazy-lock.json the repo's? post_install says the plugins are at the
// lock only when it is; desk theme check's D18 asks the same of the deployed file.
#pragma once

#include "../../desk-common/json.hpp"

#include <string>
#include <vector>

namespace desk_install::nvim_lock {

// The plugins in both locks whose commits differ. One only the repo pins is not counted: the spec can leave a plugin
// out on this machine, and lazy writes no line for what it did not install. A lock that does not parse: "(unreadable)".
inline std::vector<std::string> mismatches(const std::string& repo_text, const std::string& deployed_text) {
    using json = nlohmann::json;
    const json repo = json::parse(repo_text, nullptr, false);
    const json deployed = json::parse(deployed_text, nullptr, false);
    if (!repo.is_object() || !deployed.is_object()) return {"(unreadable)"};
    const auto commit = [](const json& v) {
        return v.is_object() && v.contains("commit") && v["commit"].is_string() ? v["commit"].get<std::string>() : std::string();
    };
    std::vector<std::string> out;
    for (auto it = repo.begin(); it != repo.end(); ++it) {
        const auto there = deployed.find(it.key());
        if (there != deployed.end() && commit(*it) != commit(*there)) out.push_back(it.key());
    }
    return out;
}

}  // namespace desk_install::nvim_lock
