// modules/papirus_icons.cpp — Papirus-Dark with Catppuccin Mocha Peach folders.
//
// Icon theme — Papirus-Dark with Catppuccin Mocha Peach folders. The
// GTK ini already references Papirus-Dark; this fetches the theme
// user-locally (no sudo) and recolors folders to match the cursor.
//
// Mirrors mappings.sh::install_specials icon/folder section (~487–596).

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) {
    std::string out;
    return sh::capture({"sh", "-c", "command -v " + bin}, out) && !out.empty();
}

bool pacman_has(const std::string& pkg) {
    return sh::run({"sh", "-c", "pacman -Qi " + pkg + " &>/dev/null"}) == 0;
}

}  // namespace

void run_papirus_icons(Context& ctx) {
    ui::section("Papirus icon theme + Catppuccin folder palette");

    fs::path user_icons = ctx.home / ".local/share/icons";
    fs::path sys_icons  = "/usr/share/icons";
    fs::path papirus_root = "";

    if (fs::is_directory(sys_icons / "Papirus")) {
        papirus_root = sys_icons;
    } else if (fs::is_directory(user_icons / "Papirus")) {
        papirus_root = user_icons;
    }

    if (papirus_root.empty() && !pacman_has("papirus-icon-theme")) {
        if (sh::dry_run()) {
            ui::substep("[dry-run] would install papirus-icon-theme via AUR or upstream script");
        } else {
            bool done = false;
            for (const char* aur : { "yay", "paru" }) {
                if (have(aur)) {
                    if (sh::run({aur, "-S", "--needed", "--noconfirm", "papirus-icon-theme"}) == 0) {
                        ui::ok("Papirus icon theme installed via " + std::string(aur));
                        papirus_root = sys_icons;
                        done = true;
                        break;
                    }
                }
            }
            if (!done) {
                ui::substep("installing Papirus via upstream script (no AUR helper)");
                if (sh::run({"sh", "-c",
                             "curl -fsSL https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-icon-theme/master/install.sh | "
                             "DESTDIR=" + user_icons.string() + " sh"}) == 0) {
                    ui::ok("Papirus icon theme installed to " + user_icons.string());
                    papirus_root = user_icons;
                } else {
                    ui::warn("Papirus install failed; skipping folder recolor");
                    return;
                }
            }
        }
    } else {
        ui::skipped("Papirus already present" + (papirus_root.empty() ? "" : " at " + papirus_root.string()));
        if (papirus_root.empty()) papirus_root = sys_icons;
    }

    if (papirus_root.empty() || !fs::is_directory(papirus_root / "Papirus")) return;

    // Catppuccin folder injection
    fs::path cat_marker = (papirus_root == sys_icons)
        ? papirus_root / ".foxml-catppuccin-injected"
        : ctx.config_home / "foxml/catppuccin-papirus-injected.marker";

    if (fs::exists(cat_marker) && !ctx.force_reapply) {
        ui::skipped("Catppuccin folder palette already injected");
    } else {
        if (sh::dry_run()) {
            ui::substep("[dry-run] would inject Catppuccin folder palette into " + papirus_root.string());
        } else {
            ui::substep("injecting Catppuccin folder palette");
            fs::path tmp = "/tmp/foxin-papirus-cat";
            fs::remove_all(tmp);
            if (sh::run({"git", "clone", "--depth", "1", "--quiet",
                         "https://github.com/catppuccin/papirus-folders.git", tmp.string()}) == 0) {
                // We need sudo to write to /usr/share/icons
                std::string cmd = "cp -r " + (tmp / "src").string() + "/* " + (papirus_root / "Papirus").string();
                if (papirus_root == sys_icons) {
                    sh::run({"sudo", "sh", "-c", cmd});
                    sh::run({"sudo", "touch", cat_marker.string()});
                } else {
                    sh::run({"sh", "-c", cmd});
                    fs::create_directories(cat_marker.parent_path());
                    std::ofstream(cat_marker) << "injected";
                }
                ui::ok("Catppuccin folder palette injected");
            }
            fs::remove_all(tmp);
        }
    }

    // Apply cat-mocha-peach folders
    fs::path pf_marker = ctx.config_home / "foxml/catppuccin-folders-applied.marker";
    if (fs::exists(pf_marker)) {
        ui::skipped("folders already cat-mocha-peach");
    } else {
        if (sh::dry_run()) {
            ui::substep("[dry-run] would run papirus-folders -C cat-mocha-peach");
        } else {
            std::string pf_cmd = "";
            if (have("papirus-folders")) {
                pf_cmd = "papirus-folders";
            } else {
                ui::substep("fetching papirus-folders script");
                sh::run({"curl", "-fsSL", "-o", "/tmp/pf",
                         "https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-folders/master/papirus-folders"});
                sh::run({"chmod", "+x", "/tmp/pf"});
                pf_cmd = "/tmp/pf";
            }

            if (!pf_cmd.empty()) {
                if (sh::run({pf_cmd, "-C", "cat-mocha-peach", "-t", "Papirus-Dark"}) == 0) {
                    ui::ok("folders → cat-mocha-peach");
                    fs::create_directories(pf_marker.parent_path());
                    std::ofstream(pf_marker) << "applied";
                }
                if (pf_cmd == "/tmp/pf") fs::remove("/tmp/pf");
            }
        }
    }

    if (have("gsettings")) {
        sh::run({"sh", "-c", "gsettings set org.gnome.desktop.interface icon-theme \"Papirus-Dark\" 2>/dev/null || true"});
    }
}

}  // namespace fox_install
