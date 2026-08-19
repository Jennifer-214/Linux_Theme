#!/bin/bash
# updates_menu.sh — rofi action menu for the waybar pending-updates pill.
#
# Click the pill → one rofi modal: every pending update listed
# (pkg curver -> newver, read-only), then action rows:
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
#   ▶ Cancel              — dismiss.
# Selecting a package row (or the separator) just re-opens the menu —
# the list is informational; only the ▶ rows do anything.
#
# Fail-safe: if the silent upgrade exits non-zero for ANY reason
# (informant news-gate, stale keyring, file conflict, failing hook) it
# drops you into an interactive terminal at the upgrade rather than
# leaving the system half-updated silently.
#
# After any apply: wipe the count cache + signal waybar (SIGRTMIN+1) so
# the pill refreshes immediately. UX matches the rest of the FoxML rofi
# surface: ne zone, hjkl nav, no input bar.

# Toggle: clicking the pill while the menu is open closes it.
if pkill -x rofi; then exit 0; fi

ROFI_ZONE="${ROFI_ZONE:-ne}"
source ~/.config/hypr/scripts/_rofi_zone.sh

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

# ▶-prefixed sentinels stay visually distinct from "pkg ver -> ver" rows.
A_TERM="▶  Apply in terminal"
A_SILENT="▶  Apply silently (no terminal)"
A_CANCEL="▶  Cancel"
SEP="────────────────────────────────"

# Offer the no-terminal path only when informant guards pacman.
actions=("$A_TERM")
command -v informant >/dev/null 2>&1 && actions+=("$A_SILENT")
actions+=("$A_CANCEL")

# Highlight "Apply in terminal" by default: pkg rows are 0..n-1, the
# separator is n, A_TERM is n+1.
default_row=$(( n + 1 ))

while true; do
    selected=$(
        { printf '%s\n' "${lines[@]}"
          printf '%s\n' "$SEP"
          printf '%s\n' "${actions[@]}"
        } | rofi -dmenu -i -no-custom \
            -p "Updates ($n)" \
            -selected-row "$default_row" \
            -kb-row-up "k,Up" \
            -kb-row-down "j,Down" \
            -kb-accept-entry "l,Return" \
            -kb-cancel "Escape,h" \
            -theme-str "$ROFI_POS_THEME inputbar {enabled: false;} listview {lines: 15;} window {width: 42%;}")

    case "$selected" in
        "$A_TERM")        apply_terminal; break ;;
        "$A_SILENT")      apply_silent;   break ;;
        "$A_CANCEL"|"")   break ;;
        *)                continue ;;  # pkg row / separator → list is read-only
    esac
done
