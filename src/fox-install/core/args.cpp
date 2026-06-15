#include "args.hpp"

#include "module.hpp"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
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
        "                    (resets earlier selection: --full --only X = force-reapply X)\n"
        "      --preset <p>  load module on/off choices from a preset file — an\n"
        "                    explicit path, or a name resolved under\n"
        "                    ~/.config/foxml/presets/ then the repo presets/.\n"
        "                    Overrides defaults additively; off-lines survive\n"
        "                    --full. Pair with -y for an unattended reinstall.\n"
        "      --reapply     run selected modules even if up-to-date — the\n"
        "                    single-module reinstall: --vault --reapply\n"
        "      --polkit-strict   add polkit strict mode (every GUI sudo re-prompts)\n"
        "      --rotate-wallpapers enable time-of-day wallpaper rotation (default: static)\n"
        "      --cpp-pro     C++ toolchain extras (clang/lldb/mold/perf/etc)\n"
        "      --arm, --paranoid chain into fox-arm at end of install\n"
        "      --arm-heavy, --heavy   ditto, runs fox-arm --heavy\n"
        "      --quiet       suppress per-step chatter (errors still print)\n"
        "      --no-update   skip install.sh's git self-update (handled by the\n"
        "                    bash wrapper; equivalent to FOXML_NO_UPDATE=1)\n"
        "      --wizard-demo render the state-driven wizard against the live\n"
        "                    registry + exit; nothing is installed\n"
        "      (env)         FOX_INSTALL_LEGACY=1 forces the legacy inline-prompt\n"
        "                    flow (escape hatch; state-driven is the default)\n"
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
    bool only_list_mode = false;
    std::vector<bool> explicitly_disabled(MODULES_COUNT, false);

    auto switch_to_exclusive = [&]() {
        if (out.only) return;
        out.only = true;
        provided_explicit_module = true;
        for (std::size_t k = 0; k < MODULES_COUNT; ++k) {
            out.module_enabled[k] = false;
        }
    };

    // Shared by the --<flag> and bare-slug spellings so both behave
    // identically (positional `render` used to miss --render's implied
    // modules and deploy nothing visible).
    auto enable_module = [&](std::size_t idx) {
        out.module_enabled[idx] = true;
        // UX: render almost always wants symlinks to deploy the fresh
        // bits AND post_install to re-render waybar style.css from the
        // .tmpl and restart waybar/dunst/mako so the changes are
        // visible. Without post_install, the new .tmpl sits on disk and
        // the running bars keep their stale CSS until next login.
        if (std::string(MODULES[idx].slug) == "render") {
            for (const char* implied : {"symlinks", "post_install"}) {
                std::size_t s_idx = find_by_slug(implied);
                if (s_idx != SIZE_MAX) out.module_enabled[s_idx] = true;
            }
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
            // An earlier explicit --no-<slug> survives --full; otherwise
            // `--no-render --full` and `--full --no-render` disagree.
            for (std::size_t k = 0; k < MODULES_COUNT; ++k) {
                if (!explicitly_disabled[k]) out.module_enabled[k] = true;
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

        if (a == "--reapply" || a == "--force-reapply") {
            // Standalone force: run modules as if stale, even where the
            // idempotency layer says up-to-date. Pairs with a module flag
            // for a single-module reinstall (`--vault --reapply`); --full
            // implies it. Selection is unchanged — this only defeats the
            // "already configured" skips inside the selected modules.
            ctx.force_reapply = true;
            continue;
        }

        if (a == "--quick") {
            // Recorded as explicit so a later --full doesn't undo it
            // (`--quick --full` used to silently re-enable all three).
            for (std::size_t k = 0; k < MODULES_COUNT; ++k) {
                std::string s = MODULES[k].slug;
                if (s == "deps" || s == "github" || s == "models") {
                    out.module_enabled[k] = false;
                    explicitly_disabled[k] = true;
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
                if (idx != SIZE_MAX && !explicitly_disabled[idx]) {
                    out.module_enabled[idx] = true;
                }
            }
            continue;
        }

        if (a == "--only" && i + 1 < argc) {
            // --only is the documented allow-list: it RESETS any earlier
            // selection — including --full's everything-on, which used to
            // win silently and turn `--full --only vault` into a full
            // install. (--full's force_reapply survives, so that spelling
            // now means "force-reapply exactly these".) A second --only
            // appends to the first.
            if (!only_list_mode) {
                out.only = false;  // let switch_to_exclusive re-clear
                switch_to_exclusive();
                only_list_mode = true;
            }
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

        if (a == "--preset" && i + 1 < argc) {
            // A preset is a durable file of `slug = on|off` overrides on top
            // of each module's default. Additive (NOT exclusive like --only):
            // unlisted modules keep their default, so a preset doesn't rot
            // when new modules are added upstream. An `off` line also marks
            // explicitly_disabled so a later --full can't silently re-enable
            // it. Resolution: explicit path, else a name under
            // ~/.config/foxml/presets/, else the repo presets/ dir.
            const std::string spec = argv[++i];
            auto is_file = [](const std::filesystem::path& p) {
                std::error_code ec;
                return std::filesystem::is_regular_file(p, ec);
            };
            std::filesystem::path path = spec;
            if (spec.find('/') == std::string::npos && !is_file(path)) {
                std::filesystem::path xdg =
                    ctx.config_home / "foxml" / "presets" / (spec + ".preset");
                std::filesystem::path repo =
                    ctx.script_dir / "presets" / (spec + ".preset");
                path = is_file(xdg) ? xdg : (is_file(repo) ? repo : xdg);
            }
            std::ifstream in(path);
            if (!in) {
                // File-not-found is FATAL: the operator named a preset whose
                // intent we can't honor — fail loud, don't silently install
                // defaults. (An unknown slug *inside* a found file only warns.)
                std::fprintf(stderr,
                    "fox-install: --preset: no preset file for '%s' "
                    "(tried explicit path, ~/.config/foxml/presets/, repo presets/)\n",
                    spec.c_str());
                return false;
            }
            auto trim = [](std::string s) {
                const char* ws = " \t\r\n";
                std::size_t b = s.find_first_not_of(ws);
                if (b == std::string::npos) return std::string();
                return s.substr(b, s.find_last_not_of(ws) - b + 1);
            };
            std::string raw;
            while (std::getline(in, raw)) {
                std::size_t hash = raw.find('#');
                if (hash != std::string::npos) raw = raw.substr(0, hash);
                std::string line = trim(raw);
                if (line.empty()) continue;
                std::size_t eq = line.find('=');
                if (eq == std::string::npos) {
                    std::fprintf(stderr,
                        "fox-install: --preset: ignoring malformed line '%s'\n",
                        line.c_str());
                    continue;
                }
                std::string slug = trim(line.substr(0, eq));
                std::string val  = trim(line.substr(eq + 1));
                for (auto& c : val)
                    c = static_cast<char>(std::tolower((unsigned char)c));
                bool want_on;
                if (val == "on" || val == "true" || val == "yes" || val == "1") {
                    want_on = true;
                } else if (val == "off" || val == "false" || val == "no" || val == "0") {
                    want_on = false;
                } else {
                    std::fprintf(stderr,
                        "fox-install: --preset: '%s' has bad value '%s' (use on/off)\n",
                        slug.c_str(), val.c_str());
                    continue;
                }
                std::size_t pidx = find_by_slug(slug);
                if (pidx == SIZE_MAX) {
                    // Non-fatal: a stored preset must outlive registry churn.
                    std::fprintf(stderr,
                        "fox-install: --preset: unknown module '%s' (skipped)\n",
                        slug.c_str());
                    continue;
                }
                out.module_enabled[pidx] = want_on;
                if (!want_on) explicitly_disabled[pidx] = true;
            }
            continue;
        }

        std::size_t idx = find_by_flag(a);
        if (idx != SIZE_MAX) {
            switch_to_exclusive();
            enable_module(idx);
            continue;
        }

        idx = find_by_no_slug(a);
        if (idx != SIZE_MAX) {
            // Note: --no-foo doesn't trigger exclusive mode; it just disables.
            out.module_enabled[idx] = false;
            explicitly_disabled[idx] = true;
            continue;
        }

        if (!a.empty() && a[0] != '-') {
            std::size_t slug_idx = find_by_slug(a);
            if (slug_idx != SIZE_MAX) {
                switch_to_exclusive();
                enable_module(slug_idx);
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
    // An explicit --no-<slug> outranks this convenience re-enable —
    // otherwise --no-preflight is accepted but silently ignored.
    if (provided_explicit_module) {
        static const char* REQ[] = { "detect", "preflight", "theme", nullptr };
        for (auto** s = REQ; *s; ++s) {
            std::size_t idx = find_by_slug(*s);
            if (idx != SIZE_MAX && !explicitly_disabled[idx]) {
                out.module_enabled[idx] = true;
            }
        }
    }

    return true;
}

}  // namespace fox_install::args
