// desk-pulse's handlers run detached: a command through /bin/sh, never waited on (the daemon ignores SIGCHLD, so the
// kernel reaps them). What the daemon does to its own signals must not reach them.
#pragma once

#include <string>

namespace desk_pulse {

// Runs `cmd` with /bin/sh -c in a new session, stdio on /dev/null. The child starts with every signal at its default
// and none blocked: an inherited ignored SIGCHLD makes every waitpid in it fail (desk-monitor's reconcile then sees no
// monitors and gives up), and the daemon's blocked SIGINT/SIGTERM would make it unstoppable.
void spawn_command(const std::string& cmd);

}  // namespace desk_pulse
