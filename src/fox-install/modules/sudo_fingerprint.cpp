// modules/sudo_fingerprint.cpp — opt-in pam_fprintd in /etc/pam.d/sudo.
//
// Wires fingerprint into the sudo PAM stack. Default-OFF because the
// recurring lockout incident (project_pam_fprintd_lockout memory)
// came from pam_fprintd misplaced in /etc/pam.d/sudo above the
// #%PAM-1.0 header AND in front of pam_unix's `try_first_pass`,
// which silently consumed empty tokens and incremented faillock.
//
// This module refuses to run unless ALL three preconditions hold:
//   1. /etc/pam.d/sudo line 1 is the PAM-1.0 header (B1).
//   2. /etc/pam.d/system-auth's pam_unix `auth` line does NOT carry
//      `try_first_pass` (the cascade trigger; B2's lockout pattern).
//   3. pam_fprintd is not already wired into /etc/pam.d/sudo.
//
// Mirrors the greetd_fingerprint module's defensive structure
// (already_wired/has_pam_header/has fingerprints enrolled).

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

std::string username() {
    if (const char* u = std::getenv("USER"); u && *u) return u;
    return "user";
}

// Real fingerprint reader present + at least one print enrolled.
int fprintd_device_count(const std::string& user) {
    std::string out;
    sh::capture({"fprintd-list", user}, out);
    std::regex pat(R"(found (\d+) devices)");
    std::istringstream is(out);
    std::string line;
    while (std::getline(is, line)) {
        std::smatch m;
        if (std::regex_search(line, m, pat)) {
            try { return std::stoi(m[1]); } catch (...) { return 0; }
        }
    }
    return 0;
}

// fprintd-list's enrolled-finger listing is polkit-gated and fails with
// "PermissionDenied" outside an active graphical session — even when a
// finger IS enrolled (greetd / login still authenticate fine). Treat
// that denial as "can't tell", NOT as "none enrolled". pam_fprintd is
// wired `sufficient`, so the worst case (truly no finger) just falls
// through to the password prompt — never a lockout. Only refuse when a
// CLEAN read definitively shows zero enrolled fingers.
enum class Enroll { Yes, None, Unknown };

Enroll enrollment_state(const std::string& user) {
    std::string out;
    sh::capture({"fprintd-list", user}, out);
    if (out.find("\n - #") != std::string::npos
        || out.find("\t- #") != std::string::npos) {
        return Enroll::Yes;
    }
    static const char* DENIED[] = {
        "PermissionDenied", "Not Authorized", "ListEnrolledFingers failed",
        "GDBus.Error", nullptr };
    for (auto** d = DENIED; *d; ++d) {
        if (out.find(*d) != std::string::npos) return Enroll::Unknown;
    }
    return Enroll::None;  // clean read, no enrolled-finger markers
}

bool sudo_has_fprintd() {
    std::ifstream f("/etc/pam.d/sudo");
    std::string line;
    std::regex pat(R"(^\s*auth\s+\S+\s+pam_fprintd\.so)");
    while (std::getline(f, line)) {
        if (std::regex_search(line, pat)) return true;
    }
    return false;
}

bool sudo_header_at_line_one() {
    std::ifstream f("/etc/pam.d/sudo");
    std::string line;
    if (!std::getline(f, line)) return false;
    // Allow leading whitespace before #%PAM-1.0; anything BUT a
    // pam_fprintd directive on line 1 is acceptable for our purposes
    // (B1 cares specifically about pam_fprintd-above-header).
    auto nws = line.find_first_not_of(" \t");
    if (nws == std::string::npos) return false;
    return line.compare(nws, 9, "#%PAM-1.0") == 0;
}

bool system_auth_has_try_first_pass() {
    std::ifstream f("/etc/pam.d/system-auth");
    std::string line;
    // PAM control fields can be `[success=1 default=bad]` (bracketed
    // with spaces inside) — same regex shape B2 uses.
    std::regex pat(
        R"(^\s*auth\s+(?:\[[^\]]*\]|\S+)\s+pam_unix\.so[^\n]*\btry_first_pass\b)");
    while (std::getline(f, line)) {
        if (std::regex_search(line, pat)) return true;
    }
    return false;
}

}  // namespace

void run_sudo_fingerprint(Context& ctx) {
    (void)ctx;
    ui::section("Fingerprint authentication for sudo (opt-in)");

    fs::path sudo_pam = "/etc/pam.d/sudo";
    if (!fs::exists(sudo_pam)) {
        ui::ok("/etc/pam.d/sudo not present — skipping");
        return;
    }

    // Hardware + enrollment gates first — no point editing PAM if
    // there's nothing to authenticate against.
    if (sh::run({"sh", "-c", "command -v fprintd-list >/dev/null"}) != 0) {
        ui::ok("fprintd not installed — skipping (enable --fprint first)");
        return;
    }
    if (fprintd_device_count(username()) == 0) {
        ui::ok("no fingerprint reader detected — skipping");
        return;
    }
    switch (enrollment_state(username())) {
        case Enroll::None:
            ui::warn("no fingerprints enrolled for " + username() +
                     " yet — run `fprintd-enroll` first, then re-run with --sudo-fingerprint");
            return;
        case Enroll::Unknown:
            ui::warn("couldn't read enrollment — polkit denied fprintd-list (strict mode without an auth agent, or no active session)");
            ui::substep("proceeding anyway — pam_fprintd is `sufficient`, so it safely "
                        "falls through to the password prompt if no finger matches");
            break;
        case Enroll::Yes:
            break;
    }

    if (sudo_has_fprintd()) {
        ui::skipped("/etc/pam.d/sudo already has pam_fprintd — leaving as-is");
        return;
    }

    // Safety gate #1: header placement. We refuse to add pam_fprintd
    // if the existing file is already malformed (header missing or
    // pam_fprintd already at line 1), because we'd be compounding
    // the very pattern this module is supposed to avoid.
    if (!sudo_header_at_line_one()) {
        ui::err("/etc/pam.d/sudo line 1 is not `#%PAM-1.0` — refusing to splice");
        ui::substep("fix the header first (or restore from a known-good /etc/pam.d/sudo)");
        return;
    }

    // Safety gate #2: pam_unix try_first_pass interaction. This is
    // the actual lockout cascade — pam_fprintd's empty token gets
    // consumed by pam_unix's try_first_pass and silently counts as
    // a failed password attempt against faillock. Refuse to wire
    // fingerprint into sudo while that interaction is live.
    if (system_auth_has_try_first_pass()) {
        ui::err("/etc/pam.d/system-auth pam_unix carries `try_first_pass`");
        ui::substep("adding pam_fprintd here would re-open the lockout cascade");
        ui::substep("fix: sudo sed -i 's|\\(pam_unix\\.so.*\\)\\btry_first_pass\\b|\\1|' /etc/pam.d/system-auth");
        ui::substep("then re-run with --sudo-fingerprint");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would back up /etc/pam.d/sudo to .foxml-bak and "
                    "insert `auth sufficient pam_fprintd.so` after #%PAM-1.0");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::warn("sudo unavailable — skipping (rerun installer to retry)");
        return;
    }

    // Create-if-missing backup: never clobber the true pre-foxml
    // original on repeat --full runs.
    sh::run({"sh", "-c",
             "[ -e /etc/pam.d/sudo.foxml-bak ] || "
             "sudo cp /etc/pam.d/sudo /etc/pam.d/sudo.foxml-bak"});

    // Splice exactly one `auth sufficient pam_fprintd.so` line directly
    // after the #%PAM-1.0 header. `/^#%PAM-1.0/a` is sed's append-after
    // form, which preserves everything else verbatim.
    sh::run({"sudo", "sed", "-i",
             "/^#%PAM-1.0/a auth      sufficient  pam_fprintd.so",
             "/etc/pam.d/sudo"});
    ui::ok("pam_fprintd.so → /etc/pam.d/sudo (fingerprint accepts sudo prompts)");
    ui::ok("backup at /etc/pam.d/sudo.foxml-bak");
    ui::substep("touch the reader to authenticate; falls through to password prompt on timeout/fail");
    ui::substep("if you lock yourself out: `su -`, faillock --reset, then restore the .foxml-bak");
}

}  // namespace fox_install
