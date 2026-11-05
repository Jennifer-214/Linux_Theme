#pragma once
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>

namespace fox_install::notifications {

inline bool binary_changed(const std::filesystem::path& installed,
                           const std::filesystem::path& running) {
    std::ifstream a(installed, std::ios::binary), b(running, std::ios::binary);
    if (!a || !b) return true;
    return !std::equal(std::istreambuf_iterator<char>(a), std::istreambuf_iterator<char>(),
                       std::istreambuf_iterator<char>(b), std::istreambuf_iterator<char>());
}

// Atomic deployment changes the inode even on a recolor. Compare the running
// executable's bytes so palette-only updates can keep the notification queue.
inline bool running_binary_changed(const std::filesystem::path& installed,
                                   const std::string& pids,
                                   const std::filesystem::path& proc = "/proc") {
    std::istringstream input(pids);
    std::string pid;
    while (input >> pid) {
        if (pid.empty() || pid.find_first_not_of("0123456789") != std::string::npos) continue;
        const auto executable = proc / pid / "exe";
        std::error_code ec;
        if (std::filesystem::exists(executable, ec) && binary_changed(installed, executable)) return true;
    }
    return false;
}

} // namespace fox_install::notifications
