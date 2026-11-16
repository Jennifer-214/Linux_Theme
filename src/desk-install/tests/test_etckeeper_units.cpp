// The etckeeper step's fox-etcwatch units, run for real (modules/etckeeper.cpp) with stand-ins as the only programs on
// PATH: a sudo that runs nothing, and a systemctl that loads the unit files at daemon-reload the way systemd does
// (systemd.unit(5): an empty unit file loads as masked, and an enable of a masked unit fails). Until 2026-11-16 the
// step wrote both units through streams still open at the reload, so systemd read two empty files, the enable failed
// on every fresh install, and later runs found current bodies and skipped: the /etc watcher was never on.
//   - a fresh install: both bodies are complete on disk at every reload and at the enable, the reload comes after the
//     write and before the enable, and the watcher ends enabled and running;
//   - a run that finds it current and watching changes nothing;
//   - current bodies with the watcher off (what that bug left behind) are enabled again;
//   - an older service body is replaced and the watcher reset and started.

#include "../core/context.hpp"
#include "../modules/etcwatch_units.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
using namespace desk_install;

namespace desk_install { void run_etckeeper(Context&); }

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

std::vector<std::string> lines(const fs::path& p) {
    std::vector<std::string> out;
    std::ifstream f(p);
    for (std::string line; std::getline(f, line);) out.push_back(line);
    return out;
}

void program(const fs::path& path, const std::string& body) {
    std::ofstream(path) << body;
    fs::permissions(path, fs::perms::owner_all, fs::perm_options::replace);
}

}  // namespace

int main() {
    // In the build tree, not /tmp: the stand-ins must be executable and /tmp may be noexec.
    const fs::path t = fs::path(BUILD_DIR) / ("etckeeper_units_" + std::to_string(::getpid()));
    fs::remove_all(t);
    const fs::path bin = t / "bin", state = t / "state", calls = t / "systemctl.log", sudo_calls = t / "sudo.log";
    fs::create_directories(bin);
    fs::create_directories(state);
    Context ctx;
    ctx.config_home = t / "config";
    const fs::path units = ctx.config_home / "systemd/user";
    const fs::path path_unit = units / "fox-etcwatch.path", svc_unit = units / "fox-etcwatch.service";

    // Nothing reaches the machine: sudo only records, and every other program the step names is a stand-in or absent.
    program(bin / "sudo", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + sudo_calls.string() + "'\nexit 0\n");
    program(bin / "etckeeper", "#!/bin/sh\nexit 0\n");
    fs::create_symlink("/bin/sh", bin / "sh");
    // systemctl --user: each call recorded with both unit files' sizes at that moment. daemon-reload takes the files as
    // they are then; enable --now of a unit loaded empty fails as masked, otherwise it enables and starts the path unit.
    const std::string size = "$(/usr/bin/stat -c %s \"$P\" 2>/dev/null || echo none) $(/usr/bin/stat -c %s \"$S\" 2>/dev/null || echo none)";
    program(bin / "systemctl",
            "#!/bin/sh\n"
            "P='" + path_unit.string() + "'; S='" + svc_unit.string() + "'; D='" + state.string() + "'\n"
            "[ \"$1\" = --user ] || { echo \"system: $*\" >> '" + calls.string() + "'; exit 1; }\n"
            "shift\n"
            "printf '%s | %s\\n' \"$*\" \"" + size + "\" >> '" + calls.string() + "'\n"
            "case \"$1\" in\n"
            "  daemon-reload) echo \"" + size + "\" > \"$D/loaded\"; exit 0 ;;\n"
            "  is-enabled) [ -e \"$D/enabled\" ] && { echo enabled; exit 0; }; echo disabled; exit 1 ;;\n"
            "  is-active) [ -e \"$D/active\" ] && exit 0; exit 3 ;;\n"
            "  enable)\n"
            "    read -r p s < \"$D/loaded\" 2>/dev/null\n"
            "    case \"$p $s\" in *none*|'0 '*|*' 0'|' ') echo 'Failed to enable unit: Unit file fox-etcwatch.path is masked.' >&2; exit 1 ;; esac\n"
            "    : > \"$D/enabled\"; : > \"$D/active\"; exit 0 ;;\n"
            "  reset-failed|unmask) exit 0 ;;\n"
            "esac\n"
            "exit 1\n");
    const char* old_path = std::getenv("PATH");
    const std::string saved = old_path ? old_path : "";
    ::setenv("PATH", bin.c_str(), 1);

    const std::string full = std::to_string(std::strlen(ETCWATCH_PATH_UNIT)) + " " +
                             std::to_string(std::strlen(ETCWATCH_SERVICE_UNIT));

    // A fresh install.
    run_etckeeper(ctx);
    auto log = lines(calls);
    int last_reload = -1, enable = -1, reset = -1;
    for (int i = 0; i < static_cast<int>(log.size()); ++i) {
        if (log[i].rfind("daemon-reload |", 0) == 0 && enable < 0) last_reload = i;
        if (log[i].rfind("reset-failed ", 0) == 0) reset = i;
        if (log[i].rfind("enable --now fox-etcwatch.path |", 0) == 0) enable = i;
    }
    expect("fresh install: the path unit is enabled with --now", enable >= 0);
    expect("fresh install: a daemon-reload comes before the enable", last_reload >= 0 && last_reload < enable);
    expect("fresh install: the failure state is reset before the enable", reset >= 0 && reset < enable);
    if (last_reload >= 0)
        expect("fresh install: at the last reload before the enable both units are complete on disk (" + full + "), got '" +
                   log[last_reload] + "'",
               log[last_reload] == "daemon-reload | " + full);
    if (enable >= 0)
        expect("fresh install: at the enable both units are complete, got '" + log[enable] + "'",
               log[enable] == "enable --now fox-etcwatch.path | " + full);
    expect("fresh install: the watcher ends enabled and running", fs::exists(state / "enabled") && fs::exists(state / "active"));
    expect("fresh install: the deployed bodies are today's", etcwatch_units_current(units));
    expect("fresh install: no temporary left beside the units",
           !fs::exists(units / "fox-etcwatch.path.foxin-tmp") && !fs::exists(units / "fox-etcwatch.service.foxin-tmp"));
    expect("sudo was asked, never run (the stand-in records it)", slurp(sudo_calls).find("-n true") != std::string::npos);

    // Already current and watching: nothing is rewritten or enabled.
    fs::remove(calls);
    const auto stamp = fs::last_write_time(path_unit);
    run_etckeeper(ctx);
    log = lines(calls);
    bool changed = false;
    for (const auto& line : log)
        changed = changed || line.rfind("enable ", 0) == 0 || line.rfind("daemon-reload", 0) == 0 || line.rfind("unmask", 0) == 0;
    expect("current and watching: no reload, unmask or enable", !changed);
    expect("current and watching: the unit file is not rewritten", fs::last_write_time(path_unit) == stamp);

    // Current bodies with the watcher off — what the bug left on every machine it installed: enabled again.
    fs::remove(state / "enabled");
    fs::remove(state / "active");
    fs::remove(calls);
    run_etckeeper(ctx);
    log = lines(calls);
    bool enabled_again = false;
    for (const auto& line : log) enabled_again = enabled_again || line == "enable --now fox-etcwatch.path | " + full;
    expect("current bodies, watcher off: enabled again", enabled_again);
    expect("current bodies, watcher off: ends enabled and running", fs::exists(state / "enabled") && fs::exists(state / "active"));

    // An older service body on a running watcher: replaced, then the watcher reset and started on it.
    std::ofstream(svc_unit) << "[Unit]\nDescription=fox-etcwatch — dispatch /etc change\n\n[Service]\nType=oneshot\nExecStart=/bin/true\n";
    fs::remove(calls);
    run_etckeeper(ctx);
    expect("an older service body is replaced with today's", slurp(svc_unit) == ETCWATCH_SERVICE_UNIT);
    log = lines(calls);
    bool reloaded_full = false;
    for (const auto& line : log) reloaded_full = reloaded_full || line == "daemon-reload | " + full;
    expect("the older body: systemd reloads the complete new units", reloaded_full);

    ::setenv("PATH", saved.c_str(), 1);
    fs::remove_all(t);
    if (failed) { std::fprintf(stderr, "etckeeper unit tests: %d FAILED\n", failed); return 1; }
    std::printf("etckeeper unit tests: OK\n");
    return 0;
}
