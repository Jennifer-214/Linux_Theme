// The desktop wallpaper after an install: the theme's own on a new machine and after a change of theme, the user's
// pick on a reinstall of the same theme. A Classic → Paper upgrade used to keep Classic's wallpaper (and login screen).
// The return value says whether to show the new one now.
#include "../modules/wallpaper_mode.hpp"

#include <cstdio>
#include <unistd.h>

namespace fs = std::filesystem;

static int failures = 0;
static void expect(const char* what, bool changed, bool want_changed, const fs::path& link, const char* want) {
    std::error_code ec;
    const std::string got = fs::is_symlink(link, ec) ? fs::read_symlink(link, ec).string() : "(none)";
    if (got == want && changed == want_changed) return;
    std::printf("FAIL %s: .current -> %s (changed %d), want %s (changed %d)\n", what, got.c_str(), changed, want,
                want_changed);
    ++failures;
}

int main() {
    char pattern[] = "/tmp/fox-wallpaper-seed-XXXXXX";
    if (!::mkdtemp(pattern)) return 1;
    const fs::path root(pattern), walls = root / "home/.wallpapers", link = walls / ".current";
    fs::create_directories(walls);
    fs::create_directories(root / "themes/Classic");
    fs::create_directories(root / "themes/Paper");
    std::ofstream(root / "themes/Classic/palette.sh") << "WALLPAPER=classic.jpg\n";
    std::ofstream(root / "themes/Paper/palette.sh") << "WALLPAPER=paper.png\n";
    for (const char* f : {"classic.jpg", "paper.png", "picked.jpg"}) std::ofstream(walls / f) << "x";

    desk_install::Context ctx;
    ctx.script_dir = root;
    ctx.home = root / "home";
    ctx.themes_dir = root / "themes";
    auto use = [&](const char* theme) {
        ctx.theme_name = theme;
        ctx.palette_path = root / "themes" / theme / "palette.sh";
    };
    auto finish_run = [&] { std::ofstream(root / ".active-theme") << ctx.theme_name << "\n"; };
    auto pick = [&](const char* file) {
        fs::remove(link);
        fs::create_symlink(file, link);
    };

    use("Classic");
    expect("new machine", desk_install::seed_theme_wallpaper(ctx), true, link, "classic.jpg");
    finish_run();

    pick("picked.jpg");
    expect("same theme keeps the pick", desk_install::seed_theme_wallpaper(ctx), false, link, "picked.jpg");
    finish_run();

    use("Paper");
    expect("theme change", desk_install::seed_theme_wallpaper(ctx), true, link, "paper.png");

    // The run stopped before it saved the theme; the next one finds the wallpaper already in place.
    expect("theme change already shown", desk_install::seed_theme_wallpaper(ctx), false, link, "paper.png");
    finish_run();

    // An install from before the rename saved the old name of the same theme, so the pick stays.
    pick("picked.jpg");
    std::ofstream(root / ".active-theme") << "FoxML_Paper\n";   // old-theme-name
    expect("old name of the same theme keeps the pick", desk_install::seed_theme_wallpaper(ctx), false, link,
           "picked.jpg");
    finish_run();

    pick("paper.png");
    use("Classic");
    fs::remove(walls / "classic.jpg");
    expect("theme change, its wallpaper missing: nothing removed", desk_install::seed_theme_wallpaper(ctx), false,
           link, "paper.png");

    fs::remove_all(root);
    if (failures == 0) std::printf("test_wallpaper_seed: ok\n");
    return failures == 0 ? 0 : 1;
}
