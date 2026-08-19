// modules/wifi_power.cpp — keep the Wi-Fi card awake across suspend/resume.
//
// Intel AX210 (and the AX2xx family) can fail to exit the D3cold low-power
// state on resume: the card never wakes ("iwlwifi: Timeout exiting D3" /
// "Couldn't get the d3 notif -110" + a register dump) and Wi-Fi is dead until
// a reboot. Pin the driver to an always-active power scheme so the PCIe link
// never enters the D3cold state that fails to wake. Sibling of bt_power (same
// card, Bluetooth side). Harmless when no iwlwifi is present — a modprobe
// option only applies once the module loads. Minor cost: slightly higher idle
// Wi-Fi power draw. See linux-theme-workspace/note.md for the research trail.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* IWLWIFI_BODY =
    "# foxml-managed — Wi-Fi suspend/resume fix. Intel AX210 et al. can fail to\n"
    "# exit D3cold on resume (dead Wi-Fi until reboot); an always-active power\n"
    "# scheme keeps the PCIe link out of that state.\n"
    "# Reverts: sudo rm /etc/modprobe.d/iwlwifi-foxml.conf\n"
    "options iwlmvm power_scheme=1\n"
    "options iwlwifi power_save=0\n";

}  // namespace

void run_wifi_power(Context& ctx) {
    ui::section("Wi-Fi power tuning (AX210 resume fix)");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write /etc/modprobe.d/iwlwifi-foxml.conf");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    fs::path conf = "/etc/modprobe.d/iwlwifi-foxml.conf";
    if (idem::up_to_date(conf, IWLWIFI_BODY, ctx.force_reapply)) {
        ui::skipped("Wi-Fi resume fix already in place");
    } else if (sh::write_root_atomic(conf, IWLWIFI_BODY, "0644")) {
        // Deliberately NO live module reload (unlike bt_power): iwlwifi carries
        // the network this install may be running over, so a reload would drop
        // later network-dependent modules — and re-invite the lockdown
        // module-signing question. The option takes effect at the next boot,
        // which a fresh install does anyway.
        ui::ok("Wi-Fi resume fix installed (applies on next boot)");
    } else {
        ui::warn("could not write " + conf.string());
    }
}

}  // namespace fox_install
