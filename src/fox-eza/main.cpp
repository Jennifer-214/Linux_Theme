// Cosmetic per-name icons, without parsing eza's output or following directory links.
#include "../fox-common/json.hpp"
#include "../fox-common/shell.hpp"
#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <string>
#include <system_error>
#include <vector>
#include <unistd.h>

namespace fs = std::filesystem;
using json = nlohmann::json;
namespace sh = fox_install::sh;

struct Listing {
    std::vector<fs::path> paths;
    int depth = 1;
    bool recurse = false, hidden = false, self = false, supported = true;
};

int number(const std::string& s) {
    if (s.empty() || s.size() > 5) return -1;
    int n = 0;
    for (char c : s) { if (c < '0' || c > '9') return -1; n = n * 10 + c - '0'; }
    return n;
}

Listing listing(const std::vector<std::string>& args) {
    Listing out;
    bool operands = false, level = false;
    const std::set<std::string> values = {"-L", "--level", "-w", "--width", "-s", "--sort", "-t", "--time", "--time-style", "-I", "--ignore-glob", "--color-scale-mode"};
    const std::set<std::string> switches = {"--all", "--almost-all", "--long", "--grid", "--oneline", "--tree", "--recurse", "--group-directories-first", "--group-directories-last", "--git", "--git-ignore", "--no-git", "--header", "--icons", "--color", "--colour", "--hyperlink", "--classify", "--no-quotes", "--only-dirs", "--only-files", "--show-symlinks", "--no-symlinks", "--no-user", "--no-time", "--no-permissions", "--no-filesize", "--smart-group", "--reverse", "--binary", "--bytes", "--treat-dirs-as-files"};
    for (size_t i = 1; i < args.size(); ++i) {
        const auto& arg = args[i];
        if (operands || arg.empty() || arg[0] != '-' || arg == "-") { out.paths.emplace_back(arg); continue; }
        if (arg == "--") { operands = true; continue; }
        const auto equal = arg.find('=');
        const auto key = arg.substr(0, equal);
        std::string value;
        if (values.count(key)) {
            if (equal != std::string::npos) value = arg.substr(equal + 1);
            else if (++i < args.size()) value = args[i];
            else { out.supported = false; break; }
            if (key == "--level" || key == "-L") { out.depth = number(value); level = true; if (out.depth < 0) out.supported = false; }
            continue;
        }
        if (arg.size() > 2 && arg[0] == '-' && arg[1] == 'L') { out.depth = number(arg.substr(2)); level = true; if (out.depth < 0) out.supported = false; continue; }
        if (arg.rfind("--", 0) == 0) {
            if (!switches.count(key)) { out.supported = false; break; }
            if (key == "--tree" || key == "--recurse") out.recurse = true;
            if (key == "--all" || key == "--almost-all") out.hidden = true;
            if (key == "--treat-dirs-as-files") out.self = true;
        } else {
            for (char c : arg.substr(1)) {
                if (std::string("1lGhTabARrxdafFobBgHimnOuUSXZ@DM").find(c) == std::string::npos) out.supported = false;
                if (c == 'T' || c == 'R') out.recurse = true;
                if (c == 'a' || c == 'A') out.hidden = true;
                if (c == 'd') out.self = true;
            }
        }
    }
    if (out.recurse && !level) out.depth = 64;
    if (!out.recurse) out.depth = 1;
    if (out.paths.empty()) out.paths.emplace_back(".");
    return out;
}

struct Name { unsigned kinds = 0; };
using Names = std::map<std::string, Name>;

void remember(const fs::path& path, Names& names) {
    std::error_code ec;
    const auto status = fs::symlink_status(path, ec);
    if (ec) return;
    const auto name = path.filename().string();
    // Invalid UTF-8 filenames remain eza's responsibility; never rewrite their bytes.
    if (json(name).dump(-1, ' ', false, json::error_handler_t::replace).find("\xef\xbf\xbd") != std::string::npos) return;
    names[name].kinds |= fs::is_symlink(status) ? 1u : fs::is_directory(status) ? 4u : 2u;
}

void scan(const fs::path& path, int depth, bool hidden, Names& names, size_t& budget) {
    if (depth <= 0 || budget == 0) return;
    std::error_code ec;
    fs::directory_iterator it(path, fs::directory_options::skip_permission_denied, ec), end;
    while (!ec && it != end && budget > 0) {
        --budget;
        const auto entry = it->path();
        const auto name = entry.filename().string();
        if (hidden || name.empty() || name.front() != '.') {
            remember(entry, names);
            const auto status = it->symlink_status(ec);
            if (!ec && fs::is_directory(status)) scan(entry, depth - 1, hidden, names, budget);
        }
        it.increment(ec);
    }
}

int main(int argc, char** argv) {
    std::vector<std::string> args{"eza"};
    for (int i = 1; i < argc; ++i) args.emplace_back(argv[i]);
    const char* home = std::getenv("HOME");
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    const char* custom = std::getenv("EZA_CONFIG_DIR");
    const fs::path dir = custom && *custom ? fs::path(custom) : xdg && *xdg ? fs::path(xdg) / "eza" : home ? fs::path(home) / ".config/eza" : fs::path();
    const auto view = listing(args);
    std::ifstream input(dir / "theme.yml");
    auto theme = json::parse(input, nullptr, false);
    if (!view.supported || !theme.is_object() || !theme.contains("_foxml") || !theme["_foxml"].is_object()) return sh::run(args);
    const auto meta = theme["_foxml"];
    if (!meta.contains("enabled") || !meta["enabled"].is_string() || meta["enabled"] != "fox-little-details-on" || !meta.contains("icon") || !meta["icon"].is_object() || !meta.contains("symlink") || !meta["symlink"].is_object()) return sh::run(args);
    if (theme.contains("filenames") && !theme["filenames"].is_object()) return sh::run(args);
    Names names;
    size_t budget = 8192;
    for (const auto& path : view.paths) {
        remember(path, names);
        std::error_code ec;
        if (!view.self && fs::is_directory(path, ec)) scan(path, std::min(view.depth, 64), view.hidden, names, budget);
    }
    if (budget == 0) return sh::run(args);
    for (const auto& [name, info] : names) {
        if ((info.kinds & (info.kinds - 1)) != 0) continue;
        auto& style = theme["filenames"][name];
        if (!style.is_null() && !style.is_object()) continue;
        // Mixed names across directories retain their existing glyph: a real file
        // must never gain a link badge because a different directory has a namesake.
        if (style.is_object() && style.contains("icon")) continue;
        auto icon = meta[info.kinds == 1 ? "symlink" : "icon"];
        if (info.kinds == 4 && meta.contains("directory") && meta["directory"].is_object()) {
            icon = meta["directory"];
            if (meta.contains("directories") && meta["directories"].is_object()
                && meta["directories"].contains(name) && meta["directories"][name].is_object())
                icon = meta["directories"][name];
        }
        auto extension = fs::path(name).extension().string();
        if (!extension.empty()) extension.erase(0, 1);
        if (info.kinds == 2 && theme.contains("extensions") && theme["extensions"].is_object()) {
            const auto& extensions = theme["extensions"];
            if (extensions.contains(extension) && extensions[extension].is_object()) {
                const auto& entry = extensions[extension];
                if (entry.contains("icon") && entry["icon"].is_object()) {
                    icon = entry["icon"];
                }
            }
        }
        style["icon"] = icon;
    }
    theme.erase("_foxml");
    const char* temp = std::getenv("TMPDIR");
    std::string pattern = (fs::path(temp && *temp ? temp : "/tmp") / "foxml-eza-XXXXXX").string();
    std::vector<char> buffer(pattern.begin(), pattern.end()); buffer.push_back('\0');
    char* created = ::mkdtemp(buffer.data());
    if (!created) return sh::run(args);
    const fs::path stage(created);
    const auto file = stage / "theme.yml";
    std::ofstream output(stage / "theme.tmp");
    output << theme.dump(-1, ' ', false, json::error_handler_t::replace); output.close();
    std::error_code ec;
    fs::rename(stage / "theme.tmp", file, ec);
    int result;
    if (output.fail() || ec) result = sh::run(args);
    else { ::setenv("EZA_CONFIG_DIR", stage.c_str(), 1); result = sh::run(args); }
    fs::remove_all(stage, ec);
    return result;
}
