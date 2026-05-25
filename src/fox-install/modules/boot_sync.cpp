// modules/boot_sync.cpp — keep ESP root kernels in sync with /boot.
//
// Why this exists: when /boot and the ESP are separate mounts (a common
// systemd-boot layout: small ESP at /boot/efi, larger /boot for kernels),
// pacman writes new kernels to /boot but the firmware loads them from the
// ESP root. Without a hook, the ESP slowly drifts behind until the next
// kernel-version bump fails to mount because /lib/modules/<running> no
// longer exists.
//
// Installs:
//   /usr/local/lib/foxml/esp-sync           — copy helper
//   /etc/pacman.d/hooks/95-foxml-esp-sync.hook — fires on kernel install
//
// Then runs the helper once to repair any current drift.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* ESP_SYNC_SCRIPT =
    "#!/bin/bash\n"
    "# foxml-managed — sync /boot kernels + initramfs to ESP root.\n"
    "# Auto-detects the ESP mountpoint from `bootctl --print-esp-path`\n"
    "# (works for systemd-boot's traditional /boot/efi layout AND the\n"
    "# modern XBOOTLDR layout where the ESP is /efi and /boot holds\n"
    "# kernels). Noop when /boot and the ESP are the same filesystem.\n"
    "set -eu\n"
    "BOOT=/boot\n"
    "[ -d \"$BOOT\" ] || exit 0\n"
    "# 1. Authoritative source on systemd-boot hosts.\n"
    "ESP=\"$(bootctl --print-esp-path 2>/dev/null || true)\"\n"
    "# 2. Fallback: well-known candidate paths.\n"
    "if [ -z \"$ESP\" ]; then\n"
    "    for cand in /efi /boot/efi; do\n"
    "        if findmnt -n \"$cand\" >/dev/null 2>&1; then ESP=\"$cand\"; break; fi\n"
    "    done\n"
    "fi\n"
    "# 3. If still empty, this host has no separate ESP. Nothing to do.\n"
    "[ -n \"$ESP\" ] && [ -d \"$ESP\" ] || exit 0\n"
    "# 4. If the candidate path exists but isn't a mountpoint, the ESP\n"
    "# silently won't get new kernels — the exact failure mode this hook\n"
    "# exists to prevent. Warn loudly when fstab promises a mount.\n"
    "if ! findmnt -n \"$ESP\" >/dev/null 2>&1; then\n"
    "    esp_re=$(printf '%s' \"$ESP\" | sed 's|/|\\\\/|g')\n"
    "    if grep -qE \"^[^#].*[[:space:]]${esp_re}[[:space:]]\" /etc/fstab 2>/dev/null; then\n"
    "        echo \"esp-sync: $ESP is in fstab but NOT currently mounted — kernels were NOT synced to the ESP. Mount it and re-run: sudo /usr/local/lib/foxml/esp-sync\" >&2\n"
    "    fi\n"
    "    exit 0\n"
    "fi\n"
    "boot_dev=$(stat -c %d \"$BOOT\")\n"
    "esp_dev=$(stat -c %d \"$ESP\")\n"
    "[ \"$boot_dev\" != \"$esp_dev\" ] || exit 0\n"
    "shopt -s nullglob\n"
    "for f in \"$BOOT\"/vmlinuz-* \"$BOOT\"/initramfs-*.img \"$BOOT\"/intel-ucode.img \"$BOOT\"/amd-ucode.img; do\n"
    "    [ -e \"$f\" ] || continue\n"
    "    base=$(basename \"$f\")\n"
    "    if ! cmp -s \"$f\" \"$ESP/$base\" 2>/dev/null; then\n"
    "        install -m 0755 \"$f\" \"$ESP/$base\"\n"
    "        echo \"esp-sync: $base\"\n"
    "    fi\n"
    "done\n";

constexpr const char* PACMAN_HOOK =
    "# foxml-managed — copy fresh kernels + microcode to the ESP root.\n"
    "# Triggers on the kernel package's vmlinuz install. mkinitcpio's\n"
    "# own 90-* hooks have already regenerated /boot/initramfs-*.img by\n"
    "# the time this 95- hook fires, so esp-sync picks them up too.\n"
    "[Trigger]\n"
    "Operation = Install\n"
    "Operation = Upgrade\n"
    "Type = Path\n"
    "Target = usr/lib/modules/*/vmlinuz\n"
    "Target = boot/intel-ucode.img\n"
    "Target = boot/amd-ucode.img\n"
    "\n"
    "[Action]\n"
    "Description = Syncing kernel + initramfs to ESP root\n"
    "When = PostTransaction\n"
    "Exec = /usr/local/lib/foxml/esp-sync\n"
    "Depends = bash\n";

bool write_root_file(const fs::path& dst, const std::string& body,
                     const std::string& mode) {
    return sh::write_root_atomic(dst, body, mode);
}

}  // namespace

void run_boot_sync(Context& ctx) {
    (void)ctx;
    ui::section("Boot path sync (/boot ⇄ ESP root)");

    // Module installs a pacman hook + helper script that the script
    // itself decides whether to act on (auto-detects ESP at run time).
    // Skip only on hosts where systemd-boot loader entries are clearly
    // absent — GRUB / rEFInd / UKI users have their own mechanisms
    // (the kernel-install or grub-mkconfig hooks shipped with those).
    bool has_systemd_boot_entries =
        fs::exists("/boot/loader/entries") || fs::exists("/efi/loader/entries");
    if (!has_systemd_boot_entries) {
        ui::skipped("no systemd-boot loader entries (/boot/loader or /efi/loader) — "
                    "skipping (GRUB / rEFInd / UKI handle kernel copies via their own hooks)");
        return;
    }

    fs::path script = "/usr/local/lib/foxml/esp-sync";
    fs::path hook   = "/etc/pacman.d/hooks/95-foxml-esp-sync.hook";

    if (sh::dry_run()) {
        ui::substep("[dry-run] would install " + script.string() + " + " +
                    hook.string() + " and run esp-sync once");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    if (write_root_file(script, ESP_SYNC_SCRIPT, "0755")) {
        ui::ok(script.string() + " (kernel→ESP copy helper)");
    } else {
        ui::warn("could not write " + script.string());
        return;
    }
    if (write_root_file(hook, PACMAN_HOOK, "0644")) {
        ui::ok(hook.string() + " (fires on kernel/initramfs install)");
    } else {
        ui::warn("could not write " + hook.string());
        return;
    }

    int rc = sh::run({"sudo", script.string()});
    if (rc == 0) {
        ui::ok("ran esp-sync — any drift repaired");
    } else {
        ui::warn("esp-sync exited " + std::to_string(rc) +
                 " — inspect /boot vs /boot/efi manually");
    }
}

}  // namespace fox_install
