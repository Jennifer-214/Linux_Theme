// modules/specials.cpp — placeholder-resolving + bulk-dir deploy handlers.
//
// What TEMPLATE_MAPPINGS / SHARED_MAPPINGS can't express:
//
//   * FIREFOX_PROFILE / AGENT_DIR placeholders (need profile discovery).
//   * JSON merges that preserve user keys (Claude hooks).
//   * `bat cache --build` (post-deploy cache rebuild).
//   * Bulk-deploy of directories like shared/hyprland_scripts/ — same
//     file every install, but the file LIST changes when new scripts
//     are added, so listing each one in SHARED_MAPPINGS would mean
//     editing two files per new script.
//
// Each helper below mirrors a specific bash block from
// mappings.sh::install_specials line-for-line.

#include "../core/context.hpp"
#include "../core/backup.hpp"
#include "../core/built_tools.hpp"
#include "../core/palette.hpp"
#include "claude_wiring.hpp"
#include "nvidia_modules.hpp"
#include "hypr_lua.hpp"
#include "firefox_appearance.hpp"
#include "firefox_policies.hpp"
#include "wallpaper_mode.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"
#include "../../fox-common/json.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <system_error>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
using json   = nlohmann::json;

namespace fox_install {

namespace {

// ─── deploy-time safety guard ────────────────────────────────────────
// Bulk-deployed shell assets (shared/bin, shared/hyprland_scripts, ...)
// ship to the user verbatim. They must NEVER mutate sensitive system
// state — PAM, sudoers, the bootloader cmdline, faillock. Those edits
// are the exclusive job of fox-install modules, which gate, back up, and
// are covered by the fox-health B1/B2 lockout checks. A shell helper
// doing `sed -i '1i ... pam_fprintd' /etc/pam.d/sudo` is the canonical
// lockout footgun (memory: project_pam_fprintd_lockout). We refuse to
// deploy any such asset.
//
// KEEP IN SYNC with src/fox-install/tests/lint_shell_assets.sh — same
// path list + verb list, enforced at build time there and here at run.
bool looks_like_shell(const fs::path& p) {
    if (p.extension() == ".sh") return true;
    std::ifstream f(p);
    std::string first;
    if (!std::getline(f, first)) return false;
    return first.rfind("#!", 0) == 0 &&
           (first.find("sh") != std::string::npos);  // bash/sh/zsh shebang
}

// Returns the offending line (1-based) + text if the asset mutates a
// sensitive path, else {0, ""}.
std::pair<int, std::string> sensitive_mutation(const fs::path& p) {
    static const char* SENSITIVE[] = {
        "/etc/pam.d", "/etc/sudoers", "/boot/loader", "/efi/loader",
        "/etc/default/grub", "/etc/security/faillock", nullptr,
    };
    static const char* MUTATORS[] = {
        "sed -i", "tee ", ">", "cp ", "mv ", "install ", "ln ", "dd ",
        "truncate", "chmod", "chown", "rm ", nullptr,
    };
    std::ifstream f(p);
    std::string line;
    int n = 0;
    while (std::getline(f, line)) {
        ++n;
        size_t c = line.find_first_not_of(" \t");
        if (c != std::string::npos && line[c] == '#') continue;  // comment
        bool hits_path = false;
        for (auto** s = SENSITIVE; *s; ++s)
            if (line.find(*s) != std::string::npos) { hits_path = true; break; }
        if (!hits_path) continue;
        for (auto** m = MUTATORS; *m; ++m)
            if (line.find(*m) != std::string::npos) return {n, line};
    }
    return {0, ""};
}

// ─── shared helpers ─────────────────────────────────────────────────
// Atomic JSON write (idem::write_atomic: tmp + rename, stream state checked)
// so a crash or disk-full mid-write can't leave the caller's settings file
// half-written — parsers would refuse it and the IDE/CLI would lose its state.
void write_json_atomic(const fs::path& dst, const json& body) {
    if (!idem::write_atomic(dst, body.dump(2))) {
        ui::warn("atomic JSON write to " + dst.string() + " failed — left untouched");
    }
}

bool have(const std::string& bin) { return sh::have(bin); }

bool deploy_file(const Context& ctx, const fs::path& src, const fs::path& dest) {
    std::error_code ec;
    fs::create_directories(dest.parent_path(), ec);
    if (!snapshot_one(ctx, dest)) {
        ui::warn("refusing to overwrite " + dest.string() + " — its backup failed");
        return false;
    }
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
    return firefox_appearance::profile(ctx);
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
    // Prefs user.js enforces — it's read on every launch and wins over
    // prefs.js, so these stay put even if Firefox rewrites prefs: the legacy
    // stylesheet switch (userChrome/userContent) and the built-in vertical tabs.
    static const std::pair<const char*, const char*> PREFS[] = {
        {"toolkit.legacyUserProfileCustomizations.stylesheets", "true"},
        {"sidebar.revamp", "true"},
        {"sidebar.verticalTabs", "true"},
    };
    fs::path userjs = profile / "user.js";
    std::ifstream existing(userjs);
    std::string body((std::istreambuf_iterator<char>(existing)),
                      std::istreambuf_iterator<char>());
    existing.close();

    bool changed = false;
    for (const auto& [key, value] : PREFS) {
        const std::string pref = std::string("user_pref(\"") + key + "\", " + value + ");";
        const size_t pos = body.find(std::string("\"") + key + "\"");
        if (pos == std::string::npos) {
            if (body.find("// FoxML theming") == std::string::npos) body += "\n// FoxML theming\n";
            body += pref + "\n";
            changed = true;
            continue;
        }
        size_t line_start = body.rfind('\n', pos);
        line_start = (line_start == std::string::npos) ? 0 : line_start + 1;
        size_t line_end = body.find('\n', pos);
        if (line_end == std::string::npos) line_end = body.size();
        if (body.compare(line_start, line_end - line_start, pref) != 0) {
            body.replace(line_start, line_end - line_start, pref);
            changed = true;
        }
    }
    const fs::path find_colors = ctx.rendered_dir / "firefox/find-colors.js";
    if (fs::exists(find_colors)) {
        std::ifstream colors_file(find_colors);
        const std::string colors((std::istreambuf_iterator<char>(colors_file)), std::istreambuf_iterator<char>());
        const std::string begin = "// >>> FoxML find colors", end = "// <<< FoxML find colors";
        const auto start = body.find(begin);
        const auto stop = start == std::string::npos ? std::string::npos : body.find(end, start);
        if (start != std::string::npos && stop == std::string::npos) {
            ui::warn("Firefox find-color block is incomplete; leaving user.js untouched");
            return;
        }
        std::string next = body;
        if (start == std::string::npos) next += "\n" + colors;
        else {
            auto length = stop + end.size() - start;
            if (start + length < next.size() && next[start + length] == '\n') ++length;
            next.replace(start, length, colors);
        }
        changed = changed || next != body;
        body = std::move(next);
    }
    if (changed && snapshot_one(ctx, userjs)) {
        if (!idem::write_atomic(userjs, body)) {
            ui::warn("Could not write Firefox preferences; leaving the previous file intact");
            return;
        }
        ui::substep("Firefox user.js (stylesheets, vertical tabs, palette find colors)");
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

// ─── Firefox add-ons (Vimium) ──────────────────────────────────────
// Through Firefox's own policy file, which it reads at start: the add-on installs from addons.mozilla.org on the
// next launch. The file is root's, so the merged copy goes in beside it and is renamed over it, the old one kept as
// policies.json.foxml-bak; a file that does not parse, or has a shape Firefox would not read, is left alone.
void do_firefox_addons(const Context& ctx) {
    if (!have("firefox")) return;
    const fs::path policy = "/etc/firefox/policies/policies.json";
    json file;
    std::error_code ec;
    const bool existed = fs::exists(policy, ec);
    if (existed) {
        std::ifstream in(policy);
        if (!in) { ui::warn("Firefox policies.json is not readable — Vimium not added"); return; }
        try { in >> file; } catch (...) { ui::warn(policy.string() + " does not parse — left as it is, Vimium not added"); return; }
    }
    std::vector<std::string> added;
    for (const auto& addon : firefox_policies::ADDONS) {
        const auto merged = firefox_policies::add_extension(file, addon);
        if (merged == firefox_policies::Merge::Refused) { ui::warn(policy.string() + " has a shape Firefox would not read — left as it is"); return; }
        if (merged == firefox_policies::Merge::Added) added.push_back(addon.name);
    }
    if (added.empty()) { ui::substep("Firefox add-ons already in its policy (Vimium)"); return; }
    const fs::path staged = ctx.home / ".cache/foxml/firefox-policies.json";
    fs::create_directories(staged.parent_path(), ec);
    if (!idem::write_atomic(staged, file.dump(2) + "\n")) { ui::warn("could not stage Firefox policies.json"); return; }
    const std::string target = policy.string(), next = target + ".foxml-new";
    const bool ok = sh::run({"sudo", "install", "-D", "-m", "644", staged.string(), next}) == 0
        && (!existed || sh::run({"sudo", "cp", "-a", target, target + ".foxml-bak"}) == 0)
        && sh::run({"sudo", "mv", "-f", next, target}) == 0;
    fs::remove(staged, ec);
    if (!ok) { sh::run({"sudo", "rm", "-f", next}); ui::warn("could not write " + target + " — Firefox add-ons not added"); return; }
    std::string names;
    for (const auto& name : added) names += (names.empty() ? "" : ", ") + name;
    ui::substep("Firefox will install " + names + " on its next start (" + target + ")");
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
        const std::string ui_theme = palette::get(ctx.palette_path, "VSCODE_UI_THEME", "vs-dark");
        std::ofstream pkg(target / "package.json");
        pkg << "{\n"
               "  \"name\": \"foxml-theme\",\n"
               "  \"displayName\": \"Fox ML Theme\",\n"
               "  \"version\": \"1.0.0\",\n"
               "  \"publisher\": \"foxml\",\n"
               "  \"engines\": { \"vscode\": \"^1.60.0\" },\n"
               "  \"categories\": [\"Themes\"],\n"
               "  \"contributes\": {\n"
               "    \"themes\": [{ \"label\": \"Fox ML\", \"uiTheme\": \"" << ui_theme << "\", "
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
            // replying in a pane clears its agent note
            {"UserPromptSubmit", {{
                {"matcher", ""},
                {"hooks", {{ {"type","command"},
                             {"command","~/.config/hypr/scripts/agent_notify.sh claude seen"} }}}
            }}},
            // what each session is doing, for the bar pill and the drawer's Agents page
            {"PreCompact", {{
                {"matcher", ""},
                {"hooks", {{ {"type","command"},
                             {"command","~/.config/hypr/scripts/agent_notify.sh claude compact"} }}}
            }}},
            {"PostCompact", {{
                {"matcher", ""},
                {"hooks", {{ {"type","command"},
                             {"command","~/.config/hypr/scripts/agent_notify.sh claude compacted"} }}}
            }}},
            {"StopFailure", {{
                {"matcher", ""},
                {"hooks", {{ {"type","command"},
                             {"command","~/.config/hypr/scripts/agent_notify.sh claude failed"} }}}
            }}},
            {"SessionStart", {{
                {"matcher", ""},
                {"hooks", {{ {"type","command"},
                             {"command","~/.config/hypr/scripts/agent_notify.sh claude started"} }}}
            }}},
            {"SessionEnd", {{
                {"matcher", ""},
                {"hooks", {{ {"type","command"},
                             {"command","~/.config/hypr/scripts/agent_notify.sh claude ended"} }}}
            }}},
        }}
    };
    // the symlinks step deploys the palette's Claude theme and status line before this runs
    const bool custom_theme = fs::is_regular_file(claude_dir / "themes/foxml.json");
    const bool status_line = fs::is_regular_file(claude_dir / "statusline.sh");
    const bool paper_mod = fs::is_regular_file(claude_dir / "mods/foxml-paper/.claude-plugin/plugin.json");

    if (!fs::exists(settings)) {
        json out = json::object();
        merge_user_settings(out, hooks, custom_theme, status_line, paper_mod);
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
    // by command, never merge_patch: a merge-patch REPLACES each hook list, erasing any hook she added herself
    if (!merge_user_settings(existing, hooks, custom_theme, status_line, paper_mod))
        ui::warn("Claude settings.json: \"hooks\" is not an object — its hooks left untouched");
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
    // Skip any name a src/<tool> builds (core/built_tools.hpp): never a script over a compiled tool.
    bool skip_built_tools;
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

    const auto built = spec.skip_built_tools ? built_tool_names(ctx.script_dir / "src") : std::set<std::string>{};
    std::vector<fs::path> files;
    for (auto& e : fs::directory_iterator(src_root, ec)) {
        if (!e.is_regular_file()) continue;
        if (spec.glob_ext && *spec.glob_ext) {
            if (e.path().extension() != spec.glob_ext) continue;
        }
        if (name_in_skip_list(e.path().filename().string(), spec.skip_names)) {
            continue;
        }
        if (built.count(e.path().filename().string())) {
            ui::warn(e.path().filename().string() + " is also a compiled tool (src/) — not copying the script over it");
            continue;
        }
        if (looks_like_shell(e.path())) {
            auto [ln, text] = sensitive_mutation(e.path());
            if (ln) {
                ui::err(e.path().filename().string() +
                        " mutates a sensitive system path — REFUSING to deploy");
                ui::substep("line " + std::to_string(ln) + ": " + text);
                ui::substep("PAM/sudoers/bootloader edits belong in a fox-install module, not a shell asset");
                continue;  // skip this file, keep deploying the rest
            }
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

// Lua twin of a per-machine module, written only when missing: convert what
// this box already has (a --monitors layout, a --nvidia setup) rather than
// shipping the generic file over it, so 0.57 keeps the same monitors and GPU env.
void lua_twin(const fs::path& conf, const fs::path& lua, const std::string& fallback) {
    std::error_code ec;
    if (fs::symlink_status(lua, ec).type() != fs::file_type::not_found) return;
    const std::string body = hypr_lua::lua_twin_body(conf, fallback, nvidia_conf_placeholder());
    if (hypr_lua::write_text_atomic(lua, body))
        ui::substep("hypr/modules/" + lua.filename().string() + " (from " + conf.filename().string() + ")");
}

// Hyprland 0.57+ reads only hyprland.lua. Older releases keep hyprland.conf
// (--symlinks): giving them the Lua entry would move 0.55/0.56 onto a config
// this repo has only verified on 0.57.
void do_hyprland_lua_entry(const Context& ctx) {
    std::string out;
    sh::capture({"Hyprland", "--version"}, out);
    const auto v = hypr_lua::parse_version(out);
    if (!hypr_lua::reads_lua_only(v)) {
        ui::skipped("hyprland.lua: Hyprland " + std::to_string(v.major) + "." + std::to_string(v.minor) +
                    " reads hyprland.conf");
        return;
    }
    if (deploy_file(ctx, ctx.script_dir / "shared/hyprland.lua", ctx.home / ".config/hypr/hyprland.lua"))
        ui::ok("hyprland.lua (Hyprland 0.57+ reads only Lua)");
}

// Hyprland modules — same shape as bulk dir, in both formats (.conf for 0.56
// and older, .lua for 0.57+). Skip theme/nvidia (managed by render + nvidia
// modules) and keep an existing monitors file (don't clobber user layout).
void do_hyprland_modules(const Context& ctx) {
    fs::path src_root = ctx.script_dir / "shared/hyprland_modules";
    fs::path dst_root = ctx.home       / ".config/hypr/modules";
    std::error_code ec;
    if (!fs::is_directory(src_root, ec)) return;
    fs::create_directories(dst_root);

    std::size_t done = 0;
    for (auto& e : fs::directory_iterator(src_root, ec)) {
        if (!e.is_regular_file()) continue;
        const std::string ext = e.path().extension().string();
        if (ext != ".conf" && ext != ".lua") continue;
        const std::string name = e.path().filename().string();
        const std::string stem = e.path().stem().string();
        if (stem == "theme" || stem == "nvidia") continue;
        if (name == "monitors.lua") continue;                      // derived below
        if (name == "monitors.conf" && fs::exists(dst_root / "monitors.conf")) continue;
        if (deploy_file(ctx, e.path(), dst_root / name)) ++done;
    }
    if (done > 0) ui::ok("hyprland modules: " + std::to_string(done) + " file(s)");

    // hyprland.conf sources modules/nvidia.conf everywhere; without NVIDIA nothing wrote it (nvidia_modules.hpp).
    const fs::path nv = dst_root / "nvidia.conf";
    if (fs::symlink_status(nv, ec).type() == fs::file_type::not_found) {
        if (ensure_nvidia_conf_placeholder(nv)) ui::substep("hypr/modules/nvidia.conf: comment-only (no NVIDIA setup)");
    }
    // hyprland.lua requires both on every machine.
    lua_twin(dst_root / "monitors.conf", dst_root / "monitors.lua",
             hypr_lua::read_text(src_root / "monitors.lua"));
    lua_twin(nv, dst_root / "nvidia.lua", hypr_lua::nvidia_lua_placeholder());

    do_hyprland_lua_entry(ctx);
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
    deploy_file(ctx, ctx.rendered_dir / "regreet/regreet.toml",
                stage / "regreet.toml");
    deploy_file(ctx, ctx.script_dir / "shared/greetd_hyprland.conf",
                stage / "hyprland.conf");
    deploy_file(ctx, ctx.script_dir / "shared/greetd_hyprland.lua",
                stage / "hyprland.lua");
    fs::path launcher_dst = stage / "start-greeter.sh";
    if (deploy_file(ctx, ctx.script_dir / "shared/greetd_start.sh", launcher_dst)) chmod_exec(launcher_dst);
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

    // One-time migration: fox-pulse subsumes the legacy bash watchers
    // (fox-monitor-watch + focus-pulse) in a single epoll daemon. On a box
    // that ran an older install, fox-monitor-watch.service may still be
    // enabled+running and its script still on disk — disable+stop it and
    // remove the stale script so we don't run both. Idempotent: no-ops when
    // the unit/script are already gone.
    sh::run({"systemctl", "--user", "disable", "--now", "fox-monitor-watch.service"});
    {
        fs::path stale = ctx.home / ".config/hypr/scripts/fox-monitor-watch.sh";
        std::error_code rec;
        if (fs::exists(stale, rec)) {
            fs::remove(stale, rec);
            ui::substep("removed stale fox-monitor-watch.sh (superseded by fox-pulse)");
        }
    }

    // Auto-enable core daemons. fox-pulse replaces fox-monitor-watch;
    // foxml-focus-pulse stays for the workspace-switch OSD.
    for (const char* svc : { "fox-pulse.service", "foxml-focus-pulse.service" }) {
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
        ui::substep("wallpaper mode: static");
    }
}

}  // namespace

void run_specials(Context& ctx) {
    ui::section("Special configs");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would: Firefox CSS+user.js, Vimium via /etc/firefox/policies (sudo, merged), Cursor/VS Code theme, "
                    "Bat cache rebuild, Claude settings jq-merge, "
                    "hyprland_scripts + waybar_scripts + hyprland_modules (.conf + .lua) + wallpapers + bin deploy, "
                    "hyprland.lua when Hyprland >= 0.57, "
                    "KEYBINDS.md to ~/.local/share/foxml/, systemd user units");
        return;
    }

    // Read before do_hyprland_modules resets autostart.conf; a theme refresh must not turn rotation off.
    keep_live_wallpaper_mode(ctx);

    do_firefox_addons(ctx);  // before do_firefox, whose restart is when Firefox reads the policy
    do_firefox(ctx);
    do_cursor_vscode(ctx);
    do_bat_config(ctx);
    do_bat_cache();
    do_git_delta(ctx);
    do_claude_hooks(ctx);

    // fox-monitor-watch.sh has been replaced by fox-pulse + the
    // `fox-install --only monitors,personalize` handler — skip it so
    // the deployed runtime no longer depends on mappings.sh.
    // Both are legacy standalone daemons superseded by fox-pulse. Deploying
    // focus-pulse.sh is actively harmful: fox-pulse prefers
    // ~/.config/foxml/pulse.d/<handler>.sh and falls back to spawning the
    // legacy script per event -- and focus-pulse.sh is a socat loop that never
    // exits, so every focus event leaked another permanent listener and each
    // listener then fired on every later event.
    static const char* HYPR_SKIPS[] = { "fox-monitor-watch.sh",
                                        "focus-pulse.sh", nullptr };

    static const BulkSpec BULK[] = {
        { "shared/bin",              ".local/bin",             "",    true,  "bin tools",        nullptr,    true  },
        { "shared/hyprland_scripts", ".config/hypr/scripts",   ".sh", true,  "hyprland scripts", HYPR_SKIPS, false },
        { "shared/waybar_scripts",   ".config/waybar/scripts", ".sh", true,  "waybar scripts",   nullptr,    false },
        { "shared/wallpapers",       ".wallpapers",            "",    false, "wallpapers",       nullptr,    false },
        { "shared/pulse.d",          ".config/foxml/pulse.d",  ".sh", true,  "pulse handlers",   nullptr,    false },
    };
    for (auto& s : BULK) deploy_dir_files(ctx, s);
    seed_theme_wallpaper(ctx);

    do_hyprland_modules(ctx);
    do_wallpaper_mode(ctx);
    do_keybinds_md(ctx);
    do_regreet_stage(ctx);
    do_btop_theme(ctx);
    do_systemd_user(ctx);
}

}  // namespace fox_install
