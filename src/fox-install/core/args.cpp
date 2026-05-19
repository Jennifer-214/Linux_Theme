#include "args.hpp"

#include "module.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace fox_install::args {

namespace {

// Look up a module by its slug. Returns SIZE_MAX if no match.
std::size_t find_by_slug(const std::string& slug) {
    for (std::size_t i = 0; i < MODULES_COUNT; ++i) {
        if (slug == MODULES[i].slug) return i;
    }
    return SIZE_MAX;
}

// Look up a module by its --foo flag. Returns SIZE_MAX if no match.
std::size_t find_by_flag(const std::string& flag) {

    for (std::size_t i = 0; i < MODULES_COUNT; ++i) {
        if (flag == MODULES[i].flag) return i;
    }
    return SIZE_MAX;
}

// Look up a module by its negated form. Accepts both:
//   * --no-<flag-tail>  e.g. --no-mac-random  (matches MODULES[].flag)
//   * --no-<slug>       e.g. --no-mac_random  (matches MODULES[].slug)
// The flag form is the user-facing convention (hyphens); the slug form
// (underscores) is the internal name. Either works.
std::size_t find_by_no_slug(const std::string& flag) {
    if (flag.rfind("--no-", 0) != 0) return SIZE_MAX;
    std::string tail = flag.substr(5);
    std::string reconstructed_flag = "--" + tail;
    for (std::size_t i = 0; i < MODULES_COUNT; ++i) {
        if (reconstructed_flag == MODULES[i].flag) return i;
        if (tail == MODULES[i].slug) return i;
    }
    return SIZE_MAX;
}

}  // namespace

void print_help(const char* argv0) {
    std::printf(
        "fox-install — FoxML Theme Hub installer (C++ orchestrator)\n\n"
        "Usage: %s [theme] [flags]\n\n"
        "Global flags:\n"
        "  -y, --yes         assume yes for every prompt (disables wizard)\n"
        "      --resume      resume from the last successful module\n"
        "      --phase <s.>  skip ahead to a specific module slug\n"
        "      --dry-run     print every command without executing it\n"
        "      --full        enable every registered module + every sub-toggle\n"
        "                    (polkit-strict, cpp-pro). Use --no-<slug> to exclude\n"
        "                    individual modules (e.g. --full --no-mac-random).\n"
        "      --quick       skip slow + network-heavy parts (deps, github, models)\n"
        "      --monitor     surgical run of the multi-monitor wizard only\n"
        "      --only <slugs> comma-separated allow-list; everything else skipped\n"
        "      --polkit-strict   add polkit strict mode (every GUI sudo re-prompts)\n"
        "      --rotate-wallpapers enable time-of-day wallpaper rotation (default: static)\n"
        "      --cpp-pro     C++ toolchain extras (clang/lldb/mold/perf/etc)\n"
        "      --arm, --paranoid chain into fox-arm at end of install\n"
        "      --arm-heavy, --heavy   ditto, runs fox-arm --heavy\n"
        "      --quiet       suppress per-step chatter (errors still print)\n"
        "      --no-update   skip install.sh's git self-update (handled by the\n"
        "                    bash wrapper; equivalent to FOXML_NO_UPDATE=1)\n"
        "      --wizard-demo render the state-driven wizard against the live\n"
        "                    registry + exit; nothing is installed (Phase 6 WIP)\n"
        "  -h, --help        show this help and exit\n"
        "      --version     print version and exit\n\n"
        "Modules (default-on shown with *):\n",
        argv0);
    for (std::size_t i = 0; i < MODULES_COUNT; ++i) {
        const Module& m = MODULES[i];
        std::printf("  %s %-14s %s  %s\n",
                    m.default_on ? "*" : " ",
                    m.flag, m.slug, m.description);
    }
    std::printf(
        "\nDisable a default module with --no-<slug>, e.g. --no-render.\n");
}

void print_version() {
    std::printf("fox-install 0.1.0 (orchestrator skeleton)\n");
}

bool parse(int argc, char** argv, Parsed& out, Context& ctx) {
    // Initial state: everything is default_on. We only clear this and switch
    // to exclusive mode if we see a module-specific flag (e.g. --render)
    // or an explicit --only.
    out.module_enabled.assign(MODULES_COUNT, false);
    for (std::size_t i = 0; i < MODULES_COUNT; ++i) {
        out.module_enabled[i] = MODULES[i].default_on;
    }

    bool provided_explicit_module = false;

    auto switch_to_exclusive = [&]() {
        if (out.only) return;
        out.only = true;
        provided_explicit_module = true;
        for (std::size_t k = 0; k < MODULES_COUNT; ++k) {
            out.module_enabled[k] = false;
        }
    };

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];

        if (a == "-h" || a == "--help")    { out.show_help = true;    continue; }
        if (a == "--version")              { out.show_version = true; continue; }
        if (a == "-y" || a == "--yes")     { ctx.assume_yes = true;   continue; }
        if (a == "--resume")               { out.resume = true;       continue; }
        if (a == "--dry-run")              { ctx.dry_run = true;      continue; }
        if (a == "--quiet")                { ctx.quiet = true; out.quiet = true; continue; }
        if (a == "--no-update")            { /* consumed by install.sh wrapper */ continue; }
        if (a == "--wizard-demo")          { out.wizard_demo = true;  continue; }

        if (a == "--phase" && i + 1 < argc) {
            out.phase = argv[++i];
            continue;
        }

        if (a == "--cpp-pro") {
            ctx.cpp_pro = true;
            std::size_t idx = find_by_slug("cpp_pro");
            if (idx != SIZE_MAX) {
                // If this is the only module flag, switch to exclusive.
                // But wait, if they pass --full --cpp-pro, we don't want to
                // clear everything. switch_to_exclusive handles this via out.only check.
                switch_to_exclusive();
                out.module_enabled[idx] = true;
            }
            continue;
        }

        if (a == "--full" || a == "--all") {
            out.full = true;
            out.only = true; // prevents later flags from clearing
            for (std::size_t k = 0; k < MODULES_COUNT; ++k) {
                out.module_enabled[k] = true;
            }
            ctx.install_polkit_strict = true;
            ctx.cpp_pro = true;
            ctx.force_reapply = true;
            continue;
        }

        if (a == "--arm" || a == "--paranoid") {
            ::setenv("FOXML_ARM", "1", 1);
            continue;
        }
        if (a == "--arm-heavy" || a == "--heavy") {
            ::setenv("FOXML_ARM", "1", 1);
            ::setenv("FOXML_ARM_HEAVY", "1", 1);
            continue;
        }

        if (a == "--polkit-strict") {
            ctx.install_polkit_strict = true;
            continue;
        }

        if (a == "--rotate-wallpapers") {
            ctx.rotate_wallpapers = true;
            continue;
        }
        if (a == "--no-rotate-wallpapers") {
            ctx.rotate_wallpapers = false;
            continue;
        }

        if (a == "--quick") {
            for (std::size_t k = 0; k < MODULES_COUNT; ++k) {
                std::string s = MODULES[k].slug;
                if (s == "deps" || s == "github" || s == "models") {
                    out.module_enabled[k] = false;
                }
            }
            continue;
        }

        if (a == "--monitor") {
            switch_to_exclusive();
            std::size_t idx = find_by_slug("monitors");
            if (idx != SIZE_MAX) out.module_enabled[idx] = true;
            continue;
        }

        if (a == "--render-only") {
            switch_to_exclusive();
            static const char* KEEP[] = {
                "detect", "preflight", "theme",
                "render", "symlinks", "specials",
                "personalize", "post_install", "summary", nullptr,
            };
            for (auto** s = KEEP; *s; ++s) {
                std::size_t idx = find_by_slug(*s);
                if (idx != SIZE_MAX) out.module_enabled[idx] = true;
            }
            continue;
        }

        if (a == "--only" && i + 1 < argc) {
            switch_to_exclusive();
            std::string list = argv[++i];
            std::size_t pos = 0;
            while (pos <= list.size()) {
                std::size_t comma = list.find(',', pos);
                std::string slug = list.substr(
                    pos, comma == std::string::npos ? std::string::npos : comma - pos);
                if (!slug.empty()) {
                    std::size_t idx = find_by_slug(slug);
                    if (idx != SIZE_MAX) {
                        out.module_enabled[idx] = true;
                    } else {
                        std::fprintf(stderr,
                            "fox-install: --only: unknown slug '%s'\n", slug.c_str());
                        return false;
                    }
                }
                if (comma == std::string::npos) break;
                pos = comma + 1;
            }
            continue;
        }

        std::size_t idx = find_by_flag(a);
        if (idx != SIZE_MAX) {
            switch_to_exclusive();
            out.module_enabled[idx] = true;

            // UX: --render almost always wants --symlinks to deploy the fresh
            // bits AND --post-install to re-render waybar style.css from the
            // .tmpl and restart waybar/dunst/mako so the changes are visible.
            // Without post_install, the new .tmpl sits on disk and the running
            // bars keep their stale CSS until next login.
            if (std::string(MODULES[idx].slug) == "render") {
                for (const char* implied : {"symlinks", "post_install"}) {
                    std::size_t s_idx = find_by_slug(implied);
                    if (s_idx != SIZE_MAX) out.module_enabled[s_idx] = true;
                }
            }
            continue;
        }

        idx = find_by_no_slug(a);
        if (idx != SIZE_MAX) {
            // Note: --no-foo doesn't trigger exclusive mode; it just disables.
            out.module_enabled[idx] = false;
            continue;
        }

        if (!a.empty() && a[0] != '-') {
            std::size_t slug_idx = find_by_slug(a);
            if (slug_idx != SIZE_MAX) {
                switch_to_exclusive();
                out.module_enabled[slug_idx] = true;
                continue;
            }

            if (ctx.theme_name.empty()) {
                ctx.theme_name = a;
                continue;
            }
        }

        std::fprintf(stderr, "fox-install: unknown argument: %s\n", a.c_str());
        return false;
    }

    // If we switched to exclusive mode because of flags like --render,
    // we MUST ensure discovery/theme modules stay on, otherwise the
    // selected module might fail (no palette, no hardware info).
    if (provided_explicit_module) {
        static const char* REQ[] = { "detect", "preflight", "theme", nullptr };
        for (auto** s = REQ; *s; ++s) {
            std::size_t idx = find_by_slug(*s);
            if (idx != SIZE_MAX) out.module_enabled[idx] = true;
        }
    }

    return true;
}

}  // namespace fox_install::args
