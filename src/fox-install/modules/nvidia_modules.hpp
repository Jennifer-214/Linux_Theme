#ifndef FOX_INSTALL_NVIDIA_MODULES_HPP
#define FOX_INSTALL_NVIDIA_MODULES_HPP

// Pure (no sudo / no I/O) merge of the nvidia early-load modules into a
// mkinitcpio.conf MODULES=(...) array. Replaces nvidia.cpp's old
// `sed s/^MODULES=\([^)]*\)/MODULES=(nvidia …)/`, a whole-line REPLACE that
// wiped whatever the user already had (encrypt for LUKS, lvm2, vfio_pci, …) →
// an initramfs missing its boot-critical modules → UNBOOTABLE. A whole-line
// replace is idempotent yet destructive (DOCS/RECURRING_BUG_PATTERNS:
// "idempotent ≠ non-destructive"); the safe shape is read-modify-write.
//
// Header-only + dependency-free so tests/test_nvidia_modules.cpp drives the
// REAL merge against fixtures — no VM, no sudo, no .o to drift from.

#include <algorithm>
#include <cstddef>
#include <string>
#include <vector>

namespace fox_install {

// The nvidia early-KMS modules, in dependency order. Appended (missing-only,
// dedup) after the user's existing entries.
inline const std::vector<std::string> kNvidiaModules = {
    "nvidia", "nvidia_modeset", "nvidia_uvm", "nvidia_drm"};

namespace nvidia_detail {

// Offset of the first ACTIVE `MODULES=` assignment (leading whitespace
// allowed; a `#`-commented line never matches), or npos. Form-agnostic: finds
// `MODULES=` whether the value is an array, a string, or a scalar — the caller
// inspects the next char to decide whether it is the array form it can edit.
inline std::size_t active_modules_offset(const std::string& text) {
    std::size_t i = 0;
    while (i < text.size()) {
        std::size_t nl = text.find('\n', i);
        std::size_t line_end = (nl == std::string::npos) ? text.size() : nl;
        std::size_t s = i;
        while (s < line_end && (text[s] == ' ' || text[s] == '\t')) ++s;
        if (text.compare(s, 8, "MODULES=") == 0) return s;
        if (nl == std::string::npos) break;
        i = nl + 1;
    }
    return std::string::npos;
}

// True when an ACTIVE (non-comment) line carries a MODULES assignment this
// parser does NOT understand: `MODULES+=(…)` or `export MODULES=(…)`.
//
// Critically distinct from "no MODULES line at all". That case is safe to append
// a canonical `MODULES=(…)` to. This one is NOT: mkinitcpio sources the conf as
// bash, so a plain `MODULES=` appended AFTER a `+=` REPLACES the array rather
// than extending it — silently dropping every entry the user accumulated
// (`MODULES+=(nvme dm_crypt)` on a LUKS box → unbootable). Conflating "unparsed"
// with "absent" is what let that path through the self-check: parse_modules()
// also returns {} here, so `kept_all = all_of(empty)` is vacuously true.
inline bool has_unparsed_modules_form(const std::string& text) {
    std::size_t i = 0;
    while (i < text.size()) {
        std::size_t nl = text.find('\n', i);
        std::size_t line_end = (nl == std::string::npos) ? text.size() : nl;
        std::size_t s = i;
        while (s < line_end && (text[s] == ' ' || text[s] == '\t')) ++s;

        std::size_t t = s;
        if (text.compare(t, 7, "export ") == 0) {
            t += 7;
            while (t < line_end && (text[t] == ' ' || text[t] == '\t')) ++t;
        }
        if (t < line_end && text[t] != '#' &&
            text.compare(t, 7, "MODULES") == 0) {
            std::size_t c = t + 7;
            if (c < line_end) {
                if (text[c] == '+') return true;            // MODULES+=
                if (text[c] == '=' && t != s) return true;  // export MODULES=
            }
        }
        if (nl == std::string::npos) break;
        i = nl + 1;
    }
    return false;
}

// Tokenize the inside of MODULES=( … ): whitespace-separated words, `#`
// comments stripped. Shared by parse and the merge body.
inline std::vector<std::string> tokenize(const std::string& inner) {
    std::vector<std::string> out;
    std::string cur;
    bool in_comment = false;
    for (char c : inner) {
        if (in_comment) {
            if (c == '\n') in_comment = false;
            continue;
        }
        if (c == '#') {
            if (!cur.empty()) { out.push_back(cur); cur.clear(); }
            in_comment = true;
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            if (!cur.empty()) { out.push_back(cur); cur.clear(); }
        } else {
            cur += c;
        }
    }
    if (!cur.empty()) out.push_back(cur);
    return out;
}

// True iff `s` is a plain kernel-module name — [A-Za-z0-9_-]+. A token that
// isn't (a backslash line-continuation, a quote, `$VAR`, or a line swallowed
// from an unclosed array) can't be safely re-emitted on one line, so the merge
// refuses rather than mangle it.
inline bool is_module_name(const std::string& s) {
    if (s.empty()) return false;
    for (char c : s) {
        bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!ok) return false;
    }
    return true;
}

// Offset just past the closing `)` of an array opened at `open` (the `(`),
// skipping `#` comments, or npos if the array is unclosed (malformed).
inline std::size_t array_close(const std::string& text, std::size_t open) {
    bool in_comment = false;
    for (std::size_t p = open + 1; p < text.size(); ++p) {
        char c = text[p];
        if (in_comment) { if (c == '\n') in_comment = false; continue; }
        if (c == '#') { in_comment = true; continue; }
        if (c == ')') return p;
    }
    return std::string::npos;
}

}  // namespace nvidia_detail

// Parse the active MODULES=(...) array into its tokens, in file order.
// Single-line AND multi-line forms; `#` comments stripped. Empty vector if
// there is no active array-form MODULES line (a commented or string-form line
// does NOT count).
inline std::vector<std::string> parse_modules(const std::string& conf_text) {
    std::size_t m = nvidia_detail::active_modules_offset(conf_text);
    if (m == std::string::npos) return {};
    std::size_t open = m + 8;  // past "MODULES="
    if (open >= conf_text.size() || conf_text[open] != '(') return {};  // not array form
    std::size_t close = nvidia_detail::array_close(conf_text, open);
    if (close == std::string::npos) return {};  // unclosed (malformed)
    return nvidia_detail::tokenize(conf_text.substr(open + 1, close - (open + 1)));
}

// Merge the nvidia modules into a mkinitcpio.conf text. Returns the new full
// text. NEVER drops an existing entry. Idempotent: merge(merge(x)) == merge(x).
//   - array-form MODULES=(...)  → splice: existing tokens kept in order, the
//     missing nvidia modules appended (dedup), body rewritten single-line; a
//     trailing comment AFTER the `)` is preserved, a rare comment INSIDE the
//     array is dropped (acceptable — mkinitcpio re-canonicalises).
//   - no MODULES line at all     → a canonical MODULES=(nvidia …) is appended.
//   - string/scalar form, an unclosed array, or any non-identifier token
//     (backslash continuation / quote / $VAR) → returned UNCHANGED (we never
//     understand-then-clobber; nvidia.cpp's self-check then refuses the edit).
inline std::string merge_modules(const std::string& conf_text) {
    std::size_t m = nvidia_detail::active_modules_offset(conf_text);

    if (m == std::string::npos) {
        // An unparsed-but-present MODULES form: refuse rather than append. A
        // canonical `MODULES=(…)` tacked on the end would REPLACE it in bash.
        // Returning unchanged makes nvidia.cpp's (b) check (`nvidia_ok`) fail,
        // which surfaces the loud "refusing an unsafe edit" warning — the exact
        // no-silent-no-op guarantee that check was written for.
        if (nvidia_detail::has_unparsed_modules_form(conf_text)) return conf_text;

        std::string out = conf_text;
        if (!out.empty() && out.back() != '\n') out += '\n';
        out += "MODULES=(";
        for (std::size_t i = 0; i < kNvidiaModules.size(); ++i)
            out += (i ? " " : "") + kNvidiaModules[i];
        out += ")\n";
        return out;
    }

    std::size_t open = m + 8;  // past "MODULES="
    if (open >= conf_text.size() || conf_text[open] != '(')
        return conf_text;  // string/scalar form — don't touch
    std::size_t close = nvidia_detail::array_close(conf_text, open);
    if (close == std::string::npos) return conf_text;  // unclosed — don't touch

    std::vector<std::string> toks =
        nvidia_detail::tokenize(conf_text.substr(open + 1, close - (open + 1)));

    // If any existing entry isn't a plain module name, we can't rewrite the
    // array single-line without risking a mangle (an escaped space) or a
    // swallowed line — leave the conf UNCHANGED. nvidia.cpp's nvidia_ok
    // self-check then refuses the edit and the GPU falls back to modeset+udev.
    for (const std::string& t : toks)
        if (!nvidia_detail::is_module_name(t)) return conf_text;

    for (const std::string& want : kNvidiaModules)
        if (std::find(toks.begin(), toks.end(), want) == toks.end())
            toks.push_back(want);

    std::string body;
    for (std::size_t i = 0; i < toks.size(); ++i)
        body += (i ? " " : "") + toks[i];

    return conf_text.substr(0, m) + "MODULES=(" + body + ")" +
           conf_text.substr(close + 1);
}

// Rewrite a single line of the hypr nvidia.conf template. The AQ_DRM_DEVICES
// env line is made ACTIVE only when the resolved device set is COMPLETE;
// otherwise it's left COMMENTED so Aquamarine auto-detects. A partial
// (single-card) value on an Optimus box blacks the iGPU-wired eDP, so an unset
// value is safer than a wrong one. Non-AQ lines (LIBVA_*, __GLX_*, WLR_*, the
// header comments) pass through untouched. Pure → unit-tested.
inline std::string rewrite_aq_line(const std::string& line,
                                   const std::string& aq_value, bool complete) {
    std::size_t i = 0;
    while (i < line.size() && (line[i] == ' ' || line[i] == '\t')) ++i;
    std::string rest = line.substr(i);
    if (!rest.empty() && rest[0] == '#') {                 // re-target an already-commented line
        rest.erase(0, 1);
        std::size_t j = 0;
        while (j < rest.size() && (rest[j] == ' ' || rest[j] == '\t')) ++j;
        rest.erase(0, j);
    }
    if (rest.rfind("env", 0) == 0 &&
        rest.find("AQ_DRM_DEVICES") != std::string::npos) {
        return line.substr(0, i) + (complete ? "" : "# ") +
               "env = AQ_DRM_DEVICES, " + aq_value;
    }
    return line;                                            // not the AQ_DRM_DEVICES line
}

}  // namespace fox_install

#endif  // FOX_INSTALL_NVIDIA_MODULES_HPP
