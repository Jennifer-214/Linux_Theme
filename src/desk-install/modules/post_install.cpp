// modules/post_install.cpp — final live-apply step (runs last by design).
//
// Mirrors install.sh.legacy::apply_post_install:
//   * Restart the bar and notifications if currently running so the new palette
//     loads without a fresh login.
//   * Nvim Lazy + treesitter sync (60s / 120s timeouts to avoid hangs).
//   * Cursor / VS Code: jq-merge workbench.colorTheme="Fox ML".
//
// Hyprland reload is intentionally NOT triggered (legacy comment: avoids
// breaking portrait monitor configurations during install testing).

#include "../core/context.hpp"
#include "personalize.hpp"
#include "gtk_appearance.hpp"
#include "firefox_appearance.hpp"
#include "notification_refresh.hpp"
#include "ide_settings.hpp"
#include "stale_services.hpp"
#include "nvim_lock.hpp"
#include "../core/idempotency.hpp"
#include "../core/state_checks.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include "../../desk-common/json.hpp"

#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <system_error>
#include <unistd.h>

namespace fs = std::filesystem;
using json   = nlohmann::json;

namespace desk_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

bool process_running(const std::string& name) {
    return sh::run({"pgrep", "-x", name}) == 0;
}

void cursor_vscode_set_theme(const Context& ctx) {
    for (const char* ide : { "Cursor", "Code" }) {
        const fs::path root = ctx.config_home / ide;
        if (!fs::is_directory(root)) continue;
        const std::string name(ide);
        switch (ide_settings::set_color_theme(ctx, root / "User/settings.json", "Fox ML")) {
            case ide_settings::Result::Updated:
                ui::ok(name + ": workbench.colorTheme = Fox ML");
                break;
            case ide_settings::Result::Unchanged:
                ui::skipped(name + " already uses Fox ML");
                break;
            case ide_settings::Result::LeftAlone:
                ui::warn(name + " settings.json has comments or isn't plain JSON, so it was left alone. "
                         "Set \"workbench.colorTheme\": \"Fox ML\" there to use the theme");
                break;
            case ide_settings::Result::Failed:
                ui::warn(name + " settings.json could not be backed up and updated; it was left as it was");
                break;
        }
    }
}

}  // namespace

void write_active_theme_and_marker(const Context& ctx) {
    // Record the active theme name at <script_dir>/.active-theme so
    // future runs of desk-install (and the legacy bash tools that still
    // read it — swap.sh, update.sh) pick the right palette. When the rendered configs did not deploy, the desktop is
    // still on the old theme, and the old name stays. A part that lags (the greeter with a cold sudo cache, the
    // drawer) does not: everything else already shows the new theme, and a tweak must not edit the old palette.
    if ((ctx.render_ran && !ctx.render_ok) || ctx.configs_failed) {
        ui::warn("theme " + ctx.theme_name + " was only partly applied — saved theme left as it was");
    } else {
        std::ofstream f(ctx.script_dir / ".active-theme");
        f << ctx.theme_name << "\n";
        if (ctx.deploy_failed) ui::warn("theme " + ctx.theme_name + " saved; some parts did not update (see the errors above)");
    }
    // Persistent install marker at ~/.local/share/foxml/.installed-version.
    // Bash deployed scripts (monitor-watch.sh historically, plus
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
                    "render waybar for current layout, restart the bar and mako, "
                    "Nvim plugins installed + restored to the lock file, the treesitter parsers installed, "
                    "GTK desktop font + accent, Thunar view + sidebar projects, Bat/delta theme cache, Cursor/VS Code workbench.colorTheme=Fox ML, "
                    "desk theme check (read-only report)");
        return;
    }

    // Persist the active theme + install marker before anything else —
    // if a later post-install step errors, at least the state files are
    // current.
    write_active_theme_and_marker(ctx);
    ui::ok("active-theme + install marker written");

    sync_gtk_font(ctx);
    sync_gtk_icon_theme(ctx);
    sync_gtk_color_scheme(ctx);
    sync_gtk_accent(ctx);
    sync_thunar_view(ctx);
    refresh_gtk_icon_cache(ctx);
    // Folder colours can need sudo, so a plain --render reports them instead of prompting.
    if (state::folders_stale(ctx))
        ui::warn("folder colours are still from the previous theme — update them with --only papirus_icons");
    if (!firefox_appearance::sync_styles(ctx))
        ui::warn("Firefox styles were not fully refreshed");

    // --render implies post-install but not specials, which normally rebuilds this cache.
    if (have("bat") && sh::run({"bat", "cache", "--build"}) != 0)
        ui::warn("Bat/delta syntax cache could not be refreshed");

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
        auto layout = desk_monitor::sidecar::read(layout_path);
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

    if (std::getenv("WAYLAND_DISPLAY") && fs::exists(start_waybar)) {
        sh::run({"setsid", "-f", start_waybar.string()});
        ui::ok("desktop bar refreshed for current palette and monitors");
    }

    const bool stock_mako = process_running("mako");
    const bool custom_mako = process_running("desk-mako");
    if (stock_mako || custom_mako) {
        const auto binary = ctx.home / ".local/bin/desk-mako";
        const auto launcher = ctx.home / ".local/bin/desk-notifications";
        const auto dropin = ctx.config_home / "systemd/user/mako.service.d/50-foxml.conf";
        const bool custom_ready = fs::exists(binary) && fs::exists(launcher) && fs::exists(dropin);
        std::string pids;
        if (custom_mako)
            sh::probe({"pgrep", "-u", std::to_string(::getuid()), "-x", "desk-mako"}, pids);
        const bool restart = custom_ready && (stock_mako || notifications::running_binary_changed(binary, pids));
        if (!restart && have("makoctl") &&
            sh::run({"sh", "-c", "makoctl reload >/dev/null 2>&1"}) == 0) {
            ui::ok("mako reloaded");
        } else if (sh::run({"systemctl", "--user", "is-active", "--quiet", "mako.service"}) == 0) {
            if (sh::run({"systemctl", "--user", "restart", "mako.service"}) == 0)
                ui::ok("Mako notification service refreshed");
            else ui::warn("Mako service restart failed; run systemctl --user restart mako.service");
        } else {
            sh::run({"pkill", "-x", custom_mako ? "desk-mako" : "mako"});
            const auto command = fs::exists(launcher) ? launcher.string()
                : (custom_mako ? binary.string() : "mako");
            if (sh::run({"setsid", "-f", command}) == 0) ui::ok("Mako notifications refreshed");
            else ui::warn("Mako could not be restarted");
        }
    }

    // A user service goes on running the program it started with: one this install replaced (desk-pulse, the bouncer's
    // script) stays the old copy until it restarts, and logging out is rare. The watchers among them restart now; the
    // theme check below (D25) names any other, fox-vault among them (a restart empties it).
    for (const auto& unit : stale::restart_replaced(ctx.home, ctx.config_home / "systemd/user", ::getuid()))
        ui::ok(unit + " restarted: it ran the version from before this install");

    // Open terminals take the new colours as well: kitty reads its config again on SIGUSR1.
    if (ctx.render_ran && ctx.render_ok && process_running("kitty") && sh::run({"pkill", "-USR1", "-x", "kitty"}) == 0)
        ui::ok("open terminals reloaded their colours");

    // Plugin maintenance, not theming: a theme swap only needs init.lua
    // re-rendered, and these two caps add up to 3 minutes to every swap.
    // swap.sh sets FOXML_SKIP_PLUGIN_SYNC so swapping stays interactive;
    // a real install leaves it unset and still syncs.
    const bool skip_plugin_sync = std::getenv("FOXML_SKIP_PLUGIN_SYNC") != nullptr;
    if (skip_plugin_sync) {
        ui::substep("plugin sync skipped (theme swap)");
    } else if (have("nvim") && fs::exists(ctx.home / ".config/nvim/init.lua")) {
        // Also on a fresh machine with no plugins yet: Lazy! install lays them all, so the first start needs nothing.
        // Restore, not sync: plugins stay at the repo lock file's versions, so a reinstall gives what was tested.
        // Updating is deliberate: :Lazy update, then commit the new lock file to shared/nvim_lazy-lock.json.
        // Lazy installs a plugin it lacks as Neovim starts, then rewrites lazy-lock.json with the commits on disk (the
        // old ones) before `restore` reads it: an upgrade that added a plugin restored the old pins. So what is missing
        // goes in first, the repo's lock is laid again, then the restore; and it says so only when the locks agree.
        const fs::path repo_lock = ctx.script_dir / "shared/nvim_lazy-lock.json";
        const fs::path lock = ctx.home / ".config/nvim/lazy-lock.json";
        ui::substep("nvim plugins installed and restored to the lock file (headless)");
        sh::run({"timeout", "600", "nvim", "--headless", "+Lazy! install", "+qa"});
        const std::string want = idem::read_file(repo_lock);
        const bool laid = !want.empty() && idem::write_atomic(lock, want);
        const int restored = sh::run({"timeout", "120", "nvim", "--headless", "+Lazy! restore", "+qa"});
        const auto off = nvim_lock::mismatches(want, idem::read_file(lock));
        if (restored == 0 && laid && off.empty()) {
            ui::ok("Nvim plugins at the lock file's versions");
        } else {
            std::string names;
            for (const auto& name : off) names += (names.empty() ? "" : ", ") + name;
            ui::warn("Plugin restore didn't complete cleanly" + (names.empty() ? std::string() : " (not at the lock: " + names + ")") +
                     " — run the install again, or `:Lazy restore` in Neovim");
        }
        // The config's parser list, installed and brought to the pinned plugin's revisions here rather than at Neovim's
        // first start (where each download stopped the screen for Enter). The command exits non-zero naming any parser
        // that did not land, so this says "installed" only when all did. (It replaced :TSUpdateSync, which the main
        // branch does not have: nvim ran it as an unknown command, exited 0, and the install said "rebuilt".)
        ui::substep("treesitter parsers installed (headless)");
        if (sh::run({"timeout", "900", "nvim", "--headless", "+DeskParsersInstall", "+qa"}) == 0) {
            ui::ok("Treesitter parsers installed");
        } else {
            ui::warn("Some treesitter parsers did not install — open Neovim and run :DeskParsersInstall");
        }
    }

    cursor_vscode_set_theme(ctx);

    // Last: check what this install or swap left behind, so a problem shows now and not days later. It only reads
    // and prints; its result never fails the install. The repo's fresh build first, the installed one otherwise.
    for (const fs::path& check : {ctx.script_dir / "src/theme-check/theme-check",
                                  ctx.home / ".local/bin/theme-check"}) {
        std::error_code ec;
        if (!fs::is_regular_file(check, ec) || ::access(check.c_str(), X_OK) != 0) continue;
        ui::section("Checking the desktop");
        const int rc = sh::run({"timeout", "180", check.string(), "--theme", ctx.theme_name});
        if (rc == 0) ui::ok("desk theme check: all clear");
        else ui::warn("desk theme check found something to look at (above); run `desk theme check --verbose` any time");
        break;
    }

    // NOTE: we deliberately keep rendered/ around. It's gitignored, so it
    // never dirties `git status` — the old "clean up for a tidy tree"
    // rationale bought nothing. Worse, render's drift detection compares
    // live ~/.config files against this previous render to warn before
    // overwriting hand-edits; deleting it makes detect_drift() early-out
    // empty, so the NEXT install silently clobbers the user's edits. See
    // render.cpp::detect_drift.
}

}  // namespace desk_install
