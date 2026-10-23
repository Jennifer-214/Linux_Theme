// core/git_clone_sh.hpp — git_clone's runner on the installer's own shell layer (sh::run / sh::probe), so clones log,
// dry-run and fail the way every other command does. Separate from git_clone.hpp so its test needs no fox-common.
#pragma once

#include "git_clone.hpp"
#include "../../fox-common/shell.hpp"

namespace fox_install::git_clone {

inline Runner sh_runner() {
    return Runner{[](const std::vector<std::string>& a) { return sh::run(a); },
                  [](const std::vector<std::string>& a) { std::string out; return sh::probe(a, out); }};
}

}  // namespace fox_install::git_clone
