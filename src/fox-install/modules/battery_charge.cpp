// modules/battery_charge.cpp — cap battery charge for cell longevity.
//
// Li-ion cells degrade fastest when held at 100%. A start/stop charge
// threshold (begin charging at 75%, stop at 80%) keeps an always-docked
// laptop off the swollen-pancake path while still leaving a usable
// reserve if it's ever unplugged. We deliberately do NOT pull TLP: TLP
// also drives the CPU governor / turbo / scaling and would stomp on
// hand-tuned clock settings. This is a targeted oneshot that touches
// only the charge-threshold sysfs knobs and nothing else.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* UNIT_NAME = "battery-charge-threshold.service";
constexpr const char* UNIT_PATH = "/etc/systemd/system/battery-charge-threshold.service";

// start charging at 75%, stop at 80%. The start threshold sits a few
// points below stop so the cell isn't micro-cycling around the cap.
constexpr const char* UNIT_BODY =
    "# foxml-managed — cap battery charge (start 75 / stop 80) for cell longevity.\n"
    "[Unit]\n"
    "Description=Set battery charge thresholds (foxml: 75/80)\n"
    "After=multi-user.target\n"
    "\n"
    "[Service]\n"
    "Type=oneshot\n"
    "RemainAfterExit=yes\n"
    // Loop over every battery exposing the knob (BAT0/BAT1/...). The
    // start threshold is optional on some firmware, so guard it; the
    // stop threshold is the one that actually protects the cell.
    "ExecStart=/usr/bin/bash -c 'for b in /sys/class/power_supply/BAT*; do "
    "e=\"$b/charge_control_end_threshold\"; s=\"$b/charge_control_start_threshold\"; "
    "[ -w \"$e\" ] || continue; [ -w \"$s\" ] && echo 75 > \"$s\"; echo 80 > \"$e\"; done'\n"
    "\n"
    "[Install]\n"
    "WantedBy=multi-user.target\n";

// True if any battery on this host exposes a writable end-threshold.
// This is the real gate — more precise than DMI chassis detection,
// since plenty of laptops have batteries whose firmware doesn't surface
// the knob at all.
bool charge_threshold_supported() {
    std::error_code ec;
    for (auto& entry : fs::directory_iterator("/sys/class/power_supply", ec)) {
        if (ec) break;
        const std::string name = entry.path().filename().string();
        if (name.rfind("BAT", 0) != 0) continue;
        if (fs::exists(entry.path() / "charge_control_end_threshold", ec)) return true;
    }
    return false;
}

}  // namespace

void run_battery(Context& ctx) {
    ui::section("Battery charge cap");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write " + std::string(UNIT_PATH) +
                    " (start 75 / stop 80) + enable --now");
        return;
    }

    if (!charge_threshold_supported()) {
        ui::skipped("no battery exposes a charge threshold — nothing to cap");
        return;
    }

    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    if (sh::write_root_atomic(UNIT_PATH, UNIT_BODY)) {
        ui::ok("wrote " + std::string(UNIT_PATH) + " (charge 75% → stop 80%)");
    } else {
        ui::warn("could not write " + std::string(UNIT_PATH));
        return;
    }

    sh::systemctl_daemon_reload(/*user=*/false);

    // enable for persistence across reboots, start now so the cap takes
    // effect immediately. The current 100% drifts down naturally; the
    // unit just stops topping past 80 from here on.
    if (sh::systemctl_enable(UNIT_NAME, /*user=*/false) == 0
        && sh::systemctl_start(UNIT_NAME, /*user=*/false) == 0) {
        ui::ok("charge cap active now and on every boot");
    } else {
        ui::warn("unit written but enable/start failed — `systemctl enable --now "
                 + std::string(UNIT_NAME) + "` by hand");
    }

    (void)ctx;
}

}  // namespace fox_install
