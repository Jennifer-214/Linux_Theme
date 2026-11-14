// Files laid under the old fox names move or go; yours stay, and a second run changes nothing.
#include "../modules/fox_moves.hpp"

#include <cstdio>
#include <fstream>
#include <unistd.h>

namespace fs = std::filesystem;
using desk_install::move_from_fox;

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}
static void write(const fs::path& path, const std::string& text) {
    fs::create_directories(path.parent_path());
    std::ofstream(path) << text;
}
static std::string read(const fs::path& path) {
    std::ifstream in(path);
    return {std::istreambuf_iterator<char>(in), {}};
}

int main() {
    char pattern[] = "/tmp/fox-moves-XXXXXX";
    if (!::mkdtemp(pattern)) return 1;
    const fs::path home(pattern), config = home / ".config";
    const std::string old = desk_install::kOldFoxFolder;
    const auto nvim = config / "nvim/lua" / old, drawer = config / "quickshell" / old, desk = config / "quickshell/desk";
    const auto ext = home / ".pi/agent/extensions";
    write(nvim / "review.lua", "old module");
    write(nvim / "mine.lua", "a file of yours");
    write(drawer / "menus.json", "{\"yours\": true}");
    write(drawer / "shell.qml", "old drawer");
    write(drawer / "menus.default.json", "{}");
    write(drawer / "notes.txt", "a file of yours");
    write(ext / desk_install::kOldPiExtensions[2], "old extension");
    write(ext / old / "build.ts", "old stamp");
    write(ext / "other.ts", "someone else's extension");

    const std::vector<std::string> laid{"shell.qml", "menus.json", "Theme.qml"};
    const auto dry = move_from_fox(home, config, laid, true);
    expect(dry.moved == 1 && dry.removed == 5, "a dry run counts what would happen");
    expect(fs::exists(nvim / "review.lua") && fs::exists(drawer / "menus.json"), "a dry run changes nothing");

    const auto ran = move_from_fox(home, config, laid, false);
    expect(ran.moved == 1 && ran.removed == 5, "one menu moved, five laid files removed");
    expect(read(desk / "menus.json") == "{\"yours\": true}", "your menu moves to the new folder as it was");
    expect(!fs::exists(nvim / "review.lua") && read(nvim / "mine.lua") == "a file of yours", "your own Neovim file stays");
    expect(!fs::exists(drawer / "shell.qml") && read(drawer / "notes.txt") == "a file of yours", "your own drawer file stays");
    expect(!fs::exists(ext / desk_install::kOldPiExtensions[2]) && !fs::exists(ext / old), "old pi extensions and their stamp go");
    expect(read(ext / "other.ts") == "someone else's extension", "other extensions stay");
    expect(ran.left == 2, "what stays is counted");

    const auto again = move_from_fox(home, config, laid, false);
    expect(again.moved == 0 && again.removed == 0, "a second run changes nothing");

    // A menu already at the new place wins; the old one is left, not overwritten or lost.
    write(drawer / "menus.json", "{\"older\": true}");
    const auto both = move_from_fox(home, config, laid, false);
    expect(both.moved == 0 && read(desk / "menus.json") == "{\"yours\": true}" && read(drawer / "menus.json") == "{\"older\": true}",
           "an existing new menu is kept and the old one left");

    expect(desk_install::fox_names_deployed(home, config) == false, "nothing laid under the old names is left");
    write(nvim / "review.lua", "old module");
    expect(desk_install::fox_names_deployed(home, config), "an old module is seen");

    fs::remove_all(home);
    if (failures == 0) std::printf("test_fox_moves: ok\n");
    return failures == 0 ? 0 : 1;
}
