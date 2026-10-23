// Live-config drift before a render (installer audit 2026-10-15, finding 19; batch 3a): render.cpp used to find drift
// only in phase 2 and exit(2) there under -y — after phase-1 root modules had already run, with no summary. The same
// check now also runs before any module: under -y / no TTY it stops the install while nothing has changed yet.
#pragma once

#include "../core/context.hpp"

#include <filesystem>
#include <vector>

namespace fox_install {

// Live ~/.config files that differ from the last render still in ctx.rendered_dir (empty on a fresh install).
std::vector<std::filesystem::path> detect_drift(const Context& ctx);

// Stop BEFORE any module runs? Only where render itself would abort (-y or no TTY, no --full, not a dry run, render
// selected) and there is drift — so the only new path stops earlier, doing less, never more.
inline bool drift_stops_before_install(bool render_will_run, bool dry_run, bool force_reapply,
                                       bool assume_yes, bool tty, bool drift) {
    return render_will_run && !dry_run && !force_reapply && (assume_yes || !tty) && drift;
}

}  // namespace fox_install
