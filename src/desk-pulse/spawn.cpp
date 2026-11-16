#include "spawn.hpp"

#include <csignal>
#include <fcntl.h>
#include <unistd.h>

namespace desk_pulse {

void spawn_command(const std::string& cmd) {
    pid_t pid = ::fork();
    if (pid < 0) return;
    if (pid == 0) {
        // An ignored signal stays ignored across exec, and a blocked one stays blocked: put back what the daemon
        // changed for itself (SIGCHLD and SIGPIPE ignored, SIGINT and SIGTERM blocked for its signalfd).
        ::signal(SIGCHLD, SIG_DFL);
        ::signal(SIGPIPE, SIG_DFL);
        sigset_t none;
        sigemptyset(&none);
        ::sigprocmask(SIG_SETMASK, &none, nullptr);
        // Detach from the controlling terminal; stdio on /dev/null so the daemon's fds are not held open.
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
    // Parent: no wait. SIGCHLD is ignored in the daemon, so the kernel reaps the child when it exits.
}

}  // namespace desk_pulse
