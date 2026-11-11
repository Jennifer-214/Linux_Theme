// The polkit fallback decides from a pretend /proc: a held marker or a running hyprpolkitagent keeps quiet; no
// prompt on two ticks in a row starts one.
#include "../polkit_watch.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <unistd.h>

namespace fs = std::filesystem;
static int failed = 0;
static void expect(bool ok, const char* what) { if (!ok) { std::printf("FAIL: %s\n", what); ++failed; } }
static void process(const fs::path& proc, int pid, const char* comm) {
    fs::create_directories(proc / std::to_string(pid));
    std::ofstream(proc / std::to_string(pid) / "comm") << comm << "\n";
}

int main() {
    const fs::path root = fs::temp_directory_path() / ("polkit-watch-" + std::to_string(::getpid()));
    const fs::path proc = root / "proc", marker = root / "foxml-polkit-agent";
    fs::create_directories(proc);
    const uid_t me = ::getuid();
    desk_pulse::AgentWatch watch;

    process(proc, 40, "quickshell");
    std::ofstream(marker) << "40\n";
    expect(!watch.tick(proc, marker, me) && !watch.tick(proc, marker, me), "the paper prompt holds it: nothing to do");

    fs::remove_all(proc / "40");
    expect(!watch.tick(proc, marker, me), "one miss is the handover moment: wait");
    expect(watch.tick(proc, marker, me), "a stale marker twice: start hyprpolkitagent");

    process(proc, 41, "quickshell");
    std::ofstream(marker) << "40\n";
    expect(!watch.tick(proc, marker, me) && watch.tick(proc, marker, me), "a running shell that does not hold the prompt is not enough");

    process(proc, 50, "hyprpolkitagent");
    fs::remove(marker);
    expect(!watch.tick(proc, marker, me) && !watch.tick(proc, marker, me), "hyprpolkitagent is running: nothing to do");

    fs::remove_all(proc / "50");
    process(proc, 60, "hyprpolkitagen");
    expect(!watch.tick(proc, marker, me) && watch.tick(proc, marker, me), "a name only close to it is not the agent");

    std::ofstream(marker) << "not a pid\n";
    expect(!watch.tick(proc, marker, me) && watch.tick(proc, marker, me), "a garbled marker holds nothing");

    fs::remove_all(root);
    std::printf("polkit_watch: %s\n", failed ? "FAILED" : "ok");
    return failed ? 1 : 0;
}
