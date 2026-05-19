// Tests for install_lock. Self-contained: each test acquires the
// lock, asserts on the result, releases (close fd), and re-tests
// from a clean state. The test runs with the dev user's $XDG_RUNTIME_DIR
// (or /tmp fallback) — same path the real installer uses, which is
// fine because no real fox-install is running while the tests run.

#include "../core/install_lock.hpp"

#include <filesystem>
#include <iostream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace fox_install::lockfile;

static int failures = 0;
#define EXPECT(cond) do { \
    if (!(cond)) { \
        std::cerr << "  FAIL: " #cond " at line " << __LINE__ << "\n"; \
        ++failures; \
    } else { \
        std::cout << "  ok: " #cond "\n"; \
    } \
} while (0)

int main() {
    std::cout << "test_install_lock:\n";

    // T1: clean acquire on a system where nothing else holds the lock.
    int first_fd = -1;
    {
        AcquireResult r = acquire();
        EXPECT(r.fd >= 0);
        EXPECT(r.holder_pid == 0);
        EXPECT(r.error_msg.empty());
        EXPECT(!r.path.empty());
        EXPECT(fs::exists(r.path));
        first_fd = r.fd;
    }

    // T2: second acquire while the first is still held → contention.
    // holder_pid should be set to our own PID (we wrote it ourselves
    // in T1, and acquire() in T2 reads it back from the lockfile).
    {
        AcquireResult r = acquire();
        EXPECT(r.fd == -1);
        EXPECT(r.holder_pid == ::getpid());
        EXPECT(r.error_msg.empty());  // contention isn't a system error
    }

    // T3: release the first → next acquire succeeds.
    release(first_fd);
    {
        AcquireResult r = acquire();
        EXPECT(r.fd >= 0);
        EXPECT(r.holder_pid == 0);
        release(r.fd);
    }

    // T4: release(-1) is a no-op (not a crash).
    release(-1);
    std::cout << "  ok: release(-1) is a no-op\n";

    if (failures == 0) {
        std::cout << "install_lock tests: OK\n";
        return 0;
    }
    std::cerr << "install_lock tests: FAILED (" << failures << " failures)\n";
    return 1;
}
