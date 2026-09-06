// fox-monitor — monitor layout: status / reconcile / rotate (hotplug-safe).
//
// Slice A of the monitor-seamless plan: a strictly read-only `status`
// diagnostic plus loud stubs for `reconcile` / `rotate` (Slice C). This
// tool is ADDITIVE — it never touches fox-install behavior and `status`
// never writes any file.
//
// `status` surfaces the half-migrated hot-swap state on this box:
//   1. live Hyprland monitors (hyprctl monitors -j)
//   2. the persisted sidecar (~/.config/foxml/monitor-layout.conf)
//   3. wallpaper-variant coverage per declared resolution
//   4. which deployment mechanism is actually live (watch service /
//      fox-pulse process / installed binary)

#include "../fox-common/ui.hpp"
#include "../fox-common/shell.hpp"
#include "sidecar.hpp"
#include "rederive.hpp"
#include "apply.hpp"
#include "variants.hpp"

#include "../fox-common/json.hpp"

#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using json   = nlohmann::json;
namespace ui = fox_install::ui;
namespace sh = fox_install::sh;

namespace {

fs::path home_dir() {
    const char* h = std::getenv("HOME");
    return h ? fs::path(h) : fs::path();
}

// Join a vector with single spaces — for displaying the parsed sidecar
// fields the way they appear on disk.
std::string join_ws(const std::vector<std::string>& v) {
    std::string out;
    for (size_t i = 0; i < v.size(); ++i) {
        if (i) out += ' ';
        out += v[i];
    }
    return out;
}

std::string trim(const std::string& s) {
    auto b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return {};
    auto e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

// --- status sections -------------------------------------------------

void report_live_monitors() {
    ui::section("Live monitors (hyprctl)");
    if (!sh::have("hyprctl")) {
        ui::warn("hyprctl not on PATH — Hyprland not running? Skipping live view");
        return;
    }
    std::string raw;
    if (!sh::capture({"hyprctl", "monitors", "-j"}, raw) || raw.empty()) {
        ui::warn("Hyprland not running — no live monitor data");
        return;
    }
    json monitors;
    try {
        monitors = json::parse(raw);
    } catch (const std::exception& e) {
        ui::warn(std::string("hyprctl monitors -j parse failed: ") + e.what());
        return;
    }
    if (!monitors.is_array()) {
        ui::warn("unexpected hyprctl output shape");
        return;
    }
    for (auto& m : monitors) {
        std::string name = m.value("name", "?");
        int w = m.value("width", 0), h = m.value("height", 0);
        int transform = m.value("transform", 0);
        double scale = m.value("scale", 1.0);
        bool focused = m.value("focused", false);
        bool portrait = (transform == 1 || transform == 3);

        std::ostringstream o;
        o << name << "  " << w << "x" << h
          << "  transform=" << transform
          << (portrait ? " (portrait)" : " (landscape)")
          << "  scale=" << scale
          << (focused ? "  [focused]" : "");
        ui::substep(o.str());
    }
}

void report_sidecar(const fox_monitor::sidecar::Layout& sc,
                    bool found, const fs::path& path) {
    ui::section("Persisted layout (sidecar)");
    if (!found) {
        ui::warn("no sidecar at " + path.string() + " — run a monitor configure first");
        return;
    }
    ui::substep("PRIMARY             = " + sc.primary);
    ui::substep("PORTRAIT_OUTPUTS    = " + join_ws(sc.portrait_outputs));
    ui::substep("SECONDARY_OUTPUTS   = " + join_ws(sc.secondary_outputs));
    ui::substep("MONITOR_RESOLUTIONS = " + join_ws(sc.monitor_resolutions));
}

void report_variant_coverage(const fox_monitor::sidecar::Layout& sc) {
    ui::section("Wallpaper variant coverage");
    fs::path wp_dir = home_dir() / ".wallpapers";
    fs::path current = wp_dir / ".current";

    std::error_code ec;
    fs::path target = fs::read_symlink(current, ec);
    if (ec) {
        ui::warn("no active wallpaper symlink at " + current.string());
        return;
    }
    // target is a bare filename like "foxml_earth_2.jpg"
    std::string fname = target.filename().string();
    std::string ext;
    std::string base = fname;
    auto dot = fname.find_last_of('.');
    if (dot != std::string::npos) {
        base = fname.substr(0, dot);
        ext  = fname.substr(dot + 1);
    }
    ui::substep("active base = " + base + (ext.empty() ? "" : " (." + ext + ")"));

    if (sc.monitor_resolutions.empty()) {
        ui::warn("MONITOR_RESOLUTIONS empty — nothing to check");
        return;
    }
    for (const auto& entry : sc.monitor_resolutions) {
        // entry form: name:WxH
        auto colon = entry.find(':');
        if (colon == std::string::npos) continue;
        std::string name = entry.substr(0, colon);
        std::string res  = entry.substr(colon + 1);
        if (res.empty()) continue;

        fs::path variant = wp_dir / (base + "_" + res + (ext.empty() ? "" : "." + ext));
        if (fs::exists(variant))
            ui::ok(name + " (" + res + "): " + variant.filename().string() + " present");
        else
            ui::warn(name + " (" + res + "): " + variant.filename().string() + " MISSING");
    }
}

void report_deployment_state() {
    ui::section("Hot-swap deployment state");

    std::string svc_out;
    sh::capture({"systemctl", "--user", "is-active", "fox-monitor-watch.service"}, svc_out);
    bool watch_active = (trim(svc_out) == "active");
    if (watch_active) ui::ok("fox-monitor-watch.service: active");
    else              ui::substep("fox-monitor-watch.service: " +
                                  (svc_out.empty() ? std::string("inactive/absent")
                                                   : trim(svc_out)));

    std::string pgrep_out;
    sh::capture({"pgrep", "-x", "fox-pulse"}, pgrep_out);
    bool pulse_running = !trim(pgrep_out).empty();
    if (pulse_running) ui::ok("fox-pulse process: running (pid " + trim(pgrep_out) + ")");
    else               ui::substep("fox-pulse process: not running");

    fs::path pulse_bin = home_dir() / ".local/bin/fox-pulse";
    bool pulse_installed = fs::exists(pulse_bin);
    if (pulse_installed) ui::ok("fox-pulse binary: installed (" + pulse_bin.string() + ")");
    else                 ui::substep("fox-pulse binary: not installed");

    // One-line summary of which mechanism is live.
    std::string live;
    if (pulse_running)
        live = "fox-pulse daemon (event-driven)";
    else if (watch_active)
        live = "fox-monitor-watch.service (legacy watcher)";
    else
        live = "NONE — no hot-swap mechanism appears live";
    ui::substep("=> active hot-swap mechanism: " + live);
}

int cmd_status() {
    fs::path sidecar_path = home_dir() / ".config/foxml/monitor-layout.conf";
    std::error_code ec;
    bool found = fs::exists(sidecar_path, ec) && !ec;
    fox_monitor::sidecar::Layout sc = fox_monitor::sidecar::read(sidecar_path);

    report_live_monitors();
    report_sidecar(sc, found, sidecar_path);
    report_variant_coverage(sc);
    report_deployment_state();
    return 0;
}

// reconcile — re-derive the layout from live Hyprland state, regenerate the
// per-monitor wallpaper variants, and RE-APPLY the CURRENT wallpaper to each
// monitor. Never rotates (the base is the .current symlink, not a clock slot).
// Composition of the libfox-monitor submodules: rederive → sidecar::write →
// variants::generate → apply::apply_current → waybar regen.
int cmd_reconcile(bool dry_run, bool force) {
    if (dry_run) sh::set_dry_run(true);

    fs::path sidecar_path = home_dir() / ".config/foxml/monitor-layout.conf";
    fs::path wall_dir     = home_dir() / ".wallpapers";

    ui::section(dry_run ? "Reconcile monitor layout (dry-run — no writes)"
                        : "Reconcile monitor layout");

    fox_monitor::sidecar::Layout prev = fox_monitor::sidecar::read(sidecar_path);

    fox_monitor::sidecar::Layout layout = fox_monitor::rederive::from_live(prev);
    if (layout.primary.empty()) {
        ui::err("could not derive layout from live Hyprland (hyprctl unavailable "
                "or no monitors) — aborting");
        return 1;
    }

    ui::section("Derived layout");
    ui::substep("PRIMARY             = " + layout.primary);
    ui::substep("PORTRAIT_OUTPUTS    = " + join_ws(layout.portrait_outputs));
    ui::substep("SECONDARY_OUTPUTS   = " + join_ws(layout.secondary_outputs));
    ui::substep("MONITOR_RESOLUTIONS = " + join_ws(layout.monitor_resolutions));

    // Persist the fresh layout. sidecar::write is its own tmp+rename — under
    // dry-run we skip the write so nothing on disk changes.
    if (dry_run) {
        ui::substep("would write sidecar -> " + sidecar_path.string());
    } else if (fox_monitor::sidecar::write(sidecar_path, layout)) {
        ui::ok("sidecar updated -> " + sidecar_path.string());
    } else {
        ui::err("failed to write sidecar -> " + sidecar_path.string());
        return 1;
    }

    ui::section("Per-monitor wallpaper variants");
    fox_monitor::variants::generate(wall_dir, layout.monitor_resolutions, dry_run, force);

    ui::section("Apply current wallpaper");
    std::size_t applied =
        fox_monitor::apply::apply_current(layout, wall_dir, dry_run);

    // Regenerate waybar if the start script is deployed (hotplug can add/drop
    // a bar). Fire-and-forget: background it INSIDE the shell (`… &`) so we
    // don't block on the long-lived waybar, and redirect its output off our
    // terminal. setsid detaches it into its own session so it survives our exit.
    ui::section("Waybar");
    fs::path waybar_start = home_dir() / ".config/hypr/scripts/start_waybar.sh";
    if (fs::exists(waybar_start)) {
        if (dry_run) {
            ui::substep("would regen waybar -> setsid " + waybar_start.string() + " (detached)");
        } else {
            sh::run({"bash", "-c",
                     "setsid '" + waybar_start.string() + "' >/dev/null 2>&1 &"});
            ui::ok("waybar regen triggered (detached)");
        }
    } else {
        ui::substep("start_waybar.sh not deployed — skipping waybar regen");
    }

    ui::section("Summary");
    ui::substep((dry_run ? "would apply to " : "applied to ") +
                std::to_string(applied) + " monitor(s)");
    return 0;
}

void usage() {
    std::cerr <<
        "fox-monitor — monitor layout: status / reconcile / rotate (hotplug-safe)\n"
        "\n"
        "Usage: fox-monitor <command> [--dry-run] [--force]\n"
        "\n"
        "Commands:\n"
        "  status      Read-only diagnostic: live monitors, persisted layout,\n"
        "              wallpaper-variant coverage, and live hot-swap mechanism.\n"
        "  reconcile   Re-derive the layout from live Hyprland, regenerate\n"
        "              per-monitor variants, and re-apply the CURRENT wallpaper\n"
        "              to each monitor. Never rotates. --dry-run plans only.\n"
        "  rotate      Rotate wallpaper across outputs (Slice C — not yet implemented).\n"
        "\n"
        "Flags:\n"
        "  -n, --dry-run  Plan only — no writes, no magick/esrgan, no GPU.\n"
        "  -f, --force    Regenerate ALL wallpaper variants (bypass the\n"
        "                 dims-match skip), e.g. after an ESRGAN upgrade.\n";
}

}  // namespace

int main(int argc, char** argv) {
    ui::init();

    if (argc < 2) { usage(); return 2; }
    std::string cmd = argv[1];

    bool dry_run = false;
    bool force   = false;
    for (int i = 2; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--dry-run" || a == "-n") dry_run = true;
        else if (a == "--force" || a == "-f") force = true;
    }

    if (cmd == "status") {
        return cmd_status();
    }
    if (cmd == "reconcile") {
        return cmd_reconcile(dry_run, force);
    }
    if (cmd == "rotate") {
        std::cerr << "fox-monitor: 'rotate' not yet implemented "
                     "(Slice C of the monitor-seamless plan)\n";
        return 2;
    }
    if (cmd == "--help" || cmd == "-h" || cmd == "help") {
        usage();
        return 0;
    }

    std::cerr << "fox-monitor: unknown command '" << cmd << "'\n\n";
    usage();
    return 2;
}
