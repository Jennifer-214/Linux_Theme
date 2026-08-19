// modules/hyprlock_pam.cpp — hyprlock password-only PAM (enrollment-gated).
//
// CRITICAL: this module rewrites /etc/pam.d/hyprlock so the lock screen
// authenticates a typed password via system-auth WITHOUT a pam_fprintd
// auth line. The fingerprint is handled by hyprlock's own native
// `auth { fingerprint {} }` block (templates/hyprlock/hyprlock.conf),
// which talks to fprintd over dbus and scans CONCURRENTLY with the
// password field — so a typed password is never blocked behind a
// finger-wait (the pam_fprintd-first failure mode this whole project
// keeps tripping: memory project_pam_fprintd_lockout).
//
// Default-on, but self-gating like fprint_pam: only rewrites the PAM
// file when a reader is present AND a finger is enrolled AND
// /etc/pam.d/hyprlock exists. A no-fingerprint box is never touched —
// the distro default PAM already works there.
//
// Backup at /etc/pam.d/hyprlock.foxml-bak — recoverable if PAM breaks.
// Recovery: `su -`, restore the .foxml-bak.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <regex>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

std::string username() {
    if (const char* u = std::getenv("USER"); u && *u) return u;
    return "user";
}

// Returns true if the user has at least one enrolled fingerprint.
// (Same probe fprint_pam uses — pairs the PAM rewrite with the fprintd
// setup so a reader with no enrolment keeps the harmless default.)
bool has_enrollment() {
    std::string out;
    sh::capture({"fprintd-list", username()}, out);
    if (out.find("No fingerprints enrolled") != std::string::npos) return false;
    return std::regex_search(out, std::regex(R"(#\d+)"));
}

// Idempotency marker — written into the first comment of our PAM file.
constexpr const char* kMarker = "# foxml: hyprlock-fix";

bool already_applied(const fs::path& pam) {
    std::ifstream f(pam);
    std::string line;
    while (std::getline(f, line)) {
        if (line.find(kMarker) != std::string::npos) return true;
    }
    return false;
}

const char* kPamBody =
    "#%PAM-1.0\n"
    "# foxml: hyprlock-fix — password via system-auth; fingerprint handled natively\n"
    "# by hyprlock (auth:fingerprint over fprintd dbus), not pam_fprintd, so a typed\n"
    "# password is never blocked behind a finger-wait. Backup: hyprlock.foxml-bak.\n"
    "auth      include   system-auth\n"
    "account   include   system-auth\n"
    "password  include   system-auth\n"
    "session   include   system-auth\n";

}  // namespace

void run_hyprlock_pam(Context& ctx) {
    ui::section("hyprlock PAM (password-only + native fingerprint, enrollment-gated)");

    if (!ctx.has_fprint) {
        ui::ok("no fingerprint reader detected — leaving the default hyprlock PAM");
        return;
    }
    if (!have("fprintd-list")) {
        ui::ok("fprintd not installed — run --fprint first");
        return;
    }

    fs::path pam = "/etc/pam.d/hyprlock";
    if (!fs::exists(pam)) {
        ui::ok(pam.string() + " missing — hyprlock not installed, skipping");
        return;
    }
    if (already_applied(pam)) {
        ui::skipped("hyprlock-fix already in " + pam.string() + " — leaving as-is");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would back up " + pam.string() + ".foxml-bak and "
                    "rewrite " + pam.string() + " to a password-only system-auth "
                    "stack (fingerprint handled natively by hyprlock)");
        return;
    }

    if (!has_enrollment()) {
        ui::warn("no fingerprints enrolled for " + username() +
                 " — hyprlock PAM rewrite deferred (default password PAM already works)");
        ui::substep("enroll a finger: `fprintd-enroll`");
        ui::substep("then re-run: fox-install --only hyprlock_pam");
        return;
    }

    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first; PAM edits need root");
        return;
    }

    // Backup is create-if-missing so a second run can't clobber the
    // pre-foxml original with the already-modified file.
    sh::run({"sh", "-c",
             "[ -e " + pam.string() + ".foxml-bak ] || "
             "sudo cp " + pam.string() + " " + pam.string() + ".foxml-bak"});

    // mkstemp avoids a /tmp symlink-race against a predictable name. The
    // 0600 file in /tmp lands at /etc/pam.d/hyprlock via `sudo install`,
    // which sets the final mode/owner.
    char tmpl[] = "/tmp/foxin-pam-hyprlock-XXXXXX";
    int fd = ::mkstemp(tmpl);
    if (fd < 0) {
        ui::err("could not create temp file for hyprlock PAM");
        return;
    }
    std::string body(kPamBody);
    ssize_t w = ::write(fd, body.data(), body.size());
    ::close(fd);
    if (w != static_cast<ssize_t>(body.size())) {
        ui::err("short write to hyprlock PAM tempfile");
        ::unlink(tmpl);
        return;
    }
    int rc = sh::run({"sudo", "install", "-m", "0644", "-o", "root", "-g", "root",
                      tmpl, pam.string()});
    ::unlink(tmpl);

    if (rc == 0) {
        ui::ok("hyprlock PAM set to password-only system-auth (native fingerprint stays)");
        ui::substep("backup at " + pam.string() + ".foxml-bak");
        ui::substep("if lock-screen auth breaks: `su -`, then "
                    "`sudo mv " + pam.string() + ".foxml-bak " + pam.string() + "`");
    } else {
        ui::err("PAM install failed — original config still in place");
    }
}

}  // namespace fox_install
