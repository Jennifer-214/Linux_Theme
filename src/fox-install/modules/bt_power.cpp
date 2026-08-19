// modules/bt_power.cpp — keep the Bluetooth controller awake + quick to connect.
//
// Intel AX210 (and many USB combo cards) get USB-autosuspended by the kernel
// after ~2s idle, which makes pairing/reconnect flaky — the usual "Bluetooth
// is really hard to connect". Disable btusb autosuspend + enable
// FastConnectable. Mirrors the no_coredumps drop-in pattern.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* BTUSB_BODY =
    "# foxml-managed — keep the BT controller awake. Intel AX210 et al. drop\n"
    "# connections when USB-autosuspended; that is the usual 'hard to connect'.\n"
    "options btusb enable_autosuspend=0\n";

}  // namespace

void run_bt_power(Context& ctx) {
    ui::section("Bluetooth power tuning");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write /etc/modprobe.d/btusb.conf + set "
                    "FastConnectable=true in /etc/bluetooth/main.conf");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    fs::path btusb = "/etc/modprobe.d/btusb.conf";
    if (idem::up_to_date(btusb, BTUSB_BODY, ctx.force_reapply)) {
        ui::skipped("btusb autosuspend already disabled");
    } else if (sh::write_root_atomic(btusb, BTUSB_BODY, "0644")) {
        ui::ok("btusb autosuspend off — reconnects stay reliable");
        // best-effort live reload; a reboot applies it regardless
        sh::run({"sh", "-c",
                 "sudo modprobe -r btusb 2>/dev/null; sudo modprobe btusb 2>/dev/null || true"});
    } else {
        ui::warn("could not write " + btusb.string());
    }

    // FastConnectable — snappier connect response. Only touch it if bluez is here.
    if (fs::exists("/etc/bluetooth/main.conf")) {
        sh::run({"sh", "-c",
                 "sudo sed -i 's/^#\\?FastConnectable = .*/FastConnectable = true/' "
                 "/etc/bluetooth/main.conf"});
        sh::run({"sh", "-c", "sudo systemctl restart bluetooth 2>/dev/null || true"});
        ui::ok("FastConnectable = true (bluetooth restarted)");
    }
}

}  // namespace fox_install
