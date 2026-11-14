// modules/recovery_entry.cpp — guaranteed recovery console for systemd-boot.
//
// Hardened installs set `editor no` in loader.conf (stops a keyboard
// attacker appending init=/bin/bash). The side effect: you can't append
// `systemd.unit=multi-user.target` at boot either, so a broken login PAM
// (e.g. a botched pam_fprintd splice) leaves USB-rescue as the only way
// in. This module clones the default loader entry into a recovery entry
// that boots straight to multi-user.target — console login, no greetd —
// selectable from the boot menu with no editor. Still secure: it boots
// to a normal login, not a root shell.
//
// This is the escape hatch that makes auto-wiring fingerprint into
// login/sudo safe (memory: project_pam_fprintd_lockout). Reboot →
// pick "(recovery console)" → fix /etc/pam.d or `faillock --reset`.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "boot_files.hpp"

#include <filesystem>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;

namespace desk_install {

namespace {

constexpr const char* RECOVERY_ARG = "systemd.unit=multi-user.target";

std::string read_text(const fs::path& p) {
    std::ifstream f(p);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Build the recovery variant: rewrite the title, append the recovery arg
// to the options line (once).
std::string make_recovery(const std::string& src) {
    std::istringstream is(src);
    std::ostringstream out;
    std::string line;
    while (std::getline(is, line)) {
        if (line.rfind("title", 0) == 0) {
            out << "title Arch Linux (recovery console)\n";
        } else if (line.rfind("options", 0) == 0) {
            if (line.find(RECOVERY_ARG) == std::string::npos) {
                out << line << " " << RECOVERY_ARG << "\n";
            } else {
                out << line << "\n";
            }
        } else {
            out << line << "\n";
        }
    }
    return out.str();
}

}  // namespace

void run_recovery_entry(Context& ctx) {
    ui::section("Recovery boot entry (console fallback)");

    // The entry loader.conf names, found the way every boot module finds it; a /boot this user cannot read is skipped.
    const auto boot = boot_files::cmdline();
    if (boot.loader == boot_files::Loader::Unreadable) {
        ui::warn("cannot read the boot entries as your user (" + boot.why + ") — recovery entry not written");
        return;
    }
    if (boot.loader != boot_files::Loader::SystemdBoot) {
        if (boot.why.empty()) ui::skipped("no systemd-boot entries dir — skipping (GRUB/rEFInd have their own recovery menus)");
        else ui::warn("could not resolve a default loader entry to clone (" + boot.why + ") — skipping");
        return;
    }
    const fs::path src = boot.file, entries_dir = src.parent_path();

    std::string base = src.stem().string();
    fs::path dst = entries_dir / (base + "-recovery.conf");
    std::string body = make_recovery(read_text(src));

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write " + dst.string() + " (boots to multi-user.target)");
        return;
    }
    if (idem::up_to_date(dst, body, ctx.force_reapply)) {
        ui::skipped("recovery entry already current");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    if (!sh::write_root_atomic(dst, body, "0644")) {
        ui::warn("could not write " + dst.string());
        return;
    }
    ui::ok(dst.filename().string() + " — select it at boot for a console login (no greetd)");
    ui::substep("recovery use: boot it → log in → fix /etc/pam.d or `faillock --reset`");

    // Confirm systemd-boot actually parsed + registered the entry, so a
    // typo (e.g. a glued kernel arg) is caught now instead of the next
    // time you're locked out and reaching for it. `bootctl list` reports
    // every discovered entry by id.
    std::string entries;
    sh::capture({"bootctl", "list"}, entries);
    if (entries.find(dst.filename().string()) != std::string::npos) {
        ui::ok("verified: appears in `bootctl list` — it'll show in the boot menu");
    } else {
        ui::warn("written but not shown by `bootctl list` — check `bootctl list` by hand");
    }
}

}  // namespace desk_install
