// modules/prune_backups.cpp — keep ~/.theme_backups lean after each install.
//
// Every install run snapshots pre-existing configs into a timestamped
// ~/.theme_backups/foxml-backup-<ts>/ dir. Nothing rotated them, so they
// accumulated unbounded (145 dirs / 4.8G observed in the wild). desk-rollback
// already owns that directory and implements the prune; this just invokes it
// at the tail of a successful install so updates self-clean. Keeps the 10
// most recent — all desk-rollback ever offers to restore anyway. The .foxml-bak
// recovery anchors next to PAM/fstab/etc. are a separate mechanism and are
// deliberately left untouched.

#include "../core/context.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include <filesystem>
#include <string>
#include <system_error>

namespace fs = std::filesystem;

namespace fox_install {

void run_prune_backups(Context& ctx) {
    ui::section("Pruning old config backups");

    fs::path tool = ctx.script_dir / "shared" / "bin" / "desk-rollback";
    std::error_code ec;
    if (!fs::exists(tool, ec)) {
        ui::substep("desk-rollback not found — skipping prune");
        return;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would keep the 10 most recent ~/.theme_backups");
        return;
    }

    std::string out;
    sh::capture({tool.string(), "--prune", "--keep", "10", "--quiet"}, out);
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
    ui::ok(out.empty() ? std::string("backups already lean (kept 10)") : out);
}

}  // namespace fox_install
