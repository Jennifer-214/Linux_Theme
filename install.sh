#!/usr/bin/env bash
# FoxML Theme Hub — installer entry point.
#
# Thin wrapper around the C++ orchestrator (src/fox-install). Adding a
# new install step means writing one .cpp under src/fox-install/modules/
# and one line in core/modules.def. Do NOT add logic here.
#
#   1. (Optionally) self-update from origin/main.
#   2. Cache sudo + keep the credential alive across the long install.
#   3. Build fox-install if it isn't already on disk.
#   4. exec fox-install with the same argv.
#
# The pre-migration bash implementation lives in legacy/ for reference
# only; nothing in the live install path sources it. mappings.sh at the
# repo root stays because three deployed Hyprland helper scripts and
# update.sh source it at RUNTIME — it is not an install-time dep.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOX_INSTALL_BIN="$SCRIPT_DIR/src/fox-install/fox-install"

# Strip --no-update from argv and set FOXML_NO_UPDATE=1 so the
# self-update block below skips the git fetch + re-exec. Equivalent
# to `FOXML_NO_UPDATE=1 ./install.sh` but discoverable from --help.
_argv=()
for _a in "$@"; do
    case "$_a" in
        --no-update) export FOXML_NO_UPDATE=1 ;;
        *) _argv+=("$_a") ;;
    esac
done
set -- "${_argv[@]+"${_argv[@]}"}"

# ─────────────────────────────────────────
# Pre-install checks.
# ─────────────────────────────────────────

# Check free space on /boot (or / if /boot is not separate)
# FoxML requires space for kernel images, initramfs, and AI models.
_boot_path="/boot"
[[ ! -d "$_boot_path" ]] && _boot_path="/"
_boot_info=$(df -Pk "$_boot_path" | awk 'NR==2 {print $2" "$4}')
read -r _boot_total_kb _boot_free_kb <<< "$_boot_info"
_boot_total_mb=$((_boot_total_kb / 1024))
_boot_free_mb=$((_boot_free_kb / 1024))
_rec_total_mb=768
_min_free_mb=256

if (( _boot_total_mb < _rec_total_mb || _boot_free_mb < _min_free_mb )); then
    echo "╭──────────────────────────────────────────────────────────────────╮"
    echo "│   Disk Space Check: $_boot_path                                   "
    printf "│   Capacity:  %4d MB (%d MB free)                              \n" "$_boot_total_mb" "$_boot_free_mb"
    echo "│   Recommended: ${_rec_total_mb} MB total capacity                         "
    echo "├──────────────────────────────────────────────────────────────────┤"
    echo "│   Warning: Your boot partition is below the recommended size.    │"
    echo "│   FoxML needs space for kernel updates and initramfs builds.     │"
    echo "│   Please consider freeing up some space (e.g., 'paccache -r').   │"
    echo "╰──────────────────────────────────────────────────────────────────╯"
    echo ""

    # Hard fail if extremely low (prevent certain breakage)
    if (( _boot_free_mb < 128 )); then
        echo ":: ERROR: Only ${_boot_free_mb}MB available. This is likely to fail during"
        echo "   initramfs generation. Free at least 128MB to continue."
        exit 1
    fi

    # Auto-yes if --yes / -y is in argv, $ASSUME_YES=1, or no TTY
    _autoyes=0
    for _a in "$@"; do
        case "$_a" in -y|--yes) _autoyes=1 ;; esac
    done
    [[ "${ASSUME_YES:-0}" == "1" ]] && _autoyes=1
    [[ ! -t 0 ]] && _autoyes=1

    if (( ! _autoyes )); then
        read -r -n 1 -p "  Continue anyway? [y/N] " _reply || true
        echo "" # New line after single-char input
        case "${_reply:-n}" in
            y|Y) echo ":: Proceeding despite low space." ;;
            *)   echo ":: Aborting."; exit 1 ;;
        esac
    fi
fi

# ─────────────────────────────────────────
# Self-update — fast-forward from origin/main + re-exec.
#
# Flow:
#   1. Quietly fetch origin/main (15s timeout — silent if offline).
#   2. If local HEAD == origin/main → no-op, continue with current code.
#   3. If there are new commits AND we're on main + clean → show the
#      commit list and ask y/n before pulling (TTY mode).
#   4. --yes / -y / ASSUME_YES=1 / no-TTY skip the prompt and update.
#   5. After pull, re-exec ourselves so the new wrapper code runs;
#      `make` then rebuilds whatever the new commits touched.
#
# Skip the whole thing with FOXML_NO_UPDATE=1 (offline / dev / explicit
# pin) or FOXML_UPDATED=1 (already re-execed; prevents an update loop).
# ─────────────────────────────────────────
if [[ "${FOXML_NO_UPDATE:-0}" != "1" && "${FOXML_UPDATED:-0}" != "1" ]] \
    && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"
    dirty="$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null | head -c 1 || echo)"
    if [[ "$branch" == "main" && -z "$dirty" ]]; then
        if timeout 15 git -C "$SCRIPT_DIR" fetch --quiet origin main 2>/dev/null; then
            local_sha="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
            remote_sha="$(git -C "$SCRIPT_DIR" rev-parse origin/main)"
            if [[ "$local_sha" != "$remote_sha" ]] \
                && git -C "$SCRIPT_DIR" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
                # Show what's coming. `git log --oneline` is one line per commit;
                # we cap at 10 so a long-stale checkout doesn't flood the prompt.
                _new=$(git -C "$SCRIPT_DIR" log --oneline HEAD..origin/main | head -10)
                _n=$(printf '%s\n' "$_new" | wc -l)
                echo ""
                echo "╭──────────────────────────────────────────────────────────────────╮"
                echo "│   Update available — ${_n} new commit(s) on origin/main           "
                echo "╰──────────────────────────────────────────────────────────────────╯"
                printf '%s\n' "$_new" | sed 's/^/  /'
                echo ""

                _do_update=1
                # Auto-yes if --yes / -y is in argv, $ASSUME_YES=1, or no TTY
                # (bootstrap curl-pipe path, CI, unattended re-installs).
                _autoyes=0
                for _a in "$@"; do
                    case "$_a" in -y|--yes) _autoyes=1 ;; esac
                done
                [[ "${ASSUME_YES:-0}" == "1" ]] && _autoyes=1
                [[ ! -t 0 ]] && _autoyes=1

                if (( ! _autoyes )); then
                    read -r -n 1 -p "  Download + install latest? [Y/n] " _reply || true
                    echo "" # New line after single-char input
                    case "${_reply:-y}" in
                        n|N) _do_update=0 ;;
                        *)   _do_update=1 ;;
                    esac
                fi

                if (( _do_update )); then
                    echo ":: Self-update: pulling origin/main (fast-forward only)"
                    git -C "$SCRIPT_DIR" pull --ff-only --quiet
                    export FOXML_UPDATED=1
                    exec "$SCRIPT_DIR/install.sh" "$@"
                else
                    echo ":: Skipping update; continuing with current version."
                fi
            fi
        fi
    fi
fi

# ─────────────────────────────────────────
# Sudo cache + keepalive. Long installs (--full with --models pulling
# multi-GB Ollama models) easily exceed sudo's 5-minute default TTL.
# Background loop refreshes the cache every 50s; trap kills it on exit.
# ─────────────────────────────────────────
if [[ -t 0 ]] || [[ "${1:-}" == *"--yes"* ]] || [[ "${ASSUME_YES:-0}" == "1" ]]; then
    if sudo -v 2>/dev/null; then
        ( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
        SUDO_KEEPALIVE_PID=$!
        trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
    else
        echo "warning: sudo cache cold — privileged steps will prompt or fail." >&2
    fi
fi

# ─────────────────────────────────────────
# Build / rebuild the native orchestrator.
# ─────────────────────────────────────────

# Ensure we have build tools. bootstrap.sh handles this for curl-pipe users,
# but manual git-cloners might be missing base-devel.
if ! command -v make >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
    echo ":: Build tools missing — installing base-devel..."
    sudo pacman -S --needed --noconfirm base-devel
fi

# nlohmann json.hpp is a fox-intel build dep. Network-dependent, so we
# still gate the fetch on "is the file missing?" rather than re-fetching
# every run.
if [[ ! -f "$SCRIPT_DIR/src/fox-intel/json.hpp" ]]; then
    echo ":: Fetching nlohmann/json header..."
    if ! curl -fsSL \
            https://github.com/nlohmann/json/releases/latest/download/json.hpp \
            -o "$SCRIPT_DIR/src/fox-intel/json.hpp"; then
        echo "ERROR: failed to fetch nlohmann/json header from GitHub." >&2
        echo "       Check network connectivity and re-run ./install.sh." >&2
        echo "       (If you're offline, drop a copy into src/fox-intel/json.hpp manually.)" >&2
        rm -f "$SCRIPT_DIR/src/fox-intel/json.hpp"   # partial download, if any
        exit 1
    fi
fi

_first_build=0
if [[ ! -x "$FOX_INSTALL_BIN" ]]; then
    _first_build=1
    echo ":: Building native orchestrator (fox-install + libfox-intel + ~10 fox-* tools)"
elif [[ "${FOXML_UPDATED:-0}" == "1" ]]; then
    echo ":: Recompiling after self-update"
fi
# Silent build with loud-on-failure rerun. Earlier attempts at a
# spinning-cursor progress bar (commits 6fc790f / da8b111) tripped
# set -e / pipefail in subtle ways depending on which subshell context
# the script was running under, and the dot-printer backgrounding
# raced on the trap. So we stick with the simple foreground pattern,
# but pass -jN for a real parallel speedup and time the wall clock so
# the user gets ONE line at the end telling them the build is done.
# The module-level progress bar inside the C++ orchestrator
# (ui::module_progress) handles the per-step pretty output once make
# hands off to fox-install.
_jobs=$(nproc 2>/dev/null || echo 2)
_start=$SECONDS
if ! make -j"$_jobs" -C "$SCRIPT_DIR" install >/dev/null 2>&1; then
    echo "error: native orchestrator build failed; rerunning loudly:" >&2
    make -j"$_jobs" -C "$SCRIPT_DIR" install
    exit 1
fi
_elapsed=$(( SECONDS - _start ))
if (( _first_build )) || [[ "${FOXML_UPDATED:-0}" == "1" ]]; then
    echo "   built in ${_elapsed}s (${_jobs} parallel jobs)"
fi

# ─────────────────────────────────────────
# Hand control to the native orchestrator.
# ─────────────────────────────────────────
exec "$FOX_INSTALL_BIN" "$@"
