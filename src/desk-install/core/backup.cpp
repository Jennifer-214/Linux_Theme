// core/backup.cpp — see backup.hpp.

#include "backup.hpp"
#include "../../desk-common/ui.hpp"

#include <string>
#include <system_error>
#include <vector>
#include <unistd.h>

namespace fs = std::filesystem;

namespace desk_install {

bool snapshot_one(const Context& ctx, const fs::path& dest) {
    std::error_code ec;
    const auto status = fs::symlink_status(dest, ec);
    if (status.type() == fs::file_type::not_found &&
        (!ec || ec == std::errc::no_such_file_or_directory)) return true;
    if (ec) {
        ui::warn("cannot inspect " + dest.string() + " for backup: " + ec.message());
        return false;
    }

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
    // A file may be deployed by both the bulk pass and a later module.
    // Preserve the first snapshot of this run, before either changed it.
    const auto previous = fs::symlink_status(bak, ec);
    if (!ec && previous.type() != fs::file_type::not_found) return true;
    if (ec && ec != std::errc::no_such_file_or_directory) {
        ui::warn("cannot inspect backup " + bak.string() + ": " + ec.message());
        return false;
    }
    ec.clear();
    fs::create_directories(bak.parent_path(), ec);
    if (!ec) fs::copy(dest, bak,
             fs::copy_options::overwrite_existing |
             fs::copy_options::copy_symlinks, ec);
    if (ec) {
        ui::warn("backup of " + dest.string() + " failed: " + ec.message());
        return false;
    }
    return true;
}

bool deploy_file_atomic(const Context& ctx, const fs::path& src, const fs::path& dest) {
    std::error_code ec;
    fs::create_directories(dest.parent_path(), ec);
    if (ec || !snapshot_one(ctx, dest)) return false;
    std::string pattern = dest.string() + ".foxin.XXXXXX";
    std::vector<char> name(pattern.begin(), pattern.end());
    name.push_back('\0');
    const int fd = ::mkstemp(name.data());
    if (fd < 0) return false;
    ::close(fd);
    const fs::path tmp(name.data());
    fs::copy_file(src, tmp, fs::copy_options::overwrite_existing, ec);
    auto mode = fs::perms::unknown;
    if (!ec) mode = fs::status(src, ec).permissions();
    if (!ec) fs::permissions(tmp, mode, fs::perm_options::replace, ec);
    if (!ec) fs::rename(tmp, dest, ec);
    if (ec) {
        std::error_code cleanup;
        fs::remove(tmp, cleanup);
        return false;
    }
    return true;
}

bool deploy_symlink_atomic(const Context& ctx, const fs::path& target, const fs::path& dest) {
    std::error_code ec;
    fs::create_directories(dest.parent_path(), ec);
    if (ec || !snapshot_one(ctx, dest)) return false;
    std::string pattern = dest.string() + ".foxlink.XXXXXX";
    std::vector<char> name(pattern.begin(), pattern.end()); name.push_back(0);
    const int fd = ::mkstemp(name.data()); if (fd < 0) return false;
    ::close(fd); ::unlink(name.data());
    fs::create_symlink(target, name.data(), ec);
    if (!ec) fs::rename(name.data(), dest, ec);
    if (ec) { std::error_code ignored; fs::remove(name.data(), ignored); return false; }
    return true;
}

}  // namespace desk_install
