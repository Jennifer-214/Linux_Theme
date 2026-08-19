// modules/reboot_polkit.cpp — let an active local wheel user reboot/poweroff
// without the "interactive authentication has not been enabled" hard-fail.
//
// logind counts the per-user systemd-manager session as a second session, so
// reboot/poweroff resolve to the `*-multiple-sessions` polkit actions, which
// default to auth_admin even for the active user. The `reboot`/`shutdown`
// commands call logind non-interactively, so instead of prompting they fail.
// A grant-only rule (active + local + wheel only) restores the normal
// single-user-desktop behaviour. Grant-only → it can never deny or lock out.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* LOGINCTL_RULE_BODY =
    "// foxml-managed — active local wheel user may reboot/poweroff without\n"
    "// re-auth (logind treats the systemd --user manager session as a second\n"
    "// session and otherwise demands admin auth for the active user).\n"
    "// Reverts: sudo rm /etc/polkit-1/rules.d/49-foxml-loginctl.rules\n"
    "polkit.addRule(function(action, subject) {\n"
    "    if (subject.local && subject.active && subject.isInGroup(\"wheel\") &&\n"
    "        (action.id == \"org.freedesktop.login1.reboot\" ||\n"
    "         action.id == \"org.freedesktop.login1.reboot-multiple-sessions\" ||\n"
    "         action.id == \"org.freedesktop.login1.power-off\" ||\n"
    "         action.id == \"org.freedesktop.login1.power-off-multiple-sessions\")) {\n"
    "        return polkit.Result.YES;\n"
    "    }\n"
    "});\n";

}  // namespace

void run_reboot_polkit(Context& ctx) {
    ui::section("Reboot/poweroff polkit rule");

    const fs::path rule = "/etc/polkit-1/rules.d/49-foxml-loginctl.rules";

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write " + rule.string() +
                    " (active+local+wheel → reboot/poweroff without re-auth)");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }
    // Full-file write = idempotent fixed point (not an append); polkitd
    // picks up rules.d changes automatically via inotify.
    if (idem::up_to_date(rule, LOGINCTL_RULE_BODY, ctx.force_reapply)) {
        ui::skipped("reboot/poweroff polkit rule already up to date");
        return;
    }
    if (!sh::write_root_atomic(rule, LOGINCTL_RULE_BODY)) {
        ui::err("could not write " + rule.string());
        return;
    }
    ui::ok("active local wheel users can reboot/poweroff without re-auth");
}

}  // namespace fox_install
