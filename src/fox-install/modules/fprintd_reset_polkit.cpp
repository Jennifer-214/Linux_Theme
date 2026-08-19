// modules/fprintd_reset_polkit.cpp — let an active local wheel user restart
// fprintd.service without re-auth, so the lock/unlock self-heal can clear a
// wedged fingerprint reader silently.
//
// Synaptics-class readers get stuck "Device already claimed" after an
// interrupted hyprlock/greetd verify (libfprint close transfer-timeout); the
// reader then refuses pam_fprintd's Claim for sudo and the prompt silently
// falls back to a password. `fox fingerprint reset` (wired into fox-lock +
// fox-unlock-hook) bounces fprintd to recover. That restart resolves to
// polkit's systemd1.manage-units action, which defaults to auth_admin — this
// grant-only rule (active + local + wheel, scoped to fprintd.service ONLY)
// makes the self-heal password-less. Grant-only → it can never deny or lock
// out. Mirrors reboot_polkit's structure.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* FPRINTD_RULE_BODY =
    "// foxml-managed — active local wheel user may restart fprintd.service\n"
    "// without re-auth, so the lock/unlock self-heal can clear a wedged\n"
    "// fingerprint reader (libfprint \"Device already claimed\" after an\n"
    "// interrupted verify) silently. Scoped to fprintd.service only.\n"
    "// Reverts: sudo rm /etc/polkit-1/rules.d/49-foxml-fprintd.rules\n"
    "polkit.addRule(function(action, subject) {\n"
    "    if (subject.local && subject.active && subject.isInGroup(\"wheel\") &&\n"
    "        action.id == \"org.freedesktop.systemd1.manage-units\" &&\n"
    "        action.lookup(\"unit\") == \"fprintd.service\") {\n"
    "        var verb = action.lookup(\"verb\");\n"
    "        if (verb == \"restart\" || verb == \"try-restart\" ||\n"
    "            verb == \"start\" || verb == \"stop\" ||\n"
    "            verb == \"reload-or-restart\") {\n"
    "            return polkit.Result.YES;\n"
    "        }\n"
    "    }\n"
    "});\n";

}  // namespace

void run_fprintd_reset_polkit(Context& ctx) {
    ui::section("fprintd-restart polkit rule (fingerprint self-heal)");

    // Only meaningful once fprintd is installed (the fprint module, which
    // runs earlier in Phase 5). Harmless otherwise — skip to keep
    // non-fingerprint machines free of a dead grant.
    if (!sh::have("fprintd-list")) {
        ui::ok("fprintd not installed — skipping (enable --fprint first)");
        return;
    }

    const fs::path rule = "/etc/polkit-1/rules.d/49-foxml-fprintd.rules";

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write " + rule.string() +
                    " (active+local+wheel → restart fprintd.service without re-auth)");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }
    // Full-file write = idempotent fixed point (not an append); polkitd
    // picks up rules.d changes automatically via inotify.
    if (idem::up_to_date(rule, FPRINTD_RULE_BODY, ctx.force_reapply)) {
        ui::skipped("fprintd-restart polkit rule already up to date");
        return;
    }
    if (!sh::write_root_atomic(rule, FPRINTD_RULE_BODY)) {
        ui::err("could not write " + rule.string());
        return;
    }
    ui::ok("active local wheel users can restart fprintd without re-auth (finger self-heal)");
}

}  // namespace fox_install
