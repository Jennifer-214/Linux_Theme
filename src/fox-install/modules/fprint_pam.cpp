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
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
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
        ui::substep("then re-run: fox-install --only fprint_pam");
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

    // Backup + atomic replace via sudo install.
    // Backup is create-if-missing so a second run can't clobber the
    // pre-foxml original with the already-modified file.
    sh::run({"sh", "-c",
             "[ -e " + pam.string() + ".foxml-bak ] || "
             "sudo cp " + pam.string() + " " + pam.string() + ".foxml-bak"});
    // mkstemp avoids a /tmp symlink-race against a predictable name.
    // The 0600 file in /tmp lands at /etc/pam.d/X via `sudo install`,
    // which sets the final mode/owner.
    char tmpl[] = "/tmp/foxin-pam-system-XXXXXX";
    int fd = ::mkstemp(tmpl);
    if (fd < 0) {
        ui::err("could not create temp file for PAM splice");
        return;
    }
    ssize_t w = ::write(fd, spliced.data(), spliced.size());
    ::close(fd);
    if (w != static_cast<ssize_t>(spliced.size())) {
        ui::err("short write to PAM splice tempfile");
        ::unlink(tmpl);
        return;
    }
    int rc = sh::run({"sudo", "install", "-m", "0644", "-o", "root", "-g", "root",
                      tmpl, pam.string()});
    ::unlink(tmpl);

    if (rc == 0) {
        ui::ok("pam_fprintd spliced into " + pam.string());
        ui::substep("backup at " + pam.string() + ".foxml-bak");
        ui::substep("if login breaks: `su -`, then "
                    "`sudo mv " + pam.string() + ".foxml-bak " + pam.string() + "`");
    } else {
        ui::err("PAM install failed — original config still in place");
    }
}

}  // namespace fox_install
