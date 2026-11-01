#!/bin/bash
# Eww Control Center action dispatcher.
# Called by the buttons inside ~/.config/eww/eww.yuck.

# Launcher actions (drun, window list) anchor top-left.
ROFI_ZONE="${ROFI_ZONE:-nw}"
source ~/.config/hypr/scripts/_rofi_zone.sh

action="$1"
arg="$2"

close_hub() {
    eww close control_center control_center_drawer 2>/dev/null
    eww update drawer_panel="" 2>/dev/null
}

case "$action" in
    drawer)
        # Toggle the side drawer between panels. Clicking the same row twice
        # closes the drawer; clicking another row swaps the panel in place.
        current="$(eww get drawer_panel 2>/dev/null)"
        if [[ "$current" == "$arg" ]]; then
            eww update drawer_panel=""
            eww close control_center_drawer 2>/dev/null
        else
            eww update drawer_panel="$arg"
            eww open control_center_drawer 2>/dev/null
        fi
        ;;

    apps)
        close_hub
        rofi -show drun -theme-str "$ROFI_POS_THEME" &
        ;;

    windows)
        close_hub
        rofi -show window \
            -kb-row-up "k,Up" -kb-row-down "j,Down" -kb-accept-entry "l,Return" \
            -theme-str "$ROFI_POS_THEME window {width: 50%;}" &
        ;;

    nightlight)
        if pkill wlsunset 2>/dev/null; then
            notify-send "Night Light" "Disabled"
        else
            wlsunset -t 3500 -T 6500 &
            notify-send "Night Light" "Enabled (3500K)"
        fi
        ;;

    idle)
        ~/.config/hypr/scripts/toggle_dpms.sh
        ;;

    wallpaper)
        ~/.config/hypr/scripts/rotate_wallpaper.sh --cycle
        ;;

    sync_theme)
        current_wp="$(awww query 2>/dev/null | awk '/currently displaying/ {print $NF}')"
        if [[ -f "$current_wp" ]]; then
            ~/.config/hypr/scripts/generate_palette.sh "$current_wp"
        else
            notify-send "Auto-Theme" "Could not detect current wallpaper."
        fi
        ;;

    picker)
        close_hub
        hyprpicker -a
        ;;

    cleanup)
        close_hub
        kitty -e zsh -c "source ~/.zshrc && fox-clean; echo -e '\nPress enter to close...'; read"
        ;;

    lock)
        close_hub
        ~/.config/hypr/scripts/lock.sh
        ;;

    run_close)
        # Generic: close the hub then run the named hypr script.
        close_hub
        script="$HOME/.config/hypr/scripts/$arg"
        [[ -x "$script" ]] && "$script" &
        ;;

    power)
        close_hub
        case "$arg" in
            lock)     ~/.config/hypr/scripts/lock.sh ;;
            suspend)  systemctl suspend ;;
            logout)   fox-hl dispatch "hl.dsp.exit()" "exit" ;;
            reboot)   systemctl reboot ;;
            shutdown) systemctl poweroff ;;
        esac
        ;;
esac
