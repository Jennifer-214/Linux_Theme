// desk-pulse's handlers start with default signals, whatever the daemon set for itself. The daemon ignores SIGCHLD
// and SIGPIPE and blocks SIGINT/SIGTERM (for its signalfd); this test does the same and spawns, through the shell as
// a handler is, this very program in --probe mode: a program the shell starts, as desk-monitor is. It reports its own
// ignored and blocked signals and whether its waitpid works (with an ignored SIGCHLD it fails: desk-monitor's
// reconcile then saw no monitors and gave up on every hotplug). The shell alone would hide it: bash takes SIGCHLD for
// itself, then hands the ignored one back to what it runs. Only sh, mv and this program run.
#include "../spawn.hpp"

#include <chrono>
#include <climits>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

namespace {
int failed = 0;
void check(bool ok, const std::string& what) {
    std::cout << (ok ? "  ok   " : "  FAIL ") << what << '\n';
    if (!ok) ++failed;
}
// A /proc/<pid>/status mask line ("SigIgn:\t0000000000011000") as a number; bit n-1 is signal n.
unsigned long long mask_of(const std::string& text, const std::string& field) {
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line)) {
        if (line.rfind(field + ":", 0) == 0) return std::stoull(line.substr(field.size() + 1), nullptr, 16);
    }
    return ~0ULL;
}
bool has(unsigned long long mask, int sig) { return (mask >> (sig - 1)) & 1ULL; }

// What a handler program sees: its own signal masks, and whether it can wait for a child of its own.
int probe(const std::string& out) {
    std::ifstream status("/proc/self/status");
    std::stringstream masks;
    std::string line;
    while (std::getline(status, line)) if (line.rfind("SigIgn:", 0) == 0 || line.rfind("SigBlk:", 0) == 0) masks << line << '\n';
    pid_t child = ::fork();
    if (child == 0) ::_exit(7);
    int code = 0;
    const pid_t got = ::waitpid(child, &code, 0);
    masks << "waitpid " << ((got == child && WIFEXITED(code) && WEXITSTATUS(code) == 7) ? "ok" : "failed") << '\n';
    std::ofstream(out) << masks.str();
    return 0;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc == 3 && std::strcmp(argv[1], "--probe") == 0) return probe(argv[2]);

    // As desk-pulse runs (its main and setup_signalfd).
    std::signal(SIGCHLD, SIG_IGN);
    std::signal(SIGPIPE, SIG_IGN);
    sigset_t blocked;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGINT);
    sigaddset(&blocked, SIGTERM);
    sigprocmask(SIG_BLOCK, &blocked, nullptr);

    char self[PATH_MAX] = {0};
    if (::readlink("/proc/self/exe", self, sizeof(self) - 1) <= 0) { std::perror("readlink"); return 2; }
    char dir[] = "/tmp/desk-pulse-spawn-XXXXXX";
    if (!::mkdtemp(dir)) { std::perror("mkdtemp"); return 2; }
    const std::string out = std::string(dir) + "/status";
    desk_pulse::spawn_command("'" + std::string(self) + "' --probe '" + out + ".part' && mv '" + out + ".part' '" + out + "'");
    std::string text;
    for (int i = 0; i < 300 && text.empty(); ++i) {
        std::ifstream in(out);
        if (in) { std::stringstream s; s << in.rdbuf(); text = s.str(); }
        if (text.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    std::remove(out.c_str());
    ::rmdir(dir);
    check(!text.empty(), "the spawned command ran and reported");
    const auto ignored = mask_of(text, "SigIgn"), held = mask_of(text, "SigBlk");
    check(ignored != ~0ULL && !has(ignored, SIGCHLD), "SIGCHLD is not ignored in what a handler runs");
    check(ignored != ~0ULL && !has(ignored, SIGPIPE), "SIGPIPE is not ignored in what a handler runs");
    check(held != ~0ULL && !has(held, SIGINT) && !has(held, SIGTERM), "SIGINT and SIGTERM are not blocked in what a handler runs");
    check(text.find("waitpid ok") != std::string::npos, "what a handler runs can wait for a child of its own (desk-monitor's waitpid)");
    std::cout << (failed ? "test_spawn: FAILED\n" : "test_spawn: all passed\n");
    return failed ? 1 : 0;
}
