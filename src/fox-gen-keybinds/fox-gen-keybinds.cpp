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
#include <sstream>
#include <string>
#include <vector>

namespace ui = fox_install::ui;
namespace fs = std::filesystem;

namespace {

struct Bind {
    std::string prefix;   // "Ctrl+a " for prefixed binds, "" for root / copy-mode
    std::string base;     // normalized key ("h", "|", "Ctrl+Shift+a")
    std::string suffix;   // " (copy mode)" for copy-mode-vi binds, "" otherwise
    std::string desc;     // empty => undocumented
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

// Collapse consecutive binds sharing prefix+suffix+desc into one a/b/c row.
std::vector<Bind> collapse(const std::vector<Bind>& in) {
    std::vector<Bind> out;
    for (const auto& b : in) {
        if (!out.empty() && !b.desc.empty() && out.back().desc == b.desc &&
            out.back().prefix == b.prefix && out.back().suffix == b.suffix) {
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
// everything outside them. Returns false if the markers are missing.
bool splice(const std::vector<std::string>& lines, const std::string& tag,
            const std::string& block, std::string& out) {
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
    for (int i = end; i < (int)lines.size(); ++i) o << lines[i] << "\n";
    out = o.str();
    return true;
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
        "  -h, --help         This help.\n");
}

}  // namespace

int main(int argc, char** argv) {
    ui::init();

    bool check = false, strict = false, verbose = false;
    std::string keybinds = "KEYBINDS.md";
    std::string tmux_conf = "templates/tmux/.tmux.conf";

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--check") check = true;
        else if (a == "--strict") strict = true;
        else if (a == "--verbose" || a == "-v") verbose = true;
        else if (a == "--keybinds" && i + 1 < argc) keybinds = argv[++i];
        else if (a == "--tmux-conf" && i + 1 < argc) tmux_conf = argv[++i];
        else if (a == "-h" || a == "--help") { usage(); return 0; }
        else { ui::err("unknown argument: " + a); usage(); return 2; }
    }

    bool ok = false;
    auto conf_lines = read_lines(tmux_conf, ok);
    if (!ok) { ui::err("cannot read " + tmux_conf); return 1; }

    ParseResult r = parse_tmux(conf_lines);
    std::string block = emit_tmux(r);

    auto kb_lines = read_lines(keybinds, ok);
    if (!ok) { ui::err("cannot read " + keybinds); return 1; }
    std::string old_content = ([&] { bool o; return read_file(keybinds, o); })();

    std::string new_content;
    if (!splice(kb_lines, "tmux", block, new_content)) {
        ui::err("no <!-- BEGIN/END GENERATED: tmux --> markers in " + keybinds);
        ui::warn("wrap the existing Tmux section in those markers once (first-run setup), then re-run");
        return 1;
    }

    size_t undoc = 0;
    for (const auto& b : r.binds) if (b.desc.empty()) ++undoc;

    bool drift = (new_content != old_content);

    if (verbose) {
        for (const auto& b : r.binds)
            if (b.desc.empty())
                ui::warn("undocumented: " + b.display() + "  (" + tmux_conf + ":" + std::to_string(b.line) + ")");
        for (const auto& c : r.collisions)
            ui::warn("collision: " + c.display + "  (" + tmux_conf + ":" +
                     std::to_string(c.first_line) + " and :" + std::to_string(c.dup_line) + ")");
    }

    ui::section(check ? "Checking KEYBINDS.md" : "Generating KEYBINDS.md");
    if (check) {
        if (drift) ui::warn(keybinds + " is out of sync with " + tmux_conf + " — run: fox dev gen-keybinds");
        else ui::ok(keybinds + " is in sync");
    } else {
        if (drift) {
            if (!write_file_atomic(keybinds, new_content)) { ui::err("write failed: " + keybinds); return 1; }
            ui::ok("updated tmux section of " + keybinds);
        } else {
            ui::skipped(keybinds + " already up to date");
        }
    }

    std::ostringstream summary;
    summary << collapse(r.binds).size() << " tmux rows · " << undoc << " undocumented · "
            << r.collisions.size() << " collisions";
    ui::summary_row("generated", summary.str());

    if (strict && (undoc > 0 || !r.collisions.empty())) {
        ui::err("strict: undocumented binds or collisions present");
        return 1;
    }
    if (check && drift) return 1;
    return 0;
}
