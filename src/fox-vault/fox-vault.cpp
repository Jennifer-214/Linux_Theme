// fox-vault — mlock'd in-RAM secret store with a Unix-socket CLI.
//
// Usage:
//   fox-vault start           # fork+daemonize; socket = $XDG_RUNTIME_DIR/fox-vault.sock
//   fox-vault stop            # tell the daemon to wipe + exit
//   fox-vault set <name>      # read value from stdin (until EOF), store
//   fox-vault get <name>      # print value to stdout, no newline
//   fox-vault del <name>
//   fox-vault list
//   fox-vault clear
//
// Wire protocol (newline-framed, length-prefixed values):
//
//   client                              daemon
//   ------                              ------
//   SET <name> <len>\n<bytes>           OK\n          | ERR <msg>\n
//   GET <name>\n                        VAL <len>\n<bytes>  | ERR\n
//   DEL <name>\n                        OK\n          | ERR\n
//   LIST\n                              LIST <n>\n<name1>\n…<nameN>\n
//   CLEAR\n                             OK\n
//   SHUTDOWN\n                          OK\n          (daemon exits)

#include "vault_store.hpp"

#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

namespace {

std::string socket_path() {
    const char* runtime = std::getenv("XDG_RUNTIME_DIR");
    if (runtime && *runtime) return std::string(runtime) + "/fox-vault.sock";
    // RUNTIME_DIR is the only sane default on Arch+Hyprland; bail loudly
    // rather than silently dropping the socket in $TMPDIR (world-listable).
    return {};
}

int bind_listen_socket(const std::string& path) {
    if (path.empty()) return -1;
    ::unlink(path.c_str());

    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (path.size() >= sizeof(addr.sun_path)) { ::close(fd); return -1; }
    std::memcpy(addr.sun_path, path.c_str(), path.size() + 1);

    // umask narrows the socket inode to 0600 before bind() creates it,
    // so a concurrent connect from another UID is closed before we
    // even chmod.
    mode_t old = ::umask(0177);
    int rc = ::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    ::umask(old);
    if (rc < 0) { ::close(fd); return -1; }
    ::chmod(path.c_str(), 0600);
    if (::listen(fd, 4) < 0) { ::close(fd); return -1; }
    return fd;
}

int connect_socket(const std::string& path) {
    if (path.empty()) return -1;
    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, path.c_str(), path.size() + 1);
    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

ssize_t read_full(int fd, void* buf, size_t n) {
    auto* p = static_cast<uint8_t*>(buf);
    size_t got = 0;
    while (got < n) {
        ssize_t r = ::read(fd, p + got, n - got);
        if (r > 0)        got += static_cast<size_t>(r);
        else if (r == 0)  return got;
        else if (errno == EINTR) continue;
        else return -1;
    }
    return got;
}

ssize_t write_full(int fd, const void* buf, size_t n) {
    auto* p = static_cast<const uint8_t*>(buf);
    size_t sent = 0;
    while (sent < n) {
        ssize_t r = ::write(fd, p + sent, n - sent);
        if (r > 0)       sent += static_cast<size_t>(r);
        else if (errno == EINTR) continue;
        else return -1;
    }
    return sent;
}

// Reads a single \n-terminated line into `out`. Returns false on EOF.
bool read_line(int fd, std::string& out) {
    out.clear();
    char c;
    for (;;) {
        ssize_t r = ::read(fd, &c, 1);
        if (r == 0) return !out.empty();
        if (r < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (c == '\n') return true;
        out.push_back(c);
        if (out.size() > 65536) return false;   // sanity cap
    }
}

// ─── daemon ─────────────────────────────────────────────────────────────
//
// `daemonize` controls whether we double-fork into the background.
//   * true  — CLI invocation: parent exits 0, child runs the loop.
//             Used when a user runs `fox-vault start` from a shell.
//   * false — systemd Type=simple invocation. The unit runs the binary
//             as its own main process; if we double-fork here systemd
//             loses the PID and marks the service failed. Used for
//             ExecStart=fox-vault start --foreground.
int run_daemon(bool daemonize) {
    std::string sock = socket_path();
    if (sock.empty()) {
        std::fprintf(stderr, "fox-vault: XDG_RUNTIME_DIR unset\n");
        return 1;
    }
    int listen_fd = bind_listen_socket(sock);
    if (listen_fd < 0) {
        std::fprintf(stderr, "fox-vault: bind/listen failed: %s\n", std::strerror(errno));
        return 1;
    }

    if (daemonize) {
        // Double-fork, detach from controlling tty.
        pid_t pid = ::fork();
        if (pid < 0) { std::perror("fox-vault: fork"); return 1; }
        if (pid > 0) return 0;                       // parent exits, CLI returns
        ::setsid();
        pid = ::fork();
        if (pid < 0) ::_exit(1);
        if (pid > 0) ::_exit(0);
        ::chdir("/");
        int dn = ::open("/dev/null", O_RDWR | O_CLOEXEC);
        if (dn >= 0) {
            ::dup2(dn, STDIN_FILENO);
            ::dup2(dn, STDOUT_FILENO);
            ::dup2(dn, STDERR_FILENO);
            if (dn > 2) ::close(dn);
        }
    }
    ::signal(SIGPIPE, SIG_IGN);

    fox_vault::Vault vault;
    const uid_t my_uid = ::getuid();
    bool running = true;
    while (running) {
        int client = ::accept4(listen_fd, nullptr, nullptr, SOCK_CLOEXEC);
        if (client < 0) {
            if (errno == EINTR) continue;
            break;
        }
        // Defense in depth: the socket already has mode 0600 and lives
        // in $XDG_RUNTIME_DIR which is per-uid 0700, so a different
        // user can't normally connect. SO_PEERCRED enforces that
        // boundary at the kernel level too — if the socket path ever
        // ends up with looser perms or in /tmp, the kernel still
        // rejects cross-uid connections here.
        struct ucred peer{};
        socklen_t peer_len = sizeof(peer);
        if (::getsockopt(client, SOL_SOCKET, SO_PEERCRED, &peer, &peer_len) != 0
            || peer.uid != my_uid) {
            ::close(client);
            continue;
        }
        std::string cmd;
        while (read_line(client, cmd)) {
            if (cmd.rfind("SET ", 0) == 0) {
                // "SET <name> <len>"
                size_t sp1 = cmd.find(' ', 4);
                if (sp1 == std::string::npos) {
                    write_full(client, "ERR bad-format\n", 15);
                    continue;
                }
                std::string name = cmd.substr(4, sp1 - 4);
                size_t len = std::strtoul(cmd.c_str() + sp1 + 1, nullptr, 10);
                if (len > (1u << 20)) {       // 1 MiB cap
                    write_full(client, "ERR too-large\n", 14);
                    continue;
                }
                std::vector<uint8_t> buf(len);
                if (len > 0 && read_full(client, buf.data(), len) != (ssize_t)len) {
                    write_full(client, "ERR short-read\n", 15);
                    continue;
                }
                bool ok = vault.set(name, buf.data(), len);
                explicit_bzero(buf.data(), buf.size());
                write_full(client, ok ? "OK\n" : "ERR alloc\n", ok ? 3 : 10);
            }
            else if (cmd.rfind("GET ", 0) == 0) {
                std::string name = cmd.substr(4);
                std::string val;
                if (!vault.get(name, val)) { write_full(client, "ERR\n", 4); continue; }
                char hdr[64];
                int hl = std::snprintf(hdr, sizeof(hdr), "VAL %zu\n", val.size());
                write_full(client, hdr, hl);
                write_full(client, val.data(), val.size());
                explicit_bzero(&val[0], val.size());
            }
            else if (cmd.rfind("DEL ", 0) == 0) {
                bool ok = vault.del(cmd.substr(4));
                write_full(client, ok ? "OK\n" : "ERR\n", ok ? 3 : 4);
            }
            else if (cmd == "LIST") {
                auto names = vault.list();
                char hdr[64];
                int hl = std::snprintf(hdr, sizeof(hdr), "LIST %zu\n", names.size());
                write_full(client, hdr, hl);
                for (auto& n : names) {
                    write_full(client, n.data(), n.size());
                    write_full(client, "\n", 1);
                }
            }
            else if (cmd == "CLEAR") {
                vault.clear();
                write_full(client, "OK\n", 3);
            }
            else if (cmd == "SHUTDOWN") {
                write_full(client, "OK\n", 3);
                running = false;
                break;
            }
            else if (cmd == "QUIT" || cmd.empty()) {
                break;
            }
            else {
                write_full(client, "ERR unknown\n", 12);
            }
        }
        ::close(client);
    }

    ::close(listen_fd);
    ::unlink(sock.c_str());
    return 0;
}

// ─── client helpers ─────────────────────────────────────────────────────
int send_simple(const std::string& cmd, std::string* response_line = nullptr) {
    int fd = connect_socket(socket_path());
    if (fd < 0) {
        std::fprintf(stderr, "fox-vault: daemon not running (is the socket present?)\n");
        return 1;
    }
    std::string line = cmd + "\n";
    write_full(fd, line.data(), line.size());
    std::string resp;
    bool got = read_line(fd, resp);
    ::close(fd);
    if (response_line) *response_line = resp;
    if (!got || resp.rfind("ERR", 0) == 0) {
        if (got) std::fprintf(stderr, "fox-vault: %s\n", resp.c_str());
        return 1;
    }
    return 0;
}

int cmd_set(const std::string& name) {
    std::vector<uint8_t> buf;
    buf.reserve(256);
    uint8_t chunk[4096];
    for (;;) {
        ssize_t r = ::read(STDIN_FILENO, chunk, sizeof(chunk));
        if (r > 0) buf.insert(buf.end(), chunk, chunk + r);
        else if (r == 0) break;
        else if (errno == EINTR) continue;
        else { std::perror("fox-vault: read stdin"); return 1; }
    }
    int fd = connect_socket(socket_path());
    if (fd < 0) { std::fprintf(stderr, "fox-vault: daemon not running\n"); return 1; }
    char hdr[256];
    int hl = std::snprintf(hdr, sizeof(hdr), "SET %s %zu\n", name.c_str(), buf.size());
    write_full(fd, hdr, hl);
    write_full(fd, buf.data(), buf.size());
    explicit_bzero(buf.data(), buf.size());
    std::string resp;
    read_line(fd, resp);
    ::close(fd);
    if (resp != "OK") {
        std::fprintf(stderr, "fox-vault: %s\n", resp.c_str());
        return 1;
    }
    return 0;
}

int cmd_get(const std::string& name) {
    int fd = connect_socket(socket_path());
    if (fd < 0) { std::fprintf(stderr, "fox-vault: daemon not running\n"); return 1; }
    std::string line = "GET " + name + "\n";
    write_full(fd, line.data(), line.size());
    std::string hdr;
    if (!read_line(fd, hdr)) { ::close(fd); return 1; }
    if (hdr.rfind("VAL ", 0) != 0) {
        ::close(fd);
        std::fprintf(stderr, "fox-vault: %s\n", hdr.c_str());
        return 1;
    }
    size_t len = std::strtoul(hdr.c_str() + 4, nullptr, 10);
    std::vector<char> body(len);
    if (len > 0 && read_full(fd, body.data(), len) != (ssize_t)len) {
        ::close(fd); return 1;
    }
    ::close(fd);
    write_full(STDOUT_FILENO, body.data(), body.size());
    explicit_bzero(body.data(), body.size());
    return 0;
}

int cmd_list() {
    int fd = connect_socket(socket_path());
    if (fd < 0) { std::fprintf(stderr, "fox-vault: daemon not running\n"); return 1; }
    write_full(fd, "LIST\n", 5);
    std::string hdr;
    if (!read_line(fd, hdr) || hdr.rfind("LIST ", 0) != 0) {
        ::close(fd); return 1;
    }
    size_t n = std::strtoul(hdr.c_str() + 5, nullptr, 10);
    for (size_t i = 0; i < n; ++i) {
        std::string name;
        if (!read_line(fd, name)) break;
        std::printf("%s\n", name.c_str());
    }
    ::close(fd);
    return 0;
}

void usage(const char* a0) {
    std::fprintf(stderr,
        "Usage:\n"
        "  %s start [--foreground]   # start daemon (background by default;\n"
        "                            # --foreground for systemd Type=simple)\n"
        "  %s stop | clear | list\n"
        "  %s set <name>             # value from stdin\n"
        "  %s get <name>\n"
        "  %s del <name>\n",
        a0, a0, a0, a0, a0);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) { usage(argv[0]); return 2; }
    std::string sub = argv[1];

    if (sub == "start") {
        bool foreground = false;
        for (int i = 2; i < argc; ++i) {
            std::string a = argv[i];
            if (a == "--foreground" || a == "-f") foreground = true;
        }
        return run_daemon(/*daemonize=*/!foreground);
    }
    if (sub == "stop")      return send_simple("SHUTDOWN");
    if (sub == "clear")     return send_simple("CLEAR");
    if (sub == "list")      return cmd_list();
    if (sub == "set" && argc >= 3) return cmd_set(argv[2]);
    if (sub == "get" && argc >= 3) return cmd_get(argv[2]);
    if (sub == "del" && argc >= 3) return send_simple(std::string("DEL ") + argv[2]);

    usage(argv[0]);
    return 2;
}
