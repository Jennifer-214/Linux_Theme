// core/backup.hpp — the install run's one backup step, shared by every module that replaces a file.
//
// Before 2026-10-15 symlinks.cpp and specials.cpp each kept their own copy of snapshot_one (the same logic,
// different comments); the theme_workspace step needed a third. One copy here instead.
#pragma once

#include "context.hpp"

#include <filesystem>

namespace desk_install {

// Snapshot one pre-existing file under ctx.backup_dir, preserving the
// $HOME-relative path. Returns false ONLY when a pre-existing dest could
// not be backed up — the caller must then refuse to overwrite it.
// Returns true when there was nothing to preserve or the backup landed.
bool snapshot_one(const Context& ctx, const std::filesystem::path& dest);

// Snapshot first, then replace one file atomically, preserving its source mode.
bool deploy_file_atomic(const Context& ctx, const std::filesystem::path& src,
                        const std::filesystem::path& dest);

}  // namespace desk_install
