// modules/greetd.cpp — themed regreet login screen deploy.
//
// Mirrors mappings.sh::install_greetd. Reads staged files from
// ~/.config/regreet/ (placed there by `specials.cpp`'s ReGreet block),
// copies them to /etc/greetd/ with the right perms, deploys the login
// wallpaper, and writes /etc/greetd/config.toml only if it's still the
// stock agreety default.
//
// Requires greetd-regreet to be installed via --deps first.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

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

// The wallpaper actually on the desktop. fox-wallpaper --set and
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
    "command = \"Hyprland -c /etc/greetd/hyprland.conf\"\n"
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

    fs::path staged = ctx.config_home / "regreet";
    for (const char* needed : { "regreet.css", "regreet.toml",
                                 "hyprland.conf", "select-monitor.sh" }) {
        if (!fs::exists(staged / needed)) {
            ui::ok("staged regreet file missing: " + (staged / needed).string() +
                   " (run --specials first to stage)");
            return;
        }
    }

    fs::path wall_path = read_wallpaper_path(staged / "regreet.toml");
    std::string wall_name = fs::path(wall_path).filename().string();

    // Prefer whatever is actually on the desktop, so the login screen matches
    // what the user is looking at instead of snapping back to the palette's
    // {{WALLPAPER}} the moment they run `fox-wallpaper --set`. Falls back to
    // the rendered theme default when .current is unset or dangling.
    std::string live = current_wallpaper_name(ctx.home);
    if (!live.empty() && fs::exists(ctx.home / ".wallpapers" / live)) {
        wall_name = live;
        wall_path = fs::path("/usr/share/wallpapers") / live;
    }

    fs::path wall_src = ctx.home / ".wallpapers" / wall_name;

    if (!fs::exists(wall_src)) {
        ui::warn("login wallpaper " + wall_src.string() +
                 " missing — copy your wallpaper to ~/.wallpapers/ first");
        return;
    }

    if (sh::dry_run()) {
        if (theme_only) {
            ui::substep("[dry-run] would install regreet css/toml/hyprland.conf "
                        "+ wallpaper to /etc/greetd/; config.toml and greetd "
                        "service state left untouched (theme-only)");
        } else {
            ui::substep("[dry-run] would install regreet files + wallpaper to "
                        "/etc/greetd/, write /etc/greetd/config.toml if stock, "
                        "enable greetd");
        }
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    write_root_file(staged / "regreet.css",       "/etc/greetd/regreet.css",      "644");
    write_root_inline("/etc/greetd/regreet.toml",
                      retarget_wallpaper(staged / "regreet.toml", wall_path.string()));
    write_root_file(staged / "hyprland.conf",     "/etc/greetd/hyprland.conf",    "644");
    write_root_file(staged / "select-monitor.sh", "/etc/greetd/select-monitor.sh","755");
    write_root_file(wall_src,                     wall_path,                       "644");
    ui::ok("regreet css/toml/hyprland.conf → /etc/greetd/");
    ui::ok("monitor selector → /etc/greetd/select-monitor.sh");
    ui::ok("login wallpaper → " + wall_path.string());

    if (theme_only) {
        ui::skipped("/etc/greetd/config.toml untouched (theme-only swap)");
        ui::skipped("greetd service state untouched (theme-only swap)");
        return;
    }

    fs::path cfg = "/etc/greetd/config.toml";
    bool stock = !fs::exists(cfg) ||
                  sh::run({"sh", "-c",
                           "sudo grep -qE '^command = \"agreety' /etc/greetd/config.toml"}) == 0;
    if (stock || ctx.force_reapply) {
        if (write_root_inline(cfg, CONFIG_TOML_BODY)) {
            ui::ok("/etc/greetd/config.toml (Hyprland greeter session)");
        }
    } else {
        ui::skipped("/etc/greetd/config.toml already customized — leaving as-is");
    }

    if (sh::run({"systemctl", "is-enabled", "--quiet", "greetd"}) != 0) {
        if (sh::run({"sudo", "systemctl", "enable", "greetd"}) == 0) {
            ui::ok("greetd enabled (login screen on next boot)");
        }
    } else {
        ui::skipped("greetd already enabled");
    }
}

}  // namespace fox_install
