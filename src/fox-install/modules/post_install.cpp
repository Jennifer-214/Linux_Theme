// modules/post_install.cpp — final live-apply step (runs last by design).
//
// Mirrors install.sh.legacy::apply_post_install:
//   * Restart waybar + dunst if currently running so the new palette
//     loads without a fresh login.
//   * Nvim Lazy + treesitter sync (60s / 120s timeouts to avoid hangs).
//   * Cursor / VS Code: jq-merge workbench.colorTheme="Fox ML".
//
// Hyprland reload is intentionally NOT triggered (legacy comment: avoids
// breaking portrait monitor configurations during install testing).

#include "../core/context.hpp"
#include "personalize.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include "../../fox-intel/json.hpp"

#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <system_error>

namespace fs = std::filesystem;
using json   = nlohmann::json;

namespace fox_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

bool process_running(const std::string& name) {
    return sh::run({"pgrep", "-x", name}) == 0;
}

void restart_detached(const std::string& killname, const std::string& spawn_cmd) {
    sh::run({"pkill", "-x", killname});
    sh::run({"setsid", "-f", spawn_cmd});
}

void cursor_vscode_set_theme(const Context& ctx) {
    if (!have("jq") && false) return;        // pure-native — no jq dependency
    for (const char* ide : { "Cursor", "Code" }) {
        fs::path root = ctx.config_home / ide;
        fs::path user = root / "User";
        if (!fs::is_directory(root)) continue;
        fs::create_directories(user);
        fs::path settings = user / "settings.json";

        json existing = json::object();
        if (fs::exists(settings)) {
            try {
                std::ifstream f(settings);
                f >> existing;
                if (!existing.is_object()) existing = json::object();
            } catch (...) { existing = json::object(); }
        }
        existing["workbench.colorTheme"] = "Fox ML";
        std::ofstream o(settings);
        o << existing.dump(2);
        ui::ok(std::string(ide) + ": workbench.colorTheme = Fox ML");
    }
}

}  // namespace

void write_active_theme_and_marker(const Context& ctx) {
    // Record the active theme name at <script_dir>/.active-theme so
    // future runs of fox-install (and the legacy bash tools that still
    // read it — swap.sh, update.sh) pick the right palette.
    {
        std::ofstream f(ctx.script_dir / ".active-theme");
        f << ctx.theme_name << "\n";
    }
    // Persistent install marker at ~/.local/share/foxml/.installed-version.
    // Bash deployed scripts (fox-monitor-watch.sh historically, plus
    // anything else that needs to walk back to the repo) consult this
    // to find FOXML_DIR.
    fs::path marker_dir = ctx.home / ".local/share/foxml";
    fs::create_directories(marker_dir);
    char ts[40] = {};
    std::time_t now = std::time(nullptr);
    std::strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%S%z", std::localtime(&now));
    std::ofstream m(marker_dir / ".installed-version");
    m << "theme="        << ctx.theme_name        << "\n"
      << "installed_at=" << ts                    << "\n"
      << "script_dir="   << ctx.script_dir.string() << "\n";
}

void run_post_install(Context& ctx) {
    ui::section("Applying post-install actions");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would: write .active-theme + install marker, "
                    "finalize per-monitor wallpaper variants + hyprlock (post-deploy), "
                    "render waybar for current layout, restart waybar+dunst+mako, "
                    "Lazy sync + TSUpdateSync (60s/120s caps), "
                    "Cursor/VS Code workbench.colorTheme=Fox ML, "
                    "remove rendered/ dir");
        return;
    }

    // Persist the active theme + install marker before anything else —
    // if a later post-install step errors, at least the state files are
    // current.
    write_active_theme_and_marker(ctx);
    ui::ok("active-theme + install marker written");

    // Finalize per-monitor personalisation now that `specials` has deployed
    // ~/.wallpapers and `symlinks` has deployed the live configs. The personalize
    // module runs back in phase 2 — before either exists on a FRESH install — so it
    // bakes no wallpaper variants then. Re-running apply_all here closes that
    // fresh-install gap: variants are generated against the now-present sources
    // (the crisp ESRGAN recipe — may take a moment when a portrait monitor needs
    // an upscaling crop) and hyprlock is re-pointed at them. The recipe-version
    // stamp + the dims-match skip make this a ONE-TIME bake — a re-install where the
    // variants already match the current recipe is a fast no-op.
    {
        fs::path layout_path = ctx.config_home / "foxml/monitor-layout.conf";
        auto layout = fox_monitor::sidecar::read(layout_path);
        if (!layout.primary.empty() || !layout.monitor_resolutions.empty()) {
            ui::substep("finalizing per-monitor wallpapers (post-deploy)");
            personalize::apply_all(ctx, layout);
        }
    }

    // Re-render waybar for the just-configured monitor layout. The
    // bash start_waybar.sh script reads ~/.config/foxml/monitor-layout.conf
    // and emits multi-bar config when secondary monitors are present;
    // without this re-render after `monitors` ran, waybar keeps the
    // pre-configure single-bar render until next login.
    fs::path start_waybar = ctx.home / ".config/hypr/scripts/start_waybar.sh";
    if (fs::exists(start_waybar)) {
        sh::run({"sh", "-c", start_waybar.string() + " --render-only >/dev/null 2>&1 || true"});
        ui::ok("waybar config re-rendered for current monitor layout");
    }

    // Hyprland reload deliberately skipped (legacy comment about portrait monitor
    // configs). Users wanting it: `hyprctl reload`.
    if (std::getenv("HYPRLAND_INSTANCE_SIGNATURE") && have("hyprctl")) {
        ui::ok("Hyprland reload skipped (run `hyprctl reload` manually if desired)");
    }

    if (process_running("waybar")) {
        if (fs::exists(start_waybar)) {
            restart_detached("waybar", start_waybar.string());
            ui::ok("Waybar restarted");
        }
    }

    if (process_running("dunst")) {
        restart_detached("dunst", "dunst");
        ui::ok("Dunst restarted");
    }

    // mako: native reload via makoctl is preferred (no popup queue loss),
    // fall back to restart if makoctl isn't around.
    if (process_running("mako")) {
        if (have("makoctl") &&
            sh::run({"sh", "-c", "makoctl reload >/dev/null 2>&1"}) == 0) {
            ui::ok("mako reloaded");
        } else {
            restart_detached("mako", "mako");
            ui::ok("mako restarted");
        }
    }

    if (have("nvim") && fs::is_directory(ctx.home / ".local/share/nvim/lazy")) {
        ui::substep("nvim Lazy sync (headless, 60s cap)");
        if (sh::run({"timeout", "60", "nvim", "--headless",
                     "+Lazy! sync", "+qa"}) == 0) {
            ui::ok("Nvim plugins synced");
        } else {
            ui::warn("Lazy sync didn't complete cleanly — run `:Lazy sync` manually");
        }
        if (fs::is_directory(ctx.home / ".local/share/nvim/lazy/nvim-treesitter")) {
            ui::substep("rebuilding treesitter parsers (headless, 120s cap)");
            if (sh::run({"timeout", "120", "nvim", "--headless",
                         "+TSUpdateSync", "+qa"}) == 0) {
                ui::ok("Treesitter parsers rebuilt");
            } else {
                ui::warn("TSUpdateSync didn't complete cleanly — run `:TSUpdateSync` manually");
            }
        }
    }

    cursor_vscode_set_theme(ctx);

    // NOTE: we deliberately keep rendered/ around. It's gitignored, so it
    // never dirties `git status` — the old "clean up for a tidy tree"
    // rationale bought nothing. Worse, render's drift detection compares
    // live ~/.config files against this previous render to warn before
    // overwriting hand-edits; deleting it makes detect_drift() early-out
    // empty, so the NEXT install silently clobbers the user's edits. See
    // render.cpp::detect_drift.
}

}  // namespace fox_install
