// theme-check — `desk theme check`: is the desktop the theme set up deployed and working?
//
// Read-only. It renders the active theme into a temporary folder to compare, and runs each probe under a time
// limit; it never writes a config, restarts a service or fixes anything. Each line ends with a hint instead.
// Results and exit codes are desk-health's (`desk sec health`): 0 ok · 1 warnings · 3 a high failure.

#include "drift.hpp"
#include "../desk-common/json.hpp"
#include "../desk-common/shell.hpp"
#include "../desk-health/health.hpp"
#include "../desk-install/core/built_tools.hpp"
#include <cstddef>
#include "../desk-install/modules/symlinks_data.hpp"

#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
namespace sh = desk_install::sh;
using nlohmann::json;
using desk_health::CheckResult;
using desk_health::Severity;
using desk_health::Status;

namespace {

struct Env {
    fs::path home, config, runtime, repo;
    std::string theme;
};

std::string env_or(const char* key, const std::string& fallback) {
    const char* value = std::getenv(key);
    return value && *value ? value : fallback;
}

std::string read_file(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream out;
    out << in.rdbuf();
    return out.str();
}

std::string trim(std::string text) {
    while (!text.empty() && (text.back() == '\n' || text.back() == ' ' || text.back() == '\r')) text.pop_back();
    const auto first = text.find_first_not_of(" \n");
    return first == std::string::npos ? std::string() : text.substr(first);
}

// The repo the installer would use: $FOXML_REPO, the marker `make install` writes, then ~/code/Linux_Theme.
fs::path find_repo(const fs::path& home) {
    std::vector<fs::path> candidates;
    if (const char* repo = std::getenv("FOXML_REPO"); repo && *repo) candidates.emplace_back(repo);
    std::ifstream marker(home / ".local/share/foxml/repo-dir");
    if (std::string line; std::getline(marker, line) && !line.empty()) candidates.emplace_back(line);
    candidates.push_back(home / "code/Linux_Theme");
    for (const auto& dir : candidates) {
        std::error_code ec;
        if (fs::is_directory(dir / "templates", ec) && fs::is_directory(dir / "themes", ec)) return dir;
    }
    return {};
}

struct Ran { int code = -1; std::string out; };

// A probe under a time limit. stderr joins stdout when asked, and is dropped otherwise. argv never meets a shell
// as text: the inner sh gets it as "$@".
Ran run_bounded(int seconds, const std::vector<std::string>& argv, bool with_stderr = false,
                const std::vector<std::string>& env = {}) {
    std::vector<std::string> full{"timeout", "-k", "2", std::to_string(seconds)};
    if (!env.empty()) { full.push_back("env"); full.insert(full.end(), env.begin(), env.end()); }
    full.insert(full.end(), {"sh", "-c", with_stderr ? "exec \"$@\" 2>&1" : "exec \"$@\" 2>/dev/null", "sh"});
    full.insert(full.end(), argv.begin(), argv.end());
    Ran ran;
    ran.code = sh::probe(full, ran.out);
    return ran;
}

CheckResult result(const char* id, std::string title, Severity severity, Status status,
                   std::string detail = {}, std::string hint = {}) {
    return CheckResult{id, std::move(title), severity, status, std::move(detail), std::move(hint)};
}

fs::path expand(const Env& env, const std::string& dest) {
    return dest.rfind("~/", 0) == 0 ? env.home / dest.substr(2) : fs::path(dest);
}

// ─── D1 drift ────────────────────────────────────────────────────────────────────────────────────────
// Files a machine owns: the monitor layout, the NVIDIA setup, plugin locks, the distro profile, your menu.
bool machine_owned(const fs::path& dest) {
    static const std::set<std::string> names = {"monitors.conf", "monitors.lua", "nvidia.conf", "nvidia.lua",
                                                "lazy-lock.json", "foxml-profile.json"};
    return names.count(dest.filename().string()) > 0;
}

desk_theme_check::Kind kind_for(const fs::path& dest) {
    const auto name = dest.filename().string();
    if (name == "hyprlock.conf") return desk_theme_check::Kind::Hyprlock;
    if (name == "rules.conf" || name == "rules.lua") return desk_theme_check::Kind::Rules;
    if (name == "autostart.conf" || name == "autostart.lua") return desk_theme_check::Kind::Autostart;
    return desk_theme_check::Kind::Plain;
}

struct Tally { int same = 0, yours = 0; std::vector<std::string> drift, missing; };

void compare_one(const Env& env, const fs::path& shipped, const fs::path& dest, Tally& tally) {
    std::error_code ec;
    if (!fs::is_regular_file(shipped, ec) || machine_owned(dest)) return;
    const auto shown = dest.lexically_relative(env.home).string();
    if (!fs::exists(dest, ec)) { tally.missing.push_back("~/" + shown); return; }
    switch (desk_theme_check::compare(read_file(shipped), read_file(dest), kind_for(dest))) {
        case desk_theme_check::Verdict::Same:  ++tally.same; break;
        case desk_theme_check::Verdict::Yours: ++tally.yours; break;
        case desk_theme_check::Verdict::Drift: tally.drift.push_back("~/" + shown); break;
    }
}

// The bulk folders specials.cpp deploys (BULK) and the drawer module's Quickshell copy.
void compare_folder(const Env& env, const fs::path& src, const fs::path& dest, const std::string& ext,
                    const std::set<std::string>& skip, Tally& tally) {
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(src, ec)) {
        if (!entry.is_regular_file()) continue;
        const auto name = entry.path().filename().string();
        if ((!ext.empty() && entry.path().extension() != ext) || skip.count(name)) continue;
        compare_one(env, entry.path(), dest / (name == "menus.json" ? "menus.default.json" : name), tally);
    }
}

fs::path firefox_profile(const Env& env) {
    for (const auto& base : {env.config / "mozilla/firefox", env.home / ".mozilla/firefox"}) {
        std::ifstream ini(base / "profiles.ini");
        std::string line, section, path, chosen;
        bool relative = true, is_default = false;
        auto settle = [&] {
            if (section.rfind("Install", 0) == 0 && !path.empty()) chosen = path;
            else if (section.rfind("Profile", 0) == 0 && is_default && chosen.empty() && !path.empty())
                chosen = relative ? (base / path).string() : path;
        };
        while (std::getline(ini, line)) {
            if (!line.empty() && line[0] == '[') {
                settle();
                section = line.substr(1, line.find(']') - 1); path.clear(); relative = true; is_default = false;
            } else if (line.rfind("Default=", 0) == 0) {
                if (section.rfind("Install", 0) == 0) path = (base / line.substr(8)).string();
                else is_default = line.substr(8) == "1";
            } else if (line.rfind("Path=", 0) == 0) path = line.substr(5);
            else if (line.rfind("IsRelative=", 0) == 0) relative = line.substr(11) == "1";
        }
        settle();
        if (!chosen.empty()) return chosen;
    }
    return {};
}

CheckResult check_drift(const Env& env) {
    const auto renderer = env.repo / "src/desk-render/desk-render-fast";
    const auto palette = env.repo / "themes" / env.theme / "palette.sh";
    std::error_code ec;
    if (!fs::exists(renderer, ec))
        return result("D1", "deployed files match the theme", Severity::Medium, Status::Skip, "",
                      "make -C " + (env.repo / "src/desk-render").string());
    if (!fs::exists(palette, ec))
        return result("D1", "deployed files match the theme", Severity::Medium, Status::Skip,
                      "no palette for the active theme '" + env.theme + "'");
    const auto rendered = fs::temp_directory_path() / ("fox-theme-check-" + std::to_string(::getpid()));
    struct Cleanup { fs::path dir; ~Cleanup() { std::error_code e; fs::remove_all(dir, e); } } cleanup{rendered};
    if (run_bounded(60, {renderer.string(), palette.string(), (env.repo / "templates").string(), rendered.string()}).code != 0)
        return result("D1", "deployed files match the theme", Severity::Medium, Status::Fail,
                      "the renderer failed for " + env.theme, "render it by hand to see the error");

    Tally tally;
    namespace map = desk_install::symlinks;
    const auto profile = firefox_profile(env);
    for (const auto& m : map::TEMPLATE_MAPPINGS) {
        std::string dest = m.dest;
        if (dest.find("AGENT_DIR") != std::string::npos) continue;
        if (dest.rfind("FIREFOX_PROFILE", 0) == 0) {
            if (profile.empty()) continue;
            compare_one(env, rendered / m.src, profile / dest.substr(16), tally);
            continue;
        }
        compare_one(env, rendered / m.src, expand(env, dest), tally);
    }
    for (const auto& m : map::SHARED_MAPPINGS) compare_one(env, env.repo / "shared" / m.src, expand(env, m.dest), tally);

    const auto built = desk_install::built_tool_names(env.repo / "src");
    compare_folder(env, env.repo / "shared/bin", env.home / ".local/bin", "", built, tally);
    compare_folder(env, env.repo / "shared/hyprland_scripts", env.config / "hypr/scripts", ".sh",
                   {"monitor-watch.sh", "focus-pulse.sh"}, tally);
    compare_folder(env, env.repo / "shared/waybar_scripts", env.config / "waybar/scripts", ".sh", {}, tally);
    compare_folder(env, env.repo / "shared/pulse.d", env.config / "foxml/pulse.d", ".sh", {}, tally);
    std::set<std::string> theme_owned;  // theme.* and nvidia.* come from the render, monitors.* from this machine
    for (const char* name : {"theme.conf", "theme.lua", "nvidia.conf", "nvidia.lua"}) theme_owned.insert(name);
    compare_folder(env, env.repo / "shared/hyprland_modules", env.config / "hypr/modules", ".conf", theme_owned, tally);
    compare_folder(env, env.repo / "shared/hyprland_modules", env.config / "hypr/modules", ".lua", theme_owned, tally);
    compare_folder(env, rendered / "quickshell/foxml", env.config / "quickshell/foxml", "", {}, tally);
    compare_folder(env, env.repo / "shared/quickshell/foxml", env.config / "quickshell/foxml", "", {}, tally);

    std::ostringstream detail;
    detail << tally.same << " match";
    if (tally.yours) detail << ", " << tally.yours << " match with lines of your own added";
    if (profile.empty()) detail << "; Firefox profile not found, its files not compared";
    for (const auto& path : tally.drift) detail << "\n  differs: " << path;
    for (const auto& path : tally.missing) detail << "\n  missing: " << path;
    if (tally.drift.empty() && tally.missing.empty())
        return result("D1", "deployed files match the theme", Severity::Medium, Status::Pass, detail.str());
    const auto count = tally.drift.size() + tally.missing.size();
    const auto title = std::to_string(count) + (count == 1 ? " deployed file differs" : " deployed files differ")
                     + " from the theme";
    return result("D1", title, Severity::Medium, Status::Warn, detail.str(),
                  "re-render: ./install.sh --render-only " + env.theme + "  (the installer backs up what it replaces)");
}

// ─── D2–D9 ───────────────────────────────────────────────────────────────────────────────────────────
bool in_session() { return !env_or("HYPRLAND_INSTANCE_SIGNATURE", "").empty(); }

CheckResult check_hyprland(const Env&) {
    if (!in_session() || !sh::have("hyprctl"))
        return result("D2", "Hyprland config has no errors", Severity::High, Status::Skip, "not in a Hyprland session");
    const auto ran = run_bounded(5, {"hyprctl", "configerrors"}, true);
    const auto said = trim(ran.out);
    if (ran.code == 0 && (said.empty() || said == "no errors"))
        return result("D2", "Hyprland config has no errors", Severity::High, Status::Pass);
    return result("D2", "Hyprland config has no errors", Severity::High, Status::Fail, said,
                  "hyprctl configerrors");
}

CheckResult check_quickshell(const Env& env) {
    const char* title = "Quickshell (bar and drawer) loaded";
    if (!in_session()) return result("D3", title, Severity::High, Status::Skip, "not in a Hyprland session");
    if (run_bounded(3, {"pgrep", "-x", "quickshell"}).code != 0)
        return result("D3", title, Severity::High, Status::Fail, "quickshell is not running",
                      "start it from your autostart, or log out and in");
    fs::path newest; fs::file_time_type when{};
    std::error_code ec;
    for (const auto& run : fs::directory_iterator(env.runtime / "quickshell/by-id", ec)) {
        const auto log = run.path() / "log.qslog";
        if (fs::exists(log, ec) && (newest.empty() || fs::last_write_time(log, ec) > when)) {
            newest = log; when = fs::last_write_time(log, ec);
        }
    }
    if (newest.empty()) return result("D3", title, Severity::High, Status::Pass, "running; no log to read");
    const auto log = run_bounded(5, {"quickshell", "log", newest.string()}, true).out;
    const auto loaded = log.rfind("Configuration Loaded"), failed = log.rfind("Failed to load configuration");
    if (failed == std::string::npos || (loaded != std::string::npos && loaded > failed))
        return result("D3", title, Severity::High, Status::Pass);
    const auto cause = log.find("caused by", failed);
    return result("D3", title, Severity::High, Status::Fail,
                  cause == std::string::npos ? "its last reload failed" : log.substr(cause, log.find('\n', cause) - cause),
                  "touch ~/.config/quickshell/foxml/shell.qml to reload it once the cause is fixed");
}

CheckResult check_drawer(const Env& env) {
    const char* title = "every drawer page opens";
    const auto drawer = env.home / ".local/bin/desk-drawer";
    const auto menus = env.config / "quickshell/foxml/menus.json";
    std::error_code ec;
    if (!fs::exists(drawer, ec)) return result("D4", title, Severity::Medium, Status::Skip, "the drawer is not installed");
    const auto config = json::parse(read_file(menus), nullptr, false);
    if (!config.is_object() || !config.contains("groups"))
        return result("D4", title, Severity::Medium, Status::Fail, menus.string() + " does not parse",
                      "compare it with menus.default.json beside it");
    std::set<std::string> pages;
    for (const auto& group : config["groups"]) {
        if (!group.is_object() || !group.contains("items") || !group["items"].is_array()) continue;
        if (group.contains("id") && group["id"].is_string()) pages.insert(group["id"].get<std::string>());
        for (const auto& item : group["items"])
            if (item.is_object() && item.value("kind", "") == "page" && item.contains("page") && item["page"].is_string())
                pages.insert(item["page"].get<std::string>());
    }
    std::vector<std::string> broken;
    for (const auto& page : pages) {
        const auto ran = run_bounded(8, {drawer.string(), "view", page});
        const auto data = json::parse(ran.out, nullptr, false);
        if (ran.code == 124) broken.push_back(page + " (took over 8 s)");
        else if (!data.is_object() || (data.contains("ok") && data["ok"] == false) || data.contains("error"))
            broken.push_back(page + (data.is_object() && data.contains("message") ? " (" + data.value("message", "") + ")" : ""));
    }
    if (broken.empty())
        return result("D4", title, Severity::Medium, Status::Pass, std::to_string(pages.size()) + " pages");
    std::string detail;
    for (const auto& page : broken) detail += "  " + page + "\n";
    return result("D4", title, Severity::Medium, Status::Fail, trim(detail), "desk-drawer view <page> shows the error");
}

CheckResult check_bar(const Env& env) {
    const char* title = "every bar module answers";
    std::vector<std::string> broken;
    std::set<std::string> seen;
    for (const char* name : {"config", "config_secondary"}) {
        const auto config = json::parse(read_file(env.config / "waybar" / name), nullptr, false, true);
        if (!config.is_object()) continue;
        for (const auto& [key, module] : config.items()) {
            if (key.rfind("custom/", 0) != 0 || !module.is_object() || !module.contains("exec") || !seen.insert(key).second) continue;
            const auto ran = run_bounded(5, {"sh", "-c", module["exec"].get<std::string>()});
            const auto first = ran.out.substr(0, ran.out.find('\n'));
            const bool streaming = ran.code == 124 && !first.empty();  // a module that keeps printing
            if (ran.code != 0 && !streaming) { broken.push_back(key + " (exit " + std::to_string(ran.code) + ")"); continue; }
            if (module.value("return-type", "") == "json" && !first.empty() && !json::accept(first))
                broken.push_back(key + " (not JSON)");
        }
    }
    if (seen.empty()) return result("D5", title, Severity::Medium, Status::Skip, "no bar config found");
    if (broken.empty()) return result("D5", title, Severity::Medium, Status::Pass, std::to_string(seen.size()) + " modules");
    std::string detail;
    for (const auto& item : broken) detail += "  " + item + "\n";
    return result("D5", title, Severity::Medium, Status::Warn, trim(detail), "run the module's exec line by hand");
}

CheckResult check_configs(const Env& env) {
    const char* title = "tmux and lock screen configs parse";
    std::vector<std::string> problems;
    const auto tmux_conf = env.home / ".tmux.conf";
    std::error_code ec;
    if (sh::have("tmux") && fs::exists(tmux_conf, ec)) {
        // A throwaway server on its own socket: the running one is never touched.
        const auto socket = "fox-theme-check-" + std::to_string(::getpid());
        const auto ran = run_bounded(5, {"tmux", "-L", socket, "-f", "/dev/null", "new-session", "-d", ";",
                                         "source-file", "-n", tmux_conf.string(), ";", "kill-server"}, true);
        if (ran.code != 0) problems.push_back("~/.tmux.conf: " + trim(ran.out));
    }
    // Every helper the lock screen calls must be there, or its label stays blank.
    static const std::regex script(R"((hypr/scripts|\.local/bin)/[A-Za-z0-9_.-]+)");
    const auto lock = read_file(env.config / "hypr/hyprlock.conf");
    for (std::sregex_iterator it(lock.begin(), lock.end(), script), end; it != end; ++it) {
        const auto rel = it->str();
        const auto path = rel.rfind("hypr/", 0) == 0 ? env.config / rel : env.home / rel;
        if (!fs::exists(path, ec)) problems.push_back("hyprlock.conf calls " + rel + ", which is missing");
    }
    if (problems.empty()) return result("D6", title, Severity::Medium, Status::Pass);
    std::string detail;
    for (const auto& item : problems) detail += "  " + item + "\n";
    return result("D6", title, Severity::Medium, Status::Fail, trim(detail));
}

CheckResult check_nvim(const Env&) {
    const char* title = "Neovim starts without errors";
    if (!sh::have("nvim")) return result("D7", title, Severity::Low, Status::Skip, "nvim is not installed");
    const auto ran = run_bounded(20, {"nvim", "--headless", "-i", "NONE", "+qa"}, true);
    if (ran.code == 124) return result("D7", title, Severity::Low, Status::Warn, "it took over 20 s", "nvim --startuptime /tmp/nvim.log");
    const auto said = trim(ran.out);
    if (ran.code == 0 && said.empty()) return result("D7", title, Severity::Low, Status::Pass);
    return result("D7", title, Severity::Low, Status::Warn, said.substr(0, 600), "start nvim and read :messages");
}

CheckResult check_claude(const Env& env) {
    const char* title = "Claude status line and paper mod work";
    const auto line = env.home / ".claude/statusline.sh";
    const auto mod = env.home / ".claude/mods/foxml-paper";
    std::error_code ec;
    if (!fs::exists(line, ec) && !fs::exists(mod, ec)) return result("D8", title, Severity::Low, Status::Skip, "not deployed");
    std::vector<std::string> problems;
    if (fs::exists(line, ec)) {
        // Its snapshot goes to a throwaway runtime folder, so the bar never sees this sample session.
        const auto scratch = fs::temp_directory_path() / ("fox-theme-check-run-" + std::to_string(::getpid()));
        fs::create_directories(scratch, ec);
        const auto sample = R"({"session_id":"theme-check","model":{"display_name":"Claude"},"context_window":{"used_percentage":40}})";
        const auto ran = run_bounded(5, {"sh", "-c", "printf '%s' \"$1\" | bash \"$2\"", "sh", sample, line.string()}, false,
                                     {"XDG_RUNTIME_DIR=" + scratch.string(), "COLUMNS=120"});
        fs::remove_all(scratch, ec);
        if (ran.code != 0 || ran.out.find("Claude") == std::string::npos) problems.push_back("the status line printed nothing usable");
    }
    if (fs::exists(mod, ec) && sh::have("claude")) {
        const auto ran = run_bounded(60, {"claude", "plugin", "validate", mod.string()}, true);
        if (ran.code != 0) problems.push_back("the paper mod does not validate: claude plugin validate " + mod.string());
    }
    if (problems.empty()) return result("D8", title, Severity::Low, Status::Pass);
    std::string detail;
    for (const auto& item : problems) detail += "  " + item + "\n";
    return result("D8", title, Severity::Low, Status::Warn, trim(detail));
}

CheckResult check_services(const Env&) {
    const char* title = "desktop services running, none doubled";
    if (!sh::have("systemctl")) return result("D9", title, Severity::Medium, Status::Skip, "no systemctl");
    std::vector<std::string> problems;
    const auto state = [](const std::string& unit, const char* what) {
        return trim(run_bounded(5, {"systemctl", "--user", what, unit}).out);
    };
    for (const char* unit : {"fox-pulse.service"})
        if (state(unit, "is-enabled") == "enabled" && state(unit, "is-active") != "active")
            problems.push_back(std::string(unit) + " is enabled but not running");
    // Jobs desk-pulse took over: either one still running means two owners.
    for (const char* unit : {"foxml-focus-pulse.service", "fox-monitor-watch.service"})
        if (state(unit, "is-active") == "active")
            problems.push_back(std::string(unit) + " still runs beside desk-pulse (retired)");
    for (const char* timer : {"wallpaper-rotate.timer", "fox-theme-check.timer"})
        if (state(timer, "is-enabled") == "enabled" && state(timer, "is-active") != "active")
            problems.push_back(std::string(timer) + " is enabled but not running");
    if (problems.empty()) return result("D9", title, Severity::Medium, Status::Pass);
    std::string detail;
    for (const auto& item : problems) detail += "  " + item + "\n";
    return result("D9", title, Severity::Medium, Status::Warn, trim(detail),
                  "systemctl --user disable --now <retired unit>; systemctl --user restart <stopped unit>");
}

// A value from the active theme's palette.sh (KEY=value lines, quotes allowed).
std::string palette_value(const Env& env, const std::string& key) {
    for (const auto& line : desk_theme_check::split_lines(read_file(env.repo / "themes" / env.theme / "palette.sh"))) {
        if (line.rfind(key + "=", 0) != 0) continue;
        auto value = line.substr(key.size() + 1);
        if (value.size() >= 2 && (value.front() == '"' || value.front() == '\'') && value.back() == value.front())
            value = value.substr(1, value.size() - 2);
        return value;
    }
    return {};
}

std::string gsetting(const char* key) {
    if (!sh::have("gsettings")) return {};
    auto value = trim(run_bounded(5, {"gsettings", "get", "org.gnome.desktop.interface", key}).out);
    if (value.size() >= 2 && value.front() == '\'' && value.back() == '\'') value = value.substr(1, value.size() - 2);
    return value;
}

CheckResult check_gtk(const Env& env) {
    const char* title = "GTK apps are light or dark like the theme";
    const auto dark = palette_value(env, "GTK_PREFER_DARK");
    const auto scheme = gsetting("color-scheme");
    if (dark.empty() || scheme.empty()) return result("D10", title, Severity::Low, Status::Skip, "no gsettings or no GTK_PREFER_DARK");
    const bool wants_dark = dark == "1" || dark == "true";
    if (wants_dark == (scheme == "prefer-dark")) return result("D10", title, Severity::Low, Status::Pass, "color-scheme " + scheme);
    return result("D10", title, Severity::Low, Status::Warn,
                  std::string("the theme is ") + (wants_dark ? "dark" : "light") + " but color-scheme is " + scheme
                  + "; GTK 4 and libadwaita apps follow color-scheme",
                  std::string("gsettings set org.gnome.desktop.interface color-scheme ") + (wants_dark ? "prefer-dark" : "default"));
}

CheckResult check_firefox(const Env& env) {
    const char* title = "Firefox find colours are the theme's";
    const auto bg = palette_value(env, "FF_FIND_BG"), fg = palette_value(env, "FF_FIND_FG");
    const auto profile = firefox_profile(env);
    std::error_code ec;
    if (bg.empty() || profile.empty() || !fs::exists(profile / "user.js", ec))
        return result("D11", title, Severity::Low, Status::Skip, profile.empty() ? "no Firefox profile found" : "no user.js or no find colours in the theme");
    const auto prefs = read_file(profile / "user.js");
    std::vector<std::string> missing;
    static const char* const prefs_wanted[] = {"ui.textHighlightBackground", "ui.textHighlightForeground",
                                               "ui.textSelectAttentionBackground", "ui.textSelectAttentionForeground"};
    for (const char* pref : prefs_wanted) {
        const auto& colour = std::string(pref).find("Background") != std::string::npos ? bg : fg;
        if (prefs.find(std::string("user_pref(\"") + pref + "\", \"#" + colour + "\");") == std::string::npos) missing.push_back(pref);
    }
    if (missing.empty()) return result("D11", title, Severity::Low, Status::Pass);
    std::string detail = "not set to the theme in user.js:";
    for (const auto& pref : missing) detail += " " + pref;
    return result("D11", title, Severity::Low, Status::Warn, detail, "re-render, then restart Firefox");
}

CheckResult check_cursor(const Env& env) {
    const char* title = "the pointer is the theme's cursor";
    const auto want = palette_value(env, "CURSOR_THEME");
    const auto have = gsetting("cursor-theme");
    if (want.empty() || have.empty()) return result("D12", title, Severity::Low, Status::Skip, "no gsettings or no CURSOR_THEME");
    std::error_code ec;
    bool installed = false;
    for (const auto& dir : {env.home / ".local/share/icons", env.home / ".icons", fs::path("/usr/share/icons")})
        installed = installed || fs::is_directory(dir / want / "cursors", ec);
    if (have == want && installed) return result("D12", title, Severity::Low, Status::Pass, want);
    return result("D12", title, Severity::Low, Status::Warn,
                  have != want ? "cursor-theme is " + have + ", the theme's is " + want : want + " is not installed",
                  "re-run the installer's cursor step (catppuccin_cursor)");
}

CheckResult check_lock_panel(const Env& env) {
    const char* title = "the lock screen's password field is on a screen you can see";
    const auto chooser = env.home / ".local/bin/lock-panel";
    const auto conf = env.config / "hypr/hyprlock.conf";
    std::error_code ec;
    if (!fs::exists(conf, ec)) return result("D13", title, Severity::Medium, Status::Skip, "no lock screen config");
    if (!in_session()) return result("D13", title, Severity::Medium, Status::Skip, "not in a Hyprland session");
    if (!fs::exists(chooser, ec))
        return result("D13", title, Severity::Medium, Status::Warn, "lock-panel is not installed, so the panel always uses its install-time pin",
                      "re-run the installer");
    const auto chosen = trim(run_bounded(5, {"bash", chooser.string()}).out);
    if (chosen.empty() || chosen == conf.string())
        return result("D13", title, Severity::Medium, Status::Pass, "its pinned monitor is connected, on and open");
    std::string to;
    for (const auto& line : desk_theme_check::split_lines(read_file(chosen)))
        if (line.find("monitor =") != std::string::npos && to.empty() && line.find("monitor =") + 9 < line.size()) to = trim(line.substr(line.find('=') + 1));
    return result("D13", title, Severity::Medium, Status::Pass,
                  "its pinned monitor is shut or unplugged; locking now would put it on " + (to.empty() ? std::string("another screen") : to));
}

struct Entry { const char* id; CheckResult (*fn)(const Env&); };
const Entry CHECKS[] = {
    {"D1", check_drift}, {"D2", check_hyprland}, {"D3", check_quickshell}, {"D4", check_drawer}, {"D5", check_bar},
    {"D6", check_configs}, {"D7", check_nvim}, {"D8", check_claude}, {"D9", check_services},
    {"D10", check_gtk}, {"D11", check_firefox}, {"D12", check_cursor}, {"D13", check_lock_panel},
};

std::vector<std::string> split_csv(const std::string& text) {
    std::vector<std::string> out;
    std::stringstream in(text);
    for (std::string item; std::getline(in, item, ',');) if (!item.empty()) out.push_back(item);
    return out;
}

const char* mark(Status status) {
    const bool tty = ::isatty(STDOUT_FILENO);
    switch (status) {
        case Status::Pass: return tty ? "\033[32m✓\033[0m   " : "ok  ";
        case Status::Warn: return tty ? "\033[33m!\033[0m   " : "warn";
        case Status::Fail: return tty ? "\033[31m✗\033[0m   " : "fail";
        case Status::Skip: return tty ? "\033[2m-\033[0m   " : "skip";
    }
    return "";
}

}  // namespace

int main(int argc, char** argv) {
    bool quiet = false, verbose = false;
    std::vector<std::string> only;
    std::string theme;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--theme" && i + 1 < argc) theme = argv[++i];
        else if (arg == "--quiet" || arg == "-q") quiet = true;
        else if (arg == "--verbose" || arg == "-v") verbose = true;
        else if (arg == "--only" && i + 1 < argc) only = split_csv(argv[++i]);
        else if (arg == "-h" || arg == "--help") {
            std::printf("usage: desk theme check [--verbose] [--quiet] [--only D1,D4] [--theme NAME]\n\n"
                        "Checks that the desktop the theme set up is deployed and working. Read-only.\n"
                        "--theme compares against another theme than the active one (after a swap, say).\n"
                        "  D1 deployed files match the theme   D2 Hyprland config   D3 Quickshell\n"
                        "  D4 drawer pages   D5 bar modules   D6 tmux / lock screen   D7 Neovim\n"
                        "  D8 Claude status line and mod   D9 services   D10 GTK light/dark   D11 Firefox find colours\n"
                        "  D12 cursor   D13 lock screen panel on a visible screen\n\n"
                        "exit codes: 0 ok  1 warnings  2 critical  3 high\n");
            return 0;
        } else { std::fprintf(stderr, "desk theme check: unknown option %s (see --help)\n", arg.c_str()); return 64; }
    }

    Env env;
    env.home = env_or("HOME", "/");
    env.config = env_or("XDG_CONFIG_HOME", (env.home / ".config").string());
    env.runtime = env_or("XDG_RUNTIME_DIR", "/run/user/" + std::to_string(::getuid()));
    env.repo = find_repo(env.home);
    env.theme = !theme.empty() ? theme : env.repo.empty() ? "" : trim(read_file(env.repo / ".active-theme"));
    if (env.theme.empty()) env.theme = "FoxML_Classic";
    if (env.theme.find('/') != std::string::npos || env.theme.rfind('.', 0) == 0) {
        std::fprintf(stderr, "desk theme check: not a theme name: %s\n", env.theme.c_str());
        return 64;
    }

    std::vector<CheckResult> results;
    for (const auto& check : CHECKS) {
        if (!only.empty() && std::none_of(only.begin(), only.end(), [&](const std::string& id) { return id == check.id; })) continue;
        if (std::string(check.id) == "D1" && env.repo.empty()) {
            results.push_back(result("D1", "deployed files match the theme", Severity::Medium, Status::Skip,
                                     "the theme repo was not found", "set FOXML_REPO to it"));
            continue;
        }
        results.push_back(check.fn(env));
        if (quiet) continue;
        const auto& r = results.back();
        std::printf("%s %-3s  %s\n", mark(r.status), r.id.c_str(), r.title.c_str());
        if ((verbose || r.status == Status::Warn || r.status == Status::Fail) && !r.detail.empty()) {
            std::istringstream lines(r.detail);
            for (std::string line; std::getline(lines, line);) std::printf("        %s\n", line.c_str());
        }
        if (r.status != Status::Pass && r.status != Status::Skip && !r.fix_hint.empty())
            std::printf("        → %s\n", r.fix_hint.c_str());
        std::fflush(stdout);
    }
    if (!quiet) std::printf("\ntheme %s · repo %s\n", env.theme.c_str(), env.repo.empty() ? "not found" : env.repo.c_str());
    return desk_health::worst_exit(results);
}
