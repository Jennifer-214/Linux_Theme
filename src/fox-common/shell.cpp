#include "shell.hpp"

#include "ui.hpp"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/wait.h>
#include <unistd.h>

namespace fox_install::sh {

namespace {

bool g_dry_run = false;

int do_run(const std::vector<const char*>& argv_c) {
    pid_t pid = ::fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        ::execvp(argv_c[0], const_cast<char* const*>(argv_c.data()));
        ::_exit(127);
    }
    int status = 0;
    while (::waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

void log_invocation(const std::vector<const char*>& argv_c) {
    if (!g_dry_run) return;
    std::string line = "[dry-run] $";
    for (auto* a : argv_c) {
        if (!a) break;
        line += ' ';
        line += a;
    }
    ui::substep(line);
}

}  // namespace

void set_dry_run(bool on) { g_dry_run = on; }
bool dry_run() { return g_dry_run; }

int run(std::initializer_list<const char*> argv) {
    std::vector<const char*> v(argv.begin(), argv.end());
    v.push_back(nullptr);
    log_invocation(v);
    if (g_dry_run) return 0;
    return do_run(v);
}

int run(const std::vector<std::string>& argv) {
    std::vector<const char*> v;
    v.reserve(argv.size() + 1);
    for (auto& s : argv) v.push_back(s.c_str());
    v.push_back(nullptr);
    log_invocation(v);
    if (g_dry_run) return 0;
    return do_run(v);
}

bool capture(const std::vector<std::string>& argv, std::string& out) {
    out.clear();
    int p[2];
    if (::pipe(p) < 0) return false;
    pid_t pid = ::fork();
    if (pid < 0) { ::close(p[0]); ::close(p[1]); return false; }
    if (pid == 0) {
        ::close(p[0]);
        ::dup2(p[1], STDOUT_FILENO);
        ::close(p[1]);
        std::vector<const char*> v;
        v.reserve(argv.size() + 1);
        for (auto& s : argv) v.push_back(s.c_str());
        v.push_back(nullptr);
        ::execvp(v[0], const_cast<char* const*>(v.data()));
        ::_exit(127);
    }
    ::close(p[1]);
    char buf[4096];
    for (;;) {
        ssize_t n = ::read(p[0], buf, sizeof(buf));
        if (n > 0) out.append(buf, static_cast<size_t>(n));
        else if (n == 0) break;
        else if (errno != EINTR) break;
    }
    ::close(p[0]);
    int status = 0;
    while (::waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return false;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

int pacman(std::initializer_list<const char*> pkgs) {
    std::vector<std::string> argv = { "sudo", "pacman", "-S", "--needed", "--noconfirm" };
    for (auto* p : pkgs) argv.emplace_back(p);
    return run(argv);
}

int pacman(const std::vector<std::string>& pkgs) {
    if (pkgs.empty()) return 0;
    std::vector<std::string> argv = { "sudo", "pacman", "-S", "--needed", "--noconfirm" };
    for (auto& p : pkgs) argv.push_back(p);
    return run(argv);
}

int systemctl_enable(const std::string& unit, bool user) {
    std::vector<std::string> argv;
    if (!user) argv.push_back("sudo");
    argv.push_back("systemctl");
    if (user) argv.push_back("--user");
    argv.push_back("enable");
    argv.push_back("--now");
    argv.push_back(unit);
    return run(argv);
}

int systemctl_start(const std::string& unit, bool user) {
    std::vector<std::string> argv;
    if (!user) argv.push_back("sudo");
    argv.push_back("systemctl");
    if (user) argv.push_back("--user");
    argv.push_back("start");
    argv.push_back(unit);
    return run(argv);
}

int systemctl_daemon_reload(bool user) {
    std::vector<std::string> argv;
    if (!user) argv.push_back("sudo");
    argv.push_back("systemctl");
    if (user) argv.push_back("--user");
    argv.push_back("daemon-reload");
    return run(argv);
}

bool sudo_warmup() {
    // Use -n (non-interactive) so this is a silent cache check, NOT a
    // PAM prompt. install.sh's wrapper keepalive loop runs `sudo -n true`
    // every 50s, keeping the timestamp file fresh; modules just need to
    // verify the cache is still warm. Crucially, `sudo -v` would invoke
    // PAM and — on systems with pam_fprintd wired into /etc/pam.d/sudo —
    // pop a fingerprint prompt for every module that needs root. That's
    // jarring during a 30-min --full run. `-n true` skips PAM entirely:
    // success if the timestamp is valid, failure otherwise. Modules that
    // want to do privileged work check this and skip cleanly if cold.
    return run({ "sudo", "-n", "true" }) == 0;
}

}  // namespace fox_install::sh
