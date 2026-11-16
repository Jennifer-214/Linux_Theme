// Runs the fox-etcwatch service's own command (modules/etcwatch_units.hpp, through tests/unit_exec.hpp) with a stand-in
// desk-dispatch first on PATH and a scratch commit stamp. On 2026-11-15 an install's burst of /etc writes started the
// service six times in six seconds; systemd's default start limit failed it, passed the failure on to
// fox-etcwatch.path, and the watcher stayed off until reset.
//   - the service has no start limit, set in [Unit] where systemd reads it;
//   - a change long after the last etckeeper commit alerts; the rest of a burst, inside a minute, does not;
//   - a minute on it alerts again; within 30 s of an etckeeper commit it does not;
//   - a garbled marker does not silence it;
//   - the state check's comparison: the old service body is out of date.

#include "../modules/etcwatch_units.hpp"
#include "unit_exec.hpp"
#include "../../desk-common/shell.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace desk_install;

namespace {

int failed = 0;
void expect(const std::string& what, bool ok) {
    if (!ok) { std::fprintf(stderr, "FAIL %s\n", what.c_str()); ++failed; }
}

std::string slurp(const fs::path& p) {
    std::ifstream f(p);
    std::stringstream b;
    b << f.rdbuf();
    return b.str();
}

// The etckeeper commit stamp, `seconds` old.
void stamp_age(const fs::path& stamp, long seconds) {
    std::ofstream(stamp) << "";
    const std::time_t when = std::time(nullptr) - seconds;
    const struct timespec times[2] = {{when, 0}, {when, 0}};
    ::utimensat(AT_FDCWD, stamp.c_str(), times, 0);
}

}  // namespace

int main() {
    const std::string unit = ETCWATCH_SERVICE_UNIT;
    const auto unit_at = unit.find("[Unit]"), service_at = unit.find("[Service]");
    const auto limit_at = unit.find("\nStartLimitIntervalSec=0\n");
    expect("the service has no start limit, in [Unit]",
           unit_at != std::string::npos && limit_at != std::string::npos && unit_at < limit_at && limit_at < service_at);

    std::string error;
    std::string script = unit_exec::shell_script(unit, error);
    expect("the service's command is a plain sh -c script (" + error + ")", error.empty() && !script.empty());

    // In the build tree, not /tmp: the stub must be executable and /tmp may be noexec.
    const fs::path t = fs::path(BUILD_DIR) / ("etcwatch_" + std::to_string(::getpid()));
    fs::remove_all(t);
    fs::create_directories(t / "bin");
    fs::create_directories(t / "run");
    const fs::path stamp = t / "etc-last-commit", sent = t / "sent", marker = t / "run/foxml-etcwatch.last";
    std::ofstream(t / "bin/desk-dispatch") << "#!/bin/sh\nprintf '%s|%s\\n' \"$1\" \"$2\" >> '" << sent.string() << "'\n";
    fs::permissions(t / "bin/desk-dispatch", fs::perms::owner_all, fs::perm_options::add);

    const std::string stamp_path = "/var/lib/foxml/etc-last-commit";
    const auto at = script.find(stamp_path);
    expect("the script reads the etckeeper stamp once", at != std::string::npos &&
                                                        script.find(stamp_path, at + 1) == std::string::npos);
    if (at != std::string::npos) script.replace(at, stamp_path.size(), stamp.string());

    const char* old_path = std::getenv("PATH");
    const std::string saved = old_path ? old_path : "";
    ::setenv("PATH", ((t / "bin").string() + ":/usr/bin:/bin").c_str(), 1);
    ::setenv("XDG_RUNTIME_DIR", (t / "run").c_str(), 1);
    auto run = [&]() {
        std::string out;
        return sh::probe({"/bin/sh", "-c", script}, out);
    };
    auto alerts = [&]() {
        const std::string s = slurp(sent);
        return static_cast<int>(std::count(s.begin(), s.end(), '\n'));
    };

    stamp_age(stamp, 3600);
    expect("a change outside etckeeper: exit 0", run() == 0);
    expect("a change outside etckeeper: one alert", alerts() == 1);
    expect("the alert says what to run, got '" + slurp(sent) + "'",
           slurp(sent).rfind("etc-change|/etc modified outside an etckeeper commit", 0) == 0 &&
               slurp(sent).find("Run: sudo etckeeper unclean") != std::string::npos);
    for (int i = 0; i < 6; ++i) run();
    expect("the rest of the burst, inside a minute: no more alerts", alerts() == 1);

    std::ofstream(marker) << (std::time(nullptr) - 61) << "\n";
    run();
    expect("a minute on: a new alert", alerts() == 2);

    fs::remove(marker);
    stamp_age(stamp, 5);
    run();
    expect("within 30 s of an etckeeper commit: no alert", alerts() == 2);

    stamp_age(stamp, 3600);
    std::ofstream(marker) << "garbled\n";
    run();
    expect("a garbled marker does not silence it", alerts() == 3);

    ::setenv("PATH", saved.c_str(), 1);
    ::unsetenv("XDG_RUNTIME_DIR");

    // The state check compares the deployed bodies: the service from before this fix is out of date.
    {
        const fs::path units = t / "units";
        fs::create_directories(units);
        expect("no units: not current", !etcwatch_units_current(units));
        std::ofstream(units / "fox-etcwatch.path") << ETCWATCH_PATH_UNIT;
        std::ofstream(units / "fox-etcwatch.service")
            << "[Unit]\nDescription=fox-etcwatch — dispatch /etc change\n\n[Service]\nType=oneshot\n"
               "ExecStart=/bin/sh -c 'stamp=$(stat -c %%Y /var/lib/foxml/etc-last-commit 2>/dev/null || echo 0); true'\n";
        expect("the old service: not current", !etcwatch_units_current(units));
        std::ofstream(units / "fox-etcwatch.service") << ETCWATCH_SERVICE_UNIT;
        expect("today's units: current", etcwatch_units_current(units));
    }

    fs::remove_all(t);
    if (failed) { std::fprintf(stderr, "etcwatch tests: %d FAILED\n", failed); return 1; }
    std::printf("etcwatch tests: OK\n");
    return 0;
}
