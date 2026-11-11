#include "reverse.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <regex>
#include <sstream>

namespace fox_render {

namespace {

// True if `s` is a 6-char hex literal (no leading #).
bool is_six_char_hex(const std::string& s) {
    if (s.size() != 6) return false;
    for (char c : s) {
        if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
    }
    return true;
}

bool starts_and_ends_with_braces(const std::string& s) {
    return s.size() >= 4 &&
           s[0] == '{' && s[1] == '{' &&
           s[s.size() - 2] == '}' && s[s.size() - 1] == '}';
}

std::string strip_marker(const std::string& s) {
    if (!starts_and_ends_with_braces(s)) return s;
    return s.substr(2, s.size() - 4);
}

std::string lower(std::string s) {
    for (auto& c : s) c = std::tolower(static_cast<unsigned char>(c));
    return s;
}

std::string upper(std::string s) {
    for (auto& c : s) c = std::toupper(static_cast<unsigned char>(c));
    return s;
}

// Single-pass string replace-all. Used instead of std::regex for the
// literal hex / RGB / string substitutions — regex would need every
// special char escaped, and the patterns are large.
void replace_all(std::string& s, const std::string& from, const std::string& to) {
    if (from.empty()) return;
    std::size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos) {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
}

// Case-insensitive variant — does both lowercase + uppercase passes.
// Bash's reverse logic did this for hex values because templates can
// contain colour literals in either case.
void replace_all_ci(std::string& s, const std::string& from, const std::string& to) {
    std::string lo = lower(from), up = upper(from);
    if (lo == up) {
        replace_all(s, from, to);
    } else {
        replace_all(s, lo, to);
        replace_all(s, up, to);
    }
}

}  // namespace

std::vector<ReverseRule> build_reverse_rules(
    const std::unordered_map<std::string, std::string>& palette)
{
    // Separate the palette into (hex_vars, str_vars) the same way the
    // forward path does. The palette map keys are `{{KEY}}` and
    // `{{KEY_R}}` etc.; we want each KEY exactly once.
    std::vector<std::pair<std::string, std::string>> hex_vars;   // KEY → hex
    std::vector<std::pair<std::string, std::string>> str_vars;   // KEY → string-value

    for (auto& [marker, value] : palette) {
        std::string key = strip_marker(marker);
        // KEY_R / KEY_G / KEY_B are computed from KEY's hex — skip them
        // here; we'll add the RGB-triple rule explicitly below.
        auto us = key.rfind('_');
        if (us != std::string::npos &&
            (key.substr(us) == "_R" || key.substr(us) == "_G" || key.substr(us) == "_B")) {
            continue;
        }
        if (is_six_char_hex(value)) {
            hex_vars.emplace_back(key, value);
        } else {
            str_vars.emplace_back(key, value);
        }
    }

    std::vector<ReverseRule> rules;
    rules.reserve(hex_vars.size() * 2 + str_vars.size());

    // Pass 1: RGB triples first (longer pattern wins). Bash inserts
    // optional whitespace between commas — match either compact
    // ("244,181,138") or spaced ("244, 181, 138").
    for (auto& [key, hex] : hex_vars) {
        int r = std::strtol(hex.substr(0, 2).c_str(), nullptr, 16);
        int g = std::strtol(hex.substr(2, 2).c_str(), nullptr, 16);
        int b = std::strtol(hex.substr(4, 2).c_str(), nullptr, 16);
        char buf_compact[40], buf_spaced[40];
        std::snprintf(buf_compact, sizeof(buf_compact), "%d,%d,%d", r, g, b);
        std::snprintf(buf_spaced,  sizeof(buf_spaced),  "%d, %d, %d", r, g, b);
        std::string repl = "{{" + key + "_R}},{{" + key + "_G}},{{" + key + "_B}}";
        std::string repl_spaced = "{{" + key + "_R}}, {{" + key + "_G}}, {{" + key + "_B}}";
        rules.push_back({buf_compact, repl,        false});
        rules.push_back({buf_spaced,  repl_spaced, false});
    }

    // Pass 2: bare hex colours, case-insensitive.
    for (auto& [key, hex] : hex_vars) {
        rules.push_back({hex, "{{" + key + "}}", true});
    }

    // Pass 3: string-valued palette vars (paths, fonts, etc.). Order
    // matters less here but keep declaration order for determinism.
    for (auto& [key, val] : str_vars) {
        if (val.empty()) continue;
        rules.push_back({val, "{{" + key + "}}", false});
    }
    return rules;
}

std::string apply_reverse(const std::string& src,
                          const std::vector<ReverseRule>& rules)
{
    std::string out = src;
    for (auto& r : rules) {
        if (r.case_insensitive) replace_all_ci(out, r.pattern, r.replacement);
        else                    replace_all(out, r.pattern, r.replacement);
    }
    return out;
}

// Patterns mirrored from update.sh:_DANGER_PATTERNS.
//
// Rationale (from bash): an attacker who compromises a live config
// could embed a payload that `update.sh --force` would otherwise
// reverse-capture into templates/, and a later `git push` would
// publish. Refuse at the capture point. Patterns here should NEVER
// appear in a config diff that only changed colours / fonts / pure
// data. Hits require manual review.
static const std::vector<std::pair<std::regex, std::string>>& danger_patterns() {
    static const std::vector<std::pair<std::regex, std::string>> ps = {
        { std::regex(R"(^[[:space:]]*exec[-_]?once[[:space:]]*=)",
                     std::regex::multiline | std::regex::ECMAScript),
          "exec-once = … (Hyprland command injection)" },
        { std::regex(R"(curl[[:space:]].*\|[[:space:]]*(bash|sh))",
                     std::regex::ECMAScript),
          "curl | bash" },
        { std::regex(R"(wget[[:space:]].*\|[[:space:]]*(bash|sh))",
                     std::regex::ECMAScript),
          "wget | bash" },
        { std::regex(R"(bash[[:space:]]+-c[[:space:]]+["'].*\$\()",
                     std::regex::ECMAScript),
          "bash -c \"…$(…)\" command substitution" },
        { std::regex(R"(eval[[:space:]]*["']?\$)",
                     std::regex::ECMAScript),
          "eval $…" },
        { std::regex(R"(on[-_]?click[[:space:]]*=)",
                     std::regex::ECMAScript),
          "on-click = … (waybar handler)" },
        { std::regex(R"(on[-_]?press[[:space:]]*=)",
                     std::regex::ECMAScript),
          "on-press = … (Hyprland keybind handler)" },
        { std::regex(R"(command[[:space:]]*=[[:space:]]*["']?[a-zA-Z])",
                     std::regex::ECMAScript),
          "command = … (systemd unit)" },
        { std::regex(R"(PreExec[[:space:]]*=)", std::regex::ECMAScript),
          "PreExec = … (systemd unit)" },
        { std::regex(R"(ExecStartPre[[:space:]]*=)", std::regex::ECMAScript),
          "ExecStartPre = … (systemd unit)" },
        { std::regex(R"(<script[[:space:]>])", std::regex::ECMAScript),
          "<script …> (HTML injection)" },
    };
    return ps;
}

std::string scan_danger(const std::string& body) {
    for (auto& [re, label] : danger_patterns()) {
        if (std::regex_search(body, re)) return label;
    }
    return {};
}

}  // namespace fox_render
