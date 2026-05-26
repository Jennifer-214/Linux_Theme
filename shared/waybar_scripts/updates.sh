#!/bin/bash
# Waybar pending-updates pill.
#
# Reads the shared cache that clock.sh maintains
# ($XDG_RUNTIME_DIR/foxml-waybar/updates) so only one process actually
# runs `checkupdates` per refresh cycle. Falls back to running it
# ourselves if the cache is missing or stale.

CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/foxml-waybar"
CACHE="$CACHE_DIR/updates"
mkdir -p "$CACHE_DIR"

fresh() {
    local f="$1" max="$2" age
    [[ -f "$f" ]] || return 1
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    (( age < max ))
}

count=0
if fresh "$CACHE" 600; then
    count=$(<"$CACHE")
elif command -v checkupdates >/dev/null 2>&1; then
    count=$(checkupdates 2>/dev/null | wc -l)
    printf '%s' "$count" > "$CACHE"
fi

# Drift indicator: how long has it been since `pacman -Sy` last
# completed? The sync db's mtime is the canonical timestamp — pacman
# rewrites it on every refresh. Glow escalates with age so the user
# doesn't have to remember to update.
SYNC_DB=/var/lib/pacman/sync/core.db
sync_age_h=0
if [[ -f "$SYNC_DB" ]]; then
    sync_age_h=$(( ( $(date +%s) - $(stat -c %Y "$SYNC_DB") ) / 3600 ))
fi

# Pick a class — same calm/warning/critical escalation pattern as the
# battery widget. Mirrors `fresh / drift / stale / ancient` thresholds
# so the user's "I haven't synced in a while" signal becomes visual.
if   (( sync_age_h < 24  )); then class="fresh"
elif (( sync_age_h < 168 )); then class="drift"      # 1-7 days
elif (( sync_age_h < 720 )); then class="stale"      # 1-4 weeks
else                              class="ancient"    # 30+ days — uh oh
fi

# Always show the count. Tooltip carries the age detail so the user
# can see why the glow lit up. Nerd Font U+F06A4 (nf-md-update,
# circular-update glyph) matches the other module icons in the bar.
text="󰚰  $count"
if   (( sync_age_h < 1   )); then age_str="< 1 hour ago"
elif (( sync_age_h < 24  )); then age_str="${sync_age_h}h ago"
else
    age_str="$(( sync_age_h / 24 ))d ago"
fi
tooltip="$count pending updates\\nlast sync: $age_str\\nclick to inspect (checkupdates | less)"

printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tooltip" "$class"
