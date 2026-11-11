// polkit_watch — keeps a polkit prompt in the session. The paper prompt (Quickshell) writes its pid to a marker
// while it holds the agent; when that marker is missing or stale on two ticks in a row and hyprpolkitagent is not
// running either, the session has no prompt, and desk-pulse starts hyprpolkitagent.
#pragma once

#include <string>
#include <sys/types.h>

namespace fox_pulse {

bool process_named(const std::string& proc, long pid, const std::string& comm, uid_t uid);
bool any_process_named(const std::string& proc, const std::string& comm, uid_t uid);

struct AgentWatch {
    int misses = 0;
    // True when hyprpolkitagent should be started now.
    bool tick(const std::string& proc, const std::string& marker, uid_t uid);
};

}  // namespace fox_pulse
