#!/bin/bash
# Waybar DISK module — used/total of /, in whole GB.
# $1: the theme's glyph (WAYBAR_ICON_DISK, passed by the bar config).
ICON="${1:-󰋊}"

read -r used_kb total_kb <<<"$(df -P / | awk 'NR==2 {print $3, $2}')"
used_gb=$(( used_kb / 1024 / 1024 ))
total_gb=$(( total_kb / 1024 / 1024 ))

if (( total_kb > 0 )); then
    pct=$(( 100 * used_kb / total_kb ))
else
    pct=0
fi

cls=""
if (( pct >= 95 )); then cls=',"class":"critical"'
elif (( pct >= 80 )); then cls=',"class":"warning"'
fi

printf '{"text":"%s %sg/%sg","tooltip":"%s%% of /"%s}\n' "$ICON" "$used_gb" "$total_gb" "$pct" "$cls"
