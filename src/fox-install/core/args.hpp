#ifndef FOX_INSTALL_ARGS_HPP
#define FOX_INSTALL_ARGS_HPP

#include "context.hpp"

#include <string>
#include <vector>

namespace fox_install::args {

struct Parsed {
    std::vector<bool> module_enabled;     // size = MODULES_COUNT, indexed by module order
    bool show_help    = false;
    bool show_version = false;
    bool quiet        = false;
    bool full         = false;            // alias for "enable every default + every major opt-in"
    bool only         = false;            // --only <list> was used
    bool resume       = false;            // --resume
    bool wizard_demo  = false;            // --wizard-demo: render the wizard against the live registry + exit
    std::string phase;                    // --phase <slug>
};

// Parses argv into Parsed + populates global flags on `ctx`.
// Returns false on parse error (prints to stderr).
bool parse(int argc, char** argv, Parsed& out, Context& ctx);

// Renders --help text using the X-macro module list.
void print_help(const char* argv0);
void print_version();

}  // namespace fox_install::args

#endif
