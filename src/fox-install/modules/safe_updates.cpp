// modules/safe_updates.cpp — install `informant` so the no-terminal
// "Apply silently" row on the waybar updates pill is safe to use.
//
// informant is a pacman hook that refuses any transaction while there's
// unread Arch news. That's the safeguard that makes an unattended
// `pacman -Syu --noconfirm` safe: a breaking-change announcement aborts
// the upgrade instead of plowing through it. updates_menu.sh only shows
// the silent action row when `informant` is on PATH (and fails over to
// an interactive terminal on any non-zero exit), so this module is what
// flips that path on.
//
// Opt-in / default-off: informant gates EVERY pacman invocation,
// including manual ones, until the pending news is read
// (`informant read`). That's a deliberate workflow change, so the user
// chooses it rather than getting it by default.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <string>

namespace fox_install {

namespace {
std::string aur_helper() {
    if (sh::have("yay"))  return "yay";
    if (sh::have("paru")) return "paru";
    return {};
}
}  // namespace

void run_safe_updates(Context&) {
    ui::section("Safe background updates (informant news-gate)");

    if (sh::have("informant")) {
        ui::skipped("informant already installed — silent updates are gated on Arch news");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would install informant via AUR helper (yay/paru)");
        return;
    }

    std::string aur = aur_helper();
    if (aur.empty()) {
        ui::warn("no AUR helper (yay/paru) on PATH — install one, then re-run --safe-updates");
        return;
    }

    if (sh::run({aur, "-S", "--needed", "--noconfirm", "informant"}) == 0) {
        ui::ok("informant installed — unread Arch news now blocks any pacman upgrade");
        ui::substep("the updates pill's \"Apply silently\" row is now active");
        ui::substep("read pending news with: informant read");
    } else {
        ui::warn("informant install failed — \"Apply silently\" stays hidden until it's present");
    }
}

}  // namespace fox_install
