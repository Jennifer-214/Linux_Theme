// state_checks.hpp — per-module introspection callbacks.
//
// Phase 6 Step 6. Each function inspects the running system (pacman -Qi,
// systemctl is-enabled, file hashes, …) and returns a Classification
// the dispatcher uses to decide whether to skip, re-run, or prompt.
//
// Wired into the registry via FOX_MODULE_FULL in modules.def. Modules
// without a state_check pointer (i.e. legacy FOX_MODULE entries) are
// classified as Fresh by the dispatcher — current behavior preserved.

#pragma once

#include "classifier.hpp"
#include "context.hpp"
#include "state_manifest.hpp"

#include <string>
#include <vector>

namespace fox_install::state {

// package_classify — pure "did module X install package P?" logic, the
// core of package_check, split out so it's unit-testable without invoking
// pacman. present = is the pkg installed now; tracked = does the manifest
// have the module's slug. (untracked+present → Noop, untracked+absent →
// Fresh, tracked+present → Noop, tracked+absent → Update.)
Classification package_classify(bool present, bool tracked,
                                const std::string& slug, const std::string& pkg);

// deps — pacman base packages. One `pacman -T` over every package run_deps installs (core/deps_list.hpp). If the
// manifest has no deps entry, we assume nothing has been installed. All present → Noop; any missing → Update.
Classification check_deps     (const Context& ctx, const Manifest& manifest);

// check_deps's verdict from one `pacman -T <every deps_packages() name>` (pacman 7.1: prints each missing name, one per
// line, and exits 127; exits 0 when all are present; a provided name counts as present). Pure, for the test.
Classification deps_classification(int rc, const std::string& out, std::size_t total);
// The query itself: pacman -T and every deps_packages() name.
std::vector<std::string> deps_probe_argv();

// render — templated config deploy. Compares the deployed copy of a
// sentinel rendered file (~/.config/hypr/hyprland.conf) against the
// stored source_hash from the manifest. No manifest entry → Fresh.
// Hash match → Noop. Hash differ → Update. File missing → Conflict.
Classification check_render   (const Context& ctx, const Manifest& manifest);

// The render's inputs, hashed: every file under templates/ (relative path and contents, in path order), the palette's
// contents and the theme name. run_render stamps rendered/.render-inputs with it after a real render, so a stamp
// that differs means rendered/ is older than what it would render now.
std::string render_inputs_hash(const Context& ctx);
std::filesystem::path render_stamp_path(const Context& ctx);
// rendered/ matches today's templates + palette. True when there are no templates to judge by (nothing to compare).
bool rendered_is_current(const Context& ctx);

// etckeeper — git /etc + fox-etcwatch.path user unit. Surfaces the
// masked-state hazard explicitly per R5/R6: a masked unit is Blocked,
// not Conflict, because nothing the installer does will recover it
// without a manual `systemctl --user unmask` first.
Classification check_etckeeper(const Context& ctx, const Manifest& manifest);

// arch_audit — foxml-arch-audit.timer (user systemd). Same masked-
// state hazard pattern as etckeeper.
Classification check_arch_audit(const Context& ctx, const Manifest& manifest);

// vault — fox-vault.service (user systemd). Same masked-state pattern.
Classification check_vault(const Context& ctx, const Manifest& manifest);

// mac_random — /etc/NetworkManager/conf.d/00-foxml-mac-random.conf
// (system file). Hashes the deployed copy and compares to the
// manifest-stored hash. No systemd unit, so no Blocked state.
Classification check_mac_random(const Context& ctx, const Manifest& manifest);

// ufw — system systemd unit. Masked → Blocked. Same shape as
// check_etckeeper except the unit is system-scope.
Classification check_ufw(const Context& ctx, const Manifest& manifest);

// endlessh — system systemd unit. Checks endlessh.service (the AUR
// build is endlessh-go.service; close enough for v1 — the install
// module re-runs either way if the primary unit isn't enabled).
Classification check_endlessh(const Context& ctx, const Manifest& manifest);

// greetd — system systemd unit. Themed login manager.
Classification check_greetd(const Context& ctx, const Manifest& manifest);

// papirus_icons — pacman package `papirus-icon-theme`. Installed
// flips to Noop when manifest tracked; missing flips to Update.
Classification check_papirus_icons(const Context& ctx, const Manifest& manifest);

// catppuccin_cursor — checks for the cursor theme directory
// (~/.icons/catppuccin-mocha-peach-cursors/cursors). Present + tracked
// = Noop; missing + tracked = Update; either + untracked = Fresh.
Classification check_catppuccin_cursor(const Context& ctx, const Manifest& manifest);

// gpg_agent_cache — writes ~/.gnupg/gpg-agent.conf with extended
// passphrase cache TTL. File existence is the sentinel.
Classification check_gpg_agent_cache(const Context& ctx, const Manifest& manifest);

// keyring_full — masks four gnome-keyring autostart units so the
// SSH + GPG components fully take over. State check: is the
// canonical sentinel unit masked?
Classification check_keyring_full(const Context& ctx, const Manifest& manifest);

// noexec_tmp — adds noexec/nosuid/nodev mount options to /tmp +
// /dev/shm via /etc/fstab. State check: does fstab already have a
// locked-down /tmp tmpfs line?
Classification check_noexec_tmp(const Context& ctx, const Manifest& manifest);

// gaming — pacman package `steam` (opt-in 32-bit gaming module). Present
// → Noop; tracked + missing → Update (re-install); untracked + present →
// already-done. Mirrors check_papirus_icons.
Classification check_gaming(const Context& ctx, const Manifest& manifest);

}  // namespace fox_install::state
