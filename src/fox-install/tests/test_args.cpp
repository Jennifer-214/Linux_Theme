// Tests for the CLI flag layer — [I-08]: a flag the parser accepts must
// take effect; no later sweep may silently override an explicit choice.
// Every case below is a bug that actually shipped (2026-06-09 audit:
// six accepted-but-overridden flags in one session).

#include "../core/args.hpp"
#include "../core/context.hpp"
#include "../core/module.hpp"

#include <iostream>
#include <string>
#include <vector>

using namespace fox_install;

static int failures = 0;
#define EXPECT(cond) do { \
    if (!(cond)) { \
        std::cerr << "  FAIL: " #cond " at line " << __LINE__ << "\n"; \
        ++failures; \
    } else { \
        std::cout << "  ok: " #cond "\n"; \
    } \
} while (0)

namespace {

std::size_t idx_of(const char* slug) {
    for (std::size_t i = 0; i < MODULES_COUNT; ++i) {
        if (std::string(MODULES[i].slug) == slug) return i;
    }
    return SIZE_MAX;
}

struct ParseResult {
    args::Parsed parsed;
    Context ctx;
    bool ok = false;
};

ParseResult do_parse(const std::vector<std::string>& flags) {
    ParseResult r;
    std::vector<std::string> keep = flags;  // own the argv storage
    std::vector<char*> argv;
    static char prog[] = "fox-install";
    argv.push_back(prog);
    for (auto& s : keep) argv.push_back(const_cast<char*>(s.c_str()));
    r.ok = args::parse(static_cast<int>(argv.size()), argv.data(),
                       r.parsed, r.ctx);
    return r;
}

bool on(const ParseResult& r, const char* slug) {
    std::size_t i = idx_of(slug);
    return i != SIZE_MAX && r.parsed.module_enabled[i];
}

}  // namespace

int main() {
    // Explicit --no-X survives the detect/preflight/theme re-enable
    // (both orders).
    {
        auto r = do_parse({"--no-preflight", "--secure"});
        EXPECT(r.ok);
        EXPECT(!on(r, "preflight"));
        EXPECT(on(r, "security"));
        EXPECT(on(r, "theme"));
        EXPECT(on(r, "detect"));
    }
    {
        auto r = do_parse({"--secure", "--no-preflight"});
        EXPECT(!on(r, "preflight"));
        EXPECT(on(r, "security"));
    }

    // --quick's disables survive --full (both orders).
    {
        auto r = do_parse({"--quick", "--full"});
        EXPECT(!on(r, "deps"));
        EXPECT(!on(r, "github"));
        EXPECT(!on(r, "models"));
        EXPECT(on(r, "render"));
    }
    {
        auto r = do_parse({"--full", "--quick"});
        EXPECT(!on(r, "deps"));
        EXPECT(on(r, "render"));
    }

    // An explicit --no-X survives --full (both orders).
    {
        auto r = do_parse({"--no-render", "--full"});
        EXPECT(!on(r, "render"));
        EXPECT(on(r, "deps"));
    }
    {
        auto r = do_parse({"--full", "--no-render"});
        EXPECT(!on(r, "render"));
    }

    // The bare-slug spelling matches --render, including the implied
    // symlinks + post_install.
    {
        auto r = do_parse({"render"});
        EXPECT(on(r, "render"));
        EXPECT(on(r, "symlinks"));
        EXPECT(on(r, "post_install"));
        EXPECT(!on(r, "security"));
    }

    // --render-only's KEEP list respects an explicit --no-X (both orders).
    {
        auto r = do_parse({"--no-preflight", "--render-only"});
        EXPECT(!on(r, "preflight"));
        EXPECT(on(r, "render"));
    }
    {
        auto r = do_parse({"--render-only", "--no-preflight"});
        EXPECT(!on(r, "preflight"));
        EXPECT(on(r, "render"));
    }

    // --only is the allow-list: it resets earlier selection, so
    // `--full --only vault` means force-reapply EXACTLY vault.
    {
        auto r = do_parse({"--only", "vault"});
        EXPECT(on(r, "vault"));
        EXPECT(!on(r, "security"));
        EXPECT(on(r, "theme"));  // REQ stays unless --no'd
    }
    {
        auto r = do_parse({"--full", "--only", "vault"});
        EXPECT(on(r, "vault"));
        EXPECT(!on(r, "security"));
        EXPECT(r.parsed.full);
        EXPECT(r.ctx.force_reapply);
    }

    // --reapply forces without changing selection — the single-module
    // reinstall spelling.
    {
        auto r = do_parse({"--vault", "--reapply"});
        EXPECT(on(r, "vault"));
        EXPECT(!on(r, "security"));
        EXPECT(r.ctx.force_reapply);
    }

    // Direct contradiction: last flag wins.
    {
        auto r = do_parse({"--no-render", "--render"});
        EXPECT(on(r, "render"));
    }

    if (failures == 0) {
        std::cout << "args flag-layer tests: OK\n";
        return 0;
    }
    std::cerr << "args flag-layer tests: FAILED (" << failures << " failures)\n";
    return 1;
}

// Module run-function link stubs (shared single source; the check_*
// symbols come from the real state_checks.o on the link line).
namespace fox_install {
#include "run_stubs.inc"
}  // namespace fox_install
