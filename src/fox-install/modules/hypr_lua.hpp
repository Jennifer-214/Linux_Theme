#ifndef FOX_INSTALL_MODULES_HYPR_LUA_HPP
#define FOX_INSTALL_MODULES_HYPR_LUA_HPP
// Hyprland 0.57 reads only hyprland.lua; 0.56 and older read hyprland.conf.
// Pure helpers the installer uses to ship both: which format the installed
// Hyprland needs, Lua twins of the files the installer generates (monitors,
// nvidia), and when greetd's config.toml may be pointed at the launcher.
// Header-only so tests/test_hypr_lua.cpp links nothing.

#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <system_error>
#include <vector>

namespace fox_install::hypr_lua {

struct Version {
    int major = -1, minor = -1, patch = -1;
    bool known() const { return major >= 0; }
};

// `Hyprland --version` prints "Hyprland 0.57.0 built from branch ...".
inline Version parse_version(const std::string& out) {
    static const std::regex pat(R"(Hyprland\s+(\d+)\.(\d+)\.(\d+))");
    std::smatch m;
    if (!std::regex_search(out, m, pat)) return {};
    return {std::stoi(m[1]), std::stoi(m[2]), std::stoi(m[3])};
}

// Unknown counts as Lua: every Hyprland Arch ships from 0.57 on needs it, and a
// box without Hyprland yet gets the current release from the deps step.
inline bool reads_lua_only(const Version& v) {
    return !v.known() || v.major > 0 || v.minor >= 57;
}

inline std::string trim(const std::string& s) {
    const auto b = s.find_first_not_of(" \t\r");
    if (b == std::string::npos) return {};
    return s.substr(b, s.find_last_not_of(" \t\r") - b + 1);
}

inline std::string lua_str(const std::string& s) {
    std::string out = "\"";
    for (char c : s) {
        if (c == '\\' || c == '"') out += '\\';
        out += c;
    }
    return out + "\"";
}

// One `monitor = NAME, MODE, POS, SCALE[, transform, N]` / `monitor = NAME, disable`
// line → hl.monitor({...}). Empty string when the line is something else.
inline std::string monitor_line_to_lua(const std::string& line) {
    static const std::regex pat(R"(^\s*monitor\s*=\s*(.*)$)");
    std::smatch m;
    if (!std::regex_match(line, m, pat)) return {};
    std::vector<std::string> f;
    std::stringstream ss(m[1].str());
    for (std::string part; std::getline(ss, part, ',');) f.push_back(trim(part));
    if (f.size() == 2 && f[1] == "disable")
        return "hl.monitor({ output = " + lua_str(f[0]) + ", disabled = true })";
    if (f.size() != 4 && !(f.size() == 6 && f[4] == "transform")) return {};
    static const std::regex num(R"(^-?\d+(\.\d+)?$)");
    const std::string scale = std::regex_match(f[3], num) ? f[3] : lua_str(f[3]);
    std::string out = "hl.monitor({ output = " + lua_str(f[0]) + ", mode = " + lua_str(f[1]) +
                      ", position = " + lua_str(f[2]) + ", scale = " + scale;
    if (f.size() == 6) out += ", transform = " + f[5];
    return out + " })";
}

// One `env = NAME, VALUE` line (optionally commented out) → hl.env(...). The
// installer only writes literal values here, so no $VAR expansion is needed.
inline std::string env_line_to_lua(const std::string& line) {
    static const std::regex pat(R"(^(\s*)(#\s*)?env\s*=\s*([^,]+?)\s*,\s*(.*?)\s*$)");
    std::smatch m;
    if (!std::regex_match(line, m, pat)) return {};
    return m[1].str() + (m[2].matched ? "-- " : "") + "hl.env(" + lua_str(m[3]) + ", " +
           lua_str(m[4]) + ")";
}

// Lua twin of a file the installer generates in hyprlang: monitors.conf (from
// --monitors) or nvidia.conf (from --nvidia). Comments and blank lines carry
// over; anything unexpected is kept as a comment rather than dropped.
inline std::string generated_conf_to_lua(const std::string& conf) {
    std::ostringstream out;
    std::stringstream in(conf);
    for (std::string line; std::getline(in, line);) {
        std::string lua = monitor_line_to_lua(line);
        if (lua.empty()) lua = env_line_to_lua(line);
        if (!lua.empty()) { out << lua << "\n"; continue; }
        const std::string t = trim(line);
        if (t.empty())          out << "\n";
        else if (t[0] == '#')   out << line.substr(0, line.find('#')) << "--" << line.substr(line.find('#') + 1) << "\n";
        else                    out << "-- (not converted) " << t << "\n";
    }
    return out.str();
}

// rules.lua's workspace-1 pin, between the foxml:workspace-pin sentinels.
inline constexpr const char* PIN_BEGIN = "-- foxml:workspace-pin-begin";
inline constexpr const char* PIN_END   = "-- foxml:workspace-pin-end";
inline std::string workspace_pin_lua(const std::string& primary) {
    return "hl.workspace_rule({ workspace = \"1\", monitor = " + lua_str(primary) +
           ", default = true })";
}

inline const char* nvidia_lua_placeholder() {
    return "-- nvidia.lua: no NVIDIA setup on this machine. hyprland.lua loads this module everywhere,\n"
           "-- and a comment-only one keeps Hyprland's config check clean. --nvidia replaces it.\n";
}

// ─── greetd ───────────────────────────────────────────────────────────
// The launcher picks hyprland.lua or hyprland.conf from `Hyprland --version` at
// every boot, so a later upgrade or downgrade can't strand the login screen.
inline constexpr const char* GREETER_LAUNCHER = "/etc/greetd/start-greeter.sh";

enum class GreeterToml { Write, Keep, AlreadyLauncher };

// What to do with an existing /etc/greetd/config.toml body. Stock agreety and
// the commands this installer wrote before (hyprland.conf, then hyprland.lua)
// are ours to replace; anything else is the user's and stays.
inline GreeterToml greeter_toml_action(const std::string& body, bool exists) {
    if (!exists) return GreeterToml::Write;
    static const std::regex cmd(R"re((^|\n)\s*command\s*=\s*"([^"]*)")re");
    std::smatch m;
    if (!std::regex_search(body, m, cmd)) return GreeterToml::Keep;
    const std::string c = trim(m[2]);
    if (c == GREETER_LAUNCHER) return GreeterToml::AlreadyLauncher;
    if (c.rfind("agreety", 0) == 0 ||
        c == "Hyprland -c /etc/greetd/hyprland.conf" ||
        c == "Hyprland -c /etc/greetd/hyprland.lua")
        return GreeterToml::Write;
    return GreeterToml::Keep;
}

inline bool verify_output_ok(const std::string& out) {
    return out.find("config ok") != std::string::npos;
}

// The login screen needs a compositor that accepted its config. A missing
// Hyprland fails too: enabling greetd then would boot to a blank screen.
inline bool greeter_config_ok(bool have_hyprland, const std::string& verify_output) {
    return have_hyprland && verify_output_ok(verify_output);
}

inline bool write_text_atomic(const std::filesystem::path& dest, const std::string& body) {
    namespace fs = std::filesystem;
    std::error_code ec;
    fs::create_directories(dest.parent_path(), ec);
    fs::path tmp = dest;
    tmp += ".foxin.tmp";
    {
        std::ofstream out(tmp);
        out << body;
        if (!out) return false;
    }
    fs::rename(tmp, dest, ec);
    if (ec) fs::remove(tmp, ec);
    return !ec;
}

inline std::string read_text(const std::filesystem::path& p) {
    std::ifstream f(p);
    std::ostringstream s;
    s << f.rdbuf();
    return s.str();
}

// Body for a missing Lua twin of a per-machine module: the converted .conf the
// box already has (a --monitors layout, a --nvidia setup), else `fallback`, so
// moving to 0.57 keeps the same monitors and GPU env. `empty_conf` is .conf
// content that means "nothing set up" (nvidia's comment-only placeholder).
inline std::string lua_twin_body(const std::filesystem::path& conf, const std::string& fallback,
                                 const std::string& empty_conf = {}) {
    if (!std::filesystem::exists(conf)) return fallback;
    const std::string text = read_text(conf);
    if (!empty_conf.empty() && text == empty_conf) return fallback;
    return generated_conf_to_lua(text);
}

}  // namespace fox_install::hypr_lua

#endif
