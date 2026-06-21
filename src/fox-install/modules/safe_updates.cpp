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

#include <filesystem>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

// Deploy the on-demand root unit the updates pill's "Apply silently" row starts
// via `systemctl start` — auth then routes through the registered GUI polkit
// agent (fingerprint/pw dialog), not pkexec's textual agent (which needs a tty
// and fails when launched from the bar). Fixed ExecStart, no user args, no
// [Install]: not an arbitrary-root primitive and never runs at boot.
void deploy_silent_unit(const Context& ctx) {
    fs::path src = ctx.script_dir / "shared/systemd_system/foxml-apply-updates.service";
    const std::string dest = "/etc/systemd/system/foxml-apply-updates.service";
    if (!fs::exists(src)) {
        ui::warn("silent-apply unit source missing: " + src.string());
        return;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would install " + dest + " + systemctl daemon-reload");
        return;
    }
    if (!sh::sudo_warmup()) { ui::err("sudo cache cold — `sudo -v` first"); return; }
    if (sh::run({"sudo", "install", "-m", "644", src.string(), dest}) == 0) {
        sh::run({"sudo", "systemctl", "daemon-reload"});
        ui::ok("installed foxml-apply-updates.service (the pill's no-terminal silent-apply unit)");
    } else {
        ui::warn("could not install foxml-apply-updates.service — silent-apply uses the terminal fallback");
    }
}

std::string aur_helper() {
    if (sh::have("yay"))  return "yay";
    if (sh::have("paru")) return "paru";
    return {};
}
}  // namespace

void run_safe_updates(Context& ctx) {
    ui::section("Safe background updates (informant news-gate + silent-apply unit)");

    // The on-demand root unit the pill's "Apply silently" row starts via
    // systemctl (GUI-polkit auth, no terminal). Deployed regardless of the
    // informant state below so the no-terminal path exists on every run.
    deploy_silent_unit(ctx);

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
