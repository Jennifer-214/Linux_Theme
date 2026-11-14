// modules/boot_files.hpp — where the kernel command line lives, found one way by every module that edits it (iommu,
// lockdown_heal, nvidia, security's AppArmor step, recovery_entry). systemd-boot's default entry is the one
// loader.conf names (archinstall writes <date>_linux.conf, not arch.conf). A /boot the user cannot read (an ESP
// mounted dmask=0077) is its own answer: those modules skip it, and never take it for "no systemd-boot" and edit
// GRUB's file instead. Never throws. Pinned by tests/test_boot_files.
#pragma once

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <system_error>
#include <vector>

namespace desk_install::boot_files {

enum class Loader { SystemdBoot, Grub, None, Unreadable };
struct Cmdline {
    Loader loader = Loader::None;
    std::filesystem::path file;   // the entry, or /etc/default/grub
    std::string why;              // what could not be read (Unreadable), or why there is no entry (None)
};

// A failed look that is not "it is not there".
inline bool unreadable(const std::error_code& ec) {
    return ec && ec != std::errc::no_such_file_or_directory && ec != std::errc::not_a_directory;
}

// loader.conf's `default` (".conf" added; a glob or @saved is not followed), else arch.conf, else the first entry by
// name that is not a recovery copy. Empty with `why` set when the folder cannot be read; empty alone when it has none.
inline std::filesystem::path default_entry(const std::filesystem::path& boot, std::string& why) {
    namespace fs = std::filesystem;
    const auto entries = boot / "loader/entries";
    std::error_code ec;
    std::ifstream conf(boot / "loader/loader.conf");
    std::string line;
    while (std::getline(conf, line)) {
        std::istringstream words(line);
        std::string key, value;
        words >> key >> value;
        if (key != "default" || value.empty() || value.find_first_of("*?[@") != std::string::npos) continue;
        if (value.size() < 5 || value.compare(value.size() - 5, 5, ".conf") != 0) value += ".conf";
        if (fs::is_regular_file(entries / value, ec)) return entries / value;
        if (unreadable(ec)) { why = ec.message(); return {}; }
    }
    if (fs::is_regular_file(entries / "arch.conf", ec)) return entries / "arch.conf";
    if (unreadable(ec)) { why = ec.message(); return {}; }
    std::vector<fs::path> found;
    for (fs::directory_iterator it(entries, ec), end; !ec && it != end; it.increment(ec)) {
        const auto name = it->path().filename().string();
        if (it->path().extension() == ".conf" && name.find("-recovery") == std::string::npos) found.push_back(it->path());
    }
    if (unreadable(ec)) { why = ec.message(); return {}; }
    std::sort(found.begin(), found.end());
    return found.empty() ? fs::path() : found.front();
}

inline Cmdline cmdline(const std::filesystem::path& boot = "/boot", const std::filesystem::path& grub = "/etc/default/grub") {
    namespace fs = std::filesystem;
    std::error_code ec;
    const bool entries = fs::is_directory(boot / "loader/entries", ec);
    if (unreadable(ec)) return {Loader::Unreadable, {}, (boot / "loader/entries").string() + ": " + ec.message()};
    if (entries) {
        std::string why;
        const auto entry = default_entry(boot, why);
        if (!why.empty()) return {Loader::Unreadable, {}, (boot / "loader/entries").string() + ": " + why};
        if (!entry.empty()) return {Loader::SystemdBoot, entry, {}};
        // systemd-boot with no entry to edit: still not a GRUB machine.
        return {Loader::None, {}, "no loader entry in " + (boot / "loader/entries").string()};
    }
    if (fs::is_regular_file(grub, ec)) return {Loader::Grub, grub, {}};
    if (unreadable(ec)) return {Loader::Unreadable, {}, grub.string() + ": " + ec.message()};
    return {};
}

}  // namespace desk_install::boot_files
