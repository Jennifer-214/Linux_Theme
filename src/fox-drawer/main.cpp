#include "json.hpp"
#include "shell.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <charconv>
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
    "wallpapers", "themes", "power", "updates", "agents"
};
const std::set<std::string> actions = {
    "volume", "volume-mute", "mic-mute", "media-play-pause", "media-next", "media-previous", "brightness",
    "nightlight", "dnd", "idle", "power-profile", "lock", "suspend", "reboot", "poweroff", "logout",
    "wallpaper-next", "wallpaper-sync", "color-picker", "updates-terminal", "updates-silent", "vault",
    "security", "cleanup", "agent-triage", "app-launch", "window-focus", "audio-output", "wifi-connect",
    "wifi-toggle", "bluetooth-connect", "bluetooth-toggle", "bluetooth-scan", "clipboard-restore", "wallpaper-set", "theme-set"
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
Json view(const Json& config, const std::string& page, const std::string& query) {
    Json out{{"id", page}, {"title", page}, {"items", Json::array()}, {"ok", true}, {"group", group_for(config, page)}};
    auto& rows = out["items"];
    auto fail = [&](const std::string& message) { out["ok"] = false; out["error"] = message; };
    bool known = false;
    if (page == "root") {
        known = true; out["title"] = "FoxML";
        for (const auto& group : config["groups"]) {
            auto row = item(text(group, "id"), text(group, "label"), "page", text(group, "description"), text(group, "icon"));
            row["page"] = text(group, "id"); rows.push_back(row);
        }
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
    if (page == "apps") {
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

Json run_action(const std::string& id, const std::string& arg) {
    if (!actions.count(id)) return result(false, "Unknown drawer action");
    if (!safe_text(arg)) return result(false, "Invalid action argument");
    const bool power = id == "suspend" || id == "reboot" || id == "poweroff" || id == "logout";
    if (power) {
        if (arg != "--confirm") return result(false, "Confirmation required");
        if (id == "logout") return command({"fox-hl", "dispatch", "hl.dsp.exit()", "exit"}, "Log out", true);
        return command({"systemctl", id}, id == "suspend" ? "Suspend" : id == "reboot" ? "Restart" : "Shut down", true);
    }
    const std::set<std::string> argument_actions{"volume","brightness","power-profile","app-launch","window-focus","audio-output","wifi-connect","bluetooth-connect","clipboard-restore","wallpaper-set","theme-set"};
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
        if (args.size() < 2 || args.size() > 3 || (args[0] != "view" && args[0] != "run")) {
            std::cout << result(false, "Use view PAGE [QUERY] or run ACTION [ARGUMENT]").dump() << '\n'; return 1;
        }
        Json config; std::string error;
        if (!read_config(config_path, config, error)) {
            Json failure = result(false, error);
            if (args[0] == "view") { failure["error"] = error; failure["id"] = args[1]; failure["title"] = "Unavailable"; failure["items"] = Json::array(); }
            std::cout << failure.dump() << '\n'; return 1;
        }
        const auto argument = args.size() == 3 ? args[2] : "";
        if (!safe_text(argument)) { std::cout << result(false, "Invalid argument").dump() << '\n'; return 1; }
        const Json response = args[0] == "view" ? view(config, args[1], argument) : run_action(args[1], argument);
        std::cout << response.dump(-1, ' ', false, Json::error_handler_t::replace) << '\n';
        return truth(response, "ok") ? 0 : 1;
    } catch (const std::exception&) {
        std::cout << result(false, "Could not read drawer data").dump() << '\n'; return 1;
    }
}
