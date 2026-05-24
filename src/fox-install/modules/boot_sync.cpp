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
    "# Noop when /boot and /boot/efi are the same filesystem.\n"
    "set -eu\n"
    "BOOT=/boot\n"
    "ESP=/boot/efi\n"
    "[ -d \"$BOOT\" ] || exit 0\n"
    "[ -d \"$ESP\" ]  || exit 0\n"
    "# If /boot/efi is in fstab but not currently mounted, the ESP\n"
    "# silently won't get the new kernels — exactly the failure mode\n"
    "# this hook exists to prevent. Warn loudly to pacman's output.\n"
    "if ! findmnt -n \"$ESP\" >/dev/null 2>&1; then\n"
    "    if grep -qE \"^[^#].*[[:space:]]${ESP//\\//\\\\/}[[:space:]]\" /etc/fstab 2>/dev/null; then\n"
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

    if (!fs::exists("/boot/loader/entries")) {
        ui::skipped("no systemd-boot loader entries — skipping (GRUB / other handles this differently)");
        return;
    }
    if (!fs::exists("/boot/efi")) {
        ui::skipped("/boot/efi not present — assuming /boot is the ESP");
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
