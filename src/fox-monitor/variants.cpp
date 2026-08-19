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

#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <fstream>
#include <regex>
#include <system_error>

namespace fs = std::filesystem;
namespace sh = fox_install::sh;
namespace ui = fox_install::ui;

namespace fox_monitor::variants {

namespace {

// Bump when the variant RECIPE changes (e.g. Lanczos cover-crop -> ESRGAN region
// upscale) so the next generate() regenerates every variant ONCE, then stays
// stable. Persisted in wall_dir/.variant-recipe — this is what lets the installer
// and `reconcile` auto-upgrade existing variants on a recipe change WITHOUT
// re-upscaling on every reinstall (which would fight the frictionless-reinstall goal).
constexpr const char* RECIPE_VERSION = "esrgan-region-s4-v1";

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

// ─── pure crop geometry ────────────────────────────────────────────
bool crop_upscales(int sw, int sh, int tw, int th) {
    if (sw <= 0 || sh <= 0 || tw <= 0 || th <= 0) return false;
    double sx = static_cast<double>(tw) / sw;
    double sy = static_cast<double>(th) / sh;
    return std::max(sx, sy) > 1.0;
}

void crop_region(int sw, int sh, int tw, int th, int& rw, int& rh) {
    rw = rh = 0;
    if (sw <= 0 || sh <= 0 || tw <= 0 || th <= 0) return;
    double tar_aspect = static_cast<double>(tw) / th;
    if (static_cast<double>(sw) / sh > tar_aspect) {
        rh = sh;
        rw = static_cast<int>(std::lround(sh * tar_aspect));
    } else {
        rw = sw;
        rh = static_cast<int>(std::lround(sw / tar_aspect));
    }
}

bool esrgan_available() {
    return sh::have("realesrgan-ncnn-vulkan");
}

// ─── per-monitor wallpaper variants ────────────────────────────────
std::size_t generate(const fs::path& wall_dir,
                     const std::vector<std::string>& monitor_resolutions,
                     bool dry_run,
                     bool force) {
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

    // Recipe-version stamp. If the recipe changed since the last run (or the
    // stamp is absent — e.g. variants made by an older Lanczos-only build, or a
    // brand-new box), treat this run as a force: regenerate every variant once so
    // they all adopt the current recipe, then write the stamp so the NEXT run
    // skips the full regen. No re-upscaling when the recipe is unchanged.
    const fs::path recipe_stamp = wall_dir / ".variant-recipe";
    bool recipe_changed = false;
    {
        std::ifstream in(recipe_stamp);
        std::string prev;
        if (in) std::getline(in, prev);
        recipe_changed = (prev != RECIPE_VERSION);
    }
    const bool effective_force = force || recipe_changed;

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
            // Skip the probe (a read-only identify subprocess) under dry-run
            // OR force: an empty map makes the planner preview/regenerate every
            // variant as a Generate (dry-run = honest "what would happen";
            // force = regenerate all, bypassing the dims-match skip).
            if (dry_run || effective_force) continue;
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
        const std::string target =
            std::to_string(act.w) + "x" + std::to_string(act.h);

        // Plain Lanczos cover-crop+extent. Used directly for DOWNSCALING crops
        // (byte-identical to the prior behavior) and as the lambda the
        // upscaling branch falls back to on any ESRGAN/magick failure.
        auto run_lanczos_downscale = [&]() -> int {
            return sh::run({
                magick, in_path.string(),
                "-resize", target + "^",
                "-gravity", "center",
                "-extent", target,
                out.string(),
            });
        };

        // Lanczos cover-crop + sharpen — the GPU-free fallback for an
        // UPSCALING crop (no ESRGAN, or any ESRGAN/magick step failed).
        auto run_lanczos_upscale = [&]() -> int {
            return sh::run({
                magick, in_path.string(),
                "-resize", target + "^",
                "-gravity", "center",
                "-extent", target,
                "-adaptive-sharpen", "0x1.4",
                "-unsharp", "0x0.8+0.6+0.01",
                out.string(),
            });
        };

        // Probe the SOURCE pixel dims (read-only identify — survives dry-run)
        // to decide upscale vs downscale per the proven recipe.
        int sw = 0, sh_px = 0;
        {
            std::vector<std::string> argv =
                (magick == "magick")
                    ? std::vector<std::string>{"magick", "identify", "-format",
                                               "%wx%h", in_path.string()}
                    : std::vector<std::string>{"identify", "-format",
                                               "%wx%h", in_path.string()};
            std::string dims;
            if (sh::capture(argv, dims)) {
                while (!dims.empty() &&
                       (dims.back() == '\n' || dims.back() == '\r' ||
                        dims.back() == ' '  || dims.back() == '\t')) {
                    dims.pop_back();
                }
                parse_res(dims, sw, sh_px);  // sw/sh_px stay 0 on parse failure
            }
        }

        const bool upscales = crop_upscales(sw, sh_px, act.w, act.h);

        if (!upscales) {
            // DOWNSCALING (or unprobeable source) crop — unchanged.
            if (run_lanczos_downscale() == 0) ++generated;
            continue;
        }

        // UPSCALING crop. Prefer the Real-ESRGAN region path; fall back to
        // Lanczos+sharpen when ESRGAN is unavailable or any step fails.
        const bool use_esrgan = esrgan_available();

        if (dry_run) {
            // Mirror sh::run's dry-run logging: print the planned command(s)
            // for the chosen path WITHOUT executing (no GPU, no FS writes).
            if (use_esrgan) {
                int rw = 0, rh = 0;
                crop_region(sw, sh_px, act.w, act.h, rw, rh);
                const std::string region =
                    std::to_string(rw) + "x" + std::to_string(rh);
                ui::substep("would crop region [" + magick + " " +
                            in_path.string() + " -gravity center -crop " +
                            region + "+0+0 +repage <tmp_region>]");
                ui::substep("would upscale [realesrgan-ncnn-vulkan -i "
                            "<tmp_region> -o <tmp_up> -n realesrgan-x4plus "
                            "-s 4]");
                ui::substep("would finalize [" + magick + " <tmp_up> -resize " +
                            target + " -unsharp 0x0.7+0.5+0.01 " +
                            out.string() + "]");
            } else {
                ui::substep("would Lanczos-upscale [" + magick + " " +
                            in_path.string() + " -resize " + target +
                            "^ -gravity center -extent " + target +
                            " -adaptive-sharpen 0x1.4 -unsharp 0x0.8+0.6+0.01 " +
                            out.string() + "]");
            }
            ++generated;
            continue;
        }

        if (!use_esrgan) {
            if (run_lanczos_upscale() == 0) ++generated;
            continue;
        }

        // ── live ESRGAN region path ──────────────────────────────────
        // 1. crop the centered source region at the target aspect.
        // 2. realesrgan-ncnn-vulkan -s 4 on the smaller region (the -s 2
        //    path checkerboards on low-VRAM cards; -s 4 stays clean).
        // 3. resize the upscaled region to the exact target + a mild unsharp.
        // Temp files live under the system temp dir with unique names; any
        // failure (nonzero rc / missing output) falls through to Lanczos.
        int rw = 0, rh = 0;
        crop_region(sw, sh_px, act.w, act.h, rw, rh);
        const std::string region = std::to_string(rw) + "x" + std::to_string(rh);

        std::error_code ec;
        fs::path tmp_dir = fs::temp_directory_path(ec);
        std::string ext_lc;
        {
            std::string s, e;
            split_name(act.out_file, s, e);
            ext_lc = e.empty() ? "png" : e;
        }
        const std::string stamp = std::to_string(::getpid()) + "_" +
                                  std::to_string(generated) + "_" + region;
        fs::path tmp_region = tmp_dir / ("foxvar_region_" + stamp + "." + ext_lc);
        fs::path tmp_up     = tmp_dir / ("foxvar_up_" + stamp + ".png");

        bool esrgan_ok = false;
        if (!ec) {
            int rc1 = sh::run({
                magick, in_path.string(),
                "-gravity", "center",
                "-crop", region + "+0+0",
                "+repage", tmp_region.string(),
            });
            if (rc1 == 0 && fs::exists(tmp_region)) {
                int rc2 = sh::run({
                    "realesrgan-ncnn-vulkan",
                    "-i", tmp_region.string(),
                    "-o", tmp_up.string(),
                    "-n", "realesrgan-x4plus",
                    "-s", "4",
                });
                if (rc2 == 0 && fs::exists(tmp_up)) {
                    int rc3 = sh::run({
                        magick, tmp_up.string(),
                        "-resize", target,
                        "-unsharp", "0x0.7+0.5+0.01",
                        out.string(),
                    });
                    esrgan_ok = (rc3 == 0 && fs::exists(out));
                }
            }
        }

        // Best-effort temp cleanup regardless of outcome.
        std::error_code rmec;
        fs::remove(tmp_region, rmec);
        fs::remove(tmp_up, rmec);

        if (esrgan_ok) {
            ++generated;
        } else {
            ui::warn("ESRGAN upscale failed for " + act.out_file +
                     " — falling back to Lanczos+sharpen");
            if (run_lanczos_upscale() == 0) ++generated;
        }
    }
    // Stamp the current recipe after a real run so the one-time full regen does
    // not repeat next time (until the recipe changes again). Dry-run never writes.
    if (!dry_run) {
        std::ofstream out(recipe_stamp);
        if (out) out << RECIPE_VERSION << "\n";
    }
    if (generated > 0) {
        ui::ok(std::to_string(generated) + " per-monitor wallpaper variant(s) generated");
    }
    return generated;
}

}  // namespace fox_monitor::variants
