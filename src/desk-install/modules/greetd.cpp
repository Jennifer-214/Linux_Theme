// modules/greetd.cpp — themed regreet login screen deploy.
//
// Mirrors mappings.sh::install_greetd. Reads staged files from
// ~/.config/regreet/ (placed there by `specials.cpp`'s ReGreet block),
// copies them to /etc/greetd/ with the right perms, deploys the login
// wallpaper, and points /etc/greetd/config.toml at start-greeter.sh when it's
// still stock or holds a command this installer wrote before. The launcher
// starts Hyprland with hyprland.lua (0.57+) or hyprland.conf (older), picked
// at every boot, so a Hyprland upgrade can't strand the login screen.
//
// Requires greetd-regreet to be installed via --deps first.

#include "../core/context.hpp"
#include "hypr_lua.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool pacman_has(const std::string& pkg) {
    return sh::run({"sh", "-c", "pacman -Qi " + pkg + " &>/dev/null"}) == 0;
}

// Read the wallpaper path out of regreet.toml's `path = "..."` line.
std::string read_wallpaper_path(const fs::path& toml) {
    std::ifstream f(toml);
    std::string line;
    std::regex pat(R"PAT(^path\s*=\s*"([^"]+)")PAT");
    while (std::getline(f, line)) {
        std::smatch m;
        if (std::regex_search(line, m, pat)) return m[1];
    }
    return "/usr/share/wallpapers/foxml_earthy.jpg";
}

// The wallpaper actually on the desktop. desk-wallpaper --set and
// rotate_wallpaper both persist the pick as a BARE filename in this symlink.
std::string current_wallpaper_name(const fs::path& home) {
    fs::path link = home / ".wallpapers/.current";
    std::error_code ec;
    if (!fs::is_symlink(link, ec)) return {};
    fs::path target = fs::read_symlink(link, ec);
    if (ec) return {};
    return target.filename().string();
}

// Rewrite regreet.toml's `path = "..."` so it names the file we actually
// installed. Line-wise on purpose -- no multiline-regex portability bet.
std::string retarget_wallpaper(const fs::path& toml, const std::string& newpath) {
    std::ifstream f(toml);
    std::regex pat(R"PAT(^path\s*=\s*"[^"]+")PAT");
    std::ostringstream out;
    std::string line;
    while (std::getline(f, line)) {
        if (std::regex_search(line, pat)) out << "path = \"" << newpath << "\"\n";
        else                              out << line << "\n";
    }
    return out.str();
}

constexpr const char* CONFIG_TOML_BODY =
    "[terminal]\n"
    "vt = 1\n"
    "[default_session]\n"
    "command = \"/etc/greetd/start-greeter.sh\"\n"
    "user = \"greeter\"\n";

bool write_root_file(const fs::path& src, const fs::path& dst,
                     const std::string& mode) {
    int rc = sh::run({"sudo", "install", "-d", dst.parent_path().string()});
    if (rc != 0) return false;
    rc = sh::run({"sudo", "install", "-m", mode, src.string(), dst.string()});
    return rc == 0;
}

bool write_root_inline(const fs::path& dst, const std::string& body) {
    return sh::write_root_atomic(dst, body);
}

// The config the launcher will pick must parse with the installed Hyprland
// before greetd is pointed at it. Always pass -c: without it, 0.57's
// verify-config writes a stock ~/.config/hypr/hyprland.lua.
bool greeter_config_parses(const fs::path& staged) {
    const bool have = sh::have("Hyprland");
    fs::path cfg;
    std::string res;
    if (have) {
        std::string out;
        sh::capture({"Hyprland", "--version"}, out);
        const bool lua = hypr_lua::reads_lua_only(hypr_lua::parse_version(out));
        cfg = staged / (lua ? "hyprland.lua" : "hyprland.conf");
        sh::capture({"Hyprland", "--verify-config", "-c", cfg.string()}, res);
    }
    if (hypr_lua::greeter_config_ok(have, res)) return true;
    if (!have) {
        ui::warn("Hyprland is not installed, so the login screen has nothing to run on");
        return false;
    }
    ui::warn("greeter config " + cfg.string() + " does not parse with the installed Hyprland:");
    ui::substep(res.substr(res.find("parsing result") == std::string::npos ? 0 : res.find("parsing result")));
    return false;
}

constexpr const char* GREETER_DIR    = "/etc/greetd";
constexpr const char* GREETER_BACKUP = "/etc/greetd.foxml-bak";

// One generation of the whole directory, so a failed update can put back the login screen that worked.
bool backup_greeter() {
    if (!fs::is_directory(GREETER_DIR)) return true;
    sh::run({"sudo", "rm", "-rf", GREETER_BACKUP});
    return sh::run({"sudo", "cp", "-a", "-T", GREETER_DIR, GREETER_BACKUP}) == 0;
}

bool restore_greeter() {
    return fs::is_directory(GREETER_BACKUP) &&
           sh::run({"sudo", "cp", "-a", "-T", GREETER_BACKUP, GREETER_DIR}) == 0;
}

// Only a new machine: an existing file holds the user's own last choice.
void seed_regreet_state() {
    const fs::path state = "/var/lib/regreet/state.toml";
    const char* user = std::getenv("USER");
    if (!user || !*user || fs::exists(state)) return;
    const bool seeded =
        sh::run({"sudo", "install", "-d", "-m", "755", "-o", "greeter", "-g", "greeter", state.parent_path().string()}) == 0 &&
        write_root_inline(state, hypr_lua::regreet_state_body(user)) &&
        sh::run({"sudo", "chown", "greeter:greeter", state.string()}) == 0;
    if (seeded) ui::ok("first login defaults to the Hyprland session");
    else        ui::warn("could not set the first-login session — pick Hyprland on the login screen");
}

}  // namespace

void run_greetd(Context& ctx) {
    ui::section("greetd + regreet themed login screen");

    // Theme swaps deploy the greeter's LOOK only. /etc/greetd/config.toml
    // decides whether login works at all, so a recolour must never rewrite it
    // -- not even via the ctx.force_reapply branch below, which swap.sh's
    // --full would otherwise trigger on every swap. Set by swap.sh.
    const bool theme_only = std::getenv("FOXML_THEME_ONLY") != nullptr;

    if (!pacman_has("greetd-regreet")) {
        ui::ok("greetd-regreet not installed, skipping login-screen setup");
        return;
    }

    // Every failure below leaves the login screen on the previous theme.
    auto incomplete = [&](const std::string& why) {
        ctx.deploy_failed = true;
        ui::err(why);
    };
    if (ctx.render_ran && !ctx.render_ok) {
        incomplete("render failed; refusing to install a partial login screen");
        return;
    }
    // A dry run stages nothing, so the checks below would report a healthy box as failed.
    if (sh::dry_run()) {
        if (theme_only) {
            ui::substep("[dry-run] would install regreet css/toml, hyprland.conf + "
                        "hyprland.lua, start-greeter.sh + wallpaper to /etc/greetd/; "
                        "config.toml and greetd service state left untouched (theme-only)");
        } else {
            ui::substep("[dry-run] would install regreet files, hyprland.conf + "
                        "hyprland.lua, start-greeter.sh + wallpaper to /etc/greetd/, "
                        "point /etc/greetd/config.toml at start-greeter.sh if stock "
                        "or installer-written, enable greetd");
        }
        return;
    }

    fs::path staged = ctx.config_home / "regreet";
    for (const char* needed : { "regreet.css", "regreet.toml", "hyprland.conf",
                                 "hyprland.lua", "select-monitor.sh", "start-greeter.sh" }) {
        if (!fs::exists(staged / needed)) {
            incomplete("staged regreet file missing: " + (staged / needed).string() +
                       " (run --specials first to stage)");
            return;
        }
    }

    fs::path wall_path = read_wallpaper_path(staged / "regreet.toml");
    std::string wall_name = fs::path(wall_path).filename().string();

    // Prefer whatever is actually on the desktop, so the login screen matches
    // what the user is looking at instead of snapping back to the palette's
    // {{WALLPAPER}} the moment they run `desk-wallpaper --set`. Falls back to
    // the rendered theme default when .current is unset or dangling.
    std::string live = current_wallpaper_name(ctx.home);
    if (!live.empty() && fs::exists(ctx.home / ".wallpapers" / live)) {
        wall_name = live;
        wall_path = fs::path("/usr/share/wallpapers") / live;
    }

    fs::path wall_src = ctx.home / ".wallpapers" / wall_name;

    if (!fs::exists(wall_src)) {
        incomplete("login wallpaper " + wall_src.string() +
                   " missing — copy your wallpaper to ~/.wallpapers/ first");
        return;
    }

    // Checked before anything is replaced: a config that won't parse must not reach a working login screen.
    if (!greeter_config_parses(staged)) {
        incomplete("login screen left as it was — fix the problem above, then re-run --greetd");
        return;
    }
    if (!sh::sudo_warmup()) {
        incomplete("sudo cache cold — `sudo -v` first");
        return;
    }
    if (!backup_greeter()) {
        incomplete("could not back up /etc/greetd — login screen left as it was");
        return;
    }

    bool installed = write_root_file(staged / "regreet.css", "/etc/greetd/regreet.css", "644");
    installed = write_root_inline("/etc/greetd/regreet.toml",
                                  retarget_wallpaper(staged / "regreet.toml", wall_path.string())) && installed;
    installed = write_root_file(staged / "hyprland.conf",     "/etc/greetd/hyprland.conf",     "644") && installed;
    installed = write_root_file(staged / "hyprland.lua",      "/etc/greetd/hyprland.lua",      "644") && installed;
    installed = write_root_file(staged / "select-monitor.sh", "/etc/greetd/select-monitor.sh", "755") && installed;
    installed = write_root_file(staged / "start-greeter.sh",  hypr_lua::GREETER_LAUNCHER,      "755") && installed;
    installed = write_root_file(wall_src,                     wall_path,                       "644") && installed;
    if (!installed) {
        incomplete(restore_greeter()
            ? "login screen files could not be installed — restored the previous ones"
            : "login screen files could not be installed, and the backup was not restored — check /etc/greetd");
        return;
    }
    ui::ok("regreet css/toml, hyprland.conf + hyprland.lua → /etc/greetd/");
    ui::ok("greeter launcher → " + std::string(hypr_lua::GREETER_LAUNCHER));
    ui::ok("monitor selector → /etc/greetd/select-monitor.sh");
    ui::ok("login wallpaper → " + wall_path.string());

    if (theme_only) {
        ui::skipped("/etc/greetd/config.toml untouched (theme-only swap)");
        ui::skipped("greetd service state untouched (theme-only swap)");
        return;
    }

    fs::path cfg = "/etc/greetd/config.toml";
    const bool exists = fs::exists(cfg);
    std::string current;
    if (exists) sh::capture({"sudo", "cat", cfg.string()}, current);
    auto action = hypr_lua::greeter_toml_action(current, exists);
    if (ctx.force_reapply && action == hypr_lua::GreeterToml::Keep) action = hypr_lua::GreeterToml::Write;
    if (action == hypr_lua::GreeterToml::AlreadyLauncher) {
        ui::skipped("/etc/greetd/config.toml already starts the greeter launcher");
    } else if (action == hypr_lua::GreeterToml::Keep) {
        ui::skipped("/etc/greetd/config.toml already customized — leaving as-is");
    } else if (write_root_inline(cfg, CONFIG_TOML_BODY)) {
        ui::ok("/etc/greetd/config.toml → start-greeter.sh (Hyprland greeter session)");
    } else {
        incomplete(restore_greeter()
            ? "/etc/greetd/config.toml could not be written — restored the previous login screen"
            : "/etc/greetd/config.toml could not be written, and the backup was not restored — check /etc/greetd");
        return;
    }

    if (sh::run({"systemctl", "is-enabled", "--quiet", "greetd"}) != 0) {
        if (sh::run({"sudo", "systemctl", "enable", "greetd"}) == 0) {
            ui::ok("greetd enabled (login screen on next boot)");
        } else {
            incomplete("could not enable greetd — is another display manager enabled?");
        }
    } else {
        ui::skipped("greetd already enabled");
    }
    seed_regreet_state();
}

}  // namespace fox_install
