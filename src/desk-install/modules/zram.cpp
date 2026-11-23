// modules/zram.cpp — compressed swap in RAM through zram-generator. Leaves a zram setup of the machine's own alone.

#include "zram_conf.hpp"

#include "../core/context.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

namespace fs = std::filesystem;

namespace desk_install {

namespace {

bool zram_swap_active() {
    std::ifstream swaps("/proc/swaps");
    for (std::string line; std::getline(swaps, line);)
        if (line.rfind("/dev/zram", 0) == 0) return true;
    return false;
}

}  // namespace

void run_zram(Context& ctx) {
    ui::section("zram swap");
    const fs::path conf = zram::CONF_PATH;
    std::error_code ec;
    const bool exists = fs::exists(conf, ec);
    std::ostringstream text;
    if (exists) text << std::ifstream(conf).rdbuf();

    switch (zram::decide(exists, text.str(), zram_swap_active())) {
        case zram::Action::LeaveTheirs:
            ui::skipped("zram is set up here already (" + conf.string() + " or an active zram swap) — left as it is");
            return;
        case zram::Action::UpToDate:
            if (!ctx.force_reapply) { ui::skipped("zram swap already configured"); return; }
            break;
        case zram::Action::Write:
            break;
    }
    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }
    if (sh::pacman({"zram-generator"}) != 0) {
        ui::warn("could not install zram-generator — no zram swap");
        return;
    }
    if (!sh::write_root_atomic(conf, zram::CONF_BODY)) {
        ui::warn("could not write " + conf.string());
        return;
    }
    ui::ok(conf.string() + " (zram0: up to 8 GiB, zstd)");
    sh::run({"sudo", "systemctl", "daemon-reload"});
    if (sh::run({"sudo", "systemctl", "start", "systemd-zram-setup@zram0.service"}) == 0) ui::ok("zram swap on");
    else ui::warn("zram swap starts at the next boot");
}

}  // namespace desk_install
