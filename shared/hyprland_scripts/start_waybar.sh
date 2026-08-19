#!/usr/bin/env bash
# start_waybar.sh — apply monitor-scale-dependent settings, then launch waybar.
#
# Renders waybar style.css + config from .tmpl files (size-token substitution)
# AND sets cursor size to match — a 1080p panel and a 4K panel need very
# different waybar font sizes and cursor sizes.
#
# Profiles (effective width = pixels / monitor scale):
#   ≤ 1920  → 1080p   font 9.5pt,  bar 32, cursor 24
#   ≤ 2560  → 1440p   font 11pt,   bar 40, cursor 28
#   else    → 4K      font 12.5pt, bar 52, cursor 32
#
# Per-output, scales to N monitors: a waybar instance has exactly one style,
# so each output is sized from ITS OWN effective width. Outputs that share a
# size profile share one instance (pinned to all of them); each distinct
# profile gets its own correctly-sized instance. The primary output always
# gets the full bar (config.tmpl); every other output gets the secondary bar
# (config_secondary.tmpl). No bar is ever scaled from a different monitor.
# Single-monitor setups keep a single instance (the common case, unchanged).
#
# Re-runnable: rerunning regenerates from the .tmpl files, so changing a
# theme via swap.sh + reloading Hyprland picks up new colors AND scales
# correctly to the current monitors.

set -euo pipefail

WAYBAR_DIR="${HOME}/.config/waybar"
STYLE_TMPL="${WAYBAR_DIR}/style.css.tmpl"
CONFIG_TMPL="${WAYBAR_DIR}/config.tmpl"
CONFIG_SECONDARY_TMPL="${WAYBAR_DIR}/config_secondary.tmpl"
STYLE_OUT="${WAYBAR_DIR}/style.css"
CONFIG_OUT="${WAYBAR_DIR}/config"
LAYOUT_FILE="${HOME}/.config/foxml/monitor-layout.conf"

# Effective width of a named monitor — `width / scale` is what waybar/Hyprland
# actually lay out against (a 4K panel at scale 2.0 should size like 1080p).
# With no name, falls back to the first monitor; with no hyprctl/jq, 1920.
effective_width_of() {
    local name="${1:-}"
    command -v hyprctl >/dev/null 2>&1 || { echo 1920; return; }
    command -v jq      >/dev/null 2>&1 || { echo 1920; return; }
    local out w s
    out=$(hyprctl monitors -j 2>/dev/null) || { echo 1920; return; }
    if [[ -n "$name" ]]; then
        w=$(printf '%s' "$out" | jq -r --arg n "$name" 'first(.[] | select(.name==$n) | .width)  // 1920')
        s=$(printf '%s' "$out" | jq -r --arg n "$name" 'first(.[] | select(.name==$n) | .scale)  // 1')
    else
        w=$(printf '%s' "$out" | jq -r '.[0].width // 1920')
        s=$(printf '%s' "$out" | jq -r '.[0].scale // 1')
    fi
    [[ -n "$w" && "$w" != "null" ]] || w=1920
    [[ -n "$s" && "$s" != "null" ]] || s=1
    # bash arithmetic doesn't do floats — multiply scale by 100, divide.
    local s100
    s100=$(awk -v s="$s" 'BEGIN{ printf "%d", s*100 }')
    (( s100 < 1 )) && s100=100
    echo $(( w * 100 / s100 ))
}

# Pick a profile from an effective width. Sets the size tokens both the CSS and
# the JSON config consume — keep token names in sync with templates/waybar/
# style.css and shared/waybar_config. Called once per output we render a bar for.
compute_profile() {
    local ew="$1"
    if   (( ew <= 1920 )); then
        PROFILE="1080p"
        FONT_BASE="10"; FONT_LOGO="12";   FONT_STATS="9"
        PAD_WIN="3px 8px"; PAD_MOD="2px 10px"; MARGIN_MOD="1px 4px"
        HEIGHT="34"; TRAY_ICON="14"
        CURSOR_SIZE="24"
    elif (( ew <= 2560 )); then
        PROFILE="1440p"
        FONT_BASE="11.5";  FONT_LOGO="14";   FONT_STATS="10.5"
        PAD_WIN="4px 9px"; PAD_MOD="3px 12px"; MARGIN_MOD="2px 5px"
        HEIGHT="42"; TRAY_ICON="15"
        CURSOR_SIZE="28"
    else
        PROFILE="4K"
        FONT_BASE="13"; FONT_LOGO="16";  FONT_STATS="12"
        PAD_WIN="4px 10px"; PAD_MOD="4px 14px"; MARGIN_MOD="2px 6px"
        HEIGHT="56"; TRAY_ICON="16"
        CURSOR_SIZE="32"
    fi
}

# Fetch gaps_out from Hyprland to align bar perfectly with windows.
# Default to 12 if not found or if hyprctl fails.
get_gaps() {
    if ! command -v hyprctl >/dev/null 2>&1; then
        echo 12; return
    fi
    local gaps
    gaps=$(hyprctl getoption general:gaps_out -j 2>/dev/null | jq -r '.custom' | awk '{print $1}')
    if [[ -z "$gaps" || "$gaps" == "null" ]]; then
        echo 12
    else
        echo "$gaps"
    fi
}

# Substitute size tokens. Use a sed delimiter that won't appear in any value —
# pipe is safe for these size strings (px, pt, plain ints, space-separated
# quads). MARGIN_BAR must be set by the caller before each call.
substitute() {
    local in="$1" out="$2"
    sed \
        -e "s|__FONT_BASE__|${FONT_BASE}|g" \
        -e "s|__FONT_LOGO__|${FONT_LOGO}|g" \
        -e "s|__FONT_STATS__|${FONT_STATS}|g" \
        -e "s|__PAD_WIN__|${PAD_WIN}|g" \
        -e "s|__PAD_MOD__|${PAD_MOD}|g" \
        -e "s|__MARGIN_MOD__|${MARGIN_MOD}|g" \
        -e "s|__HEIGHT__|${HEIGHT}|g" \
        -e "s|__MARGIN_BAR__|${MARGIN_BAR}|g" \
        -e "s|__TRAY_ICON__|${TRAY_ICON}|g" \
        "$in" > "$out"
}

GAPS=$(get_gaps)

# Construct margin string: {gaps} {gaps} 0 {gaps}, minus the 4px border width
# so the outer edges of the bar and the windows line up. Profile-independent
# (gaps-driven), so it's shared by every bar we render.
ALIGNED_MARGIN=$(( GAPS - 4 ))
(( ALIGNED_MARGIN < 0 )) && ALIGNED_MARGIN=0
MARGIN_BAR="${ALIGNED_MARGIN} ${GAPS} 0 ${GAPS}"

# --- Resolve the monitor layout up front: PRIMARY drives the main bar's size
# profile; each SECONDARY_OUTPUTS monitor gets sized from itself. Parsed (not
# sourced) so a crafted monitor name can't smuggle in shell code.
PRIMARY=""
PORTRAIT_OUTPUTS=""
SECONDARY_OUTPUTS=""
MONITOR_RESOLUTIONS=""
if [[ -r "$LAYOUT_FILE" ]]; then
    while IFS='=' read -r _k _v; do
        _v="${_v#\"}"; _v="${_v%\"}"
        case "$_k" in
            PRIMARY)             PRIMARY="$_v" ;;
            PORTRAIT_OUTPUTS)    PORTRAIT_OUTPUTS="$_v" ;;
            SECONDARY_OUTPUTS)   SECONDARY_OUTPUTS="$_v" ;;
            MONITOR_RESOLUTIONS) MONITOR_RESOLUTIONS="$_v" ;;
        esac
    done < <(grep -E '^(PRIMARY|PORTRAIT_OUTPUTS|SECONDARY_OUTPUTS|MONITOR_RESOLUTIONS)=' "$LAYOUT_FILE")
fi

# Defensive fallback: sidecar empty/stale but we're live under Hyprland with
# more than one monitor — e.g. logged in with both already connected, so the
# monitor daemon never saw a monitoradded event to refresh the sidecar — derive
# the layout straight from hyprctl so the per-output split still forms. Skipped
# at install time (--render-only runs pre-Hyprland with no IPC socket).
if [[ -z "$SECONDARY_OUTPUTS" ]] && command -v hyprctl >/dev/null 2>&1 \
    && command -v jq >/dev/null 2>&1 \
    && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" || -d "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" ]]; then
    _mons=$(hyprctl monitors -j 2>/dev/null)
    if [[ -n "$_mons" ]] && (( $(printf '%s' "$_mons" | jq 'length' 2>/dev/null || echo 0) > 1 )); then
        [[ -n "$PRIMARY" ]] || PRIMARY=$(printf '%s' "$_mons" | jq -r '.[0].name')
        SECONDARY_OUTPUTS=$(printf '%s' "$_mons" \
            | jq -r --arg p "$PRIMARY" '.[] | select(.name != $p) | .name' \
            | tr '\n' ' ' | sed 's/ *$//')
    fi
fi

# If the .tmpl files don't exist yet (e.g. someone ran an older install.sh),
# fall back to whatever's currently in style.css/config — better to start an
# untouched bar than to fail silently.
[[ -f "$STYLE_TMPL"  ]] || cp -f "$STYLE_OUT"  "$STYLE_TMPL"  2>/dev/null || true
[[ -f "$CONFIG_TMPL" ]] || cp -f "$CONFIG_OUT" "$CONFIG_TMPL" 2>/dev/null || true

# --- PRIMARY bar: full bar (config.tmpl), sized from the primary monitor. ---
EW=$(effective_width_of "$PRIMARY")
compute_profile "$EW"
[[ -f "$STYLE_TMPL"  ]] && substitute "$STYLE_TMPL"  "$STYLE_OUT"
[[ -f "$CONFIG_TMPL" ]] && substitute "$CONFIG_TMPL" "$CONFIG_OUT"

# Rofi offsets + cursor come from the PRIMARY profile — the launcher opens on
# the primary and the pointer size is session-global.
ROFI_Y=$(( ALIGNED_MARGIN + HEIGHT - 1 ))
MOD_X_MARGIN=$(echo "$MARGIN_MOD" | awk '{print $NF}' | tr -dc '0-9')
ROFI_X=$(( GAPS + MOD_X_MARGIN ))
CURSOR_SIZE_USE="$CURSOR_SIZE"
PROFILE_PRIMARY="$PROFILE"
EW_PRIMARY="$EW"

# --- SECONDARY bars: one instance per distinct size profile across all the
# external outputs, each pinned to exactly the monitors at that profile. Two
# 4K externals share one 4K bar; a 4K + a 1440p get one bar each. Scales to N.
SECONDARY_INSTANCES=()   # "config|style" pairs to launch
SECONDARY_DESC=""
HAVE_SECONDARY=0
if [[ -n "$SECONDARY_OUTPUTS" && -f "$CONFIG_SECONDARY_TMPL" && -f "$STYLE_TMPL" && -n "$PRIMARY" ]] \
    && command -v jq >/dev/null 2>&1; then
    # Drop stale per-instance renders from a previous layout (never the .tmpl).
    rm -f "$WAYBAR_DIR"/config_secondary.inst* "$WAYBAR_DIR"/style_secondary.inst*.css 2>/dev/null || true

    # Bucket every secondary output by its own size profile.
    declare -A _grp=()
    for _m in $SECONDARY_OUTPUTS; do
        _ew=$(effective_width_of "$_m")
        compute_profile "$_ew"
        _grp["$PROFILE"]+="$_m "
    done

    _idx=0
    for _prof in "${!_grp[@]}"; do
        _members="${_grp[$_prof]}"
        _first="${_members%% *}"
        _ew=$(effective_width_of "$_first")
        compute_profile "$_ew"          # re-derive this group's sizing
        _cfg="${WAYBAR_DIR}/config_secondary.inst${_idx}"
        _sty="${WAYBAR_DIR}/style_secondary.inst${_idx}.css"
        substitute "$STYLE_TMPL"            "$_sty"
        substitute "$CONFIG_SECONDARY_TMPL" "$_cfg"
        # Pin this instance to exactly the monitors in its profile group.
        _outs=$(printf '%s\n' $_members | jq -R . | jq -s 'map(select(length>0))')
        _t=$(mktemp) && jq --argjson outs "$_outs" '. + {output: $outs}' "$_cfg" > "$_t" \
            && mv "$_t" "$_cfg" || rm -f "$_t"
        SECONDARY_INSTANCES+=("$_cfg|$_sty")
        SECONDARY_DESC+="${_prof}[$(echo $_members | tr ' ' ',' | sed 's/,$//')] "
        _idx=$(( _idx + 1 ))
    done

    # Pin the primary full bar to the primary output only.
    _t=$(mktemp) && jq --arg p "$PRIMARY" '. + {output: [$p]}' "$CONFIG_OUT" > "$_t" \
        && mv "$_t" "$CONFIG_OUT" || rm -f "$_t"
    (( ${#SECONDARY_INSTANCES[@]} > 0 )) && HAVE_SECONDARY=1
fi

# Apply cursor size to the running session AND set XCURSOR_SIZE for new
# children Hyprland spawns. Skip silently if hyprctl can't reach the IPC
# socket (we're being called pre-Hyprland from install.sh).
if command -v hyprctl >/dev/null 2>&1 && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" || -d "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" ]]; then
    hyprctl setcursor "${XCURSOR_THEME:-catppuccin-mocha-peach-cursors}" "$CURSOR_SIZE_USE" >/dev/null 2>&1 || true
    hyprctl setenv XCURSOR_SIZE "$CURSOR_SIZE_USE" >/dev/null 2>&1 || true
    hyprctl setenv ROFI_X "$ROFI_X" >/dev/null 2>&1 || true
    hyprctl setenv ROFI_Y "$ROFI_Y" >/dev/null 2>&1 || true
fi

# `--render-only`: install.sh calls us this way after rendering templates,
# so the live style.css/config exist before Hyprland is even running.
if [[ "${1:-}" == "--render-only" ]]; then
    if (( HAVE_SECONDARY )); then
        echo "  + waybar rendered: primary ${PROFILE_PRIMARY} (${EW_PRIMARY}px) + secondary ${SECONDARY_DESC}(cursor ${CURSOR_SIZE_USE}px)"
    else
        echo "  + waybar rendered for ${PROFILE_PRIMARY} (width ${EW_PRIMARY}px, cursor ${CURSOR_SIZE_USE}px)"
    fi
    exit 0
fi

# Replace any existing waybar so a Hyprland reload picks up new sizes.
# pkill is asynchronous — exec'ing waybar immediately can race the old
# instance still holding its Wayland layer-shell name, leaving a dead
# bar and a "name in use" error in the journal. Wait up to ~2s for the
# old PID(s) to actually exit before launching the new one(s).
if pgrep -x waybar >/dev/null 2>&1; then
    pkill -x waybar 2>/dev/null || true
    for _ in $(seq 1 20); do
        pgrep -x waybar >/dev/null 2>&1 || break
        sleep 0.1
    done
    # Still running? Force it. Better than starting a half-dead second bar.
    pgrep -x waybar >/dev/null 2>&1 && pkill -KILL -x waybar 2>/dev/null
    sleep 0.1
fi

# Multi-monitor: launch each secondary-profile bar in the background, then exec
# the primary bar (keeps the original process model — Hyprland's exec-once sees
# the primary waybar PID; pkill -x waybar still catches every instance).
if (( HAVE_SECONDARY )); then
    for _pair in "${SECONDARY_INSTANCES[@]}"; do
        _cfg="${_pair%%|*}"; _sty="${_pair##*|}"
        waybar -c "$_cfg" -s "$_sty" >/dev/null 2>&1 &
    done
fi
exec waybar -c "$CONFIG_OUT" -s "$STYLE_OUT"
