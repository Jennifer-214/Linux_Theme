// fox-pulse — event-driven Hyprland/inotify daemon.
//
// Replaces the polling shell loops in focus-pulse.sh / fox-monitor-watch.sh
// with a single epoll loop:
//
//   ┌────────────────────────────┐
//   │ epoll                      │
//   ├────────────────────────────┤
//   │  Hyprland socket2 (events) │  ──>  classify   ──>  debouncer.trigger()
//   │  inotify (config dir)      │  ──>  classify   ──>  debouncer.trigger()
//   │  timerfd: focus  (200 ms)  │  ──>  spawn handler
//   │  timerfd: monitor (2 s)    │  ──>  spawn handler
//   │  timerfd: config (500 ms)  │  ──>  spawn handler
//   │  signalfd: SIGINT/SIGTERM  │  ──>  graceful shutdown
//   └────────────────────────────┘
//
// Each event class has a handler script under
//   ~/.config/foxml/pulse.d/<class>.sh
// (override location with FOX_PULSE_DIR=…). If the script is missing we
// fall back to the legacy shell watchers so installs that haven't laid
// the files down keep working.

#include "debouncer.hpp"
#include "hypr_socket.hpp"

#include <array>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <string>
#include <sys/epoll.h>
#include <sys/inotify.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <unordered_map>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr int   MAX_EVENTS         = 16;
constexpr int   HYPR_RECONNECT_MS  = 2000;
constexpr int   FOCUS_DEBOUNCE_MS  = 200;
constexpr int   MONITOR_DEBOUNCE_MS = 2000;
constexpr int   CONFIG_DEBOUNCE_MS = 500;

struct HandlerSpec {
    const char* name;            // class name used for handler script lookup
    const char* legacy_script;   // legacy ~/.config/hypr/scripts/* fallback
    const char* native_cmd;      // native fallback if neither script is present
};

// Native fallbacks point at fox-install with --only — that orchestrator
// drives the same logic the bash scripts used to source from mappings.sh.
// Order of resolution: ~/.config/foxml/pulse.d/<name>.sh override →
// legacy ~/.config/hypr/scripts/<script> → native command.
const HandlerSpec FOCUS_HANDLER   = { "focus",   "focus-pulse.sh",       nullptr };
const HandlerSpec MONITOR_HANDLER = { "monitor", "fox-monitor-watch.sh",
    "fox-install --only monitors,personalize --yes" };
const HandlerSpec CONFIG_HANDLER  = { "config",  nullptr, nullptr };

std::string env_or(const char* k, const std::string& fallback) {
    const char* v = std::getenv(k);
    return (v && *v) ? std::string(v) : fallback;
}

std::string handler_dir() {
    std::string home = env_or("HOME", "");
    return env_or("FOX_PULSE_DIR", home + "/.config/foxml/pulse.d");
}

std::string config_watch_dir() {
    std::string home = env_or("HOME", "");
    return env_or("FOX_PULSE_WATCH", home + "/.config/foxml");
}

std::string legacy_script_dir() {
    // Where install.sh drops the focus/monitor scripts.
    std::string home = env_or("HOME", "");
    return env_or("FOX_PULSE_LEGACY", home + "/.config/hypr/scripts");
}

// Spawn a handler in detached fashion (no zombie — double-fork). The
// daemon does no waitpid(), so any reaping is the kernel's job via
// signal(SIGCHLD, SIG_IGN) below.
void spawn_handler(const HandlerSpec& spec) {
    std::string script = handler_dir() + "/" + spec.name + ".sh";
    bool have_script = ::access(script.c_str(), X_OK) == 0;
    std::string cmd;
    if (have_script) {
        cmd = script;
    } else if (spec.legacy_script && *spec.legacy_script) {
        cmd = legacy_script_dir() + "/" + spec.legacy_script;
        if (::access(cmd.c_str(), X_OK) != 0) {
            if (spec.native_cmd && *spec.native_cmd) cmd = spec.native_cmd;
            else return;
        }
    } else if (spec.native_cmd && *spec.native_cmd) {
        cmd = spec.native_cmd;
    } else {
        return;
    }

    pid_t pid = ::fork();
    if (pid < 0) return;
    if (pid == 0) {
        // Detach from controlling terminal; redirect stdio so we don't
        // hold the daemon's fd table open.
        ::setsid();
        int dn = ::open("/dev/null", O_RDWR | O_CLOEXEC);
        if (dn >= 0) {
            ::dup2(dn, STDIN_FILENO);
            ::dup2(dn, STDOUT_FILENO);
            ::dup2(dn, STDERR_FILENO);
            if (dn > 2) ::close(dn);
        }
        ::execl("/bin/sh", "sh", "-c", cmd.c_str(), nullptr);
        ::_exit(127);
    }
    // Parent: don't wait. SIGCHLD is SIG_IGN at startup so the child is
    // auto-reaped on exit.
}

bool classify_hypr_event(const std::string& line, const HandlerSpec*& out) {
    auto starts = [&](const char* pfx) {
        return line.compare(0, std::strlen(pfx), pfx) == 0;
    };
    if (starts("workspace") || starts("focusedmon") || starts("activespecial")) {
        out = &FOCUS_HANDLER;
        return true;
    }
    if (starts("monitoradded") || starts("monitorremoved") ||
        starts("monitoraddedv2")) {
        out = &MONITOR_HANDLER;
        return true;
    }
    return false;
}

class HyprConnection {
public:
    int fd() const { return fd_; }
    bool connected() const { return fd_ >= 0; }

    bool connect_now(int epoll_fd) {
        std::string path = fox_pulse::resolve_hypr_socket2_path();
        if (path.empty()) return false;
        fd_ = fox_pulse::connect_unix_stream(path);
        if (fd_ < 0) return false;
        epoll_event ev{};
        ev.events  = EPOLLIN | EPOLLRDHUP;
        ev.data.fd = fd_;
        if (::epoll_ctl(epoll_fd, EPOLL_CTL_ADD, fd_, &ev) < 0) {
            ::close(fd_);
            fd_ = -1;
            return false;
        }
        buffer_.clear();
        return true;
    }

    void drop(int epoll_fd) {
        if (fd_ >= 0) {
            ::epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd_, nullptr);
            ::close(fd_);
            fd_ = -1;
        }
        buffer_.clear();
    }

    // Drains the socket, splits into lines, and invokes `on_line` per line.
    template <typename F>
    bool drain(F&& on_line) {
        char buf[4096];
        for (;;) {
            ssize_t n = ::read(fd_, buf, sizeof(buf));
            if (n > 0) {
                buffer_.append(buf, static_cast<size_t>(n));
                size_t pos;
                while ((pos = buffer_.find('\n')) != std::string::npos) {
                    on_line(buffer_.substr(0, pos));
                    buffer_.erase(0, pos + 1);
                }
                continue;
            }
            if (n == 0) return false;                 // peer closed
            if (errno == EAGAIN || errno == EWOULDBLOCK) return true;
            if (errno == EINTR) continue;
            return false;                              // hard error
        }
    }

private:
    int         fd_ = -1;
    std::string buffer_;
};

int setup_signalfd() {
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGHUP);
    if (::sigprocmask(SIG_BLOCK, &mask, nullptr) < 0) return -1;
    return ::signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
}

int setup_inotify(int epoll_fd, const std::string& dir) {
    int ino = ::inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (ino < 0) return -1;
    if (!fs::is_directory(dir)) {
        // Watch dir doesn't exist yet — keep ino but no watch.
        // Caller can still poll it; just no inotify events fire.
        return ino;
    }
    if (::inotify_add_watch(ino, dir.c_str(),
            IN_MODIFY | IN_CREATE | IN_DELETE | IN_MOVED_TO | IN_MOVED_FROM) < 0) {
        // Watch couldn't be added (perm, ENOSPC). Don't leak the fd —
        // close and signal failure so the daemon either retries or
        // bails cleanly. Otherwise restart cycles accumulate fds
        // toward EMFILE.
        ::close(ino);
        return -1;
    }
    epoll_event ev{};
    ev.events  = EPOLLIN;
    ev.data.fd = ino;
    if (::epoll_ctl(epoll_fd, EPOLL_CTL_ADD, ino, &ev) < 0) {
        ::close(ino);
        return -1;
    }
    return ino;
}

void drain_inotify(int fd) {
    char buf[4096] __attribute__((aligned(__alignof__(inotify_event))));
    for (;;) {
        ssize_t n = ::read(fd, buf, sizeof(buf));
        if (n <= 0) return;
        // We don't care about which file changed — class-level debounce
        // collapses any burst of changes into one handler invocation.
    }
}

}  // namespace

int main(int argc, char** argv) {
    bool verbose = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "-v") == 0 ||
            std::strcmp(argv[i], "--verbose") == 0) verbose = true;
        if (std::strcmp(argv[i], "--version") == 0) {
            std::printf("fox-pulse %s\n", "0.1.0");
            return 0;
        }
        if (std::strcmp(argv[i], "--help") == 0) {
            std::printf(
                "Usage: fox-pulse [--verbose] [--version]\n\n"
                "Handler resolution order (per event class):\n"
                "  1. ~/.config/foxml/pulse.d/<class>.sh (user override)\n"
                "  2. ~/.config/hypr/scripts/<legacy>.sh (legacy bash, if deployed)\n"
                "  3. native fallback command (e.g. fox-install --only ...)\n\n"
                "Event classes: focus, monitor, config\n");
            return 0;
        }
    }

    // SIG_IGN on SIGCHLD → kernel auto-reaps detached handlers.
    std::signal(SIGCHLD, SIG_IGN);
    std::signal(SIGPIPE, SIG_IGN);

    int epoll_fd = ::epoll_create1(EPOLL_CLOEXEC);
    if (epoll_fd < 0) {
        std::perror("fox-pulse: epoll_create1");
        return 1;
    }

    auto add_fd = [&](int fd) {
        epoll_event ev{};
        ev.events  = EPOLLIN;
        ev.data.fd = fd;
        return ::epoll_ctl(epoll_fd, EPOLL_CTL_ADD, fd, &ev);
    };

    fox_pulse::Debouncer focus_db{std::chrono::milliseconds{FOCUS_DEBOUNCE_MS}};
    fox_pulse::Debouncer mon_db  {std::chrono::milliseconds{MONITOR_DEBOUNCE_MS}};
    fox_pulse::Debouncer cfg_db  {std::chrono::milliseconds{CONFIG_DEBOUNCE_MS}};
    if (focus_db.fd() < 0 || mon_db.fd() < 0 || cfg_db.fd() < 0) {
        std::fprintf(stderr, "fox-pulse: timerfd_create failed\n");
        return 1;
    }
    add_fd(focus_db.fd());
    add_fd(mon_db.fd());
    add_fd(cfg_db.fd());

    int sig_fd = setup_signalfd();
    if (sig_fd < 0) {
        std::perror("fox-pulse: signalfd");
        return 1;
    }
    add_fd(sig_fd);

    int ino_fd = setup_inotify(epoll_fd, config_watch_dir());

    HyprConnection hypr;
    if (!hypr.connect_now(epoll_fd) && verbose) {
        std::fprintf(stderr,
            "fox-pulse: Hyprland socket not yet available — will retry\n");
    }
    auto last_reconnect = std::chrono::steady_clock::now();

    bool running = true;
    while (running) {
        epoll_event events[MAX_EVENTS];
        int timeout_ms = hypr.connected() ? -1 : HYPR_RECONNECT_MS;
        int n = ::epoll_wait(epoll_fd, events, MAX_EVENTS, timeout_ms);
        if (n < 0) {
            if (errno == EINTR) continue;
            std::perror("fox-pulse: epoll_wait");
            break;
        }

        // Reconnect attempt every HYPR_RECONNECT_MS if we lost the socket.
        // Track how many attempts in a row have failed so the daemon
        // surfaces a wedged Hyprland (or a wrong $HYPRLAND_INSTANCE_SIGNATURE)
        // instead of silently sitting disconnected forever.
        static int reconnect_misses = 0;
        if (!hypr.connected()) {
            auto now = std::chrono::steady_clock::now();
            auto since = std::chrono::duration_cast<std::chrono::milliseconds>(
                now - last_reconnect).count();
            if (since >= HYPR_RECONNECT_MS) {
                bool ok = hypr.connect_now(epoll_fd);
                last_reconnect = now;
                if (!ok) {
                    ++reconnect_misses;
                    // Log once at 1, then powers of 4 (1, 4, 16, 64, …) to
                    // make a wedged daemon visible without spamming journald.
                    if (reconnect_misses == 1
                        || (reconnect_misses & (reconnect_misses - 1)) == 0) {
                        std::fprintf(stderr,
                            "fox-pulse: Hyprland reconnect failed (%d attempts) — "
                            "check $HYPRLAND_INSTANCE_SIGNATURE and socat\n",
                            reconnect_misses);
                    }
                } else {
                    reconnect_misses = 0;
                }
            }
        }

        for (int i = 0; i < n; ++i) {
            int fd = events[i].data.fd;

            if (fd == sig_fd) {
                signalfd_siginfo si{};
                while (::read(sig_fd, &si, sizeof(si)) == sizeof(si)) {
                    if (si.ssi_signo == SIGINT || si.ssi_signo == SIGTERM) {
                        running = false;
                    }
                }
                continue;
            }

            if (fd == focus_db.fd()) {
                focus_db.read_and_consume();
                spawn_handler(FOCUS_HANDLER);
                continue;
            }
            if (fd == mon_db.fd()) {
                mon_db.read_and_consume();
                spawn_handler(MONITOR_HANDLER);
                continue;
            }
            if (fd == cfg_db.fd()) {
                cfg_db.read_and_consume();
                spawn_handler(CONFIG_HANDLER);
                continue;
            }
            if (fd == ino_fd) {
                drain_inotify(ino_fd);
                cfg_db.trigger();
                continue;
            }
            if (fd == hypr.fd()) {
                bool live = hypr.drain([&](const std::string& line) {
                    const HandlerSpec* spec = nullptr;
                    if (!classify_hypr_event(line, spec)) return;
                    if (spec == &FOCUS_HANDLER)   focus_db.trigger();
                    if (spec == &MONITOR_HANDLER) mon_db.trigger();
                    if (verbose) {
                        std::fprintf(stderr, "fox-pulse: %s -> %s\n",
                                     line.c_str(), spec->name);
                    }
                });
                if (!live) {
                    hypr.drop(epoll_fd);
                    last_reconnect = std::chrono::steady_clock::now();
                }
                continue;
            }
        }
    }

    if (ino_fd >= 0) ::close(ino_fd);
    ::close(sig_fd);
    hypr.drop(epoll_fd);
    ::close(epoll_fd);
    return 0;
}
