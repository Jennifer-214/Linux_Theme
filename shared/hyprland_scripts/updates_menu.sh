#!/bin/bash
# updates_menu.sh — rofi menu for the waybar pending-updates pill.
#
# Lists each pending update as `pkg  curver -> newver`. Enter on any
# row spawns a floating kitty popup running `sudo pacman -Syu`, then
# invalidates the count cache and signals waybar (SIGRTMIN+1) so the
# pill refreshes immediately on completion.
#
# UX matches the rest of the FoxML rofi surface: `ne` zone (drops
# below waybar on the right), hjkl navigation, no input bar (-no-custom
# rejects free-form text, `inputbar {enabled: false;}` hides the box).

# Toggle behavior: clicking the widget while the menu is already open
# closes it. Mirrors `toggle_rofi.sh`.
if pkill -x rofi; then exit 0; fi

ROFI_ZONE="${ROFI_ZONE:-ne}"
source ~/.config/hypr/scripts/_rofi_zone.sh

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

selected=$(printf '%s\n' "${lines[@]}" | rofi -dmenu -i -no-custom \
    -p "Updates ($n)" \
    -kb-row-up "k,Up" \
    -kb-row-down "j,Down" \
    -kb-accept-entry "l,Return" \
    -kb-cancel "Escape,h" \
    -theme-str "$ROFI_POS_THEME inputbar {enabled: false;} listview {lines: 15;} window {width: 38%;}")

# ESC / dismiss → empty selection → no-op exit. Any Enter (regardless
# of which row was highlighted) → run the full upgrade. Partial
# upgrades are officially unsupported on Arch, so we don't act on the
# specific row selected.
[[ -z "$selected" ]] && exit 0

kitty --class FoxmlUpdater \
      -o initial_window_width=100c \
      -o initial_window_height=30c \
      -e bash -c "sudo pacman -Syu; echo; read -n1 -s -r -p 'Done. Press any key to close...'"

# kitty -e blocks until the popup exits. Wipe the cached count + nudge
# waybar so the pill reflects reality the instant the popup closes.
rm -f "${XDG_RUNTIME_DIR:-/tmp}/foxml-waybar/updates"
pkill -SIGRTMIN+1 waybar 2>/dev/null || true
