// modules/models.cpp — queue the local model stack for background download.
//
// fox-llm-update owns the list — this machine's extras, your personal lists (the custom_models repo, any
// ~/code/*/foxml-models.txt, ~/.config/foxml/models.private), then the RAM tier of
// shared/llm/core-models.txt — and downloads it in its background queue: resumable across reboots,
// retried, Hugging Face GGUFs first, gone when done. Pulling here instead held a slow-Wi-Fi install for
// days. Tier is RAM-only: the agent models are ~3B-active MoE that run on the CPU, so VRAM no longer
// gates them. Also installs fox-llm-update.timer.

#include "../core/context.hpp"
#include "../core/hardware.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <string>
#include <sys/statvfs.h>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

const char* pick_tier(int ram_gb) {
    if (ram_gb >= 32) return "large";
    if (ram_gb >= 16) return "medium";
    return "small";
}

// Free space each tier needs before pulling (largest set + headroom).
long tier_min_free_gb(const std::string& tier) {
    if (tier == "large")  return 60;
    if (tier == "medium") return 30;
    return 15;
}

constexpr const char* UPDATE_SERVICE_BODY =
    "[Unit]\n"
    "Description=fox-llm-update — refresh local models, notify on tool updates\n"
    "After=network-online.target\n"
    "\n"
    "[Service]\n"
    "Type=oneshot\n"
    "ExecStart=%h/.local/bin/fox-llm-update --auto\n"
    "Nice=10\n"
    "IOSchedulingClass=idle\n";

constexpr const char* UPDATE_TIMER_BODY =
    "[Unit]\n"
    "Description=Run fox-llm-update daily (downloads wait for a fast network)\n"
    "\n"
    "[Timer]\n"
    "OnCalendar=daily\n"
    "RandomizedDelaySec=30min\n"
    "Persistent=true\n"
    "\n"
    "[Install]\n"
    "WantedBy=timers.target\n";

void install_update_timer(const Context& ctx) {
    fs::path dir = ctx.config_home / "systemd/user";
    if (!idem::write_atomic(dir / "fox-llm-update.service", UPDATE_SERVICE_BODY) ||
        !idem::write_atomic(dir / "fox-llm-update.timer", UPDATE_TIMER_BODY)) {
        ui::warn("could not write fox-llm-update units under " + dir.string());
        return;
    }
    sh::run({"systemctl", "--user", "daemon-reload"});
    if (sh::run({"systemctl", "--user", "enable", "--now", "fox-llm-update.timer"}) == 0) {
        ui::ok("fox-llm-update.timer enabled (daily model refresh + update notices)");
    } else {
        ui::warn("could not enable fox-llm-update.timer via systemctl --user");
    }
}

}  // namespace

// Returns $HOME free space in GB, or -1 if statvfs fails.
long home_free_gb(const Context& ctx) {
    struct statvfs vfs{};
    if (::statvfs(ctx.home.c_str(), &vfs) != 0) return -1;
    return static_cast<long>((vfs.f_bavail * vfs.f_bsize) / (1024L * 1024L * 1024L));
}

void run_models(Context& ctx) {
    ui::section("Local model stack — queued for background download");

    // Free-space gate first: a queue that can't fit would only leave half-finished models on disk.
    int ram  = hw::ram_gb();
    std::string tier = pick_tier(ram);
    ui::ok("RAM: " + std::to_string(ram) + "GB, VRAM: " +
           std::to_string(hw::vram_gb()) + "GB — tier: " + tier);

    long free_gb = home_free_gb(ctx);
    long need_gb = tier_min_free_gb(tier);
    if (free_gb >= 0 && free_gb < need_gb) {
        ui::warn("$HOME has only " + std::to_string(free_gb) + " GB free — the " + tier +
                 " tier needs " + std::to_string(need_gb) + "+ GB. Skipping.");
        ui::substep("free space then re-run: fox-install --only models");
        return;
    }

    fs::path upd = ctx.home / ".local/bin/fox-llm-update";
    if (!fs::exists(upd)) upd = ctx.shared_dir / "bin/fox-llm-update";
    std::string wanted;
    sh::capture({"bash", upd.string(), "--wanted"}, wanted);
    const long n = std::count(wanted.begin(), wanted.end(), '\n');

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write + enable fox-llm-update.{service,timer} and queue " + std::to_string(n) +
                    " models (and any Hugging Face GGUF list) for background download");
        return;
    }
    install_update_timer(ctx);
    if (sh::run({"bash", upd.string(), "--queue"}) == 0) {
        ui::ok(std::to_string(n) + " models queued — downloading in the background, resumes across reboots");
        ui::substep("progress: tail -f ~/.cache/fox-llm-update/queue.log");
    } else {
        ui::warn("could not start the download queue — run: fox-llm-update --queue");
    }
}

}  // namespace fox_install
