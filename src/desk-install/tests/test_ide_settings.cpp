// VS Code / Cursor settings are JSONC. A file strict JSON can't read used to be replaced by just the theme key.
#include "../modules/ide_settings.hpp"

#include <cstdio>
#include <unistd.h>

namespace fs = std::filesystem;
using desk_install::ide_settings::Result;
using desk_install::ide_settings::set_color_theme;

static int failures = 0;
static void expect(const char* what, bool ok) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}
static std::string read(const fs::path& p) {
    std::ifstream f(p);
    return {std::istreambuf_iterator<char>(f), {}};
}

int main() {
    char pattern[] = "/tmp/fox-ide-settings-XXXXXX";
    if (!::mkdtemp(pattern)) return 1;
    const fs::path root(pattern), settings = root / "home/.config/Code/User/settings.json";
    desk_install::Context ctx;
    ctx.home = root / "home";
    ctx.backup_dir = root / "backup";
    fs::create_directories(settings.parent_path());

    const std::string jsonc = "{\n  // my font\n  \"editor.fontSize\": 15,\n}\n";
    std::ofstream(settings) << jsonc;
    expect("comments are left alone", set_color_theme(ctx, settings, "Fox ML") == Result::LeftAlone);
    expect("commented file is unchanged", read(settings) == jsonc);

    const std::string array = "[1, 2]\n";
    std::ofstream(settings) << array;
    expect("a non-object is left alone", set_color_theme(ctx, settings, "Fox ML") == Result::LeftAlone);
    expect("non-object is unchanged", read(settings) == array);

    std::ofstream(settings) << "{\"z.last\": 1, \"a.first\": 2}";
    expect("plain JSON updates", set_color_theme(ctx, settings, "Fox ML") == Result::Updated);
    const std::string written = read(settings);
    expect("other keys stay, in order", written.find("z.last") < written.find("a.first"));
    expect("theme is set", written.find("\"workbench.colorTheme\": \"Fox ML\"") != std::string::npos);
    expect("no staged file remains", !fs::exists(settings.string() + ".foxml-new"));
    bool backed_up = false;
    for (const auto& e : fs::recursive_directory_iterator(ctx.backup_dir))
        if (e.is_regular_file() && read(e.path()).find("z.last") != std::string::npos) backed_up = true;
    expect("the old file was backed up first", backed_up);

    const auto stamp = fs::last_write_time(settings);
    expect("already set is a no-op", set_color_theme(ctx, settings, "Fox ML") == Result::Unchanged);
    expect("no-op doesn't rewrite", fs::last_write_time(settings) == stamp);

    std::ofstream(settings) << "  \n";
    expect("blank file is treated as empty", set_color_theme(ctx, settings, "Fox ML") == Result::Updated);

    fs::remove(settings);
    expect("missing file is created", set_color_theme(ctx, settings, "Fox ML") == Result::Updated && fs::exists(settings));

    fs::remove_all(root);
    if (failures == 0) std::printf("test_ide_settings: ok\n");
    return failures == 0 ? 0 : 1;
}
