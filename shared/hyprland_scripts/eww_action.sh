#!/bin/bash
# Eww Control Center action dispatcher.
# Called by the buttons inside ~/.config/eww/eww.yuck.

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
        exec desktop-menu apps
        ;;

    windows)
        close_hub
        exec desktop-menu windows
        ;;

    nightlight)
        exec desk-drawer run nightlight
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
            logout)   desk-hl dispatch "hl.dsp.exit()" "exit" ;;
            reboot)   systemctl reboot ;;
            shutdown) systemctl poweroff ;;
        esac
        ;;
esac
