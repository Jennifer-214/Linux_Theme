#!/usr/bin/env bash
# Apply the wallpaper for the current time-of-day slot via awww.
#
# Slots:
#   05–10  dawn    → foxml_misty_dawn.jpg
#   10–18  midday  → foxml_earthy.jpg
#   18–22  sunset  → foxml_sunrise_sunbeams.jpg
#   22–05  night   → foxml_night_woods.jpg
#
# Default invocation is idempotent — exits without fading or notifying if the
# slot's wallpaper is already active. Safe to fire from a frequent timer.
#
# `--cycle` (used by the ALT+W keybind) advances one slot from whatever is
# currently shown, regardless of the clock — gives "next mood now" semantics
# for the manual keybind. The next timer fire snaps back to the calendar slot.
#
# Per-monitor pre-rendered variants. configure_monitors() in mappings.sh
# writes ~/.config/foxml/monitor-layout.conf with a MONITOR_RESOLUTIONS list
# (e.g. "eDP-1:1920x1080 HDMI-A-1:1080x1920"). _generate_per_monitor_wallpapers
# pre-renders ${base}_${WxH}.${ext} for every entry. This script picks the
# matching variant per monitor — pixel-perfect, no runtime scaling — and
# falls back to the source when a variant is missing.
set -euo pipefail

WALL_DIR="${HOME}/.wallpapers"
MODE="${1:-bucket}"

# Slot definitions: start-hour, label, filename. Keep ordered by start-hour.
slots=(
    "05 dawn   foxml_misty_dawn.jpg"
    "10 midday foxml_earthy.jpg"
    "18 sunset foxml_sunrise_sunbeams.jpg"
    "22 night  foxml_night_woods.jpg"
)

# Map current hour → slot index. Hours before the first start (00–04) fall
# through to the last slot (night, which spans midnight).
calendar_slot_index() {
    local hour idx=$(( ${#slots[@]} - 1 ))
    hour=$((10#$(date +%H)))
    for i in "${!slots[@]}"; do
        read -r start _ _ <<<"${slots[$i]}"
        (( hour >= 10#$start )) && idx=$i
    done
    echo "$idx"
}

# Find the slot whose filename matches the .current symlink target.
# Returns -1 if .current is missing or points at something not in the table.
#
# Path safety: the slot table holds bare filenames (no /), so any
# symlink target containing a slash isn't a match anyway. We also
# reject symlinks that resolve outside $WALL_DIR so a crafted .current
# can't trick downstream code into reading from /etc, /home/other, etc.
slot_index_of_current() {
    local cur_link="" cur_real i fname
    [[ -L "$WALL_DIR/.current" ]] && cur_link="$(readlink "$WALL_DIR/.current")"
    [[ -z "$cur_link" ]] && { echo -1; return; }
    # Reject ../ traversal and absolute-path targets outright. .current
    # is supposed to be a bare filename symlink (e.g. "foxml_earthy.jpg")
    # inside $WALL_DIR; anything else is suspicious.
    if [[ "$cur_link" == /* || "$cur_link" == *../* || "$cur_link" == */* ]]; then
        echo -1; return
    fi
    cur_real="$(readlink -f "$WALL_DIR/.current" 2>/dev/null)"
    if [[ -n "$cur_real" && "$cur_real" != "$WALL_DIR/"* ]]; then
        echo -1; return
    fi
    for i in "${!slots[@]}"; do
        read -r _ _ fname <<<"${slots[$i]}"
        [[ "$fname" == "$cur_link" ]] && { echo "$i"; return; }
    done
    echo -1
}

case "$MODE" in
    --cycle)
        # Cycle through EVERY non-variant wallpaper in $WALL_DIR, not just
        # the 4 time-of-day slots — so `fox-wallpaper --add`'d images
        # appear in the rotation. Variants (foo_WxH.jpg, foo_portrait.jpg)
        # are filtered out so we cycle base wallpapers only.
        cycle_list=()
        while IFS= read -r f; do
            base="$(basename "$f")"
            [[ "$base" == .* ]] && continue
            [[ "$base" =~ _[0-9]+x[0-9]+\. ]] && continue
            [[ "$base" =~ _portrait\. ]] && continue
            cycle_list+=("$base")
        done < <(find "$WALL_DIR" -maxdepth 1 -type f \
                 \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.webp" \) \
                 | sort)

        if (( ${#cycle_list[@]} == 0 )); then
            echo "no wallpapers found in $WALL_DIR" >&2
            exit 1
        fi

        # Find current position in the discovered list; advance one.
        cur_link=""
        [[ -L "$WALL_DIR/.current" ]] && cur_link="$(readlink "$WALL_DIR/.current")"
        cur_idx=-1
        for i in "${!cycle_list[@]}"; do
            [[ "${cycle_list[$i]}" == "$cur_link" ]] && { cur_idx=$i; break; }
        done
        next_idx=$(( (cur_idx + 1) % ${#cycle_list[@]} ))
        target_file="${cycle_list[$next_idx]}"
        # The downstream logic still expects target_idx into $slots; if the
        # advance target ALSO appears in the slot table use that, otherwise
        # fall through to the file-based path below.
        target_idx=-1
        for i in "${!slots[@]}"; do
            read -r _ _ fname <<<"${slots[$i]}"
            [[ "$fname" == "$target_file" ]] && { target_idx=$i; break; }
        done
        ;;
    --static)
        # Always use the midday slot (foxml_earthy.jpg).
        target_idx=1
        ;;
    bucket|"")
        target_idx=$(calendar_slot_index)
        ;;
    *)
        echo "usage: $0 [--cycle|--static]" >&2
        exit 2
        ;;
esac

# If --cycle landed on a wallpaper outside the slot table, target_idx is
# -1 and target_file holds the bare filename to use directly.
if (( target_idx == -1 )); then
    pick="${WALL_DIR}/${target_file}"
    filename="${target_file}"
else
    read -r _ _ filename <<<"${slots[$target_idx]}"
    pick="${WALL_DIR}/${filename}"
fi
[[ ! -f "$pick" ]] && { echo "missing $pick" >&2; exit 1; }

# Load the layout sidecar — MONITOR_RESOLUTIONS drives per-monitor file
# pick; PRIMARY + SECONDARY_OUTPUTS drives the boot wait-for-monitors
# loop. Parsed instead of sourced so a spoofed monitor name can't smuggle
# in shell code via the sidecar.
PRIMARY=""
PORTRAIT_OUTPUTS=""
SECONDARY_OUTPUTS=""
MONITOR_RESOLUTIONS=""
layout="${HOME}/.config/foxml/monitor-layout.conf"
if [[ -r "$layout" ]]; then
    while IFS='=' read -r _k _v; do
        _v="${_v#\"}"; _v="${_v%\"}"
        case "$_k" in
            PRIMARY)             PRIMARY="$_v" ;;
            PORTRAIT_OUTPUTS)    PORTRAIT_OUTPUTS="$_v" ;;
            SECONDARY_OUTPUTS)   SECONDARY_OUTPUTS="$_v" ;;
            MONITOR_RESOLUTIONS) MONITOR_RESOLUTIONS="$_v" ;;
        esac
    done < <(grep -E '^(PRIMARY|PORTRAIT_OUTPUTS|SECONDARY_OUTPUTS|MONITOR_RESOLUTIONS)=' "$layout")
fi

# Idempotency: skip the fade + notify if we'd be applying what's already up,
# unless --cycle was passed (cycle should always change the image). Gate on a
# live awww-daemon: on cold boot the daemon isn't running yet but the .current
# symlink persists from last session, so an unconditional early-exit here would
# skip the daemon-start below entirely and leave a black screen. Only honour
# what's-already-up when the daemon is actually serving it.
if [[ "$MODE" != "--cycle" ]] && awww query &>/dev/null; then
    current_target=""
    [[ -L "$WALL_DIR/.current" ]] && current_target="$(readlink "$WALL_DIR/.current")"
    [[ "$current_target" == "$filename" ]] && exit 0
fi

ln -sfn "$filename" "$WALL_DIR/.current"

# ─────────────────────────────────────────
# Wait for every expected monitor to enumerate. On cold boot the secondary
# can take a moment to appear after Hyprland starts; without this wait,
# exec-once = rotate_wallpaper.sh applies to only the primary and the
# secondary is left wallpaper-less until the next manual cycle.
# Capped so a genuinely-unplugged dock doesn't hang boot — fall through
# and apply to whatever is present.
# ─────────────────────────────────────────
wait_for_monitors() {
    [[ -z "${SECONDARY_OUTPUTS// /}" ]] && return 0
    command -v hyprctl >/dev/null 2>&1 || return 0
    command -v jq      >/dev/null 2>&1 || return 0
    local expected="${PRIMARY} ${SECONDARY_OUTPUTS}"
    local deadline=$(( SECONDS + 5 ))
    local got missing m
    while (( SECONDS < deadline )); do
        got=$(hyprctl monitors -j 2>/dev/null | jq -r '.[].name' 2>/dev/null | tr '\n' ' ' || true)
        missing=0
        for m in $expected; do
            [[ -z "$m" ]] && continue
            [[ " $got " == *" $m "* ]] || { missing=1; break; }
        done
        (( missing == 0 )) && return 0
        sleep 0.2
    done
}
wait_for_monitors

# Map monitor name → pre-rendered variant file (absolute path). Pulls WxH
# from MONITOR_RESOLUTIONS; falls back to source on miss. Empty when the
# sidecar has no entries — the per-monitor loop below uses crop in that case.
declare -A monitor_pick
pick_ext="${pick##*.}"
pick_base="${pick%.*}"
for entry in $MONITOR_RESOLUTIONS; do
    name="${entry%%:*}"
    res="${entry##*:}"
    [[ -z "$name" || -z "$res" || "$name" == "$entry" ]] && continue
    variant="${pick_base}_${res}.${pick_ext}"
    if [[ -f "$variant" ]]; then
        monitor_pick[$name]="$variant"
    else
        monitor_pick[$name]="$pick"
    fi
done

# Make sure awww-daemon is up; spawn detached if not. Wait for the socket
# to become responsive before issuing img — daemon startup is async.
if ! awww query &>/dev/null; then
    setsid awww-daemon >/dev/null 2>&1 < /dev/null &
    disown
    for _ in {1..30}; do
        awww query &>/dev/null && break
        sleep 0.1
    done
fi

# Apply per monitor: prefer the pre-rendered variant (--resize fit, exact
# pixel match, no rescale), else fall back to the source with --resize crop.
applied_per_monitor=false
if command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    monitors_json=$(hyprctl monitors -j 2>/dev/null || true)
    if [[ -n "$monitors_json" && "$monitors_json" != "[]" ]]; then
        applied_per_monitor=true
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            mon_pick="${monitor_pick[$name]:-$pick}"
            if [[ "$mon_pick" == "$pick" ]]; then
                resize="crop"
            else
                resize="fit"
            fi
            awww img -o "$name" "$mon_pick" \
                --resize "$resize" \
                --transition-type fade \
                --transition-duration 1 \
                --transition-fps 60 || true
        done < <(echo "$monitors_json" | jq -r '.[].name')
    fi
fi

if ! $applied_per_monitor; then
    awww img "$pick" \
        --transition-type fade \
        --transition-duration 1 \
        --transition-fps 60
fi

# ─────────────────────────────────────────
# Rewrite each `background { monitor = NAME; path = ... }` block in
# hyprlock.conf to point at the rotated variant. Awk tracks which block
# we're inside so we can update the path line scoped to the matching
# monitor — no global path stomp like the previous sed pass did.
# ─────────────────────────────────────────
hyprlock_conf="${HOME}/.config/hypr/hyprlock.conf"
if [[ -f "$hyprlock_conf" && ${#monitor_pick[@]} -gt 0 ]]; then
    # Build "name=path,name=path,..." for awk. ~ is preserved literally so
    # hyprlock does its own home expansion (matches template style).
    pairs=""
    for name in "${!monitor_pick[@]}"; do
        v="${monitor_pick[$name]}"
        # Reattach ~ for the in-config path so the file stays portable.
        v_path="${v/#$HOME/~}"
        pairs+="${name}=${v_path},"
    done
    pairs="${pairs%,}"

    tmp=$(mktemp)
    # Under `set -e`, any failure between mktemp and mv would leak the
    # tempfile. Trap covers the success path too — mv removes the inode
    # so the second rm is a no-op.
    trap 'rm -f "$tmp"' EXIT
    awk -v pairs="$pairs" '
        BEGIN {
            n = split(pairs, parts, ",")
            for (i = 1; i <= n; i++) {
                k = parts[i]; sub(/=.*/, "", k)
                v = parts[i]; sub(/^[^=]+=/, "", v)
                map[k] = v
            }
        }
        /^[[:space:]]*background[[:space:]]*{/ { in_bg = 1; mon = ""; print; next }
        in_bg && /^[[:space:]]*monitor[[:space:]]*=/ {
            line = $0
            sub(/^[^=]+=[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            mon = line
            print $0; next
        }
        in_bg && /^[[:space:]]*path[[:space:]]*=/ && (mon in map) {
            sub(/=.*/, "= " map[mon])
            print; next
        }
        /^[[:space:]]*}/ && in_bg { in_bg = 0; mon = ""; print; next }
        { print }
    ' "$hyprlock_conf" > "$tmp" && mv "$tmp" "$hyprlock_conf"
fi

echo "rotated to $filename"
command -v notify-send &>/dev/null && \
    notify-send -t 3000 -i "$pick" "Wallpaper" "${filename%.*}" || true
