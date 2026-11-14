#!/bin/bash
# Compatibility router for old shortcuts; migrated menus use Quickshell exclusively.

if (( $# == 0 )); then
    printf '%s\n' 'Usage: toggle_rofi.sh COMMAND [ARGUMENTS...]' >&2
    exit 2
fi

page=""
case "${1##*/}" in
    hub.sh) page=root ;;
    network.sh) page=wifi ;;
    bluetooth.sh) page=bluetooth ;;
    audio_switcher.sh) page=audio-outputs ;;
    powermenu.sh) page=power ;;
    updates_menu.sh) page=updates ;;
    agent_rofi.sh) exec bash "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts/agent_rofi.sh" ;;
    rofi-pass) page=passwords ;;
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

if [[ -n "$page" ]]; then
    exec desktop-menu "$page"
fi

if [[ "${1##*/}" == rofi ]]; then
    printf '%s\n' 'This Rofi mode is retired. Use desktop-menu or desk-picker.' >&2
    exit 2
fi
exec "$@"
