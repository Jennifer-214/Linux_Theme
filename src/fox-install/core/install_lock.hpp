// install_lock.hpp — per-uid lockfile guarding the install run.
//
// Phase 6 Step 14 / R17. Prevents two interactive fox-install
// invocations from racing each other — the wizard's terminal state
// + the manifest writes + sudo prompts all assume there's only one
// install in flight at a time.
//
// Lock path is $XDG_RUNTIME_DIR/foxml-install-<uid>.lock when that
// env var is set (Linux convention; auto-cleaned on logout), falling
// back to /tmp/foxml-install-<uid>.lock otherwise. Per-uid so users
// on the same machine don't block each other.
//
// The lock is a kernel flock(LOCK_EX | LOCK_NB) on an empty file —
// non-blocking so a second invocation fails fast instead of hanging.
// The lockfile itself stores the holder's PID so the failing
// invocation can report who's holding it.

#pragma once

#include <string>

namespace fox_install::lockfile {

struct AcquireResult {
    int         fd          = -1;    // >= 0 on success, -1 on failure
    int         holder_pid  = 0;     // > 0 when failure is "another install running"
    std::string error_msg;           // set when fd < 0 AND holder_pid == 0
    std::string path;                // the lockfile path, for log/diagnostic use
};

// Try to acquire the install lock. On success, writes our PID into
// the lockfile and returns fd >= 0; the caller keeps the fd open for
// the duration of the install. On contention, returns fd == -1 and
// holder_pid set to the other process. On system error, fd == -1 and
// error_msg populated.
AcquireResult acquire();

// Close the lockfile fd, dropping the flock. Process exit does this
// automatically, but call explicitly when releasing the lock matters
// (e.g., after wizard abort but before a subsequent re-entry).
void release(int fd);

}  // namespace fox_install::lockfile
