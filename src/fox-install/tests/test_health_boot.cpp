// Runs modules/foxml_health_boot_script.hpp's script with stand-ins for fox-sec-health, loginctl, sudo and
// fox-dispatch (its two root paths swapped for a scratch dir, the stubs first on PATH). A critical or high result
// (exit 2, 3) must reach the phone alert, ok and warn (0, 1) must not, and the script always exits 0.
// Installer audit 2026-10-15: rc was set inside `{ ... } | tee`, a subshell, so the alert never fired.

#include "../modules/foxml_health_boot_script.hpp"
#include "../../fox-common/shell.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/utsname.h>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace fox_install;

namespace {

std::string slurp(const fs::path& p) {
    std::ifstream f(p);
    std::stringstream b;
    b << f.rdbuf();
    return b.str();
}

bool replace_once(std::string& s, const std::string& from, const std::string& to) {
    auto i = s.find(from);
    if (i == std::string::npos) return false;
    s.replace(i, from.size(), to);
    return true;
}

struct Result { int rc; std::string dispatched, log; bool patched; };

Result run_with_checker_exit(int checker_rc) {
    // In the build tree, not /tmp: the stubs must be executable and /tmp may be noexec.
    const fs::path t = fs::path(BUILD_DIR) / ("health_boot_" + std::to_string(::getpid()) + "_" + std::to_string(checker_rc));
    fs::remove_all(t);
    fs::create_directories(t / "bin");
    auto stub = [&](const char* name, const std::string& body) {
        std::ofstream(t / "bin" / name) << "#!/bin/sh\n" << body << "\n";
        fs::permissions(t / "bin" / name, fs::perms::owner_all, fs::perm_options::add);
    };
    stub("fox-sec-health", "echo 'fail A1 esp out of sync'; echo 'warn A2 old kernel'; exit " + std::to_string(checker_rc));
    stub("loginctl", "echo '1000 tester 1 active'");   // list-users --no-legend: UID USER ...
    stub("sudo", "while [ \"$1\" = -n ] || [ \"$1\" = -u ]; do [ \"$1\" = -u ] && shift; shift; done; exec \"$@\"");
    stub("fox-dispatch", "for a in \"$@\"; do echo \"$a\"; done >> '" + (t / "dispatched").string() + "'");

    std::string script = BOOT_HEALTH_SCRIPT;
    bool patched = replace_once(script, "/usr/local/bin/fox-sec-health", (t / "bin/fox-sec-health").string()) &&
                   replace_once(script, "LOG_DIR=/var/log/foxml", "LOG_DIR=" + (t / "log").string());
    std::ofstream(t / "health.sh") << script;

    const char* old_path = std::getenv("PATH");
    const std::string saved = old_path ? old_path : "";
    ::setenv("PATH", ((t / "bin").string() + ":/usr/bin:/bin").c_str(), 1);
    std::string journal;   // what the unit would send to the journal
    int rc = sh::probe({"bash", (t / "health.sh").string()}, journal);
    ::setenv("PATH", saved.c_str(), 1);

    Result r{rc, slurp(t / "dispatched"), slurp(t / "log/last-boot-health.txt"), patched};
    fs::remove_all(t);
    return r;
}

}  // namespace

int main() {
    int failed = 0;
    auto expect = [&](const std::string& what, bool ok) {
        if (!ok) { std::fprintf(stderr, "FAIL %s\n", what.c_str()); ++failed; }
    };
    struct utsname u {};
    ::uname(&u);
    const std::string host = u.nodename;

    for (int checker : {0, 1, 2, 3}) {
        const auto r = run_with_checker_exit(checker);
        const std::string tag = "checker exit " + std::to_string(checker) + ": ";
        expect(tag + "the script's root paths were swapped for the test", r.patched);
        expect(tag + "the script exits 0", r.rc == 0);
        expect(tag + "the log records the exit code",
               r.log.find("exit code: " + std::to_string(checker)) != std::string::npos);
        if (checker >= 2) {
            expect(tag + "the alert fires", r.dispatched.find("foxml-health-boot\n") != std::string::npos);
            expect(tag + "it names the host and the failing check",
                   r.dispatched.find("critical boot-path health fail on " + host + ": fail A1 esp out of sync") !=
                       std::string::npos);
        } else {
            expect(tag + "no alert", r.dispatched.empty());
        }
    }

    if (failed) { std::fprintf(stderr, "health_boot tests: %d FAILED\n", failed); return 1; }
    std::printf("health_boot tests: OK\n");
    return 0;
}
