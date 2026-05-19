// modules/summary.cpp — end-of-install summary report.
//
// Always runs last (registered at the end of modules.def). Prints a
// pacman-style block of "what got configured" so the user sees a clean
// recap regardless of how many other modules ran. Bash's equivalent
// listed each detected monitor with its WxH and the wallpaper count;
// this native version reads the monitor-layout sidecar + .wallpapers/
// dir to reproduce those rows.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../core/sidecar.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <sstream>
#include <string>
#include <system_error>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

std::size_t count_wallpapers(const fs::path& wall_dir) {
    std::error_code ec;
    if (!fs::is_directory(wall_dir, ec)) return 0;
    std::size_t n = 0;
    for (auto& e : fs::directory_iterator(wall_dir, ec)) {
        if (!e.is_regular_file()) continue;
        std::string ext = e.path().extension().string();
        for (auto& c : ext) c = std::tolower(static_cast<unsigned char>(c));
        if (ext == ".jpg" || ext == ".jpeg" || ext == ".png" || ext == ".webp") {
            ++n;
        }
    }
    return n;
}

}  // namespace

void run_summary(Context& ctx) {
    ui::section("Installation summary");
    ui::summary_row("theme",        ctx.theme_name);
    ui::summary_row("script_dir",   ctx.script_dir.string());
    ui::summary_row("rendered_dir", ctx.rendered_dir.string());
    ui::summary_row("config_home",  ctx.config_home.string());

    std::string hw;
    if (ctx.has_nvidia)    hw += "NVIDIA ";
    if (ctx.has_amd_gpu)   hw += "AMD ";
    if (ctx.has_intel_gpu) hw += "Intel ";
    if (hw.empty())        hw = "(none detected)";
    ui::summary_row("gpu",       hw);
    ui::summary_row("chassis",   ctx.is_laptop ? "laptop" : "desktop");
    if (ctx.has_fprint) ui::summary_row("fingerprint", "present");

    // Per-monitor enumeration — bash listed each entry from
    // MONITOR_RESOLUTIONS. Sidecar is the source of truth post-install.
    fs::path layout_path = ctx.config_home / "foxml/monitor-layout.conf";
    auto layout = sidecar::read(layout_path);
    if (!layout.primary.empty()) {
        ui::summary_row("primary monitor", layout.primary);
    }
    if (!layout.monitor_resolutions.empty()) {
        std::string row = std::to_string(layout.monitor_resolutions.size()) + " (";
        for (std::size_t i = 0; i < layout.monitor_resolutions.size(); ++i) {
            if (i > 0) row += ", ";
            row += layout.monitor_resolutions[i];
        }
        row += ")";
        ui::summary_row("monitors", row);
    }
    if (!layout.portrait_outputs.empty()) {
        std::string row;
        for (std::size_t i = 0; i < layout.portrait_outputs.size(); ++i) {
            if (i > 0) row += " ";
            row += layout.portrait_outputs[i];
        }
        ui::summary_row("portrait", row);
    }

    // Wallpaper count.
    std::size_t w = count_wallpapers(ctx.home / ".wallpapers");
    if (w > 0) ui::summary_row("wallpapers", std::to_string(w) + " file(s)");

    // Backup directory (only meaningful if symlinks actually wrote any).
    std::error_code ec;
    if (fs::is_directory(ctx.backup_dir, ec) && !ec) {
        ui::summary_row("backups saved to", ctx.backup_dir.string());
    }

    // fox-doctor headline result, matching the bash summary's
    // "Health check" row. fox-doctor's last line is "Result: ...";
    // we strip ANSI codes for clean alignment. Skipped when fox-doctor
    // isn't on PATH yet (first install). 10s timeout so a hung
    // doctor invocation can't wedge the end-of-install.
    if (!ctx.dry_run) {
        std::string doctor_out;
        if (sh::capture({"sh", "-c", "timeout 10 fox-doctor 2>&1 | tail -40"}, doctor_out)) {
            std::string result_line;
            std::istringstream is(doctor_out);
            std::string line;
            while (std::getline(is, line)) {
                if (line.rfind("Result:", 0) == 0 ||
                    line.find("Result:") != std::string::npos) {
                    result_line = line;
                }
            }
            if (!result_line.empty()) {
                // Strip ANSI \033[…m sequences for column alignment.
                std::string clean;
                clean.reserve(result_line.size());
                for (std::size_t i = 0; i < result_line.size(); ++i) {
                    if (result_line[i] == '\033') {
                        while (i < result_line.size() && result_line[i] != 'm') ++i;
                        continue;
                    }
                    clean.push_back(result_line[i]);
                }
                // Strip leading "Result: " if present.
                auto pos = clean.find("Result:");
                if (pos != std::string::npos) clean = clean.substr(pos + 7);
                auto a = clean.find_first_not_of(" \t");
                if (a != std::string::npos) clean = clean.substr(a);
                if (!clean.empty()) {
                    ui::summary_row("health check", clean);
                    ui::substep("run `fox doctor` for the full report");
                }
            }
        }
    }

    if (ctx.dry_run) {
        ui::substep("dry-run: no changes were applied");
    }
}

}  // namespace fox_install
