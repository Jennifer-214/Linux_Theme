// modules/specials.cpp — placeholder-resolving + bulk-dir deploy handlers.
//
// What TEMPLATE_MAPPINGS / SHARED_MAPPINGS can't express:
//
//   * FIREFOX_PROFILE / AGENT_DIR placeholders (need profile discovery).
//   * JSON merges that preserve secret keys (Gemini auth, Claude hooks).
//   * `bat cache --build` (post-deploy cache rebuild).
//   * Bulk-deploy of directories like shared/hyprland_scripts/ — same
//     file every install, but the file LIST changes when new scripts
//     are added, so listing each one in SHARED_MAPPINGS would mean
//     editing two files per new script.
//
// Each helper below mirrors a specific bash block from
// mappings.sh::install_specials line-for-line.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"
#include "../../fox-intel/json.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <system_error>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
using json   = nlohmann::json;

namespace fox_install {

namespace {

// ─── shared helpers ─────────────────────────────────────────────────
// Atomic JSON write: tmp + rename so a crash mid-write can't leave the
// caller's settings file half-written (parsers would then refuse to
// load and the IDE/CLI loses prior state). We also explicitly check
// the stream state after close — without that check a disk-full
// failure would silently produce an empty/partial tmp, and the
// subsequent rename would clobber a working config with garbage.
void write_json_atomic(const fs::path& dst, const json& body) {
    fs::path tmp = dst;
    tmp += ".foxin-tmp";
    std::error_code ec;
    {
        std::ofstream o(tmp);
        o << body.dump(2);
        o.close();
        if (!o) {
            ui::warn("write to " + tmp.string() + " failed mid-stream — "
                     "leaving " + dst.string() + " untouched");
            fs::remove(tmp, ec);
            return;
        }
    }
    fs::rename(tmp, dst, ec);
    if (ec) {
        ui::warn("atomic JSON write to " + dst.string() + " failed: " + ec.message());
        fs::remove(tmp, ec);
    }
}

bool have(const std::string& bin) { return sh::have(bin); }

void snapshot_one(const Context& ctx, const fs::path& dest) {
    std::error_code ec;
    if (!fs::exists(dest, ec) || ec) return;
    fs::path rel;
    std::string ds = dest.string(), hs = ctx.home.string();
    if (ds.rfind(hs + "/", 0) == 0) rel = ds.substr(hs.size() + 1);
    else                            rel = "_abs" + ds;
    fs::path bak = ctx.backup_dir / rel;
    fs::create_directories(bak.parent_path(), ec);
    fs::copy(dest, bak,
             fs::copy_options::overwrite_existing |
             fs::copy_options::copy_symlinks, ec);
}

bool deploy_file(const Context& ctx, const fs::path& src, const fs::path& dest) {
    std::error_code ec;
    fs::create_directories(dest.parent_path(), ec);
    snapshot_one(ctx, dest);
    fs::path tmp = dest;
    tmp += ".foxin.tmp";
    fs::copy_file(src, tmp, fs::copy_options::overwrite_existing, ec);
    if (ec) return false;
    fs::permissions(tmp, fs::status(src).permissions(),
                    fs::perm_options::replace, ec);
    fs::rename(tmp, dest, ec);
    if (ec) { fs::remove(tmp, ec); return false; }
    return true;
}

void chmod_exec(const fs::path& p) {
    std::error_code ec;
    auto perms = fs::status(p).permissions();
    perms |= fs::perms::owner_exec | fs::perms::group_exec | fs::perms::others_exec;
    fs::permissions(p, perms, fs::perm_options::replace, ec);
}

// ─── Firefox specials ───────────────────────────────────────────────
//
// Firefox 150+ on Arch uses XDG paths; older versions / non-Arch keep
// ~/.mozilla/firefox. Probe both, return whichever has a *.default-release*
// profile. Empty string means "no profile found".
fs::path firefox_profile(const Context& ctx) {
    for (const char* sub : { ".config/mozilla/firefox", ".mozilla/firefox" }) {
        fs::path base = ctx.home / sub;
        std::error_code ec;
        if (!fs::is_directory(base, ec) || ec) continue;
        for (auto& e : fs::directory_iterator(base, ec)) {
            if (!e.is_directory()) continue;
            std::string name = e.path().filename().string();
            if (name.find("default-release") != std::string::npos) {
                return e.path();
            }
        }
    }
    return {};
}

void do_firefox(const Context& ctx) {
    fs::path profile = firefox_profile(ctx);
    if (profile.empty()) {
        ui::ok("no Firefox profile found, skipping");
        return;
    }
    fs::path chrome = profile / "chrome";
    fs::create_directories(chrome);
    for (const char* css : { "userChrome.css", "userContent.css" }) {
        fs::path src = ctx.rendered_dir / "firefox" / css;
        if (!fs::exists(src)) continue;
        if (deploy_file(ctx, src, chrome / css)) {
            ui::substep(std::string("Firefox ") + css);
        }
    }
    // Set the legacy stylesheet pref via user.js — read on every launch
    // and wins over prefs.js, so this stays correct even if Firefox
    // rewrites prefs.
    fs::path userjs = profile / "user.js";
    const std::string key = "toolkit.legacyUserProfileCustomizations.stylesheets";
    const std::string pref = "user_pref(\"" + key + "\", true);";
    
    std::ifstream existing(userjs);
    std::string body((std::istreambuf_iterator<char>(existing)),
                      std::istreambuf_iterator<char>());
    existing.close();

    bool needs_update = false;
    size_t pos = body.find(key);
    if (pos == std::string::npos) {
        // Missing entirely
        body += "\n// FoxML theming\n" + pref + "\n";
        needs_update = true;
    } else {
        // Check if it's set to false
        size_t line_start = body.rfind("\n", pos);
        if (line_start == std::string::npos) line_start = 0;
        else line_start++;
        
        size_t line_end = body.find("\n", pos);
        if (line_end == std::string::npos) line_end = body.size();
        
        std::string line = body.substr(line_start, line_end - line_start);
        if (line.find("false") != std::string::npos) {
            body.replace(line_start, line_end - line_start, pref);
            needs_update = true;
        }
    }

    if (needs_update) {
        fs::path tmp = userjs;
        tmp += ".tmp";
        std::ofstream out(tmp);
        out << body;
        out.close();
        fs::rename(tmp, userjs);
        ui::substep("Firefox user.js (legacy stylesheet pref forced true)");
    }
    // Restart Firefox so the new CSS loads. Session restore brings tabs
    // back on relaunch. Skipped silently if not running.
    if (sh::run({"sh", "-c", "pgrep -x firefox >/dev/null 2>&1"}) == 0) {
        sh::run({"sh", "-c", "pkill -TERM -x firefox || true"});
        // Wait up to ~10s for graceful exit.
        for (int i = 0; i < 20; ++i) {
            if (sh::run({"sh", "-c", "pgrep -x firefox >/dev/null 2>&1"}) != 0) break;
            ::usleep(500'000);
        }
        sh::run({"sh", "-c", "setsid -f firefox >/dev/null 2>&1 &"});
        ui::substep("Firefox restarted (session restore brings tabs back)");
    }
}

// ─── Cursor / VS Code ──────────────────────────────────────────────
void do_cursor_vscode(const Context& ctx) {
    fs::path src = ctx.rendered_dir / "cursor/foxml-color-theme.json";
    if (!fs::exists(src)) return;
    for (const char* rel : { ".cursor/extensions", ".vscode/extensions" }) {
        fs::path ext_dir = ctx.home / rel;
        std::error_code ec;
        if (!fs::is_directory(ext_dir, ec)) continue;
        fs::path target = ext_dir / "foxml-theme";
        fs::create_directories(target / "themes");
        deploy_file(ctx, src, target / "themes/foxml-color-theme.json");
        std::ofstream pkg(target / "package.json");
        pkg << "{\n"
               "  \"name\": \"foxml-theme\",\n"
               "  \"displayName\": \"Fox ML Theme\",\n"
               "  \"version\": \"1.0.0\",\n"
               "  \"publisher\": \"foxml\",\n"
               "  \"engines\": { \"vscode\": \"^1.60.0\" },\n"
               "  \"categories\": [\"Themes\"],\n"
               "  \"contributes\": {\n"
               "    \"themes\": [{ \"label\": \"Fox ML\", \"uiTheme\": \"vs-dark\", "
               "\"path\": \"./themes/foxml-color-theme.json\" }]\n"
               "  }\n"
               "}\n";
        std::string editor_name = std::string(rel).substr(1, 6);  // "cursor" / "vscode"
        ui::substep(editor_name + " theme");
    }
}

// ─── Bat cache rebuild ─────────────────────────────────────────────
void do_bat_config(const Context& ctx) {
    if (!have("bat")) return;
    fs::path bat_dir = ctx.home / ".config/bat";
    if (fs::is_directory(bat_dir / "themes")) {
        fs::path conf = bat_dir / "config";
        std::string theme_line = "--theme=\"Fox ML\"";
        if (fs::exists(conf)) {
            std::string body;
            sh::capture({"grep", "-q", "^--theme=", conf.string()}, body);
            if (sh::run({"grep", "-q", "^--theme=", conf.string()}) == 0) {
                sh::run({"sed", "-i", "-E", "s|^--theme=.*|" + theme_line + "|", conf.string()});
            } else {
                std::ofstream o(conf, std::ios::app);
                o << theme_line << "\n";
            }
        } else {
            fs::create_directories(bat_dir);
            std::ofstream o(conf);
            o << theme_line << "\n";
        }
        ui::substep("bat --theme=\"Fox ML\"");
    }
}

void do_bat_cache() {
    if (!have("bat")) return;
    sh::run({"sh", "-c", "bat cache --build >/dev/null 2>&1"});
    ui::substep("Bat cache rebuilt");
}

// ─── Git Delta include ─────────────────────────────────────────────
void do_git_delta(const Context& ctx) {
    if (!have("delta")) return;
    fs::path delta_inc = ctx.home / ".config/git/delta-foxml.gitconfig";
    if (fs::exists(ctx.rendered_dir / "git/delta.gitconfig")) {
        // We use git config --global --add include.path to wire it in.
        std::string current;
        if (sh::capture({"git", "config", "--global", "--get-all", "include.path"}, current)) {
            if (current.find(delta_inc.string()) == std::string::npos) {
                sh::run({"git", "config", "--global", "--add", "include.path", delta_inc.string()});
            }
        } else {
            sh::run({"git", "config", "--global", "--add", "include.path", delta_inc.string()});
        }
        ui::substep("git delta include → " + delta_inc.string());
    }
}

// ─── Gemini settings jq-merge ──────────────────────────────────────
//
// Merge contract (matches bash jq invocation):
//   . * $new[0]                       — deep-merge entire object
//   | .hooks = $new[0].hooks         — replace .hooks wholesale
//   | .ui    = $new[0].ui            — replace .ui wholesale
//
// Translated to nlohmann/json: start from existing settings, deep-merge
// rendered settings on top, then overwrite .hooks / .ui with the
// rendered values. .security and similar top-level keys are preserved.
void do_gemini(const Context& ctx) {
    fs::path rendered = ctx.rendered_dir / "gemini/settings.json";
    if (!fs::exists(rendered)) return;

    const char* gem_env = std::getenv("GEMINI_CONFIG_HOME");
    fs::path gem_dir = (gem_env && *gem_env) ? fs::path(gem_env)
                                              : (ctx.home / ".gemini");
    fs::path target = gem_dir / "settings.json";

    json new_j;
    try {
        std::ifstream f(rendered);
        f >> new_j;
    } catch (const std::exception& e) {
        ui::warn(std::string("Gemini parse failed: ") + e.what());
        return;
    }

    if (!fs::exists(target)) {
        fs::create_directories(target.parent_path());
        write_json_atomic(target, new_j);
        ui::substep("Gemini settings installed");
        return;
    }

    json existing;
    try {
        std::ifstream f(target);
        f >> existing;
    } catch (...) {
        ui::warn("Gemini existing settings.json unparseable, skipping merge");
        return;
    }

    // Deep merge new onto existing (nlohmann/json's merge_patch deep-merges).
    existing.merge_patch(new_j);
    // Then force-replace .hooks and .ui wholesale.
    if (new_j.contains("hooks")) existing["hooks"] = new_j["hooks"];
    if (new_j.contains("ui"))    existing["ui"]    = new_j["ui"];

    write_json_atomic(target, existing);
    ui::substep("Gemini settings (hooks + theme) merged");
}

// ─── Claude CLI hooks merge ────────────────────────────────────────
void do_claude_hooks(const Context& ctx) {
    fs::path claude_dir = ctx.home / ".claude";
    fs::path settings   = claude_dir / "settings.json";
    if (!have("claude") && !fs::is_directory(claude_dir)) return;
    fs::create_directories(claude_dir);

    json hooks = {
        {"hooks", {
            {"Stop", {{
                {"matcher", ""},
                {"hooks", {{ {"type","command"},
                             {"command","~/.config/hypr/scripts/agent_notify.sh claude stop"} }}}
            }}},
            {"SubagentStop", {{
                {"matcher", ""},
                {"hooks", {{ {"type","command"},
                             {"command","~/.config/hypr/scripts/agent_notify.sh claude subagent"} }}}
            }}},
            {"Notification", {{
                {"matcher", ""},
                {"hooks", {{ {"type","command"},
                             {"command","~/.config/hypr/scripts/agent_notify.sh claude notification"} }}}
            }}},
        }}
    };

    if (!fs::exists(settings)) {
        json out = hooks;
        out["theme"] = "dark-ansi";
        write_json_atomic(settings, out);
        ui::substep("Claude settings (hooks + theme) created");
        return;
    }

    json existing;
    try {
        std::ifstream f(settings);
        f >> existing;
    } catch (...) {
        ui::warn("Claude existing settings.json unparseable, skipping merge");
        return;
    }
    existing.merge_patch(hooks);
    existing["theme"] = "dark-ansi";   // force-flip to dark-ansi on every run
    write_json_atomic(settings, existing);
    ui::substep("Claude settings (hooks + theme) merged");
}

// ─── Bulk-dir deploys ──────────────────────────────────────────────
struct BulkSpec {
    const char* src_subdir;          // relative to script_dir
    const char* dest_dir;            // relative to $HOME
    const char* glob_ext;            // ".sh", ".conf", or "" for all files
    bool        make_exec;           // chmod +x after deploy
    const char* label;
    // Filenames to skip (nullptr-terminated). Used to exclude legacy
    // bash scripts that have been replaced by native binaries.
    const char* const* skip_names;
};

bool name_in_skip_list(const std::string& name, const char* const* skips) {
    if (!skips) return false;
    for (auto** s = const_cast<const char**>(skips); *s; ++s) {
        if (name == *s) return true;
    }
    return false;
}

// Deploy every file matching glob_ext under src_subdir to dest_dir.
// Idempotent — backup_and_copy snapshots existing files first.
std::size_t deploy_dir_files(const Context& ctx, const BulkSpec& spec) {
    fs::path src_root = ctx.script_dir / spec.src_subdir;
    fs::path dst_root = ctx.home       / spec.dest_dir;
    std::error_code ec;
    if (!fs::is_directory(src_root, ec)) return 0;
    fs::create_directories(dst_root);

    std::vector<fs::path> files;
    for (auto& e : fs::directory_iterator(src_root, ec)) {
        if (!e.is_regular_file()) continue;
        if (spec.glob_ext && *spec.glob_ext) {
            if (e.path().extension() != spec.glob_ext) continue;
        }
        if (name_in_skip_list(e.path().filename().string(), spec.skip_names)) {
            continue;
        }
        files.push_back(e.path());
    }

    std::size_t done = 0;
    for (auto& src : files) {
        fs::path dest = dst_root / src.filename();
        if (deploy_file(ctx, src, dest)) {
            if (spec.make_exec) chmod_exec(dest);
            ++done;
        }
    }
    if (done > 0) {
        ui::ok(std::string(spec.label) + ": " + std::to_string(done) + " file(s)");
    }
    return done;
}

// Hyprland modules — same shape as bulk dir, but skip theme/nvidia
// (managed by render + nvidia modules) and skip monitors.conf if it
// already exists (don't clobber user-edited layout).
void do_hyprland_modules(const Context& ctx) {
    fs::path src_root = ctx.script_dir / "shared/hyprland_modules";
    fs::path dst_root = ctx.home       / ".config/hypr/modules";
    std::error_code ec;
    if (!fs::is_directory(src_root, ec)) return;
    fs::create_directories(dst_root);

    std::size_t done = 0;
    for (auto& e : fs::directory_iterator(src_root, ec)) {
        if (!e.is_regular_file()) continue;
        if (e.path().extension() != ".conf") continue;
        std::string name = e.path().filename().string();
        if (name == "theme.conf" || name == "nvidia.conf") continue;
        if (name == "monitors.conf" && fs::exists(dst_root / "monitors.conf")) continue;
        if (deploy_file(ctx, e.path(), dst_root / name)) ++done;
    }
    if (done > 0) ui::ok("hyprland modules: " + std::to_string(done) + " file(s)");
}

// KEYBINDS.md → ~/.local/share/foxml/  (for fox-cheatsheet).
void do_keybinds_md(const Context& ctx) {
    fs::path src = ctx.script_dir / "KEYBINDS.md";
    if (!fs::exists(src)) return;
    fs::path dst = ctx.home / ".local/share/foxml/KEYBINDS.md";
    if (deploy_file(ctx, src, dst)) ui::substep("KEYBINDS.md → ~/.local/share/foxml/");
}

// Stage ReGreet (themed login screen) files to ~/.config/regreet/.
// The greetd module reads them from there and `sudo install`s them
// to /etc/greetd/. Without this staging, run_greetd bails with
// "staged regreet files missing". Mirrors mappings.sh:install_specials
// lines 428-435.
void do_regreet_stage(const Context& ctx) {
    fs::path rendered_css = ctx.rendered_dir / "regreet/regreet.css";
    if (!fs::exists(rendered_css)) return;       // no regreet templates rendered

    fs::path stage = ctx.home / ".config/regreet";
    fs::create_directories(stage);
    deploy_file(ctx, rendered_css,
                stage / "regreet.css");
    deploy_file(ctx, ctx.script_dir / "shared/regreet.toml",
                stage / "regreet.toml");
    deploy_file(ctx, ctx.script_dir / "shared/greetd_hyprland.conf",
                stage / "hyprland.conf");
    fs::path picker_src = ctx.script_dir / "shared/greetd_select_monitor.sh";
    fs::path picker_dst = stage / "select-monitor.sh";
    if (deploy_file(ctx, picker_src, picker_dst)) chmod_exec(picker_dst);
    ui::substep("ReGreet staged to ~/.config/regreet/ (greetd module will deploy)");
}

// btop: set color_theme="foxml" in ~/.config/btop/btop.conf. The btop
// theme file lands via TEMPLATE_MAPPINGS but the .conf still defaults
// to the stock theme until this sed runs.
void do_btop_theme(const Context& ctx) {
    fs::path conf = ctx.home / ".config/btop/btop.conf";
    if (!fs::exists(conf)) return;
    // If the line already says foxml, no-op.
    if (sh::run({"sh", "-c",
                 "grep -qE '^color_theme = \"foxml\"' " + conf.string()}) == 0) {
        return;
    }
    // Match commented OR uncommented color_theme line. -i.bak preserves
    // the original for revert.
    sh::run({"sed", "-i",
             "-E", "s|^#?color_theme = \".*\"|color_theme = \"foxml\"|",
             conf.string()});
    ui::substep("btop color_theme → foxml");
}

// ─── Systemd user services ─────────────────────────────────────────
void do_systemd_user(const Context& ctx) {
    fs::path src_root = ctx.script_dir / "shared/systemd_user";
    fs::path dst_root = ctx.home       / ".config/systemd/user";
    std::error_code ec;
    if (!fs::is_directory(src_root, ec)) return;
    fs::create_directories(dst_root);

    std::size_t done = 0;
    for (auto& e : fs::directory_iterator(src_root, ec)) {
        if (!e.is_regular_file()) continue;
        if (deploy_file(ctx, e.path(), dst_root / e.path().filename())) ++done;
    }
    if (done == 0) return;

    sh::systemctl_daemon_reload(/*user=*/true);

    // Auto-enable core watchers
    for (const char* svc : { "fox-monitor-watch.service", "foxml-focus-pulse.service" }) {
        if (fs::exists(dst_root / svc)) {
            sh::systemctl_enable(svc, /*user=*/true);
        }
    }

    // Wallpaper rotation timer
    if (ctx.rotate_wallpapers) {
        sh::systemctl_enable("wallpaper-rotate.timer", /*user=*/true);
        ui::ok("wallpaper rotation timer enabled");
    } else {
        // Explicitly disable if it was previously enabled.
        sh::run({"systemctl", "--user", "disable", "--now", "wallpaper-rotate.timer"});
        ui::ok("wallpaper rotation timer disabled (static mode)");
    }
}

// ─── Wallpaper mode patch ──────────────────────────────────────────
void do_wallpaper_mode(const Context& ctx) {
    fs::path autostart = ctx.home / ".config/hypr/modules/autostart.conf";
    if (!fs::exists(autostart)) return;

    if (ctx.rotate_wallpapers) {
        // Ensure no --static flag
        sh::run({"sed", "-i", "s|rotate_wallpaper.sh --static|rotate_wallpaper.sh|g", autostart.string()});
        ui::substep("wallpaper mode: rotating");
    } else {
        // Ensure --static flag exists exactly once.
        sh::run({"sed", "-i", "/rotate_wallpaper.sh/ { /--static/! s|rotate_wallpaper.sh|rotate_wallpaper.sh --static| }", autostart.string()});
        ui::substep("wallpaper mode: static (FoxML Earthy)");
    }
}

}  // namespace

void run_specials(Context& ctx) {
    ui::section("Special configs");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would: Firefox CSS+user.js, Cursor/VS Code theme, "
                    "Bat cache rebuild, Gemini+Claude settings jq-merge, "
                    "hyprland_scripts + waybar_scripts + hyprland_modules + wallpapers + bin deploy, "
                    "KEYBINDS.md to ~/.local/share/foxml/, systemd user units");
        return;
    }

    do_firefox(ctx);
    do_cursor_vscode(ctx);
    do_bat_config(ctx);
    do_bat_cache();
    do_git_delta(ctx);
    do_gemini(ctx);
    do_claude_hooks(ctx);

    // fox-monitor-watch.sh has been replaced by fox-pulse + the
    // `fox-install --only monitors,personalize` handler — skip it so
    // the deployed runtime no longer depends on mappings.sh.
    static const char* HYPR_SKIPS[] = { "fox-monitor-watch.sh", nullptr };

    static const BulkSpec BULK[] = {
        { "shared/bin",              ".local/bin",             "",    true,  "bin tools",        nullptr },
        { "shared/hyprland_scripts", ".config/hypr/scripts",   ".sh", true,  "hyprland scripts", HYPR_SKIPS },
        { "shared/waybar_scripts",   ".config/waybar/scripts", ".sh", true,  "waybar scripts",   nullptr },
        { "shared/wallpapers",       ".wallpapers",            "",    false, "wallpapers",       nullptr },
    };
    for (auto& s : BULK) deploy_dir_files(ctx, s);

    do_hyprland_modules(ctx);
    do_wallpaper_mode(ctx);
    do_keybinds_md(ctx);
    do_regreet_stage(ctx);
    do_btop_theme(ctx);
    do_systemd_user(ctx);
}

}  // namespace fox_install
