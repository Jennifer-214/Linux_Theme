// modules/ssh_port.hpp — ssh_harden's port handling, pure so tests/test_ssh_port pins it. The key self-test must reach
// sshd on the port it listens on now: after a run that moved sshd off 22, a re-run that tried 22 failed and wrote
// `PasswordAuthentication yes`.
#pragma once

#include <sstream>
#include <string>
#include <vector>

namespace desk_install::ssh_port {

// The first `port N` line of `sshd -T` output; 22 (sshd's default) when there is none or it is not a port.
inline int listen_port(const std::string& sshd_t) {
    std::istringstream in(sshd_t);
    for (std::string line; std::getline(in, line);) {
        std::istringstream f(line);
        std::string key;
        long n = 0;
        if (f >> key && key == "port" && f >> n) return n >= 1 && n <= 65535 ? static_cast<int>(n) : 22;
    }
    return 22;
}

// BatchMode + PasswordAuthentication=no: a 0 exit means a key authenticated, never a password.
inline std::vector<std::string> key_test_argv(const std::string& user, int port) {
    return {"ssh", "-p", std::to_string(port), "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no",
            "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new", user + "@127.0.0.1", "true"};
}

}  // namespace desk_install::ssh_port
