#ifndef FOX_RENDER_REVERSE_HPP
#define FOX_RENDER_REVERSE_HPP

// Reverse rendering: replace concrete hex colours / RGB triples / string
// values with their {{KEY}} placeholders. Used by `update.sh`'s capture
// flow — pull live system configs back into templates/. Forward render
// is implemented in render.hpp; reverse keeps the palette parse + the
// substitution machinery in lockstep so a contributor adding a palette
// var gets correct round-trip without touching this file.
//
// Also exports the danger-pattern scan from `update.sh`: refuse to
// reverse-capture content that looks like an injection vector (curl |
// bash, exec-once, ExecStartPre, etc.). Capturing such a payload into
// templates/ would publish it on `git push`.

#include <string>
#include <unordered_map>
#include <vector>

namespace fox_render {

// Substitution entries are applied in declaration order. RGB triples
// before bare hex (longer patterns first) — otherwise "1a1214" inside
// "26,18,20" would partial-match and corrupt the RGB triple before it
// got a chance.
struct ReverseRule {
    std::string pattern;     // literal string to match
    std::string replacement; // what to substitute in its place
    bool        case_insensitive;
};

std::vector<ReverseRule> build_reverse_rules(
    const std::unordered_map<std::string, std::string>& palette);

// Apply the rule list to `src`, returning the substituted body.
std::string apply_reverse(
    const std::string& src,
    const std::vector<ReverseRule>& rules);

// Scan a body for danger patterns. Returns the matched pattern
// description on hit, empty string when clean.
std::string scan_danger(const std::string& body);

}  // namespace fox_render

#endif
