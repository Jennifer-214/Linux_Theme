// modules/ssh_port.cpp — the root reads behind ssh_port.hpp. `sudo -n`: these never prompt; a module warms sudo first,
// and a dry run with a cold cache reports the port as unknown.
#include "ssh_port.hpp"

#include "../../desk-common/shell.hpp"

namespace desk_install::ssh_port {

bool sshd_t(std::string& out) {
    return sh::capture({"sudo", "-n", "sshd", "-T"}, out);
}

std::optional<std::vector<int>> configured() {
    std::string out;
    if (!sshd_t(out)) return std::nullopt;
    auto ports = listen_ports(out);
    if (ports.empty()) return std::nullopt;
    return ports;
}

std::vector<std::string> listeners_now(int port) {
    std::string out;
    if (!sh::capture({"sudo", "-n", "ss", "-tlnpH"}, out)) sh::capture({"ss", "-tlnH"}, out);
    return listeners(out, port);
}

}  // namespace desk_install::ssh_port
