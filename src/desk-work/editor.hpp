// Messages to a running Neovim: one msgpack-RPC request over the editor's own socket, always nvim_exec_lua of
// BRIDGE_ENTRY, which hands the message to desk.bridge (shared/nvim_lua/desk/bridge.lua) to check and answer. The
// message is only ever that call's argument, never code. Every step has a deadline and the message carries it, so an
// editor stuck at a prompt costs the caller a second, and refuses the message when it gets to it.
const char* const BRIDGE_ENTRY = "return require('desk.bridge').receive(...)";

// The length of the first whole msgpack value in `bytes`: 0 while it is still arriving, npos when the bytes are not
// msgpack or nest deeper than 64. A notification that arrives ahead of the answer is skipped by it, exactly.
size_t msgpack_length(const std::string& bytes) {
    std::vector<unsigned long long> open{1};   // the values still to come at each depth
    size_t at = 0;
    const auto have = [&](unsigned long long n) { return n <= bytes.size() - at; };
    while (!open.empty()) {
        if (open.back() == 0) { open.pop_back(); continue; }
        --open.back();
        if (!have(1)) return 0;
        const auto tag = static_cast<unsigned char>(bytes[at++]);
        unsigned long long skip = 0, items = 0;
        size_t width = 0;
        char sized = 0;   // what a length field says: 's' bytes follow, 'e' bytes and their type, 'a' items, 'm' pairs
        if (tag <= 0x7f || tag >= 0xe0 || tag == 0xc0 || tag == 0xc2 || tag == 0xc3) {}
        else if (tag <= 0x8f) items = 2ULL * (tag & 0x0f);
        else if (tag <= 0x9f) items = tag & 0x0f;
        else if (tag <= 0xbf) skip = tag & 0x1f;
        else switch (tag) {
            case 0xc4: case 0xd9: width = 1; sized = 's'; break;
            case 0xc5: case 0xda: width = 2; sized = 's'; break;
            case 0xc6: case 0xdb: width = 4; sized = 's'; break;
            case 0xc7: width = 1; sized = 'e'; break;
            case 0xc8: width = 2; sized = 'e'; break;
            case 0xc9: width = 4; sized = 'e'; break;
            case 0xdc: width = 2; sized = 'a'; break;
            case 0xdd: width = 4; sized = 'a'; break;
            case 0xde: width = 2; sized = 'm'; break;
            case 0xdf: width = 4; sized = 'm'; break;
            case 0xca: skip = 4; break;
            case 0xcb: skip = 8; break;
            case 0xcc: case 0xd0: skip = 1; break;
            case 0xcd: case 0xd1: skip = 2; break;
            case 0xce: case 0xd2: skip = 4; break;
            case 0xcf: case 0xd3: skip = 8; break;
            case 0xd4: skip = 2; break;
            case 0xd5: skip = 3; break;
            case 0xd6: skip = 5; break;
            case 0xd7: skip = 9; break;
            case 0xd8: skip = 17; break;
            default: return std::string::npos;   // 0xc1 is never used
        }
        if (sized) {
            if (!have(width)) return 0;
            unsigned long long n = 0;
            for (size_t i = 0; i < width; ++i) n = (n << 8) | static_cast<unsigned char>(bytes[at + i]);
            at += width;
            if (sized == 's') skip = n; else if (sized == 'e') skip = n + 1; else if (sized == 'a') items = n; else items = 2 * n;
        }
        if (!have(skip)) return 0;
        at += skip;
        if (items) {
            if (open.size() >= 64) return std::string::npos;
            open.push_back(items);
        }
    }
    return at;
}
// msgpack is written recursively: a message nests at most `limit` deep.
bool shallow(const J& value, int limit) {
    std::vector<std::pair<const J*, int>> todo{{&value, 0}};
    while (!todo.empty()) {
        const auto [item, depth] = todo.back();
        todo.pop_back();
        if (depth > limit) return false;
        if (item->is_structured()) for (const auto& child : *item) todo.push_back({&child, depth + 1});
    }
    return true;
}
long long epoch_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}
// code: 0 answered · 1 refused there (message says why) · 2 not reached in time. editor: the record it went to.
struct EditorAnswer { int code = 2; J result; std::string message; J editor; };

EditorAnswer call_editor(const std::string& server, J message, int budget_ms) {
    EditorAnswer out;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(budget_ms);
    const auto left = [&] {
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
        return static_cast<int>(std::max<long long>(0, ms));
    };
    const auto unreached = [&](const std::string& why) { out.code = 2; out.message = why; return out; };
    const auto late = "The editor did not answer within " + std::to_string(budget_ms) + " ms";
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    struct stat info{};
    if (server.empty() || server[0] != '/' || server.size() >= sizeof(address.sun_path))
        return unreached("An editor's socket is an absolute path of up to 107 characters");
    if (::lstat(server.c_str(), &info) != 0 || !S_ISSOCK(info.st_mode) || info.st_uid != ::getuid())
        return unreached("No socket of yours is at " + server);
    std::memcpy(address.sun_path, server.data(), server.size());
    const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) return unreached("Could not open a socket");
    const struct Closer { int fd; ~Closer() { ::close(fd); } } closer{fd};
    while (::connect(fd, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0) {
        if (errno == EINTR) continue;
        // A full listen queue answers a socket that does not wait at once: again, until the deadline.
        if (errno == EAGAIN && left() > 0) { ::usleep(5000); continue; }
        return unreached("The editor at " + server + " is not listening (" + std::strerror(errno) + ")");
    }
    message["deadline"] = epoch_ms() + budget_ms;
    static unsigned serial = 0;
    const unsigned id = ++serial;
    const auto request = J::to_msgpack(J::array({0, id, "nvim_exec_lua", J::array({BRIDGE_ENTRY, J::array({message})})}));
    for (size_t sent = 0; sent < request.size();) {
        const auto n = ::send(fd, request.data() + sent, request.size() - sent, MSG_NOSIGNAL);
        if (n > 0) { sent += static_cast<size_t>(n); continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            pollfd ready{fd, POLLOUT, 0};
            const int waited = ::poll(&ready, 1, left());
            if (waited > 0 || (waited < 0 && errno == EINTR)) continue;
            return unreached(late);
        }
        return unreached("The editor closed the connection");
    }
    std::string received;
    char chunk[16384];
    for (;;) {
        for (size_t length; (length = msgpack_length(received)) != 0;) {
            if (length == std::string::npos) return unreached("The editor answered with something that is not msgpack-RPC");
            const auto value = J::from_msgpack(received.substr(0, length), true, false);
            received.erase(0, length);
            if (value.is_discarded()) return unreached("The editor's answer could not be read");
            if (!value.is_array() || value.size() != 4 || value[0] != 1 || value[1] != id) continue;   // not the answer
            if (!value[2].is_null()) {
                const auto& error = value[2];
                const auto said = error.is_array() && error.size() == 2 && error[1].is_string() ? error[1].get<std::string>()
                                                                                                 : error.dump(-1, ' ', false, J::error_handler_t::replace);
                out.code = 1;
                out.message = said.substr(0, said.find('\n')).substr(0, 300);
                return out;
            }
            out.result = value[3];
            const auto refused = out.result.is_object() ? out.result.find("refused") : out.result.end();
            if (refused != out.result.end() && refused->is_string()) { out.code = 1; out.message = refused->get<std::string>(); }
            else out.code = 0;
            return out;
        }
        if (received.size() > 4 * 1024 * 1024) return unreached("The editor's answer is larger than 4 MiB");
        pollfd ready{fd, POLLIN, 0};
        const int waited = ::poll(&ready, 1, left());
        if (waited < 0 && errno == EINTR) continue;
        if (waited <= 0) return unreached(late);
        const auto got = ::recv(fd, chunk, sizeof chunk, 0);
        if (got > 0) { received.append(chunk, static_cast<size_t>(got)); continue; }
        if (got < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        return unreached("The editor closed the connection without answering");
    }
}
// A message for her editor on a checkout goes to the socket named, else to a live main editor of the checkout; with
// several, each is pinged briefly and the one she focused last takes it.
EditorAnswer ask_editor(const std::string& root, const std::string& server, J message) {
    EditorAnswer out;
    const auto refused = [&](const std::string& why) { out.code = 1; out.message = why; return out; };
    if (!message.is_object() || !shallow(message, 8)) return refused("A message is one JSON object, nested at most 8 deep");
    if (!message.contains("root")) message["root"] = root;
    if (message["root"] != root) return refused("The message names another checkout than --root");
    J chosen = server.empty() ? J() : J{{"server", server}, {"pane", ""}};
    if (chosen.is_null()) {
        J mains = J::array();
        for (const auto& editor : live_editors(root))
            if (str(editor, "role") == "main" && !str(editor, "server").empty() && mains.size() < 8) mains.push_back(editor);
        if (mains.empty()) { out.message = "No Neovim on this checkout is listening"; return out; }
        if (mains.size() == 1) chosen = mains[0];
        else {
            long long latest = -1;
            for (const auto& editor : mains) {
                const auto pong = call_editor(str(editor, "server"), J{{"version", 1}, {"type", "ping"}, {"root", root}}, 300);
                if (pong.code == 0 && num(pong.result, "last_focus") > latest) { latest = num(pong.result, "last_focus"); chosen = editor; }
            }
            if (chosen.is_null()) { out.message = "No Neovim on this checkout answered"; return out; }
        }
    }
    out = call_editor(str(chosen, "server"), message, 1000);
    out.editor = chosen;
    return out;
}
