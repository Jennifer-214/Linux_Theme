#include "../modules/gtk_appearance.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>

namespace fs = std::filesystem;

int main() {
    std::string pattern = (fs::current_path() / ".fox-gtk-font-XXXXXX").string();
    const char* temp = ::mkdtemp(pattern.data());
    if (!temp) return 1;
    const fs::path root(temp);
    desk_install::Context ctx;
    ctx.config_home = root / "config";
    ctx.backup_dir = root / "backup";
    fs::create_directories(ctx.config_home / "gtk-3.0");
    fs::create_directories(root / "bin");
    std::ofstream(root / "bin/gsettings") <<
        "#!/bin/sh\n"
        "case $1 in\n"
        "get) printf '%s\\n' \"$FOXML_TEST_GTK_PREVIOUS\";;\n"
        "set) printf '%s\\n' \"$*\" >> \"$FOXML_TEST_GTK_CALLS\";;\n"
        "*) exit 1;;\nesac\n";
    fs::permissions(root / "bin/gsettings", fs::perms::owner_all);
    const std::string old_path = std::getenv("PATH") ? std::getenv("PATH") : "";
    ::setenv("PATH", (root / "bin").c_str(), 1);
    ::setenv("FOXML_TEST_GTK_PREVIOUS", "'Adwaita Sans 11'", 1);
    ::setenv("FOXML_TEST_GTK_CALLS", (root / "calls").c_str(), 1);
    int failures = 0;
    auto expect = [&](bool ok, const char* why) {
        if (!ok) { std::cerr << "FAIL: " << why << '\n'; ++failures; }
    };
    desk_install::sync_gtk_font(ctx);
    expect(!fs::exists(root / "calls"), "missing GTK settings leave preferences unchanged");
    const auto ini = ctx.config_home / "gtk-3.0/settings.ini";
    std::ofstream(ini) << "[Settings]\ngtk-font-name=MonaspiceKr Nerd Font 11.5\n"
                            "[Other]\ngtk-font-name=Wrong Font 12\n";
    desk_install::sh::set_dry_run(true);
    desk_install::sync_gtk_font(ctx);
    desk_install::sh::set_dry_run(false);
    expect(!fs::exists(root / "calls") && !fs::exists(ctx.backup_dir),
           "dry run changes neither desktop settings nor backups");
    desk_install::sync_gtk_font(ctx);
    const auto backup = ctx.backup_dir / "gsettings/org.gnome.desktop.interface.font-name";
    expect(desk_install::idem::read_file(root / "calls") ==
               "set org.gnome.desktop.interface font-name MonaspiceKr Nerd Font 11.5\n",
           "desktop override follows the deployed Settings section");
    expect(desk_install::idem::read_file(backup) == "'Adwaita Sans 11'\n",
           "original GVariant preference is preserved");
    const auto calls = desk_install::idem::read_file(root / "calls");
    ::setenv("FOXML_TEST_GTK_PREVIOUS", "'MonaspiceKr Nerd Font 11.5'", 1);
    desk_install::sync_gtk_font(ctx);
    expect(desk_install::idem::read_file(root / "calls") == calls,
           "matching desktop font does not trigger another settings notification");
    ::setenv("FOXML_TEST_GTK_PREVIOUS", "'Another Font 10'", 1);
    desk_install::sync_gtk_font(ctx);
    expect(desk_install::idem::read_file(backup) == "'Adwaita Sans 11'\n",
           "repeat runs keep the original backup");
    ctx.backup_dir = root / "blocked";
    std::ofstream(ctx.backup_dir) << "not a directory";
    const auto before_failure = desk_install::idem::read_file(root / "calls");
    desk_install::sync_gtk_font(ctx);
    expect(desk_install::idem::read_file(root / "calls") == before_failure,
           "backup failure prevents preference overwrite");
    ctx.backup_dir = root / "icon-backup";
    std::ofstream(ini) << "[Settings]\ngtk-icon-theme-name=FoxML-Paper\n";
    ::setenv("FOXML_TEST_GTK_PREVIOUS", "'Papirus-Light'", 1);
    desk_install::sync_gtk_icon_theme(ctx);
    expect(desk_install::idem::read_file(root / "calls").find(
               "set org.gnome.desktop.interface icon-theme FoxML-Paper\n") != std::string::npos,
           "desktop icon override follows the deployed Settings section");
    expect(desk_install::idem::read_file(ctx.backup_dir / "gsettings/org.gnome.desktop.interface.icon-theme") == "'Papirus-Light'\n",
           "original desktop icon preference is backed up");
    ctx.palette_path = root / "palette.sh";
    std::ofstream(ctx.palette_path) << "GTK_ACCENT_COLOR=pink\n";
    ::setenv("FOXML_TEST_GTK_PREVIOUS", "'blue'", 1);
    desk_install::sync_gtk_accent(ctx);
    expect(desk_install::idem::read_file(root / "calls").find(
               "set org.gnome.desktop.interface accent-color pink\n") != std::string::npos,
           "desktop accent follows the palette");
    expect(desk_install::idem::read_file(ctx.backup_dir / "gsettings/org.gnome.desktop.interface.accent-color") == "'blue'\n",
           "original desktop accent is backed up");
    const auto accent_calls = desk_install::idem::read_file(root / "calls");
    std::ofstream(ctx.palette_path) << "GTK_ACCENT_COLOR=e2a4ba\n";
    desk_install::sync_gtk_accent(ctx);
    std::ofstream(ctx.palette_path) << "THEME_TYPE=light\n";
    desk_install::sync_gtk_accent(ctx);
    expect(desk_install::idem::read_file(root / "calls") == accent_calls,
           "an unknown or missing accent name leaves the desktop accent alone");
    ::setenv("PATH", old_path.c_str(), 1);
    ::unsetenv("FOXML_TEST_GTK_PREVIOUS");
    ::unsetenv("FOXML_TEST_GTK_CALLS");
    fs::remove_all(root);
    if (!failures) std::cout << "GTK appearance synchronization: OK\n";
    return failures ? 1 : 0;
}
