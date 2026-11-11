#ifndef FOX_PULSE_HYPR_SOCKET_HPP
#define FOX_PULSE_HYPR_SOCKET_HPP

#include <string>

namespace fox_pulse {

// Resolves $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock.
// Returns empty string if either env var is unset.
std::string resolve_hypr_socket2_path();

// Connects to a Unix-domain stream socket at `path` and returns the fd
// (set to non-blocking + close-on-exec). Returns -1 on failure.
int connect_unix_stream(const std::string& path);

}  // namespace fox_pulse

#endif
