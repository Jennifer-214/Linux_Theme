// modules/personalize.cpp — per-machine personalization (native port).
//
// Bash equivalents (now retired here):
//   mappings.sh:_generate_per_monitor_wallpapers
//   mappings.sh:_personalize_hyprlock
//   mappings.sh:_personalize_workspace_rules
//
// Each is a private helper below. They share the same monitor-layout
// sidecar (~/.config/foxml/monitor-layout.conf) and run unconditionally
// — missing inputs short-circuit cleanly.

#include "personalize.hpp"
#include "hypr_lua.hpp"

#include "../core/palette.hpp"
#include "../core/splice.hpp"
#include "../../desk-monitor/variants.hpp"
#include "../../desk-monitor/apply.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install::personalize {

namespace {

// Split "<name>:<WxH>" — bash MONITOR_RESOLUTIONS shape.
bool parse_entry(const std::string& entry, std::string& name, std::string& res) {
    auto c = entry.find(':');
    if (c == std::string::npos) return false;
    name = entry.substr(0, c);
    res  = entry.substr(c + 1);
    return !name.empty() && !res.empty();
}

// The sentinel splice helper now lives in core/splice.hpp (splice_sentinel),
// shared with the welcome_banner module. The per-monitor variant planner +
// executor moved to ../../desk-monitor/variants.{hpp,cpp}.

}  // namespace

// ─── per-monitor wallpaper variants ────────────────────────────────
// Thin wrapper over the libfox-monitor variants submodule, which now owns
// the pure planner + the path-parameterized executor (shared with the
// desk-monitor binary). This adapts the install Context/Layout/dry-run state
// to variants::generate's explicit parameters.
std::size_t generate_per_monitor_wallpapers(const Context& ctx,
                                            const sidecar::Layout& layout) {
    return fox_monitor::variants::generate(
        ctx.home / ".wallpapers", layout.monitor_resolutions, sh::dry_run(),
        /*force=*/false);
}

// ─── hyprlock per-monitor background blocks ────────────────────────
namespace {

const char* const BG_BEGIN = "# foxml:hyprlock-backgrounds-begin";
const char* const BG_END   = "# foxml:hyprlock-backgrounds-end";

std::string read_text(const fs::path& p) {
    std::ifstream in(p);
    return std::string((std::istreambuf_iterator<char>(in)),
                        std::istreambuf_iterator<char>());
}

std::string trim(std::string s) {
    auto b = s.find_first_not_of(" \t");
    if (b == std::string::npos) return {};
    auto e = s.find_last_not_of(" \t\r");
    return s.substr(b, e - b + 1);
}

// "key = value" → key, value (both trimmed); false for anything else.
bool key_value(const std::string& line, std::string& key, std::string& value) {
    auto eq = line.find('=');
    if (eq == std::string::npos) return false;
    key   = trim(line.substr(0, eq));
    value = trim(line.substr(eq + 1));
    return !key.empty() && key[0] != '#';
}

// The lines of the first background block between the sentinels.
std::vector<std::string> first_background(const std::string& body) {
    std::istringstream iss(body);
    std::string line;
    std::vector<std::string> lines;
    bool in_region = false, in_block = false;
    while (std::getline(iss, line)) {
        if (line.find(BG_BEGIN) != std::string::npos) { in_region = true; continue; }
        if (line.find(BG_END)   != std::string::npos) break;
        if (!in_region) continue;
        const std::string t = trim(line);
        if (!in_block) { in_block = t.rfind("background", 0) == 0 && t.back() == '{'; continue; }
        if (t == "}") return lines;
        lines.push_back(line);
    }
    return {};
}

}  // namespace

std::string lock_source_name(const std::string& name) {
    std::string stem = name, ext;
    auto dot = stem.find_last_of('.');
    if (dot != std::string::npos) { ext = stem.substr(dot); stem.erase(dot); }
    static const std::regex variant_suffix(R"(_[0-9]+x[0-9]+$)");
    std::smatch m;
    if (std::regex_search(stem, m, variant_suffix)) stem.erase(m.position(0));
    return stem + ext;
}

std::string lock_wallpaper_for(const std::string& active, const std::string& theme_default,
                               const std::string& res,
                               const std::function<bool(const std::string&)>& on_disk,
                               bool& is_fallback) {
    auto variant = [&](const std::string& base) {
        auto dot = base.find_last_of('.');
        return dot == std::string::npos ? base + "_" + res
                                        : base.substr(0, dot) + "_" + res + base.substr(dot);
    };
    is_fallback = false;
    if (!active.empty() && on_disk(variant(active))) return variant(active);
    is_fallback = true;
    for (const std::string& c : {theme_default.empty() ? std::string() : variant(theme_default),
                                 theme_default, active})
        if (!c.empty() && on_disk(c)) return c;
    return theme_default.empty() ? active : theme_default;
}

std::string background_tail(const std::string& body) {
    std::string tail;
    for (const auto& line : first_background(body)) {
        std::string k, v;
        if (key_value(line, k, v) && (k == "monitor" || k == "path")) continue;
        if (trim(line).empty()) continue;
        tail += line + "\n";
    }
    if (!tail.empty()) tail.pop_back();
    return tail;
}

std::string background_blocks(const std::vector<std::string>& monitor_resolutions,
                              const std::string& active, const std::string& theme_default,
                              const std::string& tail,
                              const std::function<bool(const std::string&)>& on_disk,
                              std::size_t& fallbacks) {
    std::ostringstream blocks;
    fallbacks = 0;
    for (const auto& entry : monitor_resolutions) {
        std::string name, res;
        if (!parse_entry(entry, name, res)) continue;
        bool fb = false;
        const std::string file = lock_wallpaper_for(active, theme_default, res, on_disk, fb);
        if (fb) ++fallbacks;
        blocks << "background {\n"
               << "    monitor = " << name << "\n"
               << "    path = ~/.wallpapers/" << file << "\n";
        if (!tail.empty()) blocks << tail << "\n";
        blocks << "}\n";
    }
    std::string out = blocks.str();
    if (!out.empty() && out.back() == '\n') out.pop_back();
    return out;
}

// One background block per monitor in the layout, each on the wallpaper cut for
// that monitor's size (the active wallpaper's variant, else the theme default's).
// The block settings (blur, brightness, ...) come from the rendered template, so
// a theme's palette decides them rather than this file.
bool personalize_hyprlock(const Context& ctx, const sidecar::Layout& layout) {
    fs::path hyprlock = ctx.config_home / "hypr/hyprlock.conf";
    fs::path rendered = ctx.rendered_dir / "hyprlock/hyprlock.conf";
    // Personalize whichever copies exist. On a FRESH box the live config is not
    // deployed yet (symlinks runs after personalize), so read + splice the
    // rendered copy; symlinks then deploys the personalized output. On a re-run
    // the live copy exists → identical to the prior behaviour (read live, splice
    // both). Gate on either being present.
    if (!fs::exists(hyprlock) && !fs::exists(rendered)) return false;
    if (layout.monitor_resolutions.empty())             return false;

    fs::path src = fs::exists(hyprlock) ? hyprlock : rendered;
    const std::string body = read_text(src);
    if (body.find(BG_BEGIN) == std::string::npos) {
        ui::warn("hyprlock.conf missing sentinel — skipping personalisation");
        return false;
    }

    const fs::path wall_dir = ctx.home / ".wallpapers";
    auto on_disk = [&](const std::string& name) {
        std::error_code ec;
        return fs::is_regular_file(wall_dir / name, ec);
    };

    // Active wallpaper: what the desktop shows (.current), else the WALLPAPER
    // env, else the first path= in the existing block.
    std::string active = fox_monitor::apply::current_base(wall_dir);
    if (!active.empty() && !on_disk(active)) active.clear();
    if (active.empty())
        if (const char* env = std::getenv("WALLPAPER"); env && *env) active = env;
    if (active.empty()) {
        for (const auto& line : first_background(body)) {
            std::string k, v;
            if (key_value(line, k, v) && k == "path") { active = fs::path(v).filename().string(); break; }
        }
    }
    active = active.empty() ? active : lock_source_name(active);
    const std::string theme_default = palette::get(ctx.palette_path, "WALLPAPER", "");
    if (active.empty() && theme_default.empty()) return false;

    std::string tail = fs::exists(rendered) ? background_tail(read_text(rendered)) : "";
    if (tail.empty()) tail = background_tail(body);

    std::size_t fallbacks = 0;
    const std::string new_blocks = background_blocks(layout.monitor_resolutions, active,
                                                     theme_default, tail, on_disk, fallbacks);
    if (new_blocks.empty()) return false;
    std::size_t mons = 0;
    for (auto p = new_blocks.find("background {"); p != std::string::npos;
         p = new_blocks.find("background {", p + 1)) ++mons;

    // Splice into both the live config and the rendered copy (each only if
    // present). Updating the rendered copy keeps detect_drift() seeing the
    // automated personalisation as "intended" next run rather than a manual live
    // edit — and is what personalizes a FRESH box (live not deployed yet, so
    // symlinks deploys the spliced rendered copy).
    if (fs::exists(hyprlock)) splice_sentinel(hyprlock, BG_BEGIN, BG_END, new_blocks);
    if (fs::exists(rendered)) splice_sentinel(rendered, BG_BEGIN, BG_END, new_blocks);

    if (fallbacks > 0) {
        ui::ok("hyprlock personalised for " + std::to_string(mons) +
               " monitor(s) (" + std::to_string(fallbacks) + " without a wallpaper cut for that size)");
    } else {
        ui::ok("hyprlock personalised for " + std::to_string(mons) + " monitor(s)");
    }
    return true;
}

// ─── hyprlock login panel → PRIMARY ────────────────────────────────
// The foreground blocks (brand, dots, clock, date, input-field, battery)
// ship with `monitor =` empty, which hyprlock reads as "draw on every
// output" — duplicating the whole panel (and the input-field, which spawns
// one password widget per monitor). Pin them to the primary so the panel
// lives on one screen and the rest show only their blurred wallpaper.
std::string pin_foreground_monitors(const std::string& body,
                                    const std::string& primary) {
    if (primary.empty()) return body;

    const std::string b_sentinel = "# foxml:hyprlock-backgrounds-begin";
    const std::string e_sentinel = "# foxml:hyprlock-backgrounds-end";

    std::istringstream iss(body);
    std::ostringstream out;
    std::string line;
    bool in_bg = false;
    // Preserve the input's final-newline shape (getline drops it).
    bool trailing_nl = !body.empty() && body.back() == '\n';
    std::vector<std::string> lines;
    while (std::getline(iss, line)) lines.push_back(line);

    for (std::size_t i = 0; i < lines.size(); ++i) {
        std::string& l = lines[i];
        if (l.find(b_sentinel) != std::string::npos)      in_bg = true;
        else if (l.find(e_sentinel) != std::string::npos) in_bg = false;
        else if (!in_bg) {
            // Match a line whose first non-space token is `monitor` then `=`.
            auto first = l.find_first_not_of(" \t");
            if (first != std::string::npos &&
                l.compare(first, 7, "monitor") == 0) {
                auto after = l.find_first_not_of(" \t", first + 7);
                if (after != std::string::npos && l[after] == '=') {
                    l = l.substr(0, first) + "monitor = " + primary;
                }
            }
        }
        out << l;
        if (i + 1 < lines.size() || trailing_nl) out << "\n";
    }
    return out.str();
}

bool pin_hyprlock_panel(const Context& ctx, const sidecar::Layout& layout) {
    if (layout.primary.empty()) return false;

    auto apply = [&](const fs::path& p) -> bool {
        if (!fs::exists(p)) return false;
        std::string body;
        {
            std::ifstream in(p);
            body.assign((std::istreambuf_iterator<char>(in)),
                         std::istreambuf_iterator<char>());
        }
        std::string updated = pin_foreground_monitors(body, layout.primary);
        if (updated == body) return false;

        fs::path tmp = p;
        tmp += ".foxin.tmp";
        { std::ofstream w(tmp); w << updated; }
        std::error_code ec;
        fs::rename(tmp, p, ec);
        if (ec) { fs::remove(tmp); return false; }
        return true;
    };

    bool live     = apply(ctx.config_home / "hypr/hyprlock.conf");
    bool rendered = apply(ctx.rendered_dir / "hyprlock/hyprlock.conf");
    if (live || rendered) ui::ok("hyprlock panel pinned → " + layout.primary);
    return live || rendered;
}

// ─── workspace 1 pin → PRIMARY ─────────────────────────────────────
bool personalize_workspace_rules(const Context& ctx, const sidecar::Layout& layout) {
    fs::path rules = ctx.config_home / "hypr/modules/rules.conf";
    fs::path rendered = ctx.rendered_dir / "hyprland/rules.conf";
    fs::path rules_lua = ctx.config_home / "hypr/modules/rules.lua";   // Hyprland 0.57+

    // Personalize whichever copies exist — on a fresh box the live rules.conf is
    // not deployed yet (symlinks runs after personalize), so splice the rendered
    // copy and let symlinks deploy it; on a re-run the live copy exists →
    // identical to the prior behaviour. Gate on either being present.
    if (!fs::exists(rules) && !fs::exists(rendered) && !fs::exists(rules_lua)) return false;
    if (layout.primary.empty())                      return false;

    std::string new_line = "workspace = 1, monitor:" + layout.primary +
                           ", default:true";

    const std::string b_sentinel = "# foxml:workspace-pin-begin";
    const std::string e_sentinel = "# foxml:workspace-pin-end";
    if (fs::exists(rules))    splice_sentinel(rules, b_sentinel, e_sentinel, new_line);
    if (fs::exists(rendered)) splice_sentinel(rendered, b_sentinel, e_sentinel, new_line);
    if (fs::exists(rules_lua))
        splice_sentinel(rules_lua, hypr_lua::PIN_BEGIN, hypr_lua::PIN_END,
                        hypr_lua::workspace_pin_lua(layout.primary));

    ui::ok("workspace pin → " + layout.primary);
    return true;
}

void apply_all(const Context& ctx, const sidecar::Layout& layout) {
    generate_per_monitor_wallpapers(ctx, layout);
    personalize_hyprlock(ctx, layout);
    pin_hyprlock_panel(ctx, layout);
    personalize_workspace_rules(ctx, layout);

    // W1 (monitor-polish): re-apply the live wallpaper to the (possibly
    // reconfigured) layout in the SAME run. generate_per_monitor_wallpapers bakes
    // the variants but never re-applies, so a wizard rotation left the pre-rotation
    // LANDSCAPE image on a now-portrait output (the black-bar letterbox). Gated on
    // an existing .current so it targets the live-reconfigure case and stays silent
    // on a fresh box (no .current until first login's rotate_wallpaper.sh). This is
    // the reactive-refresh-omission fix: the wizard is a trigger that changes the
    // layout, so it must re-apply exactly as `desk-monitor reconcile` does.
    fs::path wall_dir = ctx.home / ".wallpapers";
    if (!fox_monitor::apply::current_base(wall_dir).empty())
        fox_monitor::apply::apply_current(layout, wall_dir, sh::dry_run());
}

}  // namespace fox_install::personalize

// Module entry point (registered in modules.def).
namespace fox_install {

namespace sidecar = fox_monitor::sidecar;

void run_personalize(Context& ctx) {
    ui::section("Personalizing for this machine");

    fs::path layout_path = ctx.config_home / "foxml/monitor-layout.conf";
    auto layout = sidecar::read(layout_path);
    if (layout.primary.empty() && layout.monitor_resolutions.empty()) {
        ui::warn("no monitor-layout.conf — run --monitors first or open a Hyprland session");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would generate per-monitor wallpapers + rewrite hyprlock + rules.conf");
        return;
    }

    personalize::apply_all(ctx, layout);
}

}  // namespace fox_install
