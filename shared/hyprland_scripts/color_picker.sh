#!/usr/bin/env bash
# Pick a colour on screen, copy its hex, and show it on a COPIED note with a swatch.
# Escape in hyprpicker prints nothing, so a cancelled pick stays quiet.
set -u

command -v hyprpicker >/dev/null 2>&1 || exit 0
hex=$(hyprpicker -a -l -b -q -f hex 2>/dev/null) || exit 0
hex=${hex//[$'\r\n\t ']/}
[[ "$hex" =~ ^#[0-9a-f]{6}$ ]] || exit 0

swatch="<span background=\"${hex}\">              </span>"
title="Color copied"
body="${swatch}  ${hex}"
palette="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/modules/border_colors.sh"
if [[ -r "$palette" ]]; then
    source "$palette"
    # Paper's COPIED stamp already says what happened; the hex is the note.
    if [[ "${C_LITTLE_DETAILS:-}" == fox-little-details-on ]]; then
        title="$hex"
        body="$swatch"
    fi
fi
notify-send --category=foxml.copied -a color-picker -h string:x-canonical-private-synchronous:color-picker \
    "$title" "$body" 2>/dev/null || true
