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

fox_install::state::Classification test_state_stub(
    const fox_install::Context&, const fox_install::state::Manifest&) {
    return {fox_install::state::Status::Fresh, "stub"};
}

// Derive "is this module declared with the extended FOX_MODULE_FULL
// form?" straight from modules.def instead of a hand-maintained slug
// list — so a new full-form module needs zero edits in this test. Both
// macros MUST be variadic to absorb the differing arities (FOX_MODULE
// = 5 args, FOX_MODULE_FULL = 9; the trailing state::check_* token is
// swallowed un-evaluated, so this include creates no symbol references).
#define FOX_MODULE(...)      false,
#define FOX_MODULE_FULL(...) true,
const bool DECLARED_FULL[] = {
#include "../core/modules.def"
};
#undef FOX_MODULE
#undef FOX_MODULE_FULL
constexpr std::size_t DECLARED_FULL_COUNT =
    sizeof(DECLARED_FULL) / sizeof(DECLARED_FULL[0]);
}  // namespace

int main() {
    int failed = 0;
    using namespace fox_install;

    if (MODULES_COUNT == 0) {
        std::fprintf(stderr, "FAIL: MODULES_COUNT == 0\n");
        return 1;
    }
    if (DECLARED_FULL_COUNT != MODULES_COUNT) {
        std::fprintf(stderr,
            "FAIL: DECLARED_FULL_COUNT (%zu) != MODULES_COUNT (%zu) — "
            "modules.def derivation drifted from the live table\n",
            DECLARED_FULL_COUNT, MODULES_COUNT);
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
        // Legacy FOX_MODULE entries route through the FOX_MODULE_FULL shim
        // with all prereqs defaulted to false and state_check to nullptr;
        // lock in that the shim still produces those legacy values. Full-
        // form entries must carry a state_check. Which form a module uses
        // is derived from modules.def (DECLARED_FULL above), not a hand-
        // maintained list — adding a full-form module needs no edit here.
        const bool is_full_form = DECLARED_FULL[i];
        if (!is_full_form) {
            if (m.requires_root || m.requires_graphical || m.requires_network) {
                std::fprintf(stderr,
                    "FAIL [%zu] %s: legacy entry has a non-false prereq "
                    "(root=%d gfx=%d net=%d) — backfill via FOX_MODULE_FULL only\n",
                    i, m.slug,
                    m.requires_root, m.requires_graphical, m.requires_network);
                ++failed;
            }
            if (m.state_check) {
                std::fprintf(stderr,
                    "FAIL [%zu] %s: legacy entry has a non-null state_check "
                    "— wire via FOX_MODULE_FULL only\n", i, m.slug);
                ++failed;
            }
        } else {
            // Full-form entries MUST carry a state_check (that's the
            // whole point of the conversion). If a future edit drops it
            // back to nullptr, surface that here.
            if (!m.state_check) {
                std::fprintf(stderr,
                    "FAIL [%zu] %s: full-form entry is missing its state_check\n",
                    i, m.slug);
                ++failed;
            }
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
    // modules.def so the prereq + state_check fields don't only get
    // test coverage on the day a real module starts using them.
    {
#define FOX_MODULE_FULL(slug, fn, flag, desc, def_on, req_root, req_gfx, req_net, sc)  \
        { #slug, &fn, flag, desc, def_on, req_root, req_gfx, req_net, sc },
        const Module fixture[] = {
            FOX_MODULE_FULL(probe_root,  test_stub, "--probe-root",  "needs root",      true,  true,  false, false, nullptr)
            FOX_MODULE_FULL(probe_gfx,   test_stub, "--probe-gfx",   "needs Wayland",   false, false, true,  false, nullptr)
            FOX_MODULE_FULL(probe_net,   test_stub, "--probe-net",   "downloads stuff", false, false, false, true,  nullptr)
            FOX_MODULE_FULL(probe_check, test_stub, "--probe-check", "has state check", false, false, false, false, &test_state_stub)
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
        if (fixture[3].state_check == nullptr) {
            std::fprintf(stderr, "FAIL: FOX_MODULE_FULL row 3 state_check is nullptr\n"); ++failed;
        } else {
            state::Manifest empty;
            Context         cx;
            auto cls = fixture[3].state_check(cx, empty);
            if (cls.status != state::Status::Fresh) {
                std::fprintf(stderr,
                    "FAIL: probe_check state_check returned %s, expected fresh\n",
                    state::status_name(cls.status));
                ++failed;
            }
        }
        if (fixture[0].state_check != nullptr || fixture[1].state_check != nullptr || fixture[2].state_check != nullptr) {
            std::fprintf(stderr, "FAIL: nullptr state_check field not preserved\n"); ++failed;
        }
    }

    if (failed == 0) {
        std::printf("fox-install registry tests: OK (%zu modules)\n",
                    MODULES_COUNT);
        return 0;
    }
    return 1;
}

// Stub definitions for every module function referenced by modules.def —
// now a shared single source (tests/run_stubs.inc) so test_registry and
// test_args stay in sync. Adding a new module = one stub line THERE.
namespace fox_install {
#include "run_stubs.inc"
}  // namespace fox_install

// State-check stubs for the three modules that use FOX_MODULE_FULL +
// state_check in modules.def. Same rationale as the run_* stubs: the
// test only inspects the table layout and never invokes these.
namespace fox_install::state {
Classification check_deps              (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_render            (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_etckeeper         (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_arch_audit        (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_vault             (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_mac_random        (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_ufw               (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_endlessh          (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_greetd            (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_papirus_icons     (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_gaming            (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_catppuccin_cursor (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_gpg_agent_cache   (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_keyring_full      (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
Classification check_noexec_tmp        (const Context&, const Manifest&) { return {Status::Fresh, "test stub"}; }
}  // namespace fox_install::state
