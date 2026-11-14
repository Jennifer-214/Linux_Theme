// modules/fox_moves.cpp — moves what the installer laid under the old fox names (fox_moves.hpp). Runs before the
// steps that lay the new ones, so the drawer step finds your menu already in its new folder.
#include "../core/context.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "fox_moves.hpp"

#include <cstdlib>

namespace desk_install {

void run_fox_moves(Context& ctx) {
    namespace fs = std::filesystem;
    ui::section("Files under the old fox names");
    std::vector<std::string> drawer;
    std::error_code ec;
    for (const auto& dir : {ctx.shared_dir / "quickshell/desk", ctx.templates_dir / "quickshell/desk"})
        for (const auto& file : fs::directory_iterator(dir, ec))
            if (file.is_regular_file(ec)) drawer.push_back(file.path().filename().string());
    // A drawer running from the old folder stops before its files go; the drawer step starts the new one.
    const bool old_drawer = fs::exists(ctx.config_home / "quickshell" / kOldFoxFolder / "shell.qml", ec);
    if (old_drawer && !sh::dry_run() && std::getenv("WAYLAND_DISPLAY"))
        sh::run({"quickshell", "-c", kOldFoxFolder, "kill"});
    const auto n = move_from_fox(ctx.home, ctx.config_home, drawer, sh::dry_run());
    if (n.moved + n.removed == 0) { ui::ok("nothing under the old names"); return; }
    const std::string said = std::to_string(n.moved) + " moved, " + std::to_string(n.removed) + " removed"
        + (n.left ? ", " + std::to_string(n.left) + " left in place (not laid by the installer)" : "");
    if (sh::dry_run()) ui::substep("[dry-run] would have " + said);
    else ui::ok(said);
}

}  // namespace desk_install
