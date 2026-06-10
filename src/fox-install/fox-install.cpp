// fox-install — typed C++ orchestrator for the FoxML Theme Hub installer.
//
// The point of this binary is the X-macro module registry in
// core/modules.def. Everything else (arg parser, --help, dispatcher,
// dry-run preview) is generated from that single list. To add a new
// install step you write one .cpp under modules/, declare the symbol
// with one line in modules.def, and rebuild.

#include "core/args.hpp"
#include "core/context.hpp"
#include "core/install_lock.hpp"
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
#include <sys/stat.h>

namespace fs = std::filesystem;

namespace {

constexpr const char* DEFAULT_THEME = "FoxML_Classic";

// Walk PATH for the first `fox-install` it would resolve to; if that's
// not the binary actually running right now AND mtimes differ, warn.
// Catches the footgun where `~/.local/bin/fox-install` (last refreshed
// by `make install`) drifts behind a freshly-built source tree binary
// — running the stale PATH copy silently uses older module logic.
void warn_if_stale_on_path() {
    char self[4096];
    ssize_t n = ::readlink("/proc/self/exe", self, sizeof(self) - 1);
    if (n <= 0) return;
    self[n] = 0;
    struct stat self_st{};
    if (::stat(self, &self_st) != 0) return;

    const char* path = std::getenv("PATH");
    if (!path) return;

    std::string p(path);
    size_t start = 0;
    while (start <= p.size()) {
        size_t end = p.find(':', start);
        if (end == std::string::npos) end = p.size();
        std::string dir = p.substr(start, end - start);
        start = end + 1;
        if (dir.empty()) continue;

        std::string candidate = dir + "/fox-install";
        struct stat cst{};
        if (::stat(candidate.c_str(), &cst) != 0) continue;
        if (!S_ISREG(cst.st_mode)) continue;
        if (cst.st_ino == self_st.st_ino && cst.st_dev == self_st.st_dev) {
            return;  // PATH resolves to self — nothing stale.
        }
        if (cst.st_mtime < self_st.st_mtime) {
            fox_install::ui::warn("stale fox-install at " + candidate
                     + " is older than this binary");
            fox_install::ui::substep("`make install` from the source tree to refresh ~/.local/bin");
        } else if (cst.st_mtime > self_st.st_mtime) {
            fox_install::ui::warn("newer fox-install at " + candidate
                     + " — PATH would resolve there, not here");
            fox_install::ui::substep("you may be running a stale copy; re-run via that path"
                        " or `cd <source> && ./install.sh`");
        }
        return;  // shell stops at first PATH hit; we do too
    }
}

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
    warn_if_stale_on_path();

    Context ctx;
    args::Parsed parsed;
    if (!args::parse(argc, argv, parsed, ctx)) return 2;
    if (parsed.show_help)    { args::print_help(argv[0]);    return 0; }
    if (parsed.show_version) { args::print_version();        return 0; }

    fill_paths(ctx, argv[0]);
    sh::set_dry_run(ctx.dry_run);

    // Phase 6 Step 14 / R17: install lockfile. Read-only / informational
    // invocations are exempt — dry-run + wizard-demo touch no shared
    // state, so a second concurrent dry-run is harmless. The real
    // installer path always takes the lock; the second invocation
    // reports the holding PID + exits non-zero rather than racing on
    // pacman / sudo / the wizard's terminal state.
    // fd is kept open for the duration of the process; OS releases the
    // flock when the fd is closed at exit. The variable is marked
    // [[maybe_unused]] because every read of it would mean adding an
    // explicit lockfile::release() call before each `return` site —
    // not worth the noise when the kernel handles release for us.
    [[maybe_unused]] int lock_fd = -1;
    if (!ctx.dry_run && !parsed.wizard_demo) {
        auto lock = lockfile::acquire();
        if (lock.fd < 0) {
            if (lock.holder_pid > 0) {
                ui::err("another fox-install is running (PID "
                        + std::to_string(lock.holder_pid)
                        + ") — abort, or wait for it to finish");
            } else {
                ui::err("could not acquire install lock: " + lock.error_msg);
            }
            return 1;
        }
        lock_fd = lock.fd;
    }

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

            if (parsed.only && !parsed.full) {
                // Explicit selection ([I-08]): never ADD hardware modules
                // the user didn't ask for — detect used to sweep the whole
                // fprint chain into a `--secure` run. Just gate OFF,
                // loudly, any requested module the hardware can't support.
                const struct { const char* slug; bool present; } gates[] = {
                    {"nvidia",             ctx.has_nvidia},
                    {"amd_gpu",            ctx.has_amd_gpu},
                    {"intel_gpu",          ctx.has_intel_gpu},
                    {"fprint",             ctx.has_fprint},
                    {"fprint_pam",         ctx.has_fprint},
                    {"greetd_fingerprint", ctx.has_fprint},
                    {"sudo_fingerprint",   ctx.has_fprint},
                };
                for (const auto& g : gates) {
                    int k = find_idx(g.slug);
                    if (k >= 0 && parsed.module_enabled[k] && !g.present) {
                        parsed.module_enabled[k] = false;
                        ui::warn(std::string(MODULES[k].flag) +
                                 " requested but the hardware wasn't detected — skipping");
                    }
                }
            } else {
                // Default / --full: hardware modules mirror detection.
                int k;
                if ((k = find_idx("nvidia"))             >= 0) parsed.module_enabled[k] = false;
                if ((k = find_idx("amd_gpu"))            >= 0) parsed.module_enabled[k] = false;
                if ((k = find_idx("intel_gpu"))          >= 0) parsed.module_enabled[k] = false;
                // The fingerprint chain is atomic + hardware-gated: present →
                // all four on, absent → all four off (even under --full, so we
                // never wire pam_fprintd on a box with no reader).
                if ((k = find_idx("fprint"))             >= 0) parsed.module_enabled[k] = false;
                if ((k = find_idx("fprint_pam"))         >= 0) parsed.module_enabled[k] = false;
                if ((k = find_idx("greetd_fingerprint")) >= 0) parsed.module_enabled[k] = false;
                if ((k = find_idx("sudo_fingerprint"))   >= 0) parsed.module_enabled[k] = false;

                if (ctx.has_nvidia)    enable_slug("nvidia");
                if (ctx.has_amd_gpu)   enable_slug("amd_gpu");
                if (ctx.has_intel_gpu) enable_slug("intel_gpu");
                if (ctx.has_fprint) {
                    // fprint installs the daemon + enrolls; the three PAM
                    // modules splice pam_fprintd `sufficient` (password always
                    // falls through). Safe to auto-enable: each self-skips on
                    // unenrolled readers / unsafe PAM stacks (B1/B2 gates), and
                    // recovery_entry guarantees a console escape hatch.
                    enable_slug("fprint");
                    enable_slug("fprint_pam");
                    enable_slug("greetd_fingerprint");
                    enable_slug("sudo_fingerprint");
                }
            }
        }
    }

    fs::path state_file = ctx.home / ".local/share/foxml/install_state";

    // --resume: pick up where the last failed install left off. The
    // dispatcher writes the just-completed module's index to
    // state_file after each success and clears it on clean exit, so
    // a non-empty state_file means "previous run failed at this index
    // — resume at the NEXT module."
    if (parsed.resume) {
        if (fs::exists(state_file)) {
            std::ifstream f(state_file);
            int last_done = -1;
            if (f >> last_done && last_done >= 0) {
                ctx.resume_idx = last_done + 1;
                ui::section("Resuming from module index " + std::to_string(ctx.resume_idx)
                            + " (last success: " + std::to_string(last_done) + ")");
            }
        } else {
            ui::warn("--resume: no prior install_state file — running from the top");
        }
    }

    // --phase <slug>: skip ahead to a specific module by name. Overrides
    // --resume if both are passed (explicit slug wins over implicit
    // last-failure position). Unknown slug = abort to avoid silently
    // running the whole install with no skip.
    if (!parsed.phase.empty()) {
        int found = -1;
        for (std::size_t k = 0; k < MODULES_COUNT; ++k) {
            if (parsed.phase == MODULES[k].slug) {
                found = static_cast<int>(k);
                break;
            }
        }
        if (found < 0) {
            ui::err("--phase: unknown module slug '" + parsed.phase + "'");
            return 2;
        }
        ctx.resume_idx = found;
        ui::section("Skipping ahead to phase '" + parsed.phase
                    + "' (index " + std::to_string(found) + ")");
    }

    // Phase 6 Step 20: state-driven is now the DEFAULT install path.
    // The wizard + preview + manifest fire on every interactive run;
    // the legacy inline-prompt path lives behind FOX_INSTALL_LEGACY=1
    // as an escape hatch for users hitting a regression we haven't
    // caught yet. FOX_INSTALL_STATE_DRIVEN=1 is still recognized but
    // is now a no-op (kept so existing shell aliases don't break).
    bool state_driven = true;
    if (const char* env = std::getenv("FOX_INSTALL_LEGACY");
            env && std::string(env) == "1") {
        state_driven = false;
        ui::warn("FOX_INSTALL_LEGACY=1: running the legacy inline-prompt "
                 "path. Drop the env var to use the state-driven flow.");
    }

    if (state_driven) {
        // Phase 6 Step 12: route child-process stderr into a per-run
        // log file so failed pacman/systemctl/git output doesn't
        // scroll past during a long install. The dispatcher tails
        // this on module failure to surface the most-recent errors.
        // Path mirrors the XDG convention used by state_manifest.
        const char* xdg_state = std::getenv("XDG_STATE_HOME");
        fs::path log_dir = (xdg_state && *xdg_state)
            ? fs::path(xdg_state) / "foxml"
            : ctx.home / ".local/state/foxml";
        char ts[32]{};
        std::time_t now = std::time(nullptr);
        std::tm* tm_now = std::localtime(&now);
        if (tm_now) std::strftime(ts, sizeof(ts), "%Y%m%d-%H%M%S", tm_now);
        const fs::path install_log = log_dir / (std::string("install-") + ts + ".log");
        sh::set_stderr_log(install_log);
        sh::log_section("fox-install start (state-driven)");

        std::vector<const Module*> mods;
        mods.reserve(MODULES_COUNT);
        for (std::size_t i = 0; i < MODULES_COUNT; ++i) mods.push_back(&MODULES[i]);

        wizard::Plan plan = wizard::default_plan(mods, ctx, manifest);

        // CLI layer (--full, --no-X, --only, explicit module flags,
        // --reapply, detect's hardware gates) — [I-08]: a flag the
        // parser accepted must take effect; overrides are loud or
        // impossible. Logic lives in wizard.cpp so test_wizard can
        // pin the precedence.
        wizard::apply_cli_layer(plan, parsed.module_enabled,
                                parsed.only, parsed.full,
                                ctx.force_reapply);

        // Phase 6 Step 13: --full repair-mode semantics. When the user
        // explicitly asks to re-apply everything, "Keep mine" is the
        // wrong safe-default — they ARE asking us to overwrite, just
        // safely. Promote every Conflict to BackupThenTakeNew so the
        // user's pre-install copy survives as .foxml-bak. Also flip
        // assume_yes so the wizard + preview short-circuit; --full is
        // a non-interactive "just do it" gesture.
        if (parsed.full) {
            ui::section("Repair mode (--full) — drift-correcting defaults");
            for (auto& mp : plan.modules) {
                if (mp.action == wizard::Action::Conflict) {
                    mp.conflict_decision = conflict::Decision::BackupThenTakeNew;
                }
            }
            ctx.assume_yes = true;
        }

        plan = wizard::run(std::move(plan), ctx);
        if (plan.aborted) {
            ui::warn("install aborted at wizard — no modules will run");
            return 1;
        }
        if (!wizard::preview(plan, ctx)) {
            ui::warn("install plan declined at preview — no modules will run");
            return 0;
        }

        // Resolve conflict_decision values into Run/Skip + side effects
        // (e.g., .foxml-bak snapshots) before translating into the
        // per-index module_enabled array.
        wizard::apply_conflict_decisions(plan, ctx);

        for (std::size_t i = 0; i < plan.modules.size() && i < MODULES_COUNT; ++i) {
            parsed.module_enabled[i] = (plan.modules[i].action != wizard::Action::Skip);
        }
    }

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

    if (ctx.dry_run && !state_driven) {
        // state_driven runs already showed the user the full plan via
        // wizard::preview — skip this legacy summary to avoid printing
        // the same module list twice.
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

    // Warm sudo once, up front, before any module runs. install.sh does
    // this for its own invocation (+ a keepalive loop); doing it here too
    // means the bare `fox-install` binary behaves the same when run
    // directly — otherwise the first root-needing module hits a cold
    // cache and bails, and because most such modules are plain FOX_MODULE
    // (requires_root=false in metadata) we can't reliably pre-filter, so
    // we just warm on any real interactive run. Non-fatal: each module
    // re-checks sudo itself, so a decline here only defers the prompt.
    if (!sh::dry_run() && ui::tty() && total_enabled > 0) {
        if (!sh::sudo_warmup_interactive()) {
            ui::warn("sudo not warmed — root-needing modules will report "
                     "errors and self-skip (run `sudo -v`, then re-run)");
        }
    }

    std::vector<std::string> failed_modules;
    std::vector<std::string> soft_error_modules;
    for (std::size_t i = 0; i < MODULES_COUNT; ++i) {
        if (ctx.resume_idx > 0 && static_cast<int>(i) < ctx.resume_idx) continue;

        const Module& m = MODULES[i];
        bool should_run = parsed.module_enabled[i];

        // --- Inline Interactive Decision ---
        // Suppressed when state_driven is on: the wizard already
        // collected per-module decisions ahead of the main loop, and
        // re-prompting here would be redundant + would let the user
        // un-do their wizard choices module-by-module.
        if (!ctx.assume_yes && !state_driven && ui::tty()) {
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
                    if ((std::string(m.slug) == "throttling" ||
                         std::string(m.slug) == "battery") && !ctx.is_laptop) {
                        should_run = false;
                    } else {
                        bool risky = (std::string(m.slug) == "fprint_pam" ||
                                      std::string(m.slug) == "greetd_fingerprint" ||
                                      std::string(m.slug) == "sudo_fingerprint");
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

        sh::log_section(std::string("module: ") + m.slug);
        const int errs_before = ui::error_count();
        try {
            m.fn(ctx);
            sh::log_section(std::string("/module: ") + m.slug + " (ok)");

            // A module that printed err() but returned normally (the
            // cold-sudo self-skip pattern) ran INCOMPLETE — track it so
            // the end summary can't claim a clean run it didn't have.
            if (ui::error_count() > errs_before) {
                soft_error_modules.emplace_back(m.slug);
            }

            // Preflight is allowed to refuse the run entirely. If it
            // flipped preflight_failed, no later module is safe — even
            // the read-only ones — because the running system itself
            // is in a half-upgraded state. Abort here, before anything
            // mutates state or writes to the bootloader.
            if (ctx.preflight_failed) {
                ui::err("preflight reported a critical health failure — aborting install");
                ui::substep("run `fox sec health --verbose` for full detail + fix hints; resolve and re-run");
                return 1;
            }

            // Update resume state after success
            if (!ctx.dry_run) {
                fs::create_directories(state_file.parent_path());
                std::ofstream f(state_file);
                f << i << std::endl;
            }

            // Record per-module success in the state manifest. For
            // modules with a known sentinel file (the same lookup
            // apply_conflict_decisions uses), hash the deployed copy
            // and store it as source_hash so the next install's
            // classifier can compare hashes properly. Without this,
            // state_checks that compare against source_hash (render,
            // mac_random) would see (deployed != "", stored == "")
            // and report Conflict on every subsequent run, defeating
            // the whole point of state-driven re-installs.
            std::string new_source_hash;
            if (state_driven) {
                if (auto sentinel = wizard::conflict_sentinel(m.slug, ctx);
                        sentinel && fs::exists(*sentinel)) {
                    try {
                        new_source_hash = state::hash_file(*sentinel);
                    } catch (const std::exception& e) {
                        ui::warn(std::string(m.slug) + ": could not hash "
                                 + sentinel->string() + " for manifest: " + e.what());
                    }
                }
            }
            manifest.modules[m.slug] = state::ModuleState{
                /* version    */ "",
                /* source_hash*/ new_source_hash,
                /* deployed_at*/ state::now_iso8601(),
            };
        } catch (const std::exception& e) {
            sh::log_section(std::string("/module: ") + m.slug + " (FAILED: " + e.what() + ")");
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
    ui::summary_row("incomplete", std::to_string(soft_error_modules.size()));

    if (!soft_error_modules.empty()) {
        std::printf("\n");
        ui::warn("modules that reported errors (ran, but incomplete):");
        std::string slugs;
        for (const auto& s : soft_error_modules) {
            std::printf("    \xE2\x80\xA2 %s\n", s.c_str());
            slugs += (slugs.empty() ? "" : ",") + s;
        }
        ui::substep("commonly a cold sudo cache — `sudo -v`, then: "
                    "fox-install --only " + slugs);
    }

    // Mid-install errors (failed pacman calls, missing packages, etc.)
    // can scroll past while the user is watching. Re-list them at the
    // tail so they're impossible to miss, with the suggested fix in
    // one line. This keeps the bash habit of "run --deps after a
    // pacman -Syu" actionable instead of buried.
    if (!failed_modules.empty()) {
        std::printf("\n");
        ui::err("modules with failures:");
        for (auto& m : failed_modules) {
            std::printf("    • %s — re-run with: fox-install --only %s\n",
                        m.c_str(), m.c_str());
        }

        // Phase 6 Step 12: surface the captured child stderr from the
        // log file. When state-driven, sh::set_stderr_log was set at
        // install start; everything that pacman/systemctl/git wrote to
        // stderr from inside the failing module landed there. Tail it
        // so the user sees the actual error message without having to
        // open the log themselves.
        if (!sh::stderr_log().empty()) {
            auto tail = sh::tail_log(20);
            if (!tail.empty()) {
                std::printf("\n  last 20 lines from %s:\n", sh::stderr_log().c_str());
                for (const auto& line : tail) {
                    std::printf("    %s\n", line.c_str());
                }
            }
        }

        std::printf("\n  Common fixes:\n"
                    "    • pacman dep-resolution errors → sudo pacman -Syu, then retry\n"
                    "    • systemctl enable failures → sudo -v, then retry\n"
                    "    • module-specific errors → check the error line above\n");
    }
    return failed_modules.empty() ? 0 : 1;
}
