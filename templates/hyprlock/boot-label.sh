#!/bin/sh
# retro-amber's lock screen text (other themes keep both labels off screen). Pango markup: escape & and <.
#   boot-label.sh                     the boot summary, top left, ending in the PASSWORD: prompt
#   boot-label.sh status PROMPT [LEDS] [POWER]
#                                     the status bar along the bottom: PROMPT is hyprlock's $FPRINTPROMPT
#                                     (empty without a reader); LEDS and POWER are folders for the tests
escape() { sed 's/&/\&amp;/g; s/</\&lt;/g'; }

if [ "${1:-}" = status ]; then
    line='ENTER UNLOCK'
    fp=$(printf '%s' "${2:-}" | LC_ALL=C tr '[:lower:]' '[:upper:]')
    [ -n "$fp" ] && line="$line   $fp"
    if [ -n "$(sh "$(dirname "$0")/capslock-label.sh" ${3:+"$3"})" ]; then
        line="$line   CAPS LOCK ON"
    else
        line="$line   CAPS LOCK OFF"
    fi
    for b in "${4:-/sys/class/power_supply}"/BAT*/capacity; do
        [ -r "$b" ] && { line="$line   BATTERY $(cat "$b")%"; break; }
    done
    # Dark text: the bar under it is amber.
    printf '<span foreground="#{{BG}}">%s</span>' "$(printf '%s' "$line" | escape)"
    exit 0
fi

cpu=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo | tr -s ' ' | cut -c1-44)
mem=$(awk '/^MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo)
disk=$(df -h / 2>/dev/null | awk 'NR == 2 {print $2}')
up=$(uptime -p 2>/dev/null | sed 's/^up //')
day=$(LC_ALL=C date +'%a %m-%d-%Y' | LC_ALL=C tr '[:lower:]' '[:upper:]')
{
    printf 'AMBER-86 BIOS v1.04   (C) 1987\n\n'
    printf 'CPU ........... %s\n' "${cpu:-unknown}"
    printf 'Memory test ... %sM OK\n' "${mem:-0}"
    printf 'Fixed disk .... %s\n' "${disk:-?}"
    printf 'Uptime ........ %s\n\n' "${up:-?}"
    printf 'C:\\DESK> LOCK\n'
    printf 'SYSTEM LOCKED  %s\n\n' "$day"
    # The password field's stars start one column after this, on the same row (HYPRLOCK_INPUT_POS).
    printf 'PASSWORD:\n'
} | escape
