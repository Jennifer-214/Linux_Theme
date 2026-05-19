// state_checks.hpp — per-module introspection callbacks.
//
// Phase 6 Step 6. Each function inspects the running system (pacman -Qi,
// systemctl is-enabled, file hashes, …) and returns a Classification
// the dispatcher uses to decide whether to skip, re-run, or prompt.
//
// Wired into the registry via FOX_MODULE_FULL in modules.def. Modules
// without a state_check pointer (i.e. legacy FOX_MODULE entries) are
// classified as Fresh by the dispatcher — current behavior preserved.

#pragma once

#include "classifier.hpp"
#include "context.hpp"
#include "state_manifest.hpp"

namespace fox_install::state {

// deps — pacman base packages. Probes for a small set of foundational
// packages (the ones every subsequent module depends on). If the
// manifest has no deps entry, we assume nothing has been installed.
// If sentinels are all present, Noop; if any are missing, Update.
Classification check_deps     (const Context& ctx, const Manifest& manifest);

// render — templated config deploy. Compares the deployed copy of a
// sentinel rendered file (~/.config/hypr/hyprland.conf) against the
// stored source_hash from the manifest. No manifest entry → Fresh.
// Hash match → Noop. Hash differ → Update. File missing → Conflict.
Classification check_render   (const Context& ctx, const Manifest& manifest);

// etckeeper — git /etc + fox-etcwatch.path user unit. Surfaces the
// masked-state hazard explicitly per R5/R6: a masked unit is Blocked,
// not Conflict, because nothing the installer does will recover it
// without a manual `systemctl --user unmask` first.
Classification check_etckeeper(const Context& ctx, const Manifest& manifest);

}  // namespace fox_install::state
