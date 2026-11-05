// modules/theme.cpp — reports the theme this run settled on (core/theme_choice.hpp).
//
// The choice is made before the plan is built, so the state checks and every module read the same palette.

#include "../core/context.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>

namespace fs = std::filesystem;

namespace fox_install {

void run_theme(Context& ctx) {
    if (!fs::exists(ctx.palette_path)) {
        ui::err("no palette for theme " + ctx.theme_name + " at " + ctx.palette_path.string());
        return;
    }
    ui::section("Theme: " + ctx.theme_name + " (" + ctx.theme_source + ")");
}

}  // namespace fox_install
