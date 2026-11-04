#!/bin/bash
# FoxML Theme Hub — Installer
# Renders templates with theme palette, copies to system
# Usage: ./install.sh [theme_name] [--deps] [--secure] [--perf] [--privacy]
#                     [--vault] [--ai] [--models] [--github] [--nvidia]
#                     [--xgboost] [--full|--all] [--render-only] [-y|--yes]
#
# --full / --all: enables every opt-in module except --xgboost.
# FOXML_NO_UPDATE=1: skip the auto-update + re-exec at startup.

set -e

# ─────────────────────────────────────────
# Silent-error protection.
#
# set -e is good (catches genuine bugs) but BAD when combined with
# `sudo cmd >/dev/null 2>&1` — a cold sudo cache silently fails, set -e
# aborts the installer, EXIT trap runs the finalizer, and the user sees
# nothing about what actually broke. The install just… ends.
#
# This ERR trap fires on every uncaught failure that would otherwise
# trigger set -e and prints WHERE and WHAT. The EXIT trap still runs
# afterward (so the multi-monitor finalizers still fire), but now the
# user sees a clear "Installer aborted at line N: <command>" instead of
# silent termination.
#
# Bash inherits the trap into functions only when `set -E` is also on,
# so commands inside install_security / install_vault / etc. are also
# covered.
# ─────────────────────────────────────────
set -E
_foxml_err_trap() {
    local exit_code=$1 lineno=$2 cmd=$3
    # `_foxml_err_silent=1` is a per-command opt-out: any caller that
    # genuinely expects a non-zero exit (e.g. `if cmd; then`) is already
    # filtered out by bash's ERR semantics. This var is here for any
    # future contributors who want to suppress a specific noisy section.
    [[ "${_foxml_err_silent:-0}" == "1" ]] && return 0
    echo "" >&2
    echo "──────────────────────────────────────────────────────────" >&2
    echo " ✗ Installer aborted at line ${lineno} (exit ${exit_code})" >&2
    echo "   failed command: ${cmd}" >&2
    echo "" >&2
    echo "   Common causes:" >&2
    echo "     • sudo cache expired — re-run with: sudo -v && fox install --full" >&2
    echo "     • network glitch during a git clone / model pull — retry" >&2
    echo "     • disk full / permission issue — check the failed path above" >&2
    echo "" >&2
    echo "   The EXIT-trap finalizer will still run to leave the system" >&2
    echo "   in a consistent state. fox doctor will tell you what's missing." >&2
    echo "──────────────────────────────────────────────────────────" >&2
}
trap '_foxml_err_trap $? $LINENO "$BASH_COMMAND"' ERR

# LEGACY-WRAPPER NOTE: this script lives in legacy/ but operates on
# files at the repo root (templates/, themes/, shared/, .active-theme).
# SCRIPT_DIR therefore resolves to the parent of this file's dir, and
# the bash mappings.sh that this script depends on is sourced from the
# legacy/ dir directly (the root mappings.sh is the post-cutover
# runtime-only version and is missing the install_* functions).
LEGACY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$LEGACY_DIR/.." && pwd)"
THEMES_DIR="$SCRIPT_DIR/themes"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
SHARED_DIR="$SCRIPT_DIR/shared"
ACTIVE_FILE="$SCRIPT_DIR/.active-theme"
BACKUP_DIR="$HOME/.theme_backups/foxml-backup-$(date +%Y%m%d-%H%M%S)"

# ─────────────────────────────────────────
# Self-update — pull latest installer from origin/main and re-exec
# before doing any destructive work. Runs ahead of mappings.sh / render.sh
# sourcing so the re-execed process picks up updated helpers too.
#
# Skip conditions (any one short-circuits to current version):
#   - FOXML_NO_UPDATE=1 in env (explicit pin / offline / dev)
#   - FOXML_UPDATED=1 in env (already re-execed, prevents loop)
#   - SCRIPT_DIR isn't inside a git work tree (curl-bash from tarball)
#   - HEAD isn't on main (don't auto-update arbitrary branches)
#   - working tree dirty (don't clobber in-progress edits)
#   - fetch fails within 15s (offline / GitHub down)
#   - pull would require non-FF (local commits ahead)
# ─────────────────────────────────────────
foxml_self_update() {
    [[ "${FOXML_NO_UPDATE:-0}" == "1" ]] && return
    [[ "${FOXML_UPDATED:-0}"   == "1" ]] && return
    git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return

    local branch
    branch="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [[ "$branch" != "main" ]]; then
        echo "  • installer on branch '$branch' (not main), skipping auto-update"
        return
    fi
    if ! git -C "$SCRIPT_DIR" diff --quiet HEAD 2>/dev/null; then
        echo "  • installer has uncommitted changes, skipping auto-update"
        return
    fi

    echo "Checking for installer updates..."
    if ! timeout 15 git -C "$SCRIPT_DIR" fetch --quiet origin main 2>/dev/null; then
        echo "  • fetch failed (offline?), continuing with current version"
        return
    fi

    local local_sha remote_sha
    local_sha="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
    remote_sha="$(git -C "$SCRIPT_DIR" rev-parse origin/main 2>/dev/null)"
    if [[ -z "$remote_sha" || "$local_sha" == "$remote_sha" ]]; then
        echo "  installer up-to-date ($(git -C "$SCRIPT_DIR" rev-parse --short HEAD))"
        return
    fi

    # Detect ahead/behind/diverged. Before we just printed "Pulling
    # updates: <local> → <remote>" unconditionally — confusing when
    # local was ahead of remote (looked like a downgrade was about to
    # happen). Use --count to label the direction precisely.
    local ahead behind
    read -r behind ahead < <(git -C "$SCRIPT_DIR" rev-list --left-right --count origin/main...HEAD 2>/dev/null)
    ahead="${ahead:-0}"; behind="${behind:-0}"

    if (( ahead > 0 && behind == 0 )); then
        echo "  • local is ${ahead} commit(s) AHEAD of origin/main — nothing to pull"
        echo "    (push your work with: git push origin main)"
        return
    fi
    if (( ahead > 0 && behind > 0 )); then
        echo "  ! local has diverged from origin (${ahead} ahead / ${behind} behind), skipping auto-update"
        echo "    rebase or merge manually before re-running"
        return
    fi

    echo "  Pulling updates: $(git -C "$SCRIPT_DIR" rev-parse --short HEAD) → $(git -C "$SCRIPT_DIR" rev-parse --short origin/main)"
    if ! git -C "$SCRIPT_DIR" pull --ff-only --quiet origin main 2>/dev/null; then
        echo "  ! non-fast-forward (local commits ahead?), continuing with current version"
        return
    fi

    # SUPPLY-CHAIN GUARD: verify the new HEAD commit is GPG-signed by a
    # trusted key BEFORE re-exec'ing it. A compromised GitHub account
    # or MITM on git fetch could otherwise auto-install attacker code
    # with the warmed sudo cache.
    #
    # FOXML_TRUSTED_SIGNERS in the user's env (or ~/.config/foxml/trusted-signers,
    # one fingerprint per line) lists the keys we'll accept. Default
    # falls back to the committer's own key if no trust file exists —
    # better than no check, weaker than an explicit allowlist.
    local _trust_file="$HOME/.config/foxml/trusted-signers"
    local _allow_unsigned="${FOXML_ALLOW_UNSIGNED_UPDATE:-0}"
    if (( _allow_unsigned != 1 )); then
        # `git verify-commit` returns 0 only when the signature is good AND
        # the key is in the user's gpg keyring (trusted via gpg's web of
        # trust or explicit trustdb).
        if ! git -C "$SCRIPT_DIR" verify-commit --raw HEAD >/dev/null 2>&1; then
            echo "  ! pulled HEAD is NOT verifiably signed — refusing to auto-exec" >&2
            echo "    rollback to pre-pull state + bail (will not run attacker code)." >&2
            git -C "$SCRIPT_DIR" reset --hard "ORIG_HEAD" >/dev/null 2>&1 || true
            echo "    if you trust this update, override with:" >&2
            echo "      FOXML_ALLOW_UNSIGNED_UPDATE=1 fox install --full" >&2
            echo "    or import the maintainer's key first:" >&2
            echo "      gh api /users/Jennifer-214/gpg_keys --jq '.[].raw_key' | gpg --import" >&2
            return
        fi
        # Belt + suspenders: when a trust-file exists, require the
        # signing key to be in it explicitly. Otherwise the default
        # gpg-keyring check is enough.
        if [[ -f "$_trust_file" ]]; then
            local _signer_fpr
            _signer_fpr=$(git -C "$SCRIPT_DIR" log -1 --format='%GF' 2>/dev/null)
            if [[ -z "$_signer_fpr" ]] || ! grep -qF "$_signer_fpr" "$_trust_file" 2>/dev/null; then
                echo "  ! commit signer ${_signer_fpr:-<unknown>} not in $_trust_file" >&2
                echo "    refusing auto-exec. Verify the key + add its fingerprint to the trust file." >&2
                git -C "$SCRIPT_DIR" reset --hard "ORIG_HEAD" >/dev/null 2>&1 || true
                return
            fi
        fi
    fi

    echo "  Installer updated (commit verified), re-executing with new version..."
    export FOXML_UPDATED=1
    exec "$SCRIPT_DIR/install.sh" "$@"
}
foxml_self_update "$@"

source "$LEGACY_DIR/mappings.sh"
source "$SCRIPT_DIR/render.sh"

# ─────────────────────────────────────────
# Robustness helpers — used at every section boundary that touches
# privileged operations. Together they guarantee:
#   • Sudo failure mid-install is logged and the affected section
#     degrades gracefully instead of aborting the whole install.
#   • Idempotent finalizers (multi-monitor personalize + ollama
#     hardening drop-in) always run, even when the main flow exits
#     early via `set -e`. The EXIT trap below catches that case.
# ─────────────────────────────────────────

# _foxml_sudo_check — re-prime sudo before a privileged section.
# Returns 0 if sudo cache is now warm. Returns 1 + warning when sudo
# is unavailable (cache expired without TTY, fingerprint timeout in
# a non-interactive context, etc.). Callers gate their section on the
# return code so install continues even when sudo can't authenticate.
_foxml_sudo_check() {
    local section="${1:-this section}"
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    # Try to re-prime once interactively. If the user isn't at a TTY
    # this fails immediately rather than hanging.
    if [[ -t 0 ]] && sudo -v 2>/dev/null; then
        return 0
    fi
    if command -v foxml_warn >/dev/null 2>&1; then
        foxml_warn "sudo unavailable — skipping ${section}"
    else
        echo "  ! sudo unavailable — skipping ${section}" >&2
    fi
    return 1
}

# _foxml_finalize — registered as EXIT trap below. Runs the
# idempotent helpers that put the system in its final state
# regardless of how install.sh exited. Functions called here MUST
# be safe to invoke on:
#   • a fully-completed install (they're no-ops)
#   • a half-completed install (they finish the work)
#   • install that aborted before reaching them (they do their work)
# Errors inside the finalizer are swallowed so the trap doesn't
# mask the original exit code with its own failures.
_foxml_finalize() {
    local exit_code=$?
    # Suppress the ERR trap during finalization — otherwise any non-zero
    # command in the cleanup (e.g. systemctl probe in a degraded state)
    # double-prints the same "Installer aborted at line N" banner. The
    # original abort was already logged; the finalizer just needs to do
    # its idempotent best-effort work quietly.
    trap - ERR
    set +e
    # Don't run during very-early failures (before flags are even parsed)
    # or in dry-run mode.
    if [[ "${DRY_RUN:-false}" == "true" ]] || [[ "${RENDER_ONLY:-false}" == "true" ]]; then
        return $exit_code
    fi

    # Multi-monitor personalize. Sidecar is the gating condition —
    # without it we don't know which monitors are present. Idempotent
    # in both directions: re-runs on a configured machine no-op, runs
    # on an unfinished install finish the job. Wrapped in a subshell
    # with `set +e` so a single failure here doesn't propagate.
    if [[ -f "$HOME/.config/foxml/monitor-layout.conf" ]]; then
        (
            set +e
            # Silence ALL output here. On normal install exit, the main
            # configure_monitors call already emitted these lines. On
            # abort, the user has bigger concerns than "personalised"
            # success messages — the ERR trap above already printed
            # what failed. The trap is here to guarantee state, not
            # to chat about it.
            _generate_per_monitor_wallpapers >/dev/null 2>&1
            _personalize_hyprlock            >/dev/null 2>&1
            _personalize_workspace_rules     >/dev/null 2>&1
        ) || true
    fi

    # Ollama sandbox drop-in. Only attempt if ollama.service exists
    # AND the drop-in is missing AND we have sudo. install_ollama_hardening
    # itself has the sudo check, but skipping the call entirely when we
    # already know sudo is unavailable keeps the output cleaner.
    if systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service' \
        && [[ ! -f /etc/systemd/system/ollama.service.d/foxml-hardening.conf ]] \
        && _foxml_sudo_check "ollama sandbox finalizer"; then
        install_ollama_hardening || true
    fi

    return $exit_code
}
trap '_foxml_finalize' EXIT

# ─────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────
THEME_NAME=""
INSTALL_DEPS=false
# Security baseline (fail2ban + auditd + waybar status sudoers + the
# optional SSH hardening wizard) is ON by default. Opt out via --no-secure.
# The SSH wizard self-skips in --yes / unattended mode, so auto-on is
# safe for both interactive and CI flows.
INSTALL_SECURITY=true
INSTALL_PERF=false
# Secure-by-default kernel/userspace hardening layers. All default ON;
# opt out individually with --no-hidepid / --no-noexec / --no-iommu /
# --no-coredumps. Heavy / breakage-prone ones (port knocking, dead-man
# USB, tripwire honeypot) remain opt-in via their own --setup commands.
INSTALL_HIDEPID=true       # /proc hidepid=2 (hide other users' procs)
INSTALL_NOEXEC_TMP=true    # /tmp + /dev/shm noexec,nosuid,nodev
INSTALL_IOMMU=true         # intel_iommu=on / amd_iommu=on (DMA isolation)
INSTALL_NO_COREDUMPS=true  # systemd-coredump → Storage=none
# --arm chains `fox arm` at the end of install so every opt-in
# defense gets walked through in the same flow (no second command).
INSTALL_ARM=false
INSTALL_ARM_HEAVY=false
# Privacy (DNS-over-HTTPS via systemd-resolved + privacy.resistFingerprinting
# in Firefox) is part of the secure-by-default stance. Opt out with --no-privacy.
INSTALL_PRIVACY=true
INSTALL_VAULT=false
INSTALL_NVIDIA=false
INSTALL_AMD_GPU=false
INSTALL_INTEL_GPU=false
INSTALL_FPRINT=false
IS_LAPTOP=false
INSTALL_XGBOOST=false
INSTALL_CPP_PRO=false
# Security hardening: ON by default. Opt out individually via --no-*
# flags. install.sh actually applies these only when --deps is set
# (so the required packages get installed in the same run); users doing
# a config-only re-run won't get half-installed hardening.
INSTALL_HARDEN_BROWSER=true
INSTALL_USBGUARD=true
INSTALL_ARCH_AUDIT=true
# MAC randomization stays opt-in — dorm / enterprise WiFi setups
# require a consistent MAC for the network ACL to recognise the device.
INSTALL_MAC_RANDOM=false
# Polkit strict mode — require password for every privileged GUI
# action (no 5-minute cached auth). Opt-in: breaks the convenience of
# "click install, click yes" workflows. Useful when you want the same
# friction in the GUI that sudo without a cookie gives you.
INSTALL_POLKIT_STRICT=false
# AppArmor mandatory access control — opt-in. Modifies kernel cmdline
# (via systemd-boot loader entries or grub default file), enables
# apparmor.service, and loads the shipped baseline profiles. Requires
# a reboot to activate enforcement. Off by default because:
#   - kernel cmdline changes are touchier than userspace tweaks
#   - some apps misbehave under default profiles until tuned
# Once enabled, even a Discord / Firefox compromise can't read
# ~/code/Trading_Software (the AppArmor profile mathematically forbids
# it at the kernel level — better than firejail's userspace sandbox).
INSTALL_APPARMOR=false
INSTALL_AI=false
INSTALL_MODELS=false
INSTALL_GITHUB=false
ASSUME_YES=false
RENDER_ONLY=false
DRY_RUN=false
QUICK=false
RESUME=false
PHASE=""
DEFAULT_THEME="FoxML_Classic"

for arg in "$@"; do
    case "$arg" in
        --deps) INSTALL_DEPS=true ;;
        --secure|--no-secure)
            [[ "$arg" == "--no-secure" ]] && INSTALL_SECURITY=false || INSTALL_SECURITY=true
            ;;
        --perf) INSTALL_PERF=true ;;
        --no-hidepid)       INSTALL_HIDEPID=false ;;
        --no-noexec)        INSTALL_NOEXEC_TMP=false ;;
        --no-iommu)         INSTALL_IOMMU=false ;;
        --no-coredumps)     INSTALL_NO_COREDUMPS=false ;;
        --arm)              INSTALL_ARM=true ;;
        --paranoid)         INSTALL_ARM=true ;;  # alias
        --heavy)            INSTALL_ARM=true; INSTALL_ARM_HEAVY=true ;;
        --privacy|--no-privacy)
            [[ "$arg" == "--no-privacy" ]] && INSTALL_PRIVACY=false || INSTALL_PRIVACY=true
            ;;
        --vault) INSTALL_VAULT=true ;;
        --nvidia)    INSTALL_NVIDIA=true ;;
        --gpu-amd)   INSTALL_AMD_GPU=true ;;
        --gpu-intel) INSTALL_INTEL_GPU=true ;;
        --fprint)    INSTALL_FPRINT=true ;;
        --xgboost) INSTALL_XGBOOST=true ;;
        --cpp-pro) INSTALL_CPP_PRO=true ;;
        --harden-browser|--no-harden-browser)
            [[ "$arg" == "--no-harden-browser" ]] && INSTALL_HARDEN_BROWSER=false || INSTALL_HARDEN_BROWSER=true
            ;;
        --usbguard|--no-usbguard)
            [[ "$arg" == "--no-usbguard" ]] && INSTALL_USBGUARD=false || INSTALL_USBGUARD=true
            ;;
        --arch-audit|--no-arch-audit)
            [[ "$arg" == "--no-arch-audit" ]] && INSTALL_ARCH_AUDIT=false || INSTALL_ARCH_AUDIT=true
            ;;
        --mac-random)       INSTALL_MAC_RANDOM=true ;;
        --polkit-strict)    INSTALL_POLKIT_STRICT=true ;;
        --apparmor)         INSTALL_APPARMOR=true ;;
        --ai) INSTALL_AI=true ;;
        --models) INSTALL_MODELS=true ;;
        --github) INSTALL_GITHUB=true ;;
        --full|--all)
            # Flip every opt-in module on. Excluded by design:
            #   --xgboost       heavy from-source build, niche use
            #   --mac-random    breaks dorm / enterprise / captive WiFi
            #   --polkit-strict daily-use ergonomics tradeoff
            #   --cpp-pro       dev-only toolchain extras
            INSTALL_DEPS=true
            INSTALL_SECURITY=true
            INSTALL_PERF=true
            INSTALL_PRIVACY=true
            INSTALL_VAULT=true
            INSTALL_NVIDIA=true
            INSTALL_AI=true
            INSTALL_MODELS=true
            INSTALL_GITHUB=true
            # AppArmor in --full means a reboot will be required after
            # install; the summary prints a reminder. Kernel cmdline +
            # service enablement are idempotent so a re-run --full is
            # safe.
            INSTALL_APPARMOR=true
            INSTALL_ARM=true   # --full now chains into `fox arm` at the
                               # end too, so one command installs and
                               # walks through every opt-in defense
            ;;
        --render-only) RENDER_ONLY=true ;;
        --dry-run)     DRY_RUN=true ;;
        --quick)       QUICK=true ;;
        --resume)      RESUME=true ;;
        --phase)       PHASE="${arg##*=}"; [[ "$PHASE" == "--phase" ]] && PHASE="next" ;;
        --phase=*)     PHASE="${arg#--phase=}" ;;
        -y|--yes) ASSUME_YES=true ;;
        *) THEME_NAME="$arg" ;;
    esac
done

# ─────────────────────────────────────────
# Hardware auto-detect block.
#
# Three independent detections, each behind a Y/n prompt in interactive
# mode and a warning-only line in --yes mode (don't auto-modify system
# without consent):
#   1. NVIDIA GPU  → nvidia-open-dkms + DKMS headers + boot tweaks
#   2. AMD GPU     → vulkan-radeon + libva-mesa-driver (userspace only)
#   3. Intel GPU   → intel-media-driver + libva-intel-driver (userspace)
#   4. Chassis type (/sys/class/dmi/id/chassis_type) → IS_LAPTOP flag
#   5. Fingerprint reader (USB vendor IDs) → fprintd + PAM integration
#
# All idempotent — re-runs see flags already set and skip prompts.
# ─────────────────────────────────────────

# Chassis: 8/9/10/11/14 = laptop family; 30/31 = tablet/convertible.
# Used to gate the fingerprint prompt (readers are laptop-only) and
# could later inform battery widget defaults.
if [[ -r /sys/class/dmi/id/chassis_type ]]; then
    case "$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)" in
        8|9|10|11|14|30|31) IS_LAPTOP=true ;;
    esac
fi

# Helper: prompt to enable a GPU userspace stack. Same pattern as
# NVIDIA but factored so the three branches stay readable.
# Note the explicit `return 0` on the early-exits — `set -e` is in effect
# at this point of the script, and a bare `return` would inherit the
# previous command's exit status (e.g. 1 from a non-matching grep) and
# kill the whole installer. "No matching GPU" is not an error.
_gpu_prompt() {
    local pattern="$1" vendor_label="$2" pkgs_label="$3" var_to_set="$4"
    local current_val="${!var_to_set}"
    [[ "$current_val" == "true" ]] && return 0
    command -v lspci >/dev/null 2>&1 || return 0
    lspci 2>/dev/null | grep -qE "$pattern" || return 0
    local gpu
    gpu=$(lspci 2>/dev/null | grep -E "$pattern" | head -1 | sed -E 's/^.*: //; s/ \(rev [^)]*\)$//')
    if $ASSUME_YES; then
        foxml_warn "${vendor_label} GPU detected (${gpu}) — pass the matching flag explicitly in --yes mode"
        return
    fi
    echo ""
    foxml_section "${vendor_label} GPU detected"
    foxml_substep "${gpu}"
    read -p "Install ${pkgs_label}? [Y/n] " -n 1 -r
    echo ""
    if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
        printf -v "$var_to_set" '%s' "true"
        foxml_ok "${vendor_label} GPU userspace enabled for this install"
    else
        foxml_substep "skipping ${vendor_label} GPU install"
    fi
}

if ! $INSTALL_NVIDIA; then
    _gpu_prompt '(VGA|3D).*NVIDIA' 'NVIDIA' \
        'nvidia-open-dkms + DKMS headers + Hyprland NVIDIA tweaks' INSTALL_NVIDIA
fi
_gpu_prompt '(VGA|3D).*(AMD|ATI)' 'AMD' \
    'vulkan-radeon + libva-mesa-driver (userspace only, no boot tweaks)' INSTALL_AMD_GPU
_gpu_prompt '(VGA|3D).*Intel' 'Intel' \
    'intel-media-driver + libva-intel-driver + vulkan-intel' INSTALL_INTEL_GPU

# Fingerprint reader: USB vendor IDs covering most consumer readers.
# Laptop-only (chassis_type check) so desktop users with random USB
# devices don't get false positives. PAM integration touches
# /etc/pam.d/system-local-login — strictly behind a prompt.
if $IS_LAPTOP && ! $ASSUME_YES && command -v lsusb >/dev/null 2>&1; then
    fp_vendors='138a|06cb|27c6|1c7a|147e|04f3|0483|08ff'
    if lsusb 2>/dev/null | grep -qiE "ID (${fp_vendors})"; then
        fp_dev=$(lsusb 2>/dev/null | grep -iE "ID (${fp_vendors})" | head -1 | sed -E 's/^Bus [0-9]+ Device [0-9]+: //')
        echo ""
        foxml_section "Fingerprint reader detected"
        foxml_substep "${fp_dev}"
        read -p "Enable fprintd + PAM integration (touches /etc/pam.d/system-local-login)? [y/N] " -n 1 -r
        echo ""
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            INSTALL_FPRINT=true
            foxml_ok "fingerprint stack enabled — you'll be prompted to enroll a finger after install"
        else
            foxml_substep "skipping fingerprint integration"
        fi
    fi
fi

# ─────────────────────────────────────────
# Pre-flight checks. Disk space, connectivity, existing-install marker,
# conflicting WM/DE. Fail fast on hard problems (no disk, no network);
# warn on soft conflicts (other DE installed).
# ─────────────────────────────────────────

# Disk: require ≥5GB free in $HOME for templates + backups + AI binaries.
# --models adds 5-20GB depending on tier; warn separately so user can
# bail before kicking off a multi-GB pull.
_free_home=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$_free_home" && "$_free_home" -lt 5 ]]; then
    foxml_err "less than 5GB free in $HOME (${_free_home}GB) — installer needs headroom for backups + tools"
    exit 1
fi
if $INSTALL_MODELS && [[ -n "$_free_home" && "$_free_home" -lt 25 ]]; then
    foxml_warn "${_free_home}GB free in $HOME — --models pulls 5-20GB depending on tier; consider pruning"
fi

# Connectivity: only matters when the install actually fetches things.
# 3s timeout — fails fast on offline / DNS-broken machines instead of
# letting pacman / git stall mid-run.
if ! $DRY_RUN && ! $RENDER_ONLY \
    && ( $INSTALL_DEPS || $INSTALL_AI || $INSTALL_MODELS || $INSTALL_GITHUB ); then
    if ! timeout 3 curl -sSf https://archlinux.org/ >/dev/null 2>&1; then
        foxml_err "can't reach archlinux.org — installer needs network for pacman / git / ollama"
        foxml_substep "diagnose: ping archlinux.org   /   systemctl status NetworkManager"
        exit 1
    fi
fi

# Existing install: marker file at the end of a successful install
# records the theme + timestamp. --quick on a re-run skips deps/clones
# (the slow parts) and just re-renders + redeploys configs. Without
# --quick, we just nudge.
INSTALL_MARKER="$HOME/.local/share/foxml/.installed-version"
if [[ -f "$INSTALL_MARKER" ]]; then
    _prior=$(cat "$INSTALL_MARKER" 2>/dev/null)
    if $QUICK; then
        foxml_substep "Quick mode: skipping deps/clones (prior install: ${_prior})"
        INSTALL_DEPS=false
        INSTALL_GITHUB=false
        INSTALL_MODELS=false
    else
        foxml_substep "Existing FoxML install detected (${_prior}) — pass --quick to skip deps + clones next time"
    fi
fi

# Phase markers. The installer records its last-completed phase in a
# state file; --resume reads it back and prints guidance. --phase X
# exits cleanly after phase X. The marker pattern is intentionally
# minimal — the existing flags (--deps off, --quick) handle most of
# the "skip-what's-done" needs.
#
# Phase names (in execution order):
#   deps   — pacman + AUR helper + Oh My Zsh + npm globals
#   render — render templates, deploy configs, scripts, modules
#   ai     — Ollama + OpenCode + model pulls + AI skills
#   github — gh auth + ~/code clone-all
#   post   — apply_post_install, install marker, summary
PHASE_STATE_FILE="$HOME/.local/state/foxml/install-state"
if $RESUME && [[ -f "$PHASE_STATE_FILE" ]]; then
    _resume_phase=$(cat "$PHASE_STATE_FILE" 2>/dev/null)
    foxml_substep "last completed phase: '${_resume_phase:-none}'"
    foxml_substep "this run continues from there; pass --quick to skip deps if already installed"
fi
_phase_mark() {
    mkdir -p "$(dirname "$PHASE_STATE_FILE")"
    echo "$1" > "$PHASE_STATE_FILE"
}
_phase_exit_if_done() {
    if [[ -n "$PHASE" && "$PHASE" == "$1" ]]; then
        foxml_substep "phase '$1' complete — exiting (--phase requested)"
        exit 0
    fi
}

# Conflicting WM/DE: warn that configs coexist but Hyprland-specific
# keybinds won't apply if the user logs into the other session.
if command -v pacman >/dev/null 2>&1; then
    _wm_conflicts=()
    pacman -Qi plasma-desktop &>/dev/null && _wm_conflicts+=("KDE Plasma")
    pacman -Qi gnome-shell    &>/dev/null && _wm_conflicts+=("GNOME")
    pacman -Qi sway           &>/dev/null && _wm_conflicts+=("sway")
    pacman -Qi i3-wm          &>/dev/null && _wm_conflicts+=("i3")
    pacman -Qi xfce4-session  &>/dev/null && _wm_conflicts+=("XFCE")
    if (( ${#_wm_conflicts[@]} > 0 )); then
        foxml_warn "another desktop / WM installed: ${_wm_conflicts[*]}"
        foxml_substep "configs will coexist; Hyprland binds only apply inside Hyprland session"
    fi
fi

# Interactive mode: prime sudo at the start of the install so the user
# doesn't get interrupted mid-flow by 4-5 sudo prompts. One prompt at
# the top, keepalive runs for the duration of the privileged sections
# (UFW, fail2ban, sysctls, AppArmor, etc.). Saves typing `sudo -v &&
# fox install --full` every time.
if ! $ASSUME_YES && $INSTALL_DEPS && [[ -t 0 ]]; then
    if ! sudo -n true 2>/dev/null; then
        echo "Prime sudo for the install (avoids prompts mid-flow):"
        sudo -v || { echo "sudo required — re-run when ready"; exit 1; }
    fi
fi

# Non-interactive mode: default theme + prime sudo cache so pacman doesn't pause
if $ASSUME_YES; then
    [[ -z "$THEME_NAME" ]] && THEME_NAME="$DEFAULT_THEME"
    if $INSTALL_DEPS || $INSTALL_NVIDIA || $INSTALL_XGBOOST; then
        echo "Caching sudo credentials for unattended install..."
        sudo -v || { echo "sudo required for --deps / --nvidia / --xgboost"; exit 1; }
    fi
fi

# Sudo keepalive — runs for any case where we primed above. Keeps the
# cache warm so late-stage privileged sections (UFW, fail2ban, AppArmor,
# ollama hardening, endlessh) don't fail silently after the cache
# expires. In --yes mode it stays alive for the full run; in interactive
# mode it's torn down at the end of the deps phase (_sudo_keepalive_stop).
if ( $ASSUME_YES && ( $INSTALL_DEPS || $INSTALL_NVIDIA || $INSTALL_XGBOOST ) ) \
   || ( ! $ASSUME_YES && $INSTALL_DEPS && sudo -n true 2>/dev/null ); then
    ( while true; do sudo -n true; sleep 50; done 2>/dev/null ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
fi

# Stop the sudo-keepalive background loop AND drop the cached
# credential. Called as soon as the privileged installation phase is
# over. After this, any further sudo command will re-prompt for the
# user's password (the desired behaviour for everything past pacman).
_sudo_keepalive_stop() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        unset SUDO_KEEPALIVE_PID
        # Drop the cached sudo timestamp so subsequent sudo invocations
        # re-prompt rather than inherit a still-warm credential.
        sudo -k 2>/dev/null || true
    fi
}

# ─────────────────────────────────────────
# Theme selection (interactive if not specified)
# ─────────────────────────────────────────
if [[ -z "$THEME_NAME" ]]; then
    echo "╭──────────────────────────────────────────────────────────────────╮"
    echo "│                    FoxML Theme Installer                        │"
    echo "╰──────────────────────────────────────────────────────────────────╯"
    echo ""

    available=()
    for d in "$THEMES_DIR"/*/; do
        [[ -f "$d/theme.conf" ]] || continue
        available+=("$(basename "$d")")
    done

    if [[ ${#available[@]} -eq 0 ]]; then
        echo "No themes found in $THEMES_DIR"
        exit 1
    fi

    echo "Available themes:"
    for i in "${!available[@]}"; do
        local_type=$(grep '^type=' "$THEMES_DIR/${available[$i]}/theme.conf" | cut -d= -f2)
        local_desc=$(grep '^description=' "$THEMES_DIR/${available[$i]}/theme.conf" | cut -d= -f2)
        printf "  [%d] %s (%s) — %s\n" "$((i+1))" "${available[$i]}" "$local_type" "$local_desc"
    done
    echo ""
    read -p "Select theme [1-${#available[@]}]: " choice
    if [[ "$choice" -ge 1 && "$choice" -le ${#available[@]} ]] 2>/dev/null; then
        THEME_NAME="${available[$((choice-1))]}"
    else
        echo "Invalid selection."
        exit 1
    fi
fi

PALETTE_FILE="$THEMES_DIR/$THEME_NAME/palette.sh"
if [[ ! -f "$PALETTE_FILE" ]]; then
    echo "Theme '$THEME_NAME' not found (missing palette.sh)"
    exit 1
fi

echo ""
echo "Installing theme: $THEME_NAME"
echo "Backups will be saved to: $BACKUP_DIR"
echo ""

# ─────────────────────────────────────────
# Dry-run: print plan summary and exit. No file writes, no pacman calls,
# no sudo. Lets the user preview which modules would activate, how many
# templates would render, and what the monitor layout looks like — useful
# when running with --full on a new machine, or sanity-checking a config
# change before committing to the install.
# ─────────────────────────────────────────
if $DRY_RUN; then
    foxml_section "Dry run — no changes will be applied"
    foxml_summary_row "Theme"             "$THEME_NAME"
    foxml_summary_row "Templates"         "${#TEMPLATE_MAPPINGS[@]} files would render"
    foxml_summary_row "Backup target"     "$BACKUP_DIR"
    mods=()
    $INSTALL_DEPS     && mods+=("deps")
    $INSTALL_SECURITY && mods+=("security")
    $INSTALL_PERF     && mods+=("perf")
    $INSTALL_PRIVACY  && mods+=("privacy")
    $INSTALL_VAULT    && mods+=("vault")
    $INSTALL_NVIDIA   && mods+=("nvidia")
    $INSTALL_AMD_GPU  && mods+=("gpu-amd")
    $INSTALL_INTEL_GPU && mods+=("gpu-intel")
    $INSTALL_FPRINT   && mods+=("fprint")
    $IS_LAPTOP        && mods+=("chassis:laptop")
    $INSTALL_XGBOOST  && mods+=("xgboost")
    $INSTALL_CPP_PRO  && mods+=("cpp-pro")
    $INSTALL_HARDEN_BROWSER && mods+=("harden-browser")
    $INSTALL_USBGUARD       && mods+=("usbguard")
    $INSTALL_ARCH_AUDIT     && mods+=("arch-audit")
    $INSTALL_MAC_RANDOM     && mods+=("mac-random")
    $INSTALL_POLKIT_STRICT  && mods+=("polkit-strict")
    $INSTALL_APPARMOR       && mods+=("apparmor")
    $INSTALL_AI       && mods+=("ai")
    $INSTALL_MODELS   && mods+=("models")
    $INSTALL_GITHUB   && mods+=("github")
    foxml_summary_row "Modules"           "${mods[*]:-none}"
    if [[ -f "$HOME/.config/foxml/monitor-layout.conf" ]]; then
        # _read_sidecar parses key=value safely without source-ing,
        # so a malicious monitor name can't smuggle in code at dry-run
        # time. Defined in mappings.sh (already sourced above).
        PRIMARY="" MONITOR_RESOLUTIONS=""
        _read_sidecar "$HOME/.config/foxml/monitor-layout.conf"
        foxml_summary_row "Monitors (sidecar)" "${MONITOR_RESOLUTIONS:-unknown}"
        foxml_summary_row "Primary"            "${PRIMARY:-unknown}"
    else
        foxml_summary_row "Monitors" "configure_monitors would run interactively"
    fi
    echo ""
    foxml_substep "no files written, no packages installed — rerun without --dry-run to apply"
    exit 0
fi

# ─────────────────────────────────────────
# Distro / session guard. install.sh issues pacman / yay / makepkg calls
# unconditionally and writes Hyprland-format configs. Fail fast with a
# clear message rather than the deep "command not found" the user would
# otherwise see hundreds of lines into the install. --dry-run skips this
# so a non-Arch user can still preview the plan.
# ─────────────────────────────────────────
if ! command -v pacman >/dev/null 2>&1; then
    foxml_err "pacman not found — install.sh requires Arch Linux or an Arch-derived distro"
    distro_id=$(grep ^ID= /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    foxml_substep "detected: ${distro_id:-unknown}"
    foxml_substep "if you're on Arch under a non-standard PATH, ensure /usr/bin is in \$PATH"
    foxml_substep "preview the install on this system without running it: ./install.sh --dry-run"
    exit 1
fi

# Hyprland session is not required for --render-only / --deps / theme
# rendering, but configure_monitors and post-install reload steps will
# self-skip without it. Surface a single line up front so the user knows
# those will defer rather than wondering why monitors aren't picked up.
if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    foxml_warn "no active Hyprland session — configure_monitors will defer to next install"
    foxml_substep "run ./install.sh from inside a Hyprland session to capture monitor layout"
fi

if ! $ASSUME_YES; then
    read -p "Continue? [y/N] " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && echo "Aborted." && exit 1
fi

mkdir -p "$BACKUP_DIR"

# ─────────────────────────────────────────
# Dependencies (only with --deps)
# ─────────────────────────────────────────
if $INSTALL_DEPS; then
    echo ""
    foxml_section "Installing dependencies"

    PACMAN_PKGS=(
        # Fonts (nerd fonts for prompt glyphs, noto for CJK/emoji fallback in welcome banner)
        ttf-hack-nerd ttf-jetbrains-mono-nerd noto-fonts noto-fonts-cjk noto-fonts-emoji
        # Compositor + lock + wallpaper + idle
        hyprland hyprlock awww hypridle
        # Themed login screen — auto-configured by install_greetd() below
        greetd greetd-regreet
        # Secrets / keyring (gnome-keyring-daemon is started from autostart.conf;
        # libsecret is the API most apps query, seahorse is the GUI manager).
        # gnupg powers gpg-agent for git commit signing — install_gpg_agent_cache()
        # extends its passphrase TTL so agent commits don't re-prompt every 10 min.
        gnome-keyring libsecret seahorse gnupg
        # Editor + terminal + multiplexer
        neovim kitty tmux
        # Neovim runtime deps:
        #  - nodejs/npm: copilot.lua needs node to launch the Copilot LSP, and
        #    mason installs pyright/bashls/jsonls/yamlls as npm packages
        #  - tree-sitter-cli: nvim-treesitter regenerates the latex grammar from
        #    source on this driver line; without the CLI it errors at startup
        nodejs npm tree-sitter-cli
        # Bar + launcher + notifications + widgets
        waybar rofi-wayland mako dunst
        # Build tools (cmake for C++ projects bootstrapped from this machine)
        cmake
        # Core & CLI Tools
        base-devel zsh fzf eza bat yazi btop fd zoxide jq git-delta github-cli pacman-contrib rofi-calc rofi-emoji
        lazygit ncspot cliphist cloc tree rsync shellcheck ripgrep
        # Networking + audio + notifications + power telemetry
        # (wpctl/nmcli/notify-send/upower/sensors are called from scripts &
        # waybar modules — without these explicit deps, fresh Arch boxes
        # silently fail at runtime)
        networkmanager wireplumber libnotify upower lm_sensors
        # unzip is needed by install_catppuccin_cursor (extracts the release zip)
        unzip
        # Screenshots + clipboard + media keys
        grim slurp wl-clipboard playerctl brightnessctl pavucontrol wlsunset swappy
        # Bluetooth
        bluez bluez-utils blueman
        # Fingerprint support
        fprintd
        # Apps + viewers (xdg-utils provides xdg-open / xdg-settings so CLI tools
        # — gcloud, gh, etc. — can spawn the default browser without ENOENT)
        firefox zathura zathura-pdf-mupdf xdg-utils thunar steam
        # Runtime libs often needed by proprietary/AUR packages
        libutf8proc xsimd
        # Tools
        hyprpicker
        # imagemagick — used by configure_monitors() to auto-crop landscape
        # wallpapers into portrait variants when a rotated monitor is detected
        imagemagick
        # socat — used by fox-monitor-watch.sh to stream Hyprland's socket2
        # event feed (monitoradded/monitorremoved) for hot-swap detection
        socat
        # Power profile switcher (waybar power-profiles-daemon module);
        # python-gobject is the optional dep that makes `powerprofilesctl` work
        # for click-to-switch handlers
        power-profiles-daemon python-gobject
        # ufw is always installed — install_ufw_baseline() applies a
        # default-deny incoming firewall on every install, not just --secure.
        # fail2ban / audit / lynis stay behind --secure (server-grade tools
        # that are dead weight on a personal laptop with no public services).
        ufw
    )

    # Security hardening — only added when --secure is passed.
    # Covers every dep for the fox-* security tools that can lazy-install
    # their AUR-only siblings (fwknop, opensnitch, endlessh, etckeeper,
    # cowrie's Python venv). Adding them here means `fox arm` doesn't
    # have to pause + ask the user to install knockd/wg/etc. mid-run.
    if $INSTALL_SECURITY; then
        PACMAN_PKGS+=(
            fail2ban audit lynis
            knockd                # fox knock (official repo)
            wireguard-tools       # fox vpn
            inotify-tools         # fox tripwire (inotifywait)
            python-virtualenv     # fox honeypot (Cowrie venv)
            qrencode              # fox spa (QR for phone key transfer)
            usbutils              # fox usb / fox deadman (lsusb / udevadm)
            etckeeper             # /etc git versioning
        )
    fi

    # Performance — only added when --perf is passed.
    if $INSTALL_PERF; then
        PACMAN_PKGS+=(chrony)
    fi

    # Vault — only added when --vault is passed.
    if $INSTALL_VAULT; then
        PACMAN_PKGS+=(pass)
    fi

    # NVIDIA driver stack — only added when --nvidia is passed.
    # nvidia-open-dkms is the kernel module (rebuilds on kernel updates
    # via DKMS), linux-headers is the DKMS prereq, libva-nvidia-driver
    # gives Firefox/VLC hardware video decode on the dGPU.
    if $INSTALL_NVIDIA; then
        PACMAN_PKGS+=(nvidia-open-dkms linux-headers libva-nvidia-driver)
    fi

    # AMD / Intel GPU userspace — auto-detected upstream; only Vulkan /
    # VA-API packages, no kernel modules or boot tweaks. Safe to install
    # alongside mesa (already in deps).
    if $INSTALL_AMD_GPU; then
        PACMAN_PKGS+=(vulkan-radeon libva-mesa-driver mesa-vdpau)
    fi
    if $INSTALL_INTEL_GPU; then
        PACMAN_PKGS+=(intel-media-driver libva-intel-driver vulkan-intel)
    fi

    # C++ trading toolchain extras — opt-in via --cpp-pro. base-devel
    # already covers gcc/make; this layer adds:
    #   clang, lldb        — alternative compiler + debugger
    #   mold               — 5-10x faster linker than ld.bfd
    #   ccache             — rebuild cache, big win on repeated builds
    #   gdb                — Linux's default debugger (not in base-devel)
    #   valgrind           — memory error / leak checks
    #   perf               — Linux kernel profiling
    #   hyperfine          — microbenchmark CLI
    #   linux-tools-common — perf needs this companion meta on some kernels
    if $INSTALL_CPP_PRO; then
        PACMAN_PKGS+=(clang lldb mold ccache gdb valgrind perf hyperfine)
    fi

    # Security hardening add-ons — on by default, --no-X opts out.
    # firejail comes in with --harden-browser since Firefox-in-firejail
    # is the canonical sandbox pairing for risky browsing.
    $INSTALL_HARDEN_BROWSER && PACMAN_PKGS+=(firejail)
    $INSTALL_USBGUARD       && PACMAN_PKGS+=(usbguard)
    $INSTALL_ARCH_AUDIT     && PACMAN_PKGS+=(arch-audit)
    $INSTALL_APPARMOR       && PACMAN_PKGS+=(apparmor)

    TO_INSTALL=()
    ALREADY_INSTALLED=0
    for pkg in "${PACMAN_PKGS[@]}"; do
        if pacman -Qi "$pkg" &>/dev/null; then
            ALREADY_INSTALLED=$((ALREADY_INSTALLED + 1))
        else
            TO_INSTALL+=("$pkg")
        fi
    done
    foxml_substep "${ALREADY_INSTALLED}/${#PACMAN_PKGS[@]} packages already installed"

    # Check for multilib if steam is needed
    if [[ " ${TO_INSTALL[*]} " =~ " steam " ]] && ! grep -q "^\[multilib\]" /etc/pacman.conf; then
        echo ""
        echo "  Steam requires the [multilib] repository, but it is disabled in /etc/pacman.conf"
        ENABLE_MULTILIB=false
        if $ASSUME_YES; then
            ENABLE_MULTILIB=true
        else
            read -p "  Enable [multilib]? (Requires sudo) [y/N] " -n 1 -r
            echo ""
            [[ $REPLY =~ ^[Yy]$ ]] && ENABLE_MULTILIB=true
        fi

        if $ENABLE_MULTILIB; then
            echo "  Enabling [multilib]..."
            sudo sed -i '/#\[multilib\]/,/#Include = \/etc\/pacman.d\/mirrorlist/ s/^#//' /etc/pacman.conf
            sudo pacman -Sy
            echo "  [multilib] enabled"
        else
            echo "  Skipping Steam (requires multilib)"
            # Remove steam from TO_INSTALL
            TO_INSTALL=(${TO_INSTALL[@]/steam/})
        fi
    fi

    if [[ ${#TO_INSTALL[@]} -gt 0 ]]; then
        foxml_substep "${#TO_INSTALL[@]} new package(s) to install: ${TO_INSTALL[*]}"
        if $ASSUME_YES; then
            sudo pacman -S --needed --noconfirm "${TO_INSTALL[@]}"
        else
            read -p "  Install with pacman? [y/N] " -n 1 -r
            echo ""
            [[ $REPLY =~ ^[Yy]$ ]] && sudo pacman -S --needed "${TO_INSTALL[@]}"
        fi
    else
        foxml_ok "all packages already installed — nothing to do"
    fi

    # Default web browser — wire xdg-open to Firefox so CLI auth flows
    # (gcloud, gh, oauth helpers) launch a browser instead of ENOENT-ing.
    # Idempotent: writes the user's ~/.config/mimeapps.list.
    if command -v xdg-settings &>/dev/null && [[ -f /usr/share/applications/firefox.desktop ]]; then
        xdg-settings set default-web-browser firefox.desktop \
            && echo "  Default browser set to Firefox"
    fi

    # Enable power-profiles-daemon (waybar module needs it active to read profiles)
    if pacman -Qi power-profiles-daemon &>/dev/null \
        && ! systemctl is-active --quiet power-profiles-daemon; then
        sudo systemctl enable --now power-profiles-daemon \
            && echo "  power-profiles-daemon enabled"
    fi

    # Enable bluetooth service
    if pacman -Qi bluez &>/dev/null \
        && ! systemctl is-active --quiet bluetooth; then
        sudo systemctl enable --now bluetooth \
            && echo "  bluetooth service enabled"
    fi

    # Fingerprint reader: enable fprintd + wire PAM. Gated by the
    # hardware-detect prompt above ($INSTALL_FPRINT).
    #
    # CRITICAL ordering: enrollment FIRST, PAM splice ONLY after a
    # finger is actually enrolled. Previous version spliced
    # `auth sufficient pam_fprintd.so` regardless; with no enrolled
    # finger every subsequent sudo / login hit a 30s pam_fprintd
    # timeout before falling through to password. The user would
    # type their password, get it eaten by the fingerprint prompt,
    # and see "Sorry, try again". Now: prompt to enroll (interactive
    # only), and only splice PAM if enrollment succeeded.
    if $INSTALL_FPRINT && pacman -Qi fprintd &>/dev/null; then
        if ! systemctl is-active --quiet fprintd; then
            sudo systemctl enable --now fprintd 2>/dev/null \
                && echo "  fprintd service enabled"
        fi

        # Check if user has any enrolled fingers. fprintd-list emits
        # "<user>: ..." lines when enrolled, "No fingerprints enrolled"
        # when not. Grep for the absence-of-enrollment string.
        _fprint_has_enrollment=0
        if fprintd-list "$USER" 2>/dev/null | grep -q "fingerprints enrolled"; then
            _fprint_has_enrollment=0
        elif fprintd-list "$USER" 2>/dev/null | grep -qE '#[0-9]'; then
            _fprint_has_enrollment=1
        fi

        if (( ! _fprint_has_enrollment )) && [[ -t 0 ]] && ! $ASSUME_YES; then
            echo ""
            echo "  Fingerprint reader is ready but no fingerprints are enrolled."
            echo "  Without enrolled fingers, PAM would wait 30s on EVERY sudo before"
            echo "  falling through to password — frustrating to use. Enroll now?"
            read -p "  Run fprintd-enroll? [Y/n] " -n 1 -r; echo ""
            if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
                # fprintd-enroll is interactive — give the user clear
                # guidance about touching the reader. Skips PAM splice
                # if enrollment fails or is cancelled.
                if fprintd-enroll "$USER"; then
                    _fprint_has_enrollment=1
                    echo "  + fingerprint enrolled"
                else
                    echo "  • enrollment cancelled or failed — PAM splice will be skipped"
                fi
            fi
        fi

        # Splice PAM ONLY when a fingerprint is actually enrolled.
        # `auth sufficient pam_fprintd.so` placed so a finger-touch
        # short-circuits the password chain, but AFTER any
        # pam_faillock/pam_env preauth lines so failed attempts still
        # count toward lockout. Falls back to "first auth line" only
        # when no preauth anchor exists.
        if (( _fprint_has_enrollment )); then
            pam_file=/etc/pam.d/system-local-login
            if [[ -f "$pam_file" ]] && ! grep -q pam_fprintd "$pam_file"; then
                # Backup before edit — recoverable if PAM ends up broken.
                sudo cp "$pam_file" "${pam_file}.foxml-bak" 2>/dev/null || true
                # awk-based insert: place pam_fprintd line AFTER the last
                # preauth/faillock/env auth line if present, otherwise
                # before the first include/required/requisite. This keeps
                # rate-limit + lockout semantics intact.
                sudo awk '
                    BEGIN { printed=0; last_preauth=0 }
                    /^auth[[:space:]]+.*pam_(faillock\.so.*preauth|env\.so)/ { last_preauth=NR }
                    { lines[NR]=$0 }
                    END {
                        insert_after = last_preauth
                        if (insert_after == 0) {
                            # No preauth anchor — insert before first auth line.
                            for (i=1; i<=NR; i++) {
                                if (lines[i] ~ /^auth[[:space:]]/) { insert_after = i-1; break }
                            }
                        }
                        for (i=1; i<=NR; i++) {
                            print lines[i]
                            if (i == insert_after && !printed) {
                                print "auth      sufficient   pam_fprintd.so"
                                printed=1
                            }
                        }
                    }
                ' "$pam_file" | sudo tee "${pam_file}.foxml-new" >/dev/null \
                    && sudo mv "${pam_file}.foxml-new" "$pam_file" \
                    && echo "  fprintd PAM line added (fingerprint can unlock sudo; backup at ${pam_file}.foxml-bak)"
            fi
        else
            # No enrollment yet — leave PAM untouched. User can re-run
            # install OR `fprintd-enroll && sudo sed ...` later.
            echo "  • PAM splice deferred (no enrolled fingerprints)"
            echo "    enroll later with: fprintd-enroll"
            echo "    then re-run: fox install --fprint"
        fi
    fi

    # AUR Helper (yay) and Spotify/Spicetify
    AUR_HELPER=""
    command -v yay &>/dev/null && AUR_HELPER="yay"
    command -v paru &>/dev/null && [[ -z "$AUR_HELPER" ]] && AUR_HELPER="paru"

    if [[ -z "$AUR_HELPER" ]]; then
        echo ""
        echo "No AUR helper (yay/paru) found."
        INSTALL_YAY=false
        if $ASSUME_YES; then
            INSTALL_YAY=true
        else
            read -p "  Install yay? [y/N] " -n 1 -r
            echo ""
            [[ $REPLY =~ ^[Yy]$ ]] && INSTALL_YAY=true
        fi

        if $INSTALL_YAY; then
            echo "  Installing yay..."
            YAY_DIR=$(mktemp -d)
            (
                set -e
                git clone https://aur.archlinux.org/yay-bin.git "$YAY_DIR"
                cd "$YAY_DIR"
                makepkg -si --noconfirm
            ) && AUR_HELPER="yay" || echo "  yay install failed"
            rm -rf "$YAY_DIR"
        fi
    fi

    # Oh My Zsh — prefer the AUR package (oh-my-zsh-git) when an AUR
    # helper is available, so the install path goes through pacman's
    # signature trust DB instead of `curl | sh`. Fall back to the
    # upstream script only if no AUR helper is present (early-bootstrap
    # machines that don't have yay/paru yet).
    _install_omz_script() {
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    }
    _install_omz_aur() {
        for aur in yay paru; do
            command -v "$aur" >/dev/null 2>&1 || continue
            "$aur" -S --needed --noconfirm oh-my-zsh-git >/dev/null 2>&1 && return 0
            return 1
        done
        return 1
    }
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        if $ASSUME_YES; then
            _install_omz_aur || _install_omz_script
        else
            read -p "  Install Oh My Zsh? [y/N] " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                _install_omz_aur || _install_omz_script
            fi
        fi
    fi

    # Global CLI tools (npm). Idempotent: only installs ones missing from PATH.
    #  - @google/gemini-cli       → `gemini` (Gemini CLI)
    #  - @anthropic-ai/claude-code → `claude` (Anthropic Claude Code)
    if command -v npm &>/dev/null; then
        NPM_GLOBALS=()
        command -v gemini &>/dev/null || NPM_GLOBALS+=("@google/gemini-cli")
        command -v claude &>/dev/null || NPM_GLOBALS+=("@anthropic-ai/claude-code")
        if [[ ${#NPM_GLOBALS[@]} -gt 0 ]]; then
            echo ""
            echo "Installing CLI tools (npm -g): ${NPM_GLOBALS[*]}"
            sudo npm install -g "${NPM_GLOBALS[@]}" \
                && echo "  Installed: ${NPM_GLOBALS[*]}" \
                || echo "  npm install failed — see output above"
        else
            echo "  Gemini CLI + Claude Code already installed"
        fi
    fi
fi

# ─────────────────────────────────────────
# XGBoost — built from source (not in any Arch repo). Heavy: ~5–10 min compile.
# Used by the FoxML_Trader training pipeline and other ML projects.
# Gated behind its own --xgboost flag since most users won't need it.
# Idempotent: skipped entirely if libxgboost.so is already installed system-wide.
# ─────────────────────────────────────────
if $INSTALL_XGBOOST; then
    if [[ -f /usr/local/lib/libxgboost.so ]]; then
        echo ""
        echo "XGBoost already installed (skipping build)"
    else
        echo ""
        echo "Building XGBoost from source (~5-10 min)..."
        # Hard-fail early if cmake is missing — saves a clone before the build dies.
        if ! command -v cmake &>/dev/null; then
            echo "  cmake not found. Run with --deps first, or: sudo pacman -S cmake"
            exit 1
        fi
        XGB_DIR="$HOME/code/xgboost"
        [[ -d "$XGB_DIR" ]] || git clone --recursive https://github.com/dmlc/xgboost.git "$XGB_DIR"
        # Subshell isolates the build's set -e so a failure here doesn't abort the
        # rest of the installer — XGBoost is opt-in via --xgboost.
        (
            set -e
            cd "$XGB_DIR"
            mkdir -p build && cd build
            cmake .. -DBUILD_STATIC_LIB=OFF
            make -j"$(nproc)"
            sudo make install
            sudo ldconfig
        ) && echo "  XGBoost installed to /usr/local/" \
          || echo "  XGBoost build failed — see output above (continuing)"
    fi
    _phase_mark deps
fi
# Sudo keepalive: stop here ONLY in interactive mode (where the user is
# at the keyboard and can re-auth when later privileged sections prompt).
# In --yes / unattended mode we keep the keepalive alive for the full
# run, because UFW + fail2ban + AppArmor + greetd + NVIDIA + the EXIT-
# trap finalizer (ollama hardening) all need sudo AFTER this point, and
# without a TTY they cannot re-prompt — they would fail silently. The
# EXIT trap on SUDO_KEEPALIVE_PID (registered at start-up) tears the
# keepalive down on script exit regardless.
if ! $ASSUME_YES; then
    _sudo_keepalive_stop
fi
_phase_exit_if_done deps

# zsh plugins — install whenever oh-my-zsh is present, regardless of --deps,
# so the caramel theme + plugin list in .zshrc don't error out on first shell.
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
if [[ -d "$HOME/.oh-my-zsh" ]]; then
    for repo in zsh-syntax-highlighting zsh-autosuggestions zsh-completions; do
        if [[ ! -d "$ZSH_CUSTOM/plugins/$repo" ]]; then
            git clone --quiet --depth 1 "https://github.com/zsh-users/$repo.git" "$ZSH_CUSTOM/plugins/$repo" \
                && echo "  zsh plugin: $repo"
        fi
    done
fi

# ─────────────────────────────────────────
# Render templates
# ─────────────────────────────────────────
echo ""
foxml_section "Rendering templates with $THEME_NAME palette"
RENDERED_DIR=$(mktemp -d)
render_all "$PALETTE_FILE" "$TEMPLATES_DIR" "$RENDERED_DIR"
echo "  Templates rendered"

if $RENDER_ONLY; then
    # In render-only mode, we still need to deploy them to the system 
    # but we skip dependencies, backups, and special sudo-heavy handlers.
    echo "Installing rendered configs (render-only)..."
    for mapping in "${TEMPLATE_MAPPINGS[@]}"; do
        src="${mapping%%|*}"
        dest="${mapping##*|}"
        dest="${dest/#\~/$HOME}"
        [[ "$dest" == *"FIREFOX_PROFILE"* ]] && continue
        [[ "$dest" == *"AGENT_DIR"* ]] && continue
        if [[ -f "$RENDERED_DIR/$src" ]]; then
            mkdir -p "$(dirname "$dest")"
            cp "$RENDERED_DIR/$src" "$dest"
        fi
    done
    
    echo "Installing shared configs (render-only)..."
    for mapping in "${SHARED_MAPPINGS[@]}"; do
        src="${mapping%%|*}"
        dest="${mapping##*|}"
        dest="${dest/#\~/$HOME}"
        if [[ -f "$SHARED_DIR/$src" ]]; then
            mkdir -p "$(dirname "$dest")"
            cp "$SHARED_DIR/$src" "$dest"
        elif [[ -d "$SHARED_DIR/$src" ]]; then
            mkdir -p "$(dirname "$dest")"
            cp -r "$SHARED_DIR/$src" "$dest"
        fi
    done

    # Re-run script and module deployment
    mkdir -p ~/.config/hypr/scripts ~/.config/waybar/scripts ~/.config/hypr/modules ~/.local/bin
    for script in "$SHARED_DIR/hyprland_scripts/"*.sh; do cp "$script" ~/.config/hypr/scripts/; chmod +x ~/.config/hypr/scripts/$(basename "$script"); done
    for script in "$SHARED_DIR/waybar_scripts/"*.sh; do cp "$script" ~/.config/waybar/scripts/; chmod +x ~/.config/waybar/scripts/$(basename "$script"); done
    for bin in "$SHARED_DIR/bin/"*; do cp "$bin" ~/.local/bin/; chmod +x ~/.local/bin/$(basename "$bin"); done
    for mod in "$SHARED_DIR/hyprland_modules/"*.conf; do 
        basename="$(basename "$mod")"
        [[ "$basename" == "theme.conf" ]] && continue
        [[ "$basename" == "nvidia.conf" ]] && continue
        cp "$mod" ~/.config/hypr/modules/
    done

    # Special handlers (AI settings, Firefox, etc.)
    install_specials "$RENDERED_DIR"
    
    # Still run waybar render to pick up monitor scale
    if [[ -x "$HOME/.config/hypr/scripts/start_waybar.sh" ]]; then
        "$HOME/.config/hypr/scripts/start_waybar.sh" --render-only || true
    fi
    
    rm -rf "$RENDERED_DIR"
    echo "Active theme: $THEME_NAME"
    echo "Render and deployment complete."
    exit 0
fi

# ─────────────────────────────────────────
# Compile FoxML Intelligence Layer (C++)
# ─────────────────────────────────────────
if [[ -d "$SCRIPT_DIR/src/fox-intel" ]]; then
    foxml_section "Compiling FoxML Intelligence Layer (C++)"
    (
        set -e
        cd "$SCRIPT_DIR/src/fox-intel"
        # Ensure json.hpp is present (fallback if not already there)
        if [[ ! -f "json.hpp" ]]; then
            curl -sLO https://github.com/nlohmann/json/releases/latest/download/json.hpp
        fi
        make clean &>/dev/null
        make -j"$(nproc)"
        cp findex fask "$SHARED_DIR/bin/"
        echo "  + Intelligence Layer compiled and deployed to shared/bin/"
    ) || echo "  ! Intelligence Layer build failed — ensure g++ and libcurl are installed."
fi

# ─────────────────────────────────────────
# Backup and copy helper
# ─────────────────────────────────────────
backup_and_copy() {
    local src="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
        local backup_path="$BACKUP_DIR/${dest#$HOME/}"
        mkdir -p "$(dirname "$backup_path")"
        cp "$dest" "$backup_path" 2>/dev/null || true
    fi
    cp "$src" "$dest"
}

# Directory-tree variant of backup_and_copy. Used for shared_mappings
# entries that resolve to directories (e.g. nvim_ftplugin/) and for the
# Papirus tree merge — both used to call raw `cp -a src/. dest/`, which
# silently overwrote user files. Now: snapshot each pre-existing file
# under $BACKUP_DIR before the copy lands, preserving the same relative
# structure so rollback can restore an exact tree.
backup_and_copy_dir() {
    local src="$1" dest="$2"
    mkdir -p "$dest"
    if [[ -d "$dest" ]]; then
        local rel backup_path
        # Walk every file we're ABOUT to copy. If a corresponding file
        # exists at the destination, snapshot it first. Symlinks are
        # preserved as-is in the backup (no -L follow).
        while IFS= read -r -d '' f; do
            rel="${f#$src/}"
            if [[ -e "$dest/$rel" || -L "$dest/$rel" ]]; then
                backup_path="$BACKUP_DIR/${dest#$HOME/}/$rel"
                mkdir -p "$(dirname "$backup_path")"
                cp -a "$dest/$rel" "$backup_path" 2>/dev/null || true
            fi
        done < <(find "$src" -mindepth 1 -print0 2>/dev/null)
    fi
    cp -a "$src/." "$dest/"
}

# ─────────────────────────────────────────
# Install rendered template files
# ─────────────────────────────────────────
echo ""
total_tmpl=${#TEMPLATE_MAPPINGS[@]}
cur_tmpl=0
for mapping in "${TEMPLATE_MAPPINGS[@]}"; do
    cur_tmpl=$((cur_tmpl + 1))
    if command -v foxml_progress >/dev/null; then foxml_progress "$cur_tmpl" "$total_tmpl" "Installing themed configs"; else echo -ne "\rInstalling themed configs $cur_tmpl/$total_tmpl"; fi

    src="${mapping%%|*}"
    dest="${mapping##*|}"
    dest="${dest/#\~/$HOME}"

    # Skip Firefox (handled by specials) and entries with FIREFOX_PROFILE
    [[ "$dest" == *"FIREFOX_PROFILE"* ]] && continue

    # Skip Agent config (handled by specials — needs jq merge to preserve auth keys)
    [[ "$dest" == *"AGENT_DIR"* ]] && continue

    # Skip if oh-my-zsh not installed (for caramel theme)
    [[ "$dest" == *".oh-my-zsh"* && ! -d "$HOME/.oh-my-zsh" ]] && continue

    if [[ -f "$RENDERED_DIR/$src" ]]; then
        backup_and_copy "$RENDERED_DIR/$src" "$dest"
    fi
done
echo ""

# ─────────────────────────────────────────
# Install shared (non-color) files
# ─────────────────────────────────────────
echo ""
total_shared=${#SHARED_MAPPINGS[@]}
cur_shared=0
for mapping in "${SHARED_MAPPINGS[@]}"; do
    cur_shared=$((cur_shared + 1))
    if command -v foxml_progress >/dev/null; then foxml_progress "$cur_shared" "$total_shared" "Installing shared configs"; else echo -ne "\rInstalling shared configs $cur_shared/$total_shared"; fi

    src="${mapping%%|*}"
    dest="${mapping##*|}"
    dest="${dest/#\~/$HOME}"

    if [[ -f "$SHARED_DIR/$src" ]]; then
        backup_and_copy "$SHARED_DIR/$src" "$dest"
    elif [[ -d "$SHARED_DIR/$src" ]]; then
        # Handle directory entries (like nvim_ftplugin/cpp.lua) — walks
        # the tree and snapshots any pre-existing file before the copy.
        backup_and_copy_dir "$SHARED_DIR/$src" "$dest"
    fi
done
echo ""

_phase_mark render
_phase_exit_if_done render

# ─────────────────────────────────────────
# Special handlers
# ─────────────────────────────────────────
echo ""
foxml_section "Installing special configs"
install_specials "$RENDERED_DIR"

# Waybar render is deferred until after configure_monitors writes the layout
# sidecar — otherwise start_waybar.sh sees no SECONDARY_OUTPUTS and emits a
# single-bar config, which wins over the multi-bar version a later run would
# generate.

# ─────────────────────────────────────────
# systemd-resolved DNSSEC — drop strict validation so zones with unsigned
# upstream responses (NTP pool subdomains, smaller zones) don't break name
# resolution. Without this, chronyd silently fails to sync the clock.
# ─────────────────────────────────────────
echo ""
echo "Configuring systemd-resolved DNSSEC..."
install_resolved_dnssec

# ─────────────────────────────────────────
# One-shot clock correction — direct UDP/123 to Cloudflare NTP IP, no
# DNS dependency. Fixes wedged clocks (multi-hour offsets) that chrony's
# slew mode refuses to step. Skipped when chrony isn't installed.
# ─────────────────────────────────────────
echo ""
echo "Synchronizing system clock..."
install_clock_sync

# ─────────────────────────────────────────
# gpg-agent passphrase cache TTL — extends the default 10-min idle cache
# so agent-driven commits don't re-prompt mid-session. No-op for users
# who don't sign with GPG. Override duration via FOXML_GPG_CACHE_TTL.
# ─────────────────────────────────────────
echo ""
echo "Configuring gpg-agent passphrase cache..."
install_gpg_agent_cache

# ─────────────────────────────────────────
# Kernel hardening sysctls — auto-applied. Drop-in at
# /etc/sysctl.d/99-foxml-hardening.conf, reversible by deleting the file.
# Pure-win settings (kptr/dmesg restrict, syncookies, rp_filter, etc.) —
# nothing that breaks normal desktop / dev workflows.
# ─────────────────────────────────────────
echo ""
echo "Applying kernel hardening sysctls..."
install_kernel_hardening

# ─────────────────────────────────────────
# Auto-on security hardening features. Flags default true; --no-X opts
# out individually. Gated on $INSTALL_DEPS so packages exist in the
# same run; config-only re-runs skip these (avoids half-installed
# state).
# ─────────────────────────────────────────
if $INSTALL_DEPS; then
    if $INSTALL_HARDEN_BROWSER; then
        echo ""
        foxml_section "Browser hardening (arkenfox + firejail)"
        install_browser_hardening
    fi
    if $INSTALL_USBGUARD; then
        echo ""
        foxml_section "USBGuard policy"
        install_usbguard
    fi
    if $INSTALL_ARCH_AUDIT; then
        echo ""
        foxml_section "arch-audit daily timer"
        install_arch_audit
    fi
fi
# MAC randomization is opt-in and doesn't require new packages
# (NetworkManager handles it), so it runs whenever the flag is set.
if $INSTALL_MAC_RANDOM; then
    echo ""
    foxml_section "NetworkManager MAC randomization"
    install_mac_random
fi
if $INSTALL_POLKIT_STRICT; then
    echo ""
    foxml_section "Polkit strict mode (every action re-prompts)"
    install_polkit_strict
fi
if $INSTALL_APPARMOR; then
    echo ""
    foxml_section "AppArmor MAC enablement"
    install_apparmor
fi

# Phone-alert hooks (fail2ban actionban → dispatch, fox-bouncer for
# USBGuard-while-locked, fox-sentry-audit kernel-level honeypot).
# Runs whenever fox-dispatch is present — wiring is idempotent. Offers
# an interactive --setup for the webhook URL when there's a TTY and
# the config doesn't exist yet.
if command -v fox-dispatch >/dev/null 2>&1; then
    echo ""
    foxml_section "Phone-alert wiring (dispatch / bouncer / audit honey / fail2ban)"
    install_dispatch_hooks
fi

# SSH tarpit (Endlessh). Only kicks in if the SSH wizard has already
# moved real sshd off port 22. Skipped cleanly otherwise.
if $INSTALL_SECURITY; then
    echo ""
    foxml_section "SSH tarpit (Endlessh) — port 22 honeypot"
    install_endlessh_tarpit
fi

# etckeeper — git-version /etc + path-watch sensitive subdirs.
if $INSTALL_SECURITY; then
    echo ""
    foxml_section "etckeeper — git-track /etc + alert on drift"
    install_etckeeper
fi

# Secure-by-default kernel/userspace hardening layers. Each runs as
# its own toggleable section so a user can opt out of just one piece
# (e.g. --no-noexec if their build tools need exec from /tmp).
if $INSTALL_HIDEPID; then
    echo ""
    foxml_section "hidepid — hide other users' processes in /proc"
    install_hidepid

if $INSTALL_SECURITY; then
    echo ""
    foxml_section "Hardened makepkg CFLAGS — protect future AUR builds"
    install_makepkg_hardening
fi
fi
if $INSTALL_NOEXEC_TMP; then
    echo ""
    foxml_section "noexec /tmp + /dev/shm — kill the malware staging ground"
    install_noexec_tmp
fi
if $INSTALL_IOMMU; then
    echo ""
    foxml_section "IOMMU — block DMA attacks from rogue Thunderbolt/PCIe"
    install_iommu
fi
if $INSTALL_NO_COREDUMPS; then
    echo ""
    foxml_section "core-dump annihilation — crashed RAM never hits disk"
    install_no_coredumps
fi

# Always normalise gnome-keyring autostart. The systemd-generated
# limited services (pkcs11+secrets only) win over our --components
# flag if they grab the daemon name first; mask them so Hyprland's
# autostart with the full set (pkcs11,secrets,ssh,gpg) takes effect.
# Without this, $SSH_AUTH_SOCK points at a stale path and `git push`
# over SSH fails with "Error connecting to agent".
if pacman -Qi gnome-keyring &>/dev/null; then
    echo ""
    foxml_section "gnome-keyring SSH+GPG components"
    install_keyring_full_components
fi

# ─────────────────────────────────────────
# UFW firewall baseline — auto-applied. Default deny incoming, allow
# outgoing, conditional limit ssh only when sshd is actually enabled.
# Skipped cleanly if ufw isn't installed; the --secure module's SSH
# hardening wizard handles port-22 vs custom-port logic separately.
# ─────────────────────────────────────────
echo ""
echo "Applying UFW firewall baseline..."
install_ufw_baseline

# ─────────────────────────────────────────
# Catppuccin cursor (per-user fetch from GitHub releases).
# Always runs — it's idempotent and our configs reference the theme.
# ─────────────────────────────────────────
echo ""
echo "Installing Catppuccin cursor..."
install_catppuccin_cursor

# ─────────────────────────────────────────
# greetd login screen — auto-runs when greetd-regreet is installed
# ─────────────────────────────────────────
if pacman -Qi greetd-regreet &>/dev/null; then
    echo ""
    echo "Configuring greetd login screen..."
    install_greetd
    install_greetd_fingerprint
fi

# ─────────────────────────────────────────
# Nvidia (full Wayland session on dGPU) — opt-in
# ─────────────────────────────────────────
if $INSTALL_NVIDIA; then
    echo ""
    echo "Configuring NVIDIA full-session setup..."
    install_nvidia
fi

# ─────────────────────────────────────────
# Security Hardening — opt-in
# ─────────────────────────────────────────
if $INSTALL_SECURITY; then
    echo ""
    echo "Configuring security hardening..."
    install_security
fi

# ─────────────────────────────────────────
# Performance — opt-in
# ─────────────────────────────────────────
if $INSTALL_PERF; then
    echo ""
    echo "Configuring performance tuning..."
    install_performance
fi

# ─────────────────────────────────────────
# Privacy — opt-in
# ─────────────────────────────────────────
if $INSTALL_PRIVACY; then
    echo ""
    echo "Configuring privacy (DoH)..."
    install_privacy
fi

# ─────────────────────────────────────────
# Vault — opt-in
# ─────────────────────────────────────────
if $INSTALL_VAULT; then
    echo ""
    echo "Configuring secure vault..."
    install_vault
fi

# ─────────────────────────────────────────
# AI Development Tools — opt-in
# ─────────────────────────────────────────
if $INSTALL_AI || $INSTALL_MODELS; then
echo ""
# Prefer the AUR package over `curl | sh`. AUR builds run through
# makepkg + PGP key validation (the maintainer's signing key is in
# pacman's trust DB after `pacman -S archlinux-keyring`), which gives
# us a verified install path instead of trusting whatever the upstream
# script does today. Falls back to the official script only if no AUR
# helper is on PATH yet (early bootstrap on a fresh machine).
if ! command -v ollama &>/dev/null; then
    if command -v yay >/dev/null 2>&1; then
        echo "Installing Ollama (via yay → AUR, signature-verified)..."
        yay -S --needed --noconfirm ollama-bin \
            || { echo "  ! AUR install failed; falling back to upstream script"; \
                 curl -fsSL https://ollama.com/install.sh | sh; }
    elif command -v paru >/dev/null 2>&1; then
        echo "Installing Ollama (via paru → AUR, signature-verified)..."
        paru -S --needed --noconfirm ollama-bin \
            || { echo "  ! AUR install failed; falling back to upstream script"; \
                 curl -fsSL https://ollama.com/install.sh | sh; }
    else
        echo "Installing Ollama via upstream script (no AUR helper on PATH)..."
        curl -fsSL https://ollama.com/install.sh | sh
    fi
else
    echo "Ollama already installed."
fi

# Ollama uses a client-server model — `ollama pull` talks to a running
# `ollama serve` daemon. On a fresh install (or any boot where ollama
# wasn't auto-started) the daemon isn't up yet, so the pull below fails
# with "could not connect to ollama server". Ensure the service is
# enabled + active first; loud-fail (caught by ERR trap) if we can't.
echo "Starting ollama daemon..."
if ! systemctl is-active --quiet ollama; then
    if sudo systemctl enable --now ollama 2>/dev/null; then
        echo "  ollama.service started"
        # Wait up to 10s for the HTTP listener to be reachable.
        for _ in $(seq 1 50); do
            curl -sf -m 1 http://127.0.0.1:11434/ >/dev/null 2>&1 && break
            sleep 0.2
        done
    else
        echo "  ! couldn't start ollama via systemd; falling back to user-space \`ollama serve\`"
        nohup ollama serve >/tmp/foxml-ollama-serve.log 2>&1 &
        disown
        for _ in $(seq 1 50); do
            curl -sf -m 1 http://127.0.0.1:11434/ >/dev/null 2>&1 && break
            sleep 0.2
        done
    fi
else
    echo "  • ollama.service already active"
fi

# Ensure embedding model is present for RAG. Allow up to two retries on
# transient failure (network glitch, daemon still warming up) before
# letting the ERR trap surface it.
echo "Pulling embedding model (nomic-embed-text)..."
_ollama_pull_attempt=0
until ollama pull nomic-embed-text; do
    _ollama_pull_attempt=$((_ollama_pull_attempt + 1))
    if (( _ollama_pull_attempt >= 3 )); then
        echo "  ! nomic-embed-text pull failed after 3 attempts — check connectivity, then:"
        echo "    ollama pull nomic-embed-text"
        break
    fi
    echo "  • pull attempt ${_ollama_pull_attempt} failed, retrying in 3s..."
    sleep 3
done

# Sandbox the ollama service via systemd hardening directives. Real
# protection against prompt-injection → tool-call escalation: even if
# a model is tricked into trying to read $HOME/.ssh, ProtectHome=ro
# stops it cold. Idempotent — re-runs converge on the same drop-in.
install_ollama_hardening

if $INSTALL_AI; then
        # Same AUR-first policy for OpenCode. `opencode-bin` ships the
        # signed upstream binary; AUR sig check catches a malicious
        # release tarball.
        if command -v opencode &>/dev/null; then
            echo "OpenCode already installed."
        elif command -v yay >/dev/null 2>&1; then
            echo "Installing OpenCode (via yay → AUR)..."
            yay -S --needed --noconfirm opencode-bin \
                || { echo "  ! AUR install failed; falling back to upstream script"; \
                     curl -fsSL https://opencode.ai/install | bash; }
        elif command -v paru >/dev/null 2>&1; then
            echo "Installing OpenCode (via paru → AUR)..."
            paru -S --needed --noconfirm opencode-bin \
                || { echo "  ! AUR install failed; falling back to upstream script"; \
                     curl -fsSL https://opencode.ai/install | bash; }
        else
            echo "Installing OpenCode via upstream script (no AUR helper on PATH)..."
            curl -fsSL https://opencode.ai/install | bash
        fi
        echo "  AI Tools binary installed."
    fi

    if $INSTALL_MODELS; then
        echo "Detecting hardware for optimal AI model stack..."
        # fox-hw-info echoes KEY=value lines; eval to actually set the vars in this shell.
        eval "$(bash "$SHARED_DIR/bin/fox-hw-info")"
        echo "  RAM: ${RAM_GB}GB, VRAM: ${VRAM_GB}GB (Tier: $TIER)"

        # Hybrid stack: a qwen2.5 chat sibling alongside the coder series.
        # The coder models are FIM-tuned and emit code when asked anything
        # general ("count to 10" → `echo -e "1\n2\n3"` with literal \n).
        # configure_opencode picks the chat sibling as the OpenCode default
        # model so general prompts produce prose; coder is still in the
        # picker for code tasks.
        case "$TIER" in
            "lite")
                echo "Pulling Lite Stack (chat 3B + coder 1.5B/3B/7B)..."
                ollama pull qwen2.5:3b
                ollama pull qwen2.5-coder:1.5b
                ollama pull qwen2.5-coder:3b
                ollama pull qwen2.5-coder:7b
                ;;
            "standard")
                echo "Pulling Standard Stack (chat 7B + coder 7B/14B/32B)..."
                ollama pull qwen2.5:7b
                ollama pull qwen2.5-coder:7b
                ollama pull qwen2.5-coder:14b
                ollama pull qwen2.5-coder:32b
                ;;
            "pro")
                # qwen2.5-coder tops out at 32B on the Ollama registry. Larger
                # hosts get the same coder ceiling — no broken 70B pull.
                echo "Pulling Pro Stack (chat 14B + coder 14B/32B)..."
                ollama pull qwen2.5:14b
                ollama pull qwen2.5-coder:14b
                ollama pull qwen2.5-coder:32b
                ;;
        esac
        echo "  + AI Models ready."
    fi

    # OpenCode config gen is deferred — defined as a function here, called at
    # the end of install.sh after GitHub clones land so skill-path discovery
    # can see the freshly-cloned workspaces on a brand-new machine.
    configure_opencode() {
        echo "Configuring OpenCode (theme + multi-model picker + skill discovery)..."
        mkdir -p "$HOME/.config/opencode"

        # Discover installed Ollama models for the picker. Embedding-only
        # models (nomic-embed-text*, mxbai-embed-*, bge-*) are filtered out
        # — they exit non-zero from the chat endpoint and clutter the model
        # picker. The previous filter matched only the bare name, so
        # nomic-embed-text:latest (the actual installed tag) slipped through.
        local INSTALLED_MODELS=()
        if command -v ollama &>/dev/null; then
            while IFS= read -r m; do
                [[ -z "$m" ]] && continue
                case "$m" in
                    nomic-embed-text*|mxbai-embed-*|bge-*) continue ;;
                esac
                INSTALLED_MODELS+=("$m")
            done < <(ollama list 2>/dev/null | awk 'NR>1 && $1 != "" {print $1}')
        fi
        if [ ${#INSTALLED_MODELS[@]} -eq 0 ]; then
            INSTALLED_MODELS=(qwen2.5-coder:7b)
        fi

        local MODELS_JSON=""
        for m in "${INSTALLED_MODELS[@]}"; do
            [ -n "$MODELS_JSON" ] && MODELS_JSON+=","
            MODELS_JSON+=$(printf '"%s":{"name":"%s"}' "$m" "$m")
        done

        # Discover skill dirs by globbing local workspaces. Only paths that
        # actually exist (and contain at least one SKILL.md) get wired in —
        # keeps private skills local without naming any private repo here.
        local SKILL_PATHS=()
        for d in "$HOME"/code/*/claude-skills; do
            [ -d "$d" ] || continue
            if find "$d" -name SKILL.md -print -quit 2>/dev/null | grep -q .; then
                SKILL_PATHS+=("$d")
            fi
        done
        local SKILL_PATHS_JSON=""
        for p in "${SKILL_PATHS[@]}"; do
            [ -n "$SKILL_PATHS_JSON" ] && SKILL_PATHS_JSON+=","
            SKILL_PATHS_JSON+=$(printf '"%s"' "$p")
        done

        # Default model: prefer a chat-tuned variant over a coder variant.
        # Coder models are FIM-tuned and produce code-formatted responses
        # for general prompts (the user reported "count to 10" yielding
        # `echo -e "1\n2..."` with literal escapes). Preference cascade:
        #   1. qwen2.5:7b   — Standard tier chat sibling
        #   2. qwen2.5:14b  — Pro tier chat sibling
        #   3. qwen2.5:3b   — Lite tier chat sibling
        #   4. any other non-coder model present
        #   5. first installed (falls back to coder if that's all there is)
        local DEFAULT_MODEL="ollama/${INSTALLED_MODELS[0]}"
        local chat_preference=("qwen2.5:7b" "qwen2.5:14b" "qwen2.5:3b")
        local picked=""
        for pref in "${chat_preference[@]}"; do
            for m in "${INSTALLED_MODELS[@]}"; do
                [ "$m" = "$pref" ] && { picked="$m"; break 2; }
            done
        done
        if [ -z "$picked" ]; then
            # No tier-specific chat model — scan for any non-coder model
            # that's not an embed variant (those are already filtered out).
            for m in "${INSTALLED_MODELS[@]}"; do
                case "$m" in
                    *-coder*) continue ;;
                    *)        picked="$m"; break ;;
                esac
            done
        fi
        [ -n "$picked" ] && DEFAULT_MODEL="ollama/$picked"

        cat <<EOF > "$HOME/.config/opencode/opencode.json"
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (Local)",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
      "models": {${MODELS_JSON}}
    }
  },
  "model": "${DEFAULT_MODEL}",
  "skills": {
    "paths": [${SKILL_PATHS_JSON}]
  }
}
EOF
        # Theme persistence lives in tui.json (separate schema). OpenCode
        # auto-migrates a top-level "theme" out of opencode.json into here on
        # first launch — we write it directly so a fresh install boots themed.
        cat <<EOF > "$HOME/.config/opencode/tui.json"
{
  "\$schema": "https://opencode.ai/tui.json",
  "theme": "foxml"
}
EOF
        echo "  + Theme: foxml (custom, palette-driven — re-run install.sh or render.sh after a palette swap to refresh)"
        echo "  + Models exposed to picker: ${#INSTALLED_MODELS[@]}  (default: $DEFAULT_MODEL)"
        echo "  + Skill workspaces wired: ${#SKILL_PATHS[@]}"

        # Project-local override — wires opencode into THIS project's own
        # claude-skills directory via a relative path. Intentionally does
        # not reference other workspaces; cross-workspace skill discovery
        # belongs in the user-level config above. Keeping this file
        # machine-agnostic means it's safe to commit (no /home/<user>
        # leaks, no private-workspace names) and identical across every
        # user who runs install.sh.
        mkdir -p "$SCRIPT_DIR/.opencode"
        cat <<EOF > "$SCRIPT_DIR/.opencode/opencode.json"
{
  "\$schema": "https://opencode.ai/config.json",
  "skills": {
    "paths": ["./claude-skills"]
  }
}
EOF
        echo "  + Project-local OpenCode config: $SCRIPT_DIR/.opencode/opencode.json"
    }

    echo "Deploying AI Skills Vault..."
    mkdir -p "$HOME/.local/share/foxml/ai_skills"
    cp -r "$SHARED_DIR/ai_skills/"* "$HOME/.local/share/foxml/ai_skills/"
    echo "  Vault initialized at ~/.local/share/foxml/ai_skills"

    # Plug skills into the current project folder
    echo "Plugging AI skills into project..."
    mkdir -p "$SCRIPT_DIR/.agent/commands"
    for skill in "$SHARED_DIR/ai_skills/"*.md; do
        dest="$SCRIPT_DIR/.agent/commands/$(basename "$skill")"
        # In-repo .agent/commands/ entries are relative symlinks back into
        # shared/ai_skills/ (committed that way) — cp would error with
        # "same file". -ef catches the same-inode case for symlink or not.
        [[ "$dest" -ef "$skill" ]] && continue
        cp "$skill" "$dest"
    done
    echo "  + Project-level AI skills ready."
    fi

# ─────────────────────────────────────────
# SSH key passphrase guard — generate keys protected, retrofit existing
# passphraseless keys. Handles the three cases the installer can land in:
#   - no key:                       generate fresh with a passphrase
#   - key exists, has passphrase:   no-op
#   - key exists, passphraseless:   offer (interactive) or auto-set (--yes)
# In --yes mode, a random 40-char alphanumeric passphrase is stashed at
# ~/.config/foxml/ssh-passphrase.txt (0600) with instructions to move it
# to a password manager (e.g. `pass insert ssh/id_ed25519`) and `shred -u`
# the file. The plaintext stash file is the lesser evil compared to a
# passphraseless on-disk key: it can be moved + destroyed in one minute;
# the key alone is a live GitHub credential until revoked.
_ensure_ssh_key_protected() {
    local gh_user="${1:-}"
    local key="$HOME/.ssh/id_ed25519"
    local pp_file="$HOME/.config/foxml/ssh-passphrase.txt"

    # _gen_passphrase: 40 chars, alphanumeric only — avoids shell-quoting
    # surprises when the user copy-pastes into a password manager.
    _gen_passphrase() {
        LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40
    }

    _stash_passphrase() {
        local pp="$1"
        mkdir -p "$(dirname "$pp_file")" && chmod 700 "$(dirname "$pp_file")"
        ( umask 077; printf '%s\n' "$pp" > "$pp_file" )
        chmod 600 "$pp_file"
        echo "    !! SSH passphrase stored at $pp_file (perms 600)."
        echo "    !! Move it to a password manager and then:"
        echo "    !!   shred -u $pp_file"
    }

    # ── Path 1: no key yet ─────────────────────────────────────────
    if [[ ! -f "$key" ]]; then
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        local ssh_email comment
        ssh_email="$(git config --global user.email 2>/dev/null)"
        comment="${ssh_email:-${gh_user}@$(hostname)}"

        if [[ -t 0 ]] && ! ${ASSUME_YES:-false}; then
            echo "    Generating SSH key (ed25519)..."
            echo "    ssh-keygen will prompt for a passphrase — leave blank"
            echo "    only if you really want a passphraseless on-disk key."
            ssh-keygen -t ed25519 -f "$key" -C "$comment"
        else
            local pp
            pp="$(_gen_passphrase)"
            echo "    Generating SSH key (ed25519) with a random passphrase..."
            ssh-keygen -t ed25519 -N "$pp" -f "$key" -C "$comment" -q
            _stash_passphrase "$pp"
        fi
        echo "      Key: $key"
        return 0
    fi

    # ── Path 2: key exists — check if it's passphraseless.
    # `ssh-keygen -y -P "" -f <key>` succeeds iff the key has no passphrase.
    if ! ssh-keygen -y -P "" -f "$key" >/dev/null 2>&1; then
        return 0   # has a passphrase, all good
    fi

    echo "    ! $key has no passphrase."
    echo "      Anyone who reads this file has your GitHub push access"
    echo "      until the key is revoked."
    if [[ -t 0 ]] && ! ${ASSUME_YES:-false}; then
        read -rp "    Set a passphrase now? [Y/n] " -n 1 -r; echo
        if [[ "$REPLY" =~ ^[Nn]$ ]]; then
            echo "      Skipped — re-run install.sh or use: ssh-keygen -p -f $key"
            return 0
        fi
        if ssh-keygen -p -f "$key"; then
            echo "      ✓ passphrase set on $key"
        else
            echo "      ! passphrase change failed — re-run: ssh-keygen -p -f $key"
        fi
    else
        local pp
        pp="$(_gen_passphrase)"
        if ssh-keygen -p -P "" -N "$pp" -f "$key" >/dev/null 2>&1; then
            echo "      ✓ random passphrase set on $key"
            _stash_passphrase "$pp"
        else
            echo "      ! could not set passphrase on $key — re-run interactively"
        fi
    fi
}

# ─────────────────────────────────────────
# GitHub Workspace — opt-in
# ─────────────────────────────────────────
install_github_workspace() {
    # If ASSUME_YES is on but --github wasn't passed, we skip.
    # If --github WAS passed, we run it regardless of ASSUME_YES because it's a specific user request.
    if $ASSUME_YES && ! $INSTALL_GITHUB; then
        return
    fi

    echo ""
    echo "╭──────────────────────────────────────────────────────────────────╮"
    echo "│   GitHub Workspace Setup                                        │"
    echo "├──────────────────────────────────────────────────────────────────┤"
    echo "│ This will create ~/code and clone all your public/private       │"
    echo "│ repositories. It uses 'gh' (GitHub CLI) for automation.         │"
    echo "╰──────────────────────────────────────────────────────────────────╯"
    if ! $ASSUME_YES; then
        read -p "Set up GitHub workspace? [y/N] " -n 1 -r; echo ""
        [[ ! $REPLY =~ ^[Yy]$ ]] && return
    fi

    # 1. Ensure gh is installed
    if ! command -v gh &>/dev/null; then
        echo "    Installing GitHub CLI..."
        sudo pacman -S --needed --noconfirm github-cli
    fi

    # 2. Check auth
    if ! gh auth status &>/dev/null; then
        echo "    You need to authenticate with GitHub."
        gh auth login
    fi

    # 3. Get username
    local gh_user
    gh_user=$(gh api user -q .login 2>/dev/null)
    if [[ -z "$gh_user" ]]; then
        read -p "    Enter your GitHub username: " gh_user
    fi

    if [[ -z "$gh_user" ]]; then
        echo "    ! No username provided, skipping."
        return
    fi

    # 4. Git Config Check
    if [[ -z "$(git config --global user.name)" ]]; then
        read -p "    Enter Git Name: " git_name
        [[ -n "$git_name" ]] && git config --global user.name "$git_name"
    fi
    if [[ -z "$(git config --global user.email)" ]]; then
        read -p "    Enter Git Email: " git_email
        [[ -n "$git_email" ]] && git config --global user.email "$git_email"
    fi

    # 4b. SSH key for git@github.com:... clones (idempotent).
    # Three cases handled by _ensure_ssh_key_protected:
    #   - no key:                   generate with passphrase
    #   - key exists, has pp:       no-op
    #   - key exists, passphraseless: offer to set a passphrase
    # In --yes mode, a random 40-char passphrase is generated and stashed
    # at ~/.config/foxml/ssh-passphrase.txt (0600) with instructions to
    # move it to a password manager and shred the file.
    _ensure_ssh_key_protected "$gh_user"

    # Upload pubkey to GitHub if not already registered there
    local pubkey_body
    pubkey_body="$(awk '{print $2}' "$HOME/.ssh/id_ed25519.pub")"
    if ! gh ssh-key list 2>/dev/null | grep -qF "$pubkey_body"; then
        if ! gh auth status 2>&1 | grep -q 'admin:public_key'; then
            echo "    Refreshing gh auth to include admin:public_key scope..."
            gh auth refresh -h github.com -s admin:public_key || true
        fi
        echo "    Uploading SSH key to GitHub..."
        gh ssh-key add "$HOME/.ssh/id_ed25519.pub" --title "$(hostname)" \
            || echo "    ! upload failed — run 'gh auth refresh -s admin:public_key' and retry"
    fi

    # 4c. GPG signing key — generates a passphrase-protected ed25519
    # signing key, uploads it to GitHub, and turns on commit/tag auto-
    # sign. Idempotent on re-runs.
    install_github_gpg_signing

    # 5. Workspace Directory
    mkdir -p "$HOME/code"
    cd "$HOME/code" || return

    # 5b. Pre-seed github.com SSH host key so the clone loop below doesn't
    # block on "Are you sure you want to continue connecting?" under --yes
    # (StrictHostKeyChecking=ask is the default on fresh ~/.ssh/known_hosts).
    if [[ ! -f "$HOME/.ssh/known_hosts" ]] \
       || ! ssh-keygen -F github.com -f "$HOME/.ssh/known_hosts" &>/dev/null; then
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null \
            >> "$HOME/.ssh/known_hosts"
        chmod 600 "$HOME/.ssh/known_hosts"
    fi

    # 6. Pull Repos. Each clone is wrapped in a `|| { echo; continue; }` so
    # one broken repo (archived, renamed, perms revoked) doesn't take down
    # the whole workspace setup under `set -e`.
    echo "      Pulling all repositories for $gh_user..."
    gh repo list "$gh_user" --limit 1000 --json name,sshUrl \
        -q '.[] | [.name, .sshUrl] | @tsv' \
        | while IFS=$'\t' read -r name url; do
        if [[ -d "$name" ]]; then
            echo "      • $name already exists, skipping"
        else
            echo "      ↓ Cloning $name..."
            git clone "$url" "$name" --quiet \
                || echo "        ! clone failed for $name, continuing"
        fi
    done

    echo "    + Workspace setup complete in ~/code"
}

if $INSTALL_GITHUB; then
    install_github_workspace
    _phase_mark github
fi
_phase_exit_if_done github

# ─────────────────────────────────────────
# OpenCode JSON config — runs LAST so skill-path discovery sees any
# workspaces that the GitHub clone step just brought down. Safe to call
# whenever --ai is set; idempotent on re-runs.
# ─────────────────────────────────────────
if $INSTALL_AI; then
    configure_opencode
    _phase_mark ai
fi
_phase_exit_if_done ai

# NOTE: configure_monitors + multi-monitor personalize used to be
# called here, nested inside `if $INSTALL_AI`. Moved to the
# unconditional block after install_throttling (below) so a run
# without --ai (or one where the AI block aborted on a sudo
# failure) still gets a properly personalized hyprlock.

# NOTE: waybar render moved to the unconditional block below for
# the same reason as configure_monitors. Keeps single source of
# truth for "after monitor config, refresh the bar."

# ─────────────────────────────────────────
# CPU throttling / power tuning — interactive wizard. Always offered at
# the end of an interactive install; auto-skipped under -y.
# ─────────────────────────────────────────
install_throttling

# ─────────────────────────────────────────
# Multi-monitor + waybar + ollama-sandbox finalization.
#
# Runs UNCONDITIONALLY (no $INSTALL_AI gate) so a re-install without
# --ai, or a run where the AI block aborted on a sudo failure, still
# gets a properly personalised hyprlock + correctly-rendered waybar
# + ollama drop-in. All helpers are idempotent — calling on a clean
# state is a no-op.
#
# The EXIT trap at the top of install.sh also re-runs these on early
# abort, so the user is doubly covered: clean exits run them here,
# aborts run them via the trap.
# ─────────────────────────────────────────
echo ""
foxml_section "Configuring monitors"
configure_monitors

# Backstop: regenerate per-monitor wallpaper variants, re-personalise
# hyprlock, re-pin workspace 1. configure_monitors above already
# emitted these lines once — redirect this backstop run so we don't
# print the same "+ hyprlock personalised" + "+ workspace pin" twice.
# Output silenced; exit codes preserved (errors still trigger ERR trap).
if [[ -f "$HOME/.config/foxml/monitor-layout.conf" ]]; then
    _generate_per_monitor_wallpapers >/dev/null 2>&1
    _personalize_hyprlock            >/dev/null 2>&1
    _personalize_workspace_rules     >/dev/null 2>&1
fi

# Render waybar AFTER configure_monitors so start_waybar.sh sees the
# layout sidecar and emits multi-bar config when secondary monitors
# are present. Then bounce the running waybar so the new config
# takes effect immediately (otherwise the bar already on screen
# keeps the pre-configure single-bar render until next session).
if [[ -x "$HOME/.config/hypr/scripts/start_waybar.sh" ]]; then
    echo ""
    foxml_section "Rendering waybar for current monitor layout"
    "$HOME/.config/hypr/scripts/start_waybar.sh" --render-only || true
    if pgrep -x waybar >/dev/null 2>&1; then
        pkill -x waybar 2>/dev/null || true
        setsid "$HOME/.config/hypr/scripts/start_waybar.sh" >/dev/null 2>&1 < /dev/null &
        disown 2>/dev/null || true
        echo "  + waybar restarted"
    fi
fi

# Ollama sandbox drop-in. install_ollama_hardening was also called
# from the AI block (if --ai|--models set), but a sudo timeout there
# would have left no drop-in. Re-running here when missing catches
# it. install_ollama_hardening's own sudo -v re-prime handles the
# "no sudo" case loudly.
if systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service' \
    && [[ ! -f /etc/systemd/system/ollama.service.d/foxml-hardening.conf ]]; then
    echo ""
    foxml_section "Ollama systemd sandbox"
    install_ollama_hardening
fi

# ─────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────
rm -rf "$RENDERED_DIR"

# ─────────────────────────────────────────
# Write active theme
# ─────────────────────────────────────────
echo "$THEME_NAME" > "$ACTIVE_FILE"

# Persistent install marker. Read by --quick on subsequent runs to skip
# the expensive parts (deps install, github clones, model pulls) when
# the theme/scripts just need a re-render.
mkdir -p "$HOME/.local/share/foxml"
{
    echo "theme=${THEME_NAME}"
    echo "installed_at=$(date -Iseconds)"
    echo "script_dir=${SCRIPT_DIR}"
} > "$HOME/.local/share/foxml/.installed-version"

# ─────────────────────────────────────────
# Pacman-style install summary
# ─────────────────────────────────────────
_summary_monitor_line() {
    # Read sidecar to produce a one-line monitor summary
    # ("eDP-1 1920x1080 + HDMI-A-1 1080x1920 (portrait)") for the report.
    local layout="$HOME/.config/foxml/monitor-layout.conf"
    [[ -f "$layout" ]] || { echo "none"; return; }
    local PRIMARY="" PORTRAIT_OUTPUTS="" SECONDARY_OUTPUTS="" MONITOR_RESOLUTIONS=""
    _read_sidecar "$layout"
    [[ -z "$MONITOR_RESOLUTIONS" ]] && { echo "${PRIMARY:-unknown}"; return; }
    local out="" entry name res portrait
    for entry in $MONITOR_RESOLUTIONS; do
        name="${entry%%:*}"; res="${entry##*:}"
        portrait=""
        [[ " ${PORTRAIT_OUTPUTS:-} " == *" ${name} "* ]] && portrait=" (portrait)"
        [[ -n "$out" ]] && out+=" + "
        out+="${name} ${res}${portrait}"
    done
    echo "$out"
}
_summary_wallpaper_count() {
    # Count pre-rendered ${base}_${WxH}.${ext} files. nullglob keeps this
    # quiet on a setup with no variants yet.
    local count
    shopt -s nullglob
    count=$(printf '%s\n' "$HOME"/.wallpapers/*_[0-9]*x[0-9]*.{jpg,jpeg,png} | grep -c '.')
    shopt -u nullglob
    echo "${count:-0}"
}

echo ""
foxml_section "Installation Complete"
foxml_summary_row "Active theme"      "$THEME_NAME"
foxml_summary_row "Templates rendered" "${#TEMPLATE_MAPPINGS[@]}"
foxml_summary_row "Monitors detected"  "$(_summary_monitor_line)"
foxml_summary_row "Wallpapers cached"  "$(_summary_wallpaper_count)"
foxml_summary_row "Backups saved to"   "$BACKUP_DIR"

# Health check: run fox-doctor and surface the headline count. Full
# output goes through fox-doctor directly if the user wants details
# (just run `fox doctor`). Skips if fox-doctor isn't on PATH yet, e.g.
# the very first install hasn't propagated ~/.local/bin yet.
if command -v fox-doctor >/dev/null 2>&1; then
    _doctor_out=$(fox-doctor 2>&1 || true)
    _doctor_result=$(printf '%s\n' "$_doctor_out" | grep -E '^Result:' | tail -1)
    if [[ -n "$_doctor_result" ]]; then
        # Strip ANSI colour codes from the captured line so the row aligns.
        _doctor_result=$(printf '%s' "$_doctor_result" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g; s/^Result: //')
        foxml_summary_row "Health check"     "${_doctor_result}"
        foxml_substep "run \`fox doctor\` for the full report"
    fi
fi
echo ""

# ─────────────────────────────────────────
# Auto-apply post-install actions. Each step self-skips when its
# precondition isn't met (no Hyprland session, waybar/dunst not running,
# no nvim install, no jq, no Cursor/Code dir).
# ─────────────────────────────────────────
apply_post_install() {
    foxml_section "Applying post-install actions"

    # Hyprland reload — only inside an active Hyprland session
    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl &>/dev/null; then
        # Commented out by user request to prevent breaking portrait monitor configurations during install testing
        # hyprctl reload >/dev/null 2>&1 && echo "  + Hyprland reloaded"
        echo "  + Hyprland reload skipped (user requested)"
    fi

    # Waybar — restart if currently running so it picks up new config
    if pgrep -x waybar >/dev/null && [[ -x "$HOME/.config/hypr/scripts/start_waybar.sh" ]]; then
        pkill -x waybar 2>/dev/null || true
        setsid -f "$HOME/.config/hypr/scripts/start_waybar.sh" >/dev/null 2>&1 || true
        echo "  + Waybar restarted"
    fi

    # Dunst — restart if currently running so the new palette loads
    if pgrep -x dunst >/dev/null; then
        pkill -x dunst 2>/dev/null || true
        setsid -f dunst >/dev/null 2>&1 || true
        echo "  + Dunst restarted"
    fi

    # Nvim Lazy sync — headless plugin update (60s cap so it can't hang)
    if command -v nvim &>/dev/null && [[ -d "$HOME/.local/share/nvim/lazy" ]]; then
        echo "  Running nvim Lazy sync (headless, 60s cap)..."
        if timeout 60 nvim --headless "+Lazy! sync" "+qa" >/dev/null 2>&1; then
            echo "  + Nvim plugins synced"
        else
            echo "  ! Lazy sync didn't complete cleanly — run ':Lazy sync' manually"
        fi

        # Rebuild treesitter parsers against current nvim ABI. Stale .so files
        # from an older Neovim cause "attempt to call method 'range' (a nil
        # value)" and similar errors after a Neovim version bump.
        if [[ -d "$HOME/.local/share/nvim/lazy/nvim-treesitter" ]]; then
            echo "  Rebuilding treesitter parsers (headless, 120s cap)..."
            if timeout 120 nvim --headless "+TSUpdateSync" "+qa" >/dev/null 2>&1; then
                echo "  + Treesitter parsers rebuilt"
            else
                echo "  ! TSUpdateSync didn't complete cleanly — run ':TSUpdateSync' manually"
            fi
        fi
    fi

    # Cursor / VS Code — set workbench.colorTheme to "Fox ML" via jq merge
    if command -v jq &>/dev/null; then
        local ide_dir ide_root settings tmp
        for ide_dir in "$HOME/.config/Cursor/User" "$HOME/.config/Code/User"; do
            ide_root="${ide_dir%/User}"
            [[ -d "$ide_root" ]] || continue
            mkdir -p "$ide_dir"
            settings="$ide_dir/settings.json"
            [[ -f "$settings" ]] || echo '{}' > "$settings"
            tmp="$(mktemp)"
            if jq '. + {"workbench.colorTheme": "Fox ML"}' "$settings" > "$tmp" 2>/dev/null; then
                mv "$tmp" "$settings"
                echo "  + $(basename "$ide_root"): workbench.colorTheme = Fox ML"
            else
                rm -f "$tmp"
            fi
        done
    fi
}

apply_post_install
_phase_mark post

# Chain into `fox arm` to walk the user through every opt-in defense
# in the same flow. Only triggers with --full / --arm / --paranoid;
# silent otherwise. Skipped under --yes (no TTY for interactive
# prompts) — `fox arm` itself is interactive by design.
if $INSTALL_ARM && [[ -t 0 ]] && ! $ASSUME_YES; then
    echo ""
    foxml_section "fox arm — walk through every opt-in defense"
    if command -v fox-arm >/dev/null 2>&1; then
        # --heavy passed → also enable opensnitch + cowrie inside arm.
        if $INSTALL_ARM_HEAVY; then
            fox-arm --heavy || true
        else
            fox-arm || true
        fi
    else
        echo "  ! fox-arm not on PATH — install seems incomplete"
    fi
fi

echo ""
if $INSTALL_AI; then
    echo "Next steps:"
    echo "  - OpenCode is ready: run 'opencode' to start local AI development"
    echo "  - AI Notifications: Claude/Gemini will notify via mako/dunst on turn complete, subagent done, and input needed (ALT+SHIFT+E for triage). Restart any in-flight agent sessions to load the new hooks."
fi
if $INSTALL_GITHUB; then
    echo "  7. GitHub Workspace is ready: Your repos are in ~/code"
fi
if $INSTALL_NVIDIA; then
    echo "  8. Reboot to load the nvidia kernel module"
fi
echo ""

# Fingerprint reader detection (Moved to bottom)
if lsusb | grep -qi "fingerprint"; then
    echo "╭──────────────────────────────────────────────────────────────────╮"
    echo "│  Hardware Detected: Fingerprint Reader                        │"
    echo "├──────────────────────────────────────────────────────────────────┤"
    echo "│ To automate your biometric setup (Sudo, Login, Git):             │"
    echo "│   Run: fox-fingerprint                                           │"
    echo "╰──────────────────────────────────────────────────────────────────╯"
    echo ""
fi
