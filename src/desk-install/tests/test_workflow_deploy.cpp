#include "../core/backup.hpp"
#include "../modules/symlinks_data.hpp"
#include "../modules/fox_aliases.hpp"
#include "../modules/menu_upgrade.hpp"
#include "../../desk-common/shell.hpp"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <set>
#include <unistd.h>

namespace fs = std::filesystem;
static std::string read(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), {}};
}
int main() {
    auto repo = fs::current_path();
    while (repo != repo.parent_path() && !fs::is_directory(repo / "shared/nvim_lua")) repo = repo.parent_path();
    const auto fixture = fs::temp_directory_path() / ("workflow-deploy-" + std::to_string(::getpid()));
    desk_install::Context ctx;
    ctx.home = fixture / "home"; ctx.backup_dir = fixture / "backup";
    fs::create_directories(ctx.home);
    int failures = 0;
    const auto check = [&](bool ok, const std::string& why) { if (!ok) { ++failures; std::cerr << "FAIL: " << why << '\n'; } };
    auto menu = nlohmann::json::parse(read(repo / "shared/quickshell/foxml/menus.json"));
    const auto shipped = menu;
    for (auto& group : menu["groups"]) if (group["id"] == "workbench") {
        auto& items = group["items"];
        items.erase(std::remove_if(items.begin(), items.end(), [](const auto& item) { return item.value("id", "") == "attention"; }), items.end());
    }
    std::set<std::string> offered;
    const auto offered_pages = desk_install::menu_upgrade::offer(menu, shipped, offered, true);
    check(std::find(offered_pages.begin(), offered_pages.end(), "attention") != offered_pages.end(), "the new attention page reaches an existing install with no offer history");
    check(desk_install::menu_upgrade::offer(menu, shipped, offered, false).empty(), "a repeated install does not offer duplicate pages");
    std::set<std::string> installed;
    for (const auto& mapping : desk_install::symlinks::SHARED_MAPPINGS) {
        const std::string source = mapping.src;
        if (source.rfind("nvim_lua/foxml/", 0) != 0 && source.rfind("claude/mods/foxml-paper/", 0) != 0
            && source != "pi/extensions/fox-notify.ts" && source != "pi/extensions/foxml/build.ts") continue;
        const auto target = ctx.home / std::string(mapping.dest).substr(2);
        check(desk_install::deploy_file_atomic(ctx, repo / "shared" / source, target), "deploy " + source);
        check(read(target) == read(repo / "shared" / source), "current bytes " + source);
        check(desk_install::deploy_file_atomic(ctx, repo / "shared" / source, target), "repeat deploy " + source);
        installed.insert(source);
    }
    // Discovery makes a newly imported module a required installer asset automatically.
    for (const auto& file : fs::directory_iterator(repo / "shared/nvim_lua/foxml"))
        if (file.path().extension() == ".lua") check(installed.count("nvim_lua/foxml/" + file.path().filename().string()), "missing Neovim module " + file.path().filename().string());
    for (const auto& folder : {"hooks", "types"})
        for (const auto& file : fs::directory_iterator(repo / "shared/claude/mods/foxml-paper" / folder))
            if (file.is_regular_file()) check(installed.count("claude/mods/foxml-paper/" + std::string(folder) + '/' + file.path().filename().string()), "missing mod dependency " + file.path().filename().string());
    const auto rendered = fixture / "rendered";
    check(desk_install::sh::run({(repo / "src/desk-render/desk-render-fast").string(), (repo / "themes/Paper/palette.sh").string(),
          (repo / "templates/claude").string(), rendered.string()}) == 0, "render notebook palette");
    const auto theme = ctx.home / ".claude/mods/foxml-paper/hooks/theme.ts";
    check(desk_install::deploy_file_atomic(ctx, rendered / "mods/foxml-paper/hooks/theme.ts", theme), "deploy rendered palette");
    check(read(theme).find("{{") == std::string::npos && read(theme).find("ink:") != std::string::npos, "palette resolves");
    const auto bin = ctx.home / ".local/bin";
    fs::create_directories(bin);
    for (const auto* tool : {"desk-work", "desk-drawer"}) {
        const auto source = repo / "src" / tool / tool;
        check(fs::is_regular_file(source) && desk_install::deploy_file_atomic(ctx, source, bin / tool), std::string("native backend ") + tool);
        check((fs::status(bin / tool).permissions() & fs::perms::owner_exec) != fs::perms::none, std::string("executable ") + tool);
    }
    desk_install::lay_fox_aliases(bin, false);
    check(fs::is_symlink(bin / "fox-work") && fs::equivalent(bin / "fox-work", bin / "desk-work"), "old work name remains usable");
    check(fs::is_symlink(bin / "fox-drawer") && fs::equivalent(bin / "fox-drawer", bin / "desk-drawer"), "old drawer name remains usable");
    fs::remove_all(fixture);
    std::cout << "workflow deployment: " << failures << " failures\n";
    return failures ? 1 : 0;
}
