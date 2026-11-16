#pragma once

#include "../core/context.hpp"
#include "../core/backup.hpp"
#include "../core/idempotency.hpp"
#include "../core/state_checks.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include <filesystem>
#include <fstream>
#include <random>
#include <string>
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

// A Firefox that has never run has no profile, so a fresh install left it unthemed and unhardened until a second run.
// This lays down the profile its first start will open, without starting it: a folder where it reads profiles (the old
// ~/.mozilla/firefox when that exists, else the XDG one), listed in profiles.ini as the default and holding a
// compatibility.ini. On its first run Firefox claims such a default as this installation's profile; without the
// compatibility.ini it would make a new one beside it. An index Firefox wrote is never rewritten. Empty, with `why`
// set, when there is none.
inline std::filesystem::path ensure_profile(const Context& ctx, std::string& why) {
    namespace fs = std::filesystem;
    if (auto found = profile(ctx); !found.empty()) return found;
    if (!sh::have("firefox")) { why = "Firefox is not installed"; return {}; }
    const auto config = ctx.config_home.empty() ? ctx.home / ".config" : ctx.config_home;
    const fs::path legacy = ctx.home / ".mozilla/firefox", xdg = config / "mozilla/firefox";
    std::error_code ec;
    for (const auto& base : {xdg, legacy}) {
        if (fs::exists(base / "profiles.ini", ec)) {
            why = (base / "profiles.ini").string() + " names no profile folder that is there; open Firefox once";
            return {};
        }
    }
    if (sh::dry_run()) { why = "a dry run makes no profile"; return {}; }
    const fs::path base = fs::is_directory(legacy, ec) ? legacy : xdg;
    const bool new_base = !fs::exists(base, ec);
    std::random_device random;
    std::string salt;
    for (int i = 0; i < 8; ++i) salt += "abcdefghijklmnopqrstuvwxyz0123456789"[random() % 36];
    const fs::path dir = base / (salt + ".default-release");
    fs::create_directories(dir, ec);
    if (ec) { why = "could not make " + dir.string() + ": " + ec.message(); return {}; }
    fs::permissions(dir, fs::perms::owner_all, fs::perm_options::replace, ec);
    if (new_base) fs::permissions(base, fs::perms::owner_all, fs::perm_options::replace, ec);
    if (!idem::write_atomic(dir / "compatibility.ini", "[Compatibility]\n") ||
        !idem::write_atomic(base / "profiles.ini", "[Profile0]\nName=default-release\nIsRelative=1\nPath=" +
                                                   dir.filename().string() + "\nDefault=1\n\n"
                                                   "[General]\nStartWithLastProfile=1\nVersion=2\n")) {
        why = "could not write Firefox's profile index in " + base.string();
        return {};
    }
    ui::ok("Firefox profile made for its first start: " + dir.string());
    return dir;
}

// Firefox's "Website appearance": the colour scheme pages are told the reader prefers (prefers-color-scheme).
inline constexpr const char* WEBSITE_APPEARANCE = "layout.css.prefers-color-scheme.content-override";

// The theme's block for user.js: the rendered find colours, and the website appearance a theme names in
// FF_WEBSITE_APPEARANCE (dark, light or auto; retro-amber asks for dark). A theme without one writes the block as it
// is. user.js cannot unset a pref (Firefox keeps the last value in prefs.js), so after a theme that set one the block
// carries Firefox's own default, 2, for one run; `old_block` is the block user.js holds now.
inline std::string theme_block(std::string block, const std::string& appearance, const std::string& old_block) {
    const std::string key = std::string("\"") + WEBSITE_APPEARANCE + "\", ";
    std::string value = appearance == "dark" ? "0" : appearance == "light" ? "1" : appearance == "auto" ? "2" : "";
    if (value.empty()) {
        const auto set = old_block.find(key);
        if (set == std::string::npos || old_block.compare(set + key.size(), 1, "2") == 0) return block;
        value = "2";
    }
    const auto end = block.rfind("// <<<");
    block.insert(end == std::string::npos ? block.size() : end,
                 std::string("user_pref(\"") + WEBSITE_APPEARANCE + "\", " + value + ");\n");
    return block;
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
