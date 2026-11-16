// modules/stale_services.hpp — user services still running a program this install replaced.
//
// A daemon keeps the file it started with. The install lays programs by rename (desk-pulse's `make install`, the bulk
// deploy of ~/.local/bin and the Hyprland scripts), so a running desk-pulse or bouncer goes on running the old copy,
// deleted from disk, until it restarts, and logging out is rare (2026-11-16: both ran the day before's version).
// Read only in /proc: the processes of a service of the user's own (its unit file in `units`), and the program each
// runs or the script an interpreter keeps open, when that file is gone from disk and the one now at its path holds
// other bytes (a rename of the same bytes is not a new version). Shared by the installer, which restarts the watchers
// among them, and `desk theme check` (D25), which names them all.
#pragma once

#include "../../desk-common/shell.hpp"

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace desk_install::stale {

struct Service {
    std::string unit;                // fox-pulse.service
    std::vector<long long> pids;     // its processes running a replaced program
    std::vector<std::string> files;  // the paths whose program changed under them
};

// The unit of a process that a user's service manager runs (0::/user.slice/…/user@1000.service/app.slice/x.service),
// else empty: a system service, a scope, the manager itself. /proc/PID/cgroup's unified line ("0::") when it has one.
inline std::string user_service(const std::string& cgroup) {
    std::string line = cgroup.substr(0, cgroup.find('\n'));
    for (std::size_t at = 0; at < cgroup.size();) {
        const auto end = cgroup.find('\n', at);
        if (cgroup.compare(at, 3, "0::") == 0) { line = cgroup.substr(at, end == std::string::npos ? std::string::npos : end - at); break; }
        if (end == std::string::npos) break;
        at = end + 1;
    }
    const auto manager = line.find("/user@");
    const auto last = line.rfind('/');
    if (manager == std::string::npos || last == std::string::npos || last <= manager) return {};
    const std::string unit = line.substr(last + 1);
    const std::string suffix = ".service";
    if (unit.size() <= suffix.size() || unit.compare(unit.size() - suffix.size(), suffix.size(), suffix) != 0) return {};
    return unit;
}

// "/home/x/.local/bin/desk-pulse (deleted)", as /proc shows a link to a file gone from disk, → its path.
inline std::string deleted_path(const std::string& target) {
    const std::string mark = " (deleted)";
    if (target.size() <= mark.size() || target[0] != '/' ||
        target.compare(target.size() - mark.size(), mark.size(), mark) != 0) return {};
    return target.substr(0, target.size() - mark.size());
}

// Both readable and byte for byte different; a file that cannot be read is never taken for a new version.
inline bool other_bytes(const std::filesystem::path& a, const std::filesystem::path& b) {
    std::ifstream x(a, std::ios::binary), y(b, std::ios::binary);
    if (!x || !y) return false;
    return !std::equal(std::istreambuf_iterator<char>(x), std::istreambuf_iterator<char>(),
                       std::istreambuf_iterator<char>(y), std::istreambuf_iterator<char>());
}

inline std::vector<Service> replaced_code(const std::filesystem::path& home, const std::filesystem::path& units,
                                          uid_t uid, const std::filesystem::path& proc = "/proc") {
    namespace fs = std::filesystem;
    std::vector<Service> found;
    const std::string under = home.string() + "/";
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(proc, ec)) {
        const auto name = entry.path().filename().string();
        struct stat st{};
        if (name.empty() || name.find_first_not_of("0123456789") != std::string::npos ||
            ::stat(entry.path().c_str(), &st) != 0 || st.st_uid != uid) continue;
        std::ifstream cgroup(entry.path() / "cgroup");
        const std::string unit = user_service(std::string(std::istreambuf_iterator<char>(cgroup), {}));
        if (unit.empty()) continue;
        const auto at = unit.find('@');
        const std::string file = at == std::string::npos ? unit : unit.substr(0, at + 1) + ".service";
        std::error_code uec;
        if (!fs::exists(units / file, uec)) continue;  // a transient unit (an app) is not one of hers
        std::vector<fs::path> links{entry.path() / "exe"};
        std::error_code dec;
        for (const auto& fd : fs::directory_iterator(entry.path() / "fd", dec)) links.push_back(fd.path());
        for (const auto& link : links) {
            std::error_code lec;
            const auto path = deleted_path(fs::read_symlink(link, lec).string());
            if (lec || path.empty() || path.rfind(under, 0) != 0) continue;
            if (!fs::is_regular_file(path, lec) || ::access(path.c_str(), X_OK) != 0 || !other_bytes(link, path)) continue;
            auto svc = std::find_if(found.begin(), found.end(), [&](const Service& s) { return s.unit == unit; });
            if (svc == found.end()) svc = found.insert(found.end(), Service{unit, {}, {}});
            const long long pid = std::stoll(name);
            if (std::find(svc->pids.begin(), svc->pids.end(), pid) == svc->pids.end()) svc->pids.push_back(pid);
            if (std::find(svc->files.begin(), svc->files.end(), path) == svc->files.end()) svc->files.push_back(path);
        }
    }
    std::sort(found.begin(), found.end(), [](const Service& a, const Service& b) { return a.unit < b.unit; });
    for (auto& svc : found) std::sort(svc.pids.begin(), svc.pids.end());
    return found;
}

// The watchers that lose nothing by a restart: each comes back watching. Never fox-vault (a restart empties it) or a
// model server (it would load its model again).
inline bool restart_safe(const std::string& unit) {
    for (const char* safe : {"fox-pulse.service", "fox-bouncer.service", "fox-sentry-audit.service",
                             "fox-tripwire.service", "fox-proximity.service", "power-state-watcher.service"})
        if (unit == safe) return true;
    return false;
}

// `systemctl --user try-restart` for each restart-safe unit named (try-restart starts nothing that is stopped). The
// units it restarted, in order.
inline std::vector<std::string> try_restart(const std::vector<std::string>& units) {
    std::vector<std::string> done;
    for (const auto& unit : units)
        if (restart_safe(unit) && sh::run({"systemctl", "--user", "try-restart", unit}) == 0) done.push_back(unit);
    return done;
}

// The installer's step: restart the watchers among the services still running a replaced program.
inline std::vector<std::string> restart_replaced(const std::filesystem::path& home, const std::filesystem::path& units,
                                                 uid_t uid, const std::filesystem::path& proc = "/proc") {
    std::vector<std::string> names;
    for (const auto& svc : replaced_code(home, units, uid, proc)) names.push_back(svc.unit);
    return try_restart(names);
}

}  // namespace desk_install::stale
