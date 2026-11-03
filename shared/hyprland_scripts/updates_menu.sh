#!/bin/bash
# updates_menu.sh — drawer entry point and update execution helpers.
#
# Quickshell lists pending updates and offers these actions:
#   ▶ Apply in terminal   — floating kitty running `sudo pacman -Syu`.
#                           Default highlight; you see output + answer
#                           any prompts. Safe choice on rolling Arch.
#   ▶ Apply silently      — starts the foxml-apply-updates.service root unit
#                           via `systemctl start`, so auth routes through the
#                           GUI polkit agent (fingerprint/pw dialog) — no
#                           terminal. Shown ONLY when `informant` is installed
#                           (its pacman hook aborts on unread Arch news — the
#                           safeguard that stops an unattended upgrade from
#                           applying a breaking change). `fox-install
#                           --safe-updates` adds the unit + informant.
#
# Fail-safe: if the silent upgrade exits non-zero for ANY reason
# (informant news-gate, stale keyring, file conflict, failing hook) it
# drops you into an interactive terminal at the upgrade rather than
# leaving the system half-updated silently.
#
# After any apply: wipe the count cache + signal waybar (SIGRTMIN+1) so
# the pill refreshes immediately.

apply_mode="${1:-}"
if [[ -n "$apply_mode" && "$apply_mode" != --apply-terminal && "$apply_mode" != --apply-silent ]]; then
    printf '%s\n' 'Usage: updates_menu.sh [--apply-terminal | --apply-silent]' >&2
    exit 2
fi
if [[ -z "$apply_mode" ]]; then
    exec fox-desktop-menu updates
fi

CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/foxml-waybar"
COUNT_CACHE="$CACHE_DIR/updates"
LIST_CACHE="$CACHE_DIR/updates.list"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/foxml-updates.lock"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foxml"
LOG="$LOG_DIR/updates-last.log"

if ! command -v checkupdates >/dev/null 2>&1; then
    notify-send "Updates" "checkupdates not installed (pacman-contrib)"
    exit 1
fi

mapfile -t lines < <(checkupdates 2>/dev/null)
n=${#lines[@]}

if (( n == 0 )); then
    notify-send "Updates" "System is up to date 󰄬"
    exit 0
fi

# Refresh the list cache the tooltip reads while we have the data.
mkdir -p "$CACHE_DIR"
printf '%s\n' "${lines[@]}" > "$LIST_CACHE"

refresh_pill() {
    rm -f "$COUNT_CACHE"
    pkill -SIGRTMIN+1 waybar 2>/dev/null || true
}

open_terminal() {
    kitty --class FoxmlUpdater \
          -o initial_window_width=100c \
          -o initial_window_height=30c \
          -e bash -c "sudo pacman -Syu; echo; read -n1 -s -r -p 'Done. Press any key to close...'"
}

apply_terminal() {
    exec 9>"$LOCK"
    flock -n 9 || { notify-send "Updates" "An update is already running."; return; }
    open_terminal
    refresh_pill
}

apply_silent() {
    if ! command -v informant >/dev/null 2>&1; then
        notify-send "Updates" "Silent updates require informant — opening terminal."
        apply_terminal
        return
    fi
    exec 9>"$LOCK"
    flock -n 9 || { notify-send "Updates" "An update is already running."; return; }

    local unit="foxml-apply-updates.service"
    # No-terminal path: start a fixed root oneshot unit via systemctl, so auth
    # routes through the registered GUI polkit agent (fingerprint/pw dialog).
    # pkexec can't be used here — launched from the bar it finds no agent and
    # falls back to a textual agent that needs /dev/tty and dies; systemctl
    # resolves the agent via the logind session instead.
    if ! systemctl cat "$unit" >/dev/null 2>&1; then
        notify-send "Updates" "Silent-apply unit missing (run: fox-install --safe-updates) — opening terminal."
        open_terminal; refresh_pill; return
    fi

    mkdir -p "$LOG_DIR"
    systemctl reset-failed "$unit" 2>/dev/null
    notify-send "Updates" "Authenticate to apply $n updates…"

    # On ANY failure — auth unavailable/cancelled OR a real upgrade error
    # (informant news-gate / conflict) — drop to the interactive terminal so the
    # user can always still update. The silent path never fails silently.
    if systemctl start "$unit" >"$LOG" 2>&1; then
        notify-send "Updates" "✓ $n packages updated."
        refresh_pill
        return
    fi
    journalctl -u "$unit" -n 40 --no-pager >>"$LOG" 2>&1 || true
    notify-send -u critical "Updates" "Silent update didn't complete — opening terminal."
    open_terminal
    refresh_pill
}

case "$apply_mode" in
    --apply-terminal) apply_terminal; exit $? ;;
    --apply-silent) apply_silent; exit $? ;;
esac
