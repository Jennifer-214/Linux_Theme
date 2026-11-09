#!/bin/bash

# Themed OSD popups for Volume and Brightness
# Uses notify-send with progress bar hints (supported by mako/dunst). app-name fox-osd
# lets a theme restyle these in mako (MAKO_OSD_APP), e.g. as a thin level line.

TYPE=$1 # "volume", "mic" or "brightness"
CHANGE=$2 # "up" or "down" or "mute"

case "$TYPE" in
    volume)
        if [[ "$CHANGE" == "mute" ]]; then
            wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
        elif [[ "$CHANGE" == "up" ]]; then
            wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ --limit 1.5
        else
            wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
        fi
        
        # Get volume and mute status
        RAW=$(wpctl get-volume @DEFAULT_AUDIO_SINK@)
        VOL=$(echo "$RAW" | awk '{print int($2*100)}')
        MUTE=$(echo "$RAW" | grep -q "MUTED" && echo "yes" || echo "no")
        
        ICON="󰕾"
        [[ "$MUTE" == "yes" ]] && ICON="󰝟"

        # Paper's shared Quickshell process draws the little volume slip. A
        # missing service retains the normal notification fallback below.
        palette="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/modules/border_colors.sh"
        [[ -r "$palette" ]] && source "$palette"
        quiet=false
        [[ "$MUTE" == "yes" ]] && quiet=true
        if [[ "${C_LITTLE_DETAILS:-}" == fox-little-details-on ]] &&
            quickshell -c foxml ipc call volume present "$VOL" "$quiet" >/dev/null 2>&1; then
            exit 0
        fi
        
        notify-send -a fox-osd -h string:x-canonical-private-synchronous:volume \
                    -h int:value:"$VOL" \
                    -i audio-volume-high \
                    "$ICON  Volume: $VOL%" \
                    --transient
        ;;
        
    mic)
        # Same toggle as the drawer's mic-mute row; the note says which way it went.
        wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle || exit 0
        if wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -q MUTED; then
            title="shh… the mic is off"; icon=microphone-sensitivity-muted
        else
            title="the mic is listening"; icon=audio-input-microphone
        fi
        notify-send -h string:x-canonical-private-synchronous:mic -i "$icon" "$title" "" 2>/dev/null || true
        ;;

    brightness)
        if [[ "$CHANGE" == "up" ]]; then
            brightnessctl set 5%+
        else
            brightnessctl set 5%-
        fi
        
        VAL=$(brightnessctl -m | cut -d, -f4 | tr -d '%')

        # Paper's light slip, beside the volume one; otherwise the notification below.
        palette="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/modules/border_colors.sh"
        [[ -r "$palette" ]] && source "$palette"
        if [[ "${C_LITTLE_DETAILS:-}" == fox-little-details-on ]] &&
            quickshell -c foxml ipc call brightness present "$VAL" >/dev/null 2>&1; then
            exit 0
        fi

        notify-send -a fox-osd -h string:x-canonical-private-synchronous:brightness \
                    -h int:value:"$VAL" \
                    -i display-brightness \
                    "󰃟  Brightness: $VAL%" \
                    --transient
        ;;
esac
