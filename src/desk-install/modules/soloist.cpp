// modules/soloist.cpp — Soloist (Spotify Connect) as a user service that starts at login, with its API key saved
// once and kept private. Skips a machine without /usr/local/bin/soloist.

#include "soloist_files.hpp"

#include "../core/backup.hpp"
#include "../core/context.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

namespace desk_install {

namespace {

std::string read_all(const fs::path& path) {
    std::ifstream in(path);
    std::ostringstream text;
    text << in.rdbuf();
    return text.str();
}

}  // namespace

void run_soloist(Context& ctx) {
    ui::section("Soloist (Spotify Connect)");
    std::error_code ec;
    if (!fs::exists(soloist::BIN, ec)) {
        ui::skipped(std::string("soloist not installed (") + soloist::BIN + ") — nothing to do");
        return;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would deploy soloist.service, make ~/.local/share/soloist private, "
                    "ask for the API key if none is saved, and start Soloist at login");
        return;
    }

    const fs::path src = ctx.shared_dir / "soloist" / soloist::UNIT;
    const fs::path unit = ctx.config_home / "systemd/user" / soloist::UNIT;
    const bool unchanged = fs::exists(unit, ec) && read_all(unit) == read_all(src);
    fs::create_directories(unit.parent_path(), ec);
    if (!deploy_file_atomic(ctx, src, unit)) {
        ui::warn("could not install " + unit.string());
        return;
    }

    const fs::path data = soloist::data_dir(ctx.home, std::getenv("XDG_DATA_HOME"));
    fs::create_directories(data, ec);
    if (!soloist::key_saved(data) && !ctx.assume_yes && ::isatty(STDIN_FILENO)) {
        ui::substep("Paste your Soloist API key and press Enter (it is not shown; Enter alone skips)");
        sh::run({soloist::BIN, "setup-api-key"});
    }
    if (!soloist::make_private(data)) ui::warn("could not make " + data.string() + " private (700, key 600)");
    const bool have_key = soloist::key_saved(data);
    if (!have_key) ui::warn("no Soloist API key saved — run `soloist setup-api-key`, then `systemctl --user restart soloist`");

    sh::systemctl_daemon_reload(/*user=*/true);
    const bool ours = sh::run({"systemctl", "--user", "is-active", "--quiet", soloist::UNIT}) == 0;
    const bool by_hand = !ours && sh::run({"pgrep", "-u", std::to_string(::getuid()), "-x", "soloist"}) == 0;
    if (by_hand) {
        // A second copy cannot take the data folder's lock and would restart every 10 seconds.
        sh::run({"systemctl", "--user", "enable", soloist::UNIT});
        ui::warn("a Soloist started by hand is running: stop it, then `systemctl --user start soloist`");
        return;
    }
    if (ours && !unchanged) sh::run({"systemctl", "--user", "restart", soloist::UNIT});
    if (sh::run({"systemctl", "--user", "enable", "--now", soloist::UNIT}) != 0) {
        ui::warn("could not start soloist.service — `journalctl --user -u soloist` says why");
        return;
    }
    ui::ok(have_key ? "Soloist runs now and at every login" : "Soloist enabled; it logs in once a key is saved");
}

}  // namespace desk_install
