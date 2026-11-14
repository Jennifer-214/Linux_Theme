#include "json.hpp"
#include "shell.hpp"
#include "../desk-monitor/placement.hpp"

#include <algorithm>
#include <cctype>
#include <array>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <future>
#include <fstream>
#include <iostream>
#include <iomanip>
#include <ctime>
#include <map>
#include <optional>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/inotify.h>
#include <poll.h>
#include <openssl/sha.h>
#include <sys/file.h>
#include <sys/statvfs.h>
#include <unistd.h>

namespace fs = std::filesystem;
namespace sh = desk_install::sh;
using Json = nlohmann::json;
using Args = std::vector<std::string>;

namespace {
std::string env(const char* key, const std::string& fallback = {}) {
    const char* value = std::getenv(key);
    return value && *value ? value : fallback;
}
std::string trim(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    return value.substr(first, value.find_last_not_of(" \t\r\n") - first + 1);
}
std::string lower(std::string value) {
    for (char& c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return value;
}
std::string text(const Json& object, const char* key, const std::string& fallback = {}) {
    const auto at = object.find(key);
    return at != object.end() && at->is_string() ? at->get<std::string>() : fallback;
}
bool truth(const Json& object, const char* key, bool fallback = false) {
    const auto at = object.find(key);
    return at != object.end() && at->is_boolean() ? at->get<bool>() : fallback;
}
bool safe_text(const std::string& value, size_t max = 4096) {
    return value.size() <= max && value.find('\0') == std::string::npos;
}
bool identifier(const std::string& value) {
    if (value.empty() || value.size() > 64 || value.front() < 'a' || value.front() > 'z') return false;
    for (char c : value) if (!(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '-') return false;
    return true;
}
std::vector<std::string> lines(const std::string& input) {
    std::istringstream in(input);
    std::vector<std::string> out;
    std::string line;
    while (std::getline(in, line)) out.push_back(line);
    return out;
}
std::string read(const fs::path& file) {
    std::ifstream in(file, std::ios::binary);
    return in ? std::string(std::istreambuf_iterator<char>(in), {}) : std::string{};
}
bool regular(const fs::path& path) { std::error_code ec; return fs::is_regular_file(path, ec); }
bool directory(const fs::path& path) { std::error_code ec; return fs::is_directory(path, ec); }
std::string home() { return env("HOME"); }
fs::path config_home() { return env("XDG_CONFIG_HOME", home() + "/.config"); }
fs::path data_home() { return env("XDG_DATA_HOME", home() + "/.local/share"); }
fs::path runtime() { return env("XDG_RUNTIME_DIR", "/tmp"); }
fs::path script(const std::string& name) { return config_home() / "hypr/scripts" / name; }
fs::path repository() {
    for (const auto& line : lines(read(data_home() / "foxml/.installed-version"))) {
        if (line.rfind("script_dir=", 0) != 0) continue;
        std::string value = trim(line.substr(11));
        if (value.size() > 1 && (value.front() == '\"' || value.front() == '\'' ) && value.back() == value.front())
            value = value.substr(1, value.size() - 2);
        if (fs::path(value).is_absolute() && directory(fs::path(value) / "themes")) return value;
    }
    const fs::path candidate = env("FOXML_REPO", home() + "/code/Linux_Theme");
    return candidate;
}
const std::set<std::string> pages = {
    "apps", "windows", "audio-outputs", "wifi", "bluetooth", "tools", "tools-ai", "tools-security", "tools-desktop", "tools-system", "tools-projects", "tools-other", "tools-all", "cheatsheet", "cheatsheet-keys", "sandbox", "clipboard-text", "clipboard-images",
    "wallpapers", "themes", "power", "updates", "agents", "projects", "bookmarks", "library", "downloads", "screenshots", "passwords", "garden",
    "models", "storage", "backups", "startup", "displays", "display", "display-modes", "calendar-feeds", "programs", "terminals", "terminals-arrange", "terminal", "terminal-pane", "jobs", "test-results", "reviews", "attention", "work-history", "work-digest", "work-health", "attention-snoozed", "worktrees", "next-steps", "failures", "api-credits", "api-tasks", "earlier-notes"
};
const std::set<std::string> actions = {
    "volume", "volume-mute", "mic-mute", "media-play-pause", "media-next", "media-previous", "brightness",
    "nightlight", "dnd", "idle", "power-profile", "lock", "suspend", "reboot", "poweroff", "logout",
    "wallpaper-next", "wallpaper-sync", "color-picker", "updates-terminal", "updates-silent", "vault",
    "security", "cleanup", "agent-triage", "agent-jump", "agent-clear", "claude-jump", "app-launch", "window-focus", "audio-output", "wifi-connect",
    "wifi-toggle", "bluetooth-connect", "bluetooth-toggle", "bluetooth-scan", "bluetooth-service", "tool-run", "cheatsheet-copy", "sandbox-launch", "clipboard-restore", "wallpaper-set", "theme-set", "project-open", "project-terminal", "project-bookmark", "drive-open", "drive-eject", "download-open", "download-folder", "screenshot-open", "screenshot-copy", "screenshot-folder", "screenshot-capture", "password-copy", "tools", "cheatsheet", "sandbox",
    "goodnight-open", "api-task-ask", "api-task-open", "api-task-failure", "api-task-settings", "api-task-review", "api-task-pi", "api-task-follow", "calendar-feed-add", "calendar-feed-remove", "calendar-refresh", "display-scale", "display-rotate", "display-side", "display-mode", "display-keep", "display-undo", "display-edit", "cursor-size", "credits-setup", "credits-console", "model-agent", "model-remove", "storage-scan", "storage-open", "storage-clean-packages", "storage-trim-journal", "storage-flatpak-unused",
    "storage-empty-trash", "storage-hidden", "backup-restore", "backup-open", "backup-prune", "startup-user", "startup-autostart", "program-quit", "program-force", "terminal-go", "terminal-new", "terminal-here", "terminal-rename", "terminal-pane-move", "terminal-pane-split", "terminal-close",
    "work-open", "work-jump", "work-tests", "work-compare", "work-ask", "work-reviews", "work-tasks", "work-task-toggle", "work-task-draft", "worktree-open", "worktree-terminal", "project-worktrees", "service-log", "service-ask",
    "note-open", "note-clear", "calendar", "work-attention", "work-event", "work-unsnooze", "work-caught-up", "work-health-controls", "work-backups", "work-set-aside", "work-bring-back"
};
// The drawer loads one page at a time, so a page read that waits on a dead service holds every other page behind it.
int read_limit_seconds = 0;
bool capture(const Args& args, std::string& out) {
    if (read_limit_seconds <= 0 || !sh::have("timeout")) return sh::capture(args, out);
    Args limited{"timeout", "-k", "1", std::to_string(read_limit_seconds)};
    limited.insert(limited.end(), args.begin(), args.end());
    return sh::capture(limited, out);
}
Json item(const std::string& id, const std::string& label, const std::string& kind = "action",
          const std::string& detail = {}, const std::string& icon = {}) {
    // A label opening with two spaces belongs to the row above it; the front end indents the card instead.
    const auto start = label.rfind("  ", 0) == 0 ? label.find_first_not_of(' ') : 0;
    Json row{{"id", id}, {"label", start == std::string::npos ? std::string() : label.substr(start)}, {"kind", kind},
             {"detail", detail}, {"icon", icon}, {"enabled", true}};
    if (start != 0) row["nested"] = true;
    return row;
}

// A small heading over the rows that follow it; never selectable, so the keys and the mouse pass over it.
Json heading(const std::string& label) {
    std::string slug;
    for (const char c : label) slug += std::isalnum(static_cast<unsigned char>(c)) ? static_cast<char>(std::tolower(static_cast<unsigned char>(c))) : '-';
    auto row = item("section-" + slug, label, "heading");
    row["enabled"] = false;
    return row;
}

// A tab's rows under their headings: sections in the order they first appear, her own rows (no section) last under
// "more". A tab without sections, or one being searched, reads as the plain list it always was.
Json sectioned(const Json& rows) {
    std::vector<std::string> order;
    bool any = false;
    for (const auto& row : rows) {
        const auto name = row.contains("section") && row["section"].is_string() ? row["section"].get<std::string>() : std::string();
        any = any || !name.empty();
        if (!name.empty() && std::find(order.begin(), order.end(), name) == order.end()) order.push_back(name);
    }
    if (!any) return rows;
    order.push_back("");
    Json out = Json::array();
    for (const auto& name : order) {
        bool headed = false;
        for (const auto& row : rows) {
            const auto mine = row.contains("section") && row["section"].is_string() ? row["section"].get<std::string>() : std::string();
            if (mine != name) continue;
            if (!headed) { out.push_back(heading(name.empty() ? "more" : name)); headed = true; }
            out.push_back(row);
        }
    }
    return out;
}
// A dollar amount as people read it: cents, and "<$0.01" for the fractions of a cent small runs cost.
std::string money_text(const std::string& usd) {
    char* end = nullptr;
    const double value = std::strtod(usd.c_str(), &end);
    if (usd.empty() || end == usd.c_str() || *end != '\0' || !std::isfinite(value) || value < 0) return "cost unknown";
    if (value > 0 && value < 0.005) return "<$0.01";
    char out[32] = {}; std::snprintf(out, sizeof out, "$%.2f", value); return out;
}
// Seconds since the epoch for an ISO-8601 time with optional fractions and a Z or ±hh:mm zone; 0 when it doesn't read.
long long iso_seconds(const std::string& iso) {
    std::tm when{}; int used = 0;
    if (std::sscanf(iso.c_str(), "%4d-%2d-%2dT%2d:%2d:%2d%n", &when.tm_year, &when.tm_mon, &when.tm_mday,
                    &when.tm_hour, &when.tm_min, &when.tm_sec, &used) != 6) return 0;
    auto rest = iso.substr(static_cast<size_t>(used));
    if (!rest.empty() && rest[0] == '.') rest.erase(0, std::min(rest.find_first_not_of("0123456789", 1), rest.size()));
    long long offset = 0; int oh = 0, om = 0;
    if (rest.size() == 6 && (rest[0] == '+' || rest[0] == '-') && std::sscanf(rest.c_str() + 1, "%2d:%2d", &oh, &om) == 2)
        offset = (oh * 3600LL + om * 60LL) * (rest[0] == '-' ? -1 : 1);
    else if (rest != "Z" && !rest.empty()) return 0;
    when.tm_year -= 1900; when.tm_mon -= 1;
    return static_cast<long long>(::timegm(&when)) - offset;
}
// "today 11:46 pm", "yesterday 9:05 am", "mon 2:10 pm" within the week, then "nov 2".
std::string when_text(long long epoch, std::time_t now = std::time(nullptr)) {
    if (epoch <= 0) return "";
    const std::time_t at = static_cast<std::time_t>(epoch);
    std::tm then{}, today{};
    if (!::localtime_r(&at, &then) || !::localtime_r(&now, &today)) return "";
    std::tm midnight = today; midnight.tm_hour = midnight.tm_min = midnight.tm_sec = 0; midnight.tm_isdst = -1;
    const auto start = std::mktime(&midnight);
    char clock[16] = {}, day[16] = {};
    std::strftime(clock, sizeof clock, "%I:%M %p", &then);
    auto time = lower(clock);
    if (time.front() == '0') time.erase(0, 1);
    if (at >= start) return "today " + time;
    if (at >= start - 24 * 3600) return "yesterday " + time;
    if (at >= start - 6 * 24 * 3600) { std::strftime(day, sizeof day, "%a", &then); return lower(day) + " " + time; }
    std::strftime(day, sizeof day, "%b %e", &then);
    std::string out = lower(day);
    out.erase(std::unique(out.begin(), out.end(), [](char a, char b) { return a == ' ' && b == ' '; }), out.end());
    return out;
}
Json result(bool ok, const std::string& message, bool close = false) {
    return Json{{"ok", ok}, {"message", message}, {"close", close}};
}
Json command(const Args& args, const std::string& message, bool close = false, const std::string& failure = {}) {
    std::string output;
    if (!sh::have(args.front())) return result(false, args.front() + " is not installed");
    if (!capture(args, output)) return result(false, failure.empty() ? "Could not " + lower(message) : failure);
    return result(true, message, close);
}
Json launch(const Args& args, const std::string& message) {
    if (args.empty() || !sh::have(args.front())) return result(false, "Required application is not installed");
    if (!sh::have("setsid")) return result(false, "setsid is not installed");
    Args detached{"setsid", "-f"};
    detached.insert(detached.end(), args.begin(), args.end());
    // Detached GUIs must not inherit the JSON pipe: its reader would otherwise wait until the GUI exits.
    const int saved_out = ::fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3);
    const int saved_err = ::fcntl(STDERR_FILENO, F_DUPFD_CLOEXEC, 3);
    const int null_fd = ::open("/dev/null", O_WRONLY | O_CLOEXEC);
    if (saved_out < 0 || saved_err < 0 || null_fd < 0) {
        if (saved_out >= 0) ::close(saved_out);
        if (saved_err >= 0) ::close(saved_err);
        if (null_fd >= 0) ::close(null_fd);
        return result(false, "Could not detach application");
    }
    ::dup2(null_fd, STDOUT_FILENO); ::dup2(null_fd, STDERR_FILENO); ::close(null_fd);
    const int status = sh::run(detached);
    ::dup2(saved_out, STDOUT_FILENO); ::dup2(saved_err, STDERR_FILENO);
    ::close(saved_out); ::close(saved_err);
    return result(status == 0, status == 0 ? message : "Could not start application", status == 0);
}
Json terminal(const Args& args, const std::string& message) {
    Args full{"kitty", "-e"}; full.insert(full.end(), args.begin(), args.end());
    if (args.empty() || !sh::have(args.front())) return result(false, "Required command is not installed");
    return launch(full, message);
}
Json background(const Args& args, const std::string& message) {
    auto response = launch(args, message);
    response["close"] = false;
    return response;
}
bool capture_json(const Args& args, Json& data) {
    std::string out;
    if (!capture(args, out)) return false;
    data = Json::parse(out, nullptr, false);
    return !data.is_discarded();
}
bool read_config(const fs::path& file, Json& config, std::string& error) {
    std::ifstream in(file);
    if (!in) { error = "Drawer menu configuration is missing: " + file.string(); return false; }
    config = Json::parse(in, nullptr, false);
    if (!config.is_object() || !config.contains("groups") || !config["groups"].is_array()) {
        error = "Menu configuration needs a groups array"; return false;
    }
    if (config["groups"].empty() || config["groups"].size() > 32) { error = "Invalid menu group count"; return false; }
    const std::set<std::string> allowed = {"id","label","detail","icon","kind","page","value","checked","enabled","confirm","argument","close","description","keys","keywords","section"};
    std::set<std::string> group_ids;
    for (const auto& group : config["groups"]) {
        const auto id = text(group, "id");
        if (!group.is_object() || !identifier(id) || id == "root" || id == "search" || pages.count(id)
            || !group_ids.insert(id).second || text(group, "label").empty() || !safe_text(text(group, "label"))
            || !group.contains("items") || !group["items"].is_array() || group["items"].size() > 128) {
            error = "Invalid or duplicate menu group"; return false;
        }
        std::set<std::string> item_ids;
        for (const auto& row : group["items"]) {
            const auto row_id = text(row, "id"), kind = text(row, "kind");
            if (!row.is_object() || !identifier(row_id) || !item_ids.insert(row_id).second
                || text(row, "label").empty() || !safe_text(text(row, "label"))
                || (kind != "page" && kind != "action" && kind != "toggle" && kind != "slider")
                || (kind != "page" && !actions.count(row_id))) {
                error = "Invalid menu item or unknown action"; return false;
            }
            for (auto it = row.begin(); it != row.end(); ++it) {
                if (!allowed.count(it.key()) || (it.value().is_string() && !safe_text(it.value().get<std::string>()))) {
                    error = "Unsupported menu item field"; return false;
                }
            }
            for (const char* key : {"checked", "enabled", "close"}) {
                if (row.contains(key) && !row[key].is_boolean()) { error = "Menu boolean has an invalid type"; return false; }
            }
            if (row.contains("argument") && !row["argument"].is_string()) { error = "Menu argument must be text"; return false; }
            if (row.contains("keys") && (!row["keys"].is_string() || !safe_text(text(row, "keys"), 64))) { error = "Menu keys must be short text"; return false; }
            if (row.contains("section") && (!row["section"].is_string() || text(row, "section").empty() || !safe_text(text(row, "section"), 40))) {
                error = "Menu section must be a short heading"; return false;
            }
            if (row.contains("keywords")) {
                const auto& words = row["keywords"];
                if (!words.is_array() || words.size() > 24
                    || std::any_of(words.begin(), words.end(), [](const Json& w) { return !w.is_string() || w.get<std::string>().empty() || !safe_text(w.get<std::string>(), 64); })) {
                    error = "Menu keywords must be a short list of words"; return false;
                }
            }
            if (row.contains("value") && !row["value"].is_number()) { error = "Slider value must be numeric"; return false; }
            if (row.contains("confirm") && !row["confirm"].is_boolean() && !row["confirm"].is_string()) {
                error = "Invalid confirmation"; return false;
            }
            if (kind == "page" && !identifier(text(row, "page"))) { error = "Invalid menu page"; return false; }
        }
    }
    for (const auto& group : config["groups"]) for (const auto& row : group["items"])
        if (text(row, "kind") == "page" && !pages.count(text(row, "page")) && !group_ids.count(text(row, "page"))) {
            error = "Unknown menu page"; return false;
        }
    for (const char* key : {"project_roots", "project_editor"}) {
        if (!config.contains(key)) continue;
        if (!config[key].is_array() || config[key].empty() || config[key].size() > 16) {
            error = std::string(key) + " must be a nonempty string array"; return false;
        }
        for (const auto& value : config[key]) {
            if (!value.is_string() || value.get<std::string>().empty() || !safe_text(value.get<std::string>())) {
                error = std::string("Invalid ") + key; return false;
            }
            if (std::string(key) == "project_roots" && !fs::path(value.get<std::string>()).is_absolute()
                && value.get<std::string>().rfind("~/", 0) != 0) {
                error = "Project roots must be absolute or start with ~/"; return false;
            }
        }
    }
    for (const char* key : {"downloads_directory", "screenshots_directory"}) if (config.contains(key)) {
        const auto path = text(config, key);
        if (path.empty() || !safe_text(path) || (!fs::path(path).is_absolute() && path.rfind("~/", 0) != 0)) {
            error = std::string(key) + " must be absolute or start with ~/"; return false;
        }
    }
    if (config.contains("favorites")) {
        if (!config["favorites"].is_array() || config["favorites"].size() > 8) {
            error = "favorites must be an array of at most eight group/item references"; return false;
        }
        std::set<std::string> seen;
        for (const auto& favorite : config["favorites"]) {
            if (!favorite.is_string()) { error = "Favorite references must be text"; return false; }
            const auto reference = favorite.get<std::string>();
            bool found = false;
            for (const auto& group : config["groups"]) for (const auto& row : group["items"])
                if (reference == text(group, "id") + "/" + text(row, "id")) found = true;
            if (!found || !seen.insert(reference).second) {
                error = "Unknown or duplicate favorite: " + reference; return false;
            }
        }
    }
    return true;
}

struct State { bool ok = false; double value = 0; bool checked = false; std::string label; };
State audio_state(bool microphone = false) {
    std::string out;
    State state;
    if (!capture({"wpctl", "get-volume", microphone ? "@DEFAULT_AUDIO_SOURCE@" : "@DEFAULT_AUDIO_SINK@"}, out)) return state;
    std::smatch match;
    if (!std::regex_search(out, match, std::regex("Volume: ([0-9]+(?:\\.[0-9]+)?)"))) return state;
    char* end = nullptr;
    const double value = std::strtod(match[1].str().c_str(), &end);
    if (!std::isfinite(value) || value < 0 || value > 10) return state;
    state.ok = true; state.value = std::round(value * 100); state.checked = out.find("MUTED") != std::string::npos;
    state.label = state.checked ? "Muted" : std::to_string(static_cast<int>(state.value)) + "%";
    return state;
}
State brightness_state() {
    std::string out; State state;
    if (!capture({"brightnessctl", "-m"}, out)) return state;
    std::smatch match;
    if (!std::regex_search(out, match, std::regex(",([0-9]{1,3})%,"))) return state;
    int value = 0; const auto digits = match[1].str();
    std::from_chars(digits.data(), digits.data() + digits.size(), value);
    if (value > 100) return state;
    state.ok = true; state.value = value; state.label = std::to_string(value) + "%"; return state;
}
State dnd_state() {
    State state; std::string out;
    if (sh::have("makoctl") && capture({"makoctl", "mode"}, out)) {
        state.ok = true; state.checked = out.find("do-not-disturb") != std::string::npos; state.label = "mako";
    } else if (sh::have("dunstctl") && capture({"dunstctl", "is-paused"}, out) && (trim(out) == "true" || trim(out) == "false")) {
        state.ok = true; state.checked = trim(out) == "true"; state.label = "dunst";
    }
    return state;
}
State process_state(const std::string& process) {
    State state; std::string out;
    if (!sh::have("pgrep")) return state;
    const int status = sh::probe({"pgrep", "-x", process}, out);
    if (status == 0 || status == 1) { state.ok = true; state.checked = status == 0; }
    return state;
}
bool nightlight_identity(bool& identity) {
    std::string output;
    if (!capture({"hyprctl", "hyprsunset", "identity", "get"}, output)) return false;
    output = trim(output);
    if (output != "true" && output != "false") return false;
    identity = output == "true";
    return true;
}
State nightlight_state() {
    State state;
    bool identity = true;
    if (nightlight_identity(identity)) {
        state.ok = true; state.checked = !identity;
        state.label = identity ? "Normal screen colors" : "Warm color filter enabled";
    } else {
        const auto process = process_state("hyprsunset");
        state.ok = process.ok && !process.checked;
    }
    return state;
}
Json toggle_nightlight() {
    if (!sh::have("hyprsunset")) return result(false, "Install hyprsunset to use Night light");
    if (!sh::have("hyprctl")) return result(false, "Hyprland controls are unavailable");
    bool identity = true;
    if (!nightlight_identity(identity)) {
        const auto process = process_state("hyprsunset");
        if (!process.ok) return result(false, "Night light state is unavailable");
        if (!process.checked) {
            const auto started = background({"hyprsunset", "--identity"}, "Starting Night light");
            if (!truth(started, "ok")) return started;
        }
        bool ready = false;
        for (int attempt = 0; attempt < 25; ++attempt) {
            if (nightlight_identity(identity)) { ready = true; break; }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (!ready) return result(false, "Night light could not connect to Hyprland; Hyprsunset did not become ready");
    }
    // Identity is the actual filter state; an idle daemon is not an enabled night light.
    Args args{"hyprctl", "hyprsunset"};
    if (identity) { args.push_back("temperature"); args.push_back("3500"); }
    else args.push_back("identity");
    std::string output;
    if (!capture(args, output) || trim(output) != "ok") return result(false, "Night light change was rejected");
    bool after = identity;
    if (!nightlight_identity(after) || after == identity) return result(false, "Night light state did not change");
    return result(true, after ? "night light off" : "night light on · a warmer glow");
}
std::string required(const std::string& id) {
    if (id == "volume" || id == "volume-mute" || id == "mic-mute") return "wpctl";
    if (id.rfind("media-", 0) == 0) return "playerctl";
    if (id == "brightness") return "brightnessctl";
    if (id == "nightlight") return "hyprsunset";
    if (id == "power-profile") return "powerprofilesctl";
    if (id == "color-picker") return "hyprpicker";
    if (id == "password-copy") return "pass";
    if (id == "security") return "desk";
    if (id == "credits-setup") return "desk-credits";
    if (id == "credits-console") return "xdg-open";
    if (id.rfind("api-task-", 0) == 0) return "claude-api";
    if (id == "suspend" || id == "reboot" || id == "poweroff") return "systemctl";
    if (id == "logout") return "desk-hl";
    return {};
}
void decorate_media(Json& row) {
    // Query the same default player as the existing playback actions. No
    // follower daemon: this shares the drawer's normal visible-page refresh.
    std::string output;
    if (!capture({"playerctl", "--no-messages", "metadata", "--format",
                      "{{title}}\x1f{{artist}}\x1f{{status}}\x1f{{mpris:artUrl}}"}, output)
        || output.size() > 16384) return;
    std::array<std::string, 4> fields;
    size_t begin = 0;
    for (size_t i = 0; i < fields.size(); ++i) {
        const auto end = output.find('\x1f', begin);
        if ((i < 3) == (end == std::string::npos)) return;
        fields[i] = trim(output.substr(begin, end == std::string::npos ? end : end - begin));
        begin = end == std::string::npos ? output.size() : end + 1;
    }
    for (size_t i = 0; i < 2; ++i) {
        if (!safe_text(fields[i], 2048)) return;
        for (char& c : fields[i]) if (static_cast<unsigned char>(c) < 32) c = ' ';
    }
    if (fields[2] != "Playing" && fields[2] != "Paused" && fields[2] != "Stopped") return;
    if (!fields[0].empty()) row["label"] = fields[0];
    row["detail"] = (fields[1].empty() ? "" : fields[1] + " · ") + fields[2];
    row["mediaState"] = fields[2];
    row["presentation"] = "media";
    const auto& artwork = fields[3];
    const bool supported = artwork.rfind("file:///", 0) == 0 || artwork.rfind("https://", 0) == 0 || artwork.rfind("http://", 0) == 0;
    if (supported && safe_text(artwork) &&
        std::none_of(artwork.begin(), artwork.end(), [](unsigned char c) { return c < 32; })) {
        row["artwork"] = artwork;
    }
}
bool decorate(Json& row) {
    const auto id = text(row, "id");
    if (text(row, "kind") == "page") return true;
    const auto dependency = required(id);
    if (!dependency.empty() && !sh::have(dependency)) {
        row["enabled"] = false; row["detail"] = dependency + " is not installed"; return false;
    }
    if (id == "media-play-pause") decorate_media(row);
    State state;
    bool queried = false;
    if (id == "volume" || id == "volume-mute" || id == "mic-mute") { state = audio_state(id == "mic-mute"); queried = true; }
    else if (id == "brightness") { state = brightness_state(); queried = true; }
    else if (id == "dnd") { state = dnd_state(); queried = true; }
    else if (id == "nightlight") { state = nightlight_state(); queried = true; }
    else if (id == "idle") {
        state = process_state("hypridle");
        const bool paused = regular(runtime() / "hypridle_paused");
        // Auto-lock is opt-in (desk-lock --idle): with hypridle off and nothing paused, nothing will blank the
        // screen, so there is nothing to stay awake against. Say so calmly rather than as a failed read.
        if (state.ok && !state.checked && !paused) {
            row["enabled"] = false; row["checked"] = false;
            row["detail"] = "Auto-lock is off, so the screen already stays awake";
            row["disabledReason"] = "Turn on auto-lock with desk-lock --idle on to use this";
            return true;
        }
        state.checked = paused; queried = true;
    }
    else if (id == "power-profile") {
        std::string out; queried = true;
        state.ok = capture({"powerprofilesctl", "get"}, out);
        state.label = trim(out);
        state.ok = state.ok && (state.label == "balanced" || state.label == "performance" || state.label == "power-saver");
    }
    if (queried) {
        if (!state.ok) {
            row["enabled"] = false; row["detail"] = "Could not read " + text(row, "label", id) + " state"; row.erase("value"); row.erase("checked"); return false;
        }
        if (text(row, "kind") == "slider") row["value"] = std::min(100.0, state.value);
        if (text(row, "kind") == "toggle") row["checked"] = state.checked;
        if (!state.label.empty() && id != "dnd") row["detail"] = state.label;
    }
    if (id == "suspend" || id == "reboot" || id == "poweroff" || id == "logout") row["confirm"] = true;
    return true;
}

struct Desktop { std::string name, detail, icon; fs::path path; std::vector<std::string> keywords; };
std::string desktop_value(std::string value) {
    std::string out;
    for (size_t i = 0; i < value.size(); ++i) {
        if (value[i] == '\\' && i + 1 < value.size()) {
            const char next = value[++i];
            if (next == 's') out += ' '; else if (next == 'n') out += '\n'; else if (next == 't') out += '\t';
            else if (next == 'r') out += '\r'; else out += next;
        } else out += value[i];
    }
    return out;
}
std::vector<Desktop> desktops() {
    std::vector<fs::path> roots{data_home() / "applications"};
    std::string dirs = env("XDG_DATA_DIRS", "/usr/local/share:/usr/share");
    std::replace(dirs.begin(), dirs.end(), ':', '\n');
    for (const auto& dir : lines(dirs)) if (!dir.empty()) roots.emplace_back(fs::path(dir) / "applications");
    std::vector<Desktop> found;
    std::set<std::string> ids;
    for (const auto& root : roots) {
        std::error_code ec;
        fs::recursive_directory_iterator iter(root, fs::directory_options::skip_permission_denied, ec), end;
        while (!ec && iter != end) {
            const auto path = iter->path(); iter.increment(ec);
            if (path.extension() != ".desktop" || !regular(path)) continue;
            std::string id = path.lexically_relative(root).string(); std::replace(id.begin(), id.end(), '/', '-');
            if (!ids.insert(id).second) continue;
            std::map<std::string, std::string> values;
            bool entry = false;
            for (const auto& raw : lines(read(path))) {
                const auto line = trim(raw);
                if (line.empty() || line.front() == '#') continue;
                if (line.front() == '[') { entry = line == "[Desktop Entry]"; continue; }
                const auto eq = line.find('=');
                if (entry && eq != std::string::npos) values[line.substr(0, eq)] = desktop_value(line.substr(eq + 1));
            }
            if (values["Type"] != "Application" || values["Name"].empty() || values["Hidden"] == "true" || values["NoDisplay"] == "true") continue;
            if (!values["TryExec"].empty() && !sh::have(values["TryExec"])) continue;
            if (!safe_text(values["Name"]) || !safe_text(path.string())) continue;
            // Keywords and the generic name let "browser" or "music" find an app by what it is for.
            std::vector<std::string> words;
            std::istringstream keywords(values["Keywords"] + ";" + values["GenericName"]);
            for (std::string word; std::getline(keywords, word, ';') && words.size() < 16;)
                if (!trim(word).empty() && safe_text(trim(word), 64)) words.push_back(trim(word));
            found.push_back({values["Name"], values["Comment"], values["Icon"], fs::absolute(path), words});
        }
    }
    std::sort(found.begin(), found.end(), [](const auto& a, const auto& b) { return lower(a.name) < lower(b.name); });
    return found;
}
std::vector<std::string> nm_fields(const std::string& line) {
    std::vector<std::string> fields(1);
    bool escaped = false;
    for (char c : line) {
        if (escaped) { fields.back() += c; escaped = false; }
        else if (c == '\\') escaped = true;
        else if (c == ':') fields.emplace_back();
        else fields.back() += c;
    }
    if (escaped) fields.back() += '\\';
    return fields;
}
bool wifi_rows(Json& rows) {
    std::string out;
    if (!capture({"nmcli", "-t", "--escape", "yes", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "no"}, out)) return false;
    rows = Json::array(); std::set<std::string> seen;
    for (const auto& line : lines(out)) {
        const auto f = nm_fields(line);
        if (f.size() != 4 || f[1].empty() || !safe_text(f[1], 32) || !seen.insert(f[1]).second) continue;
        auto row = item("wifi-connect", f[1], "action", (f[0] == "*" ? "Connected · " : "") + f[2] + "% · " + (f[3].empty() ? "Open" : f[3]), "wifi");
        row["argument"] = f[1]; row["checked"] = f[0] == "*"; rows.push_back(row);
    }
    return true;
}
// bluetoothctl waits forever for a daemon that isn't running, so ask systemd first.
bool bluetooth_service_running() {
    if (!sh::have("systemctl")) return true;
    std::string ignored;
    return capture({"systemctl", "is-active", "--quiet", "bluetooth"}, ignored);
}
bool bluetooth_rows(Json& rows) {
    std::string out;
    if (!capture({"bluetoothctl", "devices"}, out)) return false;
    rows = Json::array();
    const std::regex format("^Device ([[:xdigit:]]{2}(?::[[:xdigit:]]{2}){5}) (.+)$");
    for (const auto& line : lines(out)) {
        std::smatch match; if (!std::regex_match(line, match, format)) continue;
        auto row = item("bluetooth-connect", match[2], "action", match[1], "bluetooth");
        row["argument"] = match[1].str(); rows.push_back(row);
    }
    return true;
}
bool numeric_id(const std::string& value) {
    return !value.empty() && value.size() <= 20 && value.find_first_not_of("0123456789") == std::string::npos;
}
std::string base64(const std::string& data) {
    static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out; out.reserve((data.size() + 2) / 3 * 4);
    for (size_t i = 0; i < data.size(); i += 3) {
        const unsigned a = static_cast<unsigned char>(data[i]);
        const unsigned b = i + 1 < data.size() ? static_cast<unsigned char>(data[i + 1]) : 0;
        const unsigned c = i + 2 < data.size() ? static_cast<unsigned char>(data[i + 2]) : 0;
        out += alphabet[a >> 2]; out += alphabet[((a & 3) << 4) | (b >> 4)];
        out += i + 1 < data.size() ? alphabet[((b & 15) << 2) | (c >> 6)] : '=';
        out += i + 2 < data.size() ? alphabet[c & 63] : '=';
    }
    return out;
}
// Thumbnails are made once per clipboard entry (cliphist ids never change their contents) and kept, 0600 in a
// 0700 folder of the runtime directory, so the page's refresh reads files instead of decoding every picture again.
bool write_atomic(const fs::path& path, const std::string& data);
fs::path thumb_dir() { return runtime() / "foxml/clip-thumbs"; }
bool thumb_dir_ready() {
    std::error_code ec;
    fs::create_directories(thumb_dir(), ec);
    if (ec || fs::is_symlink(thumb_dir(), ec) || !directory(thumb_dir())) return false;
    fs::permissions(thumb_dir(), fs::perms::owner_all, fs::perm_options::replace, ec);
    return !ec;
}
enum class Preview { made, not_a_picture, unreadable };
Preview make_preview(const std::string& id, std::string& mime, std::string& bytes) {
    if (!capture({"cliphist", "decode", id}, bytes)) return Preview::unreadable;
    if (bytes.empty() || bytes.size() > 16 * 1024 * 1024) return Preview::not_a_picture;
    if (bytes.size() >= 8 && bytes.compare(0, 8, "\211PNG\r\n\032\n", 8) == 0) mime = "image/png";
    else if (bytes.size() >= 3 && bytes.compare(0, 3, "\377\330\377", 3) == 0) mime = "image/jpeg";
    else if (bytes.size() >= 12 && bytes.compare(0, 4, "RIFF") == 0 && bytes.compare(8, 4, "WEBP") == 0) mime = "image/webp";
    else return Preview::not_a_picture;
    if (sh::have("magick")) {
        // Short-lived 0600 input avoids exposing clipboard pixels in a shared thumbnail cache.
        std::string pattern = (runtime() / "fox-drawer-image-XXXXXX").string();
        std::vector<char> path(pattern.begin(), pattern.end()); path.push_back('\0');
        const int fd = ::mkstemp(path.data());
        if (fd >= 0) {
            size_t offset = 0;
            while (offset < bytes.size()) {
                const ssize_t n = ::write(fd, bytes.data() + offset, bytes.size() - offset);
                if (n > 0) offset += static_cast<size_t>(n); else if (n < 0 && errno == EINTR) continue; else break;
            }
            ::close(fd); std::string thumbnail;
            const bool ok = offset == bytes.size() && capture({"magick", std::string(path.data()) + "[0]", "-thumbnail", "144x88>", "-strip", "png:-"}, thumbnail);
            ::unlink(path.data());
            if (ok && !thumbnail.empty() && thumbnail.size() <= 256 * 1024) { bytes = std::move(thumbnail); mime = "image/png"; }
        }
    }
    if (bytes.size() > 256 * 1024) { bytes.clear(); mime.clear(); return Preview::not_a_picture; }
    return Preview::made;
}
// A kept thumbnail is "<mime>\n<bytes>"; an empty mime remembers an entry that is not a picture we can show.
std::string image_preview(const std::string& id, bool cache) {
    const auto file = thumb_dir() / (id + ".thumb");
    if (cache && regular(file) && !fs::is_symlink(file)) {
        const auto kept = read(file);
        const auto newline = kept.find('\n');
        if (newline != std::string::npos) {
            const auto mime = kept.substr(0, newline);
            return mime.empty() ? std::string() : "data:" + mime + ";base64," + base64(kept.substr(newline + 1));
        }
    }
    std::string mime, bytes;
    const auto made = make_preview(id, mime, bytes);
    if (made == Preview::unreadable) return {};
    if (cache) write_atomic(file, (made == Preview::made ? mime : std::string()) + "\n" + (made == Preview::made ? bytes : std::string()));
    return made == Preview::made ? "data:" + mime + ";base64," + base64(bytes) : std::string();
}
// Thumbnails of entries that left the history go with them.
void prune_thumbs(const std::set<std::string>& keep) {
    std::error_code ec;
    for (fs::directory_iterator it(thumb_dir(), ec), end; !ec && it != end; it.increment(ec)) {
        const auto name = it->path().filename().string();
        const auto dot = name.find('.');
        if (!keep.count(name.substr(0, dot))) { std::error_code ignored; fs::remove(it->path(), ignored); }
    }
}
bool clipboard_rows(Json& rows, bool images) {
    std::string out;
    if (!capture({"cliphist", "list"}, out)) return false;
    rows = Json::array();
    for (const auto& line : lines(out)) {
        const auto tab = line.find('\t'); if (tab == std::string::npos || !numeric_id(line.substr(0, tab))) continue;
        const auto body = line.substr(tab + 1); const bool binary = body.find("[[ binary data") != std::string::npos;
        if (binary != images) continue;
        auto row = item("clipboard-restore", images ? "Image #" + line.substr(0, tab) : body.substr(0, 140), "action",
                        images ? body : "Clipboard #" + line.substr(0, tab), images ? "image" : "clipboard");
        row["argument"] = line.substr(0, tab); rows.push_back(row);
    }
    return true;
}
std::vector<fs::path> wallpapers() {
    std::vector<fs::path> found; std::error_code ec;
    fs::directory_iterator iter(fs::path(home()) / ".wallpapers", ec), end;
    const std::regex variant(".*_[0-9]+x[0-9]+\\.[^.]+$");
    while (!ec && iter != end) {
        const auto path = iter->path(); iter.increment(ec);
        const auto name = path.filename().string(), ext = lower(path.extension().string());
        if (!name.empty() && name.front() != '.' && !std::regex_match(name, variant) && regular(path)
            && (ext == ".jpg" || ext == ".jpeg" || ext == ".png" || ext == ".webp")) found.push_back(fs::absolute(path));
    }
    std::sort(found.begin(), found.end()); return found;
}
std::vector<std::string> themes() {
    std::vector<std::string> found; std::error_code ec;
    fs::directory_iterator iter(repository() / "themes", ec), end;
    while (!ec && iter != end) {
        const auto path = iter->path(); iter.increment(ec);
        const auto name = path.filename().string();
        if (regular(path / "palette.sh") && regular(path / "theme.conf") && safe_text(name) && !name.empty() && name.front() != '-') found.push_back(name);
    }
    std::sort(found.begin(), found.end()); return found;
}

bool member_argument(const Json& rows, const std::string& argument) {
    for (const auto& row : rows) if (text(row, "argument") == argument) return true;
    return false;
}
bool desktops_argument(const std::string& argument) {
    for (const auto& app : desktops()) if (app.path.string() == argument) return true;
    return false;
}
bool percent(const std::string& value, int& parsed) {
    if (value.empty() || value.size() > 3 || value.find_first_not_of("0123456789") != std::string::npos) return false;
    const auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
    return result.ec == std::errc{} && parsed >= 0 && parsed <= 100;
}

// Shared sh:: has no stdin/pipe primitive. Keep clipboard data in the pipe, never a shell string or text JSON.
bool write_clipboard(const std::string& data) {
    int pipefd[2]; if (::pipe(pipefd) < 0) return false;
    const pid_t child = ::fork();
    if (child < 0) { ::close(pipefd[0]); ::close(pipefd[1]); return false; }
    if (child == 0) {
        ::close(pipefd[1]); ::dup2(pipefd[0], STDIN_FILENO); ::close(pipefd[0]);
        const int nullfd = ::open("/dev/null", O_WRONLY);
        if (nullfd >= 0) { ::dup2(nullfd, STDOUT_FILENO); ::close(nullfd); }
        ::execlp("wl-copy", "wl-copy", static_cast<char*>(nullptr)); ::_exit(127);
    }
    ::close(pipefd[0]);
    const auto old_signal = std::signal(SIGPIPE, SIG_IGN);
    size_t offset = 0;
    while (offset < data.size()) {
        const ssize_t count = ::write(pipefd[1], data.data() + offset, data.size() - offset);
        if (count > 0) offset += static_cast<size_t>(count); else if (count < 0 && errno == EINTR) continue; else break;
    }
    ::close(pipefd[1]); int status = 0;
    std::signal(SIGPIPE, old_signal);
    while (::waitpid(child, &status, 0) < 0) if (errno != EINTR) return false;
    return offset == data.size() && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
Json restore_clipboard(const std::string& id) {
    if (!numeric_id(id)) return result(false, "Invalid clipboard ID");
    Json rows;
    if ((!clipboard_rows(rows, false) || !member_argument(rows, id)) && (!clipboard_rows(rows, true) || !member_argument(rows, id)))
        return result(false, "Clipboard entry is unavailable");
    if (!sh::have("wl-copy")) return result(false, "wl-copy is not installed");
    // Decode succeeds before touching the live clipboard; an invalid decode must not replace it with an empty value.
    std::string data;
    if (!capture({"cliphist", "decode", id}, data)) return result(false, "Could not decode clipboard entry");
    const bool ok = write_clipboard(data);
    return result(ok, ok ? "Clipboard restored" : "Could not restore clipboard", ok);
}

std::string group_for(const Json& config, const std::string& page) {
    const auto target = page.rfind("tools-", 0) == 0 ? "tools" : page;
    for (const auto& group : config["groups"]) {
        if (text(group, "id") == target) return target;
        for (const auto& row : group["items"]) if (text(row, "page") == target) return text(group, "id");
    }
    return {};
}
// Search reads "wi-fi", "Wi-Fi" and "wifi" as one word.
std::string search_fold(const std::string& value) {
    auto out = lower(value);
    out.erase(std::remove(out.begin(), out.end(), '-'), out.end());
    return out;
}
std::string search_text(const Json& row) {
    std::string haystack = text(row, "label") + "\n" + text(row, "detail") + "\n" + text(row, "keys");
    if (const auto words = row.find("keywords"); words != row.end() && words->is_array())
        for (const auto& word : *words) if (word.is_string()) haystack += "\n" + word.get<std::string>();
    return search_fold(haystack);
}
// A menu row is also found by its id, so "dnd" or "api-credits" reach it.
void searchable_by_id(Json& row) {
    if (!row.contains("keywords") || !row["keywords"].is_array()) row["keywords"] = Json::array();
    row["keywords"].push_back(text(row, "id"));
}
struct Project { fs::path path; std::string name, type; };
fs::path bookmark_file() {
    return fs::path(env("XDG_STATE_HOME", home() + "/.local/state")) / "foxml/project-bookmarks.json";
}
bool bookmarks(std::vector<std::string>& paths) {
    const auto file = bookmark_file();
    std::error_code ec;
    if (!fs::exists(file, ec)) return !ec;
    const auto data = Json::parse(read(file), nullptr, false);
    if (!data.is_array() || data.size() > 16) return false;
    for (const auto& path : data) {
        if (!path.is_string() || !fs::path(path.get<std::string>()).is_absolute() || !safe_text(path.get<std::string>())) return false;
        if (std::find(paths.begin(), paths.end(), path.get<std::string>()) != paths.end()) return false;
        paths.push_back(path.get<std::string>());
    }
    return true;
}
bool write_atomic(const fs::path& path, const std::string& data) {
    std::string pattern = path.string() + ".XXXXXX";
    std::vector<char> name(pattern.begin(), pattern.end()); name.push_back('\0');
    const int fd = ::mkstemp(name.data());
    if (fd < 0) return false;
    size_t offset = 0;
    while (offset < data.size()) {
        const auto count = ::write(fd, data.data() + offset, data.size() - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        offset += static_cast<size_t>(count);
    }
    bool ok = offset == data.size() && ::fsync(fd) == 0;
    if (::close(fd) != 0) ok = false;
    if (ok) ok = ::rename(name.data(), path.c_str()) == 0;
    if (!ok) ::unlink(name.data());
    return ok;
}
std::string agent_key(const std::string& record) {
    std::array<unsigned char, SHA256_DIGEST_LENGTH> digest{};
    ::SHA256(reinterpret_cast<const unsigned char*>(record.data()), record.size(), digest.data());
    std::string key;
    for (const auto byte : digest) { key += "0123456789abcdef"[byte >> 4]; key += "0123456789abcdef"[byte & 15]; }
    return key;
}
fs::path agent_queue() {
    const auto dir = env("XDG_RUNTIME_DIR");
    return (!dir.empty() && directory(dir) ? fs::path(dir) : fs::path("/tmp") / ("foxml-" + env("USER", std::to_string(::getuid())))) / "foxml-agent-queue.jsonl";
}
struct AgentLock {
    int fd = -1;
    explicit AgentLock(int mode) {
        fd = ::open((agent_queue().string() + ".lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd >= 0 && ::flock(fd, mode) != 0) { ::close(fd); fd = -1; }
    }
    ~AgentLock() { if (fd >= 0) ::close(fd); }
};
// Seconds since the epoch for a note: its "epoch", else its ISO-8601 "ts" with a ±hh:mm offset; 0 when neither reads.
long long note_time(const Json& note) {
    const auto epoch = note.find("epoch");
    if (epoch != note.end() && epoch->is_number_integer()) return epoch->get<long long>();
    const auto ts = text(note, "ts");
    std::tm when{}; int oh = 0, om = 0; char sign = 0;
    if (std::sscanf(ts.c_str(), "%4d-%2d-%2dT%2d:%2d:%2d%c%2d:%2d", &when.tm_year, &when.tm_mon, &when.tm_mday,
                    &when.tm_hour, &when.tm_min, &when.tm_sec, &sign, &oh, &om) != 9 || (sign != '+' && sign != '-')) return 0;
    when.tm_year -= 1900; when.tm_mon -= 1;
    const long long offset = (oh * 3600LL + om * 60LL) * (sign == '-' ? -1 : 1);
    return static_cast<long long>(::timegm(&when)) - offset;
}
constexpr long long agent_note_lifetime = 12 * 3600;
// A pane's newest note stands for it; anything older than twelve hours has gone stale.
std::vector<std::pair<std::string, Json>> agent_notes() {
    std::vector<std::pair<std::string, Json>> notes;
    if (!regular(agent_queue())) return notes;
    AgentLock lock(LOCK_SH);
    if (lock.fd < 0) return notes;
    const long long now = static_cast<long long>(std::time(nullptr));
    // A pane is known by its tmux id and by its session:window.pane place; older notes carry only the place.
    std::map<std::string, size_t> newest;
    for (const auto& line : lines(read(agent_queue()))) {
        auto note = Json::parse(line, nullptr, false);
        if (!note.is_object()) continue;
        const auto at = note_time(note);
        if (at > 0 && now - at > agent_note_lifetime) continue;
        for (const auto& name : {text(note, "pane"), text(note, "tmux")}) {
            if (name.empty()) continue;
            const auto seen = newest.find(name);
            if (seen != newest.end()) notes[seen->second].first.clear();
            newest[name] = notes.size();
        }
        notes.emplace_back(agent_key(line), std::move(note));
    }
    notes.erase(std::remove_if(notes.begin(), notes.end(), [](const auto& entry) { return entry.first.empty(); }), notes.end());
    return notes;
}
bool dismiss_agent(const std::string& key, bool all = false) {
    AgentLock lock(LOCK_EX);
    if (lock.fd < 0) return false;
    std::string remaining;
    bool removed = false;
    for (const auto& line : lines(read(agent_queue()))) {
        if (all || (!removed && agent_key(line) == key)) { removed = true; continue; }
        remaining += line + "\n";
    }
    return write_atomic(agent_queue(), remaining);
}
Json focus_address(const std::string& address, bool close = true) {
    return command({"desk-hl", "dispatch", "hl.dsp.focus({ window = 'address:" + address + "' })",
                    "focuswindow address:" + address}, "Window selected", close);
}
void focus_agent_client(int pid) {
    std::set<int> ancestors;
    for (int depth = 0; pid > 1 && depth < 32 && ancestors.insert(pid).second; ++depth) {
        const auto stat = read(fs::path("/proc") / std::to_string(pid) / "stat");
        const auto end = stat.rfind(')');
        if (end == std::string::npos) break;
        std::istringstream fields(stat.substr(end + 1));
        char state = 0; int parent = 0;
        if (!(fields >> state >> parent)) break;
        pid = parent;
    }
    Json clients;
    if (!capture_json({"hyprctl", "-j", "clients"}, clients) || !clients.is_array()) return;
    for (const auto& client : clients) {
        const auto process = client.find("pid");
        const auto address = text(client, "address");
        if (process != client.end() && process->is_number_integer() && ancestors.count(process->get<int>())
            && std::regex_match(address, std::regex("0x[0-9a-fA-F]{1,32}"))) {
            // A moment later, detached: the drawer holds the keyboard until it closes after this action returns,
            // and closing hands it back to the old window, so focusing now only moved the pointer.
            launch({"/bin/sh", "-c", "sleep 0.35; exec desk-hl dispatch \"$1\" \"$2\"", "sh",
                    "hl.dsp.focus({ window = 'address:" + address + "' })", "focuswindow address:" + address}, "");
            return;
        }
    }
}
// Selects a tmux pane (session:window.pane) in the terminal that shows it, and focuses that window.
Json jump_target(const std::string& target) {
    if (!safe_text(target, 256) || !std::regex_match(target, std::regex("[^:\r\n]{1,200}:[0-9]+\\.[0-9]+"))) return result(false, "This note has no reachable tmux pane");
    if (!sh::have("tmux")) return result(false, "tmux is not installed");
    const auto colon = target.find(':');
    const auto session = target.substr(0, colon);
    const auto window = target.substr(0, target.rfind('.'));
    std::string output;
    if (!capture({"tmux", "has-session", "-t", "=" + session}, output)
        || !capture({"tmux", "select-window", "-t", window}, output)
        || !capture({"tmux", "select-pane", "-t", target}, output)) return result(false, "The agent terminal is no longer available");
    std::string client;
    int client_pid = 0;
    if (!env("TMUX").empty()) {
        if (!capture({"tmux", "switch-client", "-t", target}, output)) return result(false, "Could not switch to the agent terminal");
        if (capture({"tmux", "display-message", "-p", "#{client_pid}"}, output)) {
            const auto value = trim(output); std::from_chars(value.data(), value.data() + value.size(), client_pid);
        }
    } else {
        if (!capture({"tmux", "list-clients", "-F", "#{client_activity}\t#{client_name}\t#{client_pid}\t#{client_session}"}, output)) return result(false, "Could not read tmux clients");
        // A terminal already showing that session is the one to bring forward; only when none does is the most
        // recently used terminal switched over to it (switching first left focus where it was).
        unsigned long long newest = 0, newest_showing = 0;
        std::string showing; int showing_pid = 0;
        for (const auto& line : lines(output)) {
            std::vector<std::string> field;
            for (size_t at = 0;;) { const auto tab = line.find('\t', at); field.push_back(line.substr(at, tab == std::string::npos ? std::string::npos : tab - at)); if (tab == std::string::npos) break; at = tab + 1; }
            if (field.size() < 3) continue;
            unsigned long long activity = 0; int process = 0;
            const auto a = std::from_chars(field[0].data(), field[0].data() + field[0].size(), activity);
            const auto p = std::from_chars(field[2].data(), field[2].data() + field[2].size(), process);
            if (a.ec != std::errc{} || a.ptr != field[0].data() + field[0].size() || p.ec != std::errc{}
                || p.ptr != field[2].data() + field[2].size() || process <= 0) continue;
            if (client.empty() || activity >= newest) { newest = activity; client = field[1]; client_pid = process; }
            if (field.size() > 3 && field[3] == session && (showing.empty() || activity >= newest_showing)) {
                newest_showing = activity; showing = field[1]; showing_pid = process;
            }
        }
        if (!showing.empty()) {
            client = showing; client_pid = showing_pid;
            if (!capture({"tmux", "switch-client", "-c", client, "-t", target}, output)) return result(false, "Could not switch to the agent terminal");
        } else {
            // Nobody shows it: a terminal of its own, never the one you are working in.
            const auto opened = terminal({"tmux", "attach-session", "-t", "=" + session}, "Agent terminal opened");
            if (!truth(opened, "ok")) return opened;
            client_pid = 0;
        }
    }
    if (client_pid > 0) focus_agent_client(client_pid);
    return result(true, "Agent terminal selected", true);
}
Json jump_agent(const std::string& key) {
    if (key.size() != 64 || key.find_first_not_of("0123456789abcdef") != std::string::npos) return result(false, "Invalid agent note");
    Json note;
    for (const auto& entry : agent_notes()) if (entry.first == key) { note = entry.second; break; }
    if (note.is_null()) return result(false, "This agent note has already been dismissed");
    auto jumped = jump_target(text(note, "tmux"));
    if (!truth(jumped, "ok")) return jumped;
    if (!dismiss_agent(key)) return result(false, "Terminal selected, but the note could not be dismissed");
    return jumped;
}

// ── Earlier notes: mako keeps the notes that expired (four seconds, even critical ones, and unseen during
// do-not-disturb); this reads them back. mako's history has no times, so arrivals are stamped by
// `desk-drawer note-arrived <id>` (mako's on-notify hook) and do-not-disturb from the drawer remembers the newest
// note it started after. Everything lives in $XDG_RUNTIME_DIR/foxml/notes.json and goes away at logout.
fs::path notes_file() { return runtime() / "foxml/notes.json"; }
struct NotesLock {
    int fd = -1;
    NotesLock() {
        std::error_code ec; fs::create_directories(notes_file().parent_path(), ec);
        fd = ::open((notes_file().string() + ".lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd >= 0 && ::flock(fd, LOCK_EX) != 0) { ::close(fd); fd = -1; }
    }
    ~NotesLock() { if (fd >= 0) ::close(fd); }
};
Json notes_state() {
    auto state = Json::parse(read(notes_file()), nullptr, false);
    if (!state.is_object()) state = Json::object();
    if (!state.contains("arrived") || !state["arrived"].is_object()) state["arrived"] = Json::object();
    return state;
}
bool save_notes_state(const Json& state) { return write_atomic(notes_file(), state.dump()); }
long long number_field(const Json& object, const char* key) {
    const auto at = object.find(key);
    return at != object.end() && at->is_number_integer() ? at->get<long long>() : 0;
}
// Pango markup and entities out, the tmux line out, the first line that is left.
std::string note_plain(const std::string& body) {
    std::string out; bool tag = false;
    for (char c : body) { if (c == '<') tag = true; else if (c == '>') tag = false; else if (!tag) out += c; }
    for (const auto& [entity, plain] : std::vector<std::pair<std::string, std::string>>{{"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&apos;", "'"}, {"&amp;", "&"}})
        for (auto at = out.find(entity); at != std::string::npos; at = out.find(entity, at + plain.size())) out.replace(at, entity.size(), plain);
    for (const auto& line : lines(out)) {
        const auto clean = trim(line);
        if (!clean.empty() && clean.rfind("tmux:", 0) != 0) return clean.size() > 140 ? clean.substr(0, 140) + "…" : clean;
    }
    return {};
}
std::string note_pane(const std::string& body) {
    static const std::regex pane(R"(tmux: ([^:<>\s]{1,200}:[0-9]+\.[0-9]+))");
    std::smatch m;
    return std::regex_search(body, m, pane) ? m[1].str() : std::string();
}
struct Note { long long id = 0; std::string app, summary, body, urgency; };
// The volume and brightness slips are mako notes too; they are not notes anyone missed.
bool passing_note(const Json& note) { return text(note, "app_name") == "fox-osd"; }
bool mako_notes(const char* which, std::vector<Note>& notes) {
    Json data;
    if (!sh::have("makoctl") || !capture_json({"makoctl", which, "-j"}, data) || !data.is_array()) return false;
    for (const auto& n : data) {
        if (!n.is_object() || passing_note(n) || number_field(n, "id") <= 0) continue;
        Note note{number_field(n, "id"), text(n, "app_name"), text(n, "summary"), text(n, "body"), text(n, "urgency", "normal")};
        if (!safe_text(note.app, 256) || !safe_text(note.summary) || !safe_text(note.body, 16384)) continue;
        notes.push_back(note);
    }
    return true;
}
long long newest_note(const std::vector<Note>& notes) {
    long long newest = 0;
    for (const auto& n : notes) newest = std::max(newest, n.id);
    return newest;
}
int note_arrived(const std::string& id) {
    if (!numeric_id(id)) return 2;
    NotesLock lock;
    if (lock.fd < 0) return 1;
    auto state = notes_state();
    auto& arrived = state["arrived"];
    arrived[id] = static_cast<long long>(std::time(nullptr));
    // A long session keeps the newest couple of hundred stamps; mako's history is shorter than that.
    const auto key_id = [](const std::string& key) { return numeric_id(key) ? std::strtoll(key.c_str(), nullptr, 10) : 0LL; };
    while (arrived.size() > 200) {
        auto oldest = arrived.begin();
        for (auto it = arrived.begin(); it != arrived.end(); ++it) if (key_id(it.key()) < key_id(oldest.key())) oldest = it;
        arrived.erase(oldest);
    }
    return save_notes_state(state) ? 0 : 1;
}
// Ids start again at 1 when mako restarts, so a clear or a quiet mark above the newest note has gone stale.
void settle_notes_state(Json& state, long long newest) {
    if (number_field(state, "cleared") > newest) state.erase("cleared");
    if (number_field(state, "quiet_after") > newest) state["quiet_after"] = newest;
}
bool earlier_note_rows(Json& rows) {
    std::vector<Note> notes;
    if (!mako_notes("history", notes)) return false;
    NotesLock lock;
    auto state = notes_state();
    settle_notes_state(state, newest_note(notes));
    const auto cleared = number_field(state, "cleared");
    const bool quiet = state.contains("quiet_since");
    const auto quiet_after = number_field(state, "quiet_after");
    std::sort(notes.begin(), notes.end(), [](const Note& a, const Note& b) { return a.id > b.id; });
    for (const auto& note : notes) {
        if (note.id <= cleared) continue;
        const auto stamp = state["arrived"].find(std::to_string(note.id));
        std::string when = stamp != state["arrived"].end() && stamp->is_number_integer() ? when_text(stamp->get<long long>()) : "";
        if (when.empty() && quiet && note.id > quiet_after) when = "while you were quiet";
        const auto said = note_plain(note.body);
        const auto pane = note_pane(note.body);
        std::string detail = note.app.empty() ? "a note" : note.app;
        if (!said.empty()) detail += " · " + said;
        if (!when.empty()) detail += " · " + when;
        auto row = item("note-open", note.summary.empty() ? "(no title)" : note.summary, "action", detail, "message");
        row["argument"] = std::to_string(note.id);
        if (note.urgency == "critical") row["careful"] = true;
        if (!pane.empty()) row["close"] = true;
        rows.push_back(row);
    }
    if (!rows.empty()) rows.push_back(item("note-clear", "Tuck these notes away", "action", "They leave this list; new notes still arrive here", "message"));
    return true;
}
Json open_note(const std::string& id) {
    if (!numeric_id(id)) return result(false, "Invalid note");
    std::vector<Note> notes;
    if (!mako_notes("history", notes)) return result(false, "Earlier notes are unavailable");
    const auto at = std::find_if(notes.begin(), notes.end(), [&](const Note& n) { return std::to_string(n.id) == id; });
    if (at == notes.end()) return result(false, "That note has drifted out of mako's history");
    const auto pane = note_pane(at->body);
    if (!pane.empty()) return jump_target(pane);
    if (!sh::have("notify-send")) return result(false, "notify-send is not installed");
    const auto urgency = at->urgency == "low" || at->urgency == "critical" ? at->urgency : std::string("normal");
    auto shown = command({"notify-send", "-a", at->app.empty() ? std::string("foxml") : at->app, "-u", urgency, "--", at->summary, at->body},
                         "here it is again", false, "Could not show that note again");
    const auto quiet = dnd_state();
    if (truth(shown, "ok") && quiet.ok && quiet.checked) shown["message"] = "it's waiting quietly · do not disturb is on";
    return shown;
}
Json clear_notes() {
    std::vector<Note> notes;
    if (!mako_notes("history", notes)) return result(false, "Earlier notes are unavailable");
    NotesLock lock;
    auto state = notes_state();
    state["cleared"] = newest_note(notes);
    return save_notes_state(state) ? result(true, "tucked away.") : result(false, "Could not put the notes away");
}
// Do not disturb from the drawer: going quiet remembers the newest note; coming back counts what arrived since.
std::string quiet_changed(bool quiet) {
    std::vector<Note> notes;
    const bool readable = mako_notes("history", notes) && mako_notes("list", notes);
    NotesLock lock;
    auto state = notes_state();
    if (quiet) {
        state["quiet_since"] = static_cast<long long>(std::time(nullptr));
        state["quiet_after"] = readable ? newest_note(notes) : 0;
        if (!readable) state.erase("quiet_since");
        save_notes_state(state);
        return {};
    }
    if (!state.contains("quiet_since") || !readable) { state.erase("quiet_since"); state.erase("quiet_after"); save_notes_state(state); return {}; }
    settle_notes_state(state, newest_note(notes));
    std::set<long long> missed;
    for (const auto& n : notes) if (n.id > number_field(state, "quiet_after")) missed.insert(n.id);
    state.erase("quiet_since"); state.erase("quiet_after");
    save_notes_state(state);
    if (missed.empty()) return {};
    const auto count = std::to_string(missed.size()) + (missed.size() == 1 ? " note" : " notes") + " while you were quiet";
    if (sh::have("notify-send")) {
        std::string ignored;
        capture({"notify-send", "-a", "foxml", "-u", "low", "--", count, "they're waiting in earlier notes, in the drawer's comfort corner"}, ignored);
    }
    return count;
}

// Claude Code sessions, from what the status line and hooks leave in foxml-claude/ beside the agent queue:
// <id>.json is the status line's latest look (model, context, plan usage, pane), <id>.state the hooks' word on
// what it is doing. A session counts while its tmux pane still runs something other than a shell, for twelve hours.
struct ClaudeSession {
    std::string id, project, title, model, state, detail, pane, root;
    int context = -1;
    // Claude Code's own title for the session when it has given one, else the folder.
    std::string name() const { return title.empty() ? project : title; }
    long long epoch = 0;
    bool fresh = false;  // its context was tidied a moment ago: the hearts sparkle
};
struct ClaudeUsage { int five = -1, week = -1; long long five_resets = 0, week_resets = 0; };
fs::path claude_dir() { return agent_queue().parent_path() / "foxml-claude"; }
int whole(const Json& object, const char* key) {
    const auto at = object.find(key);
    return at != object.end() && at->is_number() ? static_cast<int>(at->get<double>()) : -1;
}
long long stamp(const Json& object, const char* key) {
    const auto at = object.find(key);
    return at != object.end() && at->is_number() ? static_cast<long long>(at->get<double>()) : 0;
}
std::vector<ClaudeSession> claude_sessions(ClaudeUsage& usage) {
    Json shared;
    if (sh::have("desk-work") && capture_json({"desk-work", "agents"}, shared) && shared.is_array()) {
        std::vector<ClaudeSession> sessions;
        long long usage_at = 0;
        for (const auto& agent : shared) {
            if (text(agent, "agent") != "claude") continue;
            ClaudeSession session;
            session.id = text(agent, "id"); session.root = text(agent, "root"); session.project = text(agent, "project");
            session.title = text(agent, "name"); session.model = text(agent, "model", "Claude"); session.context = whole(agent, "context");
            session.state = text(agent, "state"); session.pane = text(agent, "pane"); session.epoch = stamp(agent, "at");
            session.detail = text(agent, "detail"); session.fresh = truth(agent, "fresh");
            sessions.push_back(session);
            const auto when = stamp(agent, "usageAt");
            if (when > usage_at) {
                usage_at = when;
                const auto window = [&](const char* key, int& used, long long& resets) {
                    const auto at = agent.find(key);
                    used = at != agent.end() && at->is_object() ? whole(*at, "used") : -1;
                    resets = at != agent.end() && at->is_object() ? stamp(*at, "resets") : 0;
                    if (resets > 0 && resets <= static_cast<long long>(std::time(nullptr))) used = -1;
                };
                window("five", usage.five, usage.five_resets); window("week", usage.week, usage.week_resets);
            }
        }
        return sessions;
    }
    // Compatibility when an older installation has no common work backend yet.
    std::vector<ClaudeSession> sessions;
    std::error_code ec;
    if (!directory(claude_dir())) return sessions;
    std::map<std::string, std::pair<Json, Json>> found;
    for (const auto& entry : fs::directory_iterator(claude_dir(), ec)) {
        if (!entry.is_regular_file(ec)) continue;  // edits/ and cards/ belong to the paper mod
        const auto name = entry.path().filename().string(), ext = entry.path().extension().string();
        const auto id = entry.path().stem().string();
        if ((ext != ".json" && ext != ".state") || !std::regex_match(id, std::regex("[A-Za-z0-9_-]{1,80}"))) continue;
        if (entry.file_size(ec) > 65536) continue;
        auto data = Json::parse(read(entry.path()), nullptr, false);
        if (!data.is_object()) continue;
        (ext == ".json" ? found[id].first : found[id].second) = std::move(data);
    }
    if (found.empty()) return sessions;
    std::map<std::string, std::string> panes;
    std::string output;
    const bool tmux = sh::have("tmux") && capture({"tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_current_command}"}, output);
    if (tmux) for (const auto& line : lines(output)) {
        const auto tab = line.find('\t');
        if (tab != std::string::npos) panes[line.substr(0, tab)] = line.substr(tab + 1);
    }
    static const std::set<std::string> shells = {"zsh", "bash", "fish", "sh", "dash", "nu", "tmux"};
    const long long now = static_cast<long long>(std::time(nullptr));
    long long usage_epoch = 0;
    for (const auto& [id, pair] : found) {
        const auto& [look, word] = pair;
        ClaudeSession session;
        session.id = id;
        session.epoch = std::max(stamp(look, "epoch"), stamp(word, "epoch"));
        if (session.epoch <= 0 || now - session.epoch > agent_note_lifetime) continue;
        session.pane = text(word, "pane", text(look, "pane"));
        if (!session.pane.empty()) {
            const auto pane = panes.find(session.pane);
            if (!tmux || pane == panes.end() || shells.count(pane->second)) continue;
        }
        std::string place;
        for (const auto& candidate : {text(look, "project"), text(look, "cwd"), text(word, "cwd")})
            if (place.empty()) place = candidate;
        while (place.size() > 1 && place.back() == '/') place.pop_back();
        session.project = place.empty() ? "Claude" : place == home() ? "home" : fs::path(place).filename().string();
        session.root = place;
        session.model = text(look, "model", "Claude");
        session.context = whole(look, "context");
        session.state = text(word, "state", "waiting");
        session.detail = text(word, "detail");
        session.title = text(word, "title");
        session.fresh = text(word, "detail") == "fresh" && now - stamp(word, "epoch") < 90;
        if (session.title.size() > 80 || !safe_text(session.title)) session.title.clear();
        sessions.push_back(session);
        // Plan usage is the account's, so the freshest look that has it speaks for every session.
        const auto has = [&](const char* key) { const auto at = look.find(key); return at != look.end() && at->is_object() && whole(*at, "used") >= 0; };
        if (stamp(look, "epoch") > usage_epoch && (has("five") || has("week"))) {
            usage_epoch = stamp(look, "epoch");
            const auto window = [&](const char* key, int& used, long long& resets) {
                const auto at = look.find(key);
                if (at == look.end() || !at->is_object()) { used = -1; resets = 0; return; }
                resets = stamp(*at, "resets");
                used = resets > 0 && resets <= now ? -1 : whole(*at, "used");
            };
            window("five", usage.five, usage.five_resets);
            window("week", usage.week, usage.week_resets);
        }
    }
    std::sort(sessions.begin(), sessions.end(), [](const auto& a, const auto& b) { return a.epoch > b.epoch; });
    return sessions;
}
bool claude_busy(const ClaudeSession& session) { return session.state == "working" || session.state == "compacting"; }
std::string claude_state_text(const ClaudeSession& session) {
    if (session.state == "needs") return "needs you";
    if (session.state == "error") return session.detail == "rate_limit" ? "hit a limit" : "stopped";
    return session.state;
}
std::string claude_usage_line(const ClaudeUsage& usage) {
    std::string line;
    const auto when = [](long long resets, const char* format) {
        if (resets <= 0) return std::string();
        char out[32] = {}; const std::time_t at = static_cast<std::time_t>(resets);
        std::strftime(out, sizeof out, format, std::localtime(&at));
        return lower(trim(out));
    };
    if (usage.five >= 0) line += std::to_string(usage.five) + "% of this 5h" + (usage.five >= 80 ? " · resets " + when(usage.five_resets, "%l%p") : "");
    if (usage.week >= 0) line += (line.empty() ? "" : " · ") + std::to_string(usage.week) + "% this week" + (usage.week >= 80 ? " · resets " + when(usage.week_resets, "%a") : "");
    return line;
}
// Minutes Claude spent working today, from the hooks' tally: each working or compacting stretch runs to the
// session's next change, and a stretch still open counts up to now while that session still works. It is clock
// time: sessions working side by side count once, so the day never holds more than it has had.
int claude_minutes_today(const std::vector<ClaudeSession>& live) {
    char day[16] = {}; const std::time_t now = std::time(nullptr);
    std::strftime(day, sizeof day, "%Y-%m-%d", std::localtime(&now));
    const auto tally = claude_dir() / (std::string("tally-") + day);
    std::error_code ec;
    if (!fs::is_regular_file(tally, ec) || fs::file_size(tally, ec) > 4 * 1024 * 1024) return 0;
    std::map<std::string, std::pair<std::string, long long>> open;
    std::vector<std::pair<long long, long long>> stretches;
    const auto busy = [](const std::string& state) { return state == "working" || state == "compacting"; };
    for (const auto& line : lines(read(tally))) {
        std::istringstream fields(line);
        std::string id, state; long long at = 0;
        if (!(fields >> id >> state >> at) || at <= 0) continue;
        auto found = open.find(id);
        if (found != open.end() && busy(found->second.first) && at >= found->second.second) stretches.emplace_back(found->second.second, at);
        open[id] = {state, at};
    }
    for (const auto& [id, last] : open) {
        if (!busy(last.first)) continue;
        for (const auto& session : live)
            if (session.id == id && claude_busy(session)) { stretches.emplace_back(last.second, std::max(last.second, static_cast<long long>(now))); break; }
    }
    std::sort(stretches.begin(), stretches.end());
    long long seconds = 0, from = 0, to = -1;
    for (const auto& [start, end] : stretches) {
        if (start > to) { if (to > from) seconds += to - from; from = start; to = end; }
        else to = std::max(to, end);
    }
    if (to > from) seconds += to - from;
    return static_cast<int>(seconds / 60);
}
// Today's line counts what is left: the week first, and the five hours once they run low.
std::string claude_left_line(const ClaudeUsage& usage) {
    const auto when = [](long long resets, const char* format) {
        if (resets <= 0) return std::string();
        char out[32] = {}; const std::time_t at = static_cast<std::time_t>(resets);
        std::strftime(out, sizeof out, format, std::localtime(&at));
        return lower(trim(out));
    };
    std::string line;
    if (usage.week >= 0) {
        line = std::to_string(std::max(0, 100 - usage.week)) + "% of the week left";
        const auto day = when(usage.week_resets, "%a");
        if (!day.empty()) line += " · refills " + day;
    }
    if (usage.five >= 80)
        line += (line.empty() ? "" : " · ") + std::to_string(std::max(0, 100 - usage.five)) + "% of this 5h left";
    return line;
}
// Why a pending package deserves care, or "" when it doesn't: what it touches and what to expect.
std::string update_care(const std::string& name) {
    static const std::vector<std::pair<std::regex, std::string>> rules = {
        {std::regex("linux(-lts|-zen|-hardened)?(-headers)?|linux-firmware.*"), "kernel or firmware · reboot after"},
        {std::regex("nvidia.*|.*-dkms|dkms"), "graphics driver · reboot after; a mismatch can fall back to software rendering"},
        {std::regex("mkinitcpio|dracut|systemd-boot.*|grub|efibootmgr|amd-ucode|intel-ucode"), "boot · rebuilds the boot image"},
        {std::regex("pam|pambase|libpam.*|shadow|sudo|fprintd|libfprint"), "login and sudo · keep a terminal open until you have tested sudo"},
        {std::regex("greetd.*|regreet|hyprlock"), "login or lock screen · test it before logging out"},
        {std::regex("systemd|systemd-libs|glibc|lib32-glibc"), "core system · reboot after"},
        {std::regex("hyprland|aquamarine|hyprutils|hyprlang|hyprgraphics|xdg-desktop-portal-hyprland"), "desktop compositor · log out and back in after"},
    };
    for (const auto& [pattern, why] : rules) if (std::regex_match(name, pattern)) return why;
    return "";
}
// The bar pill, in waybar's custom-module shape: ✎ busy · ◇ waiting · ! stopped; hovering lists each session.
// Workspaces whose terminal shows a Claude that waits on you: pane → tmux session → the tmux clients showing it →
// the kitty window holding that client (walking up the client's parent processes) → its workspace. Three reads,
// only while someone is waiting.
std::vector<int> waiting_workspaces(const std::vector<ClaudeSession>& sessions) {
    std::set<std::string> panes;
    for (const auto& s : sessions) if (!s.pane.empty() && !claude_busy(s) && s.state != "error") panes.insert(s.pane);
    std::vector<int> out;
    if (panes.empty() || !sh::have("tmux") || !sh::have("hyprctl")) return out;
    std::string text;
    std::set<std::string> wanted;
    if (!capture({"tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{session_name}"}, text)) return out;
    for (const auto& line : lines(text)) {
        const auto tab = line.find('\t');
        if (tab != std::string::npos && panes.count(line.substr(0, tab))) wanted.insert(line.substr(tab + 1));
    }
    std::set<long long> client_pids;
    if (wanted.empty() || !capture({"tmux", "list-clients", "-F", "#{client_session}\t#{client_pid}"}, text)) return out;
    for (const auto& line : lines(text)) {
        const auto tab = line.find('\t');
        if (tab != std::string::npos && wanted.count(line.substr(0, tab))) client_pids.insert(std::atoll(line.substr(tab + 1).c_str()));
    }
    Json clients;
    if (client_pids.empty() || !capture_json({"hyprctl", "clients", "-j"}, clients) || !clients.is_array()) return out;
    std::map<long long, int> window_workspace;
    for (const auto& c : clients)
        if (c.is_object() && c.contains("pid") && c["pid"].is_number_integer() && c.contains("workspace") && c["workspace"].is_object())
            window_workspace[c["pid"].get<long long>()] = c["workspace"].value("id", 0);
    std::set<int> found;
    for (auto pid : client_pids) {
        for (int depth = 0; depth < 8 && pid > 1; ++depth) {
            const auto at = window_workspace.find(pid);
            if (at != window_workspace.end()) { if (at->second > 0) found.insert(at->second); break; }
            const auto stat = read(fs::path("/proc") / std::to_string(pid) / "stat");
            const auto close = stat.rfind(')');
            if (close == std::string::npos) break;
            std::istringstream fields(stat.substr(close + 2));
            std::string state; long long parent = 0;
            if (!(fields >> state >> parent)) break;
            pid = parent;
        }
    }
    return std::vector<int>(found.begin(), found.end());
}
Json claude_bar() {
    ClaudeUsage usage;
    const auto sessions = claude_sessions(usage);
    int busy = 0, waiting = 0, stopped = 0;
    bool asking = false;
    for (const auto& session : sessions) {
        if (claude_busy(session)) ++busy;
        else if (session.state == "error") ++stopped;
        else { ++waiting; asking = asking || session.state == "needs"; }
    }
    // The moment the last busy session stops, every bar says so for a few seconds. Each monitor's bar polls on
    // its own, so the moment is kept in a small file beside the sessions rather than in any one bar.
    bool done = false;
    if (directory(claude_dir())) {
        const auto memo_path = claude_dir() / ".bar-memo";
        const auto memo = Json::parse(read(memo_path), nullptr, false);
        const int was = memo.is_object() ? whole(memo, "busy") : 0;
        long long until = memo.is_object() ? stamp(memo, "doneUntil") : 0;
        const long long now = static_cast<long long>(std::time(nullptr));
        if (was > 0 && busy == 0 && !sessions.empty()) until = now + 6;
        done = busy == 0 && until > now && !sessions.empty();
        if (was != busy || (memo.is_object() ? stamp(memo, "doneUntil") : 0) != until)
            write_atomic(memo_path, Json{{"busy", busy}, {"doneUntil", until}}.dump() + "\n");
    }
    std::string text = done ? "✓ all done" : "";
    if (busy) text += "✎ " + std::to_string(busy);
    if (waiting) text += (text.empty() ? "" : "  ") + std::string("◇ ") + std::to_string(waiting);
    if (stopped) text += (text.empty() ? "" : "  ") + std::string("! ") + std::to_string(stopped);
    std::string tooltip;
    size_t shown = 0;
    for (const auto& session : sessions) {
        if (shown++ == 6) { tooltip += "and " + std::to_string(sessions.size() - 6) + " more\n"; break; }
        tooltip += session.name() + " · " + session.model + (session.context >= 0 ? " · " + std::to_string(session.context) + "% context" : "")
                 + " · " + claude_state_text(session) + "\n";
    }
    const auto line = claude_usage_line(usage);
    if (!line.empty()) tooltip += line + "\n";
    if (!tooltip.empty()) tooltip.pop_back();
    Json classes = Json::array();
    if (asking) classes.push_back("asking");
    if (usage.five >= 80 || usage.week >= 80) classes.push_back("berry");
    if (stopped) classes.push_back("stopped");
    if (done) classes.push_back("done");
    Json bar{{"text", text}, {"tooltip", tooltip}, {"class", classes}};
    if (waiting) bar["pins"] = waiting_workspaces(sessions);
    return bar;
}
// The lock screen's line: what is still going on while you are away. Empty when nothing is.
std::string claude_lock_line() {
    ClaudeUsage usage;
    int busy = 0, asking = 0;
    for (const auto& session : claude_sessions(usage)) { busy += claude_busy(session); asking += session.state == "needs"; }
    std::string line;
    if (busy) line = std::to_string(busy) + " still working ✎";
    if (asking) line += (line.empty() ? "" : "  ·  ") + std::to_string(asking) + (asking == 1 ? " needs you" : " need you");
    return line;
}
// From a session row: its pane id (%N) names the place to go.
Json jump_claude(const std::string& pane) {
    if (!std::regex_match(pane, std::regex("%[0-9]{1,6}"))) return result(false, "This session is not in a tmux pane");
    if (!sh::have("tmux")) return result(false, "tmux is not installed");
    std::string target;
    if (!capture({"tmux", "display-message", "-p", "-t", pane, "#S:#I.#P"}, target)) return result(false, "The session's terminal is no longer available");
    return jump_target(trim(target));
}
// The keybind: the next session waiting on you, those asking first, the longest-waiting first. From one of
// them, the one after it, so pressing again walks the list.
Json jump_next_claude() {
    ClaudeUsage usage;
    std::vector<ClaudeSession> waiting;
    for (const auto& session : claude_sessions(usage))
        if (!session.pane.empty() && !claude_busy(session) && session.state != "error") waiting.push_back(session);
    if (waiting.empty()) return result(false, "No session is waiting on you");
    std::stable_sort(waiting.begin(), waiting.end(), [](const auto& a, const auto& b) {
        if ((a.state == "needs") != (b.state == "needs")) return a.state == "needs";
        return a.epoch < b.epoch;
    });
    std::string here;
    if (capture({"tmux", "display-message", "-p", "#{pane_id}"}, here)) here = trim(here);
    size_t at = 0;
    for (size_t i = 0; i < waiting.size(); ++i) if (waiting[i].pane == here) { at = (i + 1) % waiting.size(); break; }
    return jump_claude(waiting[at].pane);
}

volatile std::sig_atomic_t picker_stopped = 0;
void stop_picker(int) { picker_stopped = 1; }
int pick(const Args& args) {
    std::string title = "Choose a little thing";
    bool index = false, prompt = false;
    for (size_t i = 1; i < args.size(); ++i) {
        if (args[i] == "--title" && i + 1 < args.size()) title = args[++i];
        else if (args[i] == "--index") index = true;
        else if (args[i] == "--prompt") prompt = true;
        else if (args[i] == "--help") {
            std::cout << "desk-picker [--title TITLE] [--index | --prompt]\n"
                         "Reads one label per input line; Escape cancels. / searches; j/k move.\n"; return 0;
        }
        else { std::cerr << "Usage: desk-picker [--title TITLE] [--index | --prompt]\n"; return 2; }
    }
    if (!safe_text(title, 256) || (index && prompt)) return 2;
    Args labels;
    if (!prompt) {
        std::string line;
        size_t bytes = 0;
        while (std::getline(std::cin, line)) {
            bytes += line.size();
            if (labels.size() >= 10000 || bytes > 4 * 1024 * 1024 || !safe_text(line)) {
                std::cerr << "Picker input is too large\n"; return 2;
            }
            labels.push_back(line);
        }
        if (labels.empty()) return 1;
    }
    if (!sh::have("desktop-menu") || !sh::have("quickshell")) {
        std::cerr << "Install the Quickshell drawer with desk-install --only drawer\n"; return 2;
    }
    std::string pattern = (runtime() / "foxml-picker-XXXXXX").string();
    std::vector<char> name(pattern.begin(), pattern.end()); name.push_back('\0');
    if (!::mkdtemp(name.data())) return 2;
    struct Request {
        fs::path path;
        int watch = -1;
        ~Request() { if (watch >= 0) ::close(watch); std::error_code ec; fs::remove_all(path, ec); }
    } request{fs::path(name.data())};
    picker_stopped = 0;
    std::signal(SIGINT, stop_picker); std::signal(SIGTERM, stop_picker);
    const auto reply = request.path / "response.json";
    if (!write_atomic(reply, "") || !write_atomic(request.path / "request.json",
            Json{{"title", title}, {"prompt", prompt}, {"items", labels}}.dump(-1, ' ', false, Json::error_handler_t::replace))) return 2;
    request.watch = ::inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
    if (request.watch < 0 || ::inotify_add_watch(request.watch, request.path.c_str(), IN_MOVED_TO | IN_CLOSE_WRITE) < 0) return 2;
    std::string output;
    if (!capture({"desktop-menu", "--start"}, output) ||
        !capture({"quickshell", "-c", "foxml", "ipc", "call", "drawer", "pick",
                      (request.path / "request.json").string()}, output)) {
        std::cerr << "Could not open the Quickshell picker\n"; return 2;
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::minutes(15);
    while (!picker_stopped && std::chrono::steady_clock::now() < deadline) {
        const auto raw = read(reply);
        if (!raw.empty()) {
            const auto response = Json::parse(raw, nullptr, false);
            if (!response.is_object() || truth(response, "cancel")) return 1;
            if (prompt) {
                const auto value = text(response, "text");
                if (!safe_text(value) || value.empty() || value.find('\n') != std::string::npos) return 1;
                std::cout << value << '\n'; return 0;
            }
            if (!response.contains("index") || !response["index"].is_number_unsigned()) return 2;
            const auto selected = response["index"].get<size_t>();
            if (selected >= labels.size()) return 2;
            if (index) std::cout << selected << '\n'; else std::cout << labels[selected] << '\n';
            return 0;
        }
        pollfd fd{request.watch, POLLIN, 0};
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
        if (::poll(&fd, 1, static_cast<int>(std::max<int64_t>(1, remaining))) < 0 && errno != EINTR) return 2;
        char events[4096];
        while (::read(request.watch, events, sizeof(events)) > 0) {}
    }
    capture({"quickshell", "-c", "foxml", "ipc", "call", "drawer", "cancelPicker",
                 (request.path / "request.json").string()}, output);
    return 1;
}
std::vector<std::string> password_names() {
    const fs::path store = env("PASSWORD_STORE_DIR", home() + "/.password-store");
    std::vector<std::string> names;
    std::error_code ec;
    fs::recursive_directory_iterator it(store, fs::directory_options::skip_permission_denied, ec), end;
    size_t visited = 0;
    for (; !ec && it != end && visited++ < 20000; it.increment(ec)) {
        const auto path = it->path();
        if (path.filename().string().front() == '.' || it->is_symlink(ec)) {
            it.disable_recursion_pending(); continue;
        }
        if (!it->is_regular_file(ec) || path.extension() != ".gpg") continue;
        const auto name = path.lexically_relative(store).replace_extension().generic_string();
        if (safe_text(name) && name.find('\n') == std::string::npos) names.push_back(name);
        if (names.size() >= 4000) break;
    }
    std::sort(names.begin(), names.end());
    return names;
}
int sync_thunar_bookmarks();
Json toggle_bookmark(const std::string& path) {
    const auto file = bookmark_file();
    std::error_code ec;
    fs::create_directories(file.parent_path(), ec);
    if (ec) return result(false, "Could not create bookmark storage");
    const int lock = ::open((file.string() + ".lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (lock < 0) return result(false, "Could not lock bookmarks");
    if (::flock(lock, LOCK_EX) != 0) { ::close(lock); return result(false, "Could not lock bookmarks"); }
    std::vector<std::string> paths;
    bool ok = bookmarks(paths);
    bool adding = false;
    std::string message = "Bookmark storage is unreadable; it was left untouched";
    if (ok) {
        const auto at = std::find(paths.begin(), paths.end(), path);
        adding = at == paths.end();
        if (adding && paths.size() >= 16) { ok = false; message = "Your sixteen bookmark ribbons are full"; }
        else {
            if (adding) paths.push_back(path); else paths.erase(at);
            if (fs::exists(file, ec)) ok = write_atomic(file.string() + ".bak", read(file));
            if (ec) ok = false;
            if (ok) ok = write_atomic(file, Json(paths).dump(2) + "\n");
            message = ok ? (adding ? "A bookmark ribbon, saved" : "Bookmark ribbon removed") : "Could not save bookmarks";
        }
    }
    ::close(lock);
    if (ok) sync_thunar_bookmarks();
    return result(ok, message);
}
// Thunar's sidebar lists GTK bookmarks; the projects with a ribbon join them. Only the lines added here are ever
// changed or removed (they are recorded beside the ribbons), so bookmarks she made in Thunar stay hers.
std::string file_uri(const std::string& path) {
    static const char* hex = "0123456789ABCDEF";
    std::string out = "file://";
    for (const unsigned char c : path) {
        if (std::isalnum(c) || c == '/' || c == '-' || c == '_' || c == '.' || c == '~') out += static_cast<char>(c);
        else { out += '%'; out += hex[c >> 4]; out += hex[c & 15]; }
    }
    return out;
}
int sync_thunar_bookmarks() {
    std::vector<std::string> ribbons;
    if (!bookmarks(ribbons)) return 1;
    const auto gtk = config_home() / "gtk-3.0/bookmarks";
    const auto record = bookmark_file().parent_path() / "thunar-bookmarks.json";
    std::set<std::string> ours;
    const auto saved = Json::parse(read(record), nullptr, false);
    if (saved.is_array()) for (const auto& uri : saved) if (uri.is_string()) ours.insert(uri.get<std::string>());
    std::set<std::string> wanted;
    for (const auto& path : ribbons) if (directory(path)) wanted.insert(file_uri(path));
    std::vector<std::string> kept;
    std::set<std::string> present;
    for (const auto& line : lines(read(gtk))) {
        if (trim(line).empty()) continue;
        const auto uri = line.substr(0, line.find(' '));
        if (ours.count(uri) && !wanted.count(uri)) continue;  // a ribbon taken off: its line goes
        kept.push_back(line); present.insert(uri);
    }
    std::set<std::string> now_ours;
    for (const auto& path : ribbons) {
        const auto uri = file_uri(path);
        if (!wanted.count(uri)) continue;
        if (!present.count(uri)) { kept.push_back(uri + " " + fs::path(path).filename().string()); now_ours.insert(uri); }
        else if (ours.count(uri)) now_ours.insert(uri);
    }
    std::string body;
    for (const auto& line : kept) body += line + "\n";
    std::error_code ec; fs::create_directories(gtk.parent_path(), ec);
    if (body != read(gtk) && !write_atomic(gtk, body)) return 1;
    Json list = Json::array(); for (const auto& uri : now_ours) list.push_back(uri);
    return write_atomic(record, list.dump() + "\n") ? 0 : 1;
}
std::vector<Project> projects(const Json& config) {
    const auto roots = config.value("project_roots", Json::array({"~/code"}));
    std::vector<Project> found;
    std::set<std::string> seen;
    for (const auto& value : roots) {
        std::string root = value.get<std::string>();
        if (root.rfind("~/", 0) == 0) root = home() + root.substr(1);
        std::error_code ec;
        fs::directory_iterator iter(root, fs::directory_options::skip_permission_denied, ec), end;
        while (!ec && iter != end) {
            const auto entry = *iter; iter.increment(ec);
            std::error_code status;
            if (entry.is_symlink(status) || !entry.is_directory(status)) continue;
            const auto name = entry.path().filename().string();
            if (name.empty() || name.front() == '.' || !safe_text(name)) continue;
            const auto path = fs::canonical(entry.path(), status);
            if (status || !safe_text(path.string())) continue;
            std::string type;
            for (const auto& marker : std::vector<std::pair<std::string,std::string>>{
                    {"CMakeLists.txt","C++"},{"Cargo.toml","Rust"},{"package.json","JavaScript"},
                    {"pyproject.toml","Python"},{"Makefile","Make"},{"go.mod","Go"}}) {
                if (regular(path / marker.first)) { type = marker.second; break; }
            }
            const bool git = directory(path / ".git") || regular(path / ".git");
            if (!git && type.empty()) continue;
            if (!seen.insert(path.string()).second) continue;
            found.push_back({path, name, type.empty() ? "Git project" : type + (git ? " · Git" : " project")});
        }
    }
    std::sort(found.begin(), found.end(), [](const auto& a, const auto& b) { return lower(a.name) < lower(b.name); });
    return found;
}

// A git project's state, read without taking any lock another session's commit needs: "✎ dirty", "↑2 unpushed".
std::string git_badges(const fs::path& repo) {
    std::error_code ec;
    if (!fs::exists(repo / ".git", ec) || !sh::have("git")) return {};
    std::string out;
    if (!capture({"git", "--no-optional-locks", "-C", repo.string(), "status", "--porcelain=v1", "--branch",
                  "--untracked-files=no"}, out)) return {};
    std::string badges;
    const auto all = lines(out);
    bool dirty = false;
    for (size_t i = 1; i < all.size(); ++i) dirty = dirty || !trim(all[i]).empty();
    if (dirty) badges += "✎ dirty";
    if (!all.empty()) {
        static const std::regex ahead("\\[ahead ([0-9]+)");
        std::smatch m;
        if (std::regex_search(all[0], m, ahead)) badges += (badges.empty() ? "" : " · ") + ("↑" + m[1].str() + " unpushed");
    }
    return badges;
}
Json project_card(const Project& project, bool pinned) {
    std::string location = project.path.string();
    if (location.rfind(home() + "/", 0) == 0) location = "~" + location.substr(home().size());
    const auto badges = git_badges(project.path);
    auto row = item("project-open", project.name, "action", project.type + " · " + location + (badges.empty() ? "" : " · " + badges), "▤");
    if (!badges.empty()) row["git"] = badges;
    static const auto sessions = [] { ClaudeUsage usage; return claude_sessions(usage); }();
    int open = 0;
    for (const auto& s : sessions) if (s.root == project.path.string() || s.root.rfind(project.path.string() + "/", 0) == 0) ++open;
    if (open > 1) row["detail"] = text(row, "detail") + " · also open in " + std::to_string(open) + " sessions";
    row["argument"] = project.path.string(); row["close"] = true;
    row["presentation"] = "project"; row["bookmarked"] = pinned;
    return row;
}

// ── Displays: scale, rotation, side and pointer size, applied live with a 15 s keep-or-go-back ──
namespace placement = desk_monitor::placement;
// `mode` is empty until a change picks a new one ("2560x1440@59.95"); `modes` are the ones the screen offers.
struct LiveScreen {
    std::string name, model, make, mode; int width = 0, height = 0, x = 0, y = 0, scale = 100, transform = 0, id = -1;
    double refresh = 0; std::vector<std::string> modes;
};
fs::path hypr_modules() { return config_home() / "hypr/modules"; }
fs::path display_pending() { return runtime() / "foxml/display-pending"; }
// 15 s; tests shorten it with FOXML_DISPLAY_REVERT_SECONDS (0-60).
int display_revert_wait() {
    const auto value = env("FOXML_DISPLAY_REVERT_SECONDS", "15");
    return value.size() <= 2 && !value.empty() && std::all_of(value.begin(), value.end(), ::isdigit) ? std::min(60, std::stoi(value)) : 15;
}
std::vector<LiveScreen> live_screens() {
    std::vector<LiveScreen> out;
    Json monitors;
    if (!sh::have("hyprctl") || !capture_json({"hyprctl", "monitors", "-j"}, monitors) || !monitors.is_array()) return out;
    for (const auto& m : monitors) {
        if (!m.is_object() || truth(m, "disabled")) continue;
        LiveScreen s;
        s.name = text(m, "name"); s.model = text(m, "model", text(m, "description")); s.make = text(m, "make");
        if (m.contains("refreshRate") && m["refreshRate"].is_number()) s.refresh = m["refreshRate"].get<double>();
        static const std::regex offered(R"((\d{3,5})x(\d{3,5})@(\d{2,3}(?:\.\d{1,3})?)Hz)");
        if (m.contains("availableModes") && m["availableModes"].is_array())
            for (const auto& mode : m["availableModes"]) {
                std::smatch f; const auto value = mode.is_string() ? mode.get<std::string>() : std::string();
                if (!std::regex_match(value, f, offered)) continue;
                const auto plain = f[1].str() + "x" + f[2].str() + "@" + f[3].str();
                if (std::find(s.modes.begin(), s.modes.end(), plain) == s.modes.end()) s.modes.push_back(plain);
            }
        s.width = m.value("width", 0); s.height = m.value("height", 0);
        s.x = m.value("x", 0); s.y = m.value("y", 0);
        s.scale = placement::to_x100(m.value("scale", 1.0)); s.transform = m.value("transform", 0);
        if (m.contains("id") && m["id"].is_number_integer()) s.id = m["id"].get<int>();
        if (std::regex_match(s.name, std::regex("[A-Za-z0-9_.:-]{1,64}")) && s.width > 0 && s.height > 0) out.push_back(s);
    }
    return out;
}
placement::Box live_box(const LiveScreen& s) {
    auto box = placement::logical({s.name, s.width, s.height, s.scale, s.transform, "", ""});
    box.x = s.x; box.y = s.y; return box;
}
std::string primary_of(const std::vector<LiveScreen>& screens) {
    static const std::regex line(R"re(^\s*PRIMARY="?([A-Za-z0-9_.:-]+)"?\s*$)re");
    for (const auto& l : lines(read(config_home() / "foxml/monitor-layout.conf"))) {
        std::smatch m;
        if (!std::regex_match(l, m, line)) continue;
        for (const auto& s : screens) if (s.name == m[1].str()) return s.name;
    }
    for (const auto& s : screens) if (s.x == 0 && s.y == 0) return s.name;
    return screens.empty() ? std::string() : screens.front().name;
}
std::string orientation(int transform) {
    if (transform == 3) return "portrait, turned left";
    if (transform == 1) return "portrait, turned right";
    if (transform == 2) return "upside down";
    return transform == 0 ? "landscape" : "flipped";
}
// "Acer B277K L", "Dell P2419H", "Laptop screen": the make's first word, unless the model already says it.
std::string screen_label(const LiveScreen& s) {
    if (s.name.rfind("eDP", 0) == 0 || s.name.rfind("LVDS", 0) == 0 || s.name.rfind("DSI", 0) == 0) return "Laptop screen";
    if (s.model.empty()) return s.name;
    std::string brand = s.make.substr(0, s.make.find(' '));
    auto lower = [](std::string v) { for (auto& c : v) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c))); return v; };
    const auto first = s.model.substr(0, s.model.find(' '));
    if (!brand.empty() && lower(first) == lower(brand)) return brand + s.model.substr(first.size());
    return brand.empty() ? s.model : brand + " " + s.model;
}
// "60 Hz", "59.94 Hz".
std::string hertz(double rate) {
    char out[16]; std::snprintf(out, sizeof out, "%.2f", rate);
    std::string text = out;
    while (text.back() == '0') text.pop_back();
    if (text.back() == '.') text.pop_back();
    return text + " Hz";
}
// The scale that keeps text closest to its size now, among the even ones for a mode.
int nearest_scale(const std::vector<int>& steps, int scale) {
    int best = steps.empty() ? scale : steps.front();
    for (int step : steps) if (std::abs(step - scale) < std::abs(best - scale)) best = step;
    return best;
}
// "NAME=VALUE" from a screen page's control.
bool screen_and_value(const std::string& arg, std::string& name, std::string& value) {
    const auto at = arg.find('=');
    if (at == std::string::npos || at == 0 || at + 1 >= arg.size()) return false;
    name = arg.substr(0, at); value = arg.substr(at + 1);
    return std::regex_match(name, std::regex("[A-Za-z0-9_.:-]{1,64}")) && std::regex_match(value, std::regex("[A-Za-z0-9.@-]{1,24}"));
}
// Every non-primary screen keeps its side; screens sharing a side chain outward in their live order.
std::map<std::string, placement::Box> arrange(const std::vector<LiveScreen>& screens, const std::string& primary,
                                              std::map<std::string, std::string> sides = {}) {
    const auto first = std::find_if(screens.begin(), screens.end(), [&](const LiveScreen& s) { return s.name == primary; });
    if (first == screens.end()) return {};
    const auto primary_box = live_box(*first);
    std::vector<std::pair<long, placement::Screen>> others;
    for (const auto& s : screens) {
        if (s.name == primary) continue;
        const auto box = live_box(s);
        const auto side = sides.count(s.name) ? sides[s.name] : placement::side_of(primary_box, box);
        const long distance = side == "left" ? -box.x : side == "right" ? box.x : side == "above" ? -box.y : box.y;
        others.push_back({distance, {s.name, s.width, s.height, s.scale, s.transform, side, ""}});
    }
    std::stable_sort(others.begin(), others.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    std::map<std::string, std::string> last_on_side;
    std::vector<placement::Screen> ordered;
    for (auto& [distance, screen] : others) {
        (void)distance;
        screen.anchor = last_on_side.count(screen.side) ? last_on_side[screen.side] : std::string();
        last_on_side[screen.side] = screen.name;
        ordered.push_back(screen);
    }
    return placement::place({first->name, first->width, first->height, first->scale, first->transform, "", ""}, ordered);
}
bool copy_text(const fs::path& from, const fs::path& to) { return regular(from) && write_atomic(to, read(from)); }
std::string display_token() {
    std::ifstream random("/dev/urandom", std::ios::binary);
    std::array<unsigned char, 16> bytes{};
    random.read(reinterpret_cast<char*>(bytes.data()), bytes.size());
    std::ostringstream out;
    for (auto b : bytes) out << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(b);
    return out.str();
}
// Wallpapers and the monitor sidecar follow the new layout.
void display_settled() {
    if (sh::have("desk-monitor")) launch({"desk-monitor", "reconcile"}, "");
}
Json restore_displays(const std::string& message) {
    const auto dir = hypr_modules();
    bool ok = false;
    for (const char* name : {"monitors.conf", "monitors.lua"})
        if (regular(dir / (std::string(name) + ".foxml-prev"))) ok = copy_text(dir / (std::string(name) + ".foxml-prev"), dir / name) || ok;
    std::error_code ec; fs::remove(display_pending(), ec);
    if (!ok) return result(false, "No earlier display layout is saved");
    std::string ignored; capture({"hyprctl", "reload"}, ignored);
    display_settled();
    return result(true, message);
}
// Writes the new layout to monitors.conf and monitors.lua (the first change of a round saves the
// current files as .foxml-prev), reloads Hyprland and starts the timer that goes back unless kept.
Json apply_displays(const std::vector<LiveScreen>& screens, const std::string& primary,
                    const std::map<std::string, std::string>& sides, const std::string& message) {
    const auto boxes = arrange(screens, primary, sides);
    if (boxes.empty()) return result(false, "Could not read the screens from Hyprland");
    const auto dir = hypr_modules();
    const auto conf_path = dir / "monitors.conf", lua_path = dir / "monitors.lua";
    if (!regular(lua_path) && !regular(conf_path)) return result(false, "No monitors.lua to change; run the installer's monitor step first");
    std::string conf = read(conf_path), lua = read(lua_path);
    for (const auto& s : screens) {
        const auto box = boxes.find(s.name);
        if (box == boxes.end()) continue;
        const auto position = s.name == primary ? std::string("0x0") : placement::position_text(box->second);
        const auto scale = placement::scale_text(s.scale);
        if (regular(conf_path)) conf = placement::set_conf_rule(conf, s.name, position, scale, s.transform, s.mode);
        if (regular(lua_path)) lua = placement::set_lua_rule(lua, s.name, position, scale, s.transform, s.mode);
    }
    if (!regular(display_pending())) {
        for (const auto& path : {conf_path, lua_path})
            if (regular(path) && !copy_text(path, path.string() + ".foxml-prev")) return result(false, "Could not save the current layout first");
    }
    if ((regular(conf_path) && !write_atomic(conf_path, conf)) || (regular(lua_path) && !write_atomic(lua_path, lua)))
        return result(false, "Could not write the new layout");
    std::error_code ec; fs::create_directories(display_pending().parent_path(), ec);
    const auto token = display_token();
    if (!write_atomic(display_pending(), token)) return restore_displays("Could not start the safety timer, so the layout went back");
    std::string ignored; capture({"hyprctl", "reload"}, ignored);
    const auto self = fs::read_symlink("/proc/self/exe", ec);
    if (ec || !truth(launch({self.string(), "display-revert", token}, ""), "ok"))
        return restore_displays("Could not start the safety timer, so the layout went back");
    return result(true, message + " · Keep this layout, or it goes back in " + std::to_string(display_revert_wait()) + "s");
}
int display_revert(const std::string& token) {
    if (!std::regex_match(token, std::regex("[0-9a-f]{32}"))) return 2;
    std::this_thread::sleep_for(std::chrono::seconds(display_revert_wait()));
    std::string current = read(display_pending());
    while (!current.empty() && std::isspace(static_cast<unsigned char>(current.back()))) current.pop_back();
    if (current != token) return 0;
    const auto done = restore_displays("Display layout went back");
    if (sh::have("notify-send"))
        sh::run({"notify-send", "-a", "Displays", truth(done, "ok") ? "Display layout went back" : "Display layout could not go back",
                 truth(done, "ok") ? "It was not kept in time." : "Restore monitors.lua.foxml-prev in ~/.config/hypr/modules."});
    return truth(done, "ok") ? 0 : 1;
}
int cursor_size() {
    static const std::regex size(R"re(XCURSOR_SIZE"\s*,\s*"(\d{2}))re");
    std::smatch m;
    const auto local = read(hypr_modules() / "local.lua");
    if (std::regex_search(local, m, size)) return std::stoi(m[1].str());
    const auto from_env = env("XCURSOR_SIZE", "30");
    return std::all_of(from_env.begin(), from_env.end(), ::isdigit) && !from_env.empty() && from_env.size() < 3 ? std::stoi(from_env) : 30;
}
Json set_cursor_size(int size) {
    static const std::string begin = "-- foxml:cursor-size-begin", end = "-- foxml:cursor-size-end";
    const auto path = hypr_modules() / "local.lua";
    std::string body = read(path);
    const std::string block = begin + "\nhl.env(\"XCURSOR_SIZE\", \"" + std::to_string(size) + "\")\nhl.env(\"HYPRCURSOR_SIZE\", \""
                              + std::to_string(size) + "\")\n" + end + "\n";
    const auto a = body.find(begin), b = body.find(end);
    if (a != std::string::npos && b != std::string::npos && b > a) body.replace(a, b + end.size() + 1 - a, block);
    else body = (body.empty() ? std::string("-- This machine's own Hyprland settings, loaded after the theme's modules.\n") : body
                 + (body.back() == '\n' ? "" : "\n")) + block;
    if (!write_atomic(path, body)) return result(false, "Could not save the pointer size");
    std::string ignored;
    const auto theme = env("XCURSOR_THEME", "default");
    if (sh::have("hyprctl")) capture({"hyprctl", "setcursor", theme, std::to_string(size)}, ignored);
    if (sh::have("gsettings")) capture({"gsettings", "set", "org.gnome.desktop.interface", "cursor-size", std::to_string(size)}, ignored);
    auto done = result(true, "Pointer size " + std::to_string(size) + " · apps opened from now on use it too");
    done["close"] = false; return done;
}
// Where each screen sits, said from the main screen: "main screen", "left screen", "top screen". One screen needs no words.
std::map<int, std::string> screen_places() {
    std::map<int, std::string> places;
    const auto screens = live_screens();
    if (screens.size() < 2) return places;
    const auto primary = primary_of(screens);
    const auto main_screen = std::find_if(screens.begin(), screens.end(), [&](const LiveScreen& s) { return s.name == primary; });
    if (main_screen == screens.end()) return places;
    const auto main_box = live_box(*main_screen);
    for (const auto& s : screens) {
        if (s.id < 0) continue;
        if (s.name == primary) { places[s.id] = "main screen"; continue; }
        const auto side = placement::side_of(main_box, live_box(s));
        places[s.id] = (side == "above" ? std::string("top") : side == "below" ? std::string("bottom") : side) + " screen";
    }
    return places;
}
std::string window_place(const Json& client, const std::map<int, std::string>& places) {
    std::string where;
    if (const auto ws = client.find("workspace"); ws != client.end() && ws->is_object()) {
        const auto name = text(*ws, "name");
        const int id = ws->contains("id") && (*ws)["id"].is_number_integer() ? (*ws)["id"].get<int>() : 0;
        if (id < 0 || name.rfind("special", 0) == 0) where = "tucked in the scratchpad";
        else if (!name.empty() && name != std::to_string(id) && safe_text(name, 64)) where = "workspace " + name;
        else if (id > 0) where = "workspace " + std::to_string(id);
    }
    if (const auto monitor = client.find("monitor"); monitor != client.end() && monitor->is_number_integer()) {
        const auto place = places.find(monitor->get<int>());
        if (place != places.end()) where += (where.empty() ? "" : " · ") + place->second;
    }
    return where;
}
// A slider that moves stop by stop and changes nothing until Enter: each stop's value, label and what it gives.
Json stop_slider(const std::string& id, const std::string& label, const std::string& detail, const std::string& argument,
                 const std::vector<std::pair<int, std::pair<std::string, std::string>>>& stops, int current, const std::string& icon) {
    auto row = item(id, label, "slider", detail, icon);
    row["argument"] = argument;
    row["stops"] = Json::array();
    int at = 0;
    for (size_t i = 0; i < stops.size(); ++i) {
        row["stops"].push_back(Json{{"value", stops[i].first}, {"label", stops[i].second.first}, {"detail", stops[i].second.second}});
        if (stops[i].first == current) at = static_cast<int>(i);
    }
    row["stop"] = at;
    row["value"] = stops.size() > 1 ? at * 100.0 / static_cast<double>(stops.size() - 1) : 100.0;
    return row;
}
void display_pending_rows(Json& rows) {
    if (!regular(display_pending())) return;
    std::error_code ec;
    const auto age = std::chrono::duration_cast<std::chrono::seconds>(fs::file_time_type::clock::now() - fs::last_write_time(display_pending(), ec)).count();
    const auto left = std::max<long long>(0, display_revert_wait() - age);
    rows.push_back(item("display-keep", "Keep this layout", "action", "Otherwise it goes back in " + std::to_string(left) + "s", "today"));
    rows.push_back(item("display-undo", "Go back now", "action", "Restore the layout from before", "refresh"));
}
// "left of the laptop", "above the laptop".
std::string side_words(const std::string& side, const std::string& of) {
    return side + (side == "above" || side == "below" ? " " : " of ") + of;
}
std::string screen_place(const LiveScreen& s, const std::vector<LiveScreen>& screens, const std::string& primary) {
    if (s.name == primary) return screens.size() > 1 ? "main screen" : "";
    const auto main_screen = std::find_if(screens.begin(), screens.end(), [&](const LiveScreen& o) { return o.name == primary; });
    if (main_screen == screens.end()) return "";
    const auto label = screen_label(*main_screen);
    return side_words(placement::side_of(live_box(*main_screen), live_box(s)), label == "Laptop screen" ? std::string("the laptop") : label);
}
// The Displays page: a card per screen, then what applies to every screen.
void display_rows(Json& rows) {
    const auto screens = live_screens();
    if (screens.empty()) {
        rows.push_back(item("display-edit", "Screens are unavailable", "action", "Hyprland did not answer · open monitors.lua instead", "system"));
        return;
    }
    display_pending_rows(rows);
    const auto primary = primary_of(screens);
    rows.push_back(heading("screens"));
    for (const auto& s : screens) {
        std::string detail = (placement::sideways(s.transform) ? "portrait · " : "landscape · ") + std::to_string(s.scale) + "%";
        const auto place = screen_place(s, screens, primary);
        if (!place.empty()) detail += " · " + place;
        auto card = item("display-screen", screen_label(s), "page", detail, "window");
        card["page"] = "display"; card["scope"] = s.name; card["argument"] = s.name;
        rows.push_back(card);
    }
    rows.push_back(heading("everywhere"));
    const int size = cursor_size();
    std::vector<std::pair<int, std::pair<std::string, std::string>>> pointer;
    for (int stop : {24, 30, 36, 42, 48}) pointer.push_back({stop, {std::to_string(stop), stop == 30 ? "the usual size" : stop > 30 ? "easier to find" : "smaller"}});
    rows.push_back(stop_slider("cursor-size", "Pointer size", "smaller ← → bigger · now " + std::to_string(size), "pointer", pointer, size, "comfort"));
    rows.push_back(item("display-edit", "Edit monitors.lua", "action", "Open the screen rules in Neovim · Hyprland applies them on save", "gear"));
    if (!regular(display_pending()) && regular(hypr_modules() / "monitors.lua.foxml-prev"))
        rows.push_back(item("display-undo", "Undo the last display change", "action", "Restore the layout saved before it", "refresh"));
}
// One screen's own page: its size, how it is turned, where it sits, and its mode.
bool screen_rows(const std::string& name, Json& rows, Json& out) {
    const auto screens = live_screens();
    const auto found = std::find_if(screens.begin(), screens.end(), [&](const LiveScreen& s) { return s.name == name; });
    if (found == screens.end()) return false;
    const auto& s = *found;
    const auto primary = primary_of(screens);
    out["title"] = screen_label(s);
    display_pending_rows(rows);
    rows.push_back(heading("size"));
    std::vector<std::pair<int, std::pair<std::string, std::string>>> sizes;
    for (int step : placement::scales_for(s.width, s.height)) {
        const auto box = placement::logical({s.name, s.width, s.height, step, s.transform, "", ""});
        sizes.push_back({step, {std::to_string(step) + "%", "fits like " + std::to_string(box.w) + "×" + std::to_string(box.h)}});
    }
    rows.push_back(stop_slider("display-scale", "Text and windows", "smaller ← → bigger · now " + std::to_string(s.scale) + "%",
                               s.name, sizes, s.scale, "search"));
    rows.push_back(heading("rotation"));
    for (const auto& [turn, label] : std::vector<std::pair<int, std::string>>{{0, "Landscape"}, {3, "Portrait, turned left"},
                                                                            {1, "Portrait, turned right"}, {2, "Upside down"}}) {
        auto row = item("display-rotate", label, "action", s.transform == turn ? "In use" : "", "refresh");
        row["argument"] = s.name + "=" + std::to_string(turn); row["checked"] = s.transform == turn; rows.push_back(row);
    }
    if (s.name != primary) {
        const auto main_screen = std::find_if(screens.begin(), screens.end(), [&](const LiveScreen& o) { return o.name == primary; });
        const auto now = placement::side_of(live_box(*main_screen), live_box(s));
        const auto label = screen_label(*main_screen);
        const auto of = label == "Laptop screen" ? std::string("the laptop") : label;
        rows.push_back(heading("side"));
        for (const char* side : {"left", "right", "above", "below"}) {
            auto words = side_words(side, of); words[0] = static_cast<char>(std::toupper(static_cast<unsigned char>(words[0])));
            auto row = item("display-side", words, "action",
                            now == side ? "In use" : "", "next");
            row["argument"] = s.name + "=" + side; row["checked"] = now == side; rows.push_back(row);
        }
    }
    rows.push_back(heading("mode"));
    auto mode = item("display-modes", std::to_string(s.width) + "×" + std::to_string(s.height) + " at " + hertz(s.refresh), "page",
                     "Resolution and refresh rate · " + std::to_string(s.modes.size()) + " to choose from", "system");
    mode["page"] = "display-modes"; mode["scope"] = s.name; rows.push_back(mode);
    if (s.name == primary || screens.size() < 2) rows.push_back(item("display-edit", "Edit monitors.lua", "action", "Open the screen rules in Neovim", "gear"));
    return true;
}
bool mode_rows(const std::string& name, Json& rows, Json& out) {
    const auto screens = live_screens();
    const auto found = std::find_if(screens.begin(), screens.end(), [&](const LiveScreen& s) { return s.name == name; });
    if (found == screens.end()) return false;
    const auto& s = *found;
    out["title"] = screen_label(s) + " · mode";
    display_pending_rows(rows);
    static const std::regex parts(R"((\d+)x(\d+)@([\d.]+))");
    bool marked = false;
    for (size_t i = 0; i < s.modes.size(); ++i) {
        std::smatch f;
        if (!std::regex_match(s.modes[i], f, parts)) continue;
        const bool current = !marked && std::stoi(f[1].str()) == s.width && std::stoi(f[2].str()) == s.height && std::abs(std::stod(f[3].str()) - s.refresh) < 0.5;
        marked = marked || current;
        auto row = item("display-mode", f[1].str() + "×" + f[2].str() + " · " + hertz(std::stod(f[3].str())), "action",
                        current ? "In use" : i == 0 ? "The screen's own best mode" : "", "system");
        row["argument"] = s.name + "=" + s.modes[i]; row["checked"] = current; rows.push_back(row);
    }
    if (s.modes.empty()) rows.push_back(item("display-edit", "This screen lists no modes", "action", "Open monitors.lua to set one by hand", "gear"));
    return true;
}
Json display_action(const std::string& id, const std::string& arg) {
    if (id == "display-keep") {
        std::error_code ec;
        if (!fs::remove(display_pending(), ec)) return result(false, "Nothing is waiting to be kept");
        display_settled();
        auto done = result(true, "Layout kept"); done["close"] = false; return done;
    }
    if (id == "display-undo") { auto done = restore_displays("Layout restored"); done["close"] = false; return done; }
    if (id == "display-edit") {
        const auto file = hypr_modules() / "monitors.lua";
        return terminal({"nvim", (regular(file) ? file : hypr_modules() / "monitors.conf").string()}, "Screen rules opened");
    }
    if (id == "cursor-size") {
        static const std::set<std::string> sizes{"24", "30", "36", "42", "48"};
        std::string name, value;
        if (!screen_and_value(arg, name, value) || name != "pointer" || !sizes.count(value)) return result(false, "That pointer size is not offered");
        return set_cursor_size(std::stoi(value));
    }
    std::string name, value;
    if (!screen_and_value(arg, name, value)) return result(false, "Choose a screen and a setting");
    auto screens = live_screens();
    const auto screen = std::find_if(screens.begin(), screens.end(), [&](const LiveScreen& s) { return s.name == name; });
    if (screen == screens.end()) return result(false, "That screen is no longer connected");
    const auto primary = primary_of(screens);
    // Sides come from the layout as it is now, so every screen keeps its side and is placed again from its new size.
    std::map<std::string, std::string> sides;
    const auto& main_screen = *std::find_if(screens.begin(), screens.end(), [&](const LiveScreen& s) { return s.name == primary; });
    const auto main_box = live_box(main_screen);
    for (const auto& s : screens) if (s.name != primary) sides[s.name] = placement::side_of(main_box, live_box(s));
    const auto label = screen_label(*screen);
    std::string message;
    if (id == "display-scale") {
        const auto steps = placement::scales_for(screen->width, screen->height);
        if (!std::regex_match(value, std::regex("\\d{2,3}")) || std::find(steps.begin(), steps.end(), std::stoi(value)) == steps.end())
            return result(false, "That size does not fit this screen evenly");
        if (std::stoi(value) == screen->scale) return result(false, "Already at that size");
        screen->scale = std::stoi(value);
        message = label + " at " + value + "%";
    } else if (id == "display-rotate") {
        if (value != "0" && value != "1" && value != "2" && value != "3") return result(false, "Unknown rotation");
        if (std::stoi(value) == screen->transform) return result(false, "Already turned that way");
        screen->transform = std::stoi(value);
        message = label + " " + orientation(screen->transform);
    } else if (id == "display-side") {
        if (screen->name == primary) return result(false, "The main screen stays where it is");
        if (value != "left" && value != "right" && value != "above" && value != "below") return result(false, "Unknown side");
        if (sides[screen->name] == value) return result(false, "Already on that side");
        sides[screen->name] = value;
        message = label + " moved " + value;
    } else if (id == "display-mode") {
        if (std::find(screen->modes.begin(), screen->modes.end(), value) == screen->modes.end()) return result(false, "This screen does not offer that mode");
        std::smatch f; const std::regex parts(R"((\d+)x(\d+)@([\d.]+))");
        std::regex_match(value, f, parts);
        screen->width = std::stoi(f[1].str()); screen->height = std::stoi(f[2].str()); screen->mode = value;
        const int before = screen->scale;
        screen->scale = nearest_scale(placement::scales_for(screen->width, screen->height), screen->scale);
        message = label + " at " + f[1].str() + "×" + f[2].str() + ", " + hertz(std::stod(f[3].str()))
                  + (screen->scale != before ? " · size " + std::to_string(screen->scale) + "% so it stays sharp" : "");
    } else return result(false, "Unknown display action");
    auto done = apply_displays(screens, primary, sides, message);
    done["close"] = false; return done;
}

// ── Screens coming and going: workspaces return to the screen they lived on, and a screen never arranged says so ──
fs::path workspace_homes_file() { return fs::path(env("XDG_STATE_HOME", home() + "/.local/state")) / "foxml/workspace-homes.json"; }
struct LiveWorkspace { std::string name, monitor; };
std::vector<LiveWorkspace> live_workspaces() {
    std::vector<LiveWorkspace> out;
    Json list;
    if (!sh::have("hyprctl") || !capture_json({"hyprctl", "workspaces", "-j"}, list) || !list.is_array()) return out;
    for (const auto& w : list) {
        if (!w.is_object() || w.value("id", 0) <= 0) continue;  // special workspaces have no home screen
        const auto name = text(w, "name"), monitor = text(w, "monitor");
        if (std::regex_match(name, std::regex("[A-Za-z0-9_.:-]{1,32}")) && std::regex_match(monitor, std::regex("[A-Za-z0-9_.:-]{1,64}")))
            out.push_back({name, monitor});
    }
    return out;
}
// The screen each workspace lives on. A workspace whose screen is unplugged keeps that home, and so does one
// whose screen came back within the last 15 s: Hyprland's focus events can arrive before the move home does.
int workspaces_remember() {
    const auto screens = live_screens();
    if (screens.empty()) return 0;
    auto saved = Json::parse(read(workspace_homes_file()), nullptr, false);
    if (!saved.is_object()) saved = Json::object();
    Json homes = saved.value("homes", Json::object()), seen = saved.value("seen", Json::object());
    if (!homes.is_object()) homes = Json::object();
    if (!seen.is_object()) seen = Json::object();
    const auto now = static_cast<long long>(std::time(nullptr));
    Json connected = Json::object();
    for (const auto& s : screens) connected[s.name] = seen.contains(s.name) && seen[s.name].is_number_integer() ? seen[s.name] : Json(now);
    for (const auto& w : live_workspaces()) {
        const auto home_screen = homes.contains(w.name) && homes[w.name].is_string() ? homes[w.name].get<std::string>() : std::string();
        const bool away = !home_screen.empty() && !connected.contains(home_screen);
        const bool returning = !home_screen.empty() && connected.contains(home_screen) && now - connected[home_screen].get<long long>() < 15;
        if (!away && !returning) homes[w.name] = w.monitor;
    }
    while (homes.size() > 64) homes.erase(homes.begin());
    const Json next{{"homes", homes}, {"seen", connected}};
    if (next == saved) return 0;
    std::error_code ec; fs::create_directories(workspace_homes_file().parent_path(), ec);
    return write_atomic(workspace_homes_file(), next.dump() + "\n") ? 0 : 1;
}
bool screen_has_rule(const std::string& name) {
    const auto lua = read(hypr_modules() / "monitors.lua");
    for (const auto& line : lines(lua))
        if (line.find("hl.monitor(") != std::string::npos && line.find("output = \"" + name + "\"") != std::string::npos
            && line.find("--") > line.find("hl.monitor(")) return true;
    for (const auto& line : lines(read(hypr_modules() / "monitors.conf"))) {
        std::smatch m;
        if (std::regex_match(line, m, std::regex(R"(^\s*monitor\s*=\s*([^,\s]+)\s*,.*)")) && m[1].str() == name) return true;
    }
    return false;
}
// After screens change: workspaces go home, and a screen with no saved rule gets one notice that opens its page.
int screens_changed() {
    const auto screens = live_screens();
    if (screens.empty()) return 0;
    std::set<std::string> connected;
    for (const auto& s : screens) connected.insert(s.name);
    const auto saved = Json::parse(read(workspace_homes_file()), nullptr, false);
    const auto homes = saved.is_object() ? saved.value("homes", Json::object()) : Json::object();
    for (const auto& w : live_workspaces()) {
        if (!homes.is_object() || !homes.contains(w.name) || !homes[w.name].is_string()) continue;
        const auto home_screen = homes[w.name].get<std::string>();
        if (home_screen == w.monitor || !connected.count(home_screen) || !std::regex_match(home_screen, std::regex("[A-Za-z0-9_.:-]{1,64}"))) continue;
        std::string ignored;
        capture({"hyprctl", "dispatch", "hl.dsp.workspace.move({ workspace = \"" + w.name + "\", monitor = \"" + home_screen + "\" })"}, ignored);
    }
    workspaces_remember();
    // Which screens were here last time; the first run after login only records them.
    const auto seen_file = runtime() / "foxml/screens-seen";
    const bool first = !regular(seen_file);
    std::set<std::string> before;
    for (const auto& line : lines(read(seen_file))) if (!trim(line).empty()) before.insert(trim(line));
    std::string body;
    for (const auto& name : connected) body += name + "\n";
    std::error_code ec; fs::create_directories(seen_file.parent_path(), ec);
    write_atomic(seen_file, body);
    if (first) return 0;
    for (const auto& s : screens) {
        if (before.count(s.name) || screen_has_rule(s.name) || !sh::have("notify-send")) continue;
        launch({"/bin/sh", "-c", "a=$(notify-send -a Displays -c foxml.work -A default=Arrange --wait \"$2 connected\" "
                            "'Arrange it: size, rotation and which side') && [ \"$a\" = default ] && "
                            "exec \"$HOME/.local/bin/desktop-menu\" --open display --scope \"$1\"",
                "sh", s.name, screen_label(s)}, "");
    }
    return 0;
}

Json api_history() {
    Json history;
    Json out = Json::array();
    if (!sh::have("claude-api") || !capture_json({"claude-api", "history"}, history) || !history.is_array()) return out;
    for (const auto& task : history)
        if (task.is_object() && std::regex_match(text(task, "id"), std::regex("[0-9a-f]{32}"))) out.push_back(task);
    return out;
}
Json api_projects() {
    Json projects;
    if (!sh::have("claude-api") || !capture_json({"claude-api", "projects"}, projects) || !projects.is_array()) return Json::array();
    return projects;
}
// The API project whose folder holds this path, or "" (failures elsewhere get no API row).
std::string api_project_for(const Json& projects, const std::string& path) {
    for (const auto& p : projects) {
        const auto root = text(p, "root");
        if (!root.empty() && (path == root || path.rfind(root + "/", 0) == 0)) return text(p, "id");
    }
    return {};
}
// ── While you were away: desk-lock stamps the moment the screen locks (which Claudes were working) and, once
// unlocked, one quiet note says what happened meanwhile. Both run detached from desk-lock, so a slow read can
// never hold the lock or the unlock. The stamp lives in $XDG_RUNTIME_DIR/foxml/away.json (0600).
fs::path away_file() { return runtime() / "foxml/away.json"; }
int away_start() {
    std::error_code ec;
    fs::create_directories(away_file().parent_path(), ec);
    fs::permissions(away_file().parent_path(), fs::perms::owner_all, fs::perm_options::replace, ec);
    ClaudeUsage usage;
    Json busy = Json::array();
    for (const auto& session : claude_sessions(usage)) if (claude_busy(session)) busy.push_back(session.id);
    return write_atomic(away_file(), Json{{"at", static_cast<long long>(std::time(nullptr))}, {"busy", busy}}.dump()) ? 0 : 1;
}
// The note's one line, from what was true at the lock and what is true now.
std::string away_line(const Json& stamp, const std::vector<ClaudeSession>& now, const Json& jobs, int commits) {
    const long long since = stamp.value("at", 0LL);
    std::set<std::string> was_busy;
    for (const auto& id : stamp.value("busy", Json::array())) if (id.is_string()) was_busy.insert(id.get<std::string>());
    int done = 0, needs = 0;
    for (const auto& s : now) {
        if (was_busy.count(s.id) && !claude_busy(s)) ++done;
        if (s.state == "needs") ++needs;
    }
    int passed = 0, failed = 0; std::string only;
    for (const auto& j : jobs) {
        if (!j.is_object() || !j.contains("ended") || !j["ended"].is_number_integer() || j["ended"].get<long long>() < since) continue;
        const auto state = text(j, "state");
        if (state == "passed") ++passed; else if (state == "failed") ++failed; else continue;
        only = text(j, "title", text(j, "command")) + (state == "passed" ? " passed" : " failed");
    }
    std::vector<std::string> parts;
    if (done) parts.push_back(std::to_string(done) + " done ✓");
    if (needs) parts.push_back(std::to_string(needs) + (needs == 1 ? " needs you" : " need you"));
    if (passed + failed == 1) parts.push_back(only.size() > 60 ? only.substr(0, 59) + "…" : only);
    else if (passed + failed > 1) parts.push_back(std::to_string(passed) + " jobs passed" + (failed ? " · " + std::to_string(failed) + " failed" : ""));
    if (commits) parts.push_back(std::to_string(commits) + (commits == 1 ? " commit" : " commits"));
    std::string line;
    for (const auto& part : parts) line += (line.empty() ? "" : " · ") + part;
    return line;
}
int away_summary(const Json& config) {
    Json stamp;
    std::error_code ec;
    try { stamp = Json::parse(read(away_file())); } catch (...) { return 0; }
    fs::remove(away_file(), ec);
    const long long since = stamp.value("at", 0LL), now = static_cast<long long>(std::time(nullptr));
    if (since <= 0 || now - since < 120) return 0;  // a quick step away needs no note
    read_limit_seconds = 3;
    ClaudeUsage usage;
    const auto sessions = claude_sessions(usage);
    Json jobs;
    if (!sh::have("desk-work") || !capture_json({"desk-work", "jobs"}, jobs) || !jobs.is_array()) jobs = Json::array();
    int commits = 0, looked = 0;
    for (const auto& project : projects(config)) {
        if (++looked > 16) break;
        if (!directory(project.path / ".git") && !regular(project.path / ".git")) continue;
        std::string out;
        if (capture({"git", "--no-optional-locks", "-C", project.path.string(), "rev-list", "--count", "--since=@" + std::to_string(since), "HEAD"}, out))
            commits += std::atoi(trim(out).c_str());
    }
    const auto line = away_line(stamp, sessions, jobs, commits);
    if (line.empty() || !sh::have("notify-send")) return 0;
    return sh::run({"notify-send", "--app-name=FoxML", "--category=foxml.away", "while you were away", line}) == 0 ? 0 : 1;
}
// /goodnight leaves "where we left off" notes here, one per project (the git root's folder name).
fs::path goodnight_dir() { return fs::path(env("XDG_STATE_HOME", home() + "/.local/state")) / "foxml/goodnight"; }
// Notes from the last 36 hours, newest first: the morning's slip names the project and its next step.
Json last_night_notes(std::time_t now = std::time(nullptr)) {
    std::vector<std::pair<long long, Json>> found;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(goodnight_dir(), ec)) {
        const auto name = entry.path().stem().string();
        if (entry.path().extension() != ".md" || !entry.is_regular_file(ec) || !std::regex_match(name, std::regex("[A-Za-z0-9._-]{1,80}"))) continue;
        const auto age = std::chrono::duration_cast<std::chrono::seconds>(fs::file_time_type::clock::now() - fs::last_write_time(entry.path(), ec)).count();
        if (ec || age < 0 || age > 36 * 3600) continue;
        std::string next, first;
        for (const auto& raw : lines(read(entry.path()))) {
            auto line = trim(raw);
            if (line.empty() || line[0] == '#') continue;
            line = trim(std::regex_replace(line, std::regex("^[-*] +"), ""));
            if (first.empty()) first = line;
            if (lower(line).rfind("next:", 0) == 0) { next = trim(line.substr(5)); break; }
        }
        const auto said = next.empty() ? first : next;
        found.push_back({static_cast<long long>(now) - age, Json{{"name", name}, {"next", said.substr(0, 140)}, {"hasNext", !next.empty()}}});
    }
    std::sort(found.begin(), found.end(), [](const auto& a, const auto& b) { return a.first > b.first; });
    Json out = Json::array();
    for (const auto& f : found) { if (out.size() >= 3) break; out.push_back(f.second); }
    return out;
}
Json work_data(const Json& config, bool fresh = false, bool history = false) {
    if (!sh::have("desk-work")) return Json();
    Args args{"desk-work", "overview"};
    if (fresh) { args.push_back("--fresh"); args.push_back("yes"); }
    if (history) { args.push_back("--history"); args.push_back("yes"); }
    for (const auto& project : projects(config)) {
        if (args.size() > 130) break;
        if (!directory(project.path / ".git") && !regular(project.path / ".git")) continue;
        args.push_back("--root"); args.push_back(project.path.string());
    }
    Json data;
    return capture_json(args, data) && data.is_object() ? data : Json();
}
std::string work_age(long long seconds) {
    return seconds < 60 ? std::to_string(std::max(0LL, seconds)) + "s" : seconds < 3600 ? std::to_string(seconds / 60) + "m" : std::to_string(seconds / 3600) + "h " + std::to_string(seconds % 3600 / 60) + "m";
}
Json work_row(const std::string& action, const std::string& label, const std::string& argument, const std::string& detail = {}) {
    // Each kind of work row has its own pencil drawing: the job itself, its terminal, a comparison, a question.
    static const std::map<std::string, std::string> icons = {
        {"work-open", "clock"}, {"work-tests", "notebook"}, {"work-jump", "terminal"}, {"work-compare", "search"},
        {"work-ask", "message"}, {"api-task-failure", "message"}, {"work-reviews", "note"}, {"work-attention", "note"}, {"work-task-draft", "next"},
        {"work-task-toggle", "next"}, {"work-tasks", "next"}, {"work-event", "note"}, {"work-unsnooze", "note"}, {"work-caught-up", "next"}, {"service-log", "notebook"}, {"service-ask", "message"}};
    const auto found = icons.find(action);
    auto row = item(action, label, "action", detail, found == icons.end() ? "clock" : found->second);
    row["argument"] = argument; row["close"] = true; return row;
}
bool work_project(const Json& config, const std::string& path) {
    for (const auto& p : projects(config)) if (p.path.string() == path) return true;
    return false;
}
void work_rows(const Json& config, const std::string& page, Json& rows, bool* observed = nullptr) {
    const auto data = work_data(config, page == "test-results", page == "work-history" || page == "work-digest");
    if (observed) *observed = data.is_object();
    if (!data.is_object()) {
        auto row = item("work-open", "Work records are unavailable", "action", "Install desk-work to track jobs and test results", "info");
        row["enabled"] = false; rows.push_back(row); return;
    }
    if (page == "work-history" || page == "work-digest") {
        if (page == "work-history") {
            for (const auto& event : data.value("timeline", Json::array())) rows.push_back(work_row("work-event", text(event, "label"),
                Json{{"root", text(event, "root")}, {"id", text(event, "id")}}.dump(), fs::path(text(event, "root")).filename().string()));
        } else for (const auto& summary : data.value("digests", Json::array())) {
            for (const auto& event : summary.value("events", Json::array())) rows.push_back(work_row("work-event", text(event, "label"),
                Json{{"root", text(summary, "root")}, {"id", text(event, "id")}}.dump(), fs::path(text(summary, "root")).filename().string()));
            if (whole(summary, "total") > 0) rows.push_back(work_row("work-caught-up", "Caught up · " + fs::path(text(summary, "root")).filename().string(),
                Json{{"root", text(summary, "root")}, {"through", summary.value("through", 0LL)}}.dump(), text(summary, "summary", "Only marks the events shown here")));
        }
        return;
    }
    if (page == "attention-snoozed") {
        for (const auto& entry : data.value("snoozed", Json::array())) rows.push_back(work_row("work-unsnooze", "Bring back · " + text(entry, "label"),
            Json{{"root", text(entry, "root")}, {"id", text(entry, "id")}}.dump(), "Keeps the original failure or review record"));
        return;
    }
    if (page == "attention" || (page == "reviews" && data.contains("attention"))) {
        // Commits to review fold into one row per project, which opens that project's review; everything else keeps a
        // row of its own. One row per commit buried what needs you now under dozens of them.
        std::map<std::string, int> commits;
        std::vector<std::string> order;
        int total = 0;
        for (const auto& entry : data.value("attention", Json::array())) {
            const auto kind = text(entry, "kind");
            if (page == "reviews" && kind != "commit" && kind != "request" && kind != "changed") continue;
            if (kind == "commit") {
                const auto root = text(entry, "root");
                if (!commits.count(root)) order.push_back(root);
                ++commits[root]; ++total;
                continue;
            }
            rows.push_back(work_row("work-attention", text(entry, "label"),
                Json{{"root", text(entry, "root")}, {"id", text(entry, "id")}}.dump(),
                fs::path(text(entry, "root")).filename().string() + " · " + text(entry, "why")));
        }
        for (const auto& root : order) {
            const int n = commits[root];
            rows.push_back(work_row("work-reviews", std::to_string(n) + (n == 1 ? " commit to review" : " commits to review"),
                Json{{"root", root}, {"id", ""}}.dump(), fs::path(root).filename().string() + " · opens the review in Neovim"));
        }
        if (page == "attention" && total > 0)
            rows.push_back(work_row("work-set-aside", "Set aside " + std::to_string(total) + (total == 1 ? " commit" : " commits") + " to review", "{}",
                "Catch up later: they leave this list and stay unreviewed in the review; Bring back undoes it"));
        if (page == "attention") for (const auto& record : data.value("aside", Json::array())) {
            const auto n = record.value("count", 0);
            rows.push_back(work_row("work-bring-back", "Bring back " + std::to_string(n) + " set-aside " + (n == 1 ? "commit" : "commits"),
                Json{{"root", text(record, "root")}}.dump(), fs::path(text(record, "root")).filename().string() + " · back into what needs you"));
        }
        if (page == "attention" && !data.value("snoozed", Json::array()).empty()) {
            auto row = item("attention-snoozed", "Snoozed items", "page", "Bring an item back before its snooze ends", "note");
            row["page"] = "attention-snoozed"; rows.push_back(row);
        }
        return;
    }
    if (page == "reviews") {
        for (const auto& r : data.value("reviews", Json::array()))
            rows.push_back(work_row("work-reviews", text(r, "subject"), Json{{"root", text(r, "root")}, {"id", text(r, "sha")}}.dump(),
                                    fs::path(text(r, "root")).filename().string() + " · " + text(r, "sha").substr(0, 7) + " · opens in Neovim"));
        return;
    }
    if (page == "next-steps") {
        for (const auto& t : data.value("tasks", Json::array())) {
            const auto arg = Json{{"root", text(t, "root")}, {"id", text(t, "id")}}.dump();
            rows.push_back(work_row("work-task-draft", "◇ " + text(t, "text"), arg, fs::path(text(t, "root")).filename().string() + " · prepare a note; you choose whether to send it"));
            auto done = work_row("work-task-toggle", "  Mark done", arg); done["close"] = false; rows.push_back(done);
        }
        // A pin row for each checkout in use, not one for every folder under ~/code.
        std::set<std::string> used;
        for (const auto& d : data.value("digests", Json::array())) used.insert(text(d, "root"));
        for (const auto& p : projects(config)) if (used.empty() || used.count(p.path.string()))
            rows.push_back(work_row("work-tasks", "Pin a next step · " + p.name, p.path.string(), "Add or reopen a step in Neovim"));
        return;
    }
    int shown = 0;
    // claude-api is a Python start-up of its own: read its projects at the first failed job, not for every page.
    Json api; bool api_read = false;
    const auto api_root = [&](const std::string& root) {
        if (!api_read) { api = api_projects(); api_read = true; }
        return api_project_for(api, root);
    };
    for (const auto& j : data.value("jobs", Json::array())) {
        const auto state = text(j, "state");
        if (page == "test-results" && !truth(j, "testRun")) continue;
        if (page == "failures" && state != "failed" && state != "interrupted") continue;
        if (++shown > 24) break;
        const auto id = text(j, "id");
        std::string detail = fs::path(text(j, "root")).filename().string() + " · " + state + " · " + work_age(stamp(j, "elapsed"));
        if (state != "running") detail += j.contains("exit") ? " · exit " + std::to_string(whole(j, "exit")) : " · exit unknown";
        else {
            // Against the last passing run of the very same command here: a pencil ruler and what's left, never a made-up percent.
            if (j.contains("estimate") && j["estimate"].is_number_integer() && j["estimate"].get<long long>() > 0) {
                const long long estimate = j["estimate"].get<long long>(), elapsed = stamp(j, "elapsed"), left = estimate - elapsed;
                const int filled = static_cast<int>(std::min<long long>(8, elapsed * 8 / estimate));
                std::string ruler;
                for (int i = 0; i < 8; ++i) ruler += i < filled ? "━" : "┄";
                detail += left > 0 ? " · " + ruler + " " + (left < 60 ? std::string("under a minute left") : "about " + std::to_string((left + 30) / 60) + "m left")
                                   : std::string(" · taking longer than last time");
            }
            detail += " · last output " + work_age(static_cast<long long>(std::time(nullptr)) - stamp(j, "activity")) + " ago";
        }
        const auto test = j.find("tests");
        if (test != j.end() && test->is_object()) {
            const auto passed = whole(*test, "passed"), failed = whole(*test, "failed");
            if (passed >= 0) detail += " · ✓ " + std::to_string(passed) + " passed";
            if (failed >= 0) detail += " · " + std::to_string(failed) + " failed";
            if (truth(j, "stale")) detail += " · stale";
        }
        if (truth(j, "observed")) detail += " · status only; fjob captures output";
        rows.push_back(work_row(page == "test-results" ? "work-tests" : "work-open", text(j, "title", text(j, "command")), id, detail));
        if (!text(j, "pane").empty()) rows.push_back(work_row("work-jump", "  Jump to terminal", text(j, "pane")));
        if (truth(j, "testRun")) rows.push_back(work_row("work-compare", "  What changed since it last passed?", id));
        if (state == "failed" || state == "interrupted") {
            rows.push_back(work_row("work-ask", "  Ask Claude…", id, "Review the error excerpt, then choose a session"));
            if ((page == "failures" || page == "test-results") && !api_root(text(j, "root")).empty())
                rows.push_back(work_row("api-task-failure", "  Explain with API credits", id, "Read-only review of the error · you set the budget"));
        }
    }
    if (page == "failures") {
        std::string failed;
        if (capture({"systemctl", "--user", "--failed", "--no-legend", "--plain", "--type=service"}, failed))
            for (const auto& line : lines(failed)) {
                std::istringstream fields(line); std::string unit; fields >> unit;
                if (!std::regex_match(unit, std::regex("[A-Za-z0-9_.@:-]{1,200}\\.service"))) continue;
                rows.push_back(work_row("service-log", unit, unit, "Failed user service · open its recent journal"));
                rows.push_back(work_row("service-ask", "  Ask Claude…", unit, "Review the journal excerpt before sending"));
            }
    }
}
void worktree_rows(const Json& config, const std::string& scope, Json& rows) {
    std::set<std::string> seen;
    for (const auto& p : projects(config)) {
        if (!scope.empty() && p.path.string() != scope) continue;
        Json trees;
        if (!capture_json({"desk-work", "worktrees", "--root", p.path.string()}, trees) || !trees.is_array()) continue;
        for (const auto& tree : trees) {
            const auto path = text(tree, "path"); if (!seen.insert(path).second) continue;
            const auto status = lines(text(tree, "status"));
            const auto changed = status.size() > 1 ? status.size() - 1 : 0;
            std::string detail = path + " · " + (status.empty() ? "status unavailable" : changed ? std::to_string(changed) + " changed or untracked" : "clean");
            if (!status.empty()) {
                std::smatch ahead;
                if (std::regex_search(status[0], ahead, std::regex("\\[ahead ([0-9]+)"))) detail += " · ↑" + ahead[1].str() + " unpushed";
            }
            const auto peers = tree.value("sessions", Json::array());
            if (peers.size() > 1) detail += " · also open in " + std::to_string(peers.size()) + " sessions";
            for (const auto& peer : peers) detail += " · " + text(peer, "name") + " (" + text(peer, "state") + ")";
            auto row = work_row("worktree-open", p.name + " · " + text(tree, "branch"), path, detail);
            row["enabled"] = directory(path) && !truth(tree, "bare"); rows.push_back(row);
            rows.push_back(work_row("worktree-terminal", "  Open terminal here", path));
            for (const auto& peer : peers) if (!text(peer, "pane").empty())
                rows.push_back(work_row("work-jump", "  Go to " + text(peer, "name"), text(peer, "pane")));
        }
    }
}
bool known_worktree(const Json& config, const std::string& path) {
    if (!fs::path(path).is_absolute()) return false;
    for (const auto& p : projects(config)) {
        std::string paths;
        if (!capture({"git", "--no-optional-locks", "-C", p.path.string(), "worktree", "list", "--porcelain", "-z"}, paths)) continue;
        std::istringstream in(paths); std::string line;
        while (std::getline(in, line, '\0')) if (line == "worktree " + path) return directory(path);
    }
    return false;
}

struct Volume { std::string path, disk, label, mount; uint64_t size = 0; };
bool device_path(const std::string& path) {
    return std::regex_match(path, std::regex("/dev/[A-Za-z0-9_-]+"));
}
bool volume_nodes(const Json& node, const std::string& disk, std::vector<Volume>& volumes) {
    if (!node.is_object() || !device_path(text(node, "path"))) return false;
    const auto type = text(node, "type");
    if (type != "disk" && type != "part") return false;
    std::string mount;
    if (!node.contains("mountpoints") || !node["mountpoints"].is_array()) return false;
    for (const auto& point : node["mountpoints"]) {
        if (point.is_null()) continue;
        if (!point.is_string()) return false;
        const auto value = point.get<std::string>();
        // Only user-media mounts belong in the library, including on a USB-booted system.
        if (!safe_text(value) || (value.rfind("/run/media/", 0) != 0 && value.rfind("/media/", 0) != 0 && value.rfind("/mnt/", 0) != 0)) return false;
        if (mount.empty()) mount = value;
    }
    const auto fs_type = text(node, "fstype");
    if (!mount.empty() && fs_type.empty()) return false;
    const std::set<std::string> filesystems{"vfat","exfat","ntfs","ntfs3","ext2","ext3","ext4","btrfs","xfs","f2fs","iso9660","udf"};
    if (!fs_type.empty() && !filesystems.count(fs_type)) return false;
    if (filesystems.count(fs_type)) {
        uint64_t bytes = 0;
        if (node.contains("size") && node["size"].is_number_unsigned()) bytes = node["size"].get<uint64_t>();
        volumes.push_back({text(node,"path"), disk, text(node,"label").empty() ? text(node,"name","Removable volume") : text(node,"label"), mount, bytes});
    }
    if (node.contains("children")) {
        if (!node["children"].is_array()) return false;
        for (const auto& child : node["children"]) if (!volume_nodes(child, disk, volumes)) return false;
    }
    return true;
}
bool library(std::vector<Volume>& volumes) {
    Json data;
    if (!capture_json({"lsblk","--json","--bytes","--tree","--output","NAME,PATH,TYPE,TRAN,RM,SIZE,LABEL,FSTYPE,MOUNTPOINTS"}, data)
        || !data.is_object() || !data.contains("blockdevices") || !data["blockdevices"].is_array()) return false;
    for (const auto& disk : data["blockdevices"]) {
        if (text(disk,"type") != "disk" || (text(disk,"tran") != "usb" && !truth(disk,"rm"))) continue;
        std::vector<Volume> candidate;
        if (volume_nodes(disk, text(disk,"path"), candidate)) volumes.insert(volumes.end(), candidate.begin(), candidate.end());
    }
    return true;
}
std::string capacity(uint64_t bytes) {
    const std::array<const char*,5> units{{"B","KiB","MiB","GiB","TiB"}};
    double value = bytes; size_t unit = 0;
    while (value >= 1024 && unit < units.size()-1) { value /= 1024; ++unit; }
    std::ostringstream out; out.precision(1); out << std::fixed << value << ' ' << units[unit]; return out.str();
}

fs::path download_directory(const Json& config) {
    std::string path = text(config, "downloads_directory");
    if (path.empty() && sh::have("xdg-user-dir")) {
        std::string output;
        if (capture({"xdg-user-dir", "DOWNLOAD"}, output) && fs::path(trim(output)).is_absolute()) path = trim(output);
        if (path == home()) return {}; // XDG uses HOME to mark a disabled special folder.
    }
    if (path.empty()) path = home() + "/Downloads";
    if (path.rfind("~/", 0) == 0) path = home() + path.substr(1);
    if (!safe_text(path)) return {};
    std::error_code ec;
    const auto canonical = fs::canonical(path, ec);
    return ec ? fs::path{} : canonical;
}
struct Download {
    fs::path path;
    std::string name, type, age, modified_at;
    uint64_t size;
    fs::file_time_type modified;
};
std::vector<Download> downloads(const Json& config, bool pictures_only = false) {
    std::vector<Download> found;
    const auto root = download_directory(config);
    if (root.empty()) return found;
    std::error_code ec;
    fs::directory_iterator iter(root, fs::directory_options::skip_permission_denied, ec), end;
    while (!ec && iter != end) {
        const auto entry = *iter; iter.increment(ec);
        std::error_code status;
        if (entry.is_symlink(status) || !entry.is_regular_file(status)) continue;
        const auto name = entry.path().filename().string();
        if (name.empty() || name.front() == '.' || !safe_text(name)) continue;
        const auto ext = lower(entry.path().extension().string());
        if (pictures_only && ext != ".png" && ext != ".jpg" && ext != ".jpeg" && ext != ".webp") continue;
        const std::set<std::string> partial{".part", ".partial", ".crdownload", ".download", ".tmp", ".aria2"};
        if (partial.count(ext)) continue;
        const auto modified = entry.last_write_time(status);
        if (status) continue;
        const auto size = entry.file_size(status);
        if (status) continue;
        const auto seconds = std::max<int64_t>(0, std::chrono::duration_cast<std::chrono::seconds>(fs::file_time_type::clock::now() - modified).count());
        const auto age = seconds < 60 ? "JUST NOW" : seconds < 3600 ? std::to_string(seconds / 60) + "m AGO"
            : seconds < 86400 ? std::to_string(seconds / 3600) + "h AGO" : std::to_string(seconds / 86400) + "d AGO";
        std::string type = "File";
        if (ext == ".pdf") type = "PDF";
        else if (ext == ".txt" || ext == ".md" || ext == ".rst") type = "Note";
        else if (ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".webp" || ext == ".gif" || ext == ".svg") type = "Picture";
        else if (ext == ".zip" || ext == ".gz" || ext == ".xz" || ext == ".tar" || ext == ".7z" || ext == ".rar" || ext == ".zst") type = "Archive";
        else if (ext == ".mp3" || ext == ".wav" || ext == ".flac" || ext == ".ogg") type = "Audio";
        else if (ext == ".mp4" || ext == ".webm" || ext == ".mkv") type = "Video";
        const auto system_time = std::chrono::system_clock::now() +
            std::chrono::duration_cast<std::chrono::system_clock::duration>(modified - fs::file_time_type::clock::now());
        const auto epoch = std::chrono::system_clock::to_time_t(system_time);
        std::tm local{};
        std::ostringstream date;
        if (::localtime_r(&epoch, &local)) date << std::put_time(&local, "%Y-%m-%d %H:%M:%S %Z");
        found.push_back({entry.path(), name, type, age, date.str(), size, modified});
    }
    std::sort(found.begin(), found.end(), [](const auto& a, const auto& b) {
        return a.modified != b.modified ? a.modified > b.modified : a.name < b.name;
    });
    if (found.size() > 64) found.resize(64);
    return found;
}

std::vector<Download> screenshots(const Json& config) {
    Json scoped = config;
    scoped["downloads_directory"] = text(config, "screenshots_directory", home() + "/Pictures/Screenshots");
    return downloads(scoped, true);
}
std::string file_url(const fs::path& path) {
    static constexpr char hex[] = "0123456789ABCDEF";
    std::string out = "file://";
    for (unsigned char c : path.string()) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c == '/' || c == '-' || c == '_' || c == '.' || c == '~') out += c;
        else { out += '%'; out += hex[c >> 4]; out += hex[c & 15]; }
    }
    return out;
}
Json copy_screenshot(const fs::path& path) {
    if (!sh::have("wl-copy")) return result(false, "wl-copy is not installed");
    const int fd = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return result(false, "This picture is no longer available");
    const auto ext = lower(path.extension().string());
    const char* mime = ext == ".png" ? "image/png" : ext == ".webp" ? "image/webp" : "image/jpeg";
    const pid_t child = ::fork();
    if (child == 0) {
        ::dup2(fd, STDIN_FILENO); ::close(fd);
        const int nullfd = ::open("/dev/null", O_WRONLY);
        if (nullfd >= 0) { ::dup2(nullfd, STDOUT_FILENO); ::dup2(nullfd, STDERR_FILENO); ::close(nullfd); }
        ::execlp("wl-copy", "wl-copy", "--type", mime, static_cast<char*>(nullptr)); ::_exit(127);
    }
    ::close(fd);
    if (child < 0) return result(false, "Could not start clipboard writer");
    int status = 0;
    while (::waitpid(child, &status, 0) < 0) if (errno != EINTR) return result(false, "Could not await clipboard writer");
    const bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    return result(ok, ok ? "Picture copied" : "Could not copy picture");
}

std::string group_summary(const std::string& group) {
    if (group == "sound") {
        const auto state = audio_state();
        return state.ok ? (state.checked ? "Muted · a little quiet" : state.label + " · speakers") : "Audio unavailable";
    }
    if (group == "comfort") {
        const auto state = dnd_state();
        return state.ok ? (state.checked ? "shh… notifications paused" : "Notifications on") : "Notification state unavailable";
    }
    if (group == "connections") {
        std::string out;
        if (!capture({"nmcli", "-t", "-f", "TYPE,NAME", "connection", "show", "--active"}, out)) return "Network unavailable";
        for (const auto& line : lines(out)) {
            const auto fields = nm_fields(line);
            if (fields.size() >= 2 && (fields[0] == "802-11-wireless" || fields[0] == "wifi")) return fields[1];
        }
        for (const auto& line : lines(out)) {
            const auto fields = nm_fields(line);
            if (fields.size() >= 2 && (fields[0] == "802-3-ethernet" || fields[0] == "ethernet")) return "Ethernet · " + fields[1];
        }
        return "No active network";
    }
    if (group == "desk") {
        Json clients;
        if (!capture_json({"hyprctl", "-j", "clients"}, clients) || !clients.is_array()) return "Window list unavailable";
        return std::to_string(clients.size()) + (clients.size() == 1 ? " open window" : " open windows");
    }
    if (group == "system") {
        const auto path = runtime() / "foxml-waybar/updates.list";
        if (!regular(path)) return "Updates not checked";
        size_t count = 0;
        for (const auto& line : lines(read(path))) if (!trim(line).empty()) ++count;
        return std::to_string(count) + (count == 1 ? " cached update" : " cached updates");
    }
    return {};
}

// The bench at a glance, from the same counts Today shows: what is running, then what waits for you.
std::string workbench_summary(const Json& today) {
    const auto count = [&](const char* key) { return today.contains(key) && today[key].is_number_integer() ? today[key].get<long long>() : 0LL; };
    const auto say = [](long long n, const std::string& one, const std::string& many) { return std::to_string(n) + " " + (n == 1 ? one : many); };
    if (count("jobsRunning")) return say(count("jobsRunning"), "job running", "jobs running");
    // Every live Claude counts, not only the busy ones: "4 Claudes · 2 working" when two are waiting on her.
    if (count("claudeWorking") && count("claudeSessions") > count("claudeWorking"))
        return say(count("claudeSessions"), "Claude", "Claudes") + " · " + std::to_string(count("claudeWorking")) + " working";
    if (count("claudeWorking")) return say(count("claudeWorking"), "Claude working", "Claudes working");
    if (count("claudeSessions")) return say(count("claudeSessions"), "Claude waiting", "Claudes waiting");
    if (count("jobsFailed")) return say(count("jobsFailed"), "job failed", "jobs failed");
    if (count("changesToReview")) return say(count("changesToReview"), "change to look over", "changes to look over");
    return "all quiet on the bench";
}
struct Tool { std::string name, description; };
struct ToolSection { std::string id, label, description, icon; };
const std::vector<ToolSection> tool_sections{
    {"tools-ai", "AI & coding", "Assistants, local models and code review", "message"},
    {"tools-security", "Security & privacy", "Hardening, firewall, audits and passwords", "shield"},
    {"tools-desktop", "Desktop & appearance", "Themes, screens, notifications and colors", "palette"},
    {"tools-system", "System & diagnostics", "Health checks, hardware and maintenance", "gear"},
    {"tools-projects", "Projects & backups", "Project setup, work tracking and recovery", "folder"},
    {"tools-other", "Other tools", "Additional installed Fox commands", "info"},
    {"tools-all", "All tools", "Every installed command, alphabetically", "info"},
};
std::string tool_section(const std::string& name) {
    static const std::map<std::string, std::set<std::string>> names{
        {"tools-security", {"desk-allowlist", "desk-arm", "desk-audit", "audit-timer", "desk-bouncer", "desk-deadman", "desk-dispatch", "desk-dns-shield", "desk-dnssec", "desk-fingerprint", "desk-firewall", "desk-harden", "desk-honey", "desk-honeypot", "desk-jail", "desk-knock", "desk-lock", "lock-panel", "desk-mac", "desk-offline", "desk-overwatch", "desk-pass", "desk-password-copy", "desk-ports", "desk-proximity", "desk-sec", "sec-dashboard", "sec-health", "desk-sentry-audit", "desk-snitch", "desk-spa", "desk-tripwire", "desk-usb", "desk-vault", "desk-vpn"}},
        {"tools-desktop", {"desk-color", "desk-eza", "gen-keybinds", "desk-hl", "desk-mako", "desk-monitor", "desk-notifications", "desk-pulse", "desk-render-fast", "desk-theme", "theme-check", "theme-tweak"}},
        {"tools-system", {"desk-doctor", "hw-info", "desk-install", "desk-legacy", "nvidia-state", "desk-sys", "desk-tail", "template-lint", "desk-test", "desk-uninstall"}},
        {"tools-projects", {"desk-backup", "build-verify", "desk-cafe", "desk-dev", "desk-develop", "distro-build", "distro-flash", "distro-guide", "generate-module", "desk-init", "new-project", "desk-work", "work-notice"}},
    };
    if (name.rfind("desk-ai", 0) == 0 || name.rfind("fox-llm-", 0) == 0 || name == "claude-api" || name == "desk-credits" || name == "desk-ask" || name == "agent-parse" || name == "fask" || name == "findex" || name == "fhelp") return "tools-ai";
    for (const auto& [section, tools] : names) if (tools.count(name)) return section;
    return "tools-other";
}
std::vector<Tool> desk_tools() {
    // Tools lost their fox- prefix in 2026-11: desk-* by name, and the ones that are plain names by this list.
    static const std::set<std::string> plain{"agent-parse", "ai-audit", "ai-bench", "ai-bouncer", "ai-cmd", "ai-commit", "ai-default", "ai-doctor", "ai-explain", "ai-find", "ai-history", "ai-log", "ai-oracle", "ai-purge", "ai-quick", "ai-review", "ai-snitch", "ai-status", "ai-strategy", "ai-swap", "ai-test", "ai-trace", "ai-watch", "audit-timer", "build-verify", "claude-api", "desktop-menu", "distro-build", "distro-flash", "distro-guide", "generate-module", "gen-keybinds", "hw-info", "llm-discover", "llm-grade", "llm-run", "llm-serve", "llm-update", "lock-panel", "new-project", "nvidia-state", "sec-dashboard", "sec-health", "template-lint", "theme-check", "theme-tweak", "word-count", "work-notice"};
    static const std::set<std::string> hidden{"desk", "desk-bar", "desktop-menu", "desk-drawer", "desk-cheatsheet", "desk-menu", "desk-picker", "desk-rollback", "desk-sandbox", "desk-wallpaper"};
    static const std::map<std::string, std::string> fixed{
        {"fask", "Query the local AI tools (AI model)"}, {"findex", "Rebuild the vector index for AI semantic search"}};
    std::vector<Tool> found; std::error_code ec;
    for (const auto& entry : fs::directory_iterator(fs::path(home()) / ".local/bin", ec)) {
        const auto name = entry.path().filename().string();
        const bool listed = name.rfind("desk-", 0) == 0 || plain.count(name) || fixed.count(name) || name == "fhelp";
        if (!listed || hidden.count(name) || !regular(entry.path()) || ::access(entry.path().c_str(), X_OK) != 0) continue;
        std::string description = fixed.count(name) ? fixed.at(name) : "";
        if (description.empty()) {
            // The second line of a script reads "# name — what it does".
            std::ifstream stream(entry.path(), std::ios::binary); std::string shebang, line;
            if (std::getline(stream, shebang) && shebang.rfind("#!", 0) == 0 && std::getline(stream, line))
                for (const std::string dash : {" — ", " -- ", " - "})
                    if (const auto at = line.find(dash); line.rfind("#", 0) == 0 && at != std::string::npos) {
                        description = trim(line.substr(at + dash.size()));
                        if (!description.empty()) description[0] = static_cast<char>(std::toupper(static_cast<unsigned char>(description[0])));
                        break;
                    }
        }
        found.push_back({name, description.empty() ? "Opens in a terminal" : description});
    }
    std::sort(found.begin(), found.end(), [](const Tool& a, const Tool& b) { return a.name < b.name; });
    return found;
}

// Desktop first, then the drawer, tmux and Neovim. Stock Vim keys are Vim's own and stay out; the theme's
// init.lua maps and notebook marks stay in.
enum class KeyFamily { desktop, drawer, tmux, commands, nvim, stock };
struct Shortcut { std::string keys, description, section; KeyFamily family = KeyFamily::nvim; };
KeyFamily key_family(const std::string& major, const std::string& minor) {
    if (major.rfind("Hyprland", 0) == 0) return KeyFamily::desktop;
    if (minor.find("Quickshell") != std::string::npos || minor.find("drawer") != std::string::npos) return KeyFamily::drawer;
    if (major.rfind("Tmux", 0) == 0) return KeyFamily::tmux;
    if (major.rfind("Core Vim", 0) == 0) return KeyFamily::stock;
    if (major.rfind("Useful Commands", 0) == 0) return KeyFamily::commands;
    return KeyFamily::nvim;
}
struct KeyBook { KeyFamily family; const char* id; const char* label; const char* detail; const char* icon; };
const std::vector<KeyBook> key_books{
    {KeyFamily::desktop, "desktop", "Desktop", "Apps, windows, workspaces and media", "window"},
    {KeyFamily::drawer, "drawer", "The drawer", "Moving around this drawer", "apps"},
    {KeyFamily::tmux, "tmux", "Terminal (tmux)", "Panes, windows and copy mode", "terminal"},
    {KeyFamily::commands, "commands", "Commands", "Handy commands to type", "terminal"},
    {KeyFamily::nvim, "nvim", "Neovim", "Files, search, git, code and its plugins", "note"},
};
// "ALT + Shift + N" → "alt ⇧ n", "Space ff" → "space ff": the keycaps a row draws. Empty when it would need more than
// five caps; the row then says its keys in words. Editor keys keep their case ("S" is not "s" there).
std::string key_caps(const std::string& keys, KeyFamily family) {
    std::vector<std::string> caps;
    std::string token;
    auto flush = [&] {
        if (token.empty()) return;
        std::string lower = token;
        for (auto& c : lower) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        if (lower == "shift") caps.push_back("⇧");
        else if (lower == "alt" || lower == "ctrl" || lower == "super" || lower == "space" || lower == "enter" || lower == "tab"
                 || lower == "esc" || lower == "escape" || lower == "return") caps.push_back(lower == "escape" ? "esc" : lower == "return" ? "enter" : lower);
        else caps.push_back(token);
        token.clear();
    };
    for (size_t i = 0; i < keys.size(); ++i) {
        const char c = keys[i];
        if (c == ' ' || (c == '+' && !token.empty() && i + 1 < keys.size())) flush();
        else token += c;
    }
    flush();
    // A "+" between spaced keys ("ALT + F") joins them; it is not a key of its own.
    if (caps.size() > 1) caps.erase(std::remove(caps.begin(), caps.end(), std::string("+")), caps.end());
    // A letter held with a modifier reads lowercase ("alt ⇧ d"); a bare editor key keeps its case ("S").
    const bool held = std::any_of(caps.begin(), caps.end(), [](const std::string& c) { return c == "alt" || c == "ctrl" || c == "super" || c == "⇧"; });
    for (auto& cap : caps)
        if ((held || family == KeyFamily::desktop) && cap.size() == 1 && std::isalpha(static_cast<unsigned char>(cap[0])))
            cap[0] = static_cast<char>(std::tolower(static_cast<unsigned char>(cap[0])));
    if (caps.empty() || caps.size() > 5) return {};
    std::string out;
    for (const auto& cap : caps) out += (out.empty() ? "" : " ") + cap;
    return out;
}
std::vector<Shortcut> shortcuts() {
    fs::path file = data_home() / "foxml/KEYBINDS.md";
    if (!regular(file)) file = repository() / "KEYBINDS.md";
    std::vector<Shortcut> found; std::string major, minor, section;
    for (const auto& line : lines(read(file))) {
        if (line.rfind("## ", 0) == 0) { section = major = trim(line.substr(3)); minor.clear(); continue; }
        if (line.rfind("### ", 0) == 0) { minor = trim(line.substr(4)); section = major + " · " + minor; continue; }
        if (line.rfind("| `", 0) != 0) continue;
        // The first cell, to the first bar outside backticks: "`j` / `k`" reads "j / k", "`Ctrl+a \|`" reads "Ctrl+a |".
        std::string keys; bool code = false; size_t bar = std::string::npos;
        for (size_t i = 2; i < line.size(); ++i) {
            if (line[i] == '\\' && i + 1 < line.size() && line[i + 1] == '|') { keys += '|'; ++i; }
            else if (line[i] == '`') code = !code;
            else if (line[i] == '|' && !code) { bar = i; break; }
            else keys += line[i];
        }
        keys = trim(keys);
        if (bar == std::string::npos || keys.empty()) continue;
        const auto family = key_family(major, minor);
        if (family == KeyFamily::stock) continue;
        std::string description = trim(line.substr(bar + 1));
        if (!description.empty() && description.back() == '|') description = trim(description.substr(0, description.size() - 1));
        description.erase(std::remove(description.begin(), description.end(), '`'), description.end());
        for (auto at = description.find("**"); at != std::string::npos; at = description.find("**")) description.erase(at, 2);
        found.push_back({keys, description, section, family});
    }
    std::stable_sort(found.begin(), found.end(), [](const Shortcut& a, const Shortcut& b) { return a.family < b.family; });
    return found;
}

struct Sandbox { const char* id; const char* label; const char* detail; const char* program; Args argv; };
const std::vector<Sandbox>& sandboxes() {
    static const std::vector<Sandbox> table{
        {"firefox", "Firefox", "A private session", "firefox", {"firefox"}},
        {"chromium", "Chromium", "A private session", "chromium", {"chromium", "--incognito"}},
        {"kitty", "Kitty", "A disposable terminal", "kitty", {"kitty"}},
        {"yazi", "Yazi", "A file browser with an empty home", "yazi", {"kitty", "-e", "yazi"}},
        {"pager", "Pager", "A disposable terminal", "less", {"kitty", "-e", "less"}},
    };
    return table;
}

bool valid_month(const std::string& month) {
    static const std::regex format("^[0-9]{4}-(0[1-9]|1[0-2])$");
    return std::regex_match(month, format);
}
// Days in YYYY-MM with a commit by the identity each repository is configured with. Reads dates, nothing else.
// One of your own commits: the day it was committed, the day it was written, and what makes it the same commit
// in another branch, clone or rebase (its author time and subject; a rebase changes the hash, never those).
struct OwnCommit { std::string committed, authored, key; };
std::vector<OwnCommit> own_commits(const Json& config, const std::string& since, const std::string& until) {
    std::vector<OwnCommit> out;
    if (!sh::have("git")) return out;
    for (const auto& project : projects(config)) {
        const auto path = project.path.string(); std::string email, log;
        if (!directory(project.path / ".git") && !regular(project.path / ".git")) continue;
        if (!capture({"git", "-C", path, "config", "user.email"}, email) || trim(email).empty()) continue;
        Args args{"git", "-C", path, "log", "--all", "--fixed-strings", "--author=" + trim(email), "--since=" + since + "T00:00:00",
                  "--date=format-local:%Y-%m-%d", "--format=%cd%x09%ad%x09%at%x09%s"};
        if (!until.empty()) args.push_back("--until=" + until + "T00:00:00");
        if (!capture(args, log)) continue;
        for (const auto& row : lines(log)) {
            const auto a = row.find('\t'), b = a == std::string::npos ? a : row.find('\t', a + 1);
            if (b == std::string::npos) continue;
            out.push_back({row.substr(0, a), row.substr(a + 1, b - a - 1), row.substr(b + 1)});
        }
    }
    return out;
}
std::string local_day(std::time_t when) {
    char day[16] = {}; std::strftime(day, sizeof day, "%Y-%m-%d", std::localtime(&when)); return day;
}

// ── Due dates: a course site's private calendar feed (Canvas, Moodle, Blackboard export .ics links) ──
// The links are private, so they live only in a 0600 file; the feeds are fetched in the background at most every
// three hours (calendar-refresh, started detached) and read from the cache, so nothing waits on the network and
// nothing is fetched without a feed.
fs::path calendar_feeds_file() { return config_home() / "foxml/calendar-feeds.json"; }
fs::path calendar_cache() { return fs::path(env("XDG_CACHE_HOME", home() + "/.cache")) / "foxml/calendar"; }
Json calendar_feeds() {
    const auto feeds = Json::parse(read(calendar_feeds_file()), nullptr, false);
    Json out = Json::array();
    if (feeds.is_array()) for (const auto& f : feeds) if (f.is_object() && text(f, "url").rfind("https://", 0) == 0) out.push_back(f);
    return out;
}
std::string feed_key(const std::string& url) {
    unsigned long long h = 1469598103934665603ULL;
    for (const unsigned char c : url) { h ^= c; h *= 1099511628211ULL; }
    std::ostringstream o; o << std::hex << h; return o.str();
}
bool save_calendar_feeds(const Json& feeds) {
    std::error_code ec; fs::create_directories(calendar_feeds_file().parent_path(), ec);
    if (!write_atomic(calendar_feeds_file(), feeds.dump(2) + "\n")) return false;
    ::chmod(calendar_feeds_file().c_str(), 0600);
    return true;
}
int calendar_refresh() {
    if (!sh::have("curl")) return 1;
    std::error_code ec; fs::create_directories(calendar_cache(), ec);
    // One read of the feeds at a time; a second waits for the first instead of fetching beside it.
    const int lock = ::open((calendar_cache() / ".lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lock >= 0) ::flock(lock, LOCK_EX);
    int failed = 0;
    for (const auto& feed : calendar_feeds()) {
        std::string body;
        if (!capture({"curl", "-fsSL", "--max-time", "20", "--max-filesize", "10000000", text(feed, "url")}, body)
            || body.find("BEGIN:VCALENDAR") == std::string::npos) { ++failed; continue; }
        if (!write_atomic(calendar_cache() / (feed_key(text(feed, "url")) + ".ics"), body)) ++failed;
    }
    if (lock >= 0) ::close(lock);
    return failed ? 1 : 0;
}
// Fetch in the background when the newest cache is over three hours old (or missing); never waits for it. A feed
// that keeps failing never writes its cache, so the wait runs from the last attempt: Today reads this every few seconds.
void calendar_refresh_if_stale() {
    const auto feeds = calendar_feeds();
    if (feeds.empty()) return;
    std::error_code ec;
    const auto now = fs::file_time_type::clock::now();
    const auto limit = now - std::chrono::hours(3);
    const auto attempted = calendar_cache() / ".attempted";
    std::error_code aec; const auto tried = fs::last_write_time(attempted, aec);
    if (!aec && tried > now - std::chrono::minutes(30)) return;
    for (const auto& feed : feeds) {
        const auto file = calendar_cache() / (feed_key(text(feed, "url")) + ".ics");
        std::error_code tec; const auto when = fs::last_write_time(file, tec);
        if (tec || when < limit) {
            fs::create_directories(calendar_cache(), ec);
            if (!write_atomic(attempted, "")) return;
            const auto self = fs::read_symlink("/proc/self/exe", ec);
            if (!ec) launch({self.string(), "calendar-refresh"}, "");
            return;
        }
    }
}
struct Due { std::time_t at = 0; bool all_day = false; std::string title, course; };
// ICS text to the things that are due: VEVENT start or VTODO due; UTC ("…Z"), local or date-only times.
std::vector<Due> parse_ics(const std::string& ics) {
    std::vector<std::string> unfolded;
    for (auto line : lines(ics)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (!line.empty() && (line[0] == ' ' || line[0] == '\t') && !unfolded.empty()) unfolded.back() += line.substr(1);
        else unfolded.push_back(line);
    }
    auto unescape = [](std::string s) {
        std::string out;
        for (size_t i = 0; i < s.size(); ++i) {
            if (s[i] == '\\' && i + 1 < s.size()) { const char n = s[++i]; out += n == 'n' || n == 'N' ? ' ' : n; }
            else out += s[i];
        }
        return trim(out);
    };
    auto when = [](const std::string& value, bool& all_day) -> std::time_t {
        static const std::regex stamp(R"((\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?)");
        std::smatch m;
        if (!std::regex_match(value, m, stamp)) return 0;
        std::tm tm{}; tm.tm_year = std::stoi(m[1]) - 1900; tm.tm_mon = std::stoi(m[2]) - 1; tm.tm_mday = std::stoi(m[3]);
        all_day = !m[4].matched;
        if (!all_day) { tm.tm_hour = std::stoi(m[4]); tm.tm_min = std::stoi(m[5]); tm.tm_sec = std::stoi(m[6]); }
        else tm.tm_hour = 12;
        tm.tm_isdst = -1;
        return m[7].matched && m[7].length() ? ::timegm(&tm) : std::mktime(&tm);
    };
    std::vector<Due> out;
    Due current; bool inside = false, has_due = false;
    for (const auto& line : unfolded) {
        if (line == "BEGIN:VEVENT" || line == "BEGIN:VTODO") { current = Due{}; inside = true; has_due = false; continue; }
        if ((line == "END:VEVENT" || line == "END:VTODO") && inside) {
            inside = false;
            if (current.at > 0 && !current.title.empty()) {
                static const std::regex bracket(R"(^(.*?)\s*\[([^\]]{1,40})\]\s*$)");
                std::smatch m;
                if (std::regex_match(current.title, m, bracket)) { current.title = trim(m[1]); current.course = trim(m[2]); }
                out.push_back(current);
            }
            continue;
        }
        if (!inside) continue;
        const auto colon = line.find(':');
        if (colon == std::string::npos) continue;
        const auto key = line.substr(0, line.find_first_of(";:")), value = line.substr(colon + 1);
        if (key == "SUMMARY") current.title = unescape(value).substr(0, 120);
        else if (key == "DUE") { current.at = when(value, current.all_day); has_due = true; }
        else if (key == "DTSTART" && !has_due) current.at = when(value, current.all_day);
    }
    return out;
}
std::vector<Due> due_items() {
    std::vector<Due> all;
    for (const auto& feed : calendar_feeds())
        for (const auto& d : parse_ics(read(calendar_cache() / (feed_key(text(feed, "url")) + ".ics")))) all.push_back(d);
    std::sort(all.begin(), all.end(), [](const Due& a, const Due& b) { return a.at < b.at; });
    return all;
}
std::string due_clock(const Due& d) {
    if (d.all_day) return "";
    char out[16]; const std::tm tm = *std::localtime(&d.at);
    std::strftime(out, sizeof out, "%I:%M %p", &tm);
    std::string s = trim(out);
    if (!s.empty() && s[0] == '0') s.erase(0, 1);
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}
Json due_row(const Due& d) {
    const std::tm tm = *std::localtime(&d.at);
    return Json{{"day", tm.tm_mday}, {"title", d.title}, {"course", d.course}, {"time", due_clock(d)}, {"at", static_cast<long long>(d.at)}};
}

// "today 11:59 pm", "tomorrow", "thu 9:00 am": when something is due, said the short way.
std::string due_when(const Due& d) {
    const auto now = std::time(nullptr);
    const std::tm a = *std::localtime(&now), b = *std::localtime(&d.at);
    std::tm day_a = a, day_b = b; day_a.tm_hour = day_b.tm_hour = 12; day_a.tm_min = day_b.tm_min = day_a.tm_sec = day_b.tm_sec = 0;
    const auto days = static_cast<long>(std::lround(std::difftime(std::mktime(&day_b), std::mktime(&day_a)) / 86400));
    char weekday[8]; std::strftime(weekday, sizeof weekday, "%a", &b);
    std::string w = weekday; for (auto& c : w) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    const std::string day = days == 0 ? "today" : days == 1 ? "tomorrow" : w;
    const auto clock = due_clock(d);
    return clock.empty() ? day : day + " " + clock;
}
Json calendar_feed_add(const std::string& raw) {
    std::string url = trim(raw);
    if (url.rfind("webcal://", 0) == 0) url = "https://" + url.substr(9);
    static const std::regex ok(R"(^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*$)");
    if (url.size() > 2000 || !std::regex_match(url, ok)) return result(false, "That is not a calendar link (https:// or webcal://)");
    auto feeds = calendar_feeds();
    for (const auto& f : feeds) if (text(f, "url") == url) return result(false, "That calendar is already here");
    static const std::regex host(R"(^https://([^/:]+))");
    std::smatch m; std::regex_search(url, m, host);
    feeds.push_back(Json{{"url", url}, {"name", m[1].str()}});
    if (!save_calendar_feeds(feeds)) return result(false, "Could not save the calendar link");
    const auto refreshed = calendar_refresh() == 0;
    auto done = result(true, refreshed ? "Calendar added · its due dates are on the calendar" : "Calendar added · it could not be read yet; trying again later");
    done["close"] = false; return done;
}
void calendar_feed_rows(Json& rows) {
    const auto feeds = calendar_feeds();
    const auto now = std::time(nullptr);
    if (!feeds.empty()) rows.push_back(heading("calendars"));
    for (const auto& f : feeds) {
        const auto key = feed_key(text(f, "url"));
        std::error_code ec; const auto when = fs::last_write_time(calendar_cache() / (key + ".ics"), ec);
        long long coming = 0;
        for (const auto& d : parse_ics(read(calendar_cache() / (key + ".ics")))) coming += d.at >= now;
        const auto minutes = ec ? 0 : std::chrono::duration_cast<std::chrono::minutes>(fs::file_time_type::clock::now() - when).count();
        const auto age = ec ? std::string("not read yet") : minutes < 2 ? std::string("read just now")
            : minutes < 60 ? "read " + std::to_string(minutes) + " min ago" : "read " + std::to_string(minutes / 60) + " h ago";
        auto row = item("calendar-feed-remove", text(f, "name", "calendar"), "action", std::to_string(coming) + " coming up · " + age, "today");
        row["argument"] = key; row["confirm"] = "Remove this calendar? Its due dates leave the calendar; you can add the link again any time.";
        rows.push_back(row);
    }
    rows.push_back(heading(feeds.empty() ? "add one" : "more"));
    rows.push_back(item("calendar-feed-add", "Add a calendar link", "action",
                        "Your course site's private calendar feed (Canvas, Moodle, Blackboard) · stays on this machine", "today"));
    if (!feeds.empty()) rows.push_back(item("calendar-refresh", "Read them again now", "action", "They are read every few hours on their own", "refresh"));
}

Json commit_days(const Json& config, const std::string& month) {
    std::set<std::string> days, today_commits;
    const auto today = local_day(std::time(nullptr));
    const int year = std::stoi(month.substr(0, 4)), number = std::stoi(month.substr(5, 2));
    const auto next = std::to_string(number == 12 ? year + 1 : year) + (number >= 9 && number != 12 ? "-" : "-0") + std::to_string(number == 12 ? 1 : number + 1) + "-01";
    for (const auto& commit : own_commits(config, month + "-01", next)) {
        if (commit.committed.rfind(month + "-", 0) == 0) days.insert(commit.committed);
        // Written today, not just rebased today: a rebase moves the commit date, never the author date.
        if (commit.authored == today) today_commits.insert(commit.key);
    }
    Json list = Json::array();
    for (const auto& day : days) list.push_back(std::stoi(day.substr(8, 2)));
    // What is due this month, and the next three things due from now (they may be next month).
    calendar_refresh_if_stale();
    Json due = Json::array(), coming = Json::array();
    const auto now = std::time(nullptr);
    for (const auto& d : due_items()) {
        const std::tm tm = *std::localtime(&d.at);
        if (tm.tm_year + 1900 == year && tm.tm_mon + 1 == number) due.push_back(due_row(d));
        if (d.at >= now - 3600 && coming.size() < 3) coming.push_back(due_row(d));
    }
    return Json{{"ok", true}, {"month", month}, {"days", list}, {"today", today_commits.size()}, {"due", due}, {"coming", coming}};
}

// The commit garden: how many commits you wrote on each day, from the Sunday 52 weeks before this week's to today.
Json commit_year(const Json& config) {
    const std::time_t now = std::time(nullptr);
    std::tm first = *std::localtime(&now);
    first.tm_mday -= first.tm_wday + 52 * 7; first.tm_hour = 12; first.tm_min = first.tm_sec = 0; first.tm_isdst = -1;
    const std::time_t start = std::mktime(&first);
    std::map<std::string, size_t> index;
    std::vector<std::string> days;
    for (std::tm day = first;; ++day.tm_mday) {
        std::tm probe = day; probe.tm_isdst = -1;
        const auto name = local_day(std::mktime(&probe));
        index[name] = days.size(); days.push_back(name);
        if (name == local_day(now) || days.size() > 380) break;
    }
    std::vector<std::set<std::string>> written(days.size());
    for (const auto& commit : own_commits(config, local_day(start), {})) {
        const auto at = index.find(commit.authored);
        if (at != index.end()) written[at->second].insert(commit.key);
    }
    Json counts = Json::array();
    for (const auto& keys : written) counts.push_back(keys.size());
    // Days a test run went green again after failing at least twice in a row: a pressed flower on that square.
    std::set<size_t> green;
    Json jobs;
    if (sh::have("desk-work") && capture_json({"desk-work", "jobs"}, jobs) && jobs.is_array())
        for (const auto& j : jobs) {
            if (!j.is_object() || text(j, "state") != "passed" || !truth(j, "testRun") || whole(j, "failedBefore") < 2) continue;
            if (!j.contains("ended") || !j["ended"].is_number_integer()) continue;
            const auto at = index.find(local_day(static_cast<std::time_t>(j["ended"].get<long long>())));
            if (at != index.end()) green.insert(at->second);
        }
    return Json{{"start", days.front()}, {"counts", counts}, {"green", Json(std::vector<size_t>(green.begin(), green.end()))}};
}

// What the Today sheet adds to the group summaries: the battery, agent notes and the next thing on ~/.todo.
Json today_summary(const Json& config) {
    // The API meter is its own program (a Python start-up), so it runs while the rest of the day is read.
    auto credits_read = std::async(std::launch::async, [] {
        Json credits;
        return sh::have("desk-credits") && capture_json({"desk-credits", "status"}, credits) && credits.is_object() ? credits : Json();
    });
    const auto notes = agent_notes();
    Json today{{"notes", notes.size()}, {"todo", ""}, {"waiting", Json::array()}};
    // An agent is waiting when its pane's newest note says its turn ended or it asked for something.
    // One tag per project: the newest pane is where its tag goes, and the count says how many wait there.
    std::map<std::string, size_t> projects_seen;
    for (auto at = notes.rbegin(); at != notes.rend(); ++at) {
        const auto event = text(at->second, "event");
        if (event != "stop" && event != "notification") continue;
        const auto project = text(at->second, "project", "An agent");
        const auto seen = projects_seen.find(project);
        if (seen != projects_seen.end()) {
            auto& tag = today["waiting"][seen->second];
            tag["count"] = tag["count"].get<int>() + 1;
            if (event == "notification") tag["asking"] = true;
            continue;
        }
        if (today["waiting"].size() >= 4) continue;
        projects_seen[project] = today["waiting"].size();
        today["waiting"].push_back(Json{{"project", project}, {"argument", at->first}, {"asking", event == "notification"}, {"count", 1}});
    }
    ClaudeUsage usage;
    int busy = 0;
    const auto sessions = claude_sessions(usage);
    for (const auto& session : sessions) busy += claude_busy(session);
    today["claudeWorking"] = busy;
    today["claudeSessions"] = static_cast<int>(sessions.size());
    today["claudeUsage"] = claude_left_line(usage);
    today["claudeMinutes"] = claude_minutes_today(sessions);
    // The teacup: how much of the week is left, or -1 when there is no reading.
    today["claudeWeekLeft"] = usage.week >= 0 ? std::max(0, 100 - usage.week) : -1;
    today["claudeBerry"] = usage.five >= 80 || usage.week >= 80;
    // Due within two days, from the course calendars (read in the background).
    calendar_refresh_if_stale();
    today["dueSoon"] = Json::array();
    for (const auto& d : due_items()) {
        const auto now = std::time(nullptr);
        if (d.at < now - 1800 || d.at > now + 48 * 3600 || today["dueSoon"].size() >= 3) continue;
        today["dueSoon"].push_back(Json{{"title", d.title}, {"course", d.course}, {"when", due_when(d)}});
    }
    const auto work = work_data(config);
    if (const auto credits = credits_read.get(); credits.is_object()) today["apiCredits"] = credits;
    if (work.is_object()) {
        today["jobsRunning"] = whole(work, "running"); today["jobsFinished"] = whole(work, "finished");
        today["jobsFailed"] = whole(work, "failed");
        today["changesToReview"] = work.value("reviews", Json::array()).size();
        today["nextSteps"] = work.value("tasks", Json::array()).size();
        if (!work.value("tasks", Json::array()).empty()) today["nextStep"] = text(work["tasks"][0], "text");
        // The first running job that has run before: how long it took then is how long to expect now.
        for (const auto& j : work.value("jobs", Json::array())) {
            if (text(j, "state") != "running" || !j.contains("estimate") || !j["estimate"].is_number_integer()) continue;
            const long long estimate = j["estimate"].get<long long>(), elapsed = std::max(0LL, static_cast<long long>(std::time(nullptr)) - (j.contains("started") && j["started"].is_number_integer() ? j["started"].get<long long>() : 0LL));
            auto name = text(j, "title", text(j, "command"));
            if (name.size() > 48) name = name.substr(0, 47) + "…";
            const long long left = estimate - elapsed;
            today["runningJob"] = Json{{"name", name}, {"left", left > 0 ? (left < 60 ? std::string("under a minute left") : "about " + std::to_string((left + 30) / 60) + "m left") : std::string("taking longer than last time")}};
            break;
        }
    }
    today["lastNight"] = last_night_notes();
    for (const auto& line : lines(read(fs::path(home()) / ".todo"))) if (!trim(line).empty()) { today["todo"] = trim(line); break; }
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator("/sys/class/power_supply", ec)) {
        if (entry.path().filename().string().rfind("BAT", 0) != 0) continue;
        const auto level = trim(read(entry.path() / "capacity"));
        if (level.empty()) continue;
        today["battery"] = level + "%"; today["batteryState"] = lower(trim(read(entry.path() / "status")));
        break;
    }
    return today;
}

// ─── Models: the local models fox-llm keeps, which role uses each, and whether the router serves it ───────────
fs::path llm_config_dir() { return fs::path(env("XDG_CONFIG_HOME", home() + "/.config")) / "foxml/llm"; }
fs::path gguf_dir() { return fs::path(env("XDG_DATA_HOME", home() + "/.local/share")) / "fox-llm/gguf"; }
// The first roles file there is, as DeskIntel and llm-update read them.
fs::path roles_file() {
    for (const auto& path : {llm_config_dir() / "roles.conf", fs::path(home()) / "code/custom_models/roles.conf", llm_config_dir() / "roles.default"})
        if (regular(path)) return path;
    return {};
}
std::map<std::string, std::vector<std::string>> model_roles() {
    std::map<std::string, std::vector<std::string>> roles;
    const auto file = roles_file();
    if (file.empty()) return roles;
    for (const auto& line : lines(read(file))) {
        std::istringstream fields(line);
        std::string role, model;
        if (!(fields >> role >> model) || role.empty() || role[0] == '#') continue;
        roles[model].push_back(role);
    }
    return roles;
}
bool known_model(const std::string& name) {
    return std::regex_match(name, std::regex("[A-Za-z0-9][A-Za-z0-9._:-]{0,119}")) && regular(gguf_dir() / (name + ".gguf"));
}
fs::path llm_tool(const char* name) { return fs::path(home()) / ".local/bin" / name; }
Json model_use_for_agent(const std::string& name) {
    if (!known_model(name)) return result(false, "That model is not here");
    const auto from = roles_file();
    const auto target = llm_config_dir() / "roles.conf";
    std::vector<std::string> kept;
    bool replaced = false;
    for (const auto& line : lines(from.empty() ? std::string() : read(from))) {
        std::istringstream fields(line);
        std::string role, model, rest, word;
        if ((fields >> role >> model) && role == "agent") {
            std::string server = "llama";
            fields >> server;  // the server stays; a ctx= belonged to the old model, so it goes
            kept.push_back("agent " + name + " " + server);
            replaced = true;
        } else kept.push_back(line);
    }
    if (!replaced) kept.push_back("agent " + name + " llama");
    std::string text;
    for (const auto& line : kept) text += line + "\n";
    std::error_code ec;
    fs::create_directories(target.parent_path(), ec);
    if (regular(target)) {
        char stamp[32] = {}; const std::time_t now = std::time(nullptr);
        std::strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", std::localtime(&now));
        if (!write_atomic(target.string() + ".bak-" + stamp, read(target))) return result(false, "Could not back up roles.conf");
    }
    if (!write_atomic(target, text)) return result(false, "Could not write roles.conf");
    std::string out;
    if (regular(llm_tool("llm-update"))) capture({llm_tool("llm-update").string(), "--sync"}, out);
    return result(true, name + " is the agent model now");
}
Json model_remove(const std::string& name, bool confirmed) {
    if (!confirmed) return result(false, "Confirmation required");
    if (!known_model(name)) return result(false, "That model is not here");
    const auto roles = model_roles();
    if (roles.count(name)) return result(false, "A role uses " + name + "; give that role another model first");
    std::error_code ec;
    fs::remove(gguf_dir() / (name + ".gguf"), ec);
    if (ec) return result(false, "Could not remove " + name);
    // A skip line in this machine's own list (never in a repo): llm-update won't fetch it again from any list.
    const auto list = llm_config_dir() / "gguf-models.txt";
    std::string text = regular(list) ? read(list) : "# This machine's picks and skips. A \"-name\" line skips a model from every list.\n";
    if (!text.empty() && text.back() != '\n') text += "\n";
    text += "-" + name + "\n";
    if (!write_atomic(list, text)) return result(false, name + " removed, but its skip line could not be written");
    std::string out;
    if (regular(llm_tool("llm-update"))) capture({llm_tool("llm-update").string(), "--sync"}, out);
    capture({"systemctl", "--user", "try-restart", "fox-llm-server.service"}, out);
    return result(true, name + " removed");
}

void model_rows(Json& rows) {
    std::error_code ec;
    if (!directory(gguf_dir())) {
        auto row = item("model-agent", "No local models here", "action", "The local AI layer is optional: desk ai sets it up", "info");
        row["enabled"] = false; rows.push_back(row); return;
    }
    const auto roles = model_roles();
    const auto presets = read(llm_config_dir() / "llama-presets.ini");
    std::vector<std::pair<uint64_t, std::string>> models;
    for (const auto& entry : fs::directory_iterator(gguf_dir(), ec)) {
        if (entry.path().extension() != ".gguf" || !entry.is_regular_file(ec)) continue;
        models.push_back({entry.file_size(ec), entry.path().stem().string()});
    }
    std::sort(models.rbegin(), models.rend());
    const auto joined = [](const std::vector<std::string>& list) { std::string s; for (const auto& r : list) s += (s.empty() ? "" : ", ") + r; return s; };
    for (const auto& [bytes, name] : models) {
        const bool used = roles.count(name) > 0;
        const bool agent = used && std::find(roles.at(name).begin(), roles.at(name).end(), "agent") != roles.at(name).end();
        const bool served = presets.find("[" + name + "]") != std::string::npos;
        auto row = item("model-agent", name, "action", capacity(bytes) + " · " + (used ? "the " + joined(roles.at(name)) + " model" : "no role") + (served ? "" : " · not served"), "cpu");
        row["argument"] = name;
        if (agent) { row["enabled"] = false; row["disabledReason"] = "Already the agent model"; }
        else row["confirm"] = true;
        rows.push_back(row);
    }
    auto head = item("model-remove", "Remove a model", "action", "Deleted from disk, and skipped by the nightly update", "info");
    head["enabled"] = false; rows.push_back(head);
    for (const auto& [bytes, name] : models) {
        auto row = item("model-remove", "Remove " + name, "action", capacity(bytes), "trash");
        row["argument"] = name;
        if (roles.count(name)) { row["enabled"] = false; row["disabledReason"] = "The " + joined(roles.at(name)) + " role uses it; give the role another model first"; }
        else row["confirm"] = true;
        rows.push_back(row);
    }
}

// ─── Storage: what uses the disk, measured in the background and kept for the page ────────────────────────────
fs::path storage_cache() { return fs::path(env("XDG_CACHE_HOME", home() + "/.cache")) / "foxml/storage.json"; }
fs::path storage_lock() { return runtime() / "foxml-storage-scan.lock"; }
struct StorageKind { const char* id; const char* label; std::vector<std::string> paths; const char* action; const char* hint; };
std::vector<StorageKind> storage_kinds() {
    return {
        {"packages", "Package cache", {"/var/cache/pacman/pkg", "~/.cache/yay", "~/.cache/paru"}, "storage-clean-packages", "old versions of installed packages"},
        {"models", "Local AI models", {"~/.local/share/fox-llm", "~/.cache/huggingface", "~/.ollama", "/usr/share/ollama/.ollama", "/var/lib/ollama", "~/.lmstudio", "~/.cache/lm-studio"}, "", "see Desk → Models"},
        {"games", "Games", {"~/.local/share/Steam", "~/.var/app/com.valvesoftware.Steam", "~/Games", "~/.local/share/lutris"}, "", "uninstall games from their launcher"},
        {"vms", "VM and container images", {"~/.local/share/libvirt/images", "/var/lib/libvirt/images", "~/.local/share/containers", "/var/lib/containers", "/var/lib/docker", "~/.local/share/gnome-boxes", "~/VirtualBox VMs"}, "", "remove images you no longer use"},
        {"flatpak", "Flatpak apps and runtimes", {"~/.local/share/flatpak", "/var/lib/flatpak"}, "storage-flatpak-unused", "unused runtimes can go"},
        {"dev", "Language and build caches", {"~/.npm", "~/.cache/pip", "~/.cache/uv", "~/.cargo/registry", "~/.cache/go-build", "~/.cache/ccache", "~/.ccache", "~/.cache/yarn", "~/.cache/pnpm", "~/.gradle/caches", "~/.m2/repository"}, "", "rebuilt when needed"},
        {"browser", "Browser caches", {"~/.cache/mozilla", "~/.cache/chromium", "~/.cache/google-chrome", "~/.cache/BraveSoftware"}, "", "rebuilt as you browse"},
        {"trash", "Trash", {"~/.local/share/Trash"}, "storage-empty-trash", "files you deleted"},
    };
}
std::string expand_home(const std::string& path) { return path.rfind("~/", 0) == 0 ? home() + path.substr(1) : path; }
// du's bytes for one path, and whether some of it was out of reach.
std::pair<uint64_t, bool> du_bytes(const std::string& path, int seconds) {
    std::string out;
    const int status = sh::probe({"timeout", std::to_string(seconds), "du", "-sxb", path}, out);
    uint64_t bytes = 0;
    const auto first = out.substr(0, out.find('\t'));
    std::from_chars(first.data(), first.data() + first.size(), bytes);
    return {bytes, status != 0};
}
int storage_scan() {
    std::error_code ec;
    fs::create_directories(storage_cache().parent_path(), ec);
    if (regular(storage_lock())) return 0;  // one scan at a time
    write_atomic(storage_lock(), std::to_string(::getpid()) + "\n");
    Json kinds = Json::array();
    for (const auto& kind : storage_kinds()) {
        uint64_t total = 0; bool partial = false; Json found = Json::array();
        for (const auto& raw : kind.paths) {
            const auto path = expand_home(raw);
            if (!fs::exists(path, ec)) continue;
            const auto [bytes, hidden] = du_bytes(path, 120);
            total += bytes; partial = partial || hidden;
            if (bytes > 0) found.push_back(Json{{"path", path}, {"bytes", bytes}});
        }
        if (found.empty()) continue;
        kinds.push_back(Json{{"id", kind.id}, {"label", kind.label}, {"bytes", total}, {"partial", partial}, {"paths", found}});
    }
    // The journal says its own size.
    std::string journal;
    if (sh::have("journalctl") && capture({"journalctl", "--disk-usage"}, journal)) {
        std::smatch m;
        if (std::regex_search(journal, m, std::regex("([0-9.]+)([KMGT])"))) {
            const double value = std::stod(m[1].str());
            const double scale = m[2] == "K" ? 1e3 : m[2] == "M" ? 1e6 : m[2] == "G" ? 1e9 : 1e12;
            kinds.push_back(Json{{"id", "journal"}, {"label", "System journal"}, {"bytes", static_cast<uint64_t>(value * scale)}, {"partial", false}, {"paths", Json::array()}});
        }
    }
    // The largest folders two levels into home, on this disk only.
    Json largest = Json::array();
    std::string out;
    sh::probe({"timeout", "300", "du", "-xb", "--max-depth=2", home()}, out);
    std::vector<std::pair<uint64_t, std::string>> folders;
    for (const auto& line : lines(out)) {
        const auto tab = line.find('\t');
        if (tab == std::string::npos) continue;
        uint64_t bytes = 0; std::from_chars(line.data(), line.data() + tab, bytes);
        const auto path = line.substr(tab + 1);
        if (path == home()) continue;
        folders.push_back({bytes, path});
    }
    std::sort(folders.rbegin(), folders.rend());
    // A folder shown already through one of its children says less; keep the more specific ones.
    std::vector<std::string> kept;
    for (const auto& [bytes, path] : folders) {
        if (kept.size() >= 8) break;
        bool parent = false;
        for (const auto& [other_bytes, other] : folders)
            if (other != path && other.rfind(path + "/", 0) == 0 && other_bytes * 10 >= bytes * 7) { parent = true; break; }
        if (parent) continue;
        kept.push_back(path);
        largest.push_back(Json{{"path", path}, {"bytes", bytes}});
    }
    // What the disk counts but nothing visible holds: usually places only root can read.
    struct statvfs disk{};
    uint64_t used = 0, size = 0, avail = 0;
    if (::statvfs(home().c_str(), &disk) == 0) {
        size = static_cast<uint64_t>(disk.f_blocks) * disk.f_frsize;
        avail = static_cast<uint64_t>(disk.f_bavail) * disk.f_frsize;
        used = size - static_cast<uint64_t>(disk.f_bfree) * disk.f_frsize;
    }
    std::string root_out;
    sh::probe({"timeout", "600", "du", "-sxb", "/"}, root_out);
    uint64_t visible = 0;
    const auto first = root_out.substr(0, root_out.find('\t'));
    std::from_chars(first.data(), first.data() + first.size(), visible);
    const uint64_t hidden = visible > 0 && used > visible ? used - visible : 0;
    Json data{{"at", static_cast<long long>(std::time(nullptr))}, {"used", used}, {"size", size}, {"available", avail},
              {"hidden", hidden}, {"kinds", kinds}, {"largest", largest}};
    write_atomic(storage_cache(), data.dump() + "\n");
    fs::remove(storage_lock(), ec);
    return 0;
}
std::string ago(long long seconds) {
    if (seconds < 90) return "just now";
    if (seconds < 3600) return std::to_string(seconds / 60) + " minutes ago";
    if (seconds < 172800) return std::to_string(seconds / 3600) + (seconds < 7200 ? " hour ago" : " hours ago");
    return std::to_string(seconds / 86400) + " days ago";
}
bool scan_running() {
    if (!regular(storage_lock())) return false;
    const auto pid = trim(read(storage_lock()));
    if (!pid.empty() && fs::exists(fs::path("/proc") / pid)) return true;
    std::error_code ec; fs::remove(storage_lock(), ec);  // a scan that died
    return false;
}
void storage_rows(Json& rows) {
    const auto data = Json::parse(read(storage_cache()), nullptr, false);
    if (scan_running()) {
        auto row = item("storage-scan", "Measuring the disk…", "action", "This takes a minute or two; the page fills in when it's done", "info");
        row["enabled"] = false; rows.push_back(row);
    }
    if (!data.is_object()) {
        if (!scan_running()) rows.push_back(item("storage-scan", "Measure the disk", "action", "Find what uses the space · a minute or two, in the background", "info"));
        return;
    }
    const auto num = [](const Json& o, const char* k) { return o.contains(k) && o[k].is_number() ? o[k].get<uint64_t>() : uint64_t(0); };
    const long long at = data.contains("at") && data["at"].is_number() ? data["at"].get<long long>() : 0;
    auto head = item("storage-scan", capacity(num(data, "available")) + " free of " + capacity(num(data, "size")), "action",
                     "Measured " + ago(static_cast<long long>(std::time(nullptr)) - at) + " · Enter measures again", "info");
    if (scan_running()) head["enabled"] = false;
    rows.push_back(head);
    std::vector<Json> kinds;
    if (data.contains("kinds") && data["kinds"].is_array()) for (const auto& k : data["kinds"]) kinds.push_back(k);
    std::sort(kinds.begin(), kinds.end(), [&](const Json& a, const Json& b) { return num(a, "bytes") > num(b, "bytes"); });
    std::map<std::string, std::pair<std::string, std::string>> extra;
    for (const auto& kind : storage_kinds()) extra[kind.id] = {kind.action, kind.hint};
    for (const auto& kind : kinds) {
        const auto id = text(kind, "id");
        if (num(kind, "bytes") < 50ull * 1000 * 1000) continue;
        const auto [action, hint] = extra.count(id) ? extra[id] : std::pair<std::string, std::string>{"", ""};
        std::string detail = capacity(num(kind, "bytes")) + (hint.empty() ? "" : " · " + hint);
        if (kind.contains("partial") && kind["partial"] == true) detail += " · part of it is root-only";
        std::string act = action;
        if (id == "journal") act = "storage-trim-journal";
        auto row = item(act.empty() ? "storage-open" : act, text(kind, "label"), "action", detail, "folder");
        if (act.empty()) {
            const auto& paths = kind["paths"];
            if (paths.is_array() && !paths.empty()) row["argument"] = text(paths[0], "path"); else row["enabled"] = false;
        }
        if (act == "storage-empty-trash") row["confirm"] = true;
        rows.push_back(row);
    }
    if (num(data, "hidden") > 5ull * 1000 * 1000 * 1000) {
        auto row = item("storage-hidden", capacity(num(data, "hidden")) + " the disk counts but no folder shows", "action",
                        "Usually places only root can read · Enter looks in a terminal", "info");
        rows.push_back(row);
    }
    if (data.contains("largest") && data["largest"].is_array() && !data["largest"].empty()) {
        auto label = item("storage-open", "Largest folders in your home", "action", "", "info"); label["enabled"] = false; rows.push_back(label);
        for (const auto& folder : data["largest"]) {
            auto path = text(folder, "path");
            auto shown = path.rfind(home() + "/", 0) == 0 ? "~" + path.substr(home().size()) : path;
            auto row = item("storage-open", shown, "action", capacity(num(folder, "bytes")), "folder");
            row["argument"] = path; rows.push_back(row);
        }
    }
}
bool storage_known_path(const std::string& path) {
    const auto data = Json::parse(read(storage_cache()), nullptr, false);
    if (!data.is_object()) return false;
    for (const char* list : {"largest"}) if (data.contains(list) && data[list].is_array())
        for (const auto& entry : data[list]) if (text(entry, "path") == path) return true;
    if (data.contains("kinds") && data["kinds"].is_array())
        for (const auto& kind : data["kinds"]) if (kind.contains("paths") && kind["paths"].is_array())
            for (const auto& entry : kind["paths"]) if (text(entry, "path") == path) return true;
    return false;
}

// ─── Backups: what the theme tools and the installer kept before replacing files ───────────────────────────────
fs::path backups_root() { return fs::path(env("XDG_STATE_HOME", home() + "/.local/state")) / "foxml"; }
struct Backup { fs::path path; std::string name, when, label; bool restorable = false; };
std::vector<Backup> backups() {
    std::vector<Backup> found;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(backups_root(), ec)) {
        if (!entry.is_directory(ec)) continue;
        const auto name = entry.path().filename().string();
        std::smatch m;
        if (name.find("backup") == std::string::npos || !std::regex_search(name, m, std::regex("(20[0-9]{6})-([0-9]{6})(?:-(.*))?"))) continue;
        Backup b; b.path = entry.path(); b.name = name;
        const auto d = m[1].str(), t = m[2].str();
        b.when = d.substr(0, 4) + "-" + d.substr(4, 2) + "-" + d.substr(6, 2) + " " + t.substr(0, 2) + ":" + t.substr(2, 2);
        b.label = m[3].matched ? m[3].str() : (name.rfind("theme-backup", 0) == 0 ? "theme" : name.substr(0, name.find("-backup")));
        b.restorable = regular(entry.path() / "restore.sh") && regular(entry.path() / "manifest");
        found.push_back(b);
    }
    std::sort(found.begin(), found.end(), [](const Backup& a, const Backup& b) { return a.when > b.when; });
    return found;
}
void backup_rows(Json& rows) {
    const auto all = backups();
    if (all.size() > 10) {
        auto row = item("backup-prune", "Keep the newest 10", "action", "Removes the " + std::to_string(all.size() - 10) + " older backups", "info");
        row["confirm"] = true; rows.push_back(row);
    }
    for (const auto& b : all) {
        std::size_t files = 0; std::error_code ec;
        for (fs::recursive_directory_iterator it(b.path, fs::directory_options::skip_permission_denied, ec), end; !ec && it != end; it.increment(ec))
            if (it->is_regular_file(ec)) ++files;
        auto row = item(b.restorable ? "backup-restore" : "backup-open", b.label, "action",
                        b.when + " · " + std::to_string(files) + (files == 1 ? " file" : " files") + (b.restorable ? " · Enter puts them back" : " · Enter opens the folder"),
                        b.restorable ? "refresh" : "folder");
        row["argument"] = b.name;
        if (b.restorable) row["confirm"] = true;
        rows.push_back(row);
    }
    if (all.empty()) { auto row = item("backup-open", "No backups yet", "action", "The theme tools keep one before they replace files", "info"); row["enabled"] = false; rows.push_back(row); }
}
std::optional<Backup> find_backup(const std::string& name) {
    for (const auto& b : backups()) if (b.name == name) return b;
    return std::nullopt;
}

// ─── Startup: what starts with the session ─────────────────────────────────────────────────────────────────────
fs::path user_autostart() { return fs::path(env("XDG_CONFIG_HOME", home() + "/.config")) / "autostart"; }
std::map<std::string, std::string> desktop_fields(const fs::path& file) {
    std::map<std::string, std::string> fields; bool entry = false;
    for (const auto& raw : lines(read(file))) {
        const auto line = trim(raw);
        if (!line.empty() && line.front() == '[') { entry = line == "[Desktop Entry]"; continue; }
        const auto eq = line.find('=');
        if (entry && eq != std::string::npos && !fields.count(line.substr(0, eq))) fields[line.substr(0, eq)] = line.substr(eq + 1);
    }
    return fields;
}
// ── Programs: what is using the computer right now, one row per program (its helper processes counted with it).
// Only your own processes are read or quit; the desktop's own parts are shown but never quit from here.
fs::path proc_root() { return env("FOXML_PROC", "/proc"); }
fs::path quit_asked_file() { return fs::path(env("XDG_STATE_HOME", home() + "/.local/state")) / "foxml/quit-asked.json"; }
struct Proc { int pid = 0, ppid = 0; unsigned long long ticks = 0, start = 0; long long rss = 0; std::string name, label; };
std::map<int, Proc> read_procs() {
    std::map<int, Proc> out;
    std::error_code ec;
    const long page = std::max(1L, ::sysconf(_SC_PAGESIZE));
    for (const auto& entry : fs::directory_iterator(proc_root(), ec)) {
        const auto base = entry.path().filename().string();
        if (base.empty() || !std::all_of(base.begin(), base.end(), [](unsigned char c) { return std::isdigit(c); })) continue;
        struct stat owner{};
        if (::stat(entry.path().c_str(), &owner) != 0 || owner.st_uid != ::getuid()) continue;
        const auto stat_text = read(entry.path() / "stat");
        const auto open = stat_text.find('('), close = stat_text.rfind(')');
        if (open == std::string::npos || close == std::string::npos || close + 2 > stat_text.size()) continue;
        std::istringstream rest(stat_text.substr(close + 2));
        std::vector<std::string> field; std::string word;
        while (rest >> word) field.push_back(word);
        if (field.size() < 20) continue;
        Proc proc;
        const auto number = [](const std::string& s, auto& value) { return std::from_chars(s.data(), s.data() + s.size(), value).ec == std::errc(); };
        unsigned long long user = 0, system = 0;
        if (!number(base, proc.pid) || !number(field[1], proc.ppid) || !number(field[11], user) || !number(field[12], system)
            || !number(field[19], proc.start)) continue;
        proc.ticks = user + system;
        std::istringstream statm(read(entry.path() / "statm"));
        long long size = 0, resident = 0;
        statm >> size >> resident;
        proc.rss = resident * page;
        auto exe = fs::read_symlink(entry.path() / "exe", ec).filename().string();
        ec.clear();
        if (const auto deleted = exe.find(" (deleted)"); deleted != std::string::npos) exe.erase(deleted);
        // A program file named for its version (Claude Code's "2.1.319") goes by its process name instead.
        const auto comm = stat_text.substr(open + 1, close - open - 1);
        proc.name = exe.empty() || std::regex_match(exe, std::regex("[0-9][0-9.]*")) ? comm : exe;
        proc.label = proc.name;
        // An interpreter is named by what it runs: "python3 · fox-foo.py".
        if (std::regex_match(proc.name, std::regex("(python[0-9.]*|node|bash|sh|zsh|perl|ruby|lua[0-9.]*)"))) {
            const auto cmdline = read(entry.path() / "cmdline");
            std::vector<std::string> argv; std::string arg;
            for (const char c : cmdline) { if (c) arg += c; else { argv.push_back(arg); arg.clear(); } }
            if (!arg.empty()) argv.push_back(arg);
            for (std::size_t i = 1; i < argv.size(); ++i) {
                if (argv[i] == "-c") break;                                   // inline code: no script to name
                if (argv[i] == "-m" && i + 1 < argv.size()) { proc.label += " · " + argv[i + 1]; break; }
                if (!argv[i].empty() && argv[i][0] != '-') {
                    const auto script = fs::path(argv[i]).filename().string();
                    if (std::regex_match(script, std::regex("[A-Za-z0-9@._+-]{1,60}"))) proc.label += " · " + script;
                    break;
                }
            }
        }
        // Tools that work inside a project say which one, so three Claudes are told apart.
        if (std::regex_match(proc.name, std::regex("(claude|codex|nvim|clangd|pi)"))) {
            const auto folder = fs::read_symlink(entry.path() / "cwd", ec).filename().string();
            ec.clear();
            if (!folder.empty()) proc.label += " · " + folder;
        }
        out[proc.pid] = proc;
    }
    return out;
}
struct Program { int pid = 0; unsigned long long start = 0; std::string name, label; double cpu = 0; long long rss = 0; std::vector<int> pids; };
// A process joins the nearest ancestor running the same program, so Firefox's helpers sit under Firefox.
std::vector<Program> group_programs(const std::map<int, Proc>& now, const std::map<int, Proc>& before, double seconds) {
    const double hz = static_cast<double>(std::max(1L, ::sysconf(_SC_CLK_TCK)));
    std::map<int, Program> groups;
    for (const auto& [pid, proc] : now) {
        int root = pid;
        for (int depth = 0; depth < 64; ++depth) {
            const auto parent = now.find(now.at(root).ppid);
            if (parent == now.end() || parent->second.name != proc.name) break;
            root = parent->first;
        }
        auto& group = groups[root];
        if (group.pids.empty()) { const auto& top = now.at(root); group.pid = root; group.start = top.start; group.name = top.name; group.label = top.label; }
        group.pids.push_back(pid);
        group.rss += proc.rss;
        const auto earlier = before.find(pid);
        if (seconds > 0 && earlier != before.end() && earlier->second.start == proc.start && proc.ticks >= earlier->second.ticks)
            group.cpu += (proc.ticks - earlier->second.ticks) / hz / seconds * 100.0;
    }
    std::vector<Program> out;
    for (auto& [root, group] : groups) out.push_back(std::move(group));
    return out;
}
std::vector<Program> sample_programs() {
    int ms = 250;
    const auto wanted = env("FOXML_PROC_SAMPLE_MS");
    if (!wanted.empty()) std::from_chars(wanted.data(), wanted.data() + wanted.size(), ms);
    const auto before = read_procs();
    if (ms > 0) std::this_thread::sleep_for(std::chrono::milliseconds(ms));
    return group_programs(read_procs(), before, ms / 1000.0);
}
// The desktop's own parts: quitting one from a menu would take the menu (or the session) with it.
bool desktop_part(const std::string& name) {
    static const std::regex parts("(Hyprland|quickshell|qs|systemd|\\(sd-pam\\)|dbus-.*|pipewire.*|wireplumber|xdg-.*portal.*|hyprpolkitagent|"
                                  "gnome-keyring-daemon|desk-pulse|desk-vault|desk-drawer|ssh-agent|gpg-agent|at-spi.*|hypridle|swww-daemon|mako|dunst)");
    return std::regex_match(name, parts);
}
std::string memory_text(long long bytes) {
    std::ostringstream out;
    if (bytes >= 1024LL * 1024 * 1024) out << std::fixed << std::setprecision(1) << bytes / (1024.0 * 1024 * 1024) << " GB";
    else out << std::max(1LL, bytes / (1024 * 1024)) << " MB";
    return out.str();
}
Json quit_asked() {
    std::ifstream file(quit_asked_file());
    auto asked = Json::parse(file, nullptr, false);
    return asked.is_object() ? asked : Json::object();
}
void programs_rows(Json& rows) {
    auto programs = sample_programs();
    const auto asked = quit_asked();
    const auto now = static_cast<long long>(std::time(nullptr));
    std::set<int> shown;
    const auto row_for = [&](const Program& program) {
        const auto key = std::to_string(program.pid) + ":" + std::to_string(program.start);
        std::string detail = std::to_string(static_cast<int>(std::lround(program.cpu))) + "% CPU · " + memory_text(program.rss);
        if (program.pids.size() > 1) detail += " · " + std::to_string(program.pids.size()) + " processes";
        if (desktop_part(program.name)) {
            auto row = item("program-quit", program.label, "action", detail + " · part of your desktop", "shield");
            row["enabled"] = false; return row;
        }
        const bool terminal = std::regex_match(program.name, std::regex("(kitty|tmux.*|foot|alacritty|wezterm.*)"));
        const auto it = asked.find(key);
        if (it != asked.end() && it->is_number() && now - it->get<long long>() >= 3) {
            auto row = item("program-force", "Force quit " + program.label, "action", "It did not quit when asked · " + detail, "cpu");
            row["argument"] = key; row["confirm"] = "Force quit " + program.label + " now? Anything unsaved in it is lost."; return row;
        }
        auto row = item("program-quit", program.label, "action", detail, "cpu");
        row["argument"] = key;
        row["confirm"] = terminal ? "Quit " + program.label + "? Every one of its windows closes, and what runs in them (Claude sessions too)."
                                  : "Quit " + program.label + "? Anything unsaved in it may be lost.";
        return row;
    };
    std::sort(programs.begin(), programs.end(), [](const Program& a, const Program& b) { return a.cpu > b.cpu; });
    rows.push_back(heading("busy right now"));
    for (const auto& program : programs) {
        if (shown.size() >= 6 || program.cpu < 1.0) break;
        rows.push_back(row_for(program)); shown.insert(program.pid);
    }
    if (shown.empty()) { auto calm = item("programs-calm", "Nothing is busy right now", "action", "Every program is idle", "info"); calm["enabled"] = false; rows.push_back(calm); }
    std::sort(programs.begin(), programs.end(), [](const Program& a, const Program& b) { return a.rss > b.rss; });
    rows.push_back(heading("using the most memory"));
    int listed = 0;
    for (const auto& program : programs) {
        if (listed >= 6) break;
        if (shown.count(program.pid)) continue;
        rows.push_back(row_for(program)); ++listed;
    }
}
// The pid and its start time name one process; a pid reused since the page was read is never signalled.
std::optional<Program> program_at(const std::string& key) {
    std::smatch m;
    if (!std::regex_match(key, m, std::regex("([0-9]{1,9}):([0-9]{1,20})"))) return std::nullopt;
    for (auto& program : group_programs(read_procs(), {}, 0))
        if (std::to_string(program.pid) == m[1].str() && std::to_string(program.start) == m[2].str()) return program;
    return std::nullopt;
}
Json program_quit(const std::string& key, bool confirmed, bool force) {
    if (!confirmed) return result(false, "Confirmation required");
    const auto program = program_at(key);
    if (!program) return result(false, "That program has already quit");
    if (desktop_part(program->name)) return result(false, program->label + " is part of your desktop");
    auto asked = quit_asked();
    // Forget the asks whose programs are gone, so the file stays small.
    for (auto it = asked.begin(); it != asked.end();) {
        if (it.key() != key && !program_at(it.key())) it = asked.erase(it); else ++it;
    }
    if (force) {
        for (const int pid : program->pids) ::kill(pid, SIGKILL);
        asked.erase(key);
    } else {
        if (::kill(program->pid, SIGTERM) != 0) return result(false, "Could not ask " + program->label + " to quit");
        asked[key] = static_cast<long long>(std::time(nullptr));
    }
    std::error_code ec;
    fs::create_directories(quit_asked_file().parent_path(), ec);
    write_atomic(quit_asked_file(), asked.dump());
    return result(true, force ? program->label + " force quit" : "Asked " + program->label + " to quit");
}
// ── Terminals: tmux sessions by name, where each is shown, and moving them about. Every tmux call names its target
// exactly (=name, %pane); nothing here ever stops the server itself.
// work: what the Claude in that pane is working on (the pane's @work label, set by the notebook), or "".
struct TmuxPane { std::string id, session, window, cmd, path; bool active = false; std::string work; };
struct TmuxSession { std::string name; int windows = 0; long long activity = 0; std::vector<TmuxPane> panes; std::vector<int> clients; };
std::vector<std::string> tabs(const std::string& line) {
    std::vector<std::string> out;
    for (size_t at = 0;;) { const auto tab = line.find('\t', at); out.push_back(line.substr(at, tab == std::string::npos ? std::string::npos : tab - at)); if (tab == std::string::npos) break; at = tab + 1; }
    return out;
}
std::vector<TmuxSession> tmux_sessions() {
    std::vector<TmuxSession> out;
    std::string text;
    if (!sh::have("tmux") || !capture({"tmux", "list-sessions", "-F", "#{session_name}\t#{session_windows}\t#{session_activity}"}, text)) return out;
    std::map<std::string, size_t> at;
    for (const auto& line : lines(text)) {
        const auto f = tabs(line);
        if (f.size() < 3 || f[0].empty()) continue;
        TmuxSession s; s.name = f[0]; s.windows = std::atoi(f[1].c_str()); s.activity = std::atoll(f[2].c_str());
        at[s.name] = out.size(); out.push_back(s);
    }
    if (capture({"tmux", "list-panes", "-a", "-F", "#{session_name}\t#{window_index}\t#{pane_id}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_active}\t#{window_active}\t#{@work}"}, text))
        for (const auto& line : lines(text)) {
            const auto f = tabs(line);
            if (f.size() < 7 || !at.count(f[0])) continue;
            out[at[f[0]]].panes.push_back({f[2], f[0], f[1], f[3], f[4], f[5] == "1" && f[6] == "1", f.size() > 7 ? f[7] : std::string()});
        }
    if (capture({"tmux", "list-clients", "-F", "#{client_session}\t#{client_pid}"}, text))
        for (const auto& line : lines(text)) {
            const auto f = tabs(line);
            if (f.size() >= 2 && at.count(f[0])) out[at[f[0]]].clients.push_back(std::atoi(f[1].c_str()));
        }
    return out;
}
// "claude, nvim · 3 windows": what runs there, the plain shells only when nothing else does.
std::string tmux_session_detail(const TmuxSession& s) {
    static const std::set<std::string> shells = {"zsh", "bash", "fish", "sh", "dash", "nu"};
    std::vector<std::string> apps;
    for (const auto& p : s.panes)
        if (!shells.count(p.cmd) && std::find(apps.begin(), apps.end(), p.cmd) == apps.end()) apps.push_back(p.cmd);
    std::string out;
    for (const auto& a : apps) out += (out.empty() ? "" : ", ") + a;
    if (out.empty()) out = "a shell";
    // The work in hand there, by the same name the notebook, the window title and line blame use.
    std::vector<std::string> works;
    for (const auto& p : s.panes) if (!p.work.empty() && std::find(works.begin(), works.end(), p.work) == works.end()) works.push_back(p.work);
    if (!works.empty()) out += " · " + works[0] + (works.size() > 1 ? " +" + std::to_string(works.size() - 1) : "");
    if (s.windows > 1) out += " · " + std::to_string(s.windows) + " windows";
    return out;
}
const TmuxSession* find_session(const std::vector<TmuxSession>& all, const std::string& name) {
    const auto it = std::find_if(all.begin(), all.end(), [&](const TmuxSession& s) { return s.name == name; });
    return it == all.end() ? nullptr : &*it;
}
bool session_name_ok(const std::string& name) { return !name.empty() && name.size() <= 80 && safe_text(name, 80) && name.find_first_of(".:\t\n") == std::string::npos; }
void terminals_rows(Json& rows) {
    auto sessions = tmux_sessions();
    if (!sh::have("tmux")) { auto none = item("terminal-go", "tmux is not installed", "action", "", "terminal"); none["enabled"] = false; rows.push_back(none); return; }
    std::sort(sessions.begin(), sessions.end(), [](const TmuxSession& a, const TmuxSession& b) { return a.activity > b.activity; });
    for (const bool shown : {true, false}) {
        bool any = false;
        for (const auto& s : sessions) {
            if (s.clients.empty() == shown) continue;
            if (!any) { rows.push_back(heading(shown ? "in a window" : "not in a window")); any = true; }
            auto row = item("terminal-go", s.name, "action", tmux_session_detail(s) + (shown ? "" : " · opens in a new window"), "terminal");
            row["argument"] = s.name; rows.push_back(row);
        }
    }
    // Projects not open yet: the folders under ~/code and ~/school, newest first.
    std::vector<std::pair<fs::file_time_type, fs::path>> projects;
    std::error_code ec;
    for (const auto* root : {"/code", "/school"})
        for (const auto& entry : fs::directory_iterator(home() + root, ec))
            if (const auto n = entry.path().filename().string(); entry.is_directory(ec) && n.front() != '.' && n.front() != '_' && n != "deprecated")
                projects.emplace_back(entry.last_write_time(ec), entry.path());
    std::sort(projects.begin(), projects.end(), [](const auto& a, const auto& b) { return a.first > b.first; });
    int listed = 0;
    for (const auto& [when, path] : projects) {
        auto name = path.filename().string();
        std::replace(name.begin(), name.end(), '.', '_'); std::replace(name.begin(), name.end(), ':', '_'); std::replace(name.begin(), name.end(), ' ', '_');
        if (find_session(sessions, name) || listed >= 6) continue;
        if (listed++ == 0) rows.push_back(heading("open a project"));
        auto row = item("terminal-new", path.filename().string(), "action", "A new terminal there", "folder");
        row["argument"] = path.string(); rows.push_back(row);
    }
    if (!sessions.empty()) {
        rows.push_back(heading("tidy"));
        auto arrange = item("terminals-arrange", "Rearrange sessions", "page", "Rename, show here, move a pane, close", "window");
        arrange["page"] = "terminals-arrange"; rows.push_back(arrange);
    }
}
void terminals_arrange_rows(Json& rows) {
    for (const auto& s : tmux_sessions()) {
        auto row = item("terminal-session", s.name, "page", tmux_session_detail(s) + (s.clients.empty() ? " · not in a window" : ""), "terminal");
        row["page"] = "terminal"; row["scope"] = s.name; row["argument"] = s.name; rows.push_back(row);
    }
}
bool terminal_rows(const std::string& name, Json& rows, Json& out) {
    const auto sessions = tmux_sessions();
    const auto* s = find_session(sessions, name);
    if (!s) return false;
    out["title"] = s->name;
    auto go = item("terminal-go", s->clients.empty() ? "Open in a new window" : "Go to it", "action", tmux_session_detail(*s), "terminal");
    go["argument"] = s->name; rows.push_back(go);
    auto here = item("terminal-here", "Show it in the focused terminal", "action",
                     s->clients.empty() ? "The terminal you were in switches to it" : "The terminal you were in switches to it; the window showing it now closes", "window");
    here["argument"] = s->name; rows.push_back(here);
    auto rename = item("terminal-rename", "Rename", "action", "Give it a name of your own", "note");
    rename["argument"] = s->name; rows.push_back(rename);
    if (s->panes.size() > 1 || sessions.size() > 1) {
        rows.push_back(heading("its panes"));
        for (const auto& p : s->panes) {
            auto row = item("terminal-pane", p.cmd + " · window " + p.window, "page", fs::path(p.path).filename().string() + (p.work.empty() ? "" : " · " + p.work) + (p.active ? " · the one in front" : ""), "terminal");
            row["page"] = "terminal-pane"; row["scope"] = p.id; row["argument"] = p.id; rows.push_back(row);
        }
    }
    rows.push_back(heading("close"));
    bool busy = false;
    for (const auto& p : s->panes) busy = busy || p.cmd == "claude" || p.cmd == "nvim" || p.cmd == "codex" || p.cmd == "vim";
    auto close = item("terminal-close", "Close this session", "action", busy ? "Something is still running in it" : "Every window in it closes", "trash");
    close["argument"] = s->name;
    close["confirm"] = std::string("Close ") + s->name + "?" + (busy ? " Claude, editors and anything else running in it stop, and unsaved work in them is lost." : "");
    rows.push_back(close);
    return true;
}
bool terminal_pane_rows(const std::string& pane, Json& rows, Json& out) {
    const auto sessions = tmux_sessions();
    const TmuxPane* found = nullptr;
    for (const auto& s : sessions) for (const auto& p : s.panes) if (p.id == pane) found = &p;
    if (!found) return false;
    out["title"] = found->cmd + " · " + found->session;
    rows.push_back(heading("move it"));
    for (const auto& s : sessions) {
        if (s.name == found->session) continue;
        auto row = item("terminal-pane-move", "Into " + s.name, "action", "As a new window there", "next");
        row["argument"] = pane + "\t" + s.name; rows.push_back(row);
    }
    auto own = item("terminal-pane-split", "Into a session of its own", "action", "Named for its folder", "window");
    own["argument"] = pane; rows.push_back(own);
    return true;
}
// The tmux client inside a window: the client process's parents lead to the window's process.
std::string client_in_window(int window_pid) {
    std::string text;
    if (window_pid <= 0 || !capture({"tmux", "list-clients", "-F", "#{client_tty}\t#{client_pid}"}, text)) return {};
    for (const auto& line : lines(text)) {
        const auto f = tabs(line);
        if (f.size() < 2) continue;
        int pid = std::atoi(f[1].c_str());
        for (int depth = 0; depth < 8 && pid > 1; ++depth) {
            if (pid == window_pid) return f[0];
            const auto stat = read(fs::path("/proc") / std::to_string(pid) / "stat");
            const auto close = stat.rfind(')');
            if (close == std::string::npos) break;
            std::istringstream fields(stat.substr(close + 2));
            std::string state; int parent = 0;
            if (!(fields >> state >> parent)) break;
            pid = parent;
        }
    }
    return {};
}
Json terminal_go(const std::string& name) {
    const auto sessions = tmux_sessions();
    const auto* s = find_session(sessions, name);
    if (!s) return result(false, "That session is gone");
    if (s->clients.empty()) return terminal({"tmux", "attach-session", "-t", "=" + name}, name + " opened");
    focus_agent_client(s->clients.front());
    return result(true, name, true);
}
Json terminal_here(const std::string& name) {
    const auto sessions = tmux_sessions();
    const auto* s = find_session(sessions, name);
    if (!s) return result(false, "That session is gone");
    Json active;
    if (!capture_json({"hyprctl", "-j", "activewindow"}, active) || !active.is_object()) return result(false, "No window has the focus");
    const auto tty = client_in_window(active.value("pid", 0));
    if (tty.empty()) return result(false, "The focused window is not a terminal with tmux");
    std::string text, out;
    // Never in two places: the other windows showing it let go first (each closes as its tmux client detaches).
    if (capture({"tmux", "list-clients", "-F", "#{client_tty}\t#{client_session}"}, text))
        for (const auto& line : lines(text)) {
            const auto f = tabs(line);
            if (f.size() >= 2 && f[1] == name && f[0] != tty) capture({"tmux", "detach-client", "-t", f[0]}, out);
        }
    if (!capture({"tmux", "switch-client", "-c", tty, "-t", "=" + name}, out)) return result(false, "Could not switch that terminal");
    return result(true, name + " is in that terminal now", true);
}
Json terminal_rename(const std::string& from, const std::string& to) {
    if (!session_name_ok(to)) return result(false, "A name without dots or colons, please");
    const auto sessions = tmux_sessions();
    if (!find_session(sessions, from)) return result(false, "That session is gone");
    if (find_session(sessions, to)) return result(false, "Another session is called " + to);
    std::string out;
    return capture({"tmux", "rename-session", "-t", "=" + from, "--", to}, out) ? result(true, from + " is " + to + " now") : result(false, "Could not rename it");
}
Json terminal_pane_move(const std::string& arg) {
    const auto tab = arg.find('\t');
    if (tab == std::string::npos) return result(false, "Not a pane and a session");
    const auto pane = arg.substr(0, tab), target = arg.substr(tab + 1);
    if (!std::regex_match(pane, std::regex("%[0-9]{1,9}")) || !find_session(tmux_sessions(), target)) return result(false, "That pane or session is gone");
    std::string out;
    return capture({"tmux", "break-pane", "-d", "-s", pane, "-t", "=" + target + ":"}, out) ? result(true, "Moved into " + target) : result(false, "Could not move it");
}
Json terminal_pane_split(const std::string& pane) {
    if (!std::regex_match(pane, std::regex("%[0-9]{1,9}"))) return result(false, "Not a pane");
    const auto sessions = tmux_sessions();
    const TmuxPane* found = nullptr;
    for (const auto& s : sessions) for (const auto& p : s.panes) if (p.id == pane) found = &p;
    if (!found) return result(false, "That pane is gone");
    auto base = fs::path(found->path).filename().string();
    for (auto& c : base) if (c == '.' || c == ':' || c == ' ') c = '_';
    if (base.empty()) base = "pane";
    auto name = base;
    for (int n = 2; find_session(sessions, name); ++n) name = base + "-" + std::to_string(n);
    std::string out, first;
    // A new session starts with a shell window; the pane goes in beside it and the shell goes.
    if (!capture({"tmux", "new-session", "-d", "-s", name, "-c", found->path, "-P", "-F", "#{window_id}"}, first)) return result(false, "Could not start a session");
    if (!capture({"tmux", "break-pane", "-d", "-s", pane, "-t", "=" + name + ":"}, out)) return result(false, "Could not move it");
    capture({"tmux", "kill-window", "-t", trim(first)}, out);
    return result(true, "Its own session now: " + name);
}
Json terminal_close(const std::string& name, bool confirmed) {
    if (!confirmed) return result(false, "Confirmation required");
    if (!find_session(tmux_sessions(), name)) return result(false, "That session is gone");
    std::string out;
    return capture({"tmux", "kill-session", "-t", "=" + name}, out) ? result(true, name + " closed") : result(false, "Could not close it");
}
// The system's enabled services change with sudo in a terminal, not while this page is open, and listing them takes
// over half a second: read once a minute, not on every refresh.
bool system_unit_files(std::string& out) {
    const Args ask{"systemctl", "list-unit-files", "--state=enabled", "--type=service", "--no-legend", "--plain"};
    if (env("XDG_RUNTIME_DIR").empty()) return capture(ask, out);
    const auto cache = runtime() / "desk-drawer-system-units";
    std::error_code ec;
    const auto when = fs::last_write_time(cache, ec);
    if (!ec && regular(cache) && fs::file_time_type::clock::now() - when < std::chrono::minutes(1)) { out = read(cache); return true; }
    if (!capture(ask, out)) return false;
    write_atomic(cache, out);
    return true;
}
void startup_rows(Json& rows) {
    std::string out;
    // Your own services: switching one off is yours to do.
    if (sh::have("systemctl") && capture({"systemctl", "--user", "list-unit-files", "--state=enabled", "--type=service,timer", "--no-legend", "--plain"}, out)) {
        auto head = item("startup-user", "Your services", "action", "Start with your session · Enter switches one off", "info"); head["enabled"] = false; rows.push_back(head);
        // One is-active call answers for every unit, a state per line in the order asked: not a process per row.
        std::vector<std::string> units, states;
        for (const auto& line : lines(out)) {
            const auto unit = line.substr(0, line.find(' '));
            if (std::regex_match(unit, std::regex("[A-Za-z0-9@._-]+\\.(service|timer)"))) units.push_back(unit);
        }
        if (!units.empty()) {
            Args ask{"systemctl", "--user", "is-active"};
            ask.insert(ask.end(), units.begin(), units.end());
            std::string answer; capture(ask, answer);
            states = lines(answer);
        }
        for (size_t i = 0; i < units.size(); ++i) {
            const auto& unit = units[i];
            const auto state = i < states.size() ? states[i] : std::string();
            // Linux_Theme's own watchers guard the machine; say so before one is switched off.
            const bool guard = std::regex_match(unit, std::regex("fox-(bouncer|tripwire|sentry[A-Za-z-]*|vault|honey[A-Za-z-]*)\\.(service|timer)"));
            auto row = item("startup-user", unit, "action", std::string(trim(state) == "active" ? "running" : "not running right now")
                            + (guard ? " · a security watcher: switching it off lowers your protection" : ""), guard ? "shield" : "gear");
            row["argument"] = unit; row["confirm"] = true; rows.push_back(row);
        }
    }
    // Desktop autostart entries (XDG): hidden with a user copy, the system's file is never edited.
    std::map<std::string, fs::path> entries;
    std::error_code ec;
    for (const auto& dir : {fs::path("/etc/xdg/autostart"), user_autostart()})
        for (const auto& entry : fs::directory_iterator(dir, ec)) if (entry.path().extension() == ".desktop") entries[entry.path().filename().string()] = entry.path();
    bool any = false;
    for (const auto& [name, path] : entries) {
        const auto fields = desktop_fields(path);
        if (fields.count("Hidden") && fields.at("Hidden") == "true") continue;
        if (fields.count("OnlyShowIn") && fields.at("OnlyShowIn").find("Hyprland") == std::string::npos) continue;
        if (!any) { auto head = item("startup-autostart", "Desktop autostart", "action", "Enter hides one for your account", "info"); head["enabled"] = false; rows.push_back(head); any = true; }
        auto row = item("startup-autostart", fields.count("Name") ? fields.at("Name") : name, "action", name, "gear");
        row["argument"] = name; row["confirm"] = true; rows.push_back(row);
    }
    // Hyprland's own autostart: part of the theme, listed so nothing starts unseen.
    const auto config = fs::path(env("XDG_CONFIG_HOME", home() + "/.config")) / "hypr/modules";
    std::vector<std::string> hypr;
    for (const auto& raw : lines(read(config / "autostart.lua"))) {
        std::smatch m;
        if (trim(raw).rfind("--", 0) != 0 && std::regex_search(raw, m, std::regex("hl\\.exec_cmd\\(\"([^\"]+)\"\\)"))) hypr.push_back(m[1].str());
    }
    if (hypr.empty()) for (const auto& raw : lines(read(config / "autostart.conf"))) {
        std::smatch m;
        if (std::regex_search(raw, m, std::regex("^\\s*exec-once\\s*=\\s*(.+)$"))) hypr.push_back(trim(m[1].str()));
    }
    if (!hypr.empty()) {
        auto head = item("startup-hyprland", "Started by Hyprland", "action", "Part of the theme's autostart.lua", "info"); head["enabled"] = false; rows.push_back(head);
        for (const auto& command : hypr) {
            auto row = item("startup-hyprland", command.substr(0, 90), "action", "", "gear");
            row["enabled"] = false; row["disabledReason"] = "Change it in ~/.config/hypr/modules/autostart.lua"; rows.push_back(row);
        }
    }
    // System services: listed only. Switching off the wrong one can cost the login screen or the network.
    if (sh::have("systemctl") && system_unit_files(out)) {
        auto head = item("startup-system", "System services", "action", "Listed only: change these in a terminal, with care", "info"); head["enabled"] = false; rows.push_back(head);
        for (const auto& line : lines(out)) {
            const auto unit = line.substr(0, line.find(' '));
            if (unit.empty()) continue;
            auto row = item("startup-system", unit, "action", "", "gear");
            row["enabled"] = false; row["disabledReason"] = "System services change with sudo in a terminal"; rows.push_back(row);
        }
    }
}
Json startup_user_off(const std::string& unit, bool confirmed) {
    if (!confirmed) return result(false, "Confirmation required");
    if (!std::regex_match(unit, std::regex("[A-Za-z0-9@._-]+\\.(service|timer)"))) return result(false, "Not a service name");
    return command({"systemctl", "--user", "disable", "--now", unit}, unit + " switched off", false, "Could not switch off " + unit);
}
Json startup_autostart_hide(const std::string& name, bool confirmed) {
    if (!confirmed) return result(false, "Confirmation required");
    if (!std::regex_match(name, std::regex("[A-Za-z0-9@._-]+\\.desktop"))) return result(false, "Not an autostart entry");
    const auto mine = user_autostart() / name;
    const auto source = regular(mine) ? mine : fs::path("/etc/xdg/autostart") / name;
    if (!regular(source)) return result(false, "That entry is gone");
    std::string text = read(source);
    if (text.find("\nHidden=true") == std::string::npos) {
        const auto at = text.find("[Desktop Entry]");
        if (at == std::string::npos) return result(false, "Not a desktop entry");
        text.insert(at + 15, "\nHidden=true");
    }
    std::error_code ec;
    fs::create_directories(mine.parent_path(), ec);
    return write_atomic(mine, text) ? result(true, name + " won't start next time") : result(false, "Could not write " + mine.string());
}

Json view(const Json& config, const std::string& page, const std::string& query, const std::string& project_scope = {}) {
    Json out{{"id", page}, {"title", page}, {"items", Json::array()}, {"ok", true}, {"group", group_for(config, page)}};
    auto& rows = out["items"];
    auto fail = [&](const std::string& message) { out["ok"] = false; out["error"] = message; };
    const auto work_note = [&](const std::string& label, const std::string& detail = std::string(), const std::string& icon = "info") {
        auto row = item("work-health-info", label, "action", detail, icon); row["enabled"] = false; rows.push_back(row);
    };
    bool known = false;
    if (page == "root") {
        known = true; out["title"] = text(config, "title", "Linux_Theme");
        char date[48] = {}; const std::time_t now = std::time(nullptr); const std::tm* local = std::localtime(&now);
        std::strftime(date, sizeof date, "%a, %b ", local);
        auto home_row = item("today", "Today", "page", "A look at your day", "today");
        home_row["page"] = "root"; home_row["summary"] = date + std::to_string(local->tm_mday); rows.push_back(home_row);
        out["today"] = today_summary(config);
        for (const auto& group : config["groups"]) {
            auto row = item(text(group, "id"), text(group, "label"), "page", text(group, "description"), text(group, "icon"));
            row["summary"] = text(group, "id") == "workbench" ? workbench_summary(out["today"]) : group_summary(text(group, "id"));
            row["page"] = text(group, "id"); rows.push_back(row);
        }
        out["favorites"] = Json::array();
        if (config.contains("favorites")) for (const auto& reference : config["favorites"]) {
            for (const auto& group : config["groups"]) for (auto row : group["items"]) {
                if (reference.get<std::string>() != text(group, "id") + "/" + text(row, "id")) continue;
                row["group"] = text(group, "id");
                decorate(row);
                out["favorites"].push_back(row);
            }
        }
        std::vector<std::string> pinned;
        if (!bookmarks(pinned)) fail("Bookmarks could not be read");
        for (const auto& project : projects(config)) if (std::find(pinned.begin(), pinned.end(), project.path.string()) != pinned.end())
            out["favorites"].push_back(project_card(project, true));
    } else if (page == "search") {
        known = true; out["title"] = "Find anything";
        for (const auto& group : config["groups"]) for (auto row : group["items"]) {
            row["detail"] = text(group, "label") + (text(row, "detail").empty() ? "" : " › " + text(row, "detail"));
            row["group"] = text(group, "id"); searchable_by_id(row); rows.push_back(row);
        }
        if (!query.empty()) {
            for (const auto& shortcut : shortcuts()) {
                if (shortcut.family != KeyFamily::desktop) continue;
                const auto caps = key_caps(shortcut.keys, shortcut.family);
                auto row = item("cheatsheet-copy", shortcut.description, "action", caps.empty() ? "Shortcut · " + shortcut.keys : "Shortcut", "info");
                row["argument"] = shortcut.keys; row["group"] = "system"; row["presentation"] = "shortcut";
                if (!caps.empty()) row["keys"] = caps;
                row["keywords"] = Json::array({shortcut.keys}); rows.push_back(row);
            }
            for (const auto& tool : desk_tools()) {
                auto row = item("tool-run", tool.name, "action", "Desk tools · " + tool.description, "info");
                row["argument"] = tool.name; row["close"] = true; row["group"] = "system"; rows.push_back(row);
            }
            for (const auto& project : projects(config)) {
                // The full path matched every project on the letters of the home folder.
                const auto wanted = lower(query);
                if (lower(project.name).find(wanted) == std::string::npos
                    && (wanted.find('/') == std::string::npos || lower(project.path.string()).find(wanted) == std::string::npos)) continue;
                auto row = project_card(project, false);
                row["detail"] = "Project · " + text(row, "detail");
                rows.push_back(row);
            }
            const auto captures = screenshots(config);
            for (std::size_t i = 0; i < std::min<std::size_t>(captures.size(), 12); ++i) {
                const auto& file = captures[i];
                auto row = item("screenshot-open", i == 0 ? "Last screenshot · " + file.name : file.name,
                                "action", "Screenshot scrapbook · " + file.modified_at, "image");
                row["argument"] = file.path.string(); row["close"] = true;
                rows.push_back(row);
            }
            ClaudeUsage usage;
            for (const auto& session : claude_sessions(usage)) {
                auto row = item("claude-jump", "Claude · " + session.name(), "action",
                                session.project + " · " + claude_state_text(session), "message");
                row["argument"] = session.pane; row["enabled"] = !session.pane.empty(); row["close"] = true;
                rows.push_back(row);
            }
            Json devices = Json::array();
            if (bluetooth_service_running() && bluetooth_rows(devices)) for (auto row : devices) {
                row["label"] = "Connect " + text(row, "label");
                row["detail"] = "Bluetooth device · " + text(row, "detail");
                rows.push_back(row);
            }
            for (const auto& app : desktops()) {
                auto row = item("app-launch", app.name, "action", "Desk › Applications" + (app.detail.empty() ? "" : " · " + app.detail), app.icon);
                row["argument"] = app.path.string(); row["close"] = true;
                if (!app.keywords.empty()) row["keywords"] = app.keywords;
                row["group"] = "desk"; row["enabled"] = sh::have("gio"); rows.push_back(row);
            }
            Json clients;
            if (sh::have("hyprctl") && capture_json({"hyprctl", "-j", "clients"}, clients) && clients.is_array()) {
                const auto places = screen_places();
                for (const auto& client : clients) {
                    if (!client.is_object() || text(client, "address").empty()) continue;
                    const auto where = window_place(client, places);
                    auto row = item("window-focus", text(client, "title", text(client, "class", "Window")),
                                    "action", "Desk › Open windows · " + text(client, "class") + (where.empty() ? "" : " · " + where), "window");
                    row["argument"] = text(client, "address"); row["close"] = true;
                    row["group"] = "desk"; rows.push_back(row);
                }
            }
        }
    } else for (const auto& group : config["groups"]) if (text(group, "id") == page) {
        known = true; out["title"] = text(group, "label");
        for (auto row : group["items"]) {
            if (!row.contains("enabled")) row["enabled"] = true;
            if (!decorate(row)) fail("Some controls are unavailable");
            if (!query.empty()) searchable_by_id(row);
            rows.push_back(row);
        }
        if (query.empty()) rows = sectioned(rows);
    }
    if (page == "jobs" || page == "test-results" || page == "reviews" || page == "attention" || page == "next-steps" || page == "failures" || page == "work-history" || page == "work-digest" || page == "attention-snoozed") {
        known = true;
        out["title"] = page == "work-history" ? "Project timeline" : page == "work-digest" ? "Since you last looked" : page == "attention-snoozed" ? "Snoozed items" : page == "attention" ? "Needs you" : page == "jobs" ? "Jobs" : page == "test-results" ? "Test results" : page == "reviews" ? "Changes to look over" : page == "next-steps" ? "Pinned next steps" : "Failures";
        bool observed = false; work_rows(config, page, rows, &observed); out["workObserved"] = observed;
    } else if (page == "worktrees") {
        known = true; out["title"] = "Worktree map";
        if (!project_scope.empty() && !work_project(config, project_scope)) fail("This project is no longer in your index cards");
        else worktree_rows(config, project_scope, rows);
    } else if (page == "projects" || page == "bookmarks") {
        known = true; out["title"] = page == "bookmarks" ? "Bookmarks" : "Project index cards";
        std::vector<std::string> pinned;
        if (!bookmarks(pinned)) fail("Bookmarks could not be read");
        for (const auto& project : projects(config)) {
            const bool saved = std::find(pinned.begin(), pinned.end(), project.path.string()) != pinned.end();
            if (page == "projects" || saved) rows.push_back(project_card(project, saved));
        }
        if (page == "bookmarks") for (const auto& path : pinned) {
            if (std::none_of(rows.begin(), rows.end(), [&](const auto& row) { return text(row,"argument") == path; }))
                rows.push_back(project_card({path, fs::path(path).filename().string(), "Unavailable · b removes this ribbon"}, true));
        }
        std::stable_sort(rows.begin(), rows.end(), [](const auto& a, const auto& b) { return truth(a,"bookmarked") > truth(b,"bookmarked"); });
    } else if (page == "library") {
        known = true; out["title"] = "The little library";
        std::vector<Volume> volumes;
        if (!library(volumes)) fail("Removable drives are unavailable");
        for (const auto& volume : volumes) {
            std::string detail = capacity(volume.size) + " · " + (volume.mount.empty() ? "On the shelf · Enter to mount" : "Checked out · " + volume.mount);
            struct statvfs info{};
            if (!volume.mount.empty() && ::statvfs(volume.mount.c_str(), &info) == 0)
                detail = capacity(static_cast<uint64_t>(info.f_bavail) * info.f_frsize) + " free of " + capacity(static_cast<uint64_t>(info.f_blocks) * info.f_frsize) + " · " + volume.mount;
            auto row = item("drive-open", volume.label, "action", detail, "▤");
            row["argument"] = volume.path; row["ejectArgument"] = volume.disk;
            row["presentation"] = "library"; row["mounted"] = !volume.mount.empty();
            row["enabled"] = sh::have("udisksctl") && sh::have("xdg-open");
            if (!row["enabled"].get<bool>()) row["disabledReason"] = !sh::have("udisksctl") ? "udisksctl is not installed" : "xdg-open is not installed";
            rows.push_back(row);
        }
    } else if (page == "garden") {
        known = true; out["title"] = "Commit garden";
        out["garden"] = commit_year(config);
    } else if (page == "screenshots") {
        known = true; out["title"] = "Screenshot scrapbook";
        for (const auto& file : screenshots(config)) {
            auto row = item("screenshot-open", file.name, "action", file.modified_at, "image");
            row["argument"] = file.path.string(); row["close"] = true;
            row["presentation"] = "screenshot"; row["image"] = file_url(file.path);
            row["stamp"] = file.age; row["modifiedAt"] = file.modified_at;
            row["enabled"] = sh::have("xdg-open"); rows.push_back(row);
        }
    } else if (page == "downloads") {
        known = true; out["title"] = "Incoming paper tray";
        for (const auto& file : downloads(config)) {
            auto row = item("download-open", file.name, "action", file.type + " · " + capacity(file.size), "✉");
            row["argument"] = file.path.string(); row["close"] = true;
            row["presentation"] = "download"; row["stamp"] = file.age; row["modifiedAt"] = file.modified_at;
            row["enabled"] = sh::have("xdg-open"); if (!row["enabled"].get<bool>()) row["disabledReason"] = "xdg-open is not installed"; rows.push_back(row);
        }
    } else if (page == "apps") {
        known = true; out["title"] = "Applications";
        if (!sh::have("gio")) fail("gio is not installed");
        for (const auto& app : desktops()) {
            auto row = item("app-launch", app.name, "action", app.detail, app.icon);
            if (!app.keywords.empty()) row["keywords"] = app.keywords;
            row["argument"] = app.path.string(); row["close"] = true; row["enabled"] = sh::have("gio"); rows.push_back(row);
        }
    } else if (page == "windows") {
        known = true; out["title"] = "Open windows"; Json clients;
        const bool listed = capture_json({"hyprctl", "-j", "clients"}, clients) && clients.is_array();
        const auto places = listed ? screen_places() : std::map<int, std::string>{};
        if (!listed) fail("Hyprland windows are unavailable");
        else for (const auto& client : clients) {
            if (!client.is_object() || text(client, "address").empty()) continue;
            const auto where = window_place(client, places);
            const auto app = text(client, "class");
            auto row = item("window-focus", text(client, "title", text(client, "class", "Window")), "action",
                            app + (app.empty() || where.empty() ? "" : " · ") + where, "window");
            row["argument"] = text(client, "address"); row["close"] = true; rows.push_back(row);
        }
    } else if (page == "audio-outputs") {
        known = true; out["title"] = "Audio output"; Json sinks; std::string current;
        capture({"pactl", "get-default-sink"}, current);
        if (!capture_json({"pactl", "-f", "json", "list", "sinks"}, sinks) || !sinks.is_array()) fail("Audio devices are unavailable");
        else for (const auto& sink : sinks) {
            if (!sink.is_object() || text(sink, "name").empty()) continue;
            const bool selected = trim(current) == text(sink, "name");
            auto row = item("audio-output", text(sink, "description", text(sink, "name")), "action", selected ? "Current output" : "Available", "volume");
            row["argument"] = text(sink, "name"); row["checked"] = selected; rows.push_back(row);
        }
    } else if (page == "wifi") {
        known = true; out["title"] = "Wi-Fi";
        if (!wifi_rows(rows)) fail("NetworkManager Wi-Fi is unavailable");
        std::string radio;
        auto toggle = item("wifi-toggle", "Wi-Fi radio", "toggle", "Wireless connection", "wifi");
        if (capture({"nmcli", "radio", "wifi"}, radio) && (trim(radio) == "enabled" || trim(radio) == "disabled")) toggle["checked"] = trim(radio) == "enabled";
        else { toggle["enabled"] = false; toggle["detail"] = "Radio state unavailable"; }
        rows.insert(rows.begin(), toggle);
    } else if (page == "bluetooth") {
        known = true; out["title"] = "Bluetooth";
        if (!bluetooth_service_running()) {
            auto row = item("bluetooth-service", "Turn on Bluetooth", "action", "The Bluetooth service is off · asks for your password in a terminal", "bluetooth");
            row["close"] = true; rows.push_back(row);
        } else {
            const bool reachable = bluetooth_rows(rows);
            if (!reachable) fail("Bluetooth devices are unavailable");
            for (auto& row : rows) {
                std::string info;
                if (capture({"bluetoothctl", "info", text(row, "argument")}, info) && info.find("Connected:") != std::string::npos) {
                    row["kind"] = "toggle"; row["checked"] = info.find("Connected: yes") != std::string::npos;
                    const auto status = truth(row, "checked") ? "Connected" : info.find("Paired: yes") != std::string::npos ? "Paired" : "Not paired";
                    row["detail"] = std::string(status) + " · " + text(row, "argument");
                } else { row["enabled"] = false; row["detail"] = "Device state unavailable"; }
            }
            auto toggle = item("bluetooth-toggle", "Bluetooth power", "toggle", {}, "bluetooth"); std::string controller;
            if (reachable && capture({"bluetoothctl", "show"}, controller) && controller.find("Powered:") != std::string::npos)
                toggle["checked"] = controller.find("Powered: yes") != std::string::npos;
            else { toggle["enabled"] = false; toggle["detail"] = "Controller state unavailable"; }
            rows.insert(rows.begin(), toggle);
            auto scan = item("bluetooth-scan", "Scan and pair devices", "action", "Opens the Bluetooth manager", "search"); scan["close"] = true; rows.push_back(scan);
        }
    } else if (page == "clipboard-text" || page == "clipboard-images") {
        known = true; out["title"] = page == "clipboard-images" ? "Clipboard images" : "Clipboard";
        if (!clipboard_rows(rows, page == "clipboard-images")) fail("Clipboard history is unavailable");
        else if (page == "clipboard-images") {
            const bool cache = thumb_dir_ready();
            std::set<std::string> listed;
            size_t previews = 0;
            for (auto& row : rows) {
                listed.insert(text(row, "argument"));
                if (previews++ >= 24) continue;
                const auto image = image_preview(text(row, "argument"), cache);
                if (!image.empty()) row["image"] = image;
            }
            if (cache) prune_thumbs(listed);
        }
    } else if (page == "wallpapers") {
        known = true; out["title"] = "Wallpapers";
        for (const auto& path : wallpapers()) {
            auto row = item("wallpaper-set", path.stem().string(), "action", path.filename().string(), "image");
            row["argument"] = path.string(); rows.push_back(row);
        }
    } else if (page == "themes") {
        known = true; out["title"] = "Themes";
        const auto active = trim(read(repository() / ".active-theme"));
        for (const auto& theme : themes()) {
            auto row = item("theme-set", theme, "action", theme == active ? "Current theme" : "Apply in terminal", "palette");
            row["argument"] = theme; row["checked"] = theme == active; row["close"] = true; rows.push_back(row);
        }
        if (rows.empty()) fail("No theme repository was found");
    } else if (page == "power") {
        known = true; out["title"] = "Power";
        for (const auto& pair : std::vector<std::pair<std::string,std::string>>{{"lock","Lock screen"},{"suspend","Suspend"},{"logout","Log out"},{"reboot","Restart"},{"poweroff","Shut down"}}) {
            auto row = item(pair.first, pair.second, "action", {}, pair.first);
            decorate(row); rows.push_back(row);
        }
    } else if (page == "display" || page == "display-modes") {
        known = true; out["title"] = "Displays";
        if (project_scope.empty() || !(page == "display" ? screen_rows(project_scope, rows, out) : mode_rows(project_scope, rows, out)))
            fail("That screen is no longer connected");
        for (auto& row : rows) if (truth(row, "enabled")) decorate(row);
    } else if (page == "calendar-feeds") {
        known = true; out["title"] = "Course calendars";
        calendar_feed_rows(rows);
    } else if (page == "displays") {
        known = true; out["title"] = "Displays";
        display_rows(rows);
        for (auto& row : rows) if (truth(row, "enabled")) decorate(row);
    } else if (page == "api-credits" || page == "api-tasks") {
        // One API page: what is left, then asking, earlier asks, where the money went, and the settings.
        known = true; out["title"] = "API";
        // Three small programs (each a Python start-up): read side by side, not one after another.
        auto projects_read = std::async(std::launch::async, [] { return api_projects(); });
        auto history_read = std::async(std::launch::async, [] { return api_history(); });
        Json usage;
        auto note = [&](const std::string& label, const std::string& detail, const std::string& icon = "info") {
            auto row = item("credits-summary", label, "action", detail, icon); row["enabled"] = false; rows.push_back(row);
        };
        auto money = [](const Json& row) { return money_text(text(row, "spent_usd")); };
        const bool metered = sh::have("desk-credits") && capture_json({"desk-credits", "usage"}, usage) && usage.is_object() && usage["snapshot"].is_object();
        if (metered) {
            out["credits"] = usage["snapshot"];
            note(text(usage["snapshot"], "headline"), text(usage["snapshot"], "detail"));
        } else {
            note("The API credit meter is unavailable", "Install desk-credits");
        }
        const auto projects = projects_read.get();
        if (!projects.empty()) rows.push_back(heading("ask"));
        for (const auto& project : projects) {
            const auto id = text(project, "id"), label = text(project, "label");
            const bool here = truth(project, "available");
            auto ask = item("api-task-ask", "Ask about " + label, "action",
                            "Read-only · " + text(project, "model") + " · default budget $" + text(project, "budget_usd"), "message");
            auto review = item("api-task-review", "  Review uncommitted changes", "action", "Bugs, risky edits and missing tests in the diff", "search");
            auto agent = item("api-task-pi", "  Open pi with API credits", "action", "pi can edit files · every reply is tracked", "terminal");
            for (auto* row : {&ask, &review, &agent}) {
                (*row)["argument"] = id;
                if (!here) { (*row)["enabled"] = false; (*row)["detail"] = "Project folder not found · " + text(project, "root"); }
                rows.push_back(*row);
            }
        }
        const auto history = history_read.get();
        if (!history.empty()) rows.push_back(heading("earlier asks"));
        for (const auto& task : history) {
            const auto id = text(task, "id");
            const auto cost = task.contains("cost_usd") && task["cost_usd"].is_string() ? money_text(text(task, "cost_usd")) : std::string("cost unknown");
            const auto when = when_text(iso_seconds(text(task, "finished_at", text(task, "started_at"))));
            auto row = item("api-task-open", text(task, "title", text(task, "label")), "action",
                            text(task, "label") + " · " + text(task, "status") + " · " + text(task, "model", "model unknown") + " · " + cost
                            + (when.empty() ? "" : " · " + when), "message");
            row["argument"] = id; rows.push_back(row);
            auto follow = item("api-task-follow", "  Follow up", "action", "Ask more, with this question and answer as context", "message");
            follow["argument"] = id; rows.push_back(follow);
        }
        if (metered) {
            rows.push_back(heading("spend"));
            note("Counts runs made through these tools", "API tasks and pi with API credits · other uses of the key are not included");
            if (usage["projects"].is_array() && !usage["projects"].empty()) {
                note("By project", "This month", "folder");
                for (const auto& p : usage["projects"])
                    note("  " + text(p, "label"), money(p) + " · " + std::to_string(p.value("runs", 0)) + " runs · about " + money_text(text(p, "average_usd")) + " each", "folder");
                note("By model", "Average cost per run helps pick a cheaper model", "system");
                for (const auto& m : usage["models"])
                    note("  " + text(m, "model"), money(m) + " · " + std::to_string(m.value("runs", 0)) + " runs · about " + money_text(text(m, "average_usd")) + " each · "
                         + std::to_string(m.value("input_tokens", 0) / 1000) + "k in / " + std::to_string(m.value("output_tokens", 0) / 1000) + "k out", "system");
                note("Recent days", "Spend per day", "today");
                const auto& days = usage["days"];
                for (size_t i = days.size() > 7 ? days.size() - 7 : 0; i < days.size(); ++i)
                    note("  " + text(days[i], "day"), money(days[i]) + " · " + std::to_string(days[i].value("runs", 0)) + " runs", "today");
                note("Costliest runs", "This month", "search");
                int shown = 0;
                for (const auto& t : usage["top"]) {
                    if (++shown > 5) break;
                    note("  " + text(t, "label", text(t, "id")), text(t, "project") + " · " + text(t, "model", "model unknown") + " · "
                         + money_text(text(t, "cost_usd")) + " · " + when_text(iso_seconds(text(t, "at"))), "search");
                }
            } else if (usage["snapshot"].value("remaining_usd", Json()).is_string()) {
                note("No tracked runs yet this month", "Ask about a project, or open pi with API credits");
            }
        }
        rows.push_back(heading("settings"));
        rows.push_back(item("credits-setup", "Renewal day and budget", "action", "When the monthly credit renews, and how much it is", "system"));
        rows.push_back(item("credits-console", "Open Claude Console", "action", "The account's real balance and credit expiry", "window"));
        rows.push_back(item("api-task-settings", "Edit API task settings", "action", "Key file, model, effort, default budget and project folders, in Neovim", "system"));
        for (auto& row : rows) if (truth(row, "enabled")) { decorate(row); row["close"] = true; }
    } else if (page == "tools" || page.rfind("tools-", 0) == 0) {
        const auto section = std::find_if(tool_sections.begin(), tool_sections.end(), [&](const ToolSection& s) { return s.id == page; });
        known = page == "tools" || section != tool_sections.end();
        out["title"] = page == "tools" ? "Desk tools" : section != tool_sections.end() ? section->label : "Desk tools";
        const auto tools = desk_tools();
        if (page == "tools") {
            for (const auto& category : tool_sections) {
                const auto count = std::count_if(tools.begin(), tools.end(), [&](const Tool& t) { return category.id == "tools-all" || tool_section(t.name) == category.id; });
                if (!count) continue;
                auto row = item(category.id, category.label, "page", category.description + " · " + std::to_string(count) + (count == 1 ? " tool" : " tools"), category.icon);
                row["page"] = category.id; rows.push_back(row);
            }
        } else if (known) for (const auto& tool : tools) {
            if (page != "tools-all" && tool_section(tool.name) != page) continue;
            auto row = item("tool-run", tool.name, "action", tool.description, section->icon);
            row["argument"] = tool.name; row["close"] = true; rows.push_back(row);
        }
        if (tools.empty()) fail("No desk tools were found in ~/.local/bin");
    } else if (page == "cheatsheet" || page == "cheatsheet-keys") {
        known = true; out["title"] = "Shortcut reference";
        const auto all = shortcuts();
        if (all.empty()) fail("KEYBINDS.md is unavailable");
        // One shortcut: what it does as the title, its keys as caps (or in words when they need more than five).
        auto shortcut_row = [&](const Shortcut& s, const std::string& where) {
            // "Y (copy mode)": the keys are Y; the words in brackets say when.
            std::string keys = s.keys, note;
            if (const auto open = keys.find(" ("); open != std::string::npos && keys.back() == ')') {
                note = keys.substr(open + 2, keys.size() - open - 3); keys = trim(keys.substr(0, open));
            }
            const auto caps = key_caps(keys, s.family);
            std::string detail = caps.empty() ? keys : "";
            for (const auto& part : {note, where}) if (!part.empty()) detail += (detail.empty() ? "" : " · ") + part;
            auto row = item("cheatsheet-copy", s.description, "action", detail, "info");
            row["argument"] = s.keys; row["presentation"] = "shortcut";
            if (!caps.empty()) row["keys"] = caps;
            row["keywords"] = Json::array({s.keys});
            return row;
        };
        const auto book = std::find_if(key_books.begin(), key_books.end(), [&](const KeyBook& b) { return b.id == project_scope; });
        if (!query.empty()) {
            // Searching, or the drawer's own keys from `?`: every shortcut, each saying where it belongs.
            for (const auto& s : all) rows.push_back(shortcut_row(s, s.section));
        } else if (page == "cheatsheet-keys" && book != key_books.end()) {
            out["title"] = book->label;
            std::string last;
            for (const auto& s : all) {
                if (s.family != book->family) continue;
                static const std::string dot = " · ";
                const auto at = s.section.find(dot);
                const auto heading_text = at == std::string::npos ? s.section : s.section.substr(at + dot.size());
                if (heading_text != last) { rows.push_back(heading(heading_text)); last = heading_text; }
                rows.push_back(shortcut_row(s, ""));
            }
        } else {
            for (const auto& b : key_books) {
                const auto count = std::count_if(all.begin(), all.end(), [&](const Shortcut& s) { return s.family == b.family; });
                if (!count) continue;
                auto row = item("cheatsheet-book", b.label, "page", std::string(b.detail) + " · " + std::to_string(count) + " shortcuts", b.icon);
                row["page"] = "cheatsheet-keys"; row["scope"] = b.id; row["argument"] = b.id;
                rows.push_back(row);
            }
        }
    } else if (page == "sandbox") {
        known = true; out["title"] = "Disposable sandbox";
        for (const auto& sandbox : sandboxes()) {
            auto row = item("sandbox-launch", sandbox.label, "action", sandbox.detail, "window");
            row["argument"] = sandbox.id; row["close"] = true;
            if (!sh::have(sandbox.program)) { row["enabled"] = false; row["detail"] = "Not installed"; }
            rows.push_back(row);
        }
    } else if (page == "updates") {
        known = true; out["title"] = "Updates";
        rows.push_back(item("updates-terminal", "Apply updates in terminal", "action", "Keeps the update lock and news checks", "download"));
        if (sh::have("informant")) rows.push_back(item("updates-silent", "Apply updates quietly", "action", "Protected by the unread-news guard", "download"));
        const auto pending = read(runtime() / "foxml-waybar/updates.list");
        if (pending.empty()) {
            auto row = item("updates-terminal", "No cached update list", "action", "Open the updater to check for updates", "info"); row["enabled"] = false; rows.push_back(row);
        } else {
            // The ones that touch boot, login or the graphics stack first, with why: worth a moment's care.
            std::vector<Json> careful, plain;
            for (const auto& line : lines(pending)) {
                if (trim(line).empty()) continue;
                const auto why = update_care(line.substr(0, line.find(' ')));
                auto row = item("updates-terminal", line, "action", why.empty() ? "Pending package" : why, why.empty() ? "package" : "info");
                row["enabled"] = false;
                if (!why.empty()) row["careful"] = true;
                (why.empty() ? plain : careful).push_back(row);
            }
            if (!careful.empty()) {
                auto head = item("updates-terminal", careful.size() == 1 ? "1 update needs a little care" : std::to_string(careful.size()) + " updates need a little care",
                                 "action", "Kernel, boot, login or graphics: read the notes before rebooting", "info");
                head["enabled"] = false; rows.push_back(head);
            }
            for (auto& row : careful) rows.push_back(row);
            const size_t shown = query.empty() ? std::min<size_t>(plain.size(), 12) : plain.size();
            for (size_t i = 0; i < shown; ++i) rows.push_back(plain[i]);
            if (plain.size() > shown) {
                auto more = item("updates-terminal", "and " + std::to_string(plain.size() - shown) + " more", "action", "The terminal updater lists them all", "package");
                more["enabled"] = false; rows.push_back(more);
            }
        }
    } else if (page == "earlier-notes") {
        known = true; out["title"] = "Earlier notes";
        if (!earlier_note_rows(rows)) fail(sh::have("makoctl") ? "mako's history is unavailable" : "Earlier notes read mako's history; mako is not installed");
    } else if (page == "models") {
        known = true; out["title"] = "Local models";
        model_rows(rows);
    } else if (page == "storage") {
        known = true; out["title"] = "Storage";
        storage_rows(rows);
    } else if (page == "work-health") {
        known = true; out["title"] = "Work health";
        Json health; const bool observed = capture_json({"desk-work", "health"}, health) && health.is_object() && health.value("checks", Json()).is_array();
        out["workObserved"] = observed;
        // Nothing needs attention: one line says so first, and the checks follow as the details behind it.
        const bool calm = observed && health.value("alerts", Json()).is_array() && health["alerts"].empty();
        if (calm) work_note("Everything is in order", std::to_string(health["checks"].size()) + " checks: loaded versions, project records, updates and backups", "info");
        if (observed) for (const auto& check : health["checks"]) {
            rows.push_back(heading(text(check, "label")));
            for (const auto& line : lines(text(check, "detail"))) work_note(line, "", "info");
        }
        else work_note("Health details are unavailable", "Build and install the current desk-work backend");
        rows.push_back(item("work-health-controls", "Open recovery and backup controls", "action", "Review update details in Neovim before acting", "system"));
    } else if (page == "backups") {
        known = true; out["title"] = "Backups";
        Json work_backups;
        if (capture_json({"desk-work", "integrations", "backups"}, work_backups) && work_backups.is_object()) {
            rows.push_back(heading("work integration backups"));
            work_note(std::to_string(work_backups.value("transactions", Json::array()).size()) + " transactions", std::to_string(work_backups.value("bytes", 0ULL) / 1024) + " KiB · rollback chains are retained");
            rows.push_back(item("work-backups", "Preview update backup cleanup", "action", "Review eligible backups before confirming removal in Neovim", "folder"));
        }
        backup_rows(rows);
    } else if (page == "startup") {
        known = true; out["title"] = "Startup";
        startup_rows(rows);
    } else if (page == "terminals") {
        known = true; out["title"] = "Terminals";
        terminals_rows(rows);
    } else if (page == "terminals-arrange") {
        known = true; out["title"] = "Rearrange";
        terminals_arrange_rows(rows);
    } else if (page == "terminal" || page == "terminal-pane") {
        known = true; out["title"] = "Terminal";
        if (project_scope.empty() || !(page == "terminal" ? terminal_rows(project_scope, rows, out) : terminal_pane_rows(project_scope, rows, out)))
            fail(page == "terminal" ? "That session is gone" : "That pane is gone");
    } else if (page == "programs") {
        known = true; out["title"] = "Programs";
        programs_rows(rows);
    } else if (page == "passwords") {
        known = true; out["title"] = "Passwords";
        for (const auto& name : password_names()) {
            auto row = item("password-copy", name, "action", "Copy password · pass clears the clipboard after its timeout", "key");
            row["argument"] = name;
            row["enabled"] = sh::have("pass");
            rows.push_back(row);
        }
        if (!sh::have("pass")) fail("Install pass to use your existing password store");
    } else if (page == "agents") {
        known = true; out["title"] = "Agent notes";
        // Each live Claude session first, with how full its context is; picking one goes to its pane.
        ClaudeUsage usage;
        Json activities;
        if (sh::have("desk-work")) capture_json({"desk-work", "activities"}, activities);
        for (const auto& session : claude_sessions(usage)) {
            const auto measured = session.context >= 0 ? std::to_string(session.context) + "% of its context" : "context not measured yet";
            auto row = item("claude-jump", session.name() + " · " + session.model, "action",
                            session.title.empty() ? measured : session.project + " · " + measured, "message");
            row["argument"] = session.pane; row["presentation"] = "claude"; row["claudeState"] = claude_state_text(session);
            row["context"] = session.context; row["fresh"] = session.fresh; row["enabled"] = !session.pane.empty();
            row["lastActivity"] = session.epoch;
            if (activities.is_object() && activities.contains(session.id) && activities[session.id].is_object()) {
                const auto& a = activities[session.id];
                const auto last = stamp(a, "at");
                const bool active = truth(a, "active") && claude_busy(session);
                row["currentTask"] = session.state == "needs" ? "waiting for your answer" : text(a, "text");
                row["taskStarted"] = stamp(a, "started"); row["lastActivity"] = last;
                row["detail"] = text(row, "detail") + " · " + (active ? "" : "last: ") + text(row, "currentTask")
                    + " · " + work_age(static_cast<long long>(std::time(nullptr)) - (active ? stamp(a, "started") : last))
                    + (active ? " elapsed" : " ago");
            } else if (session.state == "needs") {
                row["detail"] = text(row, "detail") + " · waiting for your answer";
            }
            row["detail"] = text(row, "detail") + " · last activity " + work_age(static_cast<long long>(std::time(nullptr)) - stamp(row, "lastActivity")) + " ago";
            if (session.pane.empty()) row["disabledReason"] = "Not in a tmux pane, so there is nowhere to jump";
            rows.push_back(row);
        }
        Json all_agents;
        if (sh::have("desk-work") && capture_json({"desk-work", "agents"}, all_agents) && all_agents.is_array())
            for (const auto& agent : all_agents) if (text(agent, "agent") != "claude") {
                auto row = item("claude-jump", text(agent, "agent") + " · " + text(agent, "name"), "action",
                    text(agent, "project") + " · " + text(agent, "state") + " · " + text(agent, "attribution", "attribution unknown"), "message");
                row["argument"] = text(agent, "pane"); row["enabled"] = !text(agent, "pane").empty(); row["close"] = true;
                if (!truth(row, "enabled")) row["disabledReason"] = "No terminal pane was recorded";
                rows.push_back(row);
            }
        const auto notes = agent_notes();
        for (auto at = notes.rbegin(); at != notes.rend() && rows.size() < 128; ++at) {
            const auto& entry = at->second;
            auto row = item("agent-jump", text(entry, "source", "Agent") + " · " + text(entry, "project", "Project"), "action", text(entry, "message"), "message");
            row["argument"] = at->first; rows.push_back(row);
        }
        if (!notes.empty()) {
            auto row = item("agent-clear", "Clear agent notes", "action", "Dismiss all pending notes", "message");
            row["confirm"] = "This puts every note away."; rows.push_back(row);
        }
    }
    if (!known) fail("Unknown drawer page");
    if (!query.empty()) {
        Json filtered = Json::array(); const auto needle = search_fold(query);
        for (const auto& row : rows) if (search_text(row).find(needle) != std::string::npos) filtered.push_back(row);
        rows = std::move(filtered);
        // A narrowed reference (the drawer's own keys, from `?`) ends with the way to every shortcut.
        if (page == "cheatsheet" && !rows.empty()) {
            auto all = item("keys-all", "All shortcuts", "page", "Every key on the desktop, not only these", "⌨");
            all["page"] = "cheatsheet"; rows.push_back(all);
        }
    }
    // Search rows come straight from the menu, so they still need their live values.
    if (page == "search") for (auto& row : rows) if (text(row, "id") != "app-launch") decorate(row);
    return out;
}

Json run_action(const Json& config, const std::string& id, const std::string& arg, bool confirmed) {
    if (!actions.count(id)) return result(false, "Unknown drawer action");
    if (!safe_text(arg)) return result(false, "Invalid action argument");
    if (id == "work-jump") return jump_claude(arg);
    if (id == "project-worktrees") {
        if (!work_project(config, arg)) return result(false, "Project is no longer in your configured project roots");
        auto out = result(true, "Worktrees opened"); out["page"] = "worktrees"; out["project"] = arg; return out;
    }
    if (id == "worktree-open" || id == "worktree-terminal") {
        if (!known_worktree(config, arg)) return result(false, "This worktree is no longer available");
        if (id == "worktree-terminal") return launch({"kitty", "--directory", arg}, "Worktree terminal opened");
        if (config.contains("project_editor")) { auto editor = config["project_editor"].get<Args>(); editor.push_back(arg); return launch(editor, "Worktree opened"); }
        return sh::have("cursor") ? launch({"cursor", arg}, "Worktree opened") : terminal({"nvim", arg}, "Worktree opened");
    }
    if (id == "work-tasks") {
        if (!work_project(config, arg)) return result(false, "Project is no longer in your configured project roots");
        return launch({"desk-work", "open", "--action", "tasks", "--root", arg}, "Project next steps opened");
    }
    if (id == "work-set-aside") { auto reply = command({"desk-work", "set-aside", "--all", "yes"}, "Commits to review set aside"); reply["close"] = false; return reply; }
    if (id == "work-bring-back") {
        const auto value = Json::parse(arg, nullptr, false);
        if (!value.is_object() || !work_project(config, text(value, "root"))) return result(false, "This project is no longer in your index cards");
        auto reply = command({"desk-work", "set-aside", "--root", text(value, "root"), "--undo", "yes"}, "Set-aside commits brought back");
        reply["close"] = false; return reply;
    }
    if (id == "work-health-controls" || id == "work-backups")
        return launch({"desk-work", "open", "--action", id == "work-backups" ? "backups" : "health"}, "Opened work controls");
    if (id == "work-reviews" || id == "work-attention" || id == "work-task-toggle" || id == "work-task-draft" || id == "work-event" || id == "work-unsnooze" || id == "work-caught-up") {
        const auto value = Json::parse(arg, nullptr, false);
        if (!value.is_object() || !work_project(config, text(value, "root"))) return result(false, "This project is no longer in your index cards");
        if (id == "work-unsnooze") { auto reply = command({"desk-work", "snooze", "--root", text(value, "root"), "--id", text(value, "id"), "--clear", "yes"}, "Attention item restored"); reply["close"] = false; return reply; }
        if (id == "work-caught-up") { auto reply = command({"desk-work", "digest", "--root", text(value, "root"), "--consumer", "desktop", "--through", std::to_string(value.value("through", 0LL))}, "Shown events marked caught up"); reply["close"] = false; return reply; }
        if (id == "work-task-toggle") return command({"desk-work", "task-toggle", "--root", text(value, "root"), "--id", text(value, "id"), "--done", "yes"}, "Next step done");
        return launch({"desk-work", "open", "--action", id == "work-event" ? "event" : id == "work-attention" ? "attention" : id == "work-reviews" ? "reviews" : "tasks", "--root", text(value, "root"), "--id", text(value, "id")}, "Opened work item");
    }
    if (id == "work-open" || id == "work-tests" || id == "work-compare" || id == "work-ask") {
        if (!std::regex_match(arg, std::regex("[a-f0-9]{32}"))) return result(false, "Invalid job record");
        return launch({"desk-work", "open", "--action", id == "work-open" ? "log" : id == "work-tests" ? "tests" : id == "work-compare" ? "compare" : "ask", "--id", arg}, "Opened in Neovim");
    }
    if (id == "service-log" || id == "service-ask") {
        if (!std::regex_match(arg, std::regex("[A-Za-z0-9_.@:-]{1,200}\\.service"))) return result(false, "Invalid service unit");
        return launch({"desk-work", "open", "--action", id == "service-log" ? "service" : "ask-service", "--id", arg}, "Service journal opened");
    }
    if (id == "agent-clear") {
        if (arg != "--confirm") return result(false, "Confirmation required");
        const bool cleared = dismiss_agent({}, true);
        return result(cleared, cleared ? "Agent notes cleared" : "Could not clear agent notes");
    }
    const bool power = id == "suspend" || id == "reboot" || id == "poweroff" || id == "logout";
    if (power) {
        if (arg != "--confirm") return result(false, "Confirmation required");
        if (id == "logout") return command({"desk-hl", "dispatch", "hl.dsp.exit()", "exit"}, "Log out", true);
        return command({"systemctl", id}, id == "suspend" ? "Suspend" : id == "reboot" ? "Restart" : "Shut down", true);
    }
    const std::set<std::string> argument_actions{"volume","brightness","power-profile","app-launch","window-focus","audio-output","wifi-connect","bluetooth-connect","tool-run","cheatsheet-copy","sandbox-launch","clipboard-restore","wallpaper-set","theme-set","project-open","project-terminal","project-bookmark","drive-open","drive-eject","download-open","download-folder","screenshot-open","screenshot-copy","screenshot-folder","password-copy","agent-jump","claude-jump","model-agent","model-remove","storage-open","backup-restore","backup-open","startup-user","startup-autostart","program-quit","program-force","terminal-go","terminal-new","terminal-here","terminal-rename","terminal-pane-move","terminal-pane-split","terminal-close","api-task-ask","api-task-open","api-task-failure","api-task-review","api-task-pi","api-task-follow","display-scale","display-rotate","display-side","display-mode","cursor-size","calendar-feed-remove","note-open","goodnight-open"};
    const bool confirm_only = arg == "--confirm" && (id == "backup-prune" || id == "storage-empty-trash");
    if (!argument_actions.count(id) && !arg.empty() && !confirm_only) return result(false, "This action accepts no argument");
    if (id == "volume" || id == "brightness") {
        int value = 0;
        if (!percent(arg, value)) return result(false, "Level must be an integer from 0 to 100");
        if (id == "volume") {
            if (!audio_state().ok) return result(false, "Audio state is unavailable");
            return command({"wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", std::to_string(value) + "%"}, "Volume adjusted", false, "Could not change the volume");
        }
        if (!brightness_state().ok) return result(false, "Brightness state is unavailable");
        return command({"brightnessctl", "set", std::to_string(std::max(1, value)) + "%"}, "Brightness adjusted", false, "Could not change the brightness");
    }
    if (id == "volume-mute" || id == "mic-mute") {
        const bool mic = id == "mic-mute";
        if (!audio_state(mic).ok) return result(false, "Audio state is unavailable");
        auto done = command({"wpctl", "set-mute", mic ? "@DEFAULT_AUDIO_SOURCE@" : "@DEFAULT_AUDIO_SINK@", "toggle"}, "mute switched", false, "Could not toggle mute");
        const auto after = audio_state(mic);
        if (truth(done, "ok") && after.ok)
            done["message"] = mic ? (after.checked ? "microphone muted · just for you" : "microphone is listening again")
                                  : (after.checked ? "sound muted · a little quiet" : "sound is back");
        return done;
    }
    if (id.rfind("media-", 0) == 0) return command({"playerctl", id.substr(6)}, "Playback updated", false, "Could not control playback");
    if (id == "nightlight") return toggle_nightlight();
    if (id == "dnd") {
        const auto state = dnd_state();
        if (!state.ok) return result(false, "Notification service is unavailable");
        auto done = state.label == "mako" ? command({"makoctl", "mode", "-t", "do-not-disturb"}, "do not disturb switched", false, "Could not toggle Do not disturb")
                                          : command({"dunstctl", "set-paused", "toggle"}, "do not disturb switched", false, "Could not toggle Do not disturb");
        const auto after = dnd_state();
        if (!truth(done, "ok") || !after.ok || after.checked == state.checked) return done;
        if (after.checked) { if (after.label == "mako") quiet_changed(true); done["message"] = "shh… notifications paused"; return done; }
        const auto missed = after.label == "mako" ? quiet_changed(false) : std::string();
        done["message"] = "notifications are back" + (missed.empty() ? std::string() : " · " + missed);
        return done;
    }
    if (id == "idle") {
        const auto idle = process_state("hypridle");
        if (!idle.ok) return result(false, "Idle service state is unavailable");
        const bool was_awake = regular(runtime() / "hypridle_paused");
        if (!idle.checked && !was_awake) return result(false, "Auto-lock is off, so the screen already stays awake");
        auto done = background({script("toggle_dpms.sh").string()}, "stay awake is switching…");
        if (!truth(done, "ok")) return done;
        // The script runs on its own; its mark appears or goes within a moment.
        for (int wait = 0; wait < 20 && regular(runtime() / "hypridle_paused") == was_awake; ++wait)
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        if (regular(runtime() / "hypridle_paused") != was_awake)
            done["message"] = was_awake ? "the screens can rest when idle again" : "staying awake · the screens stay on";
        return done;
    }
    if (id == "power-profile") {
        std::string profile = arg;
        if (profile.empty()) {
            std::string current;
            if (!capture({"powerprofilesctl", "get"}, current)) return result(false, "Power profile is unavailable");
            profile = trim(current) == "balanced" ? "performance" : trim(current) == "performance" ? "power-saver" : trim(current) == "power-saver" ? "balanced" : "";
        }
        if (profile != "balanced" && profile != "performance" && profile != "power-saver") return result(false, "Invalid power profile");
        auto done = command({"powerprofilesctl", "set", profile}, "power profile · " + profile, false, "Could not change the power profile");
        std::string now;
        if (truth(done, "ok") && capture({"powerprofilesctl", "get"}, now)) {
            now = trim(now);
            if (now == "performance") done["message"] = "performance · running at full speed";
            else if (now == "balanced") done["message"] = "balanced · as usual";
            else if (now == "power-saver") done["message"] = "power saver · going gently";
        }
        return done;
    }
    if (id == "screenshot-capture") return launch({script("screenshot.sh").string()}, "Screenshot editor opened");
    if (id == "screenshot-open" || id == "screenshot-copy" || id == "screenshot-folder") {
        for (const auto& file : screenshots(config)) if (file.path.string() == arg) {
            if (id == "screenshot-copy") return copy_screenshot(file.path);
            return launch({"xdg-open", id == "screenshot-open" ? arg : file.path.parent_path().string()},
                          id == "screenshot-open" ? "Picture opened" : "Screenshot folder opened");
        }
        return result(false, "This picture is no longer in the scrapbook");
    }
    if (id == "download-open" || id == "download-folder") {
        for (const auto& file : downloads(config)) if (file.path.string() == arg)
            return launch({"xdg-open", id == "download-open" ? arg : file.path.parent_path().string()}, id == "download-open" ? "Paper opened" : "Downloads folder opened");
        return result(false, "This file is no longer in the incoming tray");
    }
    if (id == "drive-open" || id == "drive-eject") {
        if (id == "drive-eject" && !confirmed) return result(false, "Confirmation required");
        std::vector<Volume> volumes;
        if (!library(volumes)) return result(false, "Removable drives are unavailable");
        if (id == "drive-open") {
            auto at = std::find_if(volumes.begin(), volumes.end(), [&](const auto& volume) { return volume.path == arg; });
            if (at == volumes.end()) return result(false, "This volume is no longer in the library");
            std::string mount = at->mount;
            if (mount.empty()) {
                const auto mounted = command({"udisksctl","mount","--block-device",arg,"--no-user-interaction"}, "Mount volume");
                if (!truth(mounted,"ok")) return mounted;
                volumes.clear();
                if (!library(volumes)) return result(false, "Volume mounted, but its location is unavailable");
                for (const auto& volume : volumes) if (volume.path == arg) mount = volume.mount;
            }
            if (mount.empty()) return result(false, "Volume is not mounted");
            return launch({"xdg-open", mount}, "Library volume opened");
        }
        bool found = false;
        for (const auto& volume : volumes) if (volume.disk == arg) found = true;
        if (!found) return result(false, "This drive is no longer in the library");
        for (const auto& volume : volumes) if (volume.disk == arg && !volume.mount.empty()) {
            const auto unmounted = command({"udisksctl","unmount","--block-device",volume.path,"--no-user-interaction"}, "Unmount volume");
            if (!truth(unmounted,"ok")) return result(false, "Drive remains connected: a volume could not be unmounted");
        }
        return command({"udisksctl","power-off","--block-device",arg,"--no-user-interaction"}, "Drive safely ejected", false, "Could not eject the drive");
    }
    if (id == "project-open" || id == "project-terminal" || id == "project-bookmark") {
        bool found = false;
        for (const auto& project : projects(config)) if (project.path.string() == arg) found = true;
        if (!found && id == "project-bookmark") {
            std::vector<std::string> pinned;
            if (bookmarks(pinned) && std::find(pinned.begin(), pinned.end(), arg) != pinned.end()) return toggle_bookmark(arg);
        }
        if (!found) return result(false, "Project is no longer in your configured project roots");
        if (id == "project-bookmark") return toggle_bookmark(arg);
        if (id == "project-terminal") return launch({"kitty", "--directory", arg}, "Project terminal opened");
        if (config.contains("project_editor")) {
            Args editor = config["project_editor"].get<Args>();
            editor.push_back(arg);
            return launch(editor, "Project opened in your editor");
        }
        if (sh::have("cursor")) return launch({"cursor", arg}, "Project opened in Cursor");
        return terminal({"nvim", arg}, "Project opened in Neovim");
    }
    if (id == "app-launch") {
        if (!desktops_argument(arg)) return result(false, "Application is not in the desktop catalogue");
        return launch({"gio", "launch", arg}, "Application launched");
    }
    if (id == "window-focus") {
        if (!std::regex_match(arg, std::regex("0x[0-9a-fA-F]{1,32}"))) return result(false, "Invalid window address");
        Json clients; bool found = false;
        if (!capture_json({"hyprctl", "-j", "clients"}, clients) || !clients.is_array()) return result(false, "Window list is unavailable");
        for (const auto& client : clients) if (text(client, "address") == arg) found = true;
        if (!found) return result(false, "Window no longer exists");
        return focus_address(arg);
    }
    if (id == "audio-output") {
        Json sinks; bool found = false;
        if (!capture_json({"pactl", "-f", "json", "list", "sinks"}, sinks) || !sinks.is_array()) return result(false, "Audio outputs are unavailable");
        for (const auto& sink : sinks) if (text(sink, "name") == arg && !arg.empty()) found = true;
        if (!found || arg.front() == '-') return result(false, "Invalid audio output");
        return command({"pactl", "set-default-sink", arg}, "Audio output selected", false, "Could not switch the audio output");
    }
    if ((id == "bluetooth-toggle" || id == "bluetooth-scan") && !bluetooth_service_running())
        return result(false, "The Bluetooth service is off");
    if (id == "wifi-toggle") {
        std::string current;
        if (!capture({"nmcli", "radio", "wifi"}, current) || (trim(current) != "enabled" && trim(current) != "disabled")) return result(false, "Wi-Fi radio state is unavailable");
        auto done = command({"nmcli", "radio", "wifi", trim(current) == "enabled" ? "off" : "on"}, "wi-fi switched", false, "Could not toggle Wi-Fi");
        std::string now;
        if (truth(done, "ok") && capture({"nmcli", "radio", "wifi"}, now) && (trim(now) == "enabled" || trim(now) == "disabled"))
            done["message"] = trim(now) == "enabled" ? "wi-fi on" : "wi-fi off · resting the radio";
        return done;
    }
    if (id == "wifi-connect") {
        Json networks;
        if (arg.empty() || !safe_text(arg, 32)) return result(false, "Invalid network name");
        if (!wifi_rows(networks) || !member_argument(networks, arg)) return result(false, "Network is not currently available");
        // NetworkManager reuses stored secrets. Unknown networks go to a terminal's password prompt, never this UI.
        std::string saved;
        if (capture({"nmcli", "-t", "--escape", "yes", "-f", "UUID,TYPE", "connection", "show"}, saved)) {
            for (const auto& line : lines(saved)) {
                const auto f = nm_fields(line);
                if (f.size() != 2 || f[1] != "802-11-wireless" || !std::regex_match(f[0], std::regex("[0-9a-fA-F-]{36}"))) continue;
                std::string ssid;
                if (capture({"nmcli", "-g", "802-11-wireless.ssid", "connection", "show", "uuid", f[0]}, ssid) && trim(ssid) == arg)
                    return command({"nmcli", "-w", "15", "connection", "up", "uuid", f[0]}, "Connected to " + arg, false, "Could not connect to " + arg);
            }
        }
        return terminal({"nmcli", "--ask", "device", "wifi", "connect", "--", arg}, "Network password prompt opened");
    }
    if (id == "bluetooth-toggle") {
        std::string controller;
        if (!capture({"bluetoothctl", "show"}, controller) || controller.find("Powered:") == std::string::npos) return result(false, "Bluetooth controller is unavailable");
        auto done = command({"bluetoothctl", "power", controller.find("Powered: yes") != std::string::npos ? "off" : "on"}, "bluetooth switched", false, "Could not toggle Bluetooth");
        std::string now;
        if (truth(done, "ok") && capture({"bluetoothctl", "show"}, now) && now.find("Powered:") != std::string::npos)
            done["message"] = now.find("Powered: yes") != std::string::npos ? "bluetooth on" : "bluetooth off";
        return done;
    }
    if (id == "bluetooth-service") return terminal({"sudo", "systemctl", "enable", "--now", "bluetooth"}, "Bluetooth service prompt opened");
    if (id == "bluetooth-scan") {
        if (sh::have("blueman-manager")) return launch({"blueman-manager"}, "Bluetooth manager opened");
        return terminal({"bluetoothctl"}, "Bluetooth pairing console opened");
    }
    if (id == "bluetooth-connect") {
        if (!std::regex_match(arg, std::regex("[[:xdigit:]]{2}(?::[[:xdigit:]]{2}){5}"))) return result(false, "Invalid Bluetooth address");
        if (!bluetooth_service_running()) return result(false, "The Bluetooth service is off");
        Json devices; std::string info;
        if (!bluetooth_rows(devices) || !member_argument(devices, arg) || !capture({"bluetoothctl", "info", arg}, info)) return result(false, "Bluetooth device is unavailable");
        if (info.find("Paired: yes") == std::string::npos) return terminal({"bluetoothctl", "--agent", "KeyboardDisplay", "pair", arg}, "Bluetooth pairing prompt opened");
        return command({"bluetoothctl", "--timeout", "10", info.find("Connected: yes") != std::string::npos ? "disconnect" : "connect", arg}, "Bluetooth connection updated", false, "Could not update that Bluetooth connection");
    }
    if (id == "clipboard-restore") return restore_clipboard(arg);
    if (id == "wallpaper-set") {
        bool found = false; for (const auto& path : wallpapers()) if (path.string() == arg) found = true;
        if (!found) return result(false, "Wallpaper is not in the wallpaper folder");
        return command({"desk-wallpaper", "--set", arg}, "Wallpaper selected", false, "Could not set that wallpaper");
    }
    if (id == "wallpaper-next") return command({script("rotate_wallpaper.sh").string(), "--cycle"}, "Wallpaper changed", false, "Could not change the wallpaper");
    if (id == "wallpaper-sync")
        return result(false, "Colors from wallpaper is gone: the palette it made was never one a theme could use. Themes has the palettes");
    if (id == "theme-set") {
        const auto available = themes();
        if (std::find(available.begin(), available.end(), arg) == available.end()) return result(false, "Unknown theme");
        const auto swap = repository() / "swap.sh";
        if (!regular(swap)) return result(false, "Theme swapper is unavailable");
        return terminal({"bash", swap.string(), arg}, "Theme switch opened in terminal");
    }
    if (id == "updates-terminal" || id == "updates-silent") {
        const auto updater = script("updates_menu.sh");
        if (!regular(updater)) return result(false, "Update helper is unavailable");
        return launch({"bash", updater.string(), id == "updates-terminal" ? "--apply-terminal" : "--apply-silent"}, "Updater opened");
    }
    if (id == "agent-jump") return jump_agent(arg);
    if (id == "claude-jump") return jump_claude(arg);
    if (id == "model-agent") return confirmed ? model_use_for_agent(arg) : result(false, "Confirmation required");
    if (id == "model-remove") return model_remove(arg, confirmed);
    if (id == "storage-scan") {
        std::error_code ec;
        const auto self = fs::read_symlink("/proc/self/exe", ec);
        if (ec) return result(false, "Could not start the measurement");
        auto started = launch({self.string(), "storage-scan"}, "Measuring the disk in the background");
        started["close"] = false; return started;
    }
    if (id == "storage-open") return storage_known_path(arg) ? launch({"xdg-open", arg}, "Folder opened") : result(false, "Measure the disk again first");
    if (id == "storage-clean-packages")
        return terminal({"sh", "-c", "if command -v paccache >/dev/null; then sudo paccache -rk1 && sudo paccache -ruk0; else echo 'paccache is in pacman-contrib'; fi; echo; read -rp 'Enter closes this window ' _"}, "Package cache cleanup opened");
    if (id == "storage-trim-journal")
        return terminal({"sh", "-c", "sudo journalctl --vacuum-size=500M; echo; read -rp 'Enter closes this window ' _"}, "Journal trim opened");
    if (id == "storage-flatpak-unused")
        return terminal({"sh", "-c", "flatpak uninstall --unused; echo; read -rp 'Enter closes this window ' _"}, "Flatpak cleanup opened");
    if (id == "storage-hidden")
        return terminal({"sh", "-c", "echo 'Root-only folders, largest first (read-only):'; sudo du -xh --max-depth=3 / 2>/dev/null | sort -rh | head -25; echo; read -rp 'Enter closes this window ' _"}, "Looking in a terminal");
    if (id == "storage-empty-trash") {
        if (!confirmed && arg != "--confirm") return result(false, "Confirmation required");
        return command({"gio", "trash", "--empty"}, "Trash emptied", false, "Could not empty the trash");
    }
    if (id == "backup-open" || id == "backup-restore") {
        const auto backup = find_backup(arg);
        if (!backup) return result(false, "That backup is gone");
        if (id == "backup-open") return launch({"xdg-open", backup->path.string()}, "Backup folder opened");
        if (!confirmed) return result(false, "Confirmation required");
        if (!backup->restorable) return result(false, "This backup has no restore script; open it to copy files back");
        return terminal({"bash", (backup->path / "restore.sh").string()}, "Restoring in a terminal");
    }
    if (id == "backup-prune") {
        if (arg != "--confirm") return result(false, "Confirmation required");
        const auto all = backups();
        std::error_code ec; std::size_t removed = 0;
        for (std::size_t i = 10; i < all.size(); ++i) if (fs::remove_all(all[i].path, ec) > 0 && !ec) ++removed;
        return result(true, std::to_string(removed) + (removed == 1 ? " older backup removed" : " older backups removed"));
    }
    if (id == "startup-user") return startup_user_off(arg, confirmed);
    if (id == "startup-autostart") return startup_autostart_hide(arg, confirmed);
    if (id == "program-quit") return program_quit(arg, confirmed, false);
    if (id == "terminal-go") return terminal_go(arg);
    if (id == "terminal-new") {
        std::error_code ec;
        if (!fs::is_directory(arg, ec)) return result(false, "That folder is gone");
        return launch({"kitty", "--directory", arg, "tmux", "new-session"}, "Terminal opened");
    }
    if (id == "terminal-here") return terminal_here(arg);
    if (id == "terminal-rename") {
        if (!find_session(tmux_sessions(), arg)) return result(false, "That session is gone");
        std::error_code ec;
        const auto self = fs::read_symlink("/proc/self/exe", ec);
        if (ec) return result(false, "Could not find the drawer program");
        return launch({"/bin/sh", "-c", "name=$(desk-picker --title \"Rename $2\" --prompt) && [ -n \"$name\" ] && exec \"$1\" terminal-rename \"$2\" \"$name\"",
                       "sh", self.string(), arg}, "Type a name");
    }
    if (id == "terminal-pane-move") return terminal_pane_move(arg);
    if (id == "terminal-pane-split") return terminal_pane_split(arg);
    if (id == "terminal-close") return terminal_close(arg, confirmed);
    if (id == "program-force") return program_quit(arg, confirmed, true);
    if (id == "note-open") return open_note(arg);
    if (id == "note-clear") return clear_notes();
    // The calendar is a sheet of the drawer itself, under the clock: the front end opens it like any page.
    if (id == "calendar") { auto response = result(true, ""); response["page"] = "calendar"; return response; }
    if (id == "agent-triage") { auto response = result(true, "Choose an agent note"); response["page"] = "agents"; return response; }
    // The desktop's picker script stamps the copied colour with a swatch; plain hyprpicker where it isn't deployed.
    if (id == "color-picker") return regular(script("color_picker.sh")) ? launch({"bash", script("color_picker.sh").string()}, "pick a little ink from the screen")
                                                                        : launch({"hyprpicker", "-a"}, "pick a little ink from the screen");
    if (id == "vault") { auto response = result(true, "Choose a key"); response["page"] = "passwords"; return response; }
    if (id == "password-copy") {
        const auto names = password_names();
        if (std::find(names.begin(), names.end(), arg) == names.end()) return result(false, "Unknown password entry");
        return command({"desk-password-copy", arg}, "Password copied", true, "Could not copy that password");
    }
    // Saved menus may still name these as actions; they open the same pages as the shipped menu.
    if (id == "tools" || id == "cheatsheet" || id == "sandbox") { auto response = result(true, "Choose one"); response["page"] = id; return response; }
    if (id == "tool-run") {
        const auto available = desk_tools();
        if (std::none_of(available.begin(), available.end(), [&](const Tool& tool) { return tool.name == arg; })) return result(false, "Unknown tool");
        return launch({"kitty", "--hold", "--title", "desk: " + arg, "--", (fs::path(home()) / ".local/bin" / arg).string()}, "Tool opened in a terminal");
    }
    if (id == "cheatsheet-copy") {
        const auto available = shortcuts();
        if (std::none_of(available.begin(), available.end(), [&](const Shortcut& shortcut) { return shortcut.keys == arg; })) return result(false, "Unknown shortcut");
        if (!sh::have("wl-copy")) return result(false, "wl-copy is not installed");
        const bool ok = write_clipboard(arg);
        return result(ok, ok ? "Copied: " + arg : "Could not copy that shortcut");
    }
    if (id == "sandbox-launch") {
        for (const auto& sandbox : sandboxes()) if (arg == sandbox.id) {
            if (!sh::have(sandbox.program)) return result(false, std::string(sandbox.label) + " is not installed");
            Args argv{"desk-sandbox"}; argv.insert(argv.end(), sandbox.argv.begin(), sandbox.argv.end());
            return launch(argv, "Sandbox opened");
        }
        return result(false, "Unknown sandbox");
    }
    if (id == "credits-setup") return terminal({"desk-credits", "setup"}, "Credit settings opened");
    if (id == "credits-console") return launch({"xdg-open", "https://platform.claude.com/settings/billing"}, "Claude Console opened");
    if (id.rfind("display-", 0) == 0 || id == "cursor-size") return display_action(id, arg);
    if (id == "calendar-feed-add") {
        // The link is pasted into the drawer's own prompt, then handed back to this program to keep.
        const auto self = fs::read_symlink("/proc/self/exe");
        return launch({"/bin/sh", "-c", "url=$(desk-picker --title 'Paste your course calendar link' --prompt) && [ -n \"$url\" ] && exec \"$1\" calendar-feed-add \"$url\"",
                       "sh", self.string()}, "Paste the link");
    }
    if (id == "calendar-refresh") { auto done = result(calendar_refresh() == 0, "Calendars read again"); done["close"] = false; return done; }
    if (id == "calendar-feed-remove") {
        auto feeds = calendar_feeds(); Json kept = Json::array(); bool removed = false;
        for (const auto& f : feeds) { if (feed_key(text(f, "url")) == arg) { removed = true; std::error_code ec; fs::remove(calendar_cache() / (arg + ".ics"), ec); } else kept.push_back(f); }
        if (!removed) return result(false, "That calendar is no longer here");
        auto done = result(save_calendar_feeds(kept), "Calendar removed"); done["close"] = false; return done;
    }
    if (id == "api-task-ask" || id == "api-task-review" || id == "api-task-pi") {
        for (const auto& p : api_projects()) {
            if (text(p, "id") != arg) continue;
            if (id == "api-task-pi") return terminal({"claude-api", "pi", "--project", arg}, "pi opened with API credits");
            Args args{"claude-api", "ask", "--project", arg};
            if (id == "api-task-review") args.push_back("--review-changes");
            return terminal(args, id == "api-task-review" ? "Change review prompt opened" : "API task prompt opened");
        }
        return result(false, "That API project is no longer configured");
    }
    if (id == "api-task-follow") {
        for (const auto& task : api_history())
            if (text(task, "id") == arg)
                return terminal({"claude-api", "ask", "--project", text(task, "project"), "--follow", arg}, "Follow-up prompt opened");
        return result(false, "That API task is no longer saved");
    }
    if (id == "goodnight-open") {
        if (!std::regex_match(arg, std::regex("[A-Za-z0-9._-]{1,80}"))) return result(false, "Invalid note name");
        const auto file = goodnight_dir() / (arg + ".md");
        if (!regular(file)) return result(false, "That note has been put away");
        return terminal({"nvim", file.string()}, "Last night's note opened");
    }
    if (id == "api-task-settings") {
        const auto file = config_home() / "foxml/api-tasks.json";
        if (!regular(file)) {
            std::string ignored;
            if (!capture({"claude-api", "configure"}, ignored)) return result(false, "Could not create API task settings");
        }
        return terminal({"nvim", file.string()}, "API task settings opened");
    }
    if (id == "api-task-failure") {
        if (!std::regex_match(arg, std::regex("[a-f0-9]{32}"))) return result(false, "Invalid job record");
        Json job; std::string log;
        if (!capture_json({"desk-work", "tests", "--id", arg}, job) || !job.is_object()) return result(false, "That job is no longer available");
        const auto project = api_project_for(api_projects(), text(job, "root"));
        if (project.empty()) return result(false, "This project is not set up for API reviews");
        if (!capture({"desk-work", "log", "--id", arg}, log) || log.empty()) log = "No captured output; inspect the originating terminal.";
        if (log.size() > 12000) log = log.substr(log.size() - 12000);
        const std::string exit_code = job.contains("exit") && job["exit"].is_number() ? std::to_string(whole(job, "exit")) : "unknown";
        const auto question = "Failed command in " + text(job, "root") + "\nCommand: " + text(job, "command")
                            + "\nExit: " + exit_code + "\n\n" + log;
        const auto folder = runtime() / "foxml/api-questions";
        std::error_code ec; fs::create_directories(folder, ec);
        fs::permissions(folder, fs::perms::owner_all, fs::perm_options::replace, ec);
        const auto file = folder / (arg + ".txt");
        if (!write_atomic(file, question)) return result(false, "Could not prepare the failure for review");
        return terminal({"claude-api", "ask", "--project", project, "--root", text(job, "root"), "--question-file", file.string()},
                        "API review prompt opened");
    }
    if (id == "api-task-open") {
        if (!std::regex_match(arg, std::regex("[0-9a-f]{32}"))) return result(false, "Invalid API task ID");
        return terminal({"claude-api", "open", arg}, "API task result opened in Neovim");
    }
    if (id == "security") return terminal({"desk", "sec", "dashboard", "--live"}, "Security dashboard opened");
    if (id == "cleanup") return terminal({"zsh", "-ic", "fox-clean; print; read -s '?Press enter to close…'"}, "System cleanup opened");
    if (id == "lock") return launch({script("lock.sh").string()}, "Screen lock opened");
    return result(false, "Action is unavailable");
}
} // namespace

int main(int argc, char** argv) {
    try {
        fs::path config_path = config_home() / "quickshell/foxml/menus.json";
        std::string project_scope;
        Args args;
        for (int i = 1; i < argc; ++i) {
            if (std::string(argv[i]) == "--config" && i + 1 < argc) config_path = argv[++i];
            else if (std::string(argv[i]) == "--project" && i + 1 < argc) project_scope = argv[++i];
            else args.emplace_back(argv[i]);
        }
        if (!args.empty() && args[0] == "pick") return pick(args);
        if (args.size() == 1 && (args[0] == "--help" || args[0] == "help")) {
            std::cout << "desk-drawer [--config PATH] view PAGE [QUERY]\nfox-drawer [--config PATH] run ACTION [ARGUMENT]\nfox-drawer [--config PATH] commit-days YYYY-MM\nfox-drawer claude-bar | claude-lock-line | claude-next | away-start | away-summary\nfox-drawer pick [--title TITLE] [--index | --prompt]\n"; return 0;
        }
        // Polled by the bar every few seconds, so it reads no menu and never waits long on tmux.
        if (args.size() == 1 && args[0] == "claude-bar") {
            read_limit_seconds = 2;
            std::cout << claude_bar().dump(-1, ' ', false, Json::error_handler_t::replace) << '\n';
            return 0;
        }
        if (args.size() == 1 && args[0] == "claude-lock-line") {
            read_limit_seconds = 2;
            std::cout << claude_lock_line() << '\n';
            return 0;
        }
        // Every page the backend answers, one per line: the drawer's self-check opens each.
        if (args.size() == 1 && args[0] == "pages") {
            for (const auto& page : pages) std::cout << page << '\n';
            return 0;
        }
        // The paper notebook's peers: the same live sessions the Agents page shows, one rule for both.
        if (args.size() == 1 && args[0] == "claude-peers") {
            read_limit_seconds = 2;
            ClaudeUsage usage;
            Json peers = Json::array();
            for (const auto& session : claude_sessions(usage))
                peers.push_back(Json{{"id", session.id}, {"name", session.name()}, {"project", session.project},
                                     {"state", claude_state_text(session)}, {"busy", claude_busy(session)}, {"pane", session.pane}});
            std::cout << peers.dump(-1, ' ', false, Json::error_handler_t::replace) << '\n';
            return 0;
        }
        // mako's on-notify hook: `on-notify=exec desk-drawer note-arrived "$id"` stamps when each note came.
        if (args.size() == 2 && args[0] == "note-arrived") return note_arrived(args[1]);
        // The installer, after deploying: the ribbons reach Thunar's sidebar on a machine that already has them.
        if (args.size() == 1 && args[0] == "thunar-bookmarks") return sync_thunar_bookmarks();
        // The course calendars: read now (detached, by the drawer), or keep a pasted link.
        if (args.size() == 1 && args[0] == "calendar-refresh") return calendar_refresh();
        if (args.size() == 3 && args[0] == "terminal-rename") {
            const auto renamed = terminal_rename(args[1], args[2]);
            if (sh::have("notify-send")) sh::run({"notify-send", "--app-name=FoxML", "Terminals", text(renamed, "message")});
            return truth(renamed, "ok") ? 0 : 1;
        }
        if (args.size() == 2 && args[0] == "calendar-feed-add") {
            const auto added = calendar_feed_add(args[1]);
            if (sh::have("notify-send")) sh::run({"notify-send", "--app-name=FoxML", truth(added, "ok") ? "Course calendar" : "Course calendar not added", text(added, "message")});
            return truth(added, "ok") ? 0 : 1;
        }
        // desk-pulse: after workspace switches, and after screens come or go.
        if (args.size() == 1 && args[0] == "workspaces-remember") { read_limit_seconds = 2; return workspaces_remember(); }
        if (args.size() == 1 && args[0] == "screens-changed") { read_limit_seconds = 3; return screens_changed(); }
        // desk-lock, detached: the stamp as the screen locks, and the "while you were away" note after unlock.
        if (args.size() == 1 && args[0] == "away-start") { read_limit_seconds = 2; return away_start(); }
        if (args.size() == 1 && args[0] == "away-summary") {
            Json config; std::string error;
            if (!read_config(config_path, config, error)) config = Json::object();
            return away_summary(config);
        }
        // The Storage page's measurement: slow on purpose (it walks the disk), run detached by the page.
        if (args.size() == 1 && args[0] == "storage-scan") return storage_scan();
        // The Displays page's safety timer: goes back to the saved layout unless it was kept.
        if (args.size() == 2 && args[0] == "display-revert") return display_revert(args[1]);
        if (args.size() == 1 && args[0] == "claude-next") {
            read_limit_seconds = 2;
            const auto jumped = jump_next_claude();
            std::cout << jumped.dump() << '\n';
            return truth(jumped, "ok") ? 0 : 1;
        }
        if (args.size() < 2 || args.size() > 4 || (args[0] != "view" && args[0] != "run" && args[0] != "commit-days")
            || (args.size() == 4 && (args[0] != "run" || args[3] != "--confirm"
                || !std::set<std::string>{"drive-eject", "model-agent", "model-remove", "backup-restore", "startup-user", "startup-autostart", "calendar-feed-remove", "program-quit", "program-force", "terminal-close"}.count(args[1])))) {
            std::cout << result(false, "Use view PAGE [QUERY] or run ACTION [ARGUMENT]").dump() << '\n'; return 1;
        }
        Json config; std::string error;
        if (!read_config(config_path, config, error)) {
            Json failure = result(false, error);
            if (args[0] == "view") { failure["error"] = error; failure["id"] = args[1]; failure["title"] = "Unavailable"; failure["items"] = Json::array(); }
            std::cout << failure.dump() << '\n'; return 1;
        }
        if (args[0] == "commit-days") {
            if (args.size() != 2 || !valid_month(args[1])) { std::cout << result(false, "Use commit-days YYYY-MM").dump() << '\n'; return 1; }
            read_limit_seconds = 4;
            std::cout << commit_days(config, args[1]).dump() << '\n';
            return 0;
        }
        const auto argument = args.size() >= 3 ? args[2] : "";
        if (!safe_text(argument)) { std::cout << result(false, "Invalid argument").dump() << '\n'; return 1; }
        if (args[0] == "view") read_limit_seconds = 4;
        const Json response = args[0] == "view" ? view(config, args[1], argument, project_scope) : run_action(config, args[1], argument, args.size() == 4);
        std::cout << response.dump(-1, ' ', false, Json::error_handler_t::replace) << '\n';
        return truth(response, "ok") ? 0 : 1;
    } catch (const std::exception&) {
        std::cout << result(false, "Could not read drawer data").dump() << '\n'; return 1;
    }
}
