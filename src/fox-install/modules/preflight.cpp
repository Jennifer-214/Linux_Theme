// modules/preflight.cpp — fail fast on hard problems.
//
// Mirrors install.sh's pre-flight checks: disk space at $HOME and /,
// outbound network reachable, no obviously-conflicting WM/DE running.
// Soft warnings only — never aborts; the user can override by re-running.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"
#include "../../fox-health/health.hpp"

#include <cstdlib>
#include <filesystem>
#include <string>
#include <sys/statvfs.h>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

struct DiskInfo {
    long total_mb;
    long free_mb;
};

DiskInfo get_disk_info(const char* path) {
    struct statvfs vfs{};
    if (::statvfs(path, &vfs) != 0) return {-1, -1};
    // POSIX: f_blocks / f_bfree / f_bavail are counted in units of
    // f_frsize (the *fundamental* block size). f_bsize is just a
    // preferred-IO hint and on filesystems with fragments or cluster
    // sizes (ext4 clusters, ZFS recordsize, …) it's a different
    // number — using it here gave wrong free-space readings on those
    // setups. R14.
    const unsigned long unit = vfs.f_frsize ? vfs.f_frsize : vfs.f_bsize;
    return {
        static_cast<long>((vfs.f_blocks * unit) / (1024 * 1024)),
        static_cast<long>((vfs.f_bavail * unit) / (1024 * 1024))
    };
}

bool can_reach_internet() {
    return sh::run({"curl", "-sf", "-m", "5", "-o", "/dev/null",
                    "https://archlinux.org/"}) == 0;
}

}  // namespace

void run_preflight(Context& ctx) {
    ui::section("Pre-flight checks");

    DiskInfo home = get_disk_info(ctx.home.c_str());
    DiskInfo root = get_disk_info("/");
    
    // /boot check (parity with install.sh)
    fs::path boot_path = "/boot";
    if (!fs::exists(boot_path)) boot_path = "/";
    DiskInfo boot = get_disk_info(boot_path.c_str());

    if (home.free_mb >= 0) ui::summary_row("$HOME free", std::to_string(home.free_mb) + " MB");
    if (root.free_mb >= 0) ui::summary_row("/ free",     std::to_string(root.free_mb) + " MB");
    if (boot.free_mb >= 0 && boot_path == "/boot") {
        ui::summary_row("/boot capacity", std::to_string(boot.total_mb) + " MB (" + 
                                         std::to_string(boot.free_mb) + " MB free)");
    }

    if (home.free_mb >= 0 && home.free_mb < 2048) {
        ui::warn("$HOME has <2 GB free — installs that pull AI models may fail");
    }
    if (root.free_mb >= 0 && root.free_mb < 512) {
        ui::warn("/ has <512 MB free — pacman installs may fail");
    }
    if (boot.free_mb >= 0 && (boot.total_mb < 768 || boot.free_mb < 256)) {
        ui::warn(boot_path.string() + " is below recommended size (768MB total, 256MB free)");
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] skipping connectivity probe");
    } else if (can_reach_internet()) {
        ui::ok("network reachable");
    } else {
        ui::warn("can't reach archlinux.org — offline? pacman + AUR steps will fail");
    }

    // Conflicting session-leader hint. Not fatal — many users dual-boot
    // Hyprland and another WM intentionally.
    const char* desktop = std::getenv("XDG_CURRENT_DESKTOP");
    if (desktop && std::string(desktop).find("Hyprland") == std::string::npos
                && *desktop != '\0') {
        ui::warn(std::string("current session is `") + desktop +
                 "` — Hyprland-specific steps will succeed but apply on next login");
    }

    // Installed WM/DE coexistence check via pacman -Qi. Catches the
    // installed-but-not-active case that the XDG_CURRENT_DESKTOP check
    // above misses (e.g. plasma-desktop installed alongside Hyprland —
    // configs coexist fine but Hyprland binds only apply inside a
    // Hyprland session). Mirrors install.sh.legacy's preflight.
    static const char* WM_PKGS[][2] = {
        {"plasma-desktop", "KDE Plasma"},
        {"gnome-shell",    "GNOME"},
        {"sway",           "sway"},
        {"i3-wm",          "i3"},
        {"xfce4-session",  "XFCE"},
        {nullptr, nullptr},
    };
    std::string conflicts;
    for (auto* pair : WM_PKGS) {
        if (!pair[0]) break;
        if (sh::run({"sh", "-c",
                     std::string("pacman -Qi ") + pair[0] + " &>/dev/null"}) == 0) {
            if (!conflicts.empty()) conflicts += ", ";
            conflicts += pair[1];
        }
    }
    if (!conflicts.empty()) {
        ui::warn("another desktop / WM installed: " + conflicts);
        ui::substep("configs coexist; Hyprland binds only apply inside a Hyprland session");
    }

    // Delegate the kernel/boot/PAM-stack class of checks to the
    // foxml-health library. Phase-2 integration of plans/health-checks.md:
    // preflight runs the full A + B subset (boot + auth) and bails on
    // any Critical fail. The library handles container detection
    // internally; checks that aren't safe inside containers (kernel
    // module tree) skip cleanly.
    bool in_container =
        fs::exists("/.dockerenv") ||
        fs::exists("/run/.containerenv") ||
        fs::exists("/run/systemd/container") ||
        std::getenv("container") != nullptr;

    fox_health::CheckOptions opts;
    opts.only = { "A", "B" };
    // Slow probes (pacman -Qkk) skip in dry-run since they read 1000s
    // of files for a check that doesn't influence dry-run output.
    opts.include_slow = !sh::dry_run();
    auto results = fox_health::run_all(opts);

    // Only category-A (boot path) critical fails abort the install —
    // those mean later modules can corrupt state further. Category-B
    // (auth stack) critical fails are real risks but don't compound
    // during a fox-install run; they surface as loud warnings so the
    // user sees the recommended `fox sec health --verbose` hint.
    int blocking_fails = 0;
    for (const auto& r : results) {
        if (r.status != fox_health::Status::Fail
            && r.status != fox_health::Status::Warn) continue;
        const char* glyph = (r.status == fox_health::Status::Fail) ? "✗" : "!";
        bool is_blocking = (r.severity == fox_health::Severity::Critical
                            && r.id.size() >= 1 && r.id[0] == 'A');
        if (is_blocking) {
            ui::err(std::string(glyph) + " [" + r.id + "] " + r.title);
            ++blocking_fails;
        } else if (r.severity == fox_health::Severity::Critical
                || r.severity == fox_health::Severity::High) {
            ui::warn(std::string(glyph) + " [" + r.id + "] " + r.title);
        } else {
            continue;
        }
        if (!r.detail.empty())   ui::substep(r.detail);
        if (!r.fix_hint.empty()) ui::substep("fix: " + r.fix_hint);
    }
    if (blocking_fails > 0 && !in_container) {
        // Containers run under the host kernel; the health library's
        // A1 (kernel module tree) check is the most common Critical
        // fail inside a container, and the runtime checks are designed
        // to skip there. Don't bail on Critical inside a container —
        // it's almost certainly a context mismatch, not a broken host.
        ctx.preflight_failed = true;
    }
}

}  // namespace fox_install
