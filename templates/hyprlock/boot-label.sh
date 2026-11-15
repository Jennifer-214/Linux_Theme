#!/bin/sh
# A boot-screen summary of this machine for the lock screen (retro-amber shows it; other themes keep it off screen).
# Pango markup: escape & and <.
cpu=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo | tr -s ' ' | cut -c1-44)
mem=$(awk '/^MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo)
disk=$(df -h / 2>/dev/null | awk 'NR == 2 {print $2}')
up=$(uptime -p 2>/dev/null | sed 's/^up //')
{
    printf 'AMBER-86 BIOS v1.04   (C) 1987\n\n'
    printf 'CPU ........... %s\n' "${cpu:-unknown}"
    printf 'Memory test ... %sM OK\n' "${mem:-0}"
    printf 'Fixed disk .... %s\n' "${disk:-?}"
    printf 'Uptime ........ %s\n\n' "${up:-?}"
    printf 'SYSTEM HALTED. ENTER PASSWORD TO RESUME.\n'
} | sed 's/&/\&amp;/g; s/</\&lt;/g'
