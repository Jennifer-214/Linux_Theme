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

#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <regex>
#include <set>
#include <sstream>
#include <string>
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

// Helper to apply the same splice logic to two files (e.g. config and rendered).
bool splice_file(const fs::path& p, const std::string& begin_sentinel,
                 const std::string& end_sentinel, const std::string& new_content) {
    if (!fs::exists(p)) return false;
    std::ifstream in(p);
    std::string body((std::istreambuf_iterator<char>(in)),
                      std::istreambuf_iterator<char>());
    in.close();

    if (body.find(begin_sentinel) == std::string::npos) return false;

    std::istringstream iss(body);
    std::ostringstream out;
    std::string line;
    bool skip = false;
    while (std::getline(iss, line)) {
        if (line.find(begin_sentinel) != std::string::npos) {
            out << line << "\n" << new_content << "\n";
            skip = true;
            continue;
        }
        if (line.find(end_sentinel) != std::string::npos) {
            skip = false;
            out << line << "\n";
            continue;
        }
        if (!skip) out << line << "\n";
    }

    fs::path tmp = p;
    tmp += ".foxin.tmp";
    {
        std::ofstream w(tmp);
        w << out.str();
    }
    std::error_code ec;
    fs::rename(tmp, p, ec);
    if (ec) { fs::remove(tmp); return false; }
    return true;
}

}  // namespace

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

    // Regex matching `_WxH` suffix to skip prior-run outputs.
    std::regex variant_suffix(R"(_[0-9]+x[0-9]+$)");

    size_t generated = 0;
    for (auto& entry : fs::directory_iterator(wall_dir)) {
        if (!entry.is_regular_file()) continue;
        std::string base = entry.path().filename().string();
        std::string ext  = entry.path().extension().string();
        if (ext.size() > 1) ext.erase(0, 1);
        // Case-fold ext for jpg/jpeg/png comparison (matches `nocaseglob`).
        std::string lo = ext;
        std::transform(lo.begin(), lo.end(), lo.begin(),
                       [](unsigned char c){ return std::tolower(c); });
        if (lo != "jpg" && lo != "jpeg" && lo != "png") continue;

        std::string name = entry.path().stem().string();
        if (name.size() >= 9 && name.compare(name.size() - 9, 9, "_portrait") == 0)
            continue;
        if (std::regex_search(name, variant_suffix))
            continue;

        for (auto& res : resolutions) {
            int w = 0, h = 0;
            if (!parse_res(res, w, h)) continue;
            fs::path out = wall_dir / (name + "_" + res + "." + ext);
            if (fs::exists(out)) continue;
            // Variant pixel size is 2× the monitor's reported resolution.
            // Filename stays keyed to the monitor res (so rotate_wallpaper.sh's
            // lookup still works), but the file holds 2× pixels — gives clean
            // results when the compositor renders at HiDPI scale 2.0 or
            // when the monitor is later swapped for a higher-DPI panel.
            // Compositor downsamples for 1× displays with no visible cost.
            std::string target = std::to_string(2 * w) + "x" + std::to_string(2 * h);
            int rc = sh::run({
                magick, entry.path().string(),
                "-resize", target + "^",
                "-gravity", "center",
                "-extent", target,
                out.string(),
            });
            if (rc == 0) ++generated;
        }
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
    if (!fs::exists(hyprlock))               return false;
    if (layout.monitor_resolutions.empty())  return false;

    std::string body;
    {
        std::ifstream in(hyprlock);
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

    // Splice into both the live config and the rendered copy. Updating the
    // rendered copy ensures detect_drift() sees the automated
    // personalisation as "intended" on the next run, rather than flagging
    // it as a manual live edit.
    const std::string b_sentinel = "# foxml:hyprlock-backgrounds-begin";
    const std::string e_sentinel = "# foxml:hyprlock-backgrounds-end";
    splice_file(hyprlock, b_sentinel, e_sentinel, new_blocks);
    splice_file(rendered, b_sentinel, e_sentinel, new_blocks);

    if (fallbacks > 0) {
        ui::ok("hyprlock personalised for " + std::to_string(mons) +
               " monitor(s) (" + std::to_string(fallbacks) + " on source-fallback)");
    } else {
        ui::ok("hyprlock personalised for " + std::to_string(mons) + " monitor(s)");
    }
    return true;
}

// ─── workspace 1 pin → PRIMARY ─────────────────────────────────────
bool personalize_workspace_rules(const Context& ctx, const sidecar::Layout& layout) {
    fs::path rules = ctx.config_home / "hypr/modules/rules.conf";
    // rules.conf is a shared module, so its rendered copy lives in shared_dir
    // if not using --render. But wait, it might be in TEMPLATE_MAPPINGS too.
    // Check rendered_dir first.
    fs::path rendered = ctx.rendered_dir / "hyprland/rules.conf";

    if (!fs::exists(rules))            return false;
    if (layout.primary.empty())        return false;

    std::string new_line = "workspace = 1, monitor:" + layout.primary +
                           ", default:true";
    
    const std::string b_sentinel = "# foxml:workspace-pin-begin";
    const std::string e_sentinel = "# foxml:workspace-pin-end";
    splice_file(rules, b_sentinel, e_sentinel, new_line);
    splice_file(rendered, b_sentinel, e_sentinel, new_line);

    ui::ok("workspace pin → " + layout.primary);
    return true;
}

void apply_all(const Context& ctx, const sidecar::Layout& layout) {
    generate_per_monitor_wallpapers(ctx, layout);
    personalize_hyprlock(ctx, layout);
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
