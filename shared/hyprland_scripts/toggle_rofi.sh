#!/bin/bash
# Known desktop menus share the drawer; other Rofi callers retain their arguments.

page=""
case "${1##*/}" in
    hub.sh) page=root ;;
    network.sh) page=wifi ;;
    bluetooth.sh) page=bluetooth ;;
    audio_switcher.sh) page=audio-outputs ;;
    powermenu.sh) page=power ;;
    updates_menu.sh) page=updates ;;
    clipmanager.sh)
        if [[ "${2:-text}" == image ]]; then page=clipboard-images; else page=clipboard-text; fi ;;
    rofi)
        args=("$@")
        for (( i=1; i<${#args[@]}-1; i++ )); do
            if [[ "${args[i]}" == -show ]]; then
                case "${args[i+1]}" in drun) page=apps ;; window) page=windows ;; esac
                break
            fi
        done ;;
esac

if [[ -n "$page" && "${FOXML_MENU_LEGACY:-0}" != 1 ]] &&
    command -v fox-desktop-menu >/dev/null 2>&1 && fox-desktop-menu --available; then
    if fox-desktop-menu "$page"; then exit 0; fi
fi

if pkill -x rofi; then
    exit 0
fi

ROFI_ZONE="${ROFI_ZONE:-nw}"
source "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts/_rofi_zone.sh"
export ROFI_ZONE ROFI_X ROFI_Y

if [[ "$1" == "rofi" ]]; then
    cmd="$1"; shift
    exec "$cmd" -theme-str "$ROFI_POS_THEME" "$@"
else
    exec "$@"
fi
