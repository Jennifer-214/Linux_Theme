#include "shell.hpp"

#include "ui.hpp"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <fstream>
#include <sys/wait.h>
#include <unistd.h>

namespace fox_install::sh {

namespace {

bool g_dry_run = false;
std::filesystem::path g_stderr_log;

// Open the configured stderr log for append. Returns -1 if unset or
// the open fails (which we treat as "fall through to terminal stderr"
// rather than aborting the run — losing some logs is preferable to
// the install crashing).
int open_stderr_log() {
    if (g_stderr_log.empty()) return -1;
    return ::open(g_stderr_log.c_str(),
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                  0600);
}

int do_run(const std::vector<const char*>& argv_c) {
    // Pre-open the log in the parent so a failure to open (permissions,
    // missing parent dir, …) doesn't poison the child silently. -1
    // means "no redirection" which leaves the child's stderr at the
    // inherited terminal — the current behavior.
    int log_fd = open_stderr_log();

    pid_t pid = ::fork();
    if (pid < 0) {
        if (log_fd >= 0) ::close(log_fd);
        return -1;
    }
    if (pid == 0) {
        if (log_fd >= 0) {
            // Redirect ONLY the child's stderr. The child's stdout is
            // intentionally left attached to the terminal so progress
            // output from pacman / git / make stays visible — the goal
            // is to absorb errors, not silence the install.
            ::dup2(log_fd, STDERR_FILENO);
            ::close(log_fd);
        }
        ::execvp(argv_c[0], const_cast<char* const*>(argv_c.data()));
        ::_exit(127);
    }
    if (log_fd >= 0) ::close(log_fd);  // parent's copy
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

void set_stderr_log(const std::filesystem::path& path) {
    g_stderr_log = path;
    if (path.empty()) return;
    // Create the parent dir up front so the per-child open() doesn't
    // race on the same mkdir N times. The actual file is created on
    // first append.
    std::error_code ec;
    std::filesystem::create_directories(path.parent_path(), ec);
}

const std::filesystem::path& stderr_log() { return g_stderr_log; }

void log_section(const std::string& title) {
    if (g_stderr_log.empty()) return;
    std::ofstream f(g_stderr_log, std::ios::app);
    if (!f) return;
    f << "=== " << title << " ===\n";
}

std::vector<std::string> tail_log(std::size_t lines) {
    std::vector<std::string> out;
    if (g_stderr_log.empty() || lines == 0) return out;
    std::ifstream f(g_stderr_log);
    if (!f) return out;
    std::deque<std::string> ring;
    std::string line;
    while (std::getline(f, line)) {
        ring.push_back(std::move(line));
        if (ring.size() > lines) ring.pop_front();
    }
    out.assign(ring.begin(), ring.end());
    return out;
}

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
    int log_fd = open_stderr_log();
    pid_t pid = ::fork();
    if (pid < 0) {
        ::close(p[0]); ::close(p[1]);
        if (log_fd >= 0) ::close(log_fd);
        return false;
    }
    if (pid == 0) {
        ::close(p[0]);
        ::dup2(p[1], STDOUT_FILENO);
        ::close(p[1]);
        if (log_fd >= 0) {
            ::dup2(log_fd, STDERR_FILENO);
            ::close(log_fd);
        }
        std::vector<const char*> v;
        v.reserve(argv.size() + 1);
        for (auto& s : argv) v.push_back(s.c_str());
        v.push_back(nullptr);
        ::execvp(v[0], const_cast<char* const*>(v.data()));
        ::_exit(127);
    }
    ::close(p[1]);
    if (log_fd >= 0) ::close(log_fd);
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

bool write_root_atomic(const std::filesystem::path& dst,
                       const std::string& body,
                       const std::string& mode) {
    char tmpl[] = "/tmp/foxin-rootwrite-XXXXXX";
    int fd = ::mkstemp(tmpl);
    if (fd < 0) return false;
    ssize_t w = 0;
    if (!body.empty()) {
        w = ::write(fd, body.data(), body.size());
    }
    ::close(fd);
    if (w != static_cast<ssize_t>(body.size())) {
        ::unlink(tmpl);
        return false;
    }
    int rc = run({"sudo", "install", "-d", dst.parent_path().string()});
    if (rc == 0) {
        rc = run({"sudo", "install", "-m", mode, "-o", "root", "-g", "root",
                  tmpl, dst.string()});
    }
    ::unlink(tmpl);
    return rc == 0;
}

bool have(const std::string& bin) {
    if (bin.empty()) return false;
    // Absolute or relative path: check directly. access() handles it.
    if (bin.find('/') != std::string::npos) {
        return ::access(bin.c_str(), X_OK) == 0;
    }
    const char* path = std::getenv("PATH");
    if (!path || !*path) path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin";
    std::string p = path;
    std::size_t start = 0;
    while (start <= p.size()) {
        std::size_t sep = p.find(':', start);
        std::string dir = p.substr(start, sep == std::string::npos ? std::string::npos : sep - start);
        if (dir.empty()) dir = ".";
        std::string full = dir + "/" + bin;
        if (::access(full.c_str(), X_OK) == 0) return true;
        if (sep == std::string::npos) break;
        start = sep + 1;
    }
    return false;
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
