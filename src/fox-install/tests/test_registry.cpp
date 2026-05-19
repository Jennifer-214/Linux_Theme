// Sanity check the X-macro module registry: every slug is non-empty,
// every flag starts with "--", and the count matches what's listed in
// modules.def. Catches "broke modules.def in a way that still compiles
// but produces nonsense" mistakes.

#include "../core/module.hpp"

#include <cstdio>
#include <cstring>

namespace {
// Used by the FOX_MODULE_FULL fixture below to give the function pointer
// a real target. Never called.
void test_stub(fox_install::Context&) {}
}  // namespace

int main() {
    int failed = 0;
    using namespace fox_install;

    if (MODULES_COUNT == 0) {
        std::fprintf(stderr, "FAIL: MODULES_COUNT == 0\n");
        return 1;
    }

    for (std::size_t i = 0; i < MODULES_COUNT; ++i) {
        const Module& m = MODULES[i];
        if (!m.slug || !*m.slug) {
            std::fprintf(stderr, "FAIL [%zu]: empty slug\n", i);
            ++failed;
        }
        if (!m.fn) {
            std::fprintf(stderr, "FAIL [%zu]: null function pointer\n", i);
            ++failed;
        }
        if (!m.flag || std::strncmp(m.flag, "--", 2) != 0) {
            std::fprintf(stderr, "FAIL [%zu]: flag must start with --, got %s\n",
                i, m.flag ? m.flag : "(null)");
            ++failed;
        }
        if (!m.description || !*m.description) {
            std::fprintf(stderr, "FAIL [%zu]: missing description\n", i);
            ++failed;
        }
        // Every entry in modules.def currently uses the legacy FOX_MODULE
        // form, which routes through the FOX_MODULE_FULL shim with all
        // prereqs defaulted to false. Lock that in so a future field-order
        // shuffle that flips a bool by accident shows up immediately.
        if (m.requires_root || m.requires_graphical || m.requires_network) {
            std::fprintf(stderr,
                "FAIL [%zu] %s: legacy entry has a non-false prereq "
                "(root=%d gfx=%d net=%d) — backfill via FOX_MODULE_FULL only\n",
                i, m.slug,
                m.requires_root, m.requires_graphical, m.requires_network);
            ++failed;
        }
        // Slugs must be unique across the registry.
        for (std::size_t j = i + 1; j < MODULES_COUNT; ++j) {
            if (std::strcmp(MODULES[i].slug, MODULES[j].slug) == 0) {
                std::fprintf(stderr, "FAIL: duplicate slug %s at [%zu,%zu]\n",
                    MODULES[i].slug, i, j);
                ++failed;
            }
        }
    }

    // FOX_MODULE_FULL inline fixture — exercises the macro outside
    // modules.def so the prereq fields don't only get test coverage on
    // the day a real module starts using them.
    {
#define FOX_MODULE_FULL(slug, fn, flag, desc, def_on, req_root, req_gfx, req_net)  \
        { #slug, &fn, flag, desc, def_on, req_root, req_gfx, req_net },
        const Module fixture[] = {
            FOX_MODULE_FULL(probe_root, test_stub, "--probe-root", "needs root",      true,  true,  false, false)
            FOX_MODULE_FULL(probe_gfx,  test_stub, "--probe-gfx",  "needs Wayland",   false, false, true,  false)
            FOX_MODULE_FULL(probe_net,  test_stub, "--probe-net",  "downloads stuff", false, false, false, true)
        };
#undef FOX_MODULE_FULL
        if (std::strcmp(fixture[0].slug, "probe_root") != 0 ||
                !fixture[0].requires_root || fixture[0].requires_graphical || fixture[0].requires_network) {
            std::fprintf(stderr, "FAIL: FOX_MODULE_FULL row 0 fields wrong\n"); ++failed;
        }
        if (!fixture[1].requires_graphical || fixture[1].requires_root || fixture[1].requires_network) {
            std::fprintf(stderr, "FAIL: FOX_MODULE_FULL row 1 fields wrong\n"); ++failed;
        }
        if (!fixture[2].requires_network || fixture[2].requires_root || fixture[2].requires_graphical) {
            std::fprintf(stderr, "FAIL: FOX_MODULE_FULL row 2 fields wrong\n"); ++failed;
        }
    }

    if (failed == 0) {
        std::printf("fox-install registry tests: OK (%zu modules)\n",
                    MODULES_COUNT);
        return 0;
    }
    return 1;
}

// Stub definitions for every module function referenced by modules.def.
// The test only inspects the table, never invokes these. Adding a new
// module = one stub here too. (Failing to add one shows up as a linker
// error at this site, which is the desired "compile-time enforcement"
// behaviour for the registry.)
namespace fox_install {
void run_detect      (Context&) {}
void run_preflight   (Context&) {}
void run_theme       (Context&) {}
void run_deps        (Context&) {}
void run_privacy     (Context&) {}
void run_perf            (Context&) {}
void run_clock_sync      (Context&) {}
void run_arch_audit      (Context&) {}
void run_no_coredumps    (Context&) {}
void run_hidepid         (Context&) {}
void run_noexec_tmp      (Context&) {}
void run_iommu           (Context&) {}
void run_makepkg_hardening(Context&) {}
void run_etckeeper       (Context&) {}
void run_catppuccin_cursor(Context&) {}
void run_papirus_icons   (Context&) {}
void run_zsh_plugins     (Context&) {}
void run_post_install        (Context&) {}
void run_next_steps          (Context&) {}
void run_keyring_full        (Context&) {}
void run_endlessh            (Context&) {}
void run_configure_opencode  (Context&) {}
void run_browser_hardening   (Context&) {}
void run_dispatch_hooks      (Context&) {}
void run_throttling          (Context&) {}
void run_greetd              (Context&) {}
void run_greetd_fingerprint  (Context&) {}
void run_mac_random      (Context&) {}
void run_gpg_agent_cache (Context&) {}
void run_security    (Context&) {}
void run_ufw         (Context&) {}
void run_wallpaper   (Context&) {}
void run_render      (Context&) {}
void run_symlinks    (Context&) {}
void run_specials    (Context&) {}
void run_vault       (Context&) {}
void run_ai              (Context&) {}
void run_ollama_hardening(Context&) {}
void run_models      (Context&) {}
void run_github      (Context&) {}
void run_amd_gpu     (Context&) {}
void run_intel_gpu   (Context&) {}
void run_nvidia      (Context&) {}
void run_fprint      (Context&) {}
void run_fprint_pam  (Context&) {}
void run_ssh_harden  (Context&) {}
void run_xgboost     (Context&) {}
void run_cpp_pro     (Context&) {}
void run_monitors    (Context&) {}
void run_personalize (Context&) {}
void run_summary     (Context&) {}
}  // namespace fox_install
