// Runs the foxml-arch-audit service's own command (modules/arch_audit_units.hpp, through tests/unit_exec.hpp) with
// stand-ins for arch-audit and notify-send first on PATH. Until 2026-11-15 the service ran `arch-audit -uf`: -f wants
// a FORMAT, so arch-audit stopped at a usage error that went to /dev/null, and the daily notice never came.
//   - fixable packages: one notice that counts them and lists "name → fixed version (severity)", at most ten;
//   - none: no notice, exit 0. arch-audit failing (offline): no notice, and the unit fails;
//   - a stray line on stdout (a sandbox banner) is not a package;
//   - with the real arch-audit installed, the same command runs it on a throwaway package database and advisory file
//     (no network), so the flags are ones the installed arch-audit takes;
//   - the state check's comparison: an old service body is out of date.

#include "../modules/arch_audit_units.hpp"
#include "unit_exec.hpp"
#include "../../desk-common/shell.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>
#include <utility>
#include <vector>

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

void script_file(const fs::path& p, const std::string& body) {
    std::ofstream(p) << "#!/bin/bash\n" << body << "\n";
    fs::permissions(p, fs::perms::owner_all, fs::perm_options::add);
}

// arch-audit 0.2.0's command line as far as the service uses it: -f wants a value (`-uf` alone is the usage error the
// old service hit), and %n %v %s fill one line per package, "%s" reading "High risk". STUB_* pick the case.
const char* FAKE_ARCH_AUDIT = R"(fmt=""
usage() { echo "error: a value is required for '--format <FORMAT>' but none was supplied" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--format) [ $# -ge 2 ] || usage; fmt="$2"; shift 2 ;;
        -C|--color) shift 2 ;;
        -[a-zA-Z]*f) usage ;;
        *) shift ;;
    esac
done
[ -n "${STUB_BANNER:-}" ] && echo "Reading profile /etc/firejail/arch-audit.profile"
[ -n "${STUB_FAIL:-}" ] && { echo "Error: failed to get AVG json" >&2; exit 1; }
[ -n "$fmt" ] || { echo "openssl is affected by arbitrary code execution. High risk!"; exit 0; }
printf '%s\n' "${STUB_PACKAGES:-}" | while read -r name version severity; do
    [ -n "$name" ] || continue
    printf '%s\n' "$fmt" | sed -e "s/%n/$name/g" -e "s/%v/$version/g" -e "s/%s/$severity risk/g"
done)";

// Each argument to its own file, so a multi-line body survives.
const char* FAKE_NOTIFY = R"(i=0
for a in "$@"; do i=$((i + 1)); printf '%s' "$a" > "$NOTES/arg$i"; done
echo "$i" > "$NOTES/argc"
echo x >> "$NOTES/calls")";

struct Result { int rc = -1; int notices = 0; std::string app, summary, body, stderr_text; };

Result run(const std::string& script, const fs::path& t, const std::vector<std::pair<std::string, std::string>>& env) {
    const fs::path notes = t / "notes";
    fs::remove_all(notes);
    fs::create_directories(notes);
    for (const auto& [k, v] : env) ::setenv(k.c_str(), v.c_str(), 1);
    ::setenv("NOTES", notes.c_str(), 1);
    std::string out;
    Result r;
    r.rc = sh::probe({"/bin/sh", "-c", "exec 2>\"$NOTES/stderr\"; " + script}, out);
    for (const auto& kv : env) ::unsetenv(kv.first.c_str());
    const std::string calls = slurp(notes / "calls");
    r.notices = static_cast<int>(std::count(calls.begin(), calls.end(), '\n'));
    r.stderr_text = slurp(notes / "stderr");
    if (r.notices > 0) {
        const int argc = std::atoi(slurp(notes / "argc").c_str());
        r.app = slurp(notes / "arg1");
        r.summary = slurp(notes / ("arg" + std::to_string(argc - 1)));
        r.body = slurp(notes / ("arg" + std::to_string(argc)));
    }
    return r;
}

// A throwaway pacman database and security-tracker file for the real arch-audit: openssl and zlib have shipped fixes,
// curl's is not out yet (so -u leaves it out), vim is newer than the affected version.
void advisory_fixture(const fs::path& t) {
    auto pkg = [&](const std::string& name, const std::string& version) {
        const fs::path dir = t / "db/local" / (name + "-" + version);
        fs::create_directories(dir);
        std::ofstream(dir / "desc") << "%NAME%\n" << name << "\n\n%VERSION%\n" << version << "\n\n";
    };
    fs::create_directories(t / "db/local");
    std::ofstream(t / "db/local/ALPM_DB_VERSION") << "9\n";
    pkg("openssl", "3.0.0-1");
    pkg("curl", "8.0.0-1");
    pkg("zlib", "1.3-1");
    pkg("vim", "9.0-1");
    std::ofstream(t / "all.json") << R"([
 {"name":"AVG-1","packages":["openssl"],"status":"Fixed","severity":"High","type":"arbitrary code execution","affected":"3.0.0-1","fixed":"3.0.1-1","ticket":null,"issues":["CVE-2026-0001"],"advisories":[]},
 {"name":"AVG-2","packages":["openssl"],"status":"Fixed","severity":"Medium","type":"denial of service","affected":"3.0.0-1","fixed":"3.0.2-1","ticket":null,"issues":["CVE-2026-0002"],"advisories":[]},
 {"name":"AVG-3","packages":["curl"],"status":"Vulnerable","severity":"Critical","type":"information disclosure","affected":"8.0.0-1","fixed":null,"ticket":null,"issues":["CVE-2026-0003"],"advisories":[]},
 {"name":"AVG-4","packages":["zlib","vim"],"status":"Fixed","severity":"Low","type":"unknown","affected":"1.3-1","fixed":"1.3.1-1","ticket":null,"issues":["CVE-2026-0004"],"advisories":[]}
])";
}

}  // namespace

int main() {
    // In the build tree, not /tmp: the stubs must be executable and /tmp may be noexec.
    const fs::path t = fs::path(BUILD_DIR) / ("arch_audit_" + std::to_string(::getpid()));
    fs::remove_all(t);
    fs::create_directories(t / "bin");

    std::string error;
    const std::string script = unit_exec::shell_script(ARCH_AUDIT_SERVICE, error);
    expect("the service's command is a plain sh -c script (" + error + ")", error.empty() && !script.empty());

    script_file(t / "bin/arch-audit", FAKE_ARCH_AUDIT);
    script_file(t / "bin/notify-send", FAKE_NOTIFY);
    const char* old_path = std::getenv("PATH");
    const std::string saved = old_path ? old_path : "";
    ::setenv("PATH", ((t / "bin").string() + ":/usr/bin:/bin").c_str(), 1);

    const std::string two = "openssl 3.0.2-1 High\nzlib 1.3.1-1 Low";
    const std::string fixed_two = "openssl → 3.0.2-1 (High risk)\nzlib → 1.3.1-1 (Low risk)";
    {
        const auto r = run(script, t, {{"STUB_PACKAGES", two}});
        expect("two fixes: exit 0 (" + r.stderr_text + ")", r.rc == 0);
        expect("two fixes: one notice", r.notices == 1);
        expect("two fixes: the notice is FoxML's", r.app == "--app-name=FoxML");
        expect("two fixes: the summary counts both, got '" + r.summary + "'",
               r.summary == "arch-audit: 2 package(s) with available fixes");
        expect("two fixes: the body lists them, got '" + r.body + "'", r.body == fixed_two);
    }
    {
        std::string twelve;
        for (int i = 1; i <= 12; ++i) twelve += "pkg" + std::to_string(i) + " 1.0-" + std::to_string(i) + " Medium\n";
        const auto r = run(script, t, {{"STUB_PACKAGES", twelve}});
        expect("twelve fixes: the summary counts twelve, got '" + r.summary + "'",
               r.summary == "arch-audit: 12 package(s) with available fixes");
        expect("twelve fixes: the body lists the first ten, got '" + r.body + "'",
               std::count(r.body.begin(), r.body.end(), '\n') == 9 && r.body.rfind("pkg1 → 1.0-1 (Medium risk)\n", 0) == 0 &&
                   r.body.find("\npkg10 → 1.0-10 (Medium risk)") != std::string::npos &&
                   r.body.find("pkg11") == std::string::npos);
    }
    {
        const auto r = run(script, t, {});
        expect("nothing to fix: exit 0", r.rc == 0);
        expect("nothing to fix: no notice", r.notices == 0);
    }
    {
        const auto r = run(script, t, {{"STUB_BANNER", "1"}});
        expect("a banner line alone is not a package", r.rc == 0 && r.notices == 0);
        const auto with = run(script, t, {{"STUB_BANNER", "1"}, {"STUB_PACKAGES", two}});
        expect("a banner line is not counted, got '" + with.summary + "'",
               with.summary == "arch-audit: 2 package(s) with available fixes" && with.body == fixed_two);
    }
    {
        const auto r = run(script, t, {{"STUB_FAIL", "1"}, {"STUB_PACKAGES", two}});
        expect("arch-audit failing: the unit fails", r.rc != 0);
        expect("arch-audit failing: no notice", r.notices == 0);
    }

    // The installed arch-audit, offline, on the fixture: the flags must be ones it takes.
    if (fs::exists("/usr/bin/arch-audit")) {
        advisory_fixture(t);
        script_file(t / "bin/arch-audit", "exec /usr/bin/arch-audit -b '" + (t / "db").string() + "' --source '" +
                                              (t / "all.json").string() + "' \"$@\"");
        const auto r = run(script, t, {});
        expect("real arch-audit: exit 0 (" + r.stderr_text + ")", r.rc == 0);
        expect("real arch-audit: the summary counts openssl and zlib, got '" + r.summary + "'",
               r.summary == "arch-audit: 2 package(s) with available fixes");
        expect("real arch-audit: the body lists them, got '" + r.body + "'", r.body == fixed_two);
    } else {
        std::printf("arch_audit: no /usr/bin/arch-audit here, the run against the real one is skipped\n");
    }
    ::setenv("PATH", saved.c_str(), 1);

    // The state check compares the deployed bodies: the pre-2026-11-15 service is out of date.
    {
        const fs::path units = t / "units";
        fs::create_directories(units);
        expect("no units: not current", !arch_audit_units_current(units));
        std::ofstream(units / "foxml-arch-audit.service")
            << "[Service]\nType=oneshot\nExecStart=/bin/sh -c 'out=$(arch-audit -uf 2>/dev/null); true'\n";
        std::ofstream(units / "foxml-arch-audit.timer") << ARCH_AUDIT_TIMER;
        expect("the old service: not current", !arch_audit_units_current(units));
        std::ofstream(units / "foxml-arch-audit.service") << ARCH_AUDIT_SERVICE;
        expect("today's units: current", arch_audit_units_current(units));
    }

    fs::remove_all(t);
    if (failed) { std::fprintf(stderr, "arch_audit tests: %d FAILED\n", failed); return 1; }
    std::printf("arch_audit tests: OK\n");
    return 0;
}
