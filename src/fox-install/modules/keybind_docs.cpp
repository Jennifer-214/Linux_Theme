// modules/keybind_docs.cpp — refresh KEYBINDS.md from the live configs.
//
// Runs fox-gen-keybinds so the deployed keybind reference always matches the
// actual tmux/Hyprland configs — even if someone edited a bind and forgot to
// regenerate. `specials` deploys KEYBINDS.md right after, so this must run
// before it. Read-only on the configs; rewrites only the marker-fenced
// sections of KEYBINDS.md. Never fails the install — a missing binary just
// leaves the doc as-is.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

void run_keybind_docs(Context& ctx) {
    ui::section("Refreshing keybind docs");
    fs::path in_tree = ctx.script_dir / "src/fox-gen-keybinds/fox-gen-keybinds";
    std::string bin = sh::have("fox-gen-keybinds") ? "fox-gen-keybinds" : in_tree.string();
    int rc = sh::run({bin,
                      "--keybinds", (ctx.script_dir / "KEYBINDS.md").string(),
                      "--tmux-conf", (ctx.script_dir / "templates/tmux/.tmux.conf").string(),
                      "--hypr-conf", (ctx.script_dir / "shared/hyprland_modules/keybinds.conf").string()});
    if (rc == 0) ui::ok("KEYBINDS.md matches the tmux/Hyprland configs");
    else ui::warn("fox-gen-keybinds unavailable — KEYBINDS.md left as-is");
}

}  // namespace fox_install
