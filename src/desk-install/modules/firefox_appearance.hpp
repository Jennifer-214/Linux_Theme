#pragma once

#include "../core/context.hpp"
#include "../core/backup.hpp"
#include "../core/idempotency.hpp"
#include "../core/state_checks.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include <filesystem>
#include <fstream>
#include <vector>

namespace desk_install::firefox_appearance {

// The profile Firefox itself opens, by its own index: an [Install…] section's Default=, else the older Default=1 on a
// [Profile…]. Folder names are random, and a second, older profile is common. Only profiles.ini is read.
inline std::filesystem::path profile_from_ini(const std::filesystem::path& base) {
    std::ifstream ini(base / "profiles.ini");
    if (!ini) return {};
    std::vector<std::filesystem::path> installs, marked;
    std::string line, section, path;
    bool relative = true, chosen = false;
    auto place = [&](const std::string& p, bool rel) {
        return rel && (p.empty() || p[0] != '/') ? base / p : std::filesystem::path(p);
    };
    auto close_section = [&] {
        if (section.rfind("Profile", 0) == 0 && chosen && !path.empty()) marked.push_back(place(path, relative));
        path.clear(); relative = true; chosen = false;
    };
    while (std::getline(ini, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.size() > 1 && line.front() == '[' && line.back() == ']') {
            close_section();
            section = line.substr(1, line.size() - 2);
            continue;
        }
        const auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        const std::string key = line.substr(0, eq), value = line.substr(eq + 1);
        if (section.rfind("Install", 0) == 0 && key == "Default" && !value.empty()) installs.push_back(place(value, true));
        else if (key == "Path") path = value;
        else if (key == "IsRelative") relative = value != "0";
        else if (key == "Default") chosen = value == "1";
    }
    close_section();
    installs.insert(installs.end(), marked.begin(), marked.end());
    for (const auto& candidate : installs) {
        std::error_code ec;
        if (std::filesystem::is_directory(candidate, ec)) return candidate;
    }
    return {};
}

// Share profile discovery between full setup, palette-only deployment and browser hardening.
inline std::filesystem::path profile(const Context& ctx) {
    const auto config = ctx.config_home.empty() ? ctx.home / ".config" : ctx.config_home;
    for (const auto& base : {config / "mozilla/firefox", ctx.home / ".mozilla/firefox"}) {
        std::error_code ec;
        if (!std::filesystem::is_directory(base, ec)) continue;
        if (auto listed = profile_from_ini(base); !listed.empty()) return listed;
        std::filesystem::directory_iterator it(base, ec), end;
        while (!ec && it != end) {
            if (it->is_directory(ec) && !ec &&
                it->path().filename().string().find("default-release") != std::string::npos)
                return it->path();
            it.increment(ec);
        }
    }
    return {};
}

// --render does not run Firefox setup. Refresh only its rendered stylesheets,
// without touching preferences, opening windows or restarting the browser.
inline bool sync_styles(const Context& ctx) {
    if (sh::dry_run()) return true;
    if (!((ctx.render_ran && ctx.render_ok) || state::rendered_is_current(ctx))) return false;
    const auto dest = profile(ctx);
    if (dest.empty()) return true;
    bool ok = true, changed = false;
    for (const char* name : {"userChrome.css", "userContent.css"}) {
        const auto source = ctx.rendered_dir / "firefox" / name;
        const auto target = dest / "chrome" / name;
        if (!std::filesystem::is_regular_file(source)) continue;
        if (std::filesystem::exists(target) && idem::read_file(source) == idem::read_file(target)) continue;
        if (!deploy_file_atomic(ctx, source, target)) {
            ui::warn(std::string("Firefox ") + name + " could not be deployed");
            ok = false;
        } else changed = true;
    }
    if (changed) ui::substep("Firefox styles updated; restart Firefox to load them");
    return ok;
}

}  // namespace desk_install::firefox_appearance
