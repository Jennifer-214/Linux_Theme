// User services still running a program the install replaced (modules/stale_services.hpp), read from a stand-in /proc
// and home, with a stand-in systemctl first on PATH: nothing of this machine's is read, restarted or signalled. On
// 2026-11-16 desk-pulse and the bouncer ran the day before's code, deleted from disk, after an install: `enable --now`
// starts only what is stopped.
//   - a service whose program (exe) or script (an open file an interpreter reads) was replaced by other bytes is found,
//     with its processes and the paths;
//   - the same bytes laid again (a rename of an unchanged file), a file outside the home, a transient unit (an app),
//     a scope, the user manager itself and a process with nothing deleted are not;
//   - the restart reaches only the watchers (try-restart), never fox-vault (a restart empties it) or another unit.

#include "../modules/stale_services.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
namespace stale = desk_install::stale;

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

void write(const fs::path& path, const std::string& text, bool program = false) {
    fs::create_directories(path.parent_path());
    std::ofstream(path) << text;
    if (program) fs::permissions(path, fs::perms(0755), fs::perm_options::replace);
}

std::string names(const std::vector<stale::Service>& found) {
    std::string out;
    for (const auto& svc : found) out += (out.empty() ? "" : " ") + svc.unit;
    return out;
}

}  // namespace

int main() {
    const fs::path t = fs::path(BUILD_DIR) / ("stale_services_" + std::to_string(::getpid()));
    fs::remove_all(t);
    const fs::path proc = t / "proc", home = t / "home", bin = home / ".local/bin", units = home / ".config/systemd/user";
    for (const char* unit : {"fox-pulse.service", "fox-bouncer.service", "power-state-watcher.service", "fox-vault.service",
                             "fox-tripwire.service", "fox-llm@.service"})
        write(units / unit, "[Service]\n");

    // The programs as installed now, and what each running process still holds: /proc names a file gone from disk
    // "<path> (deleted)", and opening the link reads the old copy (here a file of that name).
    write(bin / "desk-pulse", "pulse v2", true);
    write(bin / "desk-pulse (deleted)", "pulse v1");
    write(bin / "desk-bouncer", "#!/bin/bash\n# bouncer v2\n", true);
    write(bin / "desk-bouncer (deleted)", "#!/bin/bash\n# bouncer v1\n");
    write(home / ".config/hypr/scripts/power_state_watcher.sh", "#!/bin/bash\n# same\n", true);
    write(home / ".config/hypr/scripts/power_state_watcher.sh (deleted)", "#!/bin/bash\n# same\n");
    write(bin / "desk-vault", "vault v2", true);
    write(bin / "desk-vault (deleted)", "vault v1");
    write(bin / "llm-serve", "serve v2", true);
    write(bin / "llm-serve (deleted)", "serve v1");
    write(t / "usr/inotifywait", "new", true);
    write(t / "usr/inotifywait (deleted)", "old");

    const std::string slice = "0::/user.slice/user-1000.slice/user@1000.service";
    auto process = [&](int pid, const std::string& cgroup, const fs::path& exe, const fs::path& script = {}) {
        const auto dir = proc / std::to_string(pid);
        write(dir / "cgroup", cgroup + "\n");
        fs::create_symlink(exe, dir / "exe");
        fs::create_directories(dir / "fd");
        fs::create_symlink("/dev/null", dir / "fd/0");
        fs::create_symlink("pipe:[4242]", dir / "fd/1");
        if (!script.empty()) fs::create_symlink(script, dir / "fd/255");
    };
    const fs::path bash = "/usr/bin/bash";
    process(100, slice + "/app.slice/fox-pulse.service", bin / "desk-pulse (deleted)");                     // a replaced program
    process(101, slice + "/app.slice/fox-bouncer.service", bash, bin / "desk-bouncer (deleted)");           // a replaced script
    process(102, slice + "/app.slice/fox-bouncer.service", bash, bin / "desk-bouncer (deleted)");           // its pipeline
    process(103, slice + "/app.slice/power-state-watcher.service", bash,
            home / ".config/hypr/scripts/power_state_watcher.sh (deleted)");                                  // same bytes
    process(104, slice + "/app.slice/fox-vault.service", bin / "desk-vault (deleted)");                    // not restarted
    process(105, slice + "/app.slice/fox-tripwire.service", t / "usr/inotifywait (deleted)");              // outside home
    process(106, slice + "/app.slice/app-kitty@3.service", bin / "desk-pulse (deleted)");                  // transient
    process(107, slice + "/app.slice/app-Hyprland-kitty-9.scope", bin / "desk-pulse (deleted)");           // a scope
    process(108, slice + "/init.scope", bin / "desk-pulse (deleted)");                                     // the manager
    process(109, slice, bin / "desk-pulse (deleted)");
    process(110, slice + "/app.slice/fox-pulse.service", bin / "desk-pulse");                              // nothing deleted
    process(111, slice + "/app.slice/fox-llm@coder.service", bin / "llm-serve (deleted)");                 // an instance

    const auto found = stale::replaced_code(home, units, ::getuid(), proc);
    expect("found: fox-bouncer, fox-llm@coder, fox-pulse, fox-vault (sorted), got '" + names(found) + "'",
           names(found) == "fox-bouncer.service fox-llm@coder.service fox-pulse.service fox-vault.service");
    for (const auto& svc : found) {
        if (svc.unit == "fox-bouncer.service")
            expect("the bouncer: both its processes and its script",
                   svc.pids == std::vector<long long>{101, 102} && svc.files == std::vector<std::string>{(bin / "desk-bouncer").string()});
        if (svc.unit == "fox-pulse.service")
            expect("desk-pulse: the process running the old copy, not the one on the new",
                   svc.pids == std::vector<long long>{100} && svc.files == std::vector<std::string>{(bin / "desk-pulse").string()});
    }
    expect("cgroup v2 line → its user service", stale::user_service(slice + "/app.slice/fox-pulse.service\n") == "fox-pulse.service");
    expect("a hybrid cgroup file: the unified line", stale::user_service("1:name=systemd:/x\n" + slice + "/app.slice/a.service\n") == "a.service");
    expect("a system service is not a user's", stale::user_service("0::/system.slice/sshd.service\n").empty());

    // The restart: try-restart, the watchers only, through the systemctl first on PATH.
    const fs::path stand_in = t / "bin", calls = t / "systemctl.log";
    write(stand_in / "systemctl", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + calls.string() + "'\nexit 0\n", true);
    const char* old_path = std::getenv("PATH");
    const std::string saved = old_path ? old_path : "";
    ::setenv("PATH", stand_in.c_str(), 1);
    const auto restarted = stale::restart_replaced(home, units, ::getuid(), proc);
    expect("restarted: the bouncer and desk-pulse", restarted == std::vector<std::string>{"fox-bouncer.service", "fox-pulse.service"});
    expect("each with try-restart, nothing else asked: got '" + slurp(calls) + "'",
           slurp(calls) == "--user try-restart fox-bouncer.service\n--user try-restart fox-pulse.service\n");
    fs::remove(calls);
    const auto changed = stale::try_restart({"fox-pulse.service", "fox-theme-check.timer", "fox-vault.service", "power-state-watcher.service"});
    expect("a changed unit: only the watchers", changed == std::vector<std::string>{"fox-pulse.service", "power-state-watcher.service"});
    expect("never fox-vault (a restart empties it)", slurp(calls).find("fox-vault") == std::string::npos);
    ::setenv("PATH", saved.c_str(), 1);

    fs::remove_all(t);
    if (failed) { std::fprintf(stderr, "stale service tests: %d FAILED\n", failed); return 1; }
    std::printf("stale service tests: OK\n");
    return 0;
}
