// modules/zsh_plugins.cpp — clone oh-my-zsh plugins if missing.
//
// Bash version was an inline block in install.sh. Plugins:
//   zsh-syntax-highlighting, zsh-autosuggestions, zsh-completions
// Skipped if ~/.oh-my-zsh isn't installed (caramel zsh theme also
// depends on it). Idempotent.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* PLUGINS[] = {
    "zsh-syntax-highlighting",
    "zsh-autosuggestions",
    "zsh-completions",
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
        for (auto p : PLUGINS) {
            ui::substep(std::string("[dry-run] would clone ") + p);
        }
        return;
    }

    fs::path plugins_root = omz / "custom/plugins";
    fs::create_directories(plugins_root);
    std::size_t cloned = 0;
    for (auto repo : PLUGINS) {
        fs::path target = plugins_root / repo;
        if (fs::is_directory(target)) continue;
        int rc = sh::run({"git", "clone", "--quiet", "--depth", "1",
                          std::string("https://github.com/zsh-users/") + repo + ".git",
                          target.string()});
        if (rc == 0) {
            ui::ok(std::string("zsh plugin: ") + repo);
            ++cloned;
        } else {
            ui::warn(std::string("clone failed: ") + repo);
        }
    }
    if (cloned == 0) ui::skipped("all plugins already present");
}

}  // namespace fox_install
