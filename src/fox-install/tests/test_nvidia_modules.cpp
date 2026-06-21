// Tests for the nvidia mkinitcpio MODULES merge — the read-modify-write that
// replaced the destructive whole-line `sed s/^MODULES=(...)/MODULES=(nvidia …)/`.
// That sed WIPED a user's existing MODULES (encrypt/lvm2/vfio/…) → an initramfs
// missing boot-critical modules → UNBOOTABLE. It even PASSED the idempotency
// guard (a whole-line replace is a fixed point) — "idempotent ≠ non-destructive".
//
// The one guarantee every case pins: merge_modules NEVER drops an existing
// entry. Pure header → runs the REAL merge against fixtures; no VM, no sudo.

#include "../modules/nvidia_modules.hpp"

#include <algorithm>
#include <iostream>
#include <string>
#include <vector>

using namespace fox_install;

static int failures = 0;
#define EXPECT(cond) do { \
    if (!(cond)) { std::cerr << "  FAIL: " #cond " at line " << __LINE__ << "\n"; ++failures; } \
    else { std::cout << "  ok: " #cond "\n"; } \
} while (0)

static bool has(const std::vector<std::string>& v, const std::string& t) {
    return std::find(v.begin(), v.end(), t) != v.end();
}
static int count_of(const std::vector<std::string>& v, const std::string& t) {
    return static_cast<int>(std::count(v.begin(), v.end(), t));
}
static bool contains(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

int main() {
    std::cout << "test_nvidia_modules:\n";

    const std::vector<std::string> NV =
        {"nvidia", "nvidia_modeset", "nvidia_uvm", "nvidia_drm"};

    // ── 1. empty MODULES=() → all four nvidia, nothing else ────────────
    {
        auto t = parse_modules(merge_modules("MODULES=()\n"));
        for (auto& n : NV) EXPECT(has(t, n));
        EXPECT(t.size() == 4);
    }

    // ── 2. existing entries PRESERVED (the brick this fixes) ───────────
    {
        std::string in = "MODULES=(encrypt lvm2)\nHOOKS=(base udev)\n";
        std::string out = merge_modules(in);
        auto t = parse_modules(out);
        EXPECT(has(t, "encrypt"));          // <- the brick wiped these
        EXPECT(has(t, "lvm2"));
        for (auto& n : NV) EXPECT(has(t, n));
        EXPECT(t.size() == 6);
        EXPECT(t[0] == "encrypt");          // existing kept first, in order
        EXPECT(t[1] == "lvm2");
        EXPECT(contains(out, "HOOKS=(base udev)"));  // unrelated lines untouched
    }

    // ── 3. partial nvidia present → add only the missing, no dup ───────
    {
        auto t = parse_modules(merge_modules("MODULES=(encrypt lvm2 nvidia_drm)\n"));
        EXPECT(has(t, "encrypt"));
        EXPECT(has(t, "lvm2"));
        EXPECT(count_of(t, "nvidia_drm") == 1);   // not duplicated
        for (auto& n : NV) EXPECT(has(t, n));
    }

    // ── 4. all four present → idempotent no-op (fixed point) ───────────
    {
        std::string in = "MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n";
        std::string once = merge_modules(in);
        EXPECT(merge_modules(once) == once);          // merge∘merge == merge
        EXPECT(parse_modules(once).size() == 4);
    }

    // ── 5. multi-line array → merged, every entry preserved ────────────
    {
        std::string in = "MODULES=(\n  encrypt\n  lvm2\n)\n";
        auto t = parse_modules(merge_modules(in));
        EXPECT(has(t, "encrypt"));
        EXPECT(has(t, "lvm2"));
        for (auto& n : NV) EXPECT(has(t, n));
    }

    // ── 6. trailing comment after ) is preserved ───────────────────────
    {
        std::string out = merge_modules("MODULES=(encrypt)  # LUKS\n");
        EXPECT(contains(out, "# LUKS"));              // comment survives
        auto t = parse_modules(out);
        EXPECT(has(t, "encrypt"));
        EXPECT(has(t, "nvidia"));
    }

    // ── 7. no MODULES line → one is added, rest of file kept ───────────
    {
        std::string in = "# nvidia.conf\nBINARIES=()\nHOOKS=(base udev)\n";
        std::string out = merge_modules(in);
        auto t = parse_modules(out);
        for (auto& n : NV) EXPECT(has(t, n));
        EXPECT(contains(out, "HOOKS=(base udev)"));   // original kept
    }

    // ── 8. string/scalar form is NOT clobbered (safety) ────────────────
    {
        // Old pre-2019 string form. We don't understand it as an array, so we
        // must NOT bolt on a conflicting MODULES=() — leave it untouched and
        // let nvidia.cpp's self-check refuse the edit.
        std::string in = "MODULES=\"ext4\"\n";
        std::string out = merge_modules(in);
        EXPECT(out == in);                            // unchanged
        EXPECT(contains(out, "ext4"));                // not wiped
    }

    // ── 9. the GENERAL property: never drop ANY existing entry ─────────
    {
        // crc32c-intel exercises a hyphenated name — is_module_name must accept
        // it (a legit module), not bail.
        std::string in = "MODULES=(crc32c-intel encrypt lvm2 vfio_pci i915 nvme sd_mod)\n";
        std::string out = merge_modules(in);
        auto before = parse_modules(in);
        auto after  = parse_modules(out);
        EXPECT(before.size() == 7);                   // all read, incl. hyphenated
        for (auto& m : before) EXPECT(has(after, m)); // every original survives
        for (auto& n : NV)      EXPECT(has(after, n));
        EXPECT(merge_modules(out) == out);            // and still a fixed point
    }

    // ── 11. backslash line-continuation → refuse, don't mangle ─────────
    {
        // Legal shell (\ continues the line) but a single-line rewrite would
        // escape a space and mangle a neighbour (could drop a boot-critical
        // module). Bail UNCHANGED → nvidia.cpp skips; GPU still comes up via
        // modeset=1 + udev.
        std::string in = "MODULES=(encrypt \\\nlvm2)\n";
        std::string out = merge_modules(in);
        EXPECT(out == in);                            // refused, not mangled
        EXPECT(contains(out, "encrypt"));
        EXPECT(contains(out, "lvm2"));
    }

    // ── 12. unclosed array → never swallow the following line ──────────
    {
        // array_close grabs the next line's ) — but that line's token fails the
        // identifier check, so we bail UNCHANGED instead of deleting HOOKS.
        std::string in = "MODULES=(encrypt\nHOOKS=(base udev)\n";
        std::string out = merge_modules(in);
        EXPECT(out == in);                            // unchanged
        EXPECT(contains(out, "HOOKS=(base udev)"));   // HOOKS preserved
    }

    // ── 10. parse handles comments inside the array ────────────────────
    {
        auto t = parse_modules("MODULES=(encrypt  # luks\n  lvm2)\n");
        EXPECT(t.size() == 2);
        EXPECT(t[0] == "encrypt");
        EXPECT(t[1] == "lvm2");
    }

    // ── 11. rewrite_aq_line — AQ_DRM_DEVICES active iff the resolve is complete ─
    {
        // complete Optimus → active, both cards
        EXPECT(rewrite_aq_line("env = AQ_DRM_DEVICES, /dev/dri/by-path/x",
                               "/dev/dri/card1:/dev/dri/card0", true)
               == "env = AQ_DRM_DEVICES, /dev/dri/card1:/dev/dri/card0");
        // partial (single card) → COMMENTED so Aquamarine auto-detects (the fix:
        // a single-card value blacks the iGPU-wired eDP on an Optimus box)
        EXPECT(rewrite_aq_line("env = AQ_DRM_DEVICES, /dev/dri/by-path/x",
                               "/dev/dri/card1", false)
               == "# env = AQ_DRM_DEVICES, /dev/dri/card1");
        // re-activate an already-commented (inert template) line on a complete resolve
        EXPECT(rewrite_aq_line("# env = AQ_DRM_DEVICES, /dev/dri/by-path/x",
                               "/dev/dri/card1:/dev/dri/card0", true)
               == "env = AQ_DRM_DEVICES, /dev/dri/card1:/dev/dri/card0");
        // stays commented on a partial resolve
        EXPECT(rewrite_aq_line("# env = AQ_DRM_DEVICES, /dev/dri/by-path/x",
                               "/dev/dri/card1", false)
               == "# env = AQ_DRM_DEVICES, /dev/dri/card1");
        // other env lines + the doc comment untouched
        EXPECT(rewrite_aq_line("env = LIBVA_DRIVER_NAME, nvidia", "/dev/dri/card1", false)
               == "env = LIBVA_DRIVER_NAME, nvidia");
        EXPECT(rewrite_aq_line("# so AQ_DRM_DEVICES lists BOTH cards", "/dev/dri/card1", true)
               == "# so AQ_DRM_DEVICES lists BOTH cards");
    }

    if (failures == 0) {
        std::cout << "nvidia_modules tests: OK\n";
        return 0;
    }
    std::cerr << "nvidia_modules tests: FAILED (" << failures << " failures)\n";
    return 1;
}
