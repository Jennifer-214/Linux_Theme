// core/built_tools.hpp — the names the src/<tool> Makefiles build (each one's `BIN = name` / `BIN := name` line).
// specials' shared/bin bulk copy skips them, so a script never lands over the compiled tool of the same name
// (installer audit 2026-10-15: shared/bin/fox, fox-vault and fox-ai-review did). tests/test_deploy_lists.py keeps
// shared/bin free of such names; this is the install-time backstop.
#pragma once

#include <cctype>
#include <filesystem>
#include <fstream>
#include <set>
#include <string>
#include <system_error>

namespace fox_install {

inline std::set<std::string> built_tool_names(const std::filesystem::path& src_dir) {
    std::set<std::string> names;
    std::error_code ec;
    for (std::filesystem::directory_iterator it(src_dir, ec), end; !ec && it != end; it.increment(ec)) {
        std::ifstream mk(it->path() / "Makefile");
        std::string line;
        while (std::getline(mk, line)) {
            std::size_t i = line.find_first_not_of(" \t");
            if (i == std::string::npos || line.compare(i, 3, "BIN") != 0) continue;
            i = line.find_first_not_of(" \t", i + 3);
            if (i != std::string::npos && line[i] == ':') ++i;
            if (i == std::string::npos || i >= line.size() || line[i] != '=') continue;
            i = line.find_first_not_of(" \t", i + 1);
            if (i == std::string::npos) continue;
            std::size_t j = i;
            while (j < line.size() && !std::isspace(static_cast<unsigned char>(line[j])) && line[j] != '#') ++j;
            if (j > i) names.insert(line.substr(i, j - i));
            break;
        }
    }
    return names;
}

}  // namespace fox_install
