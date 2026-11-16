// tests/unit_exec.hpp — the script inside a generated unit's `ExecStart=/bin/sh -c '…'`, as sh receives it, so a test
// can run the unit's own command with stand-ins on PATH. Before sh sees the text systemd resolves % specifiers, its
// C-style escapes and ${VAR}. The scripts keep to the subset where only the first applies (no backslash, no ${), so
// the one rewrite is %% → %; a bare % specifier, a backslash, a ${ or an inner quote is reported instead.
#pragma once

#include <string>

namespace unit_exec {

// Empty `error` when the script was found and is in that subset.
inline std::string shell_script(const std::string& unit, std::string& error) {
    error.clear();
    const std::string start = "ExecStart=/bin/sh -c '";
    const auto at = unit.find(start);
    if (at == std::string::npos) { error = "no ExecStart=/bin/sh -c '…' line"; return {}; }
    const auto begin = at + start.size();
    const auto end = unit.find('\n', begin);
    std::string quoted = unit.substr(begin, end == std::string::npos ? std::string::npos : end - begin);
    if (quoted.empty() || quoted.back() != '\'') { error = "the script's closing quote does not end the line"; return {}; }
    quoted.pop_back();
    if (quoted.find('\'') != std::string::npos) error = "a quote inside the script ends systemd's quoting early";
    else if (quoted.find('\\') != std::string::npos) error = "a backslash: systemd unescapes it before sh sees it";
    else if (quoted.find("${") != std::string::npos) error = "${…}: systemd substitutes it before sh sees it";
    if (!error.empty()) return {};
    std::string script;
    for (std::size_t i = 0; i < quoted.size(); ++i) {
        if (quoted[i] != '%') { script += quoted[i]; continue; }
        if (i + 1 < quoted.size() && quoted[i + 1] == '%') { script += '%'; ++i; continue; }
        error = "a bare % specifier: systemd would expand it";
        return {};
    }
    return script;
}

}  // namespace unit_exec
