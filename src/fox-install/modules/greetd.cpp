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

#include <filesystem>
#include <fstream>
#include <regex>
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
    fs::path tmp = "/tmp/foxin-greetd.tmp";
    {
        std::ofstream o(tmp);
        o << body;
    }
    int rc = sh::run({"sudo", "install", "-d", dst.parent_path().string()});
    if (rc != 0) { fs::remove(tmp); return false; }
    rc = sh::run({"sudo", "install", "-m", "0644", "-o", "root", "-g", "root",
                  tmp.string(), dst.string()});
    fs::remove(tmp);
    return rc == 0;
}

}  // namespace

void run_greetd(Context& ctx) {
    ui::section("greetd + regreet themed login screen");

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
    fs::path wall_src = ctx.home / ".wallpapers" / wall_name;

    if (!fs::exists(wall_src)) {
        ui::warn("login wallpaper " + wall_src.string() +
                 " missing — copy your wallpaper to ~/.wallpapers/ first");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would install regreet files + wallpaper to "
                    "/etc/greetd/, write /etc/greetd/config.toml if stock, "
                    "enable greetd");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    write_root_file(staged / "regreet.css",       "/etc/greetd/regreet.css",      "644");
    write_root_file(staged / "regreet.toml",      "/etc/greetd/regreet.toml",     "644");
    write_root_file(staged / "hyprland.conf",     "/etc/greetd/hyprland.conf",    "644");
    write_root_file(staged / "select-monitor.sh", "/etc/greetd/select-monitor.sh","755");
    write_root_file(wall_src,                     wall_path,                       "644");
    ui::ok("regreet css/toml/hyprland.conf → /etc/greetd/");
    ui::ok("monitor selector → /etc/greetd/select-monitor.sh");
    ui::ok("login wallpaper → " + wall_path.string());

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
