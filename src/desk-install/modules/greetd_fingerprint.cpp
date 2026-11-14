// modules/greetd_fingerprint.cpp — pam_fprintd in /etc/pam.d/greetd ONLY.
//
// CRITICAL: this module only touches /etc/pam.d/greetd (the login
// screen). It does NOT touch /etc/pam.d/sudo. Misplaced pam_fprintd in
// sudo's PAM stack — specifically before faillock preauth — causes the
// password to be "eaten" by the stack and locks the account. Recovery
// requires `su -`, `faillock --reset`, restore .foxml-bak. Documented in
// memory: project_pam_fprintd_lockout.
//
// Mirrors mappings.sh::install_greetd_fingerprint. Safe insertion at
// line 1 of /etc/pam.d/greetd (greetd doesn't go through faillock).

#include "../core/context.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "pam_file.hpp"

#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>

namespace fs = std::filesystem;

namespace desk_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

// Detect fingerprint reader. fprintd-list "found N devices" — N=0 means
// no reader on any libfprint-supported bus.
int fprintd_device_count(const std::string& user) {
    std::string out;
    sh::capture({"fprintd-list", user}, out);
    std::istringstream is(out);
    std::string line;
    std::regex pat(R"(found (\d+) devices)");
    while (std::getline(is, line)) {
        std::smatch m;
        if (std::regex_search(line, m, pat)) {
            try { return std::stoi(m[1]); } catch (...) { return 0; }
        }
    }
    return 0;
}

bool already_wired(const fs::path& greetd_pam) {
    std::ifstream f(greetd_pam);
    std::string line;
    std::regex pat(R"(^\s*auth\s+sufficient\s+pam_fprintd\.so)");
    while (std::getline(f, line)) {
        if (std::regex_search(line, pat)) return true;
    }
    return false;
}

std::string username() {
    if (const char* u = std::getenv("USER"); u && *u) return u;
    return "user";
}

}  // namespace

void run_greetd_fingerprint(Context& ctx) {
    (void)ctx;
    ui::section("greetd fingerprint authentication");

    fs::path greetd_pam = "/etc/pam.d/greetd";
    if (!fs::exists(greetd_pam)) {
        ui::ok("/etc/pam.d/greetd missing (greetd not installed?) — skipping");
        return;
    }
    if (!have("fprintd-list")) {
        ui::ok("fprintd not installed — skipping");
        return;
    }
    if (fprintd_device_count(username()) == 0) {
        ui::ok("no fingerprint reader detected — skipping");
        return;
    }
    if (already_wired(greetd_pam)) {
        ui::skipped("/etc/pam.d/greetd already enables pam_fprintd — leaving as-is");
        return;
    }
    // The login screen reads system-local-login through its include: when fprint_pam put the finger step there, a
    // line here would make it ask twice (two waits before the password).
    {
        std::ifstream greeter(greetd_pam), local("/etc/pam.d/system-local-login");
        const std::string greeter_text(std::istreambuf_iterator<char>(greeter), {}), local_text(std::istreambuf_iterator<char>(local), {});
        if (pam_file::includes(greeter_text, "system-local-login") && pam_file::has_fprintd(local_text)) {
            ui::skipped("the login screen already asks for a finger through system-local-login (fprint_pam)");
            return;
        }
    }
    // The siblings' lockout gate: greetd's stack reaches system-auth through login, so the same cascade applies.
    if (pam_file::system_auth_has_try_first_pass()) {
        ui::skipped("fingerprint at the login screen skipped: /etc/pam.d/system-auth's pam_unix carries `try_first_pass`");
        ui::substep("an empty fingerprint token would count as a failed password there; see sudo_fingerprint for the fix");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would back up /etc/pam.d/greetd.foxml-bak and "
                    "insert `auth sufficient pam_fprintd.so` at PAM-header position");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::warn("sudo unavailable — skipping fingerprint PAM (rerun installer to retry)");
        return;
    }

    // After the header, or first without one; laid by pam_file (backup made once: it used to be overwritten every run,
    // so the original was lost on the second; replaced in one step, read back, restored on any difference).
    std::ifstream current(greetd_pam);
    const auto spliced = pam_file::with_fprintd(std::string(std::istreambuf_iterator<char>(current), {}), /*prepend=*/true);
    if (!spliced) { ui::skipped("/etc/pam.d/greetd already enables pam_fprintd — leaving as-is"); return; }
    if (const auto failed = pam_file::install(greetd_pam, *spliced); !failed.empty()) {
        ui::err(failed);
        return;
    }
    ui::ok("pam_fprintd.so → /etc/pam.d/greetd (login screen accepts fingerprint)");
    ui::ok("backup at /etc/pam.d/greetd.foxml-bak");

    std::string fp_list;
    sh::capture({"fprintd-list", username()}, fp_list);
    if (fp_list.find("\n - #") == std::string::npos) {
        ui::ok("no fingerprints enrolled for " + username() +
               " yet — run: fprintd-enroll");
    }
}

}  // namespace desk_install
