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
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* RECOVERY_ARG = "systemd.unit=multi-user.target";

std::string read_text(const fs::path& p) {
    std::ifstream f(p);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Resolve the default loader entry. loader.conf `default <name>` may end
// in .conf or be a glob; fall back to arch.conf, then the first entry.
fs::path default_entry(const fs::path& entries_dir) {
    std::string conf = read_text("/boot/loader/loader.conf");
    std::istringstream is(conf);
    std::string line;
    while (std::getline(is, line)) {
        auto p = line.find("default");
        if (p == 0) {
            std::istringstream ls(line);
            std::string key, val;
            ls >> key >> val;
            if (!val.empty() && val.find('*') == std::string::npos) {
                if (val.size() < 5 || val.substr(val.size() - 5) != ".conf") val += ".conf";
                fs::path cand = entries_dir / val;
                if (fs::exists(cand)) return cand;
            }
        }
    }
    if (fs::exists(entries_dir / "arch.conf")) return entries_dir / "arch.conf";
    std::error_code ec;
    for (auto& e : fs::directory_iterator(entries_dir, ec)) {
        if (e.path().extension() == ".conf"
            && e.path().filename().string().find("-recovery") == std::string::npos) {
            return e.path();
        }
    }
    return {};
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

    fs::path entries_dir = "/boot/loader/entries";
    if (!fs::is_directory(entries_dir)) {
        ui::skipped("no systemd-boot entries dir — skipping (GRUB/rEFInd have their own recovery menus)");
        return;
    }

    fs::path src = default_entry(entries_dir);
    if (src.empty()) {
        ui::warn("could not resolve a default loader entry to clone — skipping");
        return;
    }

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

    if (sh::write_root_atomic(dst, body, "0644")) {
        ui::ok(dst.filename().string() + " — select it at boot for a console login (no greetd)");
        ui::substep("recovery use: boot it → log in → fix /etc/pam.d or `faillock --reset`");
    } else {
        ui::warn("could not write " + dst.string());
    }
}

}  // namespace fox_install
