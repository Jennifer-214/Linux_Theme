#include "module.hpp"
#include "state_checks.hpp"

// The DESK_MODULE / DESK_MODULE_FULL X-macros are redefined twice in this
// file: once to emit forward declarations of every module function,
// once to emit the Module table. DESK_MODULE is a thin shim that
// delegates to DESK_MODULE_FULL with all prereqs defaulted to false and
// state_check defaulted to nullptr, so legacy entries in modules.def
// keep working unchanged. state_checks::* are declared in state_checks.hpp.

namespace desk_install {

#define DESK_MODULE_FULL(slug, fn, flag, desc, def_on, req_root, req_gfx, req_net, sc)  \
    void fn(Context&);
#define DESK_MODULE(slug, fn, flag, desc, def_on)  \
    DESK_MODULE_FULL(slug, fn, flag, desc, def_on, false, false, false, nullptr)
#include "modules.def"
#undef  DESK_MODULE
#undef  DESK_MODULE_FULL

#define DESK_MODULE_FULL(slug, fn, flag, desc, def_on, req_root, req_gfx, req_net, sc)  \
    { #slug, &fn, flag, desc, def_on, req_root, req_gfx, req_net, sc },
#define DESK_MODULE(slug, fn, flag, desc, def_on)  \
    DESK_MODULE_FULL(slug, fn, flag, desc, def_on, false, false, false, nullptr)
const Module MODULES[] = {
#include "modules.def"
};
#undef  DESK_MODULE
#undef  DESK_MODULE_FULL

const std::size_t MODULES_COUNT = sizeof(MODULES) / sizeof(MODULES[0]);

}  // namespace desk_install
