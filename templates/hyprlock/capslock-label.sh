#!/bin/sh
# Read only the keyboard LEDs; this helper runs only while the screen is locked.
for led in "${1:-/sys/class/leds}"/input*::capslock/brightness; do
    [ -r "$led" ] || continue
    IFS= read -r state < "$led"
    if [ "$state" = 1 ]; then
        # Retro: the words a DOS screen would print, in inverse video.
        if [ "{{DESK_STYLE}}" = retro ]; then
            printf '%s' '<span foreground="#{{BG}}" bgcolor="#{{FG}}"> CAPS LOCK ON </span>'
        else
            printf '%s' '<span foreground="#{{FG}}" bgcolor="#{{SELECTION}}">  ⇧ caps lock  </span>'
        fi
        exit 0
    fi
done
