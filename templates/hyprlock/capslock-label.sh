#!/bin/sh
# Read only the keyboard LEDs; this helper runs only while the screen is locked.
for led in "${1:-/sys/class/leds}"/input*::capslock/brightness; do
    [ -r "$led" ] || continue
    IFS= read -r state < "$led"
    if [ "$state" = 1 ]; then
        printf '%s' '<span foreground="#{{FG}}" bgcolor="#{{SELECTION}}">  ⇧ caps lock  </span>'
        exit 0
    fi
done
