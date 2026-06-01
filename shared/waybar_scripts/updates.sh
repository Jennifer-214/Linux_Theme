#!/bin/bash
# Waybar pending-updates pill.
#
# Reads the shared cache that clock.sh maintains
# ($XDG_RUNTIME_DIR/foxml-waybar/updates) so only one process actually
# runs `checkupdates` per refresh cycle. Falls back to running it
# ourselves if the cache is missing, stale, or older than the last
# pacman log mutation (so post-`pacman -Syu` refresh is automatic
# without a system hook).

CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/foxml-waybar"
CACHE="$CACHE_DIR/updates"
LIST_CACHE="$CACHE_DIR/updates.list"
mkdir -p "$CACHE_DIR"

fresh() {
    local f="$1" max="$2" cache_mtime now
    [[ -f "$f" ]] || return 1
    now=$(date +%s)
    cache_mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    (( now - cache_mtime < max )) || return 1
    # pacman writes /var/log/pacman.log on every transaction. If the
    # log is newer than our cache the count is by definition stale —
    # this is the auto-refresh path for "user just ran pacman -Syu".
    if [[ -f /var/log/pacman.log ]]; then
        local log_mtime
        log_mtime=$(stat -c %Y /var/log/pacman.log 2>/dev/null || echo 0)
        (( cache_mtime > log_mtime )) || return 1
    fi
    return 0
}

count=0
if fresh "$CACHE" 600; then
    count=$(<"$CACHE")
elif command -v checkupdates >/dev/null 2>&1; then
    # One checkupdates run feeds both the count cache and the package
    # list cache the tooltip + click menu read.
    list=$(checkupdates 2>/dev/null)
    if [[ -n "$list" ]]; then
        count=$(printf '%s\n' "$list" | wc -l)
        printf '%s\n' "$list" > "$LIST_CACHE"
    else
        count=0
        : > "$LIST_CACHE"
    fi
    printf '%s' "$count" > "$CACHE"
fi

# Drift indicator: how long has it been since `pacman -Sy` last
# completed? The sync db's mtime is the canonical timestamp — pacman
# rewrites it on every refresh.
SYNC_DB=/var/lib/pacman/sync/core.db
sync_age_h=0
if [[ -f "$SYNC_DB" ]]; then
    sync_age_h=$(( ( $(date +%s) - $(stat -c %Y "$SYNC_DB") ) / 3600 ))
fi

# Two orthogonal severity dimensions feed a single class:
#   - age:   how long since last sync     (drift / stale / ancient)
#   - count: how much work is queued      (low / mid / high)
# Severity ladder 0..3 — worse of the two wins. The user sees one
# color, the worst signal driving it.
#   0 = calm   (blush)        — fresh sync + few/no pending
#   1 = low    (green)        — small backlog OR mild drift
#   2 = mid    (yellow + glow)— meaningful backlog OR week-old sync
#   3 = high   (red + glow)   — large backlog OR month-old sync
age_sev=0
if   (( sync_age_h >= 720 )); then age_sev=3   # 30+ days
elif (( sync_age_h >= 168 )); then age_sev=2   # 1-4 weeks
elif (( sync_age_h >= 24  )); then age_sev=1   # 1-7 days
fi

count_sev=0
if   (( count >= 61 )); then count_sev=3
elif (( count >= 21 )); then count_sev=2
elif (( count >= 1  )); then count_sev=1
fi

sev=$(( age_sev > count_sev ? age_sev : count_sev ))
case "$sev" in
    0) class="calm" ;;
    1) class="low"  ;;
    2) class="mid"  ;;
    3) class="high" ;;
esac

# Always show the count. Tooltip carries the age detail so the user
# can see why the glow lit up. Nerd Font U+F06A4 (nf-md-update,
# circular-update glyph) matches the other module icons in the bar.
text="󰚰  $count"
if   (( sync_age_h < 1   )); then age_str="< 1 hour ago"
elif (( sync_age_h < 24  )); then age_str="${sync_age_h}h ago"
else
    age_str="$(( sync_age_h / 24 ))d ago"
fi
tooltip="$count pending updates\\nlast sync: $age_str"
# List the packages on hover when the cached list still matches the
# count (i.e. not stale after an apply). Cap to 15 — the click menu
# shows the full set. Real newlines → literal \n for the JSON string.
if (( count > 0 )) && [[ -s "$LIST_CACHE" ]] && (( $(wc -l < "$LIST_CACHE") == count )); then
    shown=$(head -n 15 "$LIST_CACHE" | sed 's/ -> / → /' | sed ':a;N;$!ba;s/\n/\\n/g')
    tooltip="$tooltip\\n\\n$shown"
    (( count > 15 )) && tooltip="$tooltip\\n… +$(( count - 15 )) more"
fi
tooltip="$tooltip\\nclick to inspect + update"

printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tooltip" "$class"
