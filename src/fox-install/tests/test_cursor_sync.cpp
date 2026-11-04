#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>

namespace fs = std::filesystem;
namespace fox_install { void run_catppuccin_cursor(Context&); }

std::string read(const fs::path& path) {
    std::ifstream input(path);
    return {std::istreambuf_iterator<char>(input), {}};
}

// A single opaque pixel in the base set's fill.
std::string one_pixel_cursor() {
    auto u32 = [](uint32_t v) { return std::string(reinterpret_cast<const char*>(&v), 4); };
    return "Xcur" + u32(16) + u32(0x10000) + u32(1) + u32(0xfffd0002) + u32(24) + u32(28) +
           u32(36) + u32(0xfffd0002) + u32(24) + u32(1) + u32(1) + u32(1) + u32(0) + u32(0) + u32(0) +
           std::string("\xe7\xc2\xf5\xff", 4);
}

int main() {
    // /tmp can be mounted noexec on machines using FoxML's hardening module.
    std::string pattern = (fs::current_path() / ".fox-cursor-sync-XXXXXX").string();
    const char* temp = ::mkdtemp(pattern.data());
    if (!temp) return 1;
    const fs::path root(temp);
    fox_install::Context ctx;
    ctx.home = root / "home";
    ctx.backup_dir = root / "backup";
    ctx.palette_path = root / "palette.sh";
    const std::string theme = "catppuccin-mocha-pink-cursors";
    fs::create_directories(ctx.home / ".local/share/icons" / theme);
    fs::create_directories(root / "bin");
    std::ofstream(ctx.palette_path) << "CURSOR_THEME=" << theme << '\n';
    std::ofstream(root / "bin/gsettings") << "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FOXML_CURSOR_CALLS\"\n";
    fs::permissions(root / "bin/gsettings", fs::perms::owner_all);
    const std::string old_path = std::getenv("PATH") ? std::getenv("PATH") : "";
    ::setenv("PATH", (root / "bin").c_str(), 1);
    ::setenv("FOXML_CURSOR_CALLS", (root / "calls").c_str(), 1);
    int failures = 0;
    auto expect = [&](bool ok, const char* why) {
        if (!ok) { std::cerr << "FAIL: " << why << '\n'; ++failures; }
    };
    expect(fox_install::sh::have("gsettings"), "fixture settings command is executable");
    const auto fallback = ctx.home / ".icons/default/index.theme";
    fs::create_directories(fallback.parent_path());
    std::ofstream(fallback) << "[Icon Theme]\nInherits=Adwaita\n";
    fox_install::sh::set_dry_run(true);
    fox_install::run_catppuccin_cursor(ctx);
    fox_install::sh::set_dry_run(false);
    expect(!fs::exists(root / "calls"), "dry run does not change desktop preferences");
    expect(read(fallback).find("Adwaita") != std::string::npos, "dry run preserves fallback");
    fox_install::run_catppuccin_cursor(ctx);
    const std::string expected = "[Icon Theme]\nInherits=" + theme + '\n';
    expect(read(fallback) == expected, "installed assets still synchronize the legacy fallback");
    expect(read(ctx.home / ".local/share/icons/default/index.theme") == expected,
           "installed assets synchronize the data-directory fallback");
    expect(read(ctx.backup_dir / ".icons/default/index.theme").find("Adwaita") != std::string::npos,
           "old fallback is backed up before replacement");
    expect(read(root / "calls").find("cursor-theme " + theme) != std::string::npos,
           "installed assets still synchronize desktop preferences");
    fox_install::run_catppuccin_cursor(ctx);
    expect(read(fallback) == expected, "repeat installation preserves the chosen theme");
    expect(read(ctx.backup_dir / ".icons/default/index.theme").find("Adwaita") != std::string::npos,
           "repeat installation keeps the original backup");

    // A palette recolor builds its own set from the base and selects that set.
    const std::string derived = "derived-test-cursors", base = "base-test-cursors";
    const auto base_dir = ctx.home / ".local/share/icons" / base;
    const auto derived_dir = ctx.home / ".local/share/icons" / derived;
    fs::create_directories(base_dir / "cursors");
    std::ofstream(base_dir / "cursors/default", std::ios::binary) << one_pixel_cursor();
    std::ofstream(ctx.palette_path) << "CURSOR_THEME=" << derived << "\nCURSOR_RECOLOR=" << base
                                    << ":f5c2e7:1e1e2e:edb0c4:3c3c40\n";
    fox_install::sh::set_dry_run(true);
    fox_install::run_catppuccin_cursor(ctx);
    fox_install::sh::set_dry_run(false);
    expect(!fs::exists(derived_dir), "dry run builds nothing");
    fox_install::run_catppuccin_cursor(ctx);
    const std::string built = read(derived_dir / "cursors/default");
    expect(built.size() == one_pixel_cursor().size() && built.compare(built.size() - 4, 3, "\xc4\xb0\xed") == 0,
           "the derived set carries the palette's fill");
    expect(read(root / "calls").find("cursor-theme " + derived) != std::string::npos,
           "the derived set, not its base, is selected");
    expect(read(fallback) == "[Icon Theme]\nInherits=" + derived + '\n', "the fallback names the derived set");
    fs::remove_all(base_dir);
    fox_install::run_catppuccin_cursor(ctx);
    expect(fs::exists(derived_dir / "cursors/default"), "an up-to-date set needs no base to survive a re-run");

    ::setenv("PATH", old_path.c_str(), 1);
    ::unsetenv("FOXML_CURSOR_CALLS");
    fs::remove_all(root);
    if (!failures) std::cout << "cursor preference synchronization: OK\n";
    return failures ? 1 : 0;
}
