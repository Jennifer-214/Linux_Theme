// Characterization test for the PURE per-monitor variant planner
// (variants.cpp:plan_variants).
//
// Pins the NEW contract (Slice B): variants render at NATIVE w×h (not the
// retired 2× legacy), resolutions dedupe across monitors, _portrait/_WxH
// inputs never enter the base list (so they're never processed here), an
// existing variant at native dims is a no-op, a wrong-dims existing variant
// force-regens, and an orphaned `<base>_<WxH>` variant whose res left the set
// is pruned. No imagemagick, no filesystem — fixtures are in-memory args.

#include "../variants.hpp"

#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

using namespace fox_monitor::variants;

namespace {

int failed = 0;

void check(const char* what, bool ok) {
    if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); ++failed; }
}

// Find a Generate action for a given output filename; nullptr if absent.
const VariantAction* find_gen(const std::vector<VariantAction>& acts,
                              const std::string& out) {
    for (const auto& a : acts)
        if (a.kind == VariantAction::Generate && a.out_file == out) return &a;
    return nullptr;
}

bool has_prune(const std::vector<VariantAction>& acts, const std::string& out) {
    for (const auto& a : acts)
        if (a.kind == VariantAction::Prune && a.out_file == out) return true;
    return false;
}

std::size_t count_gen(const std::vector<VariantAction>& acts,
                      const std::string& out) {
    std::size_t n = 0;
    for (const auto& a : acts)
        if (a.kind == VariantAction::Generate && a.out_file == out) ++n;
    return n;
}

}  // namespace

int main() {
    // (a) Generate target dims are NATIVE (w×h, NOT 2w×2h). The whole point
    //     of Slice B — guards the deleted `2 *`.
    {
        std::set<std::string> res = {"1920x1080"};
        std::vector<std::string> bases = {"wall.jpg"};
        std::map<std::string, std::pair<int, int>> existing;  // none yet
        auto acts = plan_variants(res, bases, existing);
        const VariantAction* g = find_gen(acts, "wall_1920x1080.jpg");
        check("(a) native variant planned", g != nullptr);
        if (g) {
            check("(a) native dims w==1920", g->w == 1920);
            check("(a) native dims h==1080", g->h == 1080);
            check("(a) NOT 2x width", g->w != 3840);
            check("(a) NOT 2x height", g->h != 2160);
            check("(a) src is the base file", g->src_base_file == "wall.jpg");
        }
    }

    // (b) Two monitors at the SAME res → ONE Generate (dedupe). The caller
    //     hands plan_variants a std::set, so identical res collapse to one.
    {
        std::set<std::string> res = {"1920x1080"};  // two eDP+HDMI both 1080p
        std::vector<std::string> bases = {"wall.png"};
        std::map<std::string, std::pair<int, int>> existing;
        auto acts = plan_variants(res, bases, existing);
        check("(b) dedupe → exactly one Generate",
              count_gen(acts, "wall_1920x1080.png") == 1);
    }

    // (c) A _portrait base and an already-_WxH base in the input list are NOT
    //     processed. (The executor filters these out of base_files before the
    //     planner sees them — so the contract here is: given a base list that
    //     ALREADY excludes them, the planner produces no variant keyed off a
    //     _portrait or _WxH stem. We feed ONLY a clean base + assert nothing
    //     spurious appears, then feed a list with them stripped per contract.)
    {
        std::set<std::string> res = {"1920x1080"};
        // Per the executor contract, _portrait and _WxH never reach plan_variants
        // as bases — so the base list is just the clean source.
        std::vector<std::string> bases = {"wall.jpg"};
        std::map<std::string, std::pair<int, int>> existing;
        auto acts = plan_variants(res, bases, existing);
        // No variant should be derived from a _portrait or _WxH stem.
        for (const auto& a : acts) {
            check("(c) no _portrait-derived variant",
                  a.out_file.find("_portrait_") == std::string::npos);
            // a clean source variant is `wall_1920x1080.jpg`; a double-suffix
            // like `wall_1920x1080_1920x1080.jpg` would mean a _WxH input leaked in.
            check("(c) no double-WxH variant",
                  a.out_file != "wall_1920x1080_1920x1080.jpg");
        }
        check("(c) exactly the one clean variant Generated",
              count_gen(acts, "wall_1920x1080.jpg") == 1 && acts.size() == 1);
    }

    // (d) An existing variant with matching NATIVE dims → NO action (skip).
    {
        std::set<std::string> res = {"1920x1080"};
        std::vector<std::string> bases = {"wall.jpg"};
        std::map<std::string, std::pair<int, int>> existing = {
            {"wall_1920x1080.jpg", {1920, 1080}},  // already native
        };
        auto acts = plan_variants(res, bases, existing);
        check("(d) native-match → no Generate",
              find_gen(acts, "wall_1920x1080.jpg") == nullptr);
        check("(d) native-match → no Prune (res still wanted)",
              !has_prune(acts, "wall_1920x1080.jpg"));
        check("(d) native-match → empty plan", acts.empty());
    }

    // (e) An existing variant with WRONG dims (e.g. 2× legacy 3840x2160) →
    //     Generate (force-regen / size-class convergence).
    {
        std::set<std::string> res = {"1920x1080"};
        std::vector<std::string> bases = {"wall.jpg"};
        std::map<std::string, std::pair<int, int>> existing = {
            {"wall_1920x1080.jpg", {3840, 2160}},  // legacy 2× pixels
        };
        auto acts = plan_variants(res, bases, existing);
        const VariantAction* g = find_gen(acts, "wall_1920x1080.jpg");
        check("(e) wrong-dims → force-regen Generate", g != nullptr);
        if (g) {
            check("(e) regen at NATIVE w", g->w == 1920);
            check("(e) regen at NATIVE h", g->h == 1080);
        }
    }

    // (f) An existing `<base>_999x999` whose res is ABSENT from the set → Prune.
    {
        std::set<std::string> res = {"1920x1080"};
        std::vector<std::string> bases = {"wall.jpg"};
        std::map<std::string, std::pair<int, int>> existing = {
            {"wall_1920x1080.jpg", {1920, 1080}},  // wanted res, native → no-op
            {"wall_999x999.jpg",   {999, 999}},    // orphaned res → prune
        };
        auto acts = plan_variants(res, bases, existing);
        check("(f) orphan res → Prune", has_prune(acts, "wall_999x999.jpg"));
        check("(f) wanted-native → no Prune",
              !has_prune(acts, "wall_1920x1080.jpg"));
        check("(f) wanted-native → no Generate",
              find_gen(acts, "wall_1920x1080.jpg") == nullptr);
        check("(f) plan is exactly the one Prune", acts.size() == 1);
    }

    // Extra: mixed landscape+portrait-shaped resolutions both Generate at
    //        their own native dims (a portrait monitor reports 2160x3840).
    {
        std::set<std::string> res = {"1920x1080", "2160x3840"};
        std::vector<std::string> bases = {"wall.jpg"};
        std::map<std::string, std::pair<int, int>> existing;
        auto acts = plan_variants(res, bases, existing);
        const VariantAction* a = find_gen(acts, "wall_1920x1080.jpg");
        const VariantAction* b = find_gen(acts, "wall_2160x3840.jpg");
        check("(x) landscape variant native", a && a->w == 1920 && a->h == 1080);
        check("(x) portrait variant native",  b && b->w == 2160 && b->h == 3840);
    }

    // (g) crop_upscales — the proven recipe's upscale predicate.
    {
        // Tall portrait FROM a landscape source → UPSCALES (th/sh > 1).
        check("(g) portrait-from-landscape upscales",
              crop_upscales(3840, 2160, 2160, 3840) == true);
        // A smaller landscape crop FROM a larger landscape → DOWNSCALES.
        check("(g) landscape-from-larger downscales",
              crop_upscales(3840, 2160, 1920, 1080) == false);
        // Equal dims → no upscale (both scales == 1.0, strict > fails).
        check("(g) equal dims no upscale",
              crop_upscales(3840, 2160, 3840, 2160) == false);
        // Zero/invalid dims → false (safe Lanczos path).
        check("(g) zero source dims → false",
              crop_upscales(0, 0, 2160, 3840) == false);
        check("(g) zero target dims → false",
              crop_upscales(3840, 2160, 0, 3840) == false);
    }

    // (h) crop_region — centered region at the target aspect, keeping the
    //     limiting source dimension.
    {
        int rw = -1, rh = -1;
        // 3840x2160 source → 2160x3840 (portrait) target: source is wider than
        // the target shape, so keep full HEIGHT (rh=2160) and rw=round(2160 *
        // 2160/3840) = round(1215) = 1215.
        crop_region(3840, 2160, 2160, 3840, rw, rh);
        check("(h) portrait region rw==1215", rw == 1215);
        check("(h) portrait region rh==2160", rh == 2160);

        // Guard against zero dims → region stays {0,0}.
        rw = -1; rh = -1;
        crop_region(0, 2160, 2160, 3840, rw, rh);
        check("(h) zero source dim → rw==0", rw == 0);
        check("(h) zero source dim → rh==0", rh == 0);

        // A 1920x1080 target from a 3840x2160 source is a DOWNSCALE — the
        // executor would NOT take the ESRGAN region path at all.
        check("(h) downscale target → crop_upscales false",
              crop_upscales(3840, 2160, 1920, 1080) == false);
    }

    if (failed == 0) std::printf("test_variants: OK\n");
    return failed ? 1 : 0;
}
