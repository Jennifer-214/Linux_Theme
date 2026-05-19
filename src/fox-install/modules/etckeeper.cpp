// modules/etckeeper.cpp — git-track /etc + drift watcher.
//
// 1. Install etckeeper (AUR-first, falls back to pacman if no AUR helper).
// 2. `etckeeper init` if /etc/.git doesn't exist yet.
// 3. Ensure root has a default git identity so etckeeper commits succeed.
// 4. Catch-up commit (silent if clean).
// 5. fox-etcwatch.path systemd-user unit — alerts when sensitive /etc
//    subdirs change OUTSIDE etckeeper commits (skips alerts within 30s
//    of an etckeeper commit by checking /etc/.git/HEAD mtime).

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) {
    std::string out;
    return sh::capture({"sh", "-c", "command -v " + bin}, out) && !out.empty();
}

void install_via_pkg() {
    if (have("yay")) {
        sh::run({"sh", "-c", "yay -S --needed --noconfirm etckeeper >/dev/null 2>&1 || true"});
    } else if (have("paru")) {
        sh::run({"sh", "-c", "paru -S --needed --noconfirm etckeeper >/dev/null 2>&1 || true"});
    } else {
        sh::run({"sh", "-c", "sudo pacman -S --needed --noconfirm etckeeper >/dev/null 2>&1 || true"});
    }
}

constexpr const char* PATH_UNIT =
    "[Unit]\n"
    "Description=fox-etcwatch — alert on changes to sensitive /etc subdirs\n"
    "\n"
    "[Path]\n"
    "PathChanged=/etc/ssh\n"
    "PathChanged=/etc/sudoers.d\n"
    "PathChanged=/etc/pam.d\n"
    "PathChanged=/etc/ufw\n"
    "PathChanged=/etc/fail2ban\n"
    "PathChanged=/etc/audit/rules.d\n"
    "PathChanged=/etc/sysctl.d\n"
    "\n"
    "[Install]\n"
    "WantedBy=default.target\n";

constexpr const char* SERVICE_UNIT =
    "[Unit]\n"
    "Description=fox-etcwatch — dispatch /etc change\n"
    "\n"
    "[Service]\n"
    "Type=oneshot\n"
    "# Suppress alerts that fire from etckeeper's own commits — if\n"
    "# /etc/.git/HEAD was touched in the last 30s, it's almost certainly\n"
    "# etckeeper rather than an out-of-band edit. user systemd units have\n"
    "# no TTY for sudo prompts, so we stat the dir entry instead of git-logging.\n"
    "ExecStart=/bin/sh -c 'head_mtime=$(stat -c %Y /etc/.git/HEAD 2>/dev/null || echo 0); "
        "now=$(date +%s); age=$((now - head_mtime)); "
        "if [ \"$age\" -gt 30 ]; then "
        "fox-dispatch \"etc-change\" "
        "\"/etc modified outside an etckeeper commit (paths: ssh/sudoers.d/pam.d/ufw/fail2ban/audit/sysctl.d). "
        "Run: sudo etckeeper unclean\" 2>/dev/null || true; "
        "fi'\n";

}  // namespace

void run_etckeeper(Context& ctx) {
    ui::section("etckeeper — git-track /etc + drift watcher");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would install etckeeper, init /etc/.git, configure root "
                    "git identity, drop fox-etcwatch.path user unit");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    if (!have("etckeeper")) install_via_pkg();
    if (!have("etckeeper")) {
        ui::warn("etckeeper install failed — skipping");
        return;
    }

    if (!fs::is_directory("/etc/.git")) {
        sh::run({"sh", "-c", "sudo etckeeper init >/dev/null 2>&1 || true"});
        ui::ok("etckeeper initialised /etc/.git");
    } else {
        ui::skipped("etckeeper already initialised in /etc");
    }

    // Root identity for etckeeper commits.
    sh::run({"sh", "-c",
             "sudo git -C /etc config user.email \"etckeeper@$(uname -n)\" 2>/dev/null || true"});
    sh::run({"sh", "-c",
             "sudo git -C /etc config user.name  \"etckeeper\" 2>/dev/null || true"});
    sh::run({"sh", "-c",
             "sudo etckeeper commit \"foxml: /etc snapshot\" >/dev/null 2>&1 || true"});

    fs::path units = ctx.config_home / "systemd/user";
    fs::path path_unit = units / "fox-etcwatch.path";
    fs::path svc_unit  = units / "fox-etcwatch.service";

    if (!fs::exists(path_unit) || ctx.force_reapply) {
        fs::create_directories(units);

        // 1. Unmask aggressively + flush systemd's cached view BEFORE
        //    writing the new unit body. The explicit daemon-reload
        //    matters: without it, the eventual enable() races with
        //    systemd's async cache refresh and still sees a stale
        //    "masked" state — which is the bug fox-install reported
        //    on a previous run even though the on-disk mask symlinks
        //    were already gone.
        sh::run({"systemctl", "--user", "unmask",
                 "fox-etcwatch.path", "fox-etcwatch.service"});
        sh::systemctl_daemon_reload(/*user=*/true);

        // 2. Belt-and-suspenders: drop any leftover /dev/null symlinks
        //    at our target paths so the upcoming ofstream creates a
        //    real file instead of writing through a dead symlink.
        std::error_code ec;
        if (fs::is_symlink(path_unit, ec)) fs::remove(path_unit, ec);
        if (fs::is_symlink(svc_unit,  ec)) fs::remove(svc_unit,  ec);

        // 3. Write the real unit bodies + reload so systemd sees them.
        std::ofstream p(path_unit);     p << PATH_UNIT;
        std::ofstream s(svc_unit);      s << SERVICE_UNIT;
        sh::systemctl_daemon_reload(/*user=*/true);

        // 4. Clear any previous failure state. The .path triggers the
        //    .service on every /etc write, and during a --full install
        //    /etc changes a lot — easily hits Restart= rate limit and
        //    leaves the unit in "failed (unit-start-limit-hit)". The
        //    reset-failed below makes the freshly-enabled unit start
        //    clean instead of inheriting that limit-hit state.
        sh::run({"systemctl", "--user", "reset-failed",
                 "fox-etcwatch.path", "fox-etcwatch.service"});

        if (sh::systemctl_enable("fox-etcwatch.path", /*user=*/true) == 0) {
            ui::ok("fox-etcwatch.path enabled (alerts on /etc/{ssh,sudoers.d,pam.d,ufw,fail2ban,audit,sysctl.d} changes)");
        } else {
            ui::warn("fox-etcwatch.path enable failed — try `systemctl --user unmask fox-etcwatch.path` then re-run --etckeeper");
        }
    } else {
        ui::skipped("fox-etcwatch already configured");
    }
}

}  // namespace fox_install
