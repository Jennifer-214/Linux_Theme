// The desktop wallpaper after an install: the theme's own on a new machine and after a change of theme, the user's
// pick on a reinstall of the same theme. A Classic → Paper upgrade used to keep Classic's wallpaper (and login screen).
#include "../modules/wallpaper_mode.hpp"

#include <cstdio>
#include <unistd.h>

namespace fs = std::filesystem;

static int failures = 0;
static void expect(const char* what, const fs::path& link, const char* want) {
    std::error_code ec;
    const std::string got = fs::is_symlink(link, ec) ? fs::read_symlink(link, ec).string() : "(none)";
    if (got == want) return;
    std::printf("FAIL %s: .current -> %s, want %s\n", what, got.c_str(), want);
    ++failures;
}

int main() {
    char pattern[] = "/tmp/fox-wallpaper-seed-XXXXXX";
    if (!::mkdtemp(pattern)) return 1;
    const fs::path root(pattern), walls = root / "home/.wallpapers", link = walls / ".current";
    fs::create_directories(walls);
    fs::create_directories(root / "themes/FoxML_Classic");
    fs::create_directories(root / "themes/FoxML_Paper");
    std::ofstream(root / "themes/FoxML_Classic/palette.sh") << "WALLPAPER=classic.jpg\n";
    std::ofstream(root / "themes/FoxML_Paper/palette.sh") << "WALLPAPER=paper.png\n";
    for (const char* f : {"classic.jpg", "paper.png", "picked.jpg"}) std::ofstream(walls / f) << "x";

    desk_install::Context ctx;
    ctx.script_dir = root;
    ctx.home = root / "home";
    auto use = [&](const char* theme) {
        ctx.theme_name = theme;
        ctx.palette_path = root / "themes" / theme / "palette.sh";
    };
    auto finish_run = [&] { std::ofstream(root / ".active-theme") << ctx.theme_name << "\n"; };

    use("FoxML_Classic");
    desk_install::seed_theme_wallpaper(ctx);
    expect("new machine", link, "classic.jpg");
    finish_run();

    fs::remove(link);
    fs::create_symlink("picked.jpg", link);
    desk_install::seed_theme_wallpaper(ctx);
    expect("same theme keeps the pick", link, "picked.jpg");
    finish_run();

    use("FoxML_Paper");
    desk_install::seed_theme_wallpaper(ctx);
    expect("theme change", link, "paper.png");
    finish_run();

    fs::remove(walls / "paper.png");
    use("FoxML_Classic");
    fs::remove(walls / "classic.jpg");
    desk_install::seed_theme_wallpaper(ctx);
    expect("theme change, its wallpaper missing: nothing removed", link, "paper.png");

    fs::remove_all(root);
    if (failures == 0) std::printf("test_wallpaper_seed: ok\n");
    return failures == 0 ? 0 : 1;
}
