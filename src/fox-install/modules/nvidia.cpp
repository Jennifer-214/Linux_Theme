// modules/nvidia.cpp — full NVIDIA Optimus / dGPU setup.
//
// Mirrors install_nvidia() in mappings.sh. The hairy parts are:
//
//   1. PCI scan for NVIDIA dGPU + iGPU under /sys/bus/pci/devices/ —
//      Aquamarine needs BOTH on Optimus laptops (eDP is wired to the
//      iGPU; NVIDIA renders, iGPU scans out via DMA-BUF).
//
//   2. Resolve /dev/dri/by-path/pci-<addr>-card → /dev/dri/cardN. We
//      build AQ_DRM_DEVICES from cardN paths because by-path names
//      contain ':' which collides with the env-var list separator.
//
//   3. Write ~/.config/hypr/modules/nvidia.conf from the template at
//      shared/hyprland_modules/nvidia.conf, substituting AQ_DRM_DEVICES.
//      Append a `source =` line to hyprland.conf if not already there.
//
//   4. Install nvidia-open-dkms + linux-headers + libva-nvidia-driver.
//
//   5. Edit /etc/mkinitcpio.conf MODULES=(...) to early-load nvidia
//      modules. Refuses if /boot has under 80 MB free (nvidia-bearing
//      initramfs grows to ~135 MB and a half-written .img bricks boot).
//
//   6. Append nvidia_drm.modeset=1 to systemd-boot entry kernel cmdline.

#include "nvidia_modules.hpp"
#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/statvfs.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

std::string read_first_line(const fs::path& p) {
    std::ifstream f(p);
    std::string s;
    std::getline(f, s);
    return s;
}

bool file_contains(const fs::path& p, const std::string& needle) {
    std::ifstream f(p);
    std::string line;
    while (std::getline(f, line)) {
        if (line.find(needle) != std::string::npos) return true;
    }
    return false;
}

// Walks /sys/bus/pci/devices, filtering to display class (0x03xxxx),
// returning the first device whose vendor matches any of `vendor_hex`.
// Returns empty string if no match.
std::string find_pci_addr_by_vendor(std::initializer_list<const char*> vendor_hex) {
    fs::path root = "/sys/bus/pci/devices";
    if (!fs::is_directory(root)) return {};
    for (const auto& dev : fs::directory_iterator(root)) {
        std::string vendor = read_first_line(dev.path() / "vendor");
        std::string cls    = read_first_line(dev.path() / "class");
        if (cls.rfind("0x03", 0) != 0) continue;        // display only
        for (auto* want : vendor_hex) {
            if (vendor == want) return dev.path().filename().string();
        }
    }
    return {};
}

std::string resolve_drm_card(const std::string& pci_addr) {
    fs::path by_path = fs::path("/dev/dri/by-path") /
                       ("pci-" + pci_addr + "-card");
    std::error_code ec;
    fs::path real = fs::read_symlink(by_path, ec);
    if (ec || real.empty()) return {};
    // by_path is a symlink that may be relative ("../card1") — resolve
    // against its parent directory to get an absolute path.
    if (real.is_relative()) real = by_path.parent_path() / real;
    real = fs::weakly_canonical(real, ec);
    if (ec || !fs::exists(real)) return {};
    return real.string();
}

long boot_free_mb() {
    struct statvfs vfs{};
    if (::statvfs("/boot", &vfs) != 0) return -1;
    return static_cast<long>((vfs.f_bavail * vfs.f_bsize) / (1024 * 1024));
}

// Read template, sub `AQ_DRM_DEVICES, .*` → `AQ_DRM_DEVICES, <value>`,
// write atomically to dest. Mirrors the sed in install_nvidia().
bool write_hypr_nvidia_conf(const fs::path& template_path,
                            const fs::path& dest,
                            const std::string& aq_value,
                            bool aq_complete) {
    std::ifstream in(template_path);
    if (!in) return false;
    std::ostringstream ss;
    std::string line;
    // rewrite_aq_line activates AQ_DRM_DEVICES only when aq_complete; on a
    // partial resolve it leaves the line commented (auto-detect) — see header.
    while (std::getline(in, line)) {
        ss << rewrite_aq_line(line, aq_value, aq_complete) << "\n";
    }
    fs::create_directories(dest.parent_path());
    fs::path tmp = dest;
    tmp += ".foxin.tmp";
    {
        std::ofstream out(tmp);
        out << ss.str();
    }
    std::error_code ec;
    fs::rename(tmp, dest, ec);
    return !ec;
}

std::string read_file_text(const fs::path& p) {
    std::ifstream f(p);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Atomically replace a root-owned file: stage the new content in a sibling
// `.foxml-new` on the SAME filesystem (so the final step is a rename, not a
// cross-fs copy), then `sudo mv` it over the target. A crash mid-write leaves
// the original intact — never a half-written boot-critical file.
bool sudo_write_atomic(const fs::path& dest, const std::string& content) {
    fs::path utmp = fs::temp_directory_path() /
                    ("foxml-mkinitcpio." + std::to_string(::getpid()));
    {
        std::ofstream o(utmp);
        o << content;
        if (!o) return false;
    }
    fs::path stage = dest;
    stage += ".foxml-new";
    bool ok = sh::run({"sudo", "cp", utmp.string(), stage.string()}) == 0;
    if (ok)
        // Match the original file's mode exactly (umask-independent) so we
        // never regress mkinitcpio.conf's 0644 to a tighter umask-derived perm.
        sh::run({"sudo", "chmod", "--reference=" + dest.string(),
                 stage.string()});
    if (ok)
        ok = sh::run({"sudo", "mv", stage.string(), dest.string()}) == 0;
    std::error_code ec;
    fs::remove(utmp, ec);
    if (!ok) sh::run({"sudo", "rm", "-f", stage.string()});
    return ok;
}

}  // namespace

void run_nvidia(Context& ctx) {
    ui::section("NVIDIA driver + Hyprland setup");

    if (!ctx.has_nvidia) {
        ui::warn("no NVIDIA GPU detected — skipping (re-run with --nvidia to force)");
        return;
    }

    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    // 1. Driver packages.
    if (sh::run({"sh", "-c",
                 "pacman -Qi nvidia-open-dkms linux-headers libva-nvidia-driver "
                 ">/dev/null 2>&1"}) == 0
        && !ctx.force_reapply) {
        ui::skipped("NVIDIA driver packages already installed");
    } else if (sh::pacman({"nvidia-open-dkms", "linux-headers",
                           "libva-nvidia-driver"}) != 0) {
        // Driver install failed → the nvidia modules won't exist. Skip the
        // rest of the module (incl. the mkinitcpio edit) so we never bake a
        // MODULES line referencing absent .ko files. Not fatal to the whole
        // install — same warn-and-continue posture as every other package
        // step; re-run --nvidia once the package issue is resolved.
        ui::warn("NVIDIA driver install failed — skipping setup (re-run --nvidia after resolving)");
        return;
    }

    // 2. PCI / DRM detection.
    std::string nvidia_addr = find_pci_addr_by_vendor({"0x10de"});
    std::string igpu_addr   = find_pci_addr_by_vendor({"0x8086", "0x1002"});
    if (nvidia_addr.empty()) {
        ui::warn("NVIDIA PCI device not present at /sys level — skipping Hyprland module write");
        return;
    }
    std::string nvidia_drm = resolve_drm_card(nvidia_addr);
    if (nvidia_drm.empty()) {
        ui::warn("could not resolve /dev/dri/by-path/pci-" + nvidia_addr +
                 "-card — is the nvidia driver loaded? (reboot may be required)");
        return;
    }
    std::string aq_drm = nvidia_drm;
    bool aq_complete = true;   // single-GPU is complete by definition
    if (!igpu_addr.empty()) {
        std::string igpu_drm = resolve_drm_card(igpu_addr);
        if (!igpu_drm.empty()) {
            aq_drm += ":" + igpu_drm;
            ui::ok("NVIDIA at " + nvidia_addr + " (" + nvidia_drm +
                   "), iGPU at " + igpu_addr + " (" + igpu_drm + ")");
        } else {
            // Optimus, but the iGPU's DRM node isn't resolvable yet (driver not
            // loaded / early boot). A single-card AQ_DRM_DEVICES would black the
            // iGPU-wired eDP on next start → leave it INERT (auto-detect) rather
            // than bake a wrong value. The user can re-run --nvidia once both
            // cards present DRM nodes.
            aq_complete = false;
            ui::warn("iGPU DRM node not ready — leaving AQ_DRM_DEVICES unset "
                     "(auto-detect); re-run --nvidia after a reboot to pin both cards");
        }
    } else {
        ui::ok("NVIDIA at " + nvidia_addr + " (single-GPU)");
    }

    // 3. Hyprland env-var module.
    fs::path tpl = ctx.script_dir / "shared/hyprland_modules/nvidia.conf";
    fs::path out = ctx.config_home / "hypr/modules/nvidia.conf";
    if (fs::exists(tpl)) {
        if (sh::dry_run()) {
            ui::substep("[dry-run] would write " + out.string() +
                       (aq_complete ? " with AQ_DRM_DEVICES=" + aq_drm
                                    : " with AQ_DRM_DEVICES left unset (auto-detect)"));
        } else if (write_hypr_nvidia_conf(tpl, out, aq_drm, aq_complete)) {
            ui::ok(aq_complete
                   ? "hypr/modules/nvidia.conf → AQ_DRM_DEVICES=" + aq_drm
                   : "hypr/modules/nvidia.conf → AQ_DRM_DEVICES auto-detect (iGPU node not ready)");
        } else {
            ui::warn("could not write " + out.string());
        }
        fs::path hypr_main = ctx.config_home / "hypr/hyprland.conf";
        if (fs::exists(hypr_main) && !file_contains(hypr_main, "modules/nvidia.conf")) {
            if (!sh::dry_run()) {
                std::ofstream app(hypr_main, std::ios::app);
                app << "\n# Nvidia (added by fox-install --nvidia)\n"
                       "source = ~/.config/hypr/modules/nvidia.conf\n";
            }
            ui::ok("hyprland.conf now sources nvidia.conf");
        }
    } else {
        ui::warn("template missing: " + tpl.string() +
                 " — Hyprland module not written");
    }

    // 4. systemd-boot kernel cmdline (nvidia_drm.modeset=1). Done BEFORE
    // the initramfs edit so every early-out below (DKMS-not-built, rebuild
    // recovery) still leaves modeset in the cmdline. It's a harmless no-op
    // until the module loads, and means a later DKMS fix picks up KMS on
    // the next boot without needing another --nvidia run.
    fs::path boot_entry = "/boot/loader/entries/arch.conf";
    if (fs::exists(boot_entry) && !file_contains(boot_entry, "nvidia_drm.modeset=1")) {
        if (sh::dry_run()) {
            ui::substep("[dry-run] would append `nvidia_drm.modeset=1` to " + boot_entry.string());
        } else {
            sh::run({"sudo", "sed", "-i.foxml-bak",
                     "-E", "s/^(options .*)/\\1 nvidia_drm.modeset=1/",
                     boot_entry.string()});
            ui::ok("appended nvidia_drm.modeset=1 to " + boot_entry.string());
        }
    } else if (!fs::exists(boot_entry)) {
        ui::warn("not using systemd-boot (no " + boot_entry.string() + ") — add `nvidia_drm.modeset=1` to your bootloader kernel cmdline manually");
    }

    // 5. mkinitcpio MODULES=(nvidia …). Guard against tiny /boot.
    fs::path mkinit = "/etc/mkinitcpio.conf";
    if (fs::exists(mkinit) && !file_contains(mkinit, "nvidia_drm")) {
        long free = boot_free_mb();
        if (free >= 0 && free < 80) {
            ui::warn("/boot has only " + std::to_string(free) +
                     " MB free (need ~135 MB for nvidia initramfs) — skipping mkinitcpio edit");
            ui::substep("free space in /boot, then re-run `--nvidia`, or accept udev-load fallback");
        } else if (sh::dry_run()) {
            // Preview the merge result — read-only, no writes (brick-safety
            // gate 1: dry-run shows the exact MODULES it would set).
            std::vector<std::string> toks =
                parse_modules(merge_modules(read_file_text(mkinit)));
            std::string line;
            for (std::size_t i = 0; i < toks.size(); ++i)
                line += (i ? " " : "") + toks[i];
            ui::substep("[dry-run] would set MODULES=(" + line +
                        ") in /etc/mkinitcpio.conf and rebuild initramfs");
        } else if (sh::run({"sh", "-c", "modinfo nvidia >/dev/null 2>&1"}) != 0) {
            // DKMS build didn't produce a loadable nvidia module for this
            // kernel. Editing MODULES to early-load it would bake a broken
            // initramfs. Skip the edit — NOT fatal: the GPU still comes up
            // via the nvidia_drm.modeset=1 cmdline arg (added above) + udev
            // late-load.
            ui::warn("nvidia kernel module not built (DKMS may have failed) — "
                     "skipping mkinitcpio MODULES edit to avoid a broken initramfs");
            ui::substep("the GPU still initialises via nvidia_drm.modeset=1 + udev late-load");
            ui::substep("fix DKMS (`sudo dkms autoinstall`), then re-run `--nvidia`");
        } else {
            // Read → merge → write. Replaces the old destructive whole-line
            // `sed s/^MODULES=(...)/MODULES=(nvidia …)/`, which WIPED a user's
            // existing MODULES (encrypt/lvm2/vfio_pci/…) → an initramfs missing
            // its boot-critical modules → unbootable. (LANDMINES: "idempotent ≠
            // non-destructive".) merge_modules keeps every existing entry and
            // appends only the missing nvidia modules.
            std::string orig   = read_file_text(mkinit);
            std::string merged = merge_modules(orig);

            // Two self-checks GATE the write — a wiped MODULES still builds a
            // VALID (incomplete) initramfs, so the rebuild-revert below never
            // fires on a clobber; the wipe must be PREVENTED, not recovered.
            //   (a) every pre-existing entry survives the merge (the brick);
            //   (b) all four nvidia modules are now present (so a parse miss or
            //       an unrecognised MODULES syntax can't silently no-op);
            //   (c) the conf was actually read — an empty `orig` (0-byte /
            //       unreadable, despite the outer exists-check) would otherwise
            //       merge to a MODULES-only file with no HOOKS → unbootable,
            //       and pass (a)+(b) vacuously (before is empty).
            std::vector<std::string> before = parse_modules(orig);
            std::vector<std::string> after  = parse_modules(merged);
            auto present = [](const std::vector<std::string>& v,
                              const std::string& mod) {
                return std::find(v.begin(), v.end(), mod) != v.end();
            };
            bool kept_all = std::all_of(before.begin(), before.end(),
                [&](const std::string& mod){ return present(after, mod); });
            bool nvidia_ok = std::all_of(kNvidiaModules.begin(), kNvidiaModules.end(),
                [&](const std::string& mod){ return present(after, mod); });

            if (orig.empty() || !kept_all || !nvidia_ok) {
                ui::warn("mkinitcpio MODULES merge self-check failed — leaving "
                         "/etc/mkinitcpio.conf untouched (refusing an unsafe edit)");
                ui::substep("the GPU still initialises via nvidia_drm.modeset=1 + udev late-load");
            } else {
                // Pristine pre-nvidia backup, created once (manual recovery +
                // the rebuild-revert source). A later --nvidia run hits the
                // outer `nvidia_drm` guard and never reaches here, so this
                // backup stays the genuine pre-nvidia conf across re-runs.
                sh::run({"sh", "-c",
                         "[ -e /etc/mkinitcpio.conf.foxml-bak ] || "
                         "sudo cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.foxml-bak"});

                if (!sudo_write_atomic(mkinit, merged)) {
                    ui::warn("could not write /etc/mkinitcpio.conf — skipping nvidia early-KMS");
                } else {
                    ui::ok("mkinitcpio MODULES merged (backup: /etc/mkinitcpio.conf.foxml-bak)");
                    // If the rebuild fails the freshly-written initramfs may be
                    // incomplete. Restore the pristine conf and regenerate a
                    // known-good initramfs before surfacing the failure, so a
                    // failed run can't strand the user at an unbootable image.
                    if (sh::run({"sudo", "mkinitcpio", "-P"}) != 0) {
                        ui::warn("mkinitcpio -P failed — reverting MODULES edit and rebuilding from backup");
                        sh::run({"sudo", "cp", "/etc/mkinitcpio.conf.foxml-bak",
                                 "/etc/mkinitcpio.conf"});
                        if (sh::run({"sudo", "mkinitcpio", "-P"}) != 0) {
                            // Couldn't rebuild even the pre-nvidia initramfs —
                            // the boot image may be incomplete. THIS is unsafe
                            // to leave, so halt the whole install loudly
                            // (dispatcher records + tails the log; --resume
                            // retries).
                            throw std::runtime_error(
                                "mkinitcpio -P failed AND the restore rebuild failed — "
                                "boot image may be incomplete; fix before rebooting");
                        }
                        // Recovered: initramfs is back to its working pre-nvidia
                        // state (modeset cmdline already added above), so the
                        // system is safe. Skip nvidia early-KMS; let the install
                        // finish.
                        ui::warn("nvidia early-KMS skipped; initramfs restored to pre-nvidia state");
                        ui::substep("fix DKMS (`sudo dkms autoinstall`), then re-run --nvidia");
                        return;
                    }
                }
            }
        }
    } else if (file_contains(mkinit, "nvidia_drm")) {
        ui::skipped("mkinitcpio already has nvidia modules");
    }

    ui::ok("NVIDIA setup complete — reboot to activate");
}

}  // namespace fox_install
