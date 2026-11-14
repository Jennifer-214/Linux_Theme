// ssh_harden's port: read from `sshd -T`, and the key self-test connects on it (it always tried 22, so a re-run after
// a move failed the test and turned passwords back on).
#include "../modules/ssh_port.hpp"

#include <cstdio>

using namespace desk_install::ssh_port;

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}

static bool has_port(const std::vector<std::string>& argv, const std::string& port) {
    for (std::size_t i = 0; i + 1 < argv.size(); ++i)
        if (argv[i] == "-p") return argv[i + 1] == port;
    return false;
}

int main() {
    const std::string moved = "addressfamily any\nport 2222\nlistenaddress 0.0.0.0:2222\npasswordauthentication no\n";
    expect(listen_port(moved) == 2222, "the port sshd -T reports");
    expect(listen_port("port 2222\nport 2223\n") == 2222, "the first of several");
    expect(listen_port("") == 22, "no output (sshd -T failed): 22");
    expect(listen_port("passwordauthentication yes\n") == 22, "no port line: 22");
    expect(listen_port("port 0\n") == 22 && listen_port("port 70000\n") == 22, "not a port: 22");
    expect(listen_port("ports 2222\n") == 22, "a key is a whole word");

    const auto argv = key_test_argv("alice", 2222);
    expect(has_port(argv, "2222"), "the key test connects on the port sshd listens on");
    expect(has_port(key_test_argv("alice", 22), "22"), "and on 22 when that is the port");
    expect(!argv.empty() && argv.front() == "ssh" && argv.back() == "true", "ssh ... true");
    bool batch = false, nopass = false, target = false;
    for (const auto& a : argv) {
        batch |= a == "BatchMode=yes";
        nopass |= a == "PasswordAuthentication=no";
        target |= a == "alice@127.0.0.1";
    }
    expect(batch && nopass, "never falls back to a password");
    expect(target, "logs in as the user on 127.0.0.1");

    if (failures == 0) std::printf("test_ssh_port: ok\n");
    return failures == 0 ? 0 : 1;
}
