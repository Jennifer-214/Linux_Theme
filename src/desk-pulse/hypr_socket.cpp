#include "hypr_socket.hpp"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace fox_pulse {

std::string resolve_hypr_socket2_path() {
    const char* runtime = std::getenv("XDG_RUNTIME_DIR");
    const char* his     = std::getenv("HYPRLAND_INSTANCE_SIGNATURE");
    if (!runtime || !his || !*runtime || !*his) return {};
    std::string p = runtime;
    p += "/hypr/";
    p += his;
    p += "/.socket2.sock";
    return p;
}

int connect_unix_stream(const std::string& path) {
    if (path.size() >= sizeof(sockaddr_un::sun_path)) return -1;

    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) return -1;

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, path.c_str(), path.size() + 1);

    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        // Non-blocking connect to a Unix stream returns 0 or fails immediately
        // (there's no SYN/ACK round-trip). EINPROGRESS doesn't really happen
        // for AF_UNIX/SOCK_STREAM, so treat any failure as fatal.
        if (errno != EINPROGRESS) {
            ::close(fd);
            return -1;
        }
    }
    return fd;
}

}  // namespace fox_pulse
