#include "install_lock.hpp"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace fox_install::lockfile {

namespace {

std::string lockfile_path() {
    fs::path dir;
    if (const char* xdg = std::getenv("XDG_RUNTIME_DIR"); xdg && *xdg) {
        dir = xdg;
    } else {
        // /tmp is universal but world-writable — use the per-uid name
        // to avoid collisions with a different user's install. The
        // lockfile mode (0600 on create) keeps the contents private.
        dir = "/tmp";
    }
    std::error_code ec;
    fs::create_directories(dir, ec);  // no-op if it already exists
    return (dir / ("foxml-install-" + std::to_string(::geteuid()) + ".lock")).string();
}

int read_holder_pid(int fd) {
    char buf[32]{};
    // Rewind first — flock doesn't reposition; if we just opened the
    // file, position is 0, but be defensive in case the kernel ever
    // surprises us.
    if (::lseek(fd, 0, SEEK_SET) < 0) return 0;
    ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
    if (n <= 0) return 0;
    buf[n] = '\0';
    char* end = nullptr;
    long pid = std::strtol(buf, &end, 10);
    if (end == buf || pid <= 0 || pid > 0x7FFFFFFF) return 0;
    return static_cast<int>(pid);
}

bool write_holder_pid(int fd) {
    if (::ftruncate(fd, 0) != 0) return false;
    if (::lseek(fd, 0, SEEK_SET) < 0) return false;
    std::string s = std::to_string(::getpid()) + "\n";
    ssize_t want = static_cast<ssize_t>(s.size());
    ssize_t got  = ::write(fd, s.data(), s.size());
    return got == want;
}

}  // namespace

AcquireResult acquire() {
    AcquireResult r;
    r.path = lockfile_path();

    int fd = ::open(r.path.c_str(),
                    O_RDWR | O_CREAT | O_CLOEXEC,
                    0600);
    if (fd < 0) {
        r.error_msg = "open " + r.path + ": " + std::strerror(errno);
        return r;
    }

    if (::flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK || errno == EAGAIN) {
            r.holder_pid = read_holder_pid(fd);
        } else {
            r.error_msg = std::string("flock: ") + std::strerror(errno);
        }
        ::close(fd);
        return r;
    }

    // We hold the lock — stamp our PID so the next would-be acquirer
    // can report it. A failure here isn't fatal (the lock still
    // works); just log a warning via the empty pid path.
    if (!write_holder_pid(fd)) {
        // Don't bail — the lock is genuinely held, just unstamped.
    }
    r.fd = fd;
    return r;
}

void release(int fd) {
    if (fd >= 0) ::close(fd);
}

}  // namespace fox_install::lockfile
