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

#include "../core/splice.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install::personalize {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

std::string image_magick_bin() {
    if (have("magick"))  return "magick";
    if (have("convert")) return "convert";
    return {};
}

// Split "WxH" → {w, h}. Returns false on parse failure.
bool parse_res(const std::string& wxh, int& w, int& h) {
    auto x = wxh.find('x');
    if (x == std::string::npos) return false;
    try {
        w = std::stoi(wxh.substr(0, x));
        h = std::stoi(wxh.substr(x + 1));
    } catch (...) { return false; }
    return w > 0 && h > 0;
}

// Split "<name>:<WxH>" — bash MONITOR_RESOLUTIONS shape.
bool parse_entry(const std::string& entry, std::string& name, std::string& res) {
    auto c = entry.find(':');
    if (c == std::string::npos) return false;
    name = entry.substr(0, c);
    res  = entry.substr(c + 1);
    return !name.empty() && !res.empty();
}

// Split "wall.jpg" → stem="wall", ext="jpg" (no leading dot). A dotless
// name yields an empty ext. Mirrors fs::path stem()/extension() but works
// on a plain filename string so the planner stays filesystem-free.
void split_name(const std::string& file, std::string& stem, std::string& ext) {
    auto dot = file.find_last_of('.');
    if (dot == std::string::npos || dot == 0) {  // dotless or dotfile
        stem = file;
        ext.clear();
    } else {
        stem = file.substr(0, dot);
        ext  = file.substr(dot + 1);
    }
}

// The sentinel splice helper now lives in core/splice.hpp (splice_sentinel),
// shared with the welcome_banner module.

}  // namespace

// ─── pure variant planner ──────────────────────────────────────────
std::vector<VariantAction> plan_variants(
    const std::set<std::string>& resolutions,
    const std::vector<std::string>& base_files,
    const std::map<std::string, std::pair<int, int>>& existing_variants) {

    std::vector<VariantAction> actions;

    // Generate (or skip) one variant per (base, res) at NATIVE dims.
    for (const auto& base : base_files) {
        std::string stem, ext;
        split_name(base, stem, ext);
        for (const auto& res : resolutions) {
            int w = 0, h = 0;
            if (!parse_res(res, w, h)) continue;
            std::string out =
                ext.empty() ? stem + "_" + res
                            : stem + "_" + res + "." + ext;
            auto it = existing_variants.find(out);
            if (it != existing_variants.end() &&
                it->second.first == w && it->second.second == h) {
                continue;  // already at native dims → no action
            }
            actions.push_back({VariantAction::Generate, base, out, w, h});
        }
    }

    // Prune existing `<base>_<WxH>` variants whose res left the set. We only
    // prune files that match a known base's `<stem>_<WxH>.<ext>` shape — a
    // safety net so we never remove an unrelated file.
    std::regex variant_suffix(R"(_([0-9]+x[0-9]+)$)");
    for (const auto& kv : existing_variants) {
        const std::string& fname = kv.first;
        std::string stem, ext;
        split_name(fname, stem, ext);
        std::smatch m;
        if (!std::regex_search(stem, m, variant_suffix)) continue;
        const std::string res = m[1].str();
        if (resolutions.count(res)) continue;  // res still wanted → keep
        actions.push_back({VariantAction::Prune, {}, fname, 0, 0});
    }

    return actions;
}

// ─── per-monitor wallpaper variants ────────────────────────────────
std::size_t generate_per_monitor_wallpapers(const Context& ctx,
                                            const sidecar::Layout& layout) {
    fs::path wall_dir = ctx.home / ".wallpapers";
    if (!fs::is_directory(wall_dir))       return 0;
    if (layout.monitor_resolutions.empty()) return 0;

    std::string magick = image_magick_bin();
    if (magick.empty()) {
        ui::warn("imagemagick missing — install imagemagick to enable per-monitor wallpapers");
        return 0;
    }

    // Dedupe resolutions across monitors — two 1920x1080 panels share one
    // rendered file (matches bash `declare -A seen_res`).
    std::set<std::string> resolutions;
    for (auto& entry : layout.monitor_resolutions) {
        std::string name, res;
        if (parse_entry(entry, name, res)) resolutions.insert(res);
    }
    if (resolutions.empty()) return 0;

    // Regex matching `_WxH` suffix to classify prior-run outputs (variants)
    // vs source images.
    std::regex variant_suffix(R"(_[0-9]+x[0-9]+$)");

    auto is_image = [](const std::string& ext) {
        std::string lo = ext;
        std::transform(lo.begin(), lo.end(), lo.begin(),
                       [](unsigned char c){ return std::tolower(c); });
        return lo == "jpg" || lo == "jpeg" || lo == "png";
    };

    // Two passes over the directory: collect base inputs (filter out
    // _portrait + _WxH variants) and probe existing-variant dims for the
    // planner. The planner itself touches neither the FS nor imagemagick.
    std::vector<std::string> base_files;
    std::map<std::string, std::pair<int, int>> existing_variants;

    for (auto& entry : fs::directory_iterator(wall_dir)) {
        if (!entry.is_regular_file()) continue;
        std::string fname = entry.path().filename().string();
        std::string ext   = entry.path().extension().string();
        if (ext.size() > 1) ext.erase(0, 1);
        if (!is_image(ext)) continue;

        std::string stem = entry.path().stem().string();

        if (std::regex_search(stem, variant_suffix)) {
            // Existing variant — probe its real pixel dims for the planner.
            // Skip the probe (a read-only identify subprocess) under dry-run:
            // an empty map makes the planner preview every variant as a
            // Generate, which is the honest "what would happen" output.
            if (sh::dry_run()) continue;
            // `magick identify ...` vs the legacy `identify ...` argv.
            std::vector<std::string> argv =
                (magick == "magick")
                    ? std::vector<std::string>{"magick", "identify", "-format",
                                               "%wx%h", entry.path().string()}
                    : std::vector<std::string>{"identify", "-format",
                                               "%wx%h", entry.path().string()};
            std::string dims;
            int vw = 0, vh = 0;
            if (sh::capture(argv, dims)) {
                while (!dims.empty() &&
                       (dims.back() == '\n' || dims.back() == '\r' ||
                        dims.back() == ' '  || dims.back() == '\t')) {
                    dims.pop_back();
                }
            }
            // Unprobeable (corrupt/unreadable) → {0,0} sentinel → the planner
            // force-regenerates it (dims != native target).
            existing_variants[fname] =
                parse_res(dims, vw, vh) ? std::make_pair(vw, vh)
                                        : std::make_pair(0, 0);
            continue;
        }

        if (stem.size() >= 9 && stem.compare(stem.size() - 9, 9, "_portrait") == 0)
            continue;

        base_files.push_back(fname);
    }

    auto actions = plan_variants(resolutions, base_files, existing_variants);

    size_t generated = 0;
    for (const auto& act : actions) {
        fs::path out = wall_dir / act.out_file;
        if (act.kind == VariantAction::Prune) {
            if (!sh::dry_run()) {
                std::error_code ec;
                fs::remove(out, ec);
            }
            continue;
        }
        fs::path in_path = wall_dir / act.src_base_file;
        // NATIVE dims — the variant file matches the monitor's reported
        // resolution exactly. The filename stays keyed to the monitor res so
        // rotate_wallpaper.sh's lookup still works.
        std::string target =
            std::to_string(act.w) + "x" + std::to_string(act.h);
        int rc = sh::run({
            magick, in_path.string(),
            "-resize", target + "^",
            "-gravity", "center",
            "-extent", target,
            out.string(),
        });
        if (rc == 0) ++generated;
    }
    if (generated > 0) {
        ui::ok(std::to_string(generated) + " per-monitor wallpaper variant(s) generated");
    }
    return generated;
}

// ─── hyprlock per-monitor background blocks ────────────────────────
// Reads the active wallpaper basename (palette WALLPAPER env or, when
// missing, the path= line inside the sentinel block), strips any prior
// _WxH suffix to walk back to the source filename, then rewrites every
// background { … } block between the sentinel pair.
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
    std::string body;
    {
        std::ifstream in(src);
        body.assign((std::istreambuf_iterator<char>(in)),
                     std::istreambuf_iterator<char>());
    }
    
    if (body.find("# foxml:hyprlock-backgrounds-begin") == std::string::npos) {
        ui::warn("hyprlock.conf missing sentinel — skipping personalisation");
        return false;
    }

    // Determine active wallpaper. WALLPAPER env (set by render.sh path)
    // is preferred; fall back to parsing the first path= line in the
    // sentinel range.
    std::string active;
    if (const char* env = std::getenv("WALLPAPER"); env && *env) active = env;
    if (active.empty()) {
        std::istringstream iss(body);
        std::string line;
        bool in_block = false;
        while (std::getline(iss, line)) {
            if (line.find("# foxml:hyprlock-backgrounds-begin") != std::string::npos)
                in_block = true;
            else if (line.find("# foxml:hyprlock-backgrounds-end") != std::string::npos)
                break;
            else if (in_block) {
                auto eq = line.find('=');
                if (eq != std::string::npos) {
                    std::string lhs = line.substr(0, eq);
                    // Tolerate leading whitespace before "path".
                    auto first = lhs.find_first_not_of(" \t");
                    if (first != std::string::npos &&
                        lhs.compare(first, 4, "path") == 0) {
                        std::string val = line.substr(eq + 1);
                        // Trim whitespace.
                        auto s = val.find_first_not_of(" \t");
                        if (s != std::string::npos) val.erase(0, s);
                        // Take basename.
                        auto slash = val.find_last_of('/');
                        if (slash != std::string::npos) val.erase(0, slash + 1);
                        active = val;
                        break;
                    }
                }
            }
        }
    }
    if (active.empty()) return false;

    // Strip _WxH suffix from the stem (variant → source).
    std::string ext;
    {
        auto dot = active.find_last_of('.');
        if (dot != std::string::npos) {
            ext = active.substr(dot + 1);
            active = active.substr(0, dot);
        }
    }
    std::regex variant_suffix(R"(_[0-9]+x[0-9]+$)");
    std::smatch m;
    if (std::regex_search(active, m, variant_suffix)) {
        active = active.substr(0, m.position(0));
    }
    std::string base   = active;
    std::string full   = base + (ext.empty() ? "" : "." + ext);

    const std::string block_tail =
        "    blur_size = 8\n"
        "    blur_passes = 3\n"
        "    vibrancy = 0.20\n"
        "    brightness = 0.45\n"
        "    contrast = 1.10";

    std::ostringstream blocks;
    size_t mons = 0, fallbacks = 0;
    for (auto& entry : layout.monitor_resolutions) {
        std::string name, res;
        if (!parse_entry(entry, name, res)) continue;
        std::string variant_disk = (ctx.home / ".wallpapers" /
                                    (base + "_" + res + "." + ext)).string();
        std::string variant_path = "~/.wallpapers/" + base + "_" + res + "." + ext;
        if (!fs::exists(variant_disk)) {
            variant_path = "~/.wallpapers/" + full;
            ++fallbacks;
        }
        blocks << "background {\n"
               << "    monitor = " << name << "\n"
               << "    path = "    << variant_path << "\n"
               << block_tail << "\n"
               << "}\n";
        ++mons;
    }
    if (mons == 0) return false;
    std::string new_blocks = blocks.str();
    if (!new_blocks.empty() && new_blocks.back() == '\n') new_blocks.pop_back();

    // Splice into both the live config and the rendered copy (each only if
    // present). Updating the rendered copy keeps detect_drift() seeing the
    // automated personalisation as "intended" next run rather than a manual live
    // edit — and is what personalizes a FRESH box (live not deployed yet, so
    // symlinks deploys the spliced rendered copy).
    const std::string b_sentinel = "# foxml:hyprlock-backgrounds-begin";
    const std::string e_sentinel = "# foxml:hyprlock-backgrounds-end";
    if (fs::exists(hyprlock)) splice_sentinel(hyprlock, b_sentinel, e_sentinel, new_blocks);
    if (fs::exists(rendered)) splice_sentinel(rendered, b_sentinel, e_sentinel, new_blocks);

    if (fallbacks > 0) {
        ui::ok("hyprlock personalised for " + std::to_string(mons) +
               " monitor(s) (" + std::to_string(fallbacks) + " on source-fallback)");
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

    // Personalize whichever copies exist — on a fresh box the live rules.conf is
    // not deployed yet (symlinks runs after personalize), so splice the rendered
    // copy and let symlinks deploy it; on a re-run the live copy exists →
    // identical to the prior behaviour. Gate on either being present.
    if (!fs::exists(rules) && !fs::exists(rendered)) return false;
    if (layout.primary.empty())                      return false;

    std::string new_line = "workspace = 1, monitor:" + layout.primary +
                           ", default:true";

    const std::string b_sentinel = "# foxml:workspace-pin-begin";
    const std::string e_sentinel = "# foxml:workspace-pin-end";
    if (fs::exists(rules))    splice_sentinel(rules, b_sentinel, e_sentinel, new_line);
    if (fs::exists(rendered)) splice_sentinel(rendered, b_sentinel, e_sentinel, new_line);

    ui::ok("workspace pin → " + layout.primary);
    return true;
}

void apply_all(const Context& ctx, const sidecar::Layout& layout) {
    generate_per_monitor_wallpapers(ctx, layout);
    personalize_hyprlock(ctx, layout);
    pin_hyprlock_panel(ctx, layout);
    personalize_workspace_rules(ctx, layout);
}

}  // namespace fox_install::personalize

// Module entry point (registered in modules.def).
namespace fox_install {

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
