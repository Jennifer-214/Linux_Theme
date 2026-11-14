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
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "fstab_tmp.hpp"
#include "pam_file.hpp"

#include <filesystem>
#include <fstream>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
#include <unistd.h>

namespace fs = std::filesystem;

namespace desk_install {

namespace {

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
    const std::string body = read_file(fstab);
    const auto kind = fstab_tmp::tmp_kind(body);
    const bool tmp_locked = fstab_tmp::locked_down(body);
    bool tmp_live = sh::run({"sh", "-c",
                             "findmnt /tmp 2>/dev/null | grep -q noexec"}) == 0;
    bool shm_live = sh::run({"sh", "-c",
                             "findmnt /dev/shm 2>/dev/null | grep -q noexec"}) == 0;
    if (tmp_locked && tmp_live && shm_live && !ctx.force_reapply) {
        ui::skipped("/tmp + /dev/shm already noexec,nosuid,nodev (fstab + live)");
        return;
    }

    // A /tmp of its own partition is left alone: a second /tmp line used to be appended beside it.
    const bool own_partition = kind == fstab_tmp::TmpKind::Partition && !tmp_locked;
    bool edited = false;
    if (own_partition) {
        ui::warn("/tmp is a partition of its own in /etc/fstab — left as it is; add noexec,nosuid,nodev to its options by hand");
    } else if (const auto next = fstab_tmp::with_tmp_locked(body)) {
        // The candidate is checked before it replaces fstab: an error it adds (one fstab did not already have) would
        // drop the next boot to an emergency shell, so fstab stays as it is. Then pam_file lays it: backup made once,
        // swapped in one step, compared, the previous fstab restored on any difference (the old revert copied back
        // the backup from the first install, losing every fstab change since).
        const auto errors = [](const std::string& file) {
            std::string out;
            sh::probe({"sh", "-c", "findmnt --verify --tab-file \"$1\" 2>&1", "sh", file}, out);
            return fstab_tmp::verify_errors(out);
        };
        char tmpl[] = "/tmp/desk-fstab-XXXXXX";
        const int fd = ::mkstemp(tmpl);
        if (fd < 0) { ui::err("could not write a candidate fstab to check — fstab left as it is"); return; }
        const bool written = ::write(fd, next->data(), next->size()) == static_cast<ssize_t>(next->size());
        ::close(fd);
        const auto before = errors(fstab.string());
        const auto after = written ? errors(tmpl) : std::set<std::string>{"could not write the candidate"};
        ::unlink(tmpl);
        for (const auto& e : after)
            if (!before.count(e)) { ui::err("the /tmp line would make fstab fail its check (" + e + ") — fstab left as it is"); return; }
        if (const auto failed = pam_file::install(fstab, *next); !failed.empty()) { ui::err(failed); return; }
        ui::ok(kind == fstab_tmp::TmpKind::None ? "/tmp added to /etc/fstab as tmpfs with noexec,nosuid,nodev"
                                                : "/tmp tmpfs entry amended with noexec,nosuid,nodev");
        edited = true;
    }

    if (sh::run({"sh", "-c",
                 "sudo mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null"}) == 0) {
        ui::ok("/dev/shm live-remounted noexec,nosuid,nodev");
    } else {
        ui::ok("/dev/shm flags will apply on next reboot");
    }

    if (own_partition) {
        // left as it is above; not remounted either
    } else if (sh::run({"sh", "-c",
                 "findmnt /tmp 2>/dev/null | grep -q noexec"}) == 0) {
        ui::skipped("/tmp already noexec live");
    } else if (sh::run({"sh", "-c",
                        "sudo mount -o remount,noexec,nosuid,nodev /tmp 2>/dev/null"}) == 0) {
        ui::ok("/tmp live-remounted noexec,nosuid,nodev");
    } else {
        ui::ok("/tmp fstab updated — reboot to apply live (kernel refused: /tmp busy)");
    }
    if (edited) {
        ui::substep("backup at /etc/fstab.foxml-bak (the fstab from before the installer first changed it)");
    }
}

}  // namespace desk_install
