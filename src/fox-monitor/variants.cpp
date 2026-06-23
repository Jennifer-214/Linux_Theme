// variants.cpp — per-monitor wallpaper-variant generator.
//
// Moved out of fox-install's personalize module (Slice C2) so the same
// planner+executor backs both the installer and the fox-monitor binary.
// The pure plan_variants() touches neither the FS nor imagemagick; generate()
// scans wall_dir, probes existing-variant dims via `magick identify`, calls
// the planner, and executes (magick resize/extent for Generate, remove for
// Prune).

#include "variants.hpp"

#include "../fox-common/shell.hpp"
#include "../fox-common/ui.hpp"

#include <algorithm>
#include <cctype>
#include <regex>
#include <system_error>

namespace fs = std::filesystem;
namespace sh = fox_install::sh;
namespace ui = fox_install::ui;

namespace fox_monitor::variants {

namespace {

std::string image_magick_bin() {
    if (sh::have("magick"))  return "magick";
    if (sh::have("convert")) return "convert";
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
std::size_t generate(const fs::path& wall_dir,
                     const std::vector<std::string>& monitor_resolutions,
                     bool dry_run) {
    if (!fs::is_directory(wall_dir))  return 0;
    if (monitor_resolutions.empty())  return 0;

    std::string magick = image_magick_bin();
    if (magick.empty()) {
        ui::warn("imagemagick missing — install imagemagick to enable per-monitor wallpapers");
        return 0;
    }

    // Dedupe resolutions across monitors — two 1920x1080 panels share one
    // rendered file (matches bash `declare -A seen_res`).
    std::set<std::string> resolutions;
    for (auto& entry : monitor_resolutions) {
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
            if (dry_run) continue;
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
            if (!dry_run) {
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

}  // namespace fox_monitor::variants
