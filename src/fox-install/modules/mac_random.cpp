// modules/mac_random.cpp — NetworkManager MAC randomization (opt-in).
//
// Per-SSID stable, varies across networks. Opt-in because dorm /
// enterprise / captive-portal networks gatekeep on persistent MAC
// addresses and randomisation breaks those setups. Mirrors
// mappings.sh::install_mac_random.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* MAC_RANDOM_BODY =
    "# foxml-managed — NetworkManager MAC randomization.\n"
    "# Reverts: sudo rm /etc/NetworkManager/conf.d/00-foxml-mac-random.conf\n"
    "[device]\n"
    "wifi.scan-rand-mac-address=yes\n"
    "\n"
    "[connection]\n"
    "wifi.cloned-mac-address=random\n"
    "ethernet.cloned-mac-address=random\n"
    "# Per-SSID stable identifier so each network gets a deterministic\n"
    "# (but unique) MAC. Prevents the network from churning ARP tables\n"
    "# every connection while still presenting a different MAC per SSID.\n"
    "connection.stable-id=${CONNECTION}/${BOOT}\n";

bool write_root_file(const fs::path& dst, const std::string& body) {
    return sh::write_root_atomic(dst, body);
}

}  // namespace

void run_mac_random(Context& ctx) {
    ui::section("NetworkManager MAC randomization");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write /etc/NetworkManager/conf.d/"
                    "00-foxml-mac-random.conf + reload NetworkManager");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    fs::path conf = "/etc/NetworkManager/conf.d/00-foxml-mac-random.conf";
    if (idem::up_to_date(conf, MAC_RANDOM_BODY, ctx.force_reapply)) {
        ui::skipped("MAC randomization config already up to date");
        return;
    }
    if (!write_root_file(conf, MAC_RANDOM_BODY)) {
        ui::err("could not write " + conf.string());
        return;
    }
    sh::run({"sh", "-c",
             "sudo systemctl reload NetworkManager 2>/dev/null || "
             "sudo systemctl restart NetworkManager 2>/dev/null || true"});
    ui::ok("MAC randomization enabled (per-SSID stable, varies across networks)");
}

}  // namespace fox_install
