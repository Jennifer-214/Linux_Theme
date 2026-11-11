// modules/browser_hardening.cpp — arkenfox user.js + firejail Firefox.
//
// Three pieces:
//   1. Fetch arkenfox user.js into the profile Firefox opens (profiles.ini).
//      Re-download if missing or older than 30 days (arkenfox tags
//      quarterly; 30d is conservative).
//   2. A user-overrides.js with laptop-friendly relaxations, copied into
//      user.js after arkenfox — Firefox never reads that file itself.
//      The lines other steps keep in user.js stay after both.
//   3. firecfg to symlink /usr/local/bin/firefox → /usr/bin/firejail so
//      every `firefox` invocation runs sandboxed, plus a
//      ~/.config/firejail/firefox.local override that pins DNS to
//      127.0.0.53 (systemd-resolved stub) — without this, the sandbox
//      can bypass the --privacy module's DoH config.

#include "../core/context.hpp"
#include "../core/backup.hpp"
#include "../core/idempotency.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "arkenfox_userjs.hpp"
#include "firefox_appearance.hpp"

#include <chrono>
#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

bool older_than_days(const fs::path& file, int days) {
    std::error_code ec;
    auto last = fs::last_write_time(file, ec);
    if (ec) return true;
    auto age = fs::file_time_type::clock::now() - last;
    return std::chrono::duration_cast<std::chrono::hours>(age).count() / 24 > days;
}

constexpr const char* OVERRIDES_STUB =
    "// user-overrides.js — your changes to arkenfox's user.js.\n"
    "//\n"
    "// Firefox only reads user.js, so the installer copies this file into it, after arkenfox,\n"
    "// on its next run; these lines win. The four below keep a personal laptop comfortable.\n"
    "// Delete one to get arkenfox's stricter setting back.\n"
    "\n"
    "user_pref(\"browser.startup.page\", 3);                             // reopen last session's tabs\n"
    "user_pref(\"privacy.clearOnShutdown_v2.cookiesAndStorage\", false); // stay signed in after closing Firefox\n"
    "user_pref(\"browser.newtabpage.enabled\", true);                    // the themed new tab page, not a blank one\n"
    "user_pref(\"browser.startup.homepage\", \"about:home\");              // and the same page for Home\n"
    "\n"
    "// More: https://github.com/arkenfox/user.js/wiki/3.1-Overrides\n";

constexpr const char* FIREJAIL_LOCAL_BODY =
    "# foxml-managed — Firejail Firefox overrides.\n"
    "# Pins DNS to 127.0.0.53 (systemd-resolved stub) so the sandbox can't\n"
    "# fall back to a non-DoH resolver. Without this, DNS queries from\n"
    "# inside the sandbox can bypass our --privacy module's DoH config.\n"
    "dns 127.0.0.53\n"
    "# Belt + suspenders: route a second resolver entry as backup.\n"
    "dns 127.0.0.1\n";

void do_arkenfox(const Context& ctx) {
    fs::path profile = firefox_appearance::profile(ctx);
    if (profile.empty()) {
        ui::ok("Firefox profile not found — launch Firefox once, then re-run --browser-harden");
        return;
    }
    fs::path user_js   = profile / "user.js";
    fs::path overrides = profile / "user-overrides.js";

    std::error_code ec;
    if (!fs::exists(overrides, ec)) {
        if (idem::write_atomic(overrides, OVERRIDES_STUB)) ui::ok("user-overrides.js created (session restore, sign-ins kept)");
        else ui::warn("could not create user-overrides.js");
    }

    const std::string old = idem::read_file(user_js);
    std::string base = arkenfox::arkenfox_part(old);
    const bool stale = base.empty() || older_than_days(user_js, 30);
    const bool overrides_newer = fs::exists(user_js, ec) && fs::exists(overrides, ec) &&
                                 fs::last_write_time(overrides, ec) > fs::last_write_time(user_js, ec);
    if (!stale && arkenfox::has_overrides(old) && !overrides_newer) {
        ui::skipped("arkenfox user.js already up-to-date");
        return;
    }

    if (stale) {
        fs::path tmp = user_js;
        tmp += ".arkenfox-tmp";
        int rc = sh::run({"curl", "-fsSL", "--max-time", "30",
                          "https://raw.githubusercontent.com/arkenfox/user.js/master/user.js",
                          "-o", tmp.string()});
        std::string download = rc == 0 ? idem::read_file(tmp) : std::string();
        fs::remove(tmp, ec);
        if (arkenfox::complete(download)) base = download;
        else if (base.empty()) {
            ui::warn("arkenfox download failed or was cut off; user.js left as it was");
            return;
        } else ui::warn("arkenfox download failed; keeping the copy already in user.js");
    }

    const std::string next = arkenfox::compose(base, idem::read_file(overrides), old);
    if (next == old) {
        ui::skipped("arkenfox user.js already up-to-date");
        return;
    }
    if (!snapshot_one(ctx, user_js) || !idem::write_atomic(user_js, next)) {
        ui::warn("could not write Firefox user.js; leaving the previous file intact");
        return;
    }
    ui::ok("arkenfox user.js → " + profile.string() + " (with user-overrides.js and the theme's lines)");
}

void do_firejail(const Context& ctx) {
    if (!have("firejail")) return;

    fs::path symlink = "/usr/local/bin/firefox";
    bool already_wired = false;
    std::error_code ec;
    if (fs::is_symlink(symlink, ec)) {
        fs::path target = fs::read_symlink(symlink, ec);
        if (target.string().find("firejail") != std::string::npos) {
            already_wired = true;
        }
    }
    if (!already_wired || ctx.force_reapply) {
        if (sh::run({"sh", "-c", "sudo firecfg >/dev/null 2>&1"}) == 0) {
            ui::ok("firejail symlinks applied (firefox now runs sandboxed)");
        }
    } else {
        ui::skipped("firejail already wired for firefox");
    }

    // Walk back firecfg's overreach. The default firecfg wraps ~60
    // binaries in /usr/local/bin/<name> → /usr/bin/firejail symlinks,
    // and several of them are critically broken under the sandbox:
    //
    //   ssh / ssh-add / ssh-agent / ssh-keygen / ssh-askpass
    //     — inside firejail, /dev/shm is a private noexec tmpfs;
    //       gdk-pixbuf can't memfd_create() and ssh-askpass dies
    //       loading the Papirus icon set (the user-visible symptom
    //       is "Memfd: cannot create a memfd" + git push failure).
    //   gnome-keyring / gnome-keyring-3 / gnome-keyring-daemon
    //     — running the keyring inside a sandbox defeats the whole
    //       SSH+GPG+secrets agent layer keyring_full sets up.
    //   gh — the GitHub CLI needs free access to ~/.ssh.
    //
    // Remove these symlinks unconditionally; this is idempotent
    // (re-runs are no-ops if the symlinks aren't there).
    static const char* UNJAIL[] = {
        "ssh", "ssh-add", "ssh-agent", "ssh-keygen", "ssh-askpass",
        "gnome-keyring", "gnome-keyring-3", "gnome-keyring-daemon",
        "gh",
        nullptr,
    };
    int removed = 0;
    for (auto** name = UNJAIL; *name; ++name) {
        fs::path link = std::string("/usr/local/bin/") + *name;
        std::error_code lec;
        if (!fs::is_symlink(link, lec)) continue;
        fs::path tgt = fs::read_symlink(link, lec);
        if (tgt.string().find("firejail") == std::string::npos) continue;
        if (sh::run({"sudo", "rm", link.string()}) == 0) ++removed;
    }
    if (removed > 0) {
        ui::ok("de-jailed " + std::to_string(removed) +
               " ssh/keyring/gh binaries (firejail breaks SSH agent + memfd)");
    }

    fs::path firejail_dir = ctx.config_home / "firejail";
    fs::path local        = firejail_dir / "firefox.local";
    fs::create_directories(firejail_dir);

    bool needs_write = true;
    if (fs::exists(local)) {
        std::ifstream f(local);
        std::string line;
        while (std::getline(f, line)) {
            if (line.find("# foxml-managed") != std::string::npos) {
                needs_write = false;
                break;
            }
        }
    }
    if (needs_write || ctx.force_reapply) {
        std::ofstream o(local);
        o << FIREJAIL_LOCAL_BODY;
        ui::ok("firejail firefox.local override (DNS pinned to 127.0.0.53 for DoH)");
    } else {
        ui::skipped("firejail firefox.local already configured");
    }
}

}  // namespace

void run_browser_hardening(Context& ctx) {
    ui::section("Browser hardening (arkenfox + firejail Firefox)");

    if (!have("firefox")) {
        ui::ok("firefox not installed, skipping browser hardening");
        return;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would fetch arkenfox user.js into the profile Firefox opens, "
                    "copy user-overrides.js in after it (keeping the theme's lines, with a backup), "
                    "apply firejail symlinks via firecfg, "
                    "drop ~/.config/firejail/firefox.local DNS pin");
        return;
    }

    do_arkenfox(ctx);
    do_firejail(ctx);
}

}  // namespace fox_install
