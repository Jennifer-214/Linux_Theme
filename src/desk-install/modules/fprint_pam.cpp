// modules/fprint_pam.cpp — fprintd PAM splice (enrollment-gated).
//
// CRITICAL: this module touches /etc/pam.d/system-local-login (the
// console-login PAM stack), NOT /etc/pam.d/sudo. pam_fprintd in
// /etc/pam.d/sudo BEFORE faillock preauth has caused account lockouts
// in this project before (memory: project_pam_fprintd_lockout). The
// safer pattern, mirroring install.sh.legacy's --deps section: splice
// only into system-local-login, only AFTER the pam_faillock preauth /
// pam_env anchor lines, only when a fingerprint is actually enrolled.
//
// Off by default. Run explicitly with --fprint-pam, after `--fprint`
// installs fprintd and `fprintd-enroll` has registered a finger.
//
// Backup at /etc/pam.d/system-local-login.foxml-bak — recoverable if
// PAM breaks. Recovery: `su -`, restore the .foxml-bak, faillock --reset.

#include "../core/context.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "pam_file.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

namespace desk_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

std::string username() {
    if (const char* u = std::getenv("USER"); u && *u) return u;
    return "user";
}

// Returns true if the user has at least one enrolled fingerprint.
bool has_enrollment() {
    std::string out;
    sh::capture({"fprintd-list", username()}, out);
    // fprintd-list emits lines like "  - #1: right-index-finger" when
    // an enrollment exists, "No fingerprints enrolled" when not.
    if (out.find("No fingerprints enrolled") != std::string::npos) return false;
    return std::regex_search(out, std::regex(R"(#\d+)"));
}

bool already_spliced(const fs::path& pam) {
    std::ifstream f(pam);
    std::string line;
    while (std::getline(f, line)) {
        if (line.find("pam_fprintd") != std::string::npos) return true;
    }
    return false;
}

// Mirror the bash awk insert logic: place
//     auth sufficient pam_fprintd.so
// AFTER the last preauth/env anchor in the file (so fprintd checks
// AFTER faillock has had a chance to bump the fail counter), falling
// back to "before the first auth line" if no anchor exists. Preserves
// rate-limit + lockout semantics.
std::string splice_pam(const std::string& body) {
    std::vector<std::string> lines;
    {
        std::istringstream is(body);
        std::string l;
        while (std::getline(is, l)) lines.push_back(l);
    }

    std::regex anchor(R"(^auth\s+.*pam_(faillock\.so.*preauth|env\.so))");
    int last_preauth = -1;
    int first_auth   = -1;
    for (int i = 0; i < (int)lines.size(); ++i) {
        if (std::regex_search(lines[i], anchor)) last_preauth = i;
        if (first_auth < 0 &&
            std::regex_search(lines[i], std::regex(R"(^auth\s+)"))) {
            first_auth = i;
        }
    }
    int insert_after = last_preauth;
    if (insert_after < 0) insert_after = first_auth - 1;
    if (insert_after < 0) insert_after = -1;     // file has no auth lines

    std::ostringstream out;
    bool printed = false;
    for (int i = 0; i < (int)lines.size(); ++i) {
        out << lines[i] << "\n";
        if (!printed && i == insert_after) {
            out << "auth      sufficient   pam_fprintd.so\n";
            printed = true;
        }
    }
    if (!printed) {
        // No auth lines at all — append at the bottom (shouldn't
        // happen on a sane PAM stack; safe fallback).
        out << "auth      sufficient   pam_fprintd.so\n";
    }
    return out.str();
}

}  // namespace

void run_fprint_pam(Context& ctx) {
    ui::section("fprintd PAM splice (system-local-login, enrollment-gated)");

    if (!ctx.has_fprint) {
        ui::ok("no fingerprint reader detected — skipping");
        return;
    }
    if (!have("fprintd-list")) {
        ui::ok("fprintd not installed — run --fprint first");
        return;
    }

    fs::path pam = "/etc/pam.d/system-local-login";
    if (!fs::exists(pam)) {
        ui::warn(pam.string() + " missing — skipping (login PAM stack absent)");
        return;
    }
    if (already_spliced(pam)) {
        ui::skipped("pam_fprintd already in " + pam.string() + " — leaving as-is");
        return;
    }

    // Lockout guard (mirrors sudo_fingerprint's gate #2). splice_pam
    // inserts pam_fprintd ahead of the included login block; that's the
    // correct spot for fingerprint-OR-password ONLY while pam_unix has no
    // `try_first_pass`. With it, the empty fprintd token is counted as a
    // failed password and faillock locks the account. Refuse outright.
    if (pam_file::system_auth_has_try_first_pass()) {
        ui::skipped("fingerprint login skipped: /etc/pam.d/system-auth's pam_unix carries `try_first_pass` (stock Arch)");
        ui::substep("splicing pam_fprintd into the login stack would re-open the lockout cascade");
        ui::substep("fix: sudo sed -i 's|\\(pam_unix\\.so.*\\)\\btry_first_pass\\b|\\1|' /etc/pam.d/system-auth");
        ui::substep("then re-run with --fprint-pam");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would back up " + pam.string() + ".foxml-bak and "
                    "splice `auth sufficient pam_fprintd.so` after the last "
                    "pam_faillock.so preauth / pam_env.so anchor");
        return;
    }

    if (!has_enrollment()) {
        ui::warn("no fingerprints enrolled for " + username() +
                 " — PAM splice deferred (would 30s-hang every sudo otherwise)");
        ui::substep("enroll a finger: `fprintd-enroll`");
        ui::substep("then re-run: desk-install --only fprint_pam");
        return;
    }

    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first; PAM edits need root");
        return;
    }

    // Read the world-readable PAM file as the calling user.
    std::ifstream f(pam);
    std::string body((std::istreambuf_iterator<char>(f)),
                      std::istreambuf_iterator<char>());
    std::string spliced = splice_pam(body);

    // Laid by pam_file: backup made once, replaced in one step, read back, the previous file restored on any difference.
    if (const auto failed = pam_file::install(pam, spliced); !failed.empty()) {
        ui::err(failed);
        return;
    }
    ui::ok("pam_fprintd spliced into " + pam.string());
    ui::substep("backup at " + pam.string() + ".foxml-bak");
    ui::substep("if login breaks: `su -`, then "
                "`sudo mv " + pam.string() + ".foxml-bak " + pam.string() + "`");
}

}  // namespace desk_install
