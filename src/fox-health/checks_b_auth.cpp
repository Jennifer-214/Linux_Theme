// checks_b_auth.cpp — B-category checks (auth stack can't get past login).
//
// Driven by the recurring `pam_fprintd` misplacement incident (twice in
// one user's history, captured in project_pam_fprintd_lockout memory).
// These checks would have caught both incidents pre-lockout.

#include "checks.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace fox_health::checks {

namespace {

bool run_capture(const std::vector<std::string>& argv, std::string& out) {
    out.clear();
    int pipefd[2];
    if (::pipe(pipefd) != 0) return false;
    pid_t pid = ::fork();
    if (pid < 0) { ::close(pipefd[0]); ::close(pipefd[1]); return false; }
    if (pid == 0) {
        ::dup2(pipefd[1], STDOUT_FILENO);
        ::close(pipefd[0]); ::close(pipefd[1]);
        int dn = ::open("/dev/null", O_WRONLY);
        if (dn >= 0) { ::dup2(dn, STDERR_FILENO); ::close(dn); }
        std::vector<char*> c_argv;
        c_argv.reserve(argv.size() + 1);
        for (auto& s : argv) c_argv.push_back(const_cast<char*>(s.c_str()));
        c_argv.push_back(nullptr);
        ::execvp(c_argv[0], c_argv.data());
        ::_exit(127);
    }
    ::close(pipefd[1]);
    char buf[4096];
    for (;;) {
        ssize_t n = ::read(pipefd[0], buf, sizeof(buf));
        if (n <= 0) break;
        out.append(buf, buf + n);
    }
    ::close(pipefd[0]);
    int status = 0;
    while (::waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

CheckResult pass(const char* id)                  { CheckResult r; r.id=id; r.status=Status::Pass; return r; }
CheckResult skip(const char* id, std::string why) { CheckResult r; r.id=id; r.status=Status::Skip; r.detail=std::move(why); return r; }
CheckResult fail(const char* id, std::string why, std::string fix={}) {
    CheckResult r; r.id=id; r.status=Status::Fail; r.detail=std::move(why); r.fix_hint=std::move(fix); return r;
}

std::vector<std::string> read_lines(const fs::path& p) {
    std::vector<std::string> out;
    std::ifstream f(p);
    std::string line;
    while (std::getline(f, line)) out.push_back(line);
    return out;
}

// Walk the include chain rooted at `pam_file` and return every line
// in resolution order. Detects cycles via a visited set so a malformed
// `include` loop can't trap us.
std::vector<std::string> resolve_pam_chain(const fs::path& pam_file) {
    std::vector<std::string> out;
    std::vector<fs::path> stack = { pam_file };
    std::vector<std::string> visited;
    std::regex inc(R"(^\s*[\w-]+\s+include\s+([^\s#]+))");
    while (!stack.empty()) {
        fs::path next = stack.back(); stack.pop_back();
        std::string key = next.string();
        bool seen = false;
        for (auto& v : visited) if (v == key) { seen = true; break; }
        if (seen) continue;
        visited.push_back(key);
        if (!fs::exists(next)) continue;
        auto lines = read_lines(next);
        for (auto& line : lines) {
            out.push_back(line);
            std::smatch m;
            if (std::regex_search(line, m, inc)) {
                fs::path inc_path = m[1].str();
                if (!inc_path.is_absolute()) {
                    inc_path = fs::path("/etc/pam.d") / inc_path;
                }
                stack.push_back(inc_path);
            }
        }
    }
    return out;
}

}  // namespace

// B1 — `/etc/pam.d/sudo` line 1 should be the `#%PAM-1.0` header
// (or any other comment/directive that isn't pam_fprintd). A line
// of `auth sufficient pam_fprintd.so` BEFORE the header is the
// canonical signature of the lockout incident: a previous installer
// or AUR script prepended the line by mistake.
CheckResult b1_sudo_header_first() {
    fs::path sudo_pam = "/etc/pam.d/sudo";
    if (!fs::exists(sudo_pam)) {
        return skip("B1", "/etc/pam.d/sudo not present (no sudo on this system?)");
    }
    auto lines = read_lines(sudo_pam);
    if (lines.empty()) {
        return fail("B1", "/etc/pam.d/sudo is empty",
            "restore from your package manager: sudo pacman -S sudo");
    }
    std::string first = lines[0];
    // Strip leading whitespace for the check.
    size_t nws = first.find_first_not_of(" \t");
    if (nws == std::string::npos) {
        return fail("B1", "/etc/pam.d/sudo: line 1 is blank",
            "first non-blank line should be `#%PAM-1.0`");
    }
    std::string head = first.substr(nws);
    if (head.rfind("pam_fprintd", 0) != std::string::npos
        || head.find("pam_fprintd") != std::string::npos) {
        return fail("B1",
            "/etc/pam.d/sudo line 1 references pam_fprintd before any other directive\n"
            "    → known lockout pattern; faillock will count password failures and lock the account\n"
            "  line was: " + first,
            "sudo sed -i '1{/pam_fprintd/d}' /etc/pam.d/sudo");
    }
    return pass("B1");
}

// B2 — actual lockout-class pattern. `pam_fprintd sufficient` is fine
// on its own (success short-circuits the chain). The dangerous case is
// when pam_fprintd's failure leaves an empty auth token in PAM state
// and a subsequent `pam_unix.so try_first_pass` consumes that empty
// token as the user's first password attempt — silently incrementing
// faillock's counter without the user typing anything.
//
// Required pattern: pam_fprintd `sufficient` BEFORE pam_unix `try_first_pass`
// in the resolved chain of the same service file.
CheckResult b2_fprintd_safe_placement() {
    static const std::vector<const char*> SERVICES = {
        "sudo", "login", "system-local-login", "system-auth",
        "hyprlock", "greetd", "passwd",
    };
    std::vector<std::string> problems;
    std::regex fprintd_sufficient(
        R"(^\s*auth\s+sufficient\s+pam_fprintd\.so)");
    // PAM control fields can be a single token (`required`, `sufficient`)
    // OR a bracketed expression with spaces inside (`[success=1 default=bad]`).
    // The bracketed form is what `system-auth` uses for the pam_unix line.
    std::regex pam_unix_tfp(
        R"(^\s*auth\s+(?:\[[^\]]*\]|\S+)\s+pam_unix\.so[^\n]*\btry_first_pass\b)");
    for (auto* svc : SERVICES) {
        fs::path pam = fs::path("/etc/pam.d") / svc;
        if (!fs::exists(pam)) continue;
        auto chain = resolve_pam_chain(pam);
        int fprintd_idx = -1;
        int tfp_idx = -1;
        for (size_t i = 0; i < chain.size(); ++i) {
            if (fprintd_idx < 0 && std::regex_search(chain[i], fprintd_sufficient)) fprintd_idx = static_cast<int>(i);
            if (tfp_idx < 0 && std::regex_search(chain[i], pam_unix_tfp)) tfp_idx = static_cast<int>(i);
        }
        if (fprintd_idx >= 0 && tfp_idx >= 0 && fprintd_idx < tfp_idx) {
            problems.push_back(std::string("/etc/pam.d/") + svc +
                ": pam_fprintd sufficient at chain position " + std::to_string(fprintd_idx) +
                " precedes pam_unix try_first_pass at position " + std::to_string(tfp_idx));
        }
    }
    if (!problems.empty()) {
        std::string detail =
            "pam_fprintd's empty-token output may be consumed by pam_unix's\n"
            "try_first_pass, silently counting failures against faillock:\n";
        for (auto& p : problems) detail += "  - " + p + "\n";
        return fail("B2", std::move(detail),
            "either drop the try_first_pass arg on pam_unix in system-auth, "
            "or move pam_fprintd AFTER pam_unix in the relevant chain");
    }
    // Pure-debug fallback for chains where one regex didn't match.
    if (const char* dbg = std::getenv("FOX_HEALTH_DEBUG_B2"); dbg && *dbg) {
        std::string det;
        for (auto* svc : SERVICES) {
            fs::path pam = fs::path("/etc/pam.d") / svc;
            if (!fs::exists(pam)) continue;
            auto chain = resolve_pam_chain(pam);
            int fp = -1, tfp = -1;
            for (size_t i = 0; i < chain.size(); ++i) {
                if (fp < 0 && std::regex_search(chain[i], fprintd_sufficient)) fp = (int)i;
                if (tfp < 0 && std::regex_search(chain[i], pam_unix_tfp)) tfp = (int)i;
            }
            det += std::string(svc) + ": chain_len=" + std::to_string(chain.size())
                + " fprintd_idx=" + std::to_string(fp)
                + " tfp_idx=" + std::to_string(tfp) + "\n";
        }
        CheckResult r; r.id = "B2"; r.status = Status::Pass; r.detail = det; return r;
    }
    return pass("B2");
}

// B3 — `faillock --user $USER` valid-entry count below the deny
// threshold. A user near lockout sees this warning before they
// actually get locked out and have to recover via su / TTY.
CheckResult b3_faillock_clear() {
    const char* user = std::getenv("USER");
    if (!user || !*user) {
        return skip("B3", "$USER unset — can't probe faillock");
    }
    std::string out;
    if (!run_capture({"faillock", "--user", user}, out) || out.empty()) {
        return skip("B3", "faillock command not available");
    }
    // Lines look like:  2026-05-24 00:13:54 TTY /dev/pts/6 V
    // Count entries with `V` in the Valid column.
    int valid = 0;
    std::istringstream is(out);
    std::string line;
    while (std::getline(is, line)) {
        // Lines after the header. The Valid column is the last token.
        if (line.empty() || line[0] == ' ' || line[0] == '\t') {}
        std::istringstream ls(line);
        std::vector<std::string> toks;
        std::string t;
        while (ls >> t) toks.push_back(t);
        if (toks.empty()) continue;
        if (toks.back() == "V") ++valid;
    }
    // Read deny= from /etc/security/faillock.conf if present, else
    // default to 3 (Arch's pam_faillock default).
    int deny = 3;
    if (fs::exists("/etc/security/faillock.conf")) {
        std::ifstream f("/etc/security/faillock.conf");
        std::string l;
        std::regex re(R"(^\s*deny\s*=\s*(\d+))");
        std::smatch m;
        while (std::getline(f, l)) {
            if (std::regex_search(l, m, re)) {
                deny = std::stoi(m[1]);
                break;
            }
        }
    }
    if (valid >= deny) {
        return fail("B3",
            "faillock counter for " + std::string(user) + " is at " +
            std::to_string(valid) + "/" + std::to_string(deny) +
            " — account is locked or one failure from lockout",
            "sudo faillock --user " + std::string(user) + " --reset");
    }
    return pass("B3");
}

}  // namespace fox_health::checks
