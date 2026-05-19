// modules/render.cpp — drives fox-render-fast for the chosen theme.
//
// Pattern every module follows:
//   • read what it needs from Context
//   • emit a ui::section() heading
//   • do its work via the typed sh:: helpers (so --dry-run works for free)
//   • record results back on Context if other modules depend on it
//
// Drift check: before re-rendering, compare the previous rendered output
// (in ctx.rendered_dir) to its deployed copy in ~/.config. If they differ,
// the user has live-edited their config since the last install and the
// next render will wipe those changes. Warn + offer to bail; --full
// (ctx.force_reapply) suppresses the prompt and overwrites.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"
#include "symlinks_data.hpp"

#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

fs::path expand_tilde(const std::string& s, const fs::path& home) {
    if (s.empty() || s[0] != '~') return fs::path(s);
    if (s.size() == 1) return home;
    if (s[1] == '/') return home / s.substr(2);
    return fs::path(s);
}

// Returns paths whose ~/.config copy differs from the previously-rendered
// version still sitting in ctx.rendered_dir. Empty when there is no
// previous render (fresh install) or all deployed copies match.
std::vector<fs::path> detect_drift(const Context& ctx) {
    std::vector<fs::path> drifted;
    if (!fs::is_directory(ctx.rendered_dir)) return drifted;
    for (const auto& m : symlinks::TEMPLATE_MAPPINGS) {
        std::string dest_s = m.dest;
        if (dest_s.find("AGENT_DIR") != std::string::npos ||
            dest_s.find("FIREFOX_PROFILE") != std::string::npos) continue;
        fs::path prior = ctx.rendered_dir / m.src;
        fs::path dest  = expand_tilde(dest_s, ctx.home);
        if (!fs::exists(prior) || !fs::exists(dest)) continue;
        if (idem::read_file(prior) != idem::read_file(dest)) {
            drifted.push_back(dest);
        }
    }
    return drifted;
}

}  // namespace

void run_render(Context& ctx) {
    ui::section("Rendering templates with " + ctx.theme_name + " palette");

    auto drifted = detect_drift(ctx);
    if (!drifted.empty()) {
        ui::warn("live ~/.config edits detected — re-render will overwrite them:");
        for (auto& p : drifted) ui::substep(p.string());
        ui::substep("capture them into templates first: ./update.sh");
        ui::substep("or pass --full to overwrite without this prompt");
        if (sh::dry_run() || ctx.force_reapply) {
            // dry-run: previewing only, never abort; --full: explicit override.
            if (ctx.force_reapply) ui::warn("--full set — overwriting anyway");
        } else if (ctx.assume_yes || !ui::tty()) {
            ui::err("aborting render to protect live edits (re-run with --full to overwrite)");
            std::exit(2);
        } else if (!ui::ask_yn("Overwrite these live edits and continue?", false, ctx.assume_yes)) {
            ui::err("render cancelled — run ./update.sh to keep your edits");
            std::exit(2);
        }
    }

    if (!fs::exists(ctx.palette_path)) {
        ui::err("palette not found: " + ctx.palette_path.string());
        return;
    }
    if (!fs::is_directory(ctx.templates_dir)) {
        ui::err("templates dir not found: " + ctx.templates_dir.string());
        return;
    }

    fs::create_directories(ctx.rendered_dir);

    // Prefer the installed binary; fall back to the in-tree build during
    // development so contributors don't need `make install` to iterate.
    std::string render_bin = "fox-render-fast";
    fs::path local = ctx.script_dir / "src/fox-render/fox-render-fast";
    if (fs::exists(local)) render_bin = local.string();

    int rc = sh::run({
        render_bin,
        ctx.palette_path.string(),
        ctx.templates_dir.string(),
        ctx.rendered_dir.string(),
    });
    if (rc != 0) {
        ui::err("render failed (exit " + std::to_string(rc) + ")");
        return;
    }
    ui::ok("templates rendered to " + ctx.rendered_dir.string());
}

}  // namespace fox_install
