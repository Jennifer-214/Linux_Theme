// Link stubs for every module run function referenced by modules.def.
// SINGLE SOURCE — included (inside `namespace fox_install`) by every
// test binary that links core/registry.o (test_registry, test_args).
// The tests only inspect the table; these are never invoked.
// Adding a new module = one stub line here (a missing one is a linker
// error in both tests — the desired compile-time enforcement).
// NB: personalize + personalization_done share run_personalize — one
// stub covers both registry rows; don't add a second.
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
void run_bt_power        (Context&) {}
void run_noexec_tmp      (Context&) {}
void run_iommu           (Context&) {}
void run_lockdown_heal   (Context&) {}
void run_boot_sync       (Context&) {}
void run_battery         (Context&) {}
void run_recovery_entry  (Context&) {}
void run_foxml_health_hook(Context&) {}
void run_foxml_health_boot(Context&) {}
void run_foxml_health_timer(Context&) {}
void run_sudo_fingerprint(Context&) {}
void run_makepkg_hardening(Context&) {}
void run_safe_updates    (Context&) {}
void run_fwupd           (Context&) {}
void run_etckeeper       (Context&) {}
void run_catppuccin_cursor(Context&) {}
void run_papirus_icons   (Context&) {}
void run_zsh_plugins     (Context&) {}
void run_post_install        (Context&) {}
void run_prune_backups       (Context&) {}
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
void run_reboot_polkit(Context&) {}
void run_fprintd_reset_polkit(Context&) {}
void run_ufw         (Context&) {}
void run_wallpaper   (Context&) {}
void run_render      (Context&) {}
void run_symlinks    (Context&) {}
void run_keybind_docs(Context&) {}
void run_specials    (Context&) {}
void run_vault       (Context&) {}
void run_ai              (Context&) {}
void run_ollama_hardening(Context&) {}
void run_models      (Context&) {}
void run_github      (Context&) {}
void run_gaming      (Context&) {}
void run_amd_gpu     (Context&) {}
void run_intel_gpu   (Context&) {}
void run_nvidia      (Context&) {}
void run_fprint      (Context&) {}
void run_fprint_pam  (Context&) {}
void run_hyprlock_pam(Context&) {}
void run_ssh_harden  (Context&) {}
void run_xgboost     (Context&) {}
void run_cpp_pro     (Context&) {}
void run_monitors    (Context&) {}
void run_personalize (Context&) {}
void run_welcome_banner(Context&) {}
void run_summary     (Context&) {}
