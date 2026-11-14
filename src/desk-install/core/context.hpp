#ifndef FOX_INSTALL_CONTEXT_HPP
#define FOX_INSTALL_CONTEXT_HPP

#include <filesystem>
#include <string>

namespace desk_install {

// Shared state passed by reference into every module's run_*() function.
// Modules read fields they care about and may set fields others depend
// on (e.g. detect.cpp sets has_nvidia; nvidia.cpp reads it).
struct Context {
    // Paths derived from argv[0] / CWD at startup.
    std::filesystem::path script_dir;       // repo root
    std::filesystem::path templates_dir;    // <script_dir>/templates
    std::filesystem::path themes_dir;       // <script_dir>/themes
    std::filesystem::path shared_dir;       // <script_dir>/shared
    std::filesystem::path rendered_dir;     // <script_dir>/rendered
    std::filesystem::path home;             // $HOME
    std::filesystem::path config_home;      // $XDG_CONFIG_HOME or ~/.config

    // Backup root for this install run. Set once in main() before any
    // module runs (e.g. ~/.theme_backups/foxml-backup-20260512-180317).
    // symlinks/specials/security/etc. snapshot pre-existing files here
    // before overwrite — same convention as the bash backup_and_copy.
    std::filesystem::path backup_dir;

    // Theme selection.
    std::string theme_name;
    std::string theme_source;               // why this theme: shown by the theme module
    std::filesystem::path palette_path;     // <themes_dir>/<theme>/palette.sh

    // Global flags.
    bool assume_yes = false;
    bool dry_run    = false;
    bool quiet      = false;
    bool render_only = false;

    // Wallpaper.
    bool rotate_wallpapers = false;       // --rotate-wallpapers (default off)
    bool rotate_decided = false;          // a flag or the wallpaper module chose; else specials keeps the live mode

    // Opt-in fine-grained hardening. Bash kept these as separate
    // INSTALL_* flags so --full could enable the security suite
    // without flipping every annoying daily-use toggle on.
    bool install_polkit_strict = false;   // --polkit-strict (off by default;
                                          // enabled by --full unless wizard
                                          // declines it)
    bool cpp_pro = false;                 // --cpp-pro (opt-in)

    // Set by --full. Modules that have "already done — skipping" early
    // returns honor this by re-applying their work instead of bailing.
    // Genuinely expensive ops (model downloads, big archive
    // pulls) keep their skip-if-present checks regardless.
    bool force_reapply = false;

    // Set by run_render: render_ran once it executes; render_ok only on a
    // successful render. run_symlinks reads them to refuse a partial deploy
    // when render failed (a partial config tree → a box with no hyprland.conf,
    // reported as success — the silent-partial-deploy trap).
    bool render_ran = false;
    bool render_ok  = false;
    // Set when a theme file could not be deployed (the run is incomplete).
    bool deploy_failed = false;
    // Set when the rendered configs themselves were not deployed: the desktop is still on the old theme, so the theme
    // name is not saved. A greeter, drawer or integration failure leaves the desktop on the new one.
    bool configs_failed = false;
    // A module that stops the whole run (render, protecting live edits) sets the exit code here; the modules after it
    // do not run, and the manifest still records the ones before it.
    int stop_code = 0;

    // Hardware detection (filled by the detect module).
    bool has_nvidia   = false;
    bool has_amd_gpu  = false;
    bool has_intel_gpu = false;
    bool is_laptop    = false;
    bool has_fprint   = false;
    // run_detect() is idempotent: it runs upfront in main() AND can be
    // re-invoked by the dispatch loop (the wizard plan re-enables detect).
    // Guard so detection + hardware prompts happen exactly once and never
    // clobber the user's opt-out choices.
    bool detect_ran   = false;

    // Resumable install state.
    int resume_idx = -1;                  // if >= 0, skip modules before this index

    // Set by preflight when it finds a state no later module can safely
    // run on (e.g. running kernel's /lib/modules/X tree is gone —
    // partial-upgrade artifact). Dispatcher aborts before the first
    // mutating module.
    bool preflight_failed = false;
};

}  // namespace desk_install

#endif
