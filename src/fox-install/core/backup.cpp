// core/backup.cpp — see backup.hpp.

#include "backup.hpp"
#include "../../fox-common/ui.hpp"

#include <string>
#include <system_error>

namespace fs = std::filesystem;

namespace fox_install {

bool snapshot_one(const Context& ctx, const fs::path& dest) {
    std::error_code ec;
    if (!fs::exists(dest, ec) || ec) return true;   // nothing to preserve

    // Compute path relative to $HOME if possible — matches bash
    // ${dest#$HOME/}. Files outside $HOME (e.g. /etc/...) go under
    // backup_dir/_abs/ to preserve uniqueness.
    fs::path rel;
    std::string ds = dest.string(), hs = ctx.home.string();
    if (ds.rfind(hs + "/", 0) == 0) {
        rel = ds.substr(hs.size() + 1);
    } else {
        rel = "_abs" + ds;
    }

    fs::path bak = ctx.backup_dir / rel;
    fs::create_directories(bak.parent_path(), ec);
    fs::copy(dest, bak,
             fs::copy_options::overwrite_existing |
             fs::copy_options::copy_symlinks, ec);
    if (ec) {
        ui::warn("backup of " + dest.string() + " failed: " + ec.message());
        return false;
    }
    return true;
}

}  // namespace fox_install
