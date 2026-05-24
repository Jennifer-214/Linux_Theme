// modules/browser_hardening.cpp — arkenfox user.js + firejail Firefox.
//
// Three pieces (mirrors mappings.sh::install_browser_hardening):
//   1. Fetch arkenfox user.js into the default-release Firefox profile.
//      Re-download if missing or older than 30 days (arkenfox tags
//      quarterly; 30d is conservative).
//   2. Drop an empty user-overrides.js stub so users have a clear place
//      to relax arkenfox settings without editing user.js itself.
//   3. firecfg to symlink /usr/local/bin/firefox → /usr/bin/firejail so
//      every `firefox` invocation runs sandboxed, plus a
//      ~/.config/firejail/firefox.local override that pins DNS to
//      127.0.0.53 (systemd-resolved stub) — without this, the sandbox
//      can bypass the --privacy module's DoH config.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <chrono>
#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

// Discover the active Firefox profile. Prefer *.default-release (the
// default-named profile on modern Firefox), fall back to *.default
// (older versions / fresh installs).
fs::path firefox_default_profile(const Context& ctx) {
    fs::path base = ctx.home / ".mozilla/firefox";
    std::error_code ec;
    if (!fs::is_directory(base, ec)) return {};
    fs::path fallback;
    for (auto& e : fs::directory_iterator(base, ec)) {
        if (!e.is_directory()) continue;
        std::string name = e.path().filename().string();
        if (name.size() > 16 && name.substr(name.size() - 16) == ".default-release")
            return e.path();
        if (name.size() > 8 && name.substr(name.size() - 8) == ".default")
            fallback = e.path();
    }
    return fallback;
}

bool needs_refresh(const fs::path& user_js) {
    std::error_code ec;
    if (!fs::exists(user_js, ec)) return true;
    // arkenfox marker check.
    std::ifstream f(user_js);
    std::string line;
    bool has_marker = false;
    while (std::getline(f, line)) {
        if (line.find("arkenfox user.js") != std::string::npos) {
            has_marker = true;
            break;
        }
    }
    if (!has_marker) return true;
    // Age check: 30 days.
    auto last = fs::last_write_time(user_js, ec);
    if (ec) return true;
    auto age = std::chrono::system_clock::now().time_since_epoch() -
               last.time_since_epoch();
    auto days = std::chrono::duration_cast<std::chrono::hours>(age).count() / 24;
    return days > 30;
}

constexpr const char* OVERRIDES_STUB =
    "// user-overrides.js — your personal overrides for arkenfox user.js.\n"
    "//\n"
    "// Anything you set here wins over the arkenfox defaults. Common\n"
    "// relaxations on a personal laptop:\n"
    "//\n"
    "//   user_pref(\"privacy.resistFingerprinting\", false);  // breaks dark mode + screen scaling\n"
    "//   user_pref(\"browser.startup.page\", 3);              // restore previous session\n"
    "//   user_pref(\"browser.search.suggest.enabled\", true); // search suggestions\n"
    "//\n"
    "// See https://github.com/arkenfox/user.js/wiki/3.1-Overrides for the full list.\n";

constexpr const char* FIREJAIL_LOCAL_BODY =
    "# foxml-managed — Firejail Firefox overrides.\n"
    "# Pins DNS to 127.0.0.53 (systemd-resolved stub) so the sandbox can't\n"
    "# fall back to a non-DoH resolver. Without this, DNS queries from\n"
    "# inside the sandbox can bypass our --privacy module's DoH config.\n"
    "dns 127.0.0.53\n"
    "# Belt + suspenders: route a second resolver entry as backup.\n"
    "dns 127.0.0.1\n";

void do_arkenfox(const Context& ctx) {
    fs::path profile = firefox_default_profile(ctx);
    if (profile.empty()) {
        ui::ok("Firefox profile not found — launch Firefox once, then re-run --browser-hardening");
        return;
    }
    fs::path user_js   = profile / "user.js";
    fs::path overrides = profile / "user-overrides.js";

    if (needs_refresh(user_js)) {
        fs::path tmp = user_js;
        tmp += ".tmp";
        int rc = sh::run({"curl", "-fsSL", "--max-time", "30",
                          "https://raw.githubusercontent.com/arkenfox/user.js/master/user.js",
                          "-o", tmp.string()});
        if (rc == 0) {
            std::error_code ec;
            fs::rename(tmp, user_js, ec);
            ui::ok("arkenfox user.js → " + profile.string());
        } else {
            ui::warn("arkenfox download failed — network issue?");
            std::error_code ec;
            fs::remove(tmp, ec);
        }
    } else {
        ui::skipped("arkenfox user.js already up-to-date");
    }

    if (!fs::exists(overrides)) {
        std::ofstream o(overrides);
        o << OVERRIDES_STUB;
        ui::ok("user-overrides.js stub created");
    }
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
        ui::substep("[dry-run] would fetch arkenfox user.js into default-release profile, "
                    "create user-overrides.js stub, apply firejail symlinks via firecfg, "
                    "drop ~/.config/firejail/firefox.local DNS pin");
        return;
    }

    do_arkenfox(ctx);
    do_firejail(ctx);
}

}  // namespace fox_install
