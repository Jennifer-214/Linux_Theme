#ifndef FOX_INSTALL_MODULE_HPP
#define FOX_INSTALL_MODULE_HPP

// Single source of truth for installable modules.
//
// To register a new install module:
//
//   1. Write `void run_foo(Context&);` in src/fox-install/modules/foo.cpp.
//   2. Add ONE line to modules.def:
//
//          FOX_MODULE(foo, run_foo, "--foo", "What it does", false)
//
//   3. Rebuild. --help, the arg parser, the dispatcher, and the
//      end-of-install summary all pick it up automatically.
//
// FOX_MODULE arguments:
//   slug         identifier used in code, e.g. `foo`        (must be a valid C identifier)
//   function     symbol to call: void run_foo(Context&)
//   flag         CLI flag, e.g. "--foo"
//   description  one-line description shown in --help
//   default_on   if true, module runs unless explicitly disabled with --no-<slug>
//
// FOX_MODULE_FULL — extended form. Same shape plus three trailing prereq
// booleans (Step 5) and an optional state_check function pointer (Step 6),
// consumed by the dispatcher in Session B Step 7 to skip modules whose
// requirements can't be met or whose work has already been done:
//
//     FOX_MODULE_FULL(foo, run_foo, "--foo", "...", false,
//                     /*requires_root*/      true,
//                     /*requires_graphical*/ false,
//                     /*requires_network*/   true,
//                     /*state_check*/        state::check_foo)
//
// FOX_MODULE(...) is a backward-compat shim that defaults all three
// prereq fields to false and the state_check pointer to nullptr —
// existing entries in modules.def keep working unchanged.

#include "context.hpp"
#include "classifier.hpp"
#include "state_manifest.hpp"

namespace fox_install {

using ModuleFn     = void(*)(Context&);

// Optional per-module introspection callback. Returns a Classification
// describing whether the module needs to run, is up to date, conflicts
// with on-disk state, or is blocked by an unmet prereq. nullptr means
// "no introspection — treat as Fresh on every run" (current behavior
// for legacy FOX_MODULE entries).
using StateCheckFn = state::Classification(*)(const Context&, const state::Manifest&);

struct Module {
    const char* slug;
    ModuleFn    fn;
    const char* flag;
    const char* description;
    bool        default_on;
    bool        requires_root;
    bool        requires_graphical;
    bool        requires_network;
    StateCheckFn state_check;
};

// Defined in registry.cpp via X-macro expansion of modules.def.
extern const Module  MODULES[];
extern const std::size_t MODULES_COUNT;

}  // namespace fox_install

#endif
