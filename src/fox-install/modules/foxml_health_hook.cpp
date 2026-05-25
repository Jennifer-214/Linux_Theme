// modules/foxml_health_hook.cpp — pacman post-transaction health probe.
//
// Phase 3 of plans/health-checks.md: install a pacman hook that runs
// the A + B subset of foxml-health after every transaction touching
// /etc/pam.d/*, /boot/*, /etc/fstab, /etc/default/grub, or
// /etc/mkinitcpio.conf. The hook surfaces "your system just drifted"
// the moment it happens — typically right after a pacman -Syu that
// landed a new kernel without a matching ESP copy, or a foreign
// package modifying a PAM file.
//
// Components installed:
//   /usr/local/bin/fox-sec-health         — the CLI binary, sudo-copied
//                                           from the user's $HOME build
//                                           so root-context pacman can
//                                           find it on PATH.
//   /etc/pacman.d/hooks/99-foxml-health.hook
//                                         — the trigger.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* PACMAN_HOOK =
    "# foxml-managed — run the foxml-health A + B subset after any\n"
    "# transaction that touches a path the health library cares about.\n"
    "# Failures surface immediately in pacman output, before the user\n"
    "# loses the context of which package change caused the drift.\n"
    "[Trigger]\n"
    "Operation = Install\n"
    "Operation = Upgrade\n"
    "Operation = Remove\n"
    "Type = Path\n"
    "Target = etc/pam.d/*\n"
    "Target = boot/*\n"
    "Target = etc/fstab\n"
    "Target = etc/default/grub\n"
    "Target = etc/mkinitcpio.conf\n"
    "Target = etc/security/faillock.conf\n"
    "\n"
    "[Action]\n"
    "Description = Health probe (foxml-health A + B subset)\n"
    "When = PostTransaction\n"
    "# --no-slow keeps the hook fast (skips pacman -Qkk linux which is\n"
    "# ~1s); the worst-case install of a kernel triggers boot_sync's\n"
    "# 95- hook AND this 99- hook, total under 200ms on a working host.\n"
    "Exec = /usr/local/bin/fox-sec-health --only A,B --no-slow\n"
    "Depends = bash\n"
    "AbortOnFail\n";

}  // namespace

void run_foxml_health_hook(Context& ctx) {
    ui::section("foxml-health pacman hook (post-transaction probe)");

    // Locate the freshly-built fox-sec-health binary. It lives next
    // to fox-install in the source tree.
    fs::path src_bin = ctx.script_dir / "src/fox-sec-health/fox-sec-health";
    if (!fs::exists(src_bin)) {
        ui::warn(src_bin.string() + " not built — run `make` first");
        return;
    }

    fs::path dst_bin = "/usr/local/bin/fox-sec-health";
    fs::path hook    = "/etc/pacman.d/hooks/99-foxml-health.hook";

    if (sh::dry_run()) {
        ui::substep("[dry-run] would install " + src_bin.string() + " → " + dst_bin.string()
                    + " and write " + hook.string());
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    if (sh::run({"sudo", "install", "-m", "0755", "-o", "root", "-g", "root",
                 src_bin.string(), dst_bin.string()}) != 0) {
        ui::warn("could not install " + dst_bin.string());
        return;
    }
    ui::ok(dst_bin.string() + " (root-accessible health probe)");

    if (sh::write_root_atomic(hook, PACMAN_HOOK)) {
        ui::ok(hook.string() + " (fires on PAM / boot / fstab / mkinitcpio changes)");
    } else {
        ui::warn("could not write " + hook.string());
    }
}

}  // namespace fox_install
