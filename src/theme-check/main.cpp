// theme-check — `desk theme check`: is the desktop the theme set up deployed and working?
//
// Read-only. It renders the active theme into a temporary folder to compare, and runs each probe under a time
// limit; it never writes a config, restarts a service or fixes anything. Each line ends with a hint instead.
// Running programs are only looked at in /proc and in desk-work's records: never asked, signalled or connected to.
// Results and exit codes are desk-health's (`desk sec health`): 0 ok · 1 warnings · 2 critical · 3 a high failure.
// DESK_THEME_CHECK_ROOT (tests) names a folder that stands in for / where the checks read /etc, /proc and /usr.

#include "drift.hpp"
#include "../desk-common/json.hpp"
#include "../desk-common/shell.hpp"
#include "../desk-health/health.hpp"
#include "../desk-install/core/built_tools.hpp"
#include <cstddef>
#include "../desk-install/modules/arch_audit_units.hpp"
#include "../desk-install/modules/etcwatch_units.hpp"
#include "../desk-install/modules/firefox_appearance.hpp"
#include "../desk-install/modules/stale_services.hpp"
#include "../desk-install/modules/symlinks_data.hpp"
#include "../desk-install/modules/workflow_assets.hpp"

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <map>
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

// The profile Firefox opens (profiles.ini), found the way the installer finds the one it themes.
fs::path firefox_profile(const Env& env) {
    desk_install::Context ctx;
    ctx.home = env.home;
    ctx.config_home = env.config;
    return desk_install::firefox_appearance::profile(ctx);
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
    for (const auto& m : map::SHARED_MAPPINGS)
        if (!desk_install::workflow::build_stamp(m.src)) compare_one(env, env.repo / "shared" / m.src, expand(env, m.dest), tally);

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
    compare_folder(env, rendered / "quickshell/desk", env.config / "quickshell/desk", "", {}, tally);
    compare_folder(env, env.repo / "shared/quickshell/desk", env.config / "quickshell/desk", "", {"Build.js"}, tally);

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
                  "touch ~/.config/quickshell/desk/shell.qml to reload it once the cause is fixed");
}

CheckResult check_drawer(const Env& env) {
    const char* title = "every drawer page opens";
    const auto drawer = env.home / ".local/bin/desk-drawer";
    const auto menus = env.config / "quickshell/desk/menus.json";
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

// `desk-work health`, asked once a run: D8 reads its alerts, D25 the sessions it knows run older code.
const json& work_health() {
    static json health(json::value_t::discarded);
    static bool asked = false;
    if (asked || !sh::have("desk-work")) return health;
    asked = true;
    const auto probe = run_bounded(15, {"desk-work", "health"}, true);
    if (probe.code == 0) health = json::parse(probe.out, nullptr, false);
    return health;
}

CheckResult check_claude(const Env& env) {
    const char* title = "Claude status line and paper mod work";
    const auto line = env.home / ".claude/statusline.sh";
    const auto mod = env.home / ".claude/mods/desk-notebook";
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
        // Any case: retro-amber's line says the model in capitals (CLAUDE).
        std::string said = ran.out;
        std::transform(said.begin(), said.end(), said.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        if (ran.code != 0 || said.find("claude") == std::string::npos) problems.push_back("the status line printed nothing usable");
    }
    if (fs::exists(mod, ec) && sh::have("claude")) {
        const auto ran = run_bounded(60, {"claude", "plugin", "validate", mod.string()}, true);
        if (ran.code != 0) problems.push_back("the paper mod does not validate: claude plugin validate " + mod.string());
    }
    if (const auto& versions = work_health(); versions.is_object()) {
        for (const auto& alert : versions.value("alerts", nlohmann::json::array())) if (alert.is_string()) problems.push_back(alert.get<std::string>());
        if (!versions.value("alerts", nlohmann::json::array()).empty()) problems.push_back("desk-work health shows last refresh, retry times and recovery details");
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

// ─── D14–D25: what the 2026-11-16 batch put in place, and what still runs the version before it ─────
// A system path, under the folder DESK_THEME_CHECK_ROOT names when a test sets it.
fs::path sys(const std::string& path) {
    static const std::string root = env_or("DESK_THEME_CHECK_ROOT", "");
    return root.empty() ? fs::path(path) : fs::path(root) / path.substr(1);
}

bool has(const std::string& text, const std::string& part) { return text.find(part) != std::string::npos; }

// A string field of JSON another program wrote; empty when it is missing or not a string.
std::string text_of(const json& row, const char* key) {
    return row.is_object() && row.contains(key) && row[key].is_string() ? row[key].get<std::string>() : std::string();
}

std::string tilde(const Env& env, const fs::path& path) {
    const auto rel = path.lexically_relative(env.home);
    return !rel.empty() && *rel.begin() != ".." ? "~/" + rel.string() : path.string();
}

std::time_t mtime(const fs::path& path) {
    struct stat st{};
    return ::stat(path.c_str(), &st) == 0 ? st.st_mtime : 0;
}

std::string clock_at(std::time_t at) {
    char text[32] = "";
    std::tm local{};
    if (::localtime_r(&at, &local)) std::strftime(text, sizeof text, "%a %H:%M", &local);
    return text;
}

// The program a shell would run for `name`, or empty.
std::string which(const std::string& name) {
    std::stringstream dirs(env_or("PATH", ""));
    for (std::string dir; std::getline(dirs, dir, ':');) {
        const auto full = (dir.empty() ? fs::path(".") : fs::path(dir)) / name;
        std::error_code ec;
        if (fs::is_regular_file(full, ec) && ::access(full.c_str(), X_OK) == 0) return full.string();
    }
    return {};
}

CheckResult listed(const char* id, const char* title, Severity severity, const std::vector<std::string>& lines,
                   std::string hint) {
    std::string detail;
    for (const auto& line : lines) detail += (detail.empty() ? "  " : "\n  ") + line;
    return result(id, title, severity, Status::Warn, detail, std::move(hint));
}

// Her own processes, read once from /proc: nothing is asked of them.
struct Proc { long long pid = 0, ppid = 0; std::string comm, args; std::time_t started = 0; };

const std::vector<Proc>& processes() {
    static std::vector<Proc> found;
    static bool read = false;
    if (read) return found;
    read = true;
    long long boot = 0;
    for (const auto& line : desk_theme_check::split_lines(read_file(sys("/proc/stat"))))
        if (line.rfind("btime ", 0) == 0) boot = std::atoll(line.c_str() + 6);
    const long ticks = ::sysconf(_SC_CLK_TCK);
    if (boot <= 0 || ticks <= 0) return found;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(sys("/proc"), ec)) {
        const auto name = entry.path().filename().string();
        struct stat st{};
        if (name.find_first_not_of("0123456789") != std::string::npos || ::stat(entry.path().c_str(), &st) != 0
            || st.st_uid != ::getuid()) continue;
        const auto line = read_file(entry.path() / "stat");
        const auto close = line.rfind(')');
        if (close == std::string::npos) continue;
        std::istringstream rest(line.substr(close + 1));
        std::vector<std::string> fields;  // stat's fields from the 3rd: state, ppid, … starttime is the 22nd
        for (std::string field; rest >> field;) fields.push_back(field);
        if (fields.size() < 20) continue;
        Proc proc;
        proc.pid = std::atoll(name.c_str());
        proc.ppid = std::atoll(fields[1].c_str());
        proc.started = static_cast<std::time_t>(boot + std::atoll(fields[19].c_str()) / ticks);
        proc.comm = trim(read_file(entry.path() / "comm"));
        proc.args = read_file(entry.path() / "cmdline");
        std::replace(proc.args.begin(), proc.args.end(), '\0', ' ');
        found.push_back(std::move(proc));
    }
    return found;
}

std::vector<const Proc*> started_before(std::initializer_list<const char*> names, std::time_t when) {
    std::vector<const Proc*> out;
    for (const auto& proc : processes())
        for (const char* name : names)
            if (when > 0 && proc.comm == name && proc.started < when) out.push_back(&proc);
    return out;
}

std::string pids(const std::vector<const Proc*>& procs) {
    std::string out;
    for (const auto* proc : procs) out += (out.empty() ? "pid " : ", pid ") + std::to_string(proc->pid) + " since " + clock_at(proc->started);
    return out;
}

// D14. Before 2026-11-16 the café dispatcher, which NetworkManager runs as root, sourced ~/.config/foxml/cafe.conf and
// ran ~/.local/bin/desk-firewall: anything running as you could become root at the next Wi-Fi connection. Only `desk
// cafe --setup` (the fixed one, marked as MARK in shared/bin/desk-cafe) or `--disable` replaces it.
CheckResult check_cafe(const Env&) {
    const char* title = "café mode cannot hand out root";
    const std::string shown = "/etc/NetworkManager/dispatcher.d/99-foxml-cafe";
    const auto dispatcher = sys(shown);
    std::error_code ec;
    if (!fs::is_directory(dispatcher.parent_path(), ec))
        return result("D14", title, Severity::Critical, Status::Skip, "requires NetworkManager");
    if (!fs::exists(dispatcher, ec)) return result("D14", title, Severity::Critical, Status::Pass, "café mode is not set up");
    if (!std::ifstream(dispatcher))
        return result("D14", title, Severity::Critical, Status::Warn, "cannot read " + shown, "desk sec cafe says whether it is the old one");
    if (has(read_file(dispatcher), "# foxml-managed: cafe v2"))
        return result("D14", title, Severity::Critical, Status::Pass, "the fixed dispatcher (cafe v2)");
    return result("D14", "the old café dispatcher is installed: it can hand out root", Severity::Critical, Status::Fail,
                  shown + " runs as root at every Wi-Fi connection,\nand runs ~/.config/foxml/cafe.conf and "
                  "~/.local/bin/desk-firewall, two files you own:\nanything running as you can become root",
                  "desk sec cafe --disable   (or desk sec cafe --setup to keep café mode, now fixed)");
}

// D15. In the profile Firefox opens: the stylesheets as the theme renders them now (retro-amber's DOS pages among
// them), the prefs user.js holds to, and the theme's website appearance (FF_WEBSITE_APPEARANCE). Firefox reads all
// of them at its start only.
CheckResult check_firefox_theme(const Env& env) {
    const char* title = "Firefox has the theme's styles and website appearance";
    namespace ff = desk_install::firefox_appearance;
    if (!sh::have("firefox")) return result("D15", title, Severity::Low, Status::Skip, "Firefox is not installed");
    const auto profile = firefox_profile(env);
    if (profile.empty())
        return result("D15", title, Severity::Low, Status::Warn, "Firefox has no profile yet",
                      "./install.sh --only specials  (it makes the profile Firefox's first start opens)");
    std::vector<std::string> problems;
    std::string note;
    const auto renderer = env.repo / "src/desk-render/desk-render-fast";
    const auto palette = env.repo / "themes" / env.theme / "palette.sh";
    std::error_code ec;
    const bool themed = !env.repo.empty() && fs::exists(palette, ec);
    if (themed && fs::exists(renderer, ec)) {
        const auto rendered = fs::temp_directory_path() / ("fox-theme-check-firefox-" + std::to_string(::getpid()));
        struct Cleanup { fs::path dir; ~Cleanup() { std::error_code e; fs::remove_all(dir, e); } } cleanup{rendered};
        if (run_bounded(30, {renderer.string(), palette.string(), (env.repo / "templates/firefox").string(), rendered.string()}).code != 0)
            problems.push_back("the theme's Firefox files did not render");
        else for (const std::string name : {"userChrome.css", "userContent.css"}) {
            if (!fs::exists(profile / "chrome" / name, ec)) problems.push_back("chrome/" + name + " is missing");
            else if (read_file(profile / "chrome" / name) != read_file(rendered / name))
                problems.push_back("chrome/" + name + " is not " + env.theme + "'s");
        }
    } else note = themed ? " (stylesheets not compared: no renderer)" : " (stylesheets not compared: the theme repo was not found)";
    const auto prefs = read_file(profile / "user.js");
    for (const auto& [key, value] : ff::ENFORCED_PREFS)
        if (!has(prefs, std::string("user_pref(\"") + key + "\", " + value + ");")) problems.push_back(std::string("user.js does not set ") + key);
    if (themed) {
        const std::string pref = std::string("user_pref(\"") + ff::WEBSITE_APPEARANCE + "\", ";
        const auto at = prefs.rfind(pref);
        const auto set = at == std::string::npos ? std::string() : trim(prefs.substr(at + pref.size(), prefs.find(')', at) - at - pref.size()));
        const auto named = [](const std::string& v) { return v == "0" ? std::string("dark") : v == "1" ? "light" : v == "2" ? "auto" : v; };
        const auto look = palette_value(env, "FF_WEBSITE_APPEARANCE");
        const std::string want = look == "dark" ? "0" : look == "light" ? "1" : look == "auto" ? "2" : "";
        if (!want.empty() && set != want)
            problems.push_back("its website appearance is not " + look + (set.empty() ? " (user.js does not set it)" : " (user.js: " + named(set) + ")"));
        else if (want.empty() && (set == "0" || set == "1"))
            problems.push_back("user.js still sets the website appearance to " + named(set) + ", from another theme");
    }
    if (!problems.empty()) {
        problems.insert(problems.begin(), "in " + tilde(env, profile) + ":");
        return listed("D15", title, Severity::Low, problems, "./install.sh --only specials  (it restarts a running Firefox)");
    }
    const auto changed = std::max({mtime(profile / "chrome/userChrome.css"), mtime(profile / "chrome/userContent.css"), mtime(profile / "user.js")});
    if (const auto running = started_before({"firefox", "firefox-bin"}, changed); !running.empty())
        return result("D15", title, Severity::Low, Status::Warn,
                      "Firefox (" + pids(running) + ") started before its theme files changed (" + clock_at(changed) + ")",
                      "restart Firefox to load them");
    return result("D15", title, Severity::Low, Status::Pass, tilde(env, profile) + note);
}

// D16. A notebook's Shift+Enter inside tmux: kitty sends CSI u only while tmux is in front (the desk_tmux user var that
// tmux's smcup/rmcup override sets and clears), and zsh takes the code as Enter. A tmux client keeps the smcup it
// attached with, and an open kitty the map it read.
CheckResult check_shift_enter(const Env& env) {
    const char* title = "Shift+Enter reaches programs in tmux, and only there";
    const auto kitty = env.config / "kitty/kitty.conf", tmux = env.home / ".tmux.conf", zsh = env.home / ".zshrc";
    std::error_code ec;
    if (!fs::exists(kitty, ec) && !fs::exists(tmux, ec) && !fs::exists(zsh, ec))
        return result("D16", title, Severity::Low, Status::Skip, "kitty, tmux and zsh configs are not deployed");
    std::vector<std::string> problems;
    if (const auto text = read_file(kitty); fs::exists(kitty, ec) && !has(text, "map --when-focus-on var:desk_tmux=1 shift+enter send_text "))
        problems.push_back(has(text, "map shift+enter send_text ")
                               ? "kitty.conf sends Shift+Enter as CSI u everywhere: a Python REPL outside tmux reads it wrong"
                               : "kitty.conf has no Shift+Enter map for tmux");
    if (const auto text = read_file(tmux); fs::exists(tmux, ec) && !(has(text, "xterm-kitty:smcup=") && has(text, "SetUserVar=desk_tmux")))
        problems.push_back("~/.tmux.conf does not tell kitty when tmux is in front (its smcup/rmcup)");
    if (fs::exists(zsh, ec) && !has(read_file(zsh), "'^[[13;2u' accept-line"))
        problems.push_back("~/.zshrc does not take Shift+Enter's CSI u as Enter");
    if (!problems.empty()) return listed("D16", title, Severity::Low, problems, "re-render: ./install.sh --render-only " + env.theme);
    if (const auto clients = started_before({"tmux: client"}, mtime(tmux)); !clients.empty())
        return result("D16", title, Severity::Low, Status::Warn,
                      "tmux attached before ~/.tmux.conf changed (" + clock_at(mtime(tmux)) + "): " + pids(clients),
                      "tmux source-file ~/.tmux.conf, then detach and attach again; ctrl+shift+F5 reloads an open kitty");
    return result("D16", title, Severity::Low, Status::Pass);
}

// D17. The editor's pop-out (kitty, class desk-popout) never takes the keyboard as it opens: one window rule, in
// rules.lua (Hyprland 0.57 on) and its rules.conf twin (older Hyprland).
CheckResult check_popout_rule(const Env& env) {
    const char* title = "Hyprland keeps the editor's pop-out from taking the keyboard";
    std::vector<std::string> problems;
    int found = 0;
    for (const std::string name : {"rules.lua", "rules.conf"}) {
        std::error_code ec;
        const auto file = env.config / "hypr/modules" / name;
        if (!fs::exists(file, ec)) { problems.push_back("~/.config/hypr/modules/" + name + " is missing"); continue; }
        ++found;
        if (!has(read_file(file), "^(desk-popout)$")) problems.push_back(name + " has no desk-popout window rule");
    }
    if (!found) return result("D17", title, Severity::Low, Status::Skip, "Hyprland's rules are not deployed");
    if (!problems.empty()) return listed("D17", title, Severity::Low, problems, "./install.sh --only specials");
    return result("D17", title, Severity::Low, Status::Pass, "rules.lua and rules.conf");
}

// The commit a git clone has checked out: .git/HEAD, through its ref file or packed-refs.
std::string git_head(const fs::path& repo) {
    const auto git = repo / ".git";
    const auto head = trim(read_file(git / "HEAD"));
    if (head.rfind("ref: ", 0) != 0) return head;
    const auto ref = head.substr(5);
    if (auto sha = trim(read_file(git / ref)); !sha.empty()) return sha;
    for (const auto& line : desk_theme_check::split_lines(read_file(git / "packed-refs")))
        if (line.size() > 41 && line.compare(41, std::string::npos, ref) == 0) return line.substr(0, 40);
    return {};
}

// D18. The installer restores Neovim's plugins to the lock file it deploys (shared/nvim_lazy-lock.json): what was
// tested, such as nvim-scrollbar on its v1 commit (on main it warns at every start).
CheckResult check_plugin_lock(const Env& env) {
    const char* title = "Neovim's plugins are at the lock file's commits";
    const auto lock_file = env.config / "nvim/lazy-lock.json";
    const auto lazy = env.home / ".local/share/nvim/lazy";
    std::error_code ec;
    if (!sh::have("nvim")) return result("D18", title, Severity::Low, Status::Skip, "nvim is not installed");
    if (!fs::exists(lock_file, ec)) return result("D18", title, Severity::Low, Status::Skip, "no plugin lock deployed (~/.config/nvim/lazy-lock.json)");
    const auto lock = json::parse(read_file(lock_file), nullptr, false);
    if (!lock.is_object())
        return result("D18", title, Severity::Low, Status::Warn, "~/.config/nvim/lazy-lock.json does not parse", "./install.sh  (it deploys the repo's lock)");
    if (!fs::is_directory(lazy, ec)) return result("D18", title, Severity::Low, Status::Skip, "no plugins installed yet (Neovim installs them at its first start)");
    const auto pin = [](const json& entry) { return text_of(entry, "commit"); };
    std::vector<std::string> problems;
    std::string hint = "nvim --headless '+Lazy! restore' +qa  (what the installer runs), then restart Neovim";
    const auto shipped = env.repo.empty() ? json() : json::parse(read_file(env.repo / "shared/nvim_lazy-lock.json"), nullptr, false);
    if (shipped.is_object())
        for (const auto& [name, entry] : shipped.items())
            if (const auto deployed = pin(lock.value(name, json())); !pin(entry).empty() && deployed != pin(entry)) {
                problems.push_back((deployed.empty() ? "the deployed lock has no " + name : "the deployed lock pins " + name + " at " + deployed.substr(0, 7))
                                   + ", the repo's pins " + pin(entry).substr(0, 7));
                hint = "./install.sh  (it deploys the repo's lock, then restores the plugins to it)";
            }
    int same = 0;
    for (const auto& [name, entry] : lock.items()) {
        if (pin(entry).empty() || !fs::is_directory(lazy / name / ".git", ec)) continue;
        const auto head = git_head(lazy / name);
        if (head == pin(entry)) { ++same; continue; }
        const auto branch = text_of(entry, "branch");
        problems.push_back(name + " is at " + (head.empty() ? std::string("an unknown commit") : head.substr(0, 7)) + ", the lock pins "
                           + pin(entry).substr(0, 7) + (branch.empty() ? "" : " (" + branch + ")"));
    }
    if (problems.size() > 8) {
        const auto more = problems.size() - 8;
        problems.resize(8);
        problems.push_back("and " + std::to_string(more) + " more");
    }
    if (!problems.empty()) return listed("D18", title, Severity::Low, problems, hint);
    std::string detail = std::to_string(same) + " plugins at their pinned commits";
    if (const auto scrollbar = lock.value("nvim-scrollbar", json()); !pin(scrollbar).empty() && fs::is_directory(lazy / "nvim-scrollbar", ec))
        detail += "; nvim-scrollbar at " + pin(scrollbar).substr(0, 7) + " (" + text_of(scrollbar, "branch") + ")";
    return result("D18", title, Severity::Low, Status::Pass, detail);
}

// D19. A notebook opens as Markdown through jupytext (pipx puts it in ~/.local/bin) and runs its cells in ipykernel
// (pacman's python-ipykernel). After Arch moves to a new Python, pipx's jupytext names a Python that is gone.
CheckResult check_notebooks(const Env& env) {
    const char* title = "notebooks have jupytext and ipykernel";
    if (!sh::have("nvim")) return result("D19", title, Severity::Low, Status::Skip, "nvim is not installed");
    if (std::error_code missing; !fs::exists(env.config / "nvim/init.lua", missing))
        return result("D19", title, Severity::Low, Status::Skip, "the theme's Neovim config is not deployed");
    std::vector<std::string> problems, hints;
    auto jupytext = which("jupytext");
    if (const auto mine = env.home / ".local/bin/jupytext"; jupytext.empty() && ::access(mine.c_str(), X_OK) == 0) jupytext = mine.string();
    std::error_code ec;
    if (jupytext.empty()) {
        problems.push_back("jupytext is missing: an .ipynb opens as JSON");
        hints.push_back("pipx install jupytext");
    } else {
        std::ifstream script(jupytext);
        std::string first;
        std::getline(script, first);
        const auto interpreter = first.rfind("#!/", 0) == 0 ? first.substr(2, first.find(' ') == std::string::npos ? std::string::npos : first.find(' ') - 2) : "";
        if (!interpreter.empty() && !fs::exists(interpreter, ec)) {
            problems.push_back("jupytext's Python (" + interpreter + ") is gone");
            hints.push_back("pipx reinstall-all");
        }
    }
    // The site-packages of the Python python3 runs (its own folder name: python3.14), the system's or yours.
    std::vector<std::string> pythons;
    if (const auto link = fs::read_symlink(sys("/usr/bin/python3"), ec); !ec) pythons.push_back(link.filename().string());
    else for (const auto& entry : fs::directory_iterator(sys("/usr/lib"), ec))
        if (entry.path().filename().string().rfind("python3.", 0) == 0) pythons.push_back(entry.path().filename().string());
    bool kernel = false;
    for (const auto& python : pythons)
        for (const auto& lib : {sys("/usr/lib"), env.home / ".local/lib"})
            kernel = kernel || fs::exists(lib / python / "site-packages/ipykernel/__init__.py", ec);
    if (!kernel) {
        problems.push_back("ipykernel is missing: a cell has no Python kernel to run in");
        hints.push_back("sudo pacman -S python-ipykernel");
    }
    if (problems.empty()) return result("D19", title, Severity::Low, Status::Pass, jupytext);
    std::string hint;
    for (const auto& one : hints) hint += (hint.empty() ? "" : "; ") + one;
    return listed("D19", title, Severity::Low, problems, hint);
}

// D20. The notebook's g sends a call graph to the editor through `desk-work editor`, and declared tools are `desk-work
// tools`; a desk-work from before those has neither. Its help says which commands it has.
CheckResult check_work_commands(const Env&) {
    const char* title = "desk-work has editor and tools (the notebook's g needs them)";
    const auto tool = which("desk-work");
    if (tool.empty()) return result("D20", title, Severity::Low, Status::Skip, "desk-work is not installed");
    const auto help = run_bounded(5, {tool, "help"}).out;
    std::string missing;
    for (const std::string command : {"editor", "tools"})
        if (!has(help, "desk-work " + command + " ")) missing += (missing.empty() ? "desk-work " : " and desk-work ") + command;
    if (missing.empty()) return result("D20", title, Severity::Low, Status::Pass, tool);
    return result("D20", title, Severity::Low, Status::Warn, tool + " is older: it has no " + missing,
                  "./install.sh --only integrations  (it installs desk-work)");
}

// D21. The retro bar's words (LLM 35B IDLE, SEC 1 WARN, …) come from one table in BarLogic.js (retroModules).
// Quickshell reloads a changed file by itself.
CheckResult check_retro_bar(const Env& env) {
    const char* title = "the bar's retro module table is deployed";
    const auto logic = env.config / "quickshell/desk/BarLogic.js";
    std::error_code ec;
    if (!fs::is_directory(logic.parent_path(), ec)) return result("D21", title, Severity::Low, Status::Skip, "the desk bar is not installed");
    const auto text = read_file(logic);
    std::string problem;
    if (!fs::exists(logic, ec)) problem = "~/.config/quickshell/desk/BarLogic.js is missing";
    else if (!has(text, "var retroModules")) problem = "BarLogic.js is from before the retro bar: it has no retroModules table";
    else if (const auto shipped = env.repo / "shared/quickshell/desk/BarLogic.js"; !env.repo.empty() && fs::exists(shipped, ec) && read_file(shipped) != text)
        problem = "BarLogic.js is not the repo's";
    if (problem.empty()) return result("D21", title, Severity::Low, Status::Pass);
    return result("D21", title, Severity::Low, Status::Warn, problem, "./install.sh --only drawer");
}

// Asks systemd about a user unit; nothing is started or changed.
std::string user_unit(const std::string& unit, const char* what) {
    return trim(run_bounded(5, {"systemctl", "--user", what, unit}).out);
}

bool reload_pending(const std::string& unit) {
    return trim(run_bounded(5, {"systemctl", "--user", "show", "-p", "NeedDaemonReload", "--value", unit}).out) == "yes";
}

// D22. fox-etcwatch alerts on /etc changes. Until 2026-11-16 a burst of /etc writes (an install) passed its service's
// start limit, and systemd then switched the watcher off until reset. The units today are etcwatch_units.hpp's.
CheckResult check_etcwatch(const Env& env) {
    const char* title = "the /etc watcher (fox-etcwatch) is current and watching";
    const auto units = env.config / "systemd/user";
    std::error_code ec;
    if (!fs::exists(units / "fox-etcwatch.path", ec) && !fs::exists(units / "fox-etcwatch.service", ec))
        return result("D22", title, Severity::Medium, Status::Skip, "not installed (the installer's etckeeper step)");
    if (!desk_install::etcwatch_units_current(units))
        return result("D22", title, Severity::Medium, Status::Warn,
                      "its units are older: a burst of /etc writes switches the watcher off (start limit)", "./install.sh --only etckeeper");
    if (!sh::have("systemctl")) return result("D22", title, Severity::Medium, Status::Pass, "its units are current; no systemctl to ask whether it runs");
    if (reload_pending("fox-etcwatch.service") || reload_pending("fox-etcwatch.path"))
        return result("D22", title, Severity::Medium, Status::Warn, "systemd still runs its older units", "systemctl --user daemon-reload");
    if (const auto state = user_unit("fox-etcwatch.path", "is-active"); state != "active")
        return result("D22", title, Severity::Medium, Status::Warn, "fox-etcwatch.path is " + (state.empty() ? std::string("not known to systemd") : state),
                      "systemctl --user reset-failed fox-etcwatch.path; systemctl --user enable --now fox-etcwatch.path");
    return result("D22", title, Severity::Medium, Status::Pass, "watching");
}

// D23. foxml-arch-audit.service ran `arch-audit -uf` until 2026-11-15: arch-audit 0.2 takes -f as a format, so it
// stopped at a usage error and no notice ever came. The units today are arch_audit_units.hpp's.
CheckResult check_arch_audit(const Env& env) {
    const char* title = "the daily arch-audit check runs flags arch-audit takes";
    const auto units = env.config / "systemd/user";
    const auto service = units / "foxml-arch-audit.service";
    std::error_code ec;
    if (!fs::exists(service, ec) && !fs::exists(units / "foxml-arch-audit.timer", ec))
        return result("D23", title, Severity::Low, Status::Skip,
                      sh::have("arch-audit") ? "not set up (./install.sh --only arch_audit)" : "arch-audit is not installed");
    if (!desk_install::arch_audit_units_current(units))
        return result("D23", title, Severity::Low, Status::Warn,
                      has(read_file(service), "arch-audit -uf") ? "it runs arch-audit -uf, which arch-audit refuses: no notice ever comes"
                                                                 : "its units are not the installer's",
                      "./install.sh --only arch_audit");
    if (sh::have("systemctl") && reload_pending("foxml-arch-audit.service"))
        return result("D23", title, Severity::Low, Status::Warn, "systemd still runs the older service", "systemctl --user daemon-reload");
    return result("D23", title, Severity::Low, Status::Pass);
}

// D24. Declared tools in desk.d, read by desk-work's own parser (`desk-work tools list`, which runs nothing a
// declaration names). A file it cannot read names no checkout, so it is listed in every one.
CheckResult check_declarations(const Env& env) {
    const char* title = "the tools declared in ~/.config/foxml/desk.d are valid";
    const auto dir = env.config / "foxml/desk.d";
    std::vector<fs::path> files;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(dir, ec)) {
        const auto name = entry.path().filename().string();
        if (name.size() > 5 && name[0] != '.' && entry.path().extension() == ".json") files.push_back(entry.path());
    }
    if (files.empty()) return result("D24", title, Severity::Low, Status::Skip, "nothing declared there");
    const auto tool = which("desk-work");
    if (tool.empty()) return result("D24", title, Severity::Low, Status::Skip, "requires desk-work");
    std::set<std::string> roots{env.home.string()}, problems, tools;
    for (const auto& file : files)
        if (const auto root = text_of(json::parse(read_file(file), nullptr, false), "root"); root.rfind('/', 0) == 0) roots.insert(root);
    bool answered = false;
    for (const auto& root : roots) {
        const auto list = json::parse(run_bounded(10, {tool, "tools", "list", "--root", root}).out, nullptr, false);
        if (!list.is_object() || !list.value("files", json()).is_array() || !list.value("tools", json()).is_array()) continue;
        answered = true;
        const auto mine = [&](const json& row) { return row.is_object() && fs::path(text_of(row, "file")).parent_path() == dir; };
        const auto name = [](const json& row) { return fs::path(text_of(row, "file")).filename().string(); };
        for (const auto& file : list["files"])
            if (mine(file) && file.value("ok", json()) != true) problems.insert(name(file) + ": " + text_of(file, "message"));
        for (const auto& one : list["tools"]) {
            if (!mine(one)) continue;
            if (one.contains("refused")) problems.insert(name(one) + ": tool " + text_of(one, "id") + ": " + text_of(one, "refused"));
            else tools.insert(name(one) + ":" + text_of(one, "id"));
        }
    }
    if (!answered) return result("D24", title, Severity::Low, Status::Skip, "requires a desk-work with desk-work tools (D20)");
    if (!problems.empty())
        return listed("D24", title, Severity::Low, std::vector<std::string>(problems.begin(), problems.end()),
                      "fix the file named; desk-work tools list --root <its root> shows what desk-work reads (docs/desk-tools.md)");
    return result("D24", title, Severity::Low, Status::Pass,
                  std::to_string(files.size()) + (files.size() == 1 ? " file, " : " files, ") + std::to_string(tools.size())
                  + (tools.size() == 1 ? " tool" : " tools"));
}

// D25. A program keeps the version it loaded. desk-work records the build each Neovim, Claude Code notebook and
// Quickshell loaded and the one installed, and names the sessions that run older code with how to reload each.
// A Neovim or Claude Code it has no record of (started before it kept them, or without desk-work) counts as older
// when it started before its build stamp, which every install writes. Quickshell reloads changed files itself, so
// only desk-work's record says it runs older code. A service of hers (its unit in ~/.config/systemd/user) still running
// a program replaced since it started is named too (modules/stale_services.hpp; the installer restarts the watchers).
// A Neovim from before the install runs the old noice setup, whose :restart can stop at a "Press any key" it does not
// show: quitting it and starting it again is the reload that always works.
struct Session { const char* client; const char* comm; const char* name; const char* stamp; const char* restart; };
const Session SESSIONS[] = {
    {"nvim", "nvim", "Neovim", "~/.config/nvim/lua/desk/build.lua", "quit it and start it again"},
    {"notebook", "claude", "Claude Code", "~/.claude/mods/desk-notebook/hooks/build.ts", "/exit, then claude --continue"},
    {"desktop", "quickshell", "Quickshell", "", ""},
};

CheckResult check_sessions(const Env& env) {
    const char* title = "running sessions and services have the installed version loaded";
    std::vector<std::string> stale;
    std::set<long long> recorded;
    const auto& health = work_health();
    const bool answered = health.is_object() && health.value("sessions", json()).is_array();
    // One line a session: desk-work can know one by its client record and its agent records; the one naming the
    // conversation (claude --resume <id>) says the most.
    std::map<std::pair<std::string, long long>, json> older;
    if (answered)
        for (const auto& row : health["sessions"]) {
            const auto pid = row.is_object() && row.value("pid", json()).is_number_integer() ? row["pid"].get<long long>() : 0;
            const auto status = text_of(row, "status");
            if (status == "current" || status == "reload-pending") recorded.insert(pid);  // "unverified": no word
            if (status != "reload-pending") continue;
            auto& kept = older[{text_of(row, "client"), pid}];
            if (kept.is_null() || (text_of(kept, "session").empty() && !text_of(row, "session").empty())) {
                const auto root = kept.is_null() ? std::string() : text_of(kept, "root");
                kept = row;
                if (text_of(kept, "root").empty() && !root.empty()) kept["root"] = root;
            }
        }
    for (const auto& [key, row] : older) {
        std::string name = key.first;
        for (const auto& session : SESSIONS) if (name == session.client) name = session.name;
        std::string where = key.second > 0 ? "pid " + std::to_string(key.second) : "";
        if (const auto root = text_of(row, "root"); !root.empty()) where += (where.empty() ? "" : ", ") + fs::path(root).filename().string();
        const auto reload = text_of(row, "reload");
        stale.push_back((name.empty() ? std::string("a session") : name) + (where.empty() ? "" : " (" + where + ")")
                        + " runs older code: " + (reload.empty() ? std::string("restart it to load the installed version") : reload));
    }
    std::map<long long, std::vector<long long>> children;
    for (const auto& proc : processes()) children[proc.ppid].push_back(proc.pid);
    bool stamped = false;
    for (const auto& session : SESSIONS) {
        const auto stamp = *session.stamp ? mtime(desk_install::workflow::destination(env.home, env.config, session.stamp)) : 0;
        stamped = stamped || stamp > 0;
        std::vector<const Proc*> before;
        for (const auto* proc : started_before({session.comm}, stamp)) {
            if (has(proc->args, "--embed") || has(proc->args, "--headless")) continue;  // a UI's server, or a probe
            bool known = recorded.count(proc->pid) > 0;
            for (const auto child : children[proc->pid]) known = known || recorded.count(child) > 0;
            if (!known) before.push_back(proc);
        }
        if (!before.empty())
            stale.push_back(std::string(session.name) + " (" + pids(before) + ") started before the last install ("
                            + clock_at(stamp) + "): " + session.restart);
    }
    for (const auto& svc : desk_install::stale::replaced_code(env.home, env.config / "systemd/user", ::getuid(), sys("/proc"))) {
        std::string ids, files;
        for (const auto pid : svc.pids) ids += (ids.empty() ? "pid " : ", pid ") + std::to_string(pid);
        for (const auto& file : svc.files) files += (files.empty() ? "" : ", ") + tilde(env, file);
        stale.push_back(svc.unit + " (" + ids + ") runs " + files + " from before it was replaced: systemctl --user restart "
                        + svc.unit + (svc.unit == "fox-vault.service" ? " (the vault then starts empty)" : ""));
    }
    if (!stale.empty()) return listed("D25", title, Severity::Low, stale, "restart each one named to load the new version");
    if (!answered && !stamped) return result("D25", title, Severity::Low, Status::Skip, "requires desk-work (it records what each session loaded)");
    return result("D25", title, Severity::Low, Status::Pass, "none runs code from before the install");
}

// When a check can run: Weekly — from the weekly timer too, with no live session (its environment can be stale there)
// and nothing heavy; Live — only when she runs it, because it asks the running Hyprland or Quickshell, or (D7) starts
// a whole Neovim. The field sits before the function, so every new check must say which (--scheduled reads it).
enum class When { Weekly, Live };
struct Entry { const char* id; When when; CheckResult (*fn)(const Env&); };
// D14 first: an old café dispatcher is a way to root.
const Entry CHECKS[] = {
    {"D14", When::Weekly, check_cafe},
    {"D1", When::Weekly, check_drift}, {"D2", When::Live, check_hyprland}, {"D3", When::Live, check_quickshell},
    {"D4", When::Live, check_drawer}, {"D5", When::Live, check_bar}, {"D6", When::Weekly, check_configs},
    {"D7", When::Live, check_nvim}, {"D8", When::Weekly, check_claude}, {"D9", When::Weekly, check_services},
    {"D10", When::Weekly, check_gtk}, {"D11", When::Weekly, check_firefox}, {"D12", When::Weekly, check_cursor},
    {"D13", When::Live, check_lock_panel}, {"D15", When::Weekly, check_firefox_theme},
    {"D16", When::Weekly, check_shift_enter}, {"D17", When::Weekly, check_popout_rule},
    {"D18", When::Weekly, check_plugin_lock}, {"D19", When::Weekly, check_notebooks},
    {"D20", When::Weekly, check_work_commands}, {"D21", When::Weekly, check_retro_bar},
    {"D22", When::Weekly, check_etcwatch}, {"D23", When::Weekly, check_arch_audit},
    {"D24", When::Weekly, check_declarations}, {"D25", When::Weekly, check_sessions},
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
    bool quiet = false, verbose = false, scheduled = false, list = false, only_given = false;
    std::vector<std::string> only;
    std::string theme;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--theme" && i + 1 < argc) theme = argv[++i];
        else if (arg == "--quiet" || arg == "-q") quiet = true;
        else if (arg == "--verbose" || arg == "-v") verbose = true;
        else if (arg == "--only" && i + 1 < argc) { only = split_csv(argv[++i]); only_given = true; }
        else if (arg == "--scheduled") scheduled = true;
        else if (arg == "--list") list = true;
        else if (arg == "-h" || arg == "--help") {
            std::printf("usage: desk theme check [--verbose] [--quiet] [--only D1,D4] [--scheduled] [--list] [--theme NAME]\n\n"
                        "Checks that the desktop the theme set up is deployed and working. Read-only.\n"
                        "--theme compares against another theme than the active one (after a swap, say).\n"
                        "--scheduled runs only the checks the weekly timer runs (no live session, nothing heavy);\n"
                        "--list prints the ids that would run, and runs nothing.\n"
                        "  D1 deployed files match the theme   D2 Hyprland config   D3 Quickshell\n"
                        "  D4 drawer pages   D5 bar modules   D6 tmux / lock screen   D7 Neovim\n"
                        "  D8 Claude status line and mod   D9 services   D10 GTK light/dark   D11 Firefox find colours\n"
                        "  D12 cursor   D13 lock screen panel on a visible screen   D14 the café dispatcher (root)\n"
                        "  D15 Firefox styles and website appearance   D16 Shift+Enter in tmux   D17 the pop-out's window rule\n"
                        "  D18 Neovim plugins at the lock   D19 notebooks (jupytext, ipykernel)   D20 desk-work editor and tools\n"
                        "  D21 the retro bar's table   D22 /etc watcher   D23 arch-audit timer   D24 declared tools (desk.d)\n"
                        "  D25 running sessions and services on an older version\n\n"
                        "exit codes: 0 ok  1 warnings  2 critical  3 high\n");
            return 0;
        } else { std::fprintf(stderr, "desk theme check: unknown option %s (see --help)\n", arg.c_str()); return 64; }
    }
    // A run that checks nothing must not look like a clean one: an unknown id, an empty --only, or filters that leave
    // nothing are refused instead of exiting 0.
    for (const auto& id : only)
        if (std::none_of(std::begin(CHECKS), std::end(CHECKS), [&](const Entry& c) { return id == c.id; })) {
            std::fprintf(stderr, "desk theme check: no check is called %s (see --help)\n", id.c_str());
            return 64;
        }
    if (only_given && only.empty()) { std::fprintf(stderr, "desk theme check: --only names no check\n"); return 64; }
    const auto selected = [&](const Entry& c) {
        return (only.empty() || std::any_of(only.begin(), only.end(), [&](const std::string& id) { return id == c.id; }))
            && (!scheduled || c.when == When::Weekly);
    };
    if (std::none_of(std::begin(CHECKS), std::end(CHECKS), selected)) {
        std::fprintf(stderr, "desk theme check: nothing to check — those options select no check\n");
        return 64;
    }

    Env env;
    env.home = env_or("HOME", "/");
    env.config = env_or("XDG_CONFIG_HOME", (env.home / ".config").string());
    env.runtime = env_or("XDG_RUNTIME_DIR", "/run/user/" + std::to_string(::getuid()));
    env.repo = find_repo(env.home);
    env.theme = !theme.empty() ? theme : env.repo.empty() ? "" : trim(read_file(env.repo / ".active-theme"));
    if (env.theme.empty()) env.theme = "Classic";
    if (env.theme.find('/') != std::string::npos || env.theme.rfind('.', 0) == 0) {
        std::fprintf(stderr, "desk theme check: not a theme name: %s\n", env.theme.c_str());
        return 64;
    }

    std::vector<CheckResult> results;
    for (const auto& check : CHECKS) {
        if (!selected(check)) continue;
        if (list) { std::printf("%s\n", check.id); continue; }
        if (std::string(check.id) == "D1" && env.repo.empty()) {
            results.push_back(result("D1", "deployed files match the theme", Severity::Medium, Status::Skip,
                                     "the theme repo was not found", "set FOXML_REPO to it"));
            continue;
        }
        try {
            results.push_back(check.fn(env));
        } catch (const std::exception& error) {
            results.push_back(result(check.id, "the check could not run", Severity::Low, Status::Warn, error.what()));
        }
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
    if (list) return 0;
    if (!quiet) std::printf("\ntheme %s · repo %s\n", env.theme.c_str(), env.repo.empty() ? "not found" : env.repo.c_str());
    return desk_health::worst_exit(results);
}
