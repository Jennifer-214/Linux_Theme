#include "polkit_watch.hpp"

#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sys/stat.h>

namespace fox_pulse {

namespace {
std::string first_line(const std::string& path) {
    std::ifstream in(path);
    std::string line;
    std::getline(in, line);
    return line;
}
bool owned_by(const std::string& path, uid_t uid) {
    struct stat st{};
    return ::stat(path.c_str(), &st) == 0 && st.st_uid == uid;
}
}  // namespace

bool process_named(const std::string& proc, long pid, const std::string& comm, uid_t uid) {
    if (pid <= 0) return false;
    const std::string dir = proc + "/" + std::to_string(pid);
    return owned_by(dir, uid) && first_line(dir + "/comm") == comm;
}

bool any_process_named(const std::string& proc, const std::string& comm, uid_t uid) {
    std::error_code ec;
    for (const auto& entry : std::filesystem::directory_iterator(proc, ec)) {
        const auto name = entry.path().filename().string();
        if (name.empty() || !std::isdigit(static_cast<unsigned char>(name[0]))) continue;
        if (process_named(proc, std::strtol(name.c_str(), nullptr, 10), comm, uid)) return true;
    }
    return false;
}

bool AgentWatch::tick(const std::string& proc, const std::string& marker, uid_t uid) {
    const auto held = first_line(marker);
    const long pid = held.empty() ? 0 : std::strtol(held.c_str(), nullptr, 10);
    if (process_named(proc, pid, "quickshell", uid) || any_process_named(proc, "hyprpolkitagent", uid)) {
        misses = 0;
        return false;
    }
    // One miss can be the moment the paper prompt takes over (it stops hyprpolkitagent, then registers).
    if (++misses < 2) return false;
    misses = 0;
    return true;
}

}  // namespace fox_pulse
