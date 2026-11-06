#include "../core/backup.hpp"
#include "../../fox-common/shell.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <cstdlib>
#include <unistd.h>

namespace fs = std::filesystem;
namespace fox_install { void run_drawer(Context&); }

std::string read(const fs::path& path) {
    std::ifstream f(path);
    return {std::istreambuf_iterator<char>(f), {}};
}

int main() {
    // The fixture executes fake build tools; /tmp is noexec on FoxML systems.
    std::string pattern = (fs::current_path() / ".fox-drawer-deploy-XXXXXX").string();
    const char* temp = ::mkdtemp(pattern.data());
    if (!temp) return 1;
    const fs::path root(temp);
    fox_install::Context ctx;
    ctx.home = root / "home";
    ctx.config_home = ctx.home / ".config";
    ctx.backup_dir = root / "backup";
    fs::create_directories(ctx.home);
    const auto source = root / "source";
    const auto dest = ctx.home / "program";
    std::ofstream(source) << "new\n";
    std::ofstream(dest) << "original\n";
    fs::permissions(source, fs::perms::owner_read | fs::perms::owner_write | fs::perms::owner_exec);
    int failures = 0;
    auto expect = [&](bool ok, const char* why) {
        if (!ok) { std::cerr << "FAIL: " << why << '\n'; ++failures; }
    };
    expect(fox_install::deploy_file_atomic(ctx, source, dest), "deploy succeeds");
    expect(read(dest) == "new\n", "new file is installed");
    expect(read(ctx.backup_dir / "program") == "original\n", "old file is backed up");
    expect((fs::status(dest).permissions() & fs::perms::owner_exec) != fs::perms::none,
           "executable permissions are preserved");
    expect(!fs::exists(dest.string() + ".foxin.tmp"), "temporary file is gone");
    std::ofstream(source) << "newer\n";
    expect(fox_install::deploy_file_atomic(ctx, source, dest), "repeat deployment succeeds");
    expect(read(ctx.backup_dir / "program") == "original\n", "first snapshot survives a second deploy");
    const auto protected_file = root / "protected";
    std::ofstream(protected_file) << "leave this alone\n";
    fs::create_symlink(protected_file, dest.string() + ".foxin.tmp");
    expect(fox_install::deploy_file_atomic(ctx, source, dest), "old predictable temporary path is ignored");
    expect(read(protected_file) == "leave this alone\n", "temporary symlink target is untouched");
    ctx.backup_dir = root / "blocked";
    std::ofstream(ctx.backup_dir) << "not a directory";
    std::ofstream(source) << "must not land\n";
    expect(!fox_install::deploy_file_atomic(ctx, source, dest), "backup failure refuses deployment");
    expect(read(dest) == "newer\n", "backup failure preserves installed file");
    fox_install::sh::set_dry_run(true);
    fox_install::run_drawer(ctx);
    fox_install::sh::set_dry_run(false);
    expect(!fs::exists(ctx.config_home), "drawer dry run creates no configuration");

    // Exercise the module with fake build tools and a temporary HOME; no live
    // desktop process, package manager, or notification bus is involved.
    const std::string original_path = std::getenv("PATH") ? std::getenv("PATH") : "";
    const bool had_wayland = std::getenv("WAYLAND_DISPLAY") != nullptr;
    const std::string original_wayland = had_wayland ? std::getenv("WAYLAND_DISPLAY") : "";
    ::unsetenv("WAYLAND_DISPLAY");
    ctx.script_dir = root / "repo";
    ctx.shared_dir = ctx.script_dir / "shared";
    ctx.templates_dir = ctx.script_dir / "templates";
    ctx.rendered_dir = root / "rendered";
    ctx.palette_path = ctx.script_dir / "palette.sh";
    ctx.backup_dir = root / "drawer-backup";
    auto put = [&](const fs::path& path, const std::string& body, bool executable = false) {
        fs::create_directories(path.parent_path());
        std::ofstream(path) << body;
        if (executable) fs::permissions(path, fs::perms::owner_read | fs::perms::owner_write | fs::perms::owner_exec);
    };
    put(root / "bin/make", "#!/bin/sh\ncase \"$2\" in */fox-mako) test \"${FOXML_TEST_MAKO_FAIL:-0}\" = 0;; *) exit 0;; esac\n", true);
    const std::string path = (root / "bin").string() + ":" + original_path;
    ::setenv("PATH", path.c_str(), 1);
    put(ctx.script_dir / "src/fox-drawer/fox-drawer", "new backend", true);
    put(ctx.script_dir / "src/fox-render/fox-render-fast",
        "#!/bin/sh\nmkdir -p \"$3\"\nprintf 'rendered palette\\n' > \"$3/Theme.qml\"\nprintf 'new pencil icon\\n' > \"$3/paper-icon.svg\"\n", true);
    put(ctx.script_dir / "src/fox-mako/Makefile", "all:\n");
    put(ctx.script_dir / "src/fox-mako/fox-mako", "new Mako", true);
    put(ctx.templates_dir / "waybar/drawer-state.css", "runtime default");
    for (const char* name : {"shell.qml", "BarBannerHint.qml", "PageEdgeScrollBar.qml", "MediaArtwork.qml", "StateTag.qml", "ScrapbookSheet.qml", "VolumeSlip.qml"})
        put(ctx.shared_dir / "quickshell/foxml" / name, std::string("new ") + name);
    put(ctx.shared_dir / "quickshell/foxml/menus.json", "new defaults");
    for (const char* name : {"fox-desktop-menu", "fox-bar", "fox-hl", "fox-picker", "fox-menu", "fox-cheatsheet", "fox-sandbox",
                            "fox-ai-quick", "fox-wallpaper", "fox-password-copy", "fox-notifications"})
        put(ctx.shared_dir / "bin" / name, std::string("new ") + name, true);
    for (const char* name : {"toggle_rofi.sh", "hub.sh", "network.sh", "bluetooth.sh", "audio_switcher.sh", "powermenu.sh",
                            "clipmanager.sh", "updates_menu.sh", "eww_action.sh", "start_waybar.sh", "startup.sh", "agent_rofi.sh", "panic.sh", "osd.sh", "screenshot.sh"})
        put(ctx.shared_dir / "hyprland_scripts" / name, "script", true);
    const fs::path service = "systemd/user/mako.service.d/50-foxml.conf";
    put(ctx.shared_dir / service, "new service override");
    put(ctx.home / ".local/bin/fox-mako", "old Mako", true);
    put(ctx.home / ".local/bin/fox-notifications", "old launcher", true);
    put(ctx.config_home / service, "old service override");
    put(ctx.config_home / "quickshell/foxml/menus.json", "my hierarchy");
    put(ctx.config_home / "quickshell/foxml/MediaArtwork.qml", "old artwork");
    put(ctx.config_home / "quickshell/foxml/paper-icon.svg", "old pencil icon");
    put(ctx.config_home / "waybar/drawer-state.css", "active runtime marker");
    fox_install::run_drawer(ctx);
    expect(read(ctx.home / ".local/bin/fox-mako") == "new Mako", "custom Mako is deployed");
    expect(read(ctx.backup_dir / ".local/bin/fox-mako") == "old Mako", "custom Mako is backed up");
    expect(read(ctx.backup_dir / ".local/bin/fox-notifications") == "old launcher", "notification launcher is backed up");
    expect(read(ctx.backup_dir / ".config" / service) == "old service override", "Mako service override is backed up");
    expect(read(ctx.config_home / service) == "new service override", "Mako service override is deployed");
    expect(read(ctx.config_home / "quickshell/foxml/menus.json") == "my hierarchy", "custom hierarchy is preserved");
    expect(read(ctx.config_home / "quickshell/foxml/menus.default.json") == "new defaults", "menu defaults are refreshed");
    expect(read(ctx.config_home / "quickshell/foxml/Theme.qml") == "rendered palette\n", "drawer palette is deployed");
    expect(read(ctx.config_home / "quickshell/foxml/paper-icon.svg") == "new pencil icon\n", "rendered drawer artwork is deployed");
    expect(read(ctx.backup_dir / ".config/quickshell/foxml/paper-icon.svg") == "old pencil icon", "rendered artwork is backed up before replacement");
    expect(read(ctx.config_home / "waybar/drawer-state.css") == "active runtime marker", "runtime bar marker is preserved");
    for (const char* name : {"BarBannerHint.qml", "PageEdgeScrollBar.qml", "MediaArtwork.qml", "StateTag.qml", "ScrapbookSheet.qml", "VolumeSlip.qml"})
        expect(read(ctx.config_home / "quickshell/foxml" / name) == std::string("new ") + name, "new QML component is deployed automatically");
    expect(read(ctx.backup_dir / ".config/quickshell/foxml/MediaArtwork.qml") == "old artwork", "QML component is backed up");
    ::setenv("FOXML_TEST_MAKO_FAIL", "1", 1);
    put(ctx.script_dir / "src/fox-mako/fox-mako", "must not deploy", true);
    put(ctx.shared_dir / "bin/fox-notifications", "must not deploy", true);
    put(ctx.shared_dir / service, "must not deploy");
    fox_install::run_drawer(ctx);
    expect(read(ctx.home / ".local/bin/fox-mako") == "new Mako", "failed build preserves installed custom Mako");
    expect(read(ctx.home / ".local/bin/fox-notifications") == "new fox-notifications", "failed build preserves notification launcher");
    expect(read(ctx.config_home / service) == "new service override", "failed build preserves service override");
    expect(read(ctx.backup_dir / ".local/bin/fox-mako") == "old Mako", "repeated deploy preserves the first backup");
    put(ctx.config_home / "quickshell/foxml/menus.json", R"({"favorites":["desk/custom"],"groups":[{"id":"desk","label":"My desk","items":[{"id":"custom","label":"Keep me"}]}]})");
    put(ctx.shared_dir / "quickshell/foxml/menus.json", R"({"groups":[{"id":"desk","items":[{"id":"screenshots","page":"screenshots","label":"Screenshot scrapbook","kind":"page"}]}]})");
    fox_install::run_drawer(ctx);
    const auto upgraded = read(ctx.config_home / "quickshell/foxml/menus.json");
    expect(upgraded.find("Keep me") != std::string::npos && upgraded.find("My desk") != std::string::npos
           && upgraded.find("desk/custom") != std::string::npos && upgraded.find("Screenshot scrapbook") != std::string::npos,
           "scrapbook migration preserves custom entries, titles and favorites");
    fox_install::run_drawer(ctx);
    expect(read(ctx.config_home / "quickshell/foxml/menus.json") == upgraded, "scrapbook migration is idempotent");
    expect(read(ctx.config_home / "hypr/scripts/osd.sh") == "script", "drawer installs the volume helper");
    expect(read(ctx.config_home / "hypr/scripts/screenshot.sh") == "script", "drawer installs the screenshot helper");
    ::unsetenv("FOXML_TEST_MAKO_FAIL");
    ::setenv("PATH", original_path.c_str(), 1);
    if (had_wayland) ::setenv("WAYLAND_DISPLAY", original_wayland.c_str(), 1);
    fs::remove_all(root);
    if (!failures) std::cout << "drawer deployment: OK\n";
    return failures ? 1 : 0;
}
