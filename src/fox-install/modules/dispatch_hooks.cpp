// modules/dispatch_hooks.cpp — phone-alert wiring (fail2ban + fox-bouncer + fox-sentry-audit).
//
// Mirrors mappings.sh::install_dispatch_hooks:
//   1. Install foxml-fail2ban-notify helper to /usr/local/bin/.
//   2. fail2ban: drop action.d/foxml-dispatch.conf + splice the action
//      into jail.local's [sshd] section. Self-heals existing
//      foxml-dispatch action stanzas (the original idempotency grep was
//      broken because the inserted text spans two lines).
//   3. fox-bouncer user service (USB-blocked-while-locked alerts).
//   4. fox-sentry-audit user service (kernel-level honeypot via auditd).
//   5. Interactive offer to run `fox-dispatch --setup` if no webhook
//      config exists yet. Skipped under --yes / no-TTY.
//
// All sub-steps are idempotent; missing fox-* binaries are skipped silently.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }
bool pacman_has(const std::string& pkg) {
    return sh::run({"sh", "-c", "pacman -Qi " + pkg + " &>/dev/null"}) == 0;
}
bool tty_in() { return ::isatty(STDIN_FILENO); }

std::string username() {
    if (const char* u = std::getenv("USER"); u && *u) return u;
    return "user";
}

void install_helper_script(const Context& ctx) {
    fs::path src = ctx.script_dir / "shared/bin/foxml-fail2ban-notify";
    if (!fs::exists(src)) return;
    if (sh::run({"sudo", "install", "-m", "0755",
                 src.string(),
                 "/usr/local/bin/foxml-fail2ban-notify"}) == 0) {
        ui::ok("foxml-fail2ban-notify installed to /usr/local/bin/");
    } else {
        ui::warn("couldn't install fail2ban-notify helper (sudo cold?)");
    }
}

void wire_fail2ban() {
    if (!pacman_has("fail2ban") || !have("fox-dispatch")) {
        ui::ok("fail2ban or fox-dispatch missing — skipping ban-hook");
        return;
    }

    // Action drop-in.
    std::string action_body =
        "# foxml-managed — fires fox-dispatch on every fail2ban ban.\n"
        "[Definition]\n"
        "actionban  = /usr/local/bin/foxml-fail2ban-notify <ip> <name> <failures> " + username() + "\n"
        "actionunban = /bin/true\n"
        "[Init]\n";

    sh::write_root_atomic("/etc/fail2ban/action.d/foxml-dispatch.conf", action_body);
    ui::ok("fail2ban action.d/foxml-dispatch.conf written");

    // Splice into jail.local: dedupe existing stanzas first (gawk inplace),
    // then insert exactly one after the [sshd] header.
    if (fs::exists("/etc/fail2ban/jail.local")) {
        sh::run({"sh", "-c",
                 "sudo gawk -i inplace '"
                 "/^action[[:space:]]*=[[:space:]]*%\\(action_\\)s[[:space:]]*$/ {"
                 "getline next_line; "
                 "if (next_line ~ /^[[:space:]]+foxml-dispatch[[:space:]]*$/) { next } "
                 "else { print; print next_line; next } "
                 "} "
                 "{ print } "
                 "' /etc/fail2ban/jail.local"});
        sh::run({"sudo", "chmod", "644", "/etc/fail2ban/jail.local"});
        sh::run({"sudo", "sed", "-i",
                 R"(/^\[sshd\]/a action = %(action_)s\n         foxml-dispatch)",
                 "/etc/fail2ban/jail.local"});
        ui::ok("jail.local sshd → exactly one foxml-dispatch action (deduped)");
    }

    // Single validation + restart point.
    if (sh::run({"sh", "-c", "sudo fail2ban-client -t >/dev/null 2>&1"}) == 0) {
        if (sh::run({"sh", "-c",
                     "sudo systemctl restart fail2ban >/dev/null 2>&1"}) == 0) {
            ui::ok("fail2ban restarted — phone alerts live");
        } else {
            ui::warn("fail2ban restart failed — `systemctl status fail2ban`");
        }
    } else {
        ui::warn("fail2ban-client -t fails — leaving daemon as-is; diagnose: sudo fail2ban-client -t");
    }
}

void wire_fox_service(const Context& ctx,
                      const std::string& bin, const std::string& unit_name,
                      const std::string& install_msg) {
    if (!have(bin)) return;
    if (sh::run({"systemctl", "--user", "is-enabled", "--quiet",
                 unit_name + ".service"}) == 0
        && !ctx.force_reapply) {
        ui::skipped(bin + " already enabled");
        return;
    }
    if (sh::run({"sh", "-c", bin + " --install >/dev/null 2>&1"}) == 0) {
        ui::ok(install_msg);
    } else {
        ui::warn(bin + " install failed (run manually: " + bin + " --install)");
    }
}

void maybe_offer_setup(const Context& ctx) {
    if (!tty_in() || ctx.assume_yes) return;

    fs::path conf       = ctx.config_home / "foxml/dispatch.conf";
    fs::path marker     = ctx.config_home / "foxml/.skipped-dispatch";

    if (fs::exists(conf))   { ui::skipped("fox-dispatch webhook already configured"); return; }
    if (fs::exists(marker)) { ui::ok("fox-dispatch previously declined — remove " +
                                      marker.string() + " to re-prompt"); return; }
    if (!have("fox-dispatch")) return;

    std::cout << "\n  fox-dispatch (phone alerts) is not yet configured.\n";
    if (ui::ask_yn("  Set up Discord/Telegram webhook now?",
                   /*default_yes=*/false, ctx.assume_yes)) {
        sh::run({"fox-dispatch", "--setup"});
    } else {
        fs::create_directories(marker.parent_path());
        std::ofstream f(marker);
        ui::ok("declined — run later: fox-dispatch --setup");
    }
}

}  // namespace

void run_dispatch_hooks(Context& ctx) {
    ui::section("Phone-alert wiring (fox-dispatch / fail2ban / bouncer / sentry-audit)");

    if (!have("fox-dispatch")) {
        ui::ok("fox-dispatch binary not installed — skipping wiring (re-run after --deps)");
        return;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would install fail2ban-notify helper, wire foxml-dispatch "
                    "action into jail.local, enable fox-bouncer + fox-sentry-audit user "
                    "services, optionally prompt for fox-dispatch --setup");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    install_helper_script(ctx);
    wire_fail2ban();
    wire_fox_service(ctx, "fox-bouncer",      "fox-bouncer",      "fox-bouncer.service enabled");
    if (pacman_has("audit")) {
        wire_fox_service(ctx, "fox-sentry-audit", "fox-sentry-audit",
                          "fox-sentry-audit.service enabled (kernel-level honeypot)");
    }
    maybe_offer_setup(ctx);
}

}  // namespace fox_install
