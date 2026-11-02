#include "json.hpp"
#include "shell.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <vector>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/file.h>
#include <sys/statvfs.h>
#include <unistd.h>

namespace fs = std::filesystem;
namespace sh = fox_install::sh;
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
    "apps", "windows", "audio-outputs", "wifi", "bluetooth", "clipboard-text", "clipboard-images",
    "wallpapers", "themes", "power", "updates", "agents", "projects", "bookmarks", "library", "downloads"
};
const std::set<std::string> actions = {
    "volume", "volume-mute", "mic-mute", "media-play-pause", "media-next", "media-previous", "brightness",
    "nightlight", "dnd", "idle", "power-profile", "lock", "suspend", "reboot", "poweroff", "logout",
    "wallpaper-next", "wallpaper-sync", "color-picker", "updates-terminal", "updates-silent", "vault",
    "security", "cleanup", "agent-triage", "app-launch", "window-focus", "audio-output", "wifi-connect",
    "wifi-toggle", "bluetooth-connect", "bluetooth-toggle", "bluetooth-scan", "clipboard-restore", "wallpaper-set", "theme-set", "project-open", "project-terminal", "project-bookmark", "drive-open", "drive-eject", "download-open", "download-folder"
};
Json item(const std::string& id, const std::string& label, const std::string& kind = "action",
          const std::string& detail = {}, const std::string& icon = {}) {
    return Json{{"id", id}, {"label", label}, {"kind", kind}, {"detail", detail}, {"icon", icon}, {"enabled", true}};
}
Json result(bool ok, const std::string& message, bool close = false) {
    return Json{{"ok", ok}, {"message", message}, {"close", close}};
}
Json command(const Args& args, const std::string& message, bool close = false) {
    std::string output;
    if (!sh::have(args.front())) return result(false, args.front() + " is not installed");
    if (!sh::capture(args, output)) return result(false, "Could not " + lower(message));
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
    if (!sh::capture(args, out)) return false;
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
    const std::set<std::string> allowed = {"id","label","detail","icon","kind","page","value","checked","enabled","confirm","argument","close","description"};
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
    if (config.contains("downloads_directory")) {
        const auto path = text(config, "downloads_directory");
        if (path.empty() || !safe_text(path) || (!fs::path(path).is_absolute() && path.rfind("~/", 0) != 0)) {
            error = "downloads_directory must be absolute or start with ~/"; return false;
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
    if (!sh::capture({"wpctl", "get-volume", microphone ? "@DEFAULT_AUDIO_SOURCE@" : "@DEFAULT_AUDIO_SINK@"}, out)) return state;
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
    if (!sh::capture({"brightnessctl", "-m"}, out)) return state;
    std::smatch match;
    if (!std::regex_search(out, match, std::regex(",([0-9]{1,3})%,"))) return state;
    int value = 0; const auto digits = match[1].str();
    std::from_chars(digits.data(), digits.data() + digits.size(), value);
    if (value > 100) return state;
    state.ok = true; state.value = value; state.label = std::to_string(value) + "%"; return state;
}
State dnd_state() {
    State state; std::string out;
    if (sh::have("makoctl") && sh::capture({"makoctl", "mode"}, out)) {
        state.ok = true; state.checked = out.find("do-not-disturb") != std::string::npos; state.label = "mako";
    } else if (sh::have("dunstctl") && sh::capture({"dunstctl", "is-paused"}, out) && (trim(out) == "true" || trim(out) == "false")) {
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
std::string required(const std::string& id) {
    if (id == "volume" || id == "volume-mute" || id == "mic-mute") return "wpctl";
    if (id.rfind("media-", 0) == 0) return "playerctl";
    if (id == "brightness") return "brightnessctl";
    if (id == "nightlight") return "wlsunset";
    if (id == "power-profile") return "powerprofilesctl";
    if (id == "color-picker") return "hyprpicker";
    if (id == "vault") return "rofi-pass";
    if (id == "security") return "fox";
    if (id == "suspend" || id == "reboot" || id == "poweroff") return "systemctl";
    if (id == "logout") return "fox-hl";
    return {};
}
bool decorate(Json& row) {
    const auto id = text(row, "id");
    if (text(row, "kind") == "page") return true;
    const auto dependency = required(id);
    if (!dependency.empty() && !sh::have(dependency)) {
        row["enabled"] = false; row["detail"] = dependency + " is not installed"; return false;
    }
    State state;
    bool queried = false;
    if (id == "volume" || id == "volume-mute" || id == "mic-mute") { state = audio_state(id == "mic-mute"); queried = true; }
    else if (id == "brightness") { state = brightness_state(); queried = true; }
    else if (id == "dnd") { state = dnd_state(); queried = true; }
    else if (id == "nightlight") { state = process_state("wlsunset"); queried = true; }
    else if (id == "idle") {
        state = process_state("hypridle");
        const bool paused = regular(runtime() / "hypridle_paused");
        state.ok = state.ok && (paused || state.checked); state.checked = paused; queried = true;
    }
    else if (id == "power-profile") {
        std::string out; queried = true;
        state.ok = sh::capture({"powerprofilesctl", "get"}, out);
        state.label = trim(out);
        state.ok = state.ok && (state.label == "balanced" || state.label == "performance" || state.label == "power-saver");
    }
    if (queried) {
        if (!state.ok) {
            row["enabled"] = false; row["detail"] = "State unavailable"; row.erase("value"); row.erase("checked"); return false;
        }
        if (text(row, "kind") == "slider") row["value"] = std::min(100.0, state.value);
        if (text(row, "kind") == "toggle") row["checked"] = state.checked;
        if (!state.label.empty() && id != "dnd") row["detail"] = state.label;
    }
    if (id == "suspend" || id == "reboot" || id == "poweroff" || id == "logout") row["confirm"] = true;
    return true;
}

struct Desktop { std::string name, detail, icon; fs::path path; };
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
            found.push_back({values["Name"], values["Comment"], values["Icon"], fs::absolute(path)});
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
    if (!sh::capture({"nmcli", "-t", "--escape", "yes", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "no"}, out)) return false;
    rows = Json::array(); std::set<std::string> seen;
    for (const auto& line : lines(out)) {
        const auto f = nm_fields(line);
        if (f.size() != 4 || f[1].empty() || !safe_text(f[1], 32) || !seen.insert(f[1]).second) continue;
        auto row = item("wifi-connect", f[1], "action", f[2] + "% · " + (f[3].empty() ? "Open" : f[3]), "wifi");
        row["argument"] = f[1]; row["checked"] = f[0] == "*"; rows.push_back(row);
    }
    return true;
}
bool bluetooth_rows(Json& rows) {
    std::string out;
    if (!sh::capture({"bluetoothctl", "devices"}, out)) return false;
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
std::string image_preview(const std::string& id) {
    std::string bytes;
    if (!sh::capture({"cliphist", "decode", id}, bytes) || bytes.empty() || bytes.size() > 16 * 1024 * 1024) return {};
    std::string mime;
    if (bytes.size() >= 8 && bytes.compare(0, 8, "\211PNG\r\n\032\n", 8) == 0) mime = "image/png";
    else if (bytes.size() >= 3 && bytes.compare(0, 3, "\377\330\377", 3) == 0) mime = "image/jpeg";
    else if (bytes.size() >= 12 && bytes.compare(0, 4, "RIFF") == 0 && bytes.compare(8, 4, "WEBP") == 0) mime = "image/webp";
    else return {};
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
            const bool ok = offset == bytes.size() && sh::capture({"magick", std::string(path.data()) + "[0]", "-thumbnail", "144x88>", "-strip", "png:-"}, thumbnail);
            ::unlink(path.data());
            if (ok && !thumbnail.empty() && thumbnail.size() <= 256 * 1024) { bytes = std::move(thumbnail); mime = "image/png"; }
        }
    }
    if (bytes.size() > 256 * 1024) return {};
    return "data:" + mime + ";base64," + base64(bytes);
}
bool clipboard_rows(Json& rows, bool images) {
    std::string out;
    if (!sh::capture({"cliphist", "list"}, out)) return false;
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
Json restore_clipboard(const std::string& id) {
    if (!numeric_id(id)) return result(false, "Invalid clipboard ID");
    Json rows;
    if ((!clipboard_rows(rows, false) || !member_argument(rows, id)) && (!clipboard_rows(rows, true) || !member_argument(rows, id)))
        return result(false, "Clipboard entry is unavailable");
    if (!sh::have("wl-copy")) return result(false, "wl-copy is not installed");
    // Decode succeeds before touching the live clipboard; an invalid decode must not replace it with an empty value.
    std::string data;
    if (!sh::capture({"cliphist", "decode", id}, data)) return result(false, "Could not decode clipboard entry");
    int pipefd[2]; if (::pipe(pipefd) < 0) return result(false, "Could not open clipboard pipe");
    const pid_t child = ::fork();
    if (child < 0) { ::close(pipefd[0]); ::close(pipefd[1]); return result(false, "Could not start clipboard writer"); }
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
    while (::waitpid(child, &status, 0) < 0) if (errno != EINTR) return result(false, "Could not await clipboard writer");
    const bool ok = offset == data.size() && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    return result(ok, ok ? "Clipboard restored" : "Could not restore clipboard", ok);
}

std::string group_for(const Json& config, const std::string& page) {
    for (const auto& group : config["groups"]) {
        if (text(group, "id") == page) return page;
        for (const auto& row : group["items"]) if (text(row, "page") == page) return text(group, "id");
    }
    return {};
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
    return result(ok, message);
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

Json project_card(const Project& project, bool pinned) {
    std::string location = project.path.string();
    if (location.rfind(home() + "/", 0) == 0) location = "~" + location.substr(home().size());
    auto row = item("project-open", project.name, "action", project.type + " · " + location, "▤");
    row["argument"] = project.path.string(); row["close"] = true;
    row["presentation"] = "project"; row["bookmarked"] = pinned;
    return row;
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
        if (sh::capture({"xdg-user-dir", "DOWNLOAD"}, output) && fs::path(trim(output)).is_absolute()) path = trim(output);
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
    std::string name, type, age;
    uint64_t size;
    fs::file_time_type modified;
};
std::vector<Download> downloads(const Json& config) {
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
        found.push_back({entry.path(), name, type, age, size, modified});
    }
    std::sort(found.begin(), found.end(), [](const auto& a, const auto& b) {
        return a.modified != b.modified ? a.modified > b.modified : a.name < b.name;
    });
    if (found.size() > 64) found.resize(64);
    return found;
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
        if (!sh::capture({"nmcli", "-t", "-f", "TYPE,NAME", "connection", "show", "--active"}, out)) return "Network unavailable";
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
        return std::to_string(count) + " cached updates";
    }
    return {};
}

Json view(const Json& config, const std::string& page, const std::string& query) {
    Json out{{"id", page}, {"title", page}, {"items", Json::array()}, {"ok", true}, {"group", group_for(config, page)}};
    auto& rows = out["items"];
    auto fail = [&](const std::string& message) { out["ok"] = false; out["error"] = message; };
    bool known = false;
    if (page == "root") {
        known = true; out["title"] = text(config, "title", "FoxML");
        for (const auto& group : config["groups"]) {
            auto row = item(text(group, "id"), text(group, "label"), "page", text(group, "description"), text(group, "icon"));
            row["summary"] = group_summary(text(group, "id"));
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
        known = true; out["title"] = "Find a little thing";
        for (const auto& group : config["groups"]) for (auto row : group["items"]) {
            row["detail"] = text(group, "label") + (text(row, "detail").empty() ? "" : " › " + text(row, "detail"));
            row["group"] = text(group, "id"); rows.push_back(row);
        }
        if (!query.empty()) {
            for (const auto& app : desktops()) {
                auto row = item("app-launch", app.name, "action", "Desk › Applications · " + app.detail, app.icon);
                row["argument"] = app.path.string(); row["close"] = true;
                row["group"] = "desk"; row["enabled"] = sh::have("gio"); rows.push_back(row);
            }
            Json clients;
            if (sh::have("hyprctl") && capture_json({"hyprctl", "-j", "clients"}, clients) && clients.is_array()) {
                for (const auto& client : clients) {
                    if (!client.is_object() || text(client, "address").empty()) continue;
                    auto row = item("window-focus", text(client, "title", text(client, "class", "Window")),
                                    "action", "Desk › Windows · " + text(client, "class"), "window");
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
            rows.push_back(row);
        }
    }
    if (page == "projects" || page == "bookmarks") {
        known = true; out["title"] = page == "bookmarks" ? "Bookmarked pages" : "Project index cards";
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
            row["enabled"] = sh::have("udisksctl") && sh::have("xdg-open"); rows.push_back(row);
        }
    } else if (page == "downloads") {
        known = true; out["title"] = "Incoming paper tray";
        for (const auto& file : downloads(config)) {
            auto row = item("download-open", file.name, "action", file.type + " · " + capacity(file.size) + " · modified " + lower(file.age), "✉");
            row["argument"] = file.path.string(); row["close"] = true;
            row["presentation"] = "download"; row["stamp"] = file.age;
            row["enabled"] = sh::have("xdg-open"); rows.push_back(row);
        }
    } else if (page == "apps") {
        known = true; out["title"] = "Applications";
        if (!sh::have("gio")) fail("gio is not installed");
        for (const auto& app : desktops()) {
            auto row = item("app-launch", app.name, "action", app.detail, app.icon);
            row["argument"] = app.path.string(); row["close"] = true; row["enabled"] = sh::have("gio"); rows.push_back(row);
        }
    } else if (page == "windows") {
        known = true; out["title"] = "Windows"; Json clients;
        if (!capture_json({"hyprctl", "-j", "clients"}, clients) || !clients.is_array()) fail("Hyprland windows are unavailable");
        else for (const auto& client : clients) {
            if (!client.is_object() || text(client, "address").empty()) continue;
            auto row = item("window-focus", text(client, "title", text(client, "class", "Window")), "action", text(client, "class"), "window");
            row["argument"] = text(client, "address"); row["close"] = true; rows.push_back(row);
        }
    } else if (page == "audio-outputs") {
        known = true; out["title"] = "Audio outputs"; Json sinks; std::string current;
        sh::capture({"pactl", "get-default-sink"}, current);
        if (!capture_json({"pactl", "-f", "json", "list", "sinks"}, sinks) || !sinks.is_array()) fail("Audio devices are unavailable");
        else for (const auto& sink : sinks) {
            if (!sink.is_object() || text(sink, "name").empty()) continue;
            auto row = item("audio-output", text(sink, "description", text(sink, "name")), "action", text(sink, "state"), "volume");
            row["argument"] = text(sink, "name"); row["checked"] = trim(current) == text(sink, "name"); rows.push_back(row);
        }
    } else if (page == "wifi") {
        known = true; out["title"] = "Wi-Fi";
        if (!wifi_rows(rows)) fail("NetworkManager Wi-Fi is unavailable");
        std::string radio;
        auto toggle = item("wifi-toggle", "Wi-Fi radio", "toggle", "Wireless connection", "wifi");
        if (sh::capture({"nmcli", "radio", "wifi"}, radio) && (trim(radio) == "enabled" || trim(radio) == "disabled")) toggle["checked"] = trim(radio) == "enabled";
        else { toggle["enabled"] = false; toggle["detail"] = "Radio state unavailable"; }
        rows.insert(rows.begin(), toggle);
    } else if (page == "bluetooth") {
        known = true; out["title"] = "Bluetooth";
        if (!bluetooth_rows(rows)) fail("Bluetooth devices are unavailable");
        for (auto& row : rows) {
            std::string info;
            if (sh::capture({"bluetoothctl", "info", text(row, "argument")}, info) && info.find("Connected:") != std::string::npos) {
                row["kind"] = "toggle"; row["checked"] = info.find("Connected: yes") != std::string::npos;
                const auto status = truth(row, "checked") ? "Connected" : info.find("Paired: yes") != std::string::npos ? "Paired" : "Not paired";
                row["detail"] = std::string(status) + " · " + text(row, "argument");
            } else { row["enabled"] = false; row["detail"] = "Device state unavailable"; }
        }
        auto toggle = item("bluetooth-toggle", "Bluetooth power", "toggle", {}, "bluetooth"); std::string controller;
        if (sh::capture({"bluetoothctl", "show"}, controller) && controller.find("Powered:") != std::string::npos)
            toggle["checked"] = controller.find("Powered: yes") != std::string::npos;
        else { toggle["enabled"] = false; toggle["detail"] = "Controller state unavailable"; }
        rows.insert(rows.begin(), toggle);
        rows.push_back(item("bluetooth-scan", "Scan and pair devices", "action", "Opens the Bluetooth manager", "search"));
    } else if (page == "clipboard-text" || page == "clipboard-images") {
        known = true; out["title"] = page == "clipboard-images" ? "Image clipboard" : "Text clipboard";
        if (!clipboard_rows(rows, page == "clipboard-images")) fail("Clipboard history is unavailable");
        else if (page == "clipboard-images") {
            size_t previews = 0;
            for (auto& row : rows) {
                if (previews++ >= 24) break;
                const auto image = image_preview(text(row, "argument"));
                if (!image.empty()) row["image"] = image;
            }
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
            auto row = item("theme-set", theme, "action", "Apply in terminal", "palette");
            row["argument"] = theme; row["checked"] = theme == active; row["close"] = true; rows.push_back(row);
        }
        if (rows.empty()) fail("No theme repository was found");
    } else if (page == "power") {
        known = true; out["title"] = "Power";
        for (const auto& pair : std::vector<std::pair<std::string,std::string>>{{"lock","Lock screen"},{"suspend","Suspend"},{"logout","Log out"},{"reboot","Restart"},{"poweroff","Shut down"}}) {
            auto row = item(pair.first, pair.second, "action", {}, pair.first);
            decorate(row); rows.push_back(row);
        }
    } else if (page == "updates") {
        known = true; out["title"] = "Updates";
        rows.push_back(item("updates-terminal", "Apply updates in terminal", "action", "Keeps the update lock and news checks", "download"));
        if (sh::have("informant")) rows.push_back(item("updates-silent", "Apply updates quietly", "action", "Protected by the unread-news guard", "download"));
        const auto pending = read(runtime() / "foxml-waybar/updates.list");
        if (pending.empty()) {
            auto row = item("updates-terminal", "No cached update list", "action", "Open the updater to check for updates", "info"); rows.push_back(row);
        } else for (const auto& line : lines(pending)) {
            if (line.empty()) continue;
            auto row = item("updates-terminal", line, "action", "Pending package", "package"); row["enabled"] = false; rows.push_back(row);
        }
    } else if (page == "agents") {
        known = true; out["title"] = "Agent notifications";
        rows.push_back(item("agent-triage", "Open agent triage", "action", "Jump to a pending agent's terminal", "message"));
        for (const auto& line : lines(read(runtime() / "foxml-agent-queue.jsonl"))) {
            const auto entry = Json::parse(line, nullptr, false);
            if (!entry.is_object()) continue;
            auto row = item("agent-triage", text(entry, "source", "Agent") + " · " + text(entry, "project", "Project"), "action", text(entry, "message"), "message"); rows.push_back(row);
        }
    }
    if (!known) fail("Unknown drawer page");
    if (!query.empty()) {
        Json filtered = Json::array(); const auto needle = lower(query);
        for (const auto& row : rows) if (lower(text(row, "label") + " " + text(row, "detail")).find(needle) != std::string::npos) filtered.push_back(row);
        rows = std::move(filtered);
    }
    return out;
}

Json run_action(const Json& config, const std::string& id, const std::string& arg, bool confirmed) {
    if (!actions.count(id)) return result(false, "Unknown drawer action");
    if (!safe_text(arg)) return result(false, "Invalid action argument");
    const bool power = id == "suspend" || id == "reboot" || id == "poweroff" || id == "logout";
    if (power) {
        if (arg != "--confirm") return result(false, "Confirmation required");
        if (id == "logout") return command({"fox-hl", "dispatch", "hl.dsp.exit()", "exit"}, "Log out", true);
        return command({"systemctl", id}, id == "suspend" ? "Suspend" : id == "reboot" ? "Restart" : "Shut down", true);
    }
    const std::set<std::string> argument_actions{"volume","brightness","power-profile","app-launch","window-focus","audio-output","wifi-connect","bluetooth-connect","clipboard-restore","wallpaper-set","theme-set","project-open","project-terminal","project-bookmark","drive-open","drive-eject","download-open","download-folder"};
    if (!argument_actions.count(id) && !arg.empty()) return result(false, "This action accepts no argument");
    if (id == "volume" || id == "brightness") {
        int value = 0;
        if (!percent(arg, value)) return result(false, "Level must be an integer from 0 to 100");
        if (id == "volume") {
            if (!audio_state().ok) return result(false, "Audio state is unavailable");
            return command({"wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", std::to_string(value) + "%"}, "Volume adjusted");
        }
        if (!brightness_state().ok) return result(false, "Brightness state is unavailable");
        return command({"brightnessctl", "set", std::to_string(std::max(1, value)) + "%"}, "Brightness adjusted");
    }
    if (id == "volume-mute" || id == "mic-mute") {
        if (!audio_state(id == "mic-mute").ok) return result(false, "Audio state is unavailable");
        return command({"wpctl", "set-mute", id == "mic-mute" ? "@DEFAULT_AUDIO_SOURCE@" : "@DEFAULT_AUDIO_SINK@", "toggle"}, "Mute toggled");
    }
    if (id.rfind("media-", 0) == 0) return command({"playerctl", id.substr(6)}, "Playback updated");
    if (id == "nightlight") {
        const auto state = process_state("wlsunset");
        if (!state.ok) return result(false, "Night light state is unavailable");
        return state.checked ? command({"pkill", "-x", "wlsunset"}, "Night light disabled") : background({"wlsunset", "-t", "3500", "-T", "6500"}, "Night light enabled");
    }
    if (id == "dnd") {
        const auto state = dnd_state();
        if (!state.ok) return result(false, "Notification service is unavailable");
        return state.label == "mako" ? command({"makoctl", "mode", "-t", "do-not-disturb"}, "Do not disturb toggled")
                                     : command({"dunstctl", "set-paused", "toggle"}, "Do not disturb toggled");
    }
    if (id == "idle") {
        if (!process_state("hypridle").ok) return result(false, "Idle service state is unavailable");
        return background({script("toggle_dpms.sh").string()}, "Idle inhibition toggled");
    }
    if (id == "power-profile") {
        std::string profile = arg;
        if (profile.empty()) {
            std::string current;
            if (!sh::capture({"powerprofilesctl", "get"}, current)) return result(false, "Power profile is unavailable");
            profile = trim(current) == "balanced" ? "performance" : trim(current) == "performance" ? "power-saver" : trim(current) == "power-saver" ? "balanced" : "";
        }
        if (profile != "balanced" && profile != "performance" && profile != "power-saver") return result(false, "Invalid power profile");
        return command({"powerprofilesctl", "set", profile}, "Power profile: " + profile);
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
        return command({"udisksctl","power-off","--block-device",arg,"--no-user-interaction"}, "Drive safely ejected");
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
        return command({"hyprctl", "dispatch", "focuswindow", "address:" + arg}, "Window selected", true);
    }
    if (id == "audio-output") {
        Json sinks; bool found = false;
        if (!capture_json({"pactl", "-f", "json", "list", "sinks"}, sinks) || !sinks.is_array()) return result(false, "Audio outputs are unavailable");
        for (const auto& sink : sinks) if (text(sink, "name") == arg && !arg.empty()) found = true;
        if (!found || arg.front() == '-') return result(false, "Invalid audio output");
        return command({"pactl", "set-default-sink", arg}, "Audio output selected");
    }
    if (id == "wifi-toggle") {
        std::string current;
        if (!sh::capture({"nmcli", "radio", "wifi"}, current) || (trim(current) != "enabled" && trim(current) != "disabled")) return result(false, "Wi-Fi radio state is unavailable");
        return command({"nmcli", "radio", "wifi", trim(current) == "enabled" ? "off" : "on"}, "Wi-Fi radio toggled");
    }
    if (id == "wifi-connect") {
        Json networks;
        if (arg.empty() || !safe_text(arg, 32)) return result(false, "Invalid network name");
        if (!wifi_rows(networks) || !member_argument(networks, arg)) return result(false, "Network is not currently available");
        // NetworkManager reuses stored secrets. Unknown networks go to a terminal's password prompt, never this UI.
        std::string saved;
        if (sh::capture({"nmcli", "-t", "--escape", "yes", "-f", "UUID,TYPE", "connection", "show"}, saved)) {
            for (const auto& line : lines(saved)) {
                const auto f = nm_fields(line);
                if (f.size() != 2 || f[1] != "802-11-wireless" || !std::regex_match(f[0], std::regex("[0-9a-fA-F-]{36}"))) continue;
                std::string ssid;
                if (sh::capture({"nmcli", "-g", "802-11-wireless.ssid", "connection", "show", "uuid", f[0]}, ssid) && trim(ssid) == arg)
                    return command({"nmcli", "-w", "15", "connection", "up", "uuid", f[0]}, "Connected to " + arg);
            }
        }
        return terminal({"nmcli", "--ask", "device", "wifi", "connect", "--", arg}, "Network password prompt opened");
    }
    if (id == "bluetooth-toggle") {
        std::string controller;
        if (!sh::capture({"bluetoothctl", "show"}, controller) || controller.find("Powered:") == std::string::npos) return result(false, "Bluetooth controller is unavailable");
        return command({"bluetoothctl", "power", controller.find("Powered: yes") != std::string::npos ? "off" : "on"}, "Bluetooth power toggled");
    }
    if (id == "bluetooth-scan") return terminal({"bluetoothctl"}, "Bluetooth pairing console opened");
    if (id == "bluetooth-connect") {
        if (!std::regex_match(arg, std::regex("[[:xdigit:]]{2}(?::[[:xdigit:]]{2}){5}"))) return result(false, "Invalid Bluetooth address");
        Json devices; std::string info;
        if (!bluetooth_rows(devices) || !member_argument(devices, arg) || !sh::capture({"bluetoothctl", "info", arg}, info)) return result(false, "Bluetooth device is unavailable");
        if (info.find("Paired: yes") == std::string::npos) return terminal({"bluetoothctl", "--agent", "KeyboardDisplay", "pair", arg}, "Bluetooth pairing prompt opened");
        return command({"bluetoothctl", "--timeout", "10", info.find("Connected: yes") != std::string::npos ? "disconnect" : "connect", arg}, "Bluetooth connection updated");
    }
    if (id == "clipboard-restore") return restore_clipboard(arg);
    if (id == "wallpaper-set") {
        bool found = false; for (const auto& path : wallpapers()) if (path.string() == arg) found = true;
        if (!found) return result(false, "Wallpaper is not in the wallpaper folder");
        return command({"fox-wallpaper", "--set", arg}, "Wallpaper selected");
    }
    if (id == "wallpaper-next") return command({script("rotate_wallpaper.sh").string(), "--cycle"}, "Wallpaper changed");
    if (id == "wallpaper-sync") {
        fs::path wallpaper; std::error_code ec;
        const auto current = fs::path(home()) / ".wallpapers/.current";
        if (fs::is_symlink(current, ec)) {
            auto target = fs::read_symlink(current, ec);
            if (!ec) wallpaper = target.is_absolute() ? target : current.parent_path() / target;
        }
        if (!regular(wallpaper)) {
            std::string query;
            if (sh::capture({"awww", "query"}, query)) for (const auto& line : lines(query)) {
                const auto at = line.find("image:");
                if (at != std::string::npos && regular(trim(line.substr(at + 6)))) { wallpaper = trim(line.substr(at + 6)); break; }
            }
        }
        if (!regular(wallpaper)) return result(false, "Current wallpaper is unavailable");
        if (!regular(script("generate_palette.sh"))) return result(false, "Palette generator is unavailable");
        return terminal({"bash", script("generate_palette.sh").string(), wallpaper.string()}, "Wallpaper theme generation opened");
    }
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
        return launch({"env", "FOXML_MENU_LEGACY=1", "bash", updater.string(), id == "updates-terminal" ? "--apply-terminal" : "--apply-silent"}, "Updater opened");
    }
    if (id == "agent-triage") {
        if (!regular(script("agent_rofi.sh"))) return result(false, "Agent triage helper is unavailable");
        return launch({"env", "FOXML_MENU_LEGACY=1", "bash", script("agent_rofi.sh").string()}, "Agent triage opened");
    }
    if (id == "color-picker") return launch({"hyprpicker", "-a"}, "Color picker opened");
    if (id == "vault") return launch({"rofi-pass"}, "Password vault opened");
    if (id == "security") return terminal({"fox", "sec", "--live"}, "Security dashboard opened");
    if (id == "cleanup") return terminal({"zsh", "-ic", "fox-clean"}, "System cleanup opened");
    if (id == "lock") return launch({script("lock.sh").string()}, "Screen lock opened");
    return result(false, "Action is unavailable");
}
} // namespace

int main(int argc, char** argv) {
    try {
        fs::path config_path = config_home() / "quickshell/foxml/menus.json";
        Args args;
        for (int i = 1; i < argc; ++i) {
            if (std::string(argv[i]) == "--config" && i + 1 < argc) config_path = argv[++i];
            else args.emplace_back(argv[i]);
        }
        if (args.size() == 1 && (args[0] == "--help" || args[0] == "help")) {
            std::cout << "fox-drawer [--config PATH] view PAGE [QUERY]\nfox-drawer [--config PATH] run ACTION [ARGUMENT]\n"; return 0;
        }
        if (args.size() < 2 || args.size() > 4 || (args[0] != "view" && args[0] != "run")
            || (args.size() == 4 && (args[0] != "run" || args[1] != "drive-eject" || args[3] != "--confirm"))) {
            std::cout << result(false, "Use view PAGE [QUERY] or run ACTION [ARGUMENT]").dump() << '\n'; return 1;
        }
        Json config; std::string error;
        if (!read_config(config_path, config, error)) {
            Json failure = result(false, error);
            if (args[0] == "view") { failure["error"] = error; failure["id"] = args[1]; failure["title"] = "Unavailable"; failure["items"] = Json::array(); }
            std::cout << failure.dump() << '\n'; return 1;
        }
        const auto argument = args.size() >= 3 ? args[2] : "";
        if (!safe_text(argument)) { std::cout << result(false, "Invalid argument").dump() << '\n'; return 1; }
        const Json response = args[0] == "view" ? view(config, args[1], argument) : run_action(config, args[1], argument, args.size() == 4);
        std::cout << response.dump(-1, ' ', false, Json::error_handler_t::replace) << '\n';
        return truth(response, "ok") ? 0 : 1;
    } catch (const std::exception&) {
        std::cout << result(false, "Could not read drawer data").dump() << '\n'; return 1;
    }
}
