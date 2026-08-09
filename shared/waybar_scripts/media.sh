#!/bin/bash
# Waybar media player module
# Shows current track, scroll to seek, click to play/pause

status=$(playerctl status 2>/dev/null)
if [[ -z "$status" ]]; then
    echo '{"text":""}'
    exit 0
fi

if [[ "$status" == "Playing" ]]; then icon="󰏤"; else icon="󰐊"; fi

artist=$(playerctl metadata artist 2>/dev/null)
title=$(playerctl metadata title 2>/dev/null)

# Track metadata is free text — titles routinely contain quotes, and
# one unescaped `"` breaks the hand-built JSON and blanks the module.
# Escape at emission (backslashes first, then quotes).
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    printf '%s' "$s"
}

# Truncate long titles
full_text="$icon $artist - $title"
if (( ${#full_text} > 40 )); then
    display_text="${full_text:0:37}..."
else
    display_text="$full_text"
fi

printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' \
    "$(json_escape "$display_text")" "$(json_escape "$full_text")" "${status,,}"
