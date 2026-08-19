// modules/symlinks.cpp — deploy rendered + shared configs (native port).
//
// Iterates TEMPLATE_MAPPINGS and SHARED_MAPPINGS from symlinks_data.hpp,
// resolving ~ to $HOME and skipping entries whose destination still
// contains a placeholder (FIREFOX_PROFILE / AGENT_DIR — those are
// handled by `modules/specials.cpp`).
//
// Mirrors bash semantics:
//   * file source            → backup_and_copy (snapshot to ctx.backup_dir, then copy)
//   * dir source             → backup_and_copy_dir (per-file snapshot inside dir, then copy tree)
//   * dest under .oh-my-zsh  → skip when ~/.oh-my-zsh doesn't exist (caramel zsh theme)

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"
#include "symlinks_data.hpp"

#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

// Expand a leading `~` to $HOME. Anything else is returned untouched.
fs::path expand_tilde(const std::string& s, const fs::path& home) {
    if (s.empty() || s[0] != '~') return fs::path(s);
    if (s.size() == 1) return home;
    if (s[1] == '/') return home / s.substr(2);
    // We don't support `~user/...` form — bash mapping table never uses it.
    return fs::path(s);
}

bool contains(const std::string& s, const char* needle) {
    return s.find(needle) != std::string::npos;
}

// Snapshot one pre-existing file under ctx.backup_dir, preserving the
// $HOME-relative path. Returns false ONLY when a pre-existing dest could
// not be backed up — the caller must then refuse to overwrite it.
// Returns true when there was nothing to preserve or the backup landed.
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

// One file: backup + atomic copy. Preserves source permissions. Refuses
// to overwrite an existing file whose backup failed (better to leave the
// user's config intact than clobber it with no recoverable copy).
bool deploy_file(const Context& ctx, const fs::path& src, const fs::path& dest) {
    std::error_code ec;
    fs::create_directories(dest.parent_path(), ec);
    if (!snapshot_one(ctx, dest)) {
        ui::warn("refusing to overwrite " + dest.string() + " — its backup failed");
        return false;
    }

    fs::path tmp = dest;
    tmp += ".foxin.tmp";
    fs::copy_file(src, tmp, fs::copy_options::overwrite_existing, ec);
    if (ec) return false;
    fs::permissions(tmp, fs::status(src).permissions(),
                    fs::perm_options::replace, ec);
    fs::rename(tmp, dest, ec);
    if (ec) { fs::remove(tmp, ec); return false; }
    return true;
}

// Recursive dir copy with per-file snapshot of any pre-existing files
// at the destination (matches bash backup_and_copy_dir).
bool deploy_dir(const Context& ctx, const fs::path& src, const fs::path& dest) {
    std::error_code ec;
    fs::create_directories(dest, ec);
    bool all_backed_up = true;
    for (auto& e : fs::recursive_directory_iterator(src)) {
        if (!e.is_regular_file()) continue;
        fs::path rel = fs::relative(e.path(), src);
        if (!snapshot_one(ctx, dest / rel)) all_backed_up = false;
    }
    // Refuse the bulk overwrite if any pre-existing file couldn't be
    // backed up — the recursive copy below clobbers in place.
    if (!all_backed_up) {
        ui::warn("refusing to overwrite " + dest.string() + " — a backup failed");
        return false;
    }
    // Now copy the tree. fs::copy_options::recursive + overwrite_existing
    // is the std::filesystem analogue of `cp -a src/. dest/`.
    fs::copy(src, dest,
             fs::copy_options::recursive |
             fs::copy_options::overwrite_existing |
             fs::copy_options::copy_symlinks, ec);
    return !ec;
}

// Returns true if the destination should be skipped for this run.
bool should_skip(const Context& ctx, const std::string& dest_raw) {
    // Placeholders that the specials module owns.
    if (contains(dest_raw, "FIREFOX_PROFILE")) return true;
    if (contains(dest_raw, "AGENT_DIR"))       return true;
    // oh-my-zsh theme — only if oh-my-zsh is actually installed.
    if (contains(dest_raw, ".oh-my-zsh")) {
        std::error_code ec;
        if (!fs::is_directory(ctx.home / ".oh-my-zsh", ec) || ec) return true;
    }
    return false;
}

// Deploy one mapping. base = source root (rendered_dir or shared_dir).
// Returns 1 on success, 0 on skipped, -1 on failure.
int deploy_mapping(const Context& ctx,
                   const fs::path& base,
                   const symlinks::Mapping& m) {
    if (should_skip(ctx, m.dest)) return 0;

    fs::path src  = base / m.src;
    fs::path dest = expand_tilde(m.dest, ctx.home);

    std::error_code ec;
    if (!fs::exists(src, ec) || ec) {
        // Bash version silently skipped missing sources too.
        return 0;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would deploy " + dest.string());
        return 1;
    }
    bool ok = fs::is_directory(src) ? deploy_dir(ctx, src, dest)
                                    : deploy_file(ctx, src, dest);
    if (!ok) {
        ui::warn("failed to deploy " + dest.string());
        return -1;
    }
    return 1;
}

}  // namespace

void run_symlinks(Context& ctx) {
    ui::section("Deploying rendered + shared configs");

    // Silent-partial-deploy guard: if render ran this session but did NOT
    // succeed, deploying now ships a partial config tree (no hyprland.conf/
    // waybar) yet reports "deployed N" success. Refuse rather than half-config.
    if (ctx.render_ran && !ctx.render_ok) {
        ui::err("render did not complete this run — refusing to deploy a partial "
                "config set (would leave the box without hyprland.conf/waybar). "
                "Resolve the render error and re-run --render --symlinks.");
        return;
    }

    if (!fs::is_directory(ctx.rendered_dir)) {
        if (ctx.render_ran) {
            ui::err("render reported success but produced no rendered_dir — "
                    "refusing a partial deploy");
            return;
        }
        ui::warn("no rendered dir — did --render run? (deploying shared configs only)");
    }
    if (!fs::is_directory(ctx.shared_dir)) {
        ui::warn("no shared dir at " + ctx.shared_dir.string());
    }

    std::size_t deployed = 0, skipped = 0, failed = 0;
    auto tally = [&](int r) {
        if (r == 1) ++deployed;
        else if (r == 0) ++skipped;
        else ++failed;
    };

    // TEMPLATE_MAPPINGS — sourced from rendered/<src>.
    for (std::size_t i = 0; i < symlinks::TEMPLATE_MAPPINGS_COUNT; ++i) {
        tally(deploy_mapping(ctx, ctx.rendered_dir, symlinks::TEMPLATE_MAPPINGS[i]));
    }
    // SHARED_MAPPINGS — sourced from shared/<src>.
    for (std::size_t i = 0; i < symlinks::SHARED_MAPPINGS_COUNT; ++i) {
        tally(deploy_mapping(ctx, ctx.shared_dir, symlinks::SHARED_MAPPINGS[i]));
    }

    ui::ok("deployed " + std::to_string(deployed) +
           ", skipped "  + std::to_string(skipped) +
           ", failed "   + std::to_string(failed));
    if (deployed > 0 && !sh::dry_run()) {
        ui::ok("backups at " + ctx.backup_dir.string());
    }
}

}  // namespace fox_install
