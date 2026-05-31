// fox-gen-keybinds — regenerate the marker-fenced keybind sections of
// KEYBINDS.md from the config files that define the binds.
//
// The configs are the single source of truth; this writes only between its
// own <!-- BEGIN/END GENERATED: <source> --> markers, so hand-curated
// sections (nvim) are never touched. Deterministic: no AI, no network.
//
// Phase 1: tmux only. Hyprland + kitty land in later phases.

#include "../fox-common/ui.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace ui = fox_install::ui;
namespace fs = std::filesystem;

namespace {

struct Bind {
    std::string prefix;      // "Ctrl+a " / "ALT + Shift + " / "" — modifier(s) + separator
    std::string base;        // normalized key ("h", "|", "Ctrl+Shift+a", "1")
    std::string suffix;      // " (copy mode)" for copy-mode-vi binds, "" otherwise
    std::string desc;        // empty => undocumented
    std::string subsection;  // ### group (hypr); empty for tmux (flat)
    bool allow_dup = false;  // intentional double-bind — suppress collision lint
    int line = 0;
    std::string display() const { return prefix + base + suffix; }
    std::string collide_key() const { return prefix + "\x1f" + base + "\x1f" + suffix; }
};

struct Collision {
    std::string display;
    int first_line, dup_line;
};

std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

bool starts_with(const std::string& s, const std::string& p) {
    return s.size() >= p.size() && s.compare(0, p.size(), p) == 0;
}

std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    return s;
}

std::vector<std::string> read_lines(const std::string& path, bool& ok) {
    std::vector<std::string> out;
    std::ifstream f(path);
    ok = static_cast<bool>(f);
    if (!ok) return out;
    std::string line;
    while (std::getline(f, line)) out.push_back(line);
    return out;
}

std::string read_file(const std::string& path, bool& ok) {
    std::ifstream f(path);
    ok = static_cast<bool>(f);
    if (!ok) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

bool write_file_atomic(const std::string& path, const std::string& content) {
    fs::path dst(path);
    fs::path tmp = dst;
    tmp += ".tmp";
    {
        std::ofstream f(tmp, std::ios::trunc);
        if (!f) return false;
        f << content;
        if (!f) return false;
    }
    std::error_code ec;
    fs::rename(tmp, dst, ec);
    return !ec;
}

// A comment "block" is one or more consecutive `#` lines. Section banners
// (=== / ─── decoration) are not descriptions — they reset context.
bool is_banner(const std::vector<std::string>& block) {
    for (const auto& l : block)
        if (l.find("===") != std::string::npos ||
            l.find("\xE2\x94\x80") != std::string::npos)  // ─ (U+2500)
            return true;
    return false;
}

// Description = first sentence of the joined comment block, with a leading
// "prefix + X —/=" stripped (the key is already shown) and trailing period removed.
std::string make_desc(const std::vector<std::string>& block) {
    std::string joined;
    for (const auto& l : block) {
        if (!joined.empty()) joined += ' ';
        joined += l;
    }
    joined = trim(joined);
    if (size_t dot = joined.find(". "); dot != std::string::npos)
        joined = joined.substr(0, dot + 1);
    if (starts_with(lower(joined), "prefix")) {
        size_t em = joined.find("\xE2\x80\x94");  // — (U+2014)
        size_t eq = joined.find('=');
        size_t sep = std::string::npos;
        size_t seplen = 1;
        if (em != std::string::npos) { sep = em; seplen = 3; }
        if (eq != std::string::npos && (sep == std::string::npos || eq < sep)) { sep = eq; seplen = 1; }
        if (sep != std::string::npos) joined = trim(joined.substr(sep + seplen));
    }
    joined = trim(joined);
    if (!joined.empty() && joined.back() == '.') joined.pop_back();
    return trim(joined);
}

// "C-S-a" -> "Ctrl+Shift+a", "C-a" -> "Ctrl+a", "|" -> "|", "Tab" -> "Tab".
std::string norm_key(const std::string& k) {
    if (k == "-" || k.find('-') == std::string::npos) return k;
    std::vector<std::string> parts;
    std::string cur;
    for (char c : k) {
        if (c == '-') { parts.push_back(cur); cur.clear(); }
        else cur += c;
    }
    parts.push_back(cur);
    std::string out;
    for (size_t i = 0; i < parts.size(); ++i) {
        if (i + 1 < parts.size()) {
            std::string m = parts[i];
            if (m == "C") m = "Ctrl";
            else if (m == "M") m = "Alt";
            else if (m == "S") m = "Shift";
            out += m + "+";
        } else {
            out += parts[i];
        }
    }
    return out;
}

bool parse_bind(const std::string& t, const std::string& prefix_disp, int line,
                const std::string& pending_desc, Bind& out) {
    std::istringstream is(t);
    std::string tok;
    is >> tok;  // "bind" / "bind-key"
    std::string table;
    bool root = false, key_found = false;
    std::string key;
    while (is >> tok) {
        if (tok == "-r") continue;
        if (tok == "-n") { root = true; continue; }
        if (tok == "-T") { is >> table; continue; }
        key = tok;
        key_found = true;
        break;
    }
    if (!key_found || key.find("Mouse") != std::string::npos) return false;
    out = Bind{};
    out.base = norm_key(key);
    out.line = line;
    out.desc = pending_desc;
    if (starts_with(table, "copy-mode")) { out.suffix = " (copy mode)"; }
    else if (root) { /* root table: bare key */ }
    else { out.prefix = prefix_disp + " "; }
    return true;
}

bool is_bind_line(const std::string& t) {
    return starts_with(t, "bind ") || starts_with(t, "bind\t") ||
           starts_with(t, "bind-key ") || starts_with(t, "bind-key\t");
}

struct ParseResult {
    std::vector<Bind> binds;
    std::vector<Collision> collisions;
    std::string prefix_disp = "Ctrl+a";
};

ParseResult parse_tmux(const std::vector<std::string>& lines) {
    ParseResult r;
    // First pass: resolve the prefix key (set -g prefix C-a).
    for (const auto& raw : lines) {
        std::string t = trim(raw);
        if (starts_with(t, "set -g prefix ") || starts_with(t, "set-option -g prefix ")) {
            std::istringstream is(t);
            std::string a, b, c, key;
            is >> a >> b >> c >> key;
            if (!key.empty()) r.prefix_disp = norm_key(key);
        }
    }

    std::vector<std::string> block;
    std::string pending_desc;
    int lineno = 0;
    for (const auto& raw : lines) {
        ++lineno;
        std::string t = trim(raw);
        if (starts_with(t, "#")) {
            block.push_back(trim(t.substr(1)));
            continue;
        }
        if (t.empty()) { block.clear(); pending_desc.clear(); continue; }
        // non-comment, non-blank: flush any adjacent comment block
        if (!block.empty()) {
            pending_desc = is_banner(block) ? std::string{} : make_desc(block);
            block.clear();
        }
        if (is_bind_line(t)) {
            Bind b;
            if (parse_bind(t, r.prefix_disp, lineno, pending_desc, b))
                r.binds.push_back(b);
            // carry pending_desc to the next consecutive bind
        } else {
            pending_desc.clear();  // a setting line breaks comment→bind adjacency
        }
    }

    // Collisions: same display key bound twice.
    std::vector<std::pair<std::string, int>> seen;
    for (const auto& b : r.binds) {
        auto it = std::find_if(seen.begin(), seen.end(),
                               [&](auto& p) { return p.first == b.collide_key(); });
        if (it != seen.end())
            r.collisions.push_back({b.display(), it->second, b.line});
        else
            seen.push_back({b.collide_key(), b.line});
    }
    return r;
}

// Collapse consecutive binds sharing prefix+suffix+desc+subsection into one
// a/b/c row.
std::vector<Bind> collapse(const std::vector<Bind>& in) {
    std::vector<Bind> out;
    for (const auto& b : in) {
        if (!out.empty() && !b.desc.empty() && out.back().desc == b.desc &&
            out.back().prefix == b.prefix && out.back().suffix == b.suffix &&
            out.back().subsection == b.subsection) {
            out.back().base += "/" + b.base;
        } else {
            out.push_back(b);
        }
    }
    return out;
}

const char* UNDOC = "\xE2\x9A\xA0 undocumented (add a comment above the bind)";

// Escape `|` so it survives a markdown table cell (matches the prior doc).
std::string md_escape(const std::string& s) {
    std::string o;
    for (char c : s) { if (c == '|') o += "\\|"; else o += c; }
    return o;
}

std::string cap_first(std::string s) {
    if (!s.empty() && std::islower((unsigned char)s[0]))
        s[0] = (char)std::toupper((unsigned char)s[0]);
    return s;
}

std::string emit_tmux(const ParseResult& r) {
    std::ostringstream o;
    o << "\n## Tmux (" << r.prefix_disp << " prefix)\n\n";
    o << "| Key | Action |\n|-----|--------|\n";
    for (const auto& b : collapse(r.binds)) {
        std::string key = md_escape(b.prefix + b.base + b.suffix);
        std::string desc = md_escape(b.desc.empty() ? std::string(UNDOC) : cap_first(b.desc));
        o << "| `" << key << "` | " << desc << " |\n";
    }
    o << "\n";
    return o.str();
}

// Replace the content between <!-- BEGIN GENERATED: tag --> and
// <!-- END GENERATED: tag --> with `block`, preserving the markers and
// everything outside them byte-for-byte. Operates on (and returns) the whole
// file content so calls chain: splice(c,"tmux",...) then splice(c,"hypr",...).
// Returns false if the markers are missing.
bool splice(const std::string& content, const std::string& tag,
            const std::string& block, std::string& out) {
    std::vector<std::string> lines;
    { std::string cur;
      for (char c : content) { if (c == '\n') { lines.push_back(cur); cur.clear(); } else cur += c; }
      lines.push_back(cur); }
    std::string begin_needle = "BEGIN GENERATED: " + tag;
    std::string end_needle = "END GENERATED: " + tag;
    int begin = -1, end = -1;
    for (int i = 0; i < (int)lines.size(); ++i) {
        if (begin < 0 && lines[i].find(begin_needle) != std::string::npos) begin = i;
        else if (begin >= 0 && lines[i].find(end_needle) != std::string::npos) { end = i; break; }
    }
    if (begin < 0 || end < 0) return false;
    std::ostringstream o;
    for (int i = 0; i <= begin; ++i) o << lines[i] << "\n";
    o << block;
    for (int i = end; i < (int)lines.size(); ++i) {
        o << lines[i];
        if (i + 1 < (int)lines.size()) o << "\n";
    }
    out = o.str();
    return true;
}

// ───────────────────────── Hyprland ─────────────────────────

// Split on the first (maxfields-1) delimiters; the final field is the rest.
std::vector<std::string> split_n(const std::string& s, char d, int maxfields) {
    std::vector<std::string> out;
    std::string cur;
    for (char c : s) {
        if (c == d && (int)out.size() < maxfields - 1) { out.push_back(trim(cur)); cur.clear(); }
        else cur += c;
    }
    out.push_back(trim(cur));
    return out;
}

// A comment line that is only ─ / = / - / space decoration (banner rule).
bool is_decoration(const std::string& s) {
    if (trim(s).empty()) return false;
    std::string t = s;
    size_t pos;
    while ((pos = t.find("\xE2\x94\x80")) != std::string::npos) t.erase(pos, 3);  // ─
    for (unsigned char c : t)
        if (c != '=' && c != '-' && c != ' ' && c != '\t') return false;
    return true;
}

std::string hypr_mod(const std::string& m) {
    if (m == "ALT") return "ALT";
    if (m == "SHIFT") return "Shift";
    if (m == "CTRL" || m == "CONTROL") return "Ctrl";
    if (m == "SUPER") return "Super";
    return m;
}

std::string hypr_key(const std::string& k) {
    static const std::map<std::string, std::string> m = {
        {"RETURN", "Enter"}, {"return", "Enter"}, {"escape", "Esc"}, {"Escape", "Esc"},
        {"comma", ","}, {"period", "."}, {"slash", "/"}, {"grave", "Grave"},
        {"bracketleft", "["}, {"bracketright", "]"},
        {"XF86AudioRaiseVolume", "Vol +"}, {"XF86AudioLowerVolume", "Vol \xE2\x88\x92"},
        {"XF86AudioMute", "Mute"}, {"XF86MonBrightnessUp", "Bright +"},
        {"XF86MonBrightnessDown", "Bright \xE2\x88\x92"}, {"XF86AudioPlay", "Play"},
        {"XF86AudioNext", "Next"}, {"XF86AudioPrev", "Prev"}, {"XF86AudioStop", "Stop"},
    };
    auto it = m.find(k);
    return it != m.end() ? it->second : k;
}

// Description for a bind with no comment, derived from its dispatcher/key.
// Returns "" when nothing sensible can be inferred (e.g. exec a script).
std::string derive(const std::string& dispatcher, const std::string& arg,
                   const std::string& raw_key) {
    static const std::map<std::string, std::string> media = {
        {"XF86AudioRaiseVolume", "Raise output volume"},
        {"XF86AudioLowerVolume", "Lower output volume"},
        {"XF86AudioMute", "Toggle mute"},
        {"XF86MonBrightnessUp", "Raise screen brightness"},
        {"XF86MonBrightnessDown", "Lower screen brightness"},
        {"XF86AudioPlay", "Play / pause"}, {"XF86AudioNext", "Next track"},
        {"XF86AudioPrev", "Previous track"}, {"XF86AudioStop", "Stop playback"},
    };
    if (auto it = media.find(raw_key); it != media.end()) return it->second;

    if (dispatcher == "workspace") {
        if (arg == "e-1") return "Previous workspace";
        if (arg == "e+1") return "Next workspace";
        return "Switch to workspace";  // numeric — key column shows which
    }
    if (dispatcher == "movetoworkspace") return "Move window to workspace";
    if (dispatcher == "movefocus") {
        if (arg == "l") return "Move focus left";
        if (arg == "r") return "Move focus right";
        if (arg == "u") return "Move focus up";
        if (arg == "d") return "Move focus down";
        return "Move focus";
    }
    if (dispatcher == "killactive") return "Close the active window";
    if (dispatcher == "togglefloating") return "Toggle floating";
    if (dispatcher == "centerwindow") return "Center the floating window";
    if (dispatcher == "togglegroup") return "Toggle window group";
    if (dispatcher == "changegroupactive")
        return arg == "b" ? "Previous window in group" : "Next window in group";
    if (dispatcher == "pin") return "Pin window above all workspaces";
    if (dispatcher == "layoutmsg")
        return arg == "togglesplit" ? "Toggle split direction" : "Layout: " + arg;
    if (dispatcher == "cyclenext") {
        if (arg == "prev") return "Cycle to previous window";
        if (arg == "floating") return "Cycle floating windows";
        if (arg == "tiled") return "Cycle tiled windows";
        return "Cycle to next window";
    }
    if (dispatcher == "fullscreen") return "Toggle fullscreen";
    if (dispatcher == "resizeactive") return "Resize the focused window";
    if (dispatcher == "moveactive") return "Move the focused window";
    if (dispatcher == "submap") return arg == "reset" ? "Exit this mode" : "";
    return "";  // exec / unknown — needs a comment
}

// Render a collapsed key list as a range when it's a clean run:
// "1/2/3/4/5/6/7/8/9" -> "1–9", "F1/F2/F3/F4/F5/F6" -> "F1–F6".
std::string compact_keys(const std::string& base) {
    std::vector<std::string> parts = split_n(base, '/', 1000);
    if (parts.size() < 3) return base;
    std::string pfx;
    int prev = 0;
    bool first = true, consec = true;
    for (auto& p : parts) {
        size_t i = 0;
        while (i < p.size() && !std::isdigit((unsigned char)p[i])) ++i;
        std::string a = p.substr(0, i), num = p.substr(i);
        if (num.empty()) { consec = false; break; }
        int n = std::stoi(num);
        if (first) { pfx = a; first = false; }
        else if (a != pfx || n != prev + 1) { consec = false; break; }
        prev = n;
    }
    if (consec) return parts.front() + "\xE2\x80\x93" + parts.back();  // –
    return base;
}

void process_hypr_block(const std::vector<std::string>& block,
                        std::string& subsection, std::string& pending_desc) {
    bool has_deco = false;
    std::vector<std::string> nondeco;
    for (const auto& l : block) {
        if (is_decoration(l)) has_deco = true;
        else nondeco.push_back(l);
    }
    if (has_deco) {
        if (!nondeco.empty()) {
            subsection = nondeco.front();
            std::vector<std::string> prose(nondeco.begin() + 1, nondeco.end());
            pending_desc = prose.empty() ? std::string{} : make_desc(prose);
        }
    } else {
        pending_desc = make_desc(block);
    }
}

ParseResult parse_hypr(const std::vector<std::string>& lines) {
    ParseResult r;
    std::string mainmod = "ALT";
    for (const auto& raw : lines) {
        std::string t = trim(raw);
        if (starts_with(t, "$mainMod")) {
            auto eq = t.find('=');
            if (eq != std::string::npos) mainmod = trim(t.substr(eq + 1));
        }
    }

    std::vector<std::string> block;
    std::string subsection, pending_desc;
    bool pending_allow_dup = false;
    int lineno = 0;
    for (const auto& raw : lines) {
        ++lineno;
        std::string t = trim(raw);
        if (starts_with(t, "#")) {
            std::string c = trim(t.substr(1));
            if (c == "gen-keybinds: allow-dup") { pending_allow_dup = true; continue; }
            block.push_back(c);
            continue;
        }
        bool just_flushed = false;
        if (!block.empty()) {
            process_hypr_block(block, subsection, pending_desc);
            block.clear();
            just_flushed = true;  // pending_desc came from a comment right above this line
        }
        if (t.empty()) { pending_desc.clear(); pending_allow_dup = false; continue; }

        if (!starts_with(t, "bind")) { pending_desc.clear(); pending_allow_dup = false; continue; }

        auto eq = t.find('=');
        if (eq == std::string::npos) { pending_desc.clear(); continue; }
        std::string variant = trim(t.substr(0, eq));
        auto f = split_n(t.substr(eq + 1), ',', 5);
        if (f.size() < 2) { pending_desc.clear(); continue; }

        std::string mods = f[0], key = f[1], inline_desc, dispatcher, arg;
        if (variant == "bindd" && f.size() >= 4) {
            inline_desc = f[2]; dispatcher = f[3]; arg = f.size() > 4 ? f[4] : "";
        } else {
            dispatcher = f.size() > 2 ? f[2] : ""; arg = f.size() > 3 ? f[3] : "";
        }
        if (key.find("mouse") != std::string::npos) continue;  // skip mouse binds

        std::string mod_disp;
        for (auto& tok : split_n(mods, ' ', 1000)) {
            if (tok.empty()) continue;
            std::string resolved = (tok == "$mainMod") ? mainmod : tok;
            mod_disp += hypr_mod(resolved) + " + ";
        }

        Bind b;
        b.prefix = mod_disp;
        b.base = hypr_key(key);
        b.line = lineno;
        b.subsection = subsection;
        b.allow_dup = pending_allow_dup;
        pending_allow_dup = false;
        // Priority: bindd inline desc > comment directly above this bind >
        // dispatcher-derived default > a comment carried from an earlier bind
        // (the carried case only catches binds derive can't describe, e.g. the
        // chvt run sharing one section comment).
        std::string derived = derive(dispatcher, arg, key);
        if (!inline_desc.empty()) b.desc = inline_desc;
        else if (just_flushed && !pending_desc.empty()) b.desc = pending_desc;
        else if (!derived.empty()) b.desc = derived;
        else b.desc = pending_desc;
        r.binds.push_back(b);
    }

    std::vector<std::pair<std::string, int>> seen;
    for (const auto& b : r.binds) {
        auto it = std::find_if(seen.begin(), seen.end(),
                               [&](auto& p) { return p.first == b.collide_key(); });
        if (it != seen.end()) { if (!b.allow_dup) r.collisions.push_back({b.display(), it->second, b.line}); }
        else seen.push_back({b.collide_key(), b.line});
    }
    return r;
}

std::string emit_hypr(const ParseResult& r, const std::string& mainmod) {
    std::ostringstream o;
    o << "\n## Hyprland (" << mainmod << " = mainMod)\n";
    std::string cur = "\x01";  // sentinel that no real subsection matches
    for (const auto& b : collapse(r.binds)) {
        if (b.subsection != cur) {
            cur = b.subsection;
            o << "\n### " << (cur.empty() ? "Other" : cur) << "\n\n";
            o << "| Key | Action |\n|-----|--------|\n";
        }
        std::string key = md_escape(b.prefix + compact_keys(b.base) + b.suffix);
        std::string desc = md_escape(b.desc.empty() ? std::string(UNDOC) : cap_first(b.desc));
        o << "| `" << key << "` | " << desc << " |\n";
    }
    o << "\n";
    return o.str();
}

std::string hypr_mainmod(const std::vector<std::string>& lines) {
    for (const auto& raw : lines) {
        std::string t = trim(raw);
        if (starts_with(t, "$mainMod")) {
            auto eq = t.find('=');
            if (eq != std::string::npos) return trim(t.substr(eq + 1));
        }
    }
    return "ALT";
}

void usage() {
    std::printf(
        "Usage: fox-gen-keybinds [options]\n\n"
        "Regenerate the marker-fenced keybind sections of KEYBINDS.md from the\n"
        "config files that define the binds. Writes only between its own\n"
        "<!-- BEGIN/END GENERATED: <source> --> markers; hand-curated sections\n"
        "(e.g. nvim) are left untouched.\n\n"
        "Options:\n"
        "  --check            Report whether the doc is in sync; write nothing.\n"
        "                     Exit non-zero on drift. (Use this in CI.)\n"
        "  --strict           Treat undocumented binds and collisions as errors.\n"
        "  --verbose          List undocumented binds and collisions with line numbers.\n"
        "  --keybinds PATH    KEYBINDS.md path (default: KEYBINDS.md).\n"
        "  --tmux-conf PATH   tmux config path (default: templates/tmux/.tmux.conf).\n"
        "  --hypr-conf PATH   Hyprland keybinds path\n"
        "                     (default: shared/hyprland_modules/keybinds.conf).\n"
        "  -h, --help         This help.\n");
}

}  // namespace

int main(int argc, char** argv) {
    ui::init();

    bool check = false, strict = false, verbose = false;
    std::string keybinds = "KEYBINDS.md";
    std::string tmux_conf = "templates/tmux/.tmux.conf";
    std::string hypr_conf = "shared/hyprland_modules/keybinds.conf";

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--check") check = true;
        else if (a == "--strict") strict = true;
        else if (a == "--verbose" || a == "-v") verbose = true;
        else if (a == "--keybinds" && i + 1 < argc) keybinds = argv[++i];
        else if (a == "--tmux-conf" && i + 1 < argc) tmux_conf = argv[++i];
        else if (a == "--hypr-conf" && i + 1 < argc) hypr_conf = argv[++i];
        else if (a == "-h" || a == "--help") { usage(); return 0; }
        else { ui::err("unknown argument: " + a); usage(); return 2; }
    }

    bool ok = false;
    auto tmux_lines = read_lines(tmux_conf, ok);
    if (!ok) { ui::err("cannot read " + tmux_conf); return 1; }
    auto hypr_lines = read_lines(hypr_conf, ok);
    if (!ok) { ui::err("cannot read " + hypr_conf); return 1; }

    ParseResult tmux_r = parse_tmux(tmux_lines);
    ParseResult hypr_r = parse_hypr(hypr_lines);

    std::string old_content = read_file(keybinds, ok);
    if (!ok) { ui::err("cannot read " + keybinds); return 1; }

    std::string content = old_content;
    if (!splice(content, "tmux", emit_tmux(tmux_r), content)) {
        ui::err("no <!-- BEGIN/END GENERATED: tmux --> markers in " + keybinds);
        ui::warn("wrap the existing Tmux section in those markers once (first-run setup), then re-run");
        return 1;
    }
    if (!splice(content, "hypr", emit_hypr(hypr_r, hypr_mainmod(hypr_lines)), content)) {
        ui::err("no <!-- BEGIN/END GENERATED: hypr --> markers in " + keybinds);
        ui::warn("wrap the existing Hyprland section in those markers once (first-run setup), then re-run");
        return 1;
    }

    struct Src { const char* name; const std::string& conf; const ParseResult& r; };
    const Src srcs[] = {{"tmux", tmux_conf, tmux_r}, {"hypr", hypr_conf, hypr_r}};

    size_t undoc = 0, collisions = 0, rows = 0;
    for (const auto& s : srcs) {
        rows += collapse(s.r.binds).size();
        collisions += s.r.collisions.size();
        for (const auto& b : s.r.binds) if (b.desc.empty()) ++undoc;
        if (verbose) {
            for (const auto& b : s.r.binds)
                if (b.desc.empty())
                    ui::warn(std::string("undocumented: ") + b.display() + "  (" + s.conf + ":" +
                             std::to_string(b.line) + ")");
            for (const auto& c : s.r.collisions)
                ui::warn(std::string("collision: ") + c.display + "  (" + s.conf + ":" +
                         std::to_string(c.first_line) + " and :" + std::to_string(c.dup_line) + ")");
        }
    }

    bool drift = (content != old_content);

    ui::section(check ? "Checking KEYBINDS.md" : "Generating KEYBINDS.md");
    if (check) {
        if (drift) ui::warn(keybinds + " is out of sync with the configs — run: fox dev gen-keybinds");
        else ui::ok(keybinds + " is in sync");
    } else if (drift) {
        if (!write_file_atomic(keybinds, content)) { ui::err("write failed: " + keybinds); return 1; }
        ui::ok("updated tmux + hypr sections of " + keybinds);
    } else {
        ui::skipped(keybinds + " already up to date");
    }

    std::ostringstream summary;
    summary << rows << " rows · " << undoc << " undocumented · " << collisions << " collisions";
    ui::summary_row("generated", summary.str());

    if (strict && (undoc > 0 || collisions > 0)) {
        ui::err("strict: undocumented binds or collisions present");
        return 1;
    }
    if (check && drift) return 1;
    return 0;
}
