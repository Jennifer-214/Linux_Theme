// modules/noexec_tmp.cpp — noexec / nosuid / nodev on /tmp + /dev/shm.
//
// Kills the "drop second-stage payload in /tmp, exec it" malware class
// at the cost of breaking the rare build script that legit-execs from
// /tmp. Opt-in via --noexec-tmp.
//
// Mirrors mappings.sh::install_noexec_tmp. Edits /etc/fstab (backup at
// fstab.foxml-bak) and remounts /tmp + /dev/shm live where the kernel
// allows (refuses if /tmp is held open — falls back to "applies next reboot").

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <stdexcept>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool has_tmp_tmpfs(const std::string& fstab) {
    std::istringstream is(fstab);
    std::string line;
    std::regex pat(R"(^\S+\s+/tmp\s+tmpfs)");
    while (std::getline(is, line)) {
        if (std::regex_search(line, pat)) return true;
    }
    return false;
}

bool tmp_fstab_locked_down(const std::string& fstab) {
    std::istringstream is(fstab);
    std::string line;
    std::regex pat(R"(^\S+\s+/tmp\s+tmpfs)");
    while (std::getline(is, line)) {
        if (!std::regex_search(line, pat)) continue;
        return line.find("noexec") != std::string::npos
            && line.find("nosuid") != std::string::npos
            && line.find("nodev")  != std::string::npos;
    }
    return false;
}

std::string read_file(const fs::path& p) {
    std::ifstream f(p);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

}  // namespace

void run_noexec_tmp(Context& ctx) {
    ui::section("/tmp + /dev/shm noexec,nosuid,nodev");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would back up /etc/fstab, append /tmp tmpfs mount "
                    "or amend its options, remount /tmp and /dev/shm live");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    fs::path fstab = "/etc/fstab";
    std::string body = read_file(fstab);

    // Snapshot fstab's parse-health BEFORE we touch it, so we only react
    // to a problem WE introduced (not a pre-existing unrelated warning).
    bool verify_ok_before =
        sh::run({"sh", "-c", "findmnt --verify >/dev/null 2>&1"}) == 0;

    bool tmp_locked = tmp_fstab_locked_down(body);
    bool tmp_live = sh::run({"sh", "-c",
                             "findmnt /tmp 2>/dev/null | grep -q noexec"}) == 0;
    bool shm_live = sh::run({"sh", "-c",
                             "findmnt /dev/shm 2>/dev/null | grep -q noexec"}) == 0;
    if (tmp_locked && tmp_live && shm_live && !ctx.force_reapply) {
        ui::skipped("/tmp + /dev/shm already noexec,nosuid,nodev (fstab + live)");
        return;
    }

    // Only back up /etc/fstab when we're actually about to edit it —
    // a pure /dev/shm remount needs no fstab change. Backup is
    // create-if-missing: a foxml-modified fstab must never overwrite the
    // true pre-foxml original on repeat --full runs.
    if (!tmp_locked) {
        sh::run({"sh", "-c",
                 "[ -e /etc/fstab.foxml-bak ] || "
                 "sudo cp /etc/fstab /etc/fstab.foxml-bak"});
        if (!has_tmp_tmpfs(body)) {
            sh::run({"sh", "-c",
                     "echo 'tmpfs   /tmp        tmpfs   "
                     "defaults,noexec,nosuid,nodev,size=4G  0 0' | "
                     "sudo tee -a /etc/fstab >/dev/null"});
            ui::ok("/tmp added to /etc/fstab as tmpfs with noexec,nosuid,nodev");
        } else {
            // Amend each missing flag onto the existing /tmp tmpfs line's
            // options field. Appending to the captured options column
            // (the 4th \S+) works whether or not the line uses `defaults`
            // — the prior `defaults`-only sed silently no-op'd on lines
            // that spelled out their options.
            sh::run({"sh", "-c",
                     "sudo sed -i -E '/^\\S+\\s+\\/tmp\\s+tmpfs/{"
                     "/\\bnoexec\\b/!s/(\\S+\\s+\\/tmp\\s+tmpfs\\s+\\S+)/\\1,noexec/;"
                     "/\\bnosuid\\b/!s/(\\S+\\s+\\/tmp\\s+tmpfs\\s+\\S+)/\\1,nosuid/;"
                     "/\\bnodev\\b/!s/(\\S+\\s+\\/tmp\\s+tmpfs\\s+\\S+)/\\1,nodev/"
                     "}' /etc/fstab"});
            ui::ok("/tmp tmpfs entry amended with noexec,nosuid,nodev");
        }

        // Validate the edited fstab before the next boot trusts it. A
        // malformed/duplicate line drops the system to an emergency
        // shell. If our edit newly broke parsing, revert from the backup
        // and fail the module rather than leave an unbootable fstab.
        if (verify_ok_before &&
            sh::run({"sh", "-c", "findmnt --verify >/dev/null 2>&1"}) != 0) {
            ui::warn("fstab edit failed `findmnt --verify` — reverting from /etc/fstab.foxml-bak");
            if (sh::run({"sudo", "cp", "/etc/fstab.foxml-bak", "/etc/fstab"}) != 0) {
                // Revert failed — fstab may be left in a state that drops the
                // next boot to an emergency shell. THIS is unsafe; halt loudly.
                throw std::runtime_error(
                    "noexec_tmp: fstab failed verification AND the revert failed — "
                    "inspect /etc/fstab before rebooting");
            }
            // Reverted to the known-good fstab → system is safe. Skip the
            // /tmp hardening (and the live remounts below) and continue.
            ui::warn("/tmp hardening not applied; fstab reverted to its pre-foxml state");
            return;
        }
    }

    if (sh::run({"sh", "-c",
                 "sudo mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null"}) == 0) {
        ui::ok("/dev/shm live-remounted noexec,nosuid,nodev");
    } else {
        ui::ok("/dev/shm flags will apply on next reboot");
    }

    if (sh::run({"sh", "-c",
                 "findmnt /tmp 2>/dev/null | grep -q noexec"}) == 0) {
        ui::skipped("/tmp already noexec live");
    } else if (sh::run({"sh", "-c",
                        "sudo mount -o remount,noexec,nosuid,nodev /tmp 2>/dev/null"}) == 0) {
        ui::ok("/tmp live-remounted noexec,nosuid,nodev");
    } else {
        ui::ok("/tmp fstab updated — reboot to apply live (kernel refused: /tmp busy)");
    }
    if (!tmp_locked) {
        ui::substep("backup at /etc/fstab.foxml-bak — revert with: sudo mv /etc/fstab.foxml-bak /etc/fstab");
    }
}

}  // namespace fox_install
