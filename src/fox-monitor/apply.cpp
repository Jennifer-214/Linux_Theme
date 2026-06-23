// apply.cpp — re-apply the CURRENT wallpaper per monitor via awww.
//
// Port of rotate_wallpaper.sh's per-monitor loop. The base comes from the
// `.current` symlink (a bare filename), so this RE-APPLIES what's already
// chosen — it never advances a time-of-day slot. The pre-rendered
// `<base>_<WxH>` variant gets --resize fit (pixel-exact); a missing variant
// falls back to the source with --resize crop.

#include "apply.hpp"

#include "../fox-common/shell.hpp"
#include "../fox-common/ui.hpp"

#include <chrono>
#include <system_error>
#include <thread>

namespace fs = std::filesystem;
namespace sh = fox_install::sh;
namespace ui = fox_install::ui;

namespace fox_monitor::apply {

namespace {

// Split "name:WxH" — bash MONITOR_RESOLUTIONS shape.
bool parse_entry(const std::string& entry, std::string& name, std::string& res) {
    auto c = entry.find(':');
    if (c == std::string::npos) return false;
    name = entry.substr(0, c);
    res  = entry.substr(c + 1);
    return !name.empty() && !res.empty();
}

// Split "wall.jpg" → stem="wall", ext="jpg" (no leading dot).
void split_name(const std::string& file, std::string& stem, std::string& ext) {
    auto dot = file.find_last_of('.');
    if (dot == std::string::npos || dot == 0) { stem = file; ext.clear(); }
    else { stem = file.substr(0, dot); ext = file.substr(dot + 1); }
}

// Ensure awww-daemon is responsive; spawn detached if not. Returns true
// once `awww query` succeeds (or immediately under dry_run).
bool ensure_daemon(bool dry_run) {
    if (!sh::have("awww")) {
        ui::warn("awww not on PATH — install awww to apply wallpapers");
        return false;
    }
    std::string ignore;
    if (sh::capture({"awww", "query"}, ignore)) return true;
    if (dry_run) return true;

    if (sh::have("awww-daemon")) {
        // setsid detaches the daemon from this process group.
        sh::run({"setsid", "awww-daemon"});
    }
    for (int i = 0; i < 30; ++i) {
        if (sh::capture({"awww", "query"}, ignore)) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return false;
}

}  // namespace

std::string current_base(const fs::path& wall_dir) {
    fs::path link = wall_dir / ".current";
    std::error_code ec;
    fs::path target = fs::read_symlink(link, ec);
    if (ec) return {};
    // .current is supposed to be a bare filename inside wall_dir; reject a
    // target carrying a path separator (matches the rotate.sh path-safety).
    std::string t = target.string();
    if (t.empty() || t.find('/') != std::string::npos) return {};
    return t;
}

std::string variant_for(const std::string& base, const std::string& res,
                        const fs::path& wall_dir, bool& is_fallback) {
    std::string stem, ext;
    split_name(base, stem, ext);
    std::string variant =
        ext.empty() ? stem + "_" + res : stem + "_" + res + "." + ext;
    std::error_code ec;
    if (fs::exists(wall_dir / variant, ec) && !ec) {
        is_fallback = false;
        return variant;
    }
    is_fallback = true;
    return base;
}

std::size_t apply_current(const sidecar::Layout& layout,
                          const fs::path& wall_dir, bool dry_run) {
    std::string base = current_base(wall_dir);
    if (base.empty()) {
        ui::warn("no active wallpaper symlink at " +
                 (wall_dir / ".current").string() + " — nothing to apply");
        return 0;
    }
    if (layout.monitor_resolutions.empty()) {
        ui::warn("MONITOR_RESOLUTIONS empty — no monitors to apply to");
        return 0;
    }

    ui::substep("current wallpaper = " + base);

    if (!ensure_daemon(dry_run)) {
        ui::warn("awww-daemon not responsive — skipping apply");
        return 0;
    }

    std::size_t applied = 0;
    for (const auto& entry : layout.monitor_resolutions) {
        std::string name, res;
        if (!parse_entry(entry, name, res)) continue;

        bool is_fallback = false;
        std::string file = variant_for(base, res, wall_dir, is_fallback);
        const char* resize = is_fallback ? "crop" : "fit";
        fs::path img = wall_dir / file;

        if (dry_run) {
            ui::substep(name + " (" + res + "): " + file + " --resize " +
                        resize + (is_fallback ? "  [fallback: variant missing]"
                                              : "  [variant]"));
            ++applied;
            continue;
        }

        int rc = sh::run({
            "awww", "img", "-o", name, img.string(),
            "--resize", resize,
            "--transition-type", "fade",
            "--transition-duration", "1",
            "--transition-fps", "60",
        });
        if (rc == 0) {
            ui::ok(name + " (" + res + "): " + file + " applied (--resize " +
                   std::string(resize) +
                   (is_fallback ? ", fallback to source)" : ")"));
            ++applied;
        } else {
            ui::warn(name + " (" + res + "): awww img failed (rc=" +
                     std::to_string(rc) + ")");
        }
    }
    return applied;
}

}  // namespace fox_monitor::apply
