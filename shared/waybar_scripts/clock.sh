#!/bin/bash
# Waybar composite clock — date/time as text, weather + pending pacman
# updates as tooltip. Caches both data sources because wttr.in rate-limits
# and `checkupdates` is slow (DB lock + sync).

CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/foxml-waybar"
mkdir -p "$CACHE_DIR"

# fresh? mtime within $1 seconds
fresh() {
    local f="$1" max="$2" age
    [[ -f "$f" ]] || return 1
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    (( age < max ))
}

# ── Weather (refresh every 30 min) ────────────────────────────────
WEATHER_CACHE="$CACHE_DIR/weather"
weather="N/A"
if fresh "$WEATHER_CACHE" 1800; then
    weather=$(<"$WEATHER_CACHE")
else
    new=$(curl -s --max-time 3 "wttr.in/?format=%c+%t" 2>/dev/null | tr -d '+')
    if [[ -n "$new" ]]; then
        weather="$new"
        printf '%s' "$weather" > "$WEATHER_CACHE"
    elif [[ -f "$WEATHER_CACHE" ]]; then
        # stale-fallback so a transient network blip doesn't drop the field
        weather=$(<"$WEATHER_CACHE")
    fi
fi

# ── Pending updates (refresh every 10 min) ────────────────────────
UPDATES_CACHE="$CACHE_DIR/updates"
updates=0
if fresh "$UPDATES_CACHE" 600; then
    updates=$(<"$UPDATES_CACHE")
elif command -v checkupdates >/dev/null 2>&1; then
    # clock.sh is the primary checkupdates runner on the 600s cycle, so
    # cache the package list here too (the updates pill tooltip + click
    # menu read it) rather than running checkupdates a second time.
    # Exit codes: 0 = updates pending, 2 = genuinely none, 1 = error.
    # A network blip must NOT be recorded as "0 pending" — keep the
    # stale count instead (same discipline as the weather fallback).
    _ul=$(checkupdates 2>/dev/null)
    _rc=$?
    if (( _rc == 0 )) && [[ -n "$_ul" ]]; then
        updates=$(printf '%s\n' "$_ul" | wc -l)
        printf '%s\n' "$_ul" > "$CACHE_DIR/updates.list"
        printf '%s' "$updates" > "$UPDATES_CACHE"
    elif (( _rc == 2 )); then
        updates=0
        : > "$CACHE_DIR/updates.list"
        printf '%s' "$updates" > "$UPDATES_CACHE"
    elif [[ -f "$UPDATES_CACHE" ]]; then
        updates=$(<"$UPDATES_CACHE")
    fi
fi

# ── Output ────────────────────────────────────────────────────────
text=$(date +"  %a %b %d  %I:%M %p")
today=$(date +"%A, %B %-d %Y")

# Manual JSON: sources only emit safe chars (digits, ASCII words, weather
# emoji + temperature). \\n in the tooltip becomes a real newline in
# Waybar's pango-rendered output.
tooltip="$today\\n\\n  Weather: $weather\\n  Updates: $updates pending"

printf '{"text":"%s","tooltip":"%s"}\n' "$text" "$tooltip"
