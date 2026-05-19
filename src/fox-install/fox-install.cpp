// fox-install — typed C++ orchestrator for the FoxML Theme Hub installer.
//
// The point of this binary is the X-macro module registry in
// core/modules.def. Everything else (arg parser, --help, dispatcher,
// dry-run preview) is generated from that single list. To add a new
// install step you write one .cpp under modules/, declare the symbol
// with one line in modules.def, and rebuild.

#include "core/args.hpp"
#include "core/context.hpp"
#include "core/module.hpp"
#include "core/state_manifest.hpp"
#include "core/wizard.hpp"
#include "../fox-common/shell.hpp"
#include "../fox-common/ui.hpp"

#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <unistd.h>

namespace fs = std::filesystem;

namespace {

constexpr const char* DEFAULT_THEME = "FoxML_Classic";

fs::path detect_script_dir(const char* argv0) {
    // Resolution order:
    //   1. $FOXML_REPO env var (explicit override).
    //   2. Walk up from argv0 looking for templates/ + themes/. This works
    //      for dev runs (./src/fox-install/fox-install …).
    //   3. ~/.local/share/foxml/repo-dir marker, written by `make install`
    //      so a binary at ~/.local/bin/fox-install can find its source.
    //   4. fs::current_path() as last resort.
    if (const char* env = std::getenv("FOXML_REPO"); env && *env) {
        fs::path p = env;
        if (fs::is_directory(p / "templates") && fs::is_directory(p / "themes")) {
            return p;
        }
    }

    fs::path p = argv0;
    if (!p.is_absolute()) {
        std::error_code ec;
        p = fs::absolute(p, ec);
    }
    p = fs::weakly_canonical(p);
    fs::path dir = p.parent_path();
    while (!dir.empty() && dir != dir.root_path()) {
        if (fs::is_directory(dir / "templates") &&
            fs::is_directory(dir / "themes")) {
            return dir;
        }
        dir = dir.parent_path();
    }

    if (const char* home = std::getenv("HOME"); home && *home) {
        fs::path marker = fs::path(home) / ".local/share/foxml/repo-dir";
        std::ifstream f(marker);
        if (f) {
            std::string line;
            if (std::getline(f, line) && !line.empty()) {
                fs::path repo = line;
                if (fs::is_directory(repo / "templates") &&
                    fs::is_directory(repo / "themes")) {
                    return repo;
                }
            }
        }
    }

    return fs::current_path();
}

void fill_paths(fox_install::Context& ctx, const char* argv0) {
    ctx.script_dir    = detect_script_dir(argv0);
    ctx.templates_dir = ctx.script_dir / "templates";
    ctx.themes_dir    = ctx.script_dir / "themes";
    ctx.shared_dir    = ctx.script_dir / "shared";
    ctx.rendered_dir  = ctx.script_dir / "rendered";

    const char* home_env = std::getenv("HOME");
    ctx.home = home_env ? fs::path(home_env) : fs::path("/tmp");

    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    ctx.config_home = (xdg && *xdg) ? fs::path(xdg) : (ctx.home / ".config");

    if (ctx.theme_name.empty()) ctx.theme_name = DEFAULT_THEME;
    ctx.palette_path = ctx.themes_dir / ctx.theme_name / "palette.sh";

    // Timestamped backup root (matches bash
    // BACKUP_DIR=$HOME/.theme_backups/foxml-backup-YYYYMMDD-HHMMSS).
    char ts[32]{};
    std::time_t now = std::time(nullptr);
    std::tm* tm_now = std::localtime(&now);
    if (tm_now) std::strftime(ts, sizeof(ts), "%Y%m%d-%H%M%S", tm_now);
    ctx.backup_dir = ctx.home / ".theme_backups" /
                     (std::string("foxml-backup-") + ts);
}

}  // namespace

int main(int argc, char** argv) {
    using namespace fox_install;

    ui::init();

    Context ctx;
    args::Parsed parsed;
    if (!args::parse(argc, argv, parsed, ctx)) return 2;
    if (parsed.show_help)    { args::print_help(argv[0]);    return 0; }
    if (parsed.show_version) { args::print_version();        return 0; }

    fill_paths(ctx, argv[0]);
    sh::set_dry_run(ctx.dry_run);

    // Phase 6 Step 3: load the state manifest from the prior install (if
    // any). Read-only for now — Session B wires classification on top.
    // A read failure is non-fatal: we log a warning and proceed with an
    // empty manifest, then overwrite it cleanly at end-of-install.
    state::Manifest manifest;
    try {
        manifest = state::read(state::default_path());
    } catch (const std::exception& e) {
        ui::warn(std::string("state manifest read failed: ") + e.what()
                 + " (treating as empty)");
    }

    // Phase 6 Step 9/10: --wizard-demo renders the wizard + preview
    // screen against the live registry + the manifest we just loaded,
    // then exits without installing anything. This is the manual-
    // verification entry point while the state-driven flow is being
    // built; Step 11 wires it into the install flow proper.
    if (parsed.wizard_demo) {
        std::vector<const Module*> modules;
        modules.reserve(MODULES_COUNT);
        for (std::size_t i = 0; i < MODULES_COUNT; ++i) modules.push_back(&MODULES[i]);
        wizard::Plan plan = wizard::default_plan(modules, ctx, manifest);
        plan = wizard::run(std::move(plan), ctx);
        if (plan.aborted) return 1;
        const bool committed = wizard::preview(plan, ctx);
        return committed ? 0 : 2;  // 2 = declined at preview
    }

    // Run `detect` upfront so the dry-run plan, interactive wizards,
    // and main loop see the final enable state of hardware-gated
    // modules (nvidia/amd_gpu/intel_gpu/fprint). detect is read-only
    // — re-running it is cheap. confirm_hw inside detect honors
    // ctx.assume_yes (--yes auto-accepts; interactive mode still asks
    // per-piece). After detect we toggle module_enabled to mirror the
    // resolved ctx.has_* flags, then mark detect as already-run so
    // the main loop skips it.
    {
        auto find_idx = [](const char* slug) -> int {
            for (std::size_t k = 0; k < MODULES_COUNT; ++k) {
                if (std::string(MODULES[k].slug) == slug) return static_cast<int>(k);
            }
            return -1;
        };
        int detect_idx = find_idx("detect");
        if (detect_idx >= 0 && parsed.module_enabled[detect_idx]) {
            MODULES[detect_idx].fn(ctx);
            parsed.module_enabled[detect_idx] = false;

            auto enable_slug = [&](const char* slug) {
                int k = find_idx(slug);
                if (k >= 0) parsed.module_enabled[k] = true;
            };
            // Default-disable hardware modules; they'll be flipped on only
            // if detected + confirmed during the detect phase.
            int k;
            if ((k = find_idx("nvidia"))    >= 0) parsed.module_enabled[k] = false;
            if ((k = find_idx("amd_gpu"))   >= 0) parsed.module_enabled[k] = false;
            if ((k = find_idx("intel_gpu")) >= 0) parsed.module_enabled[k] = false;
            if ((k = find_idx("fprint"))    >= 0) parsed.module_enabled[k] = false;

            if (ctx.has_nvidia)    enable_slug("nvidia");
            if (ctx.has_amd_gpu)   enable_slug("amd_gpu");
            if (ctx.has_intel_gpu) enable_slug("intel_gpu");
            if (ctx.has_fprint)    enable_slug("fprint");
        }
    }

    fs::path state_file = ctx.home / ".local/share/foxml/install_state";

    // Pre-install marker detect. Bash printed a nudge about --quick on
    // every invocation when ~/.local/share/foxml/.installed-version
    // existed. We do the same — silent first install, nudge thereafter.
    {
        fs::path marker = ctx.home / ".local/share/foxml/.installed-version";
        if (fs::exists(marker) && !ctx.dry_run) {
            std::ifstream f(marker);
            std::string line;
            std::string prior_theme;
            while (std::getline(f, line)) {
                if (line.rfind("theme=", 0) == 0) {
                    prior_theme = line.substr(6);
                    break;
                }
            }
            std::printf(" -> existing FoxML install detected"
                        "%s%s — pass --quick to skip deps + clones + model pulls\n",
                        prior_theme.empty() ? "" : " (",
                        prior_theme.empty() ? "" : (prior_theme + ")").c_str());
        }
    }

    if (ctx.dry_run) {
        ui::section("Dry-run plan (baseline)");
        for (std::size_t i = 0; i < MODULES_COUNT; ++i) {
            std::string status = parsed.module_enabled[i] ? "will run" : "skipped";
            if (ctx.resume_idx > 0 && static_cast<int>(i) < ctx.resume_idx) {
                status = "skipped (before resume point)";
            }
            ui::summary_row(MODULES[i].slug, status);
        }
    }

    ui::section("FoxML installer (fox-install) — theme: " + ctx.theme_name);

    // Upper bound for the progress bar denominator. Interactive prompts
    // may push the actually-run count lower if the user answers 'n', but
    // counting up to the planned total still gives a meaningful sense
    // of "how much of the install is left."
    std::size_t total_enabled = 0;
    for (std::size_t k = 0; k < MODULES_COUNT; ++k) {
        if (parsed.module_enabled[k]) ++total_enabled;
    }
    std::size_t ran_count = 0;

    std::vector<std::string> failed_modules;
    for (std::size_t i = 0; i < MODULES_COUNT; ++i) {
        if (ctx.resume_idx > 0 && static_cast<int>(i) < ctx.resume_idx) continue;

        const Module& m = MODULES[i];
        bool should_run = parsed.module_enabled[i];

        // --- Inline Interactive Decision ---
        if (!ctx.assume_yes && ui::tty()) {
            if (parsed.only && !should_run) {
                // In --only mode, we don't prompt for things that aren't 
                // in the allow-list. 
            } else {
                auto is_backbone = [](const char* s) {
                    static const char* B[] = { "detect", "preflight", "theme", "render",
                        "symlinks", "specials", "post_install", "summary", "next_steps", nullptr };
                    for (auto** p = B; *p; ++p) if (std::string(*p) == s) return true;
                    return false;
                };
                auto is_hw = [](const char* s) {
                    static const char* H[] = { "nvidia", "amd_gpu", "intel_gpu", "fprint", nullptr };
                    for (auto** p = H; *p; ++p) if (std::string(*p) == s) return true;
                    return false;
                };

                if (!is_backbone(m.slug) && !is_hw(m.slug)) {
                    // Skip laptop-only modules on desktops
                    if (std::string(m.slug) == "throttling" && !ctx.is_laptop) {
                        should_run = false;
                    } else {
                        bool risky = (std::string(m.slug) == "fprint_pam" ||
                                      std::string(m.slug) == "greetd_fingerprint");
                        std::string prompt = "Execute module " + std::string(m.slug);
                        if (risky) prompt += " [LOCKOUT RISK]";
                        prompt += " (" + std::string(m.description) + ")?";
                        
                        // We use the current enabled state as the default.
                        should_run = ui::ask_yn(prompt, should_run, false);
                    }
                }
            }
        }

        if (!should_run) continue;

        ++ran_count;
        ui::module_progress(ran_count, total_enabled, m.slug);

        try {
            m.fn(ctx);

            // Update resume state after success
            if (!ctx.dry_run) {
                fs::create_directories(state_file.parent_path());
                std::ofstream f(state_file);
                f << i << std::endl;
            }

            // Phase 6 Step 3: record per-module success in the state
            // manifest. Session B will populate version + source_hash;
            // for now we just stamp the timestamp so we have a record
            // of "this module ran successfully in this install."
            manifest.modules[m.slug] = state::ModuleState{
                /* version    */ "",
                /* source_hash*/ "",
                /* deployed_at*/ state::now_iso8601(),
            };
        } catch (const std::exception& e) {
            ui::err(std::string(m.slug) + ": " + e.what());
            failed_modules.emplace_back(m.slug);
            // On failure, we don't advance the state_file so --resume
            // will retry the failing module.
            break; 
        }
    }

    // Clear resume state on clean completion
    if (failed_modules.empty() && !ctx.dry_run && fs::exists(state_file)) {
        fs::remove(state_file);
    }

    // Phase 6 Step 3: persist the updated manifest. Done even on
    // partial-failure runs so subsequent invocations can see which
    // modules already succeeded. Write failure is non-fatal.
    if (!ctx.dry_run) {
        try {
            state::write(state::default_path(), manifest);
        } catch (const std::exception& e) {
            ui::warn(std::string("state manifest write failed: ") + e.what());
        }
    }

    ui::section("Done");
    ui::summary_row("theme",     ctx.theme_name);
    ui::summary_row("modules",   std::to_string(MODULES_COUNT) + " registered");
    ui::summary_row("failures",  std::to_string(failed_modules.size()));

    // Mid-install errors (failed pacman calls, missing packages, etc.)
    // can scroll past while the user is watching. Re-list them at the
    // tail so they're impossible to miss, with the suggested fix in
    // one line. This keeps the bash habit of "run --deps after a
    // pacman -Syu" actionable instead of buried.
    if (!failed_modules.empty()) {
        std::printf("\n");
        ui::err("modules with failures (scroll up for details):");
        for (auto& m : failed_modules) {
            std::printf("    • %s — re-run with: fox-install --only %s\n",
                        m.c_str(), m.c_str());
        }
        std::printf("\n  Common fixes:\n"
                    "    • pacman dep-resolution errors → sudo pacman -Syu, then retry\n"
                    "    • systemctl enable failures → sudo -v, then retry\n"
                    "    • module-specific errors → check the error line above\n");
    }
    return failed_modules.empty() ? 0 : 1;
}
