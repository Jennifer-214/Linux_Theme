// modules/zsh_plugins.cpp — clone oh-my-zsh plugins if missing.
//
// Bash version was an inline block in install.sh. Plugins:
//   zsh-syntax-highlighting, zsh-autosuggestions, zsh-completions, fzf-tab
// Skipped if ~/.oh-my-zsh isn't installed (caramel zsh theme also
// depends on it). Idempotent. Each plugin carries its own URL since they
// span orgs (zsh-users/* + Aloxaf/fzf-tab); the .zshrc template owns
// enabling them (plugins=() array + the manual source order).

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

struct Plugin { const char* name; const char* url; };

constexpr Plugin PLUGINS[] = {
    {"zsh-syntax-highlighting", "https://github.com/zsh-users/zsh-syntax-highlighting.git"},
    {"zsh-autosuggestions",     "https://github.com/zsh-users/zsh-autosuggestions.git"},
    {"zsh-completions",         "https://github.com/zsh-users/zsh-completions.git"},
    {"fzf-tab",                 "https://github.com/Aloxaf/fzf-tab.git"},
};

}  // namespace

void run_zsh_plugins(Context& ctx) {
    ui::section("oh-my-zsh plugins");

    fs::path omz = ctx.home / ".oh-my-zsh";
    if (!fs::is_directory(omz)) {
        ui::ok("oh-my-zsh not installed — skipping plugin clones");
        return;
    }

    if (sh::dry_run()) {
        for (auto& p : PLUGINS) {
            ui::substep(std::string("[dry-run] would clone ") + p.name);
        }
        return;
    }

    fs::path plugins_root = omz / "custom/plugins";
    fs::create_directories(plugins_root);
    std::size_t cloned = 0;
    for (auto& p : PLUGINS) {
        fs::path target = plugins_root / p.name;
        if (fs::is_directory(target)) continue;
        int rc = sh::run({"git", "clone", "--quiet", "--depth", "1", p.url, target.string()});
        if (rc == 0) {
            ui::ok(std::string("zsh plugin: ") + p.name);
            ++cloned;
        } else {
            ui::warn(std::string("clone failed: ") + p.name);
        }
    }
    if (cloned == 0) ui::skipped("all plugins already present");
}

}  // namespace fox_install
