#include "module.hpp"
#include "state_checks.hpp"

// The FOX_MODULE / FOX_MODULE_FULL X-macros are redefined twice in this
// file: once to emit forward declarations of every module function,
// once to emit the Module table. FOX_MODULE is a thin shim that
// delegates to FOX_MODULE_FULL with all prereqs defaulted to false and
// state_check defaulted to nullptr, so legacy entries in modules.def
// keep working unchanged. state_checks::* are declared in state_checks.hpp.

namespace fox_install {

#define FOX_MODULE_FULL(slug, fn, flag, desc, def_on, req_root, req_gfx, req_net, sc)  \
    void fn(Context&);
#define FOX_MODULE(slug, fn, flag, desc, def_on)  \
    FOX_MODULE_FULL(slug, fn, flag, desc, def_on, false, false, false, nullptr)
#include "modules.def"
#undef  FOX_MODULE
#undef  FOX_MODULE_FULL

#define FOX_MODULE_FULL(slug, fn, flag, desc, def_on, req_root, req_gfx, req_net, sc)  \
    { #slug, &fn, flag, desc, def_on, req_root, req_gfx, req_net, sc },
#define FOX_MODULE(slug, fn, flag, desc, def_on)  \
    FOX_MODULE_FULL(slug, fn, flag, desc, def_on, false, false, false, nullptr)
const Module MODULES[] = {
#include "modules.def"
};
#undef  FOX_MODULE
#undef  FOX_MODULE_FULL

const std::size_t MODULES_COUNT = sizeof(MODULES) / sizeof(MODULES[0]);

}  // namespace fox_install
