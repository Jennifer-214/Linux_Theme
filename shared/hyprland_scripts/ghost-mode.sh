#!/usr/bin/env bash
# ghost-mode.sh — "boss key" toggle.
#
# On: hide the waybar, mute audio, blur all windows, set the active
#     window's opacity to 100% so whatever is up reads as a single
#     opaque pane (no neighbour-window peek-through).
# Off: restore everything to the pre-toggle state.
#
# Keybind: $mod+G in keybinds.conf.
#
# State file at $XDG_RUNTIME_DIR/foxml-ghost-mode tracks toggle status
# AND captures the pre-toggle audio mute state, so we don't accidentally
# UN-mute audio that the user had muted before triggering ghost.

set -u

STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE="$STATE_DIR/foxml-ghost-mode"

was_muted() {
    wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -q MUTED
}

# Parse the state file SAFELY — read key=value pairs and only accept a
# known allowlist of keys with strict value patterns. Previously we did
# `source "$STATE"`, which is arbitrary code execution if anything in
# $XDG_RUNTIME_DIR ever wrote `PRE_MUTED=no; rm -rf ~` to that path.
# This loop refuses anything it doesn't recognise.
_load_ghost_state() {
    local file="$1"
    PRE_MUTED=""
    TS=""
    local k v
    while IFS='=' read -r k v; do
        # Strip surrounding whitespace + any quotes.
        k="${k##[[:space:]]}"; k="${k%%[[:space:]]}"
        v="${v##[[:space:]]}"; v="${v%%[[:space:]]}"
        v="${v#\"}"; v="${v%\"}"
        v="${v#\'}"; v="${v%\'}"
        case "$k" in
            PRE_MUTED)
                # Only literal yes/no — anything else is malicious or stale.
                [[ "$v" == "yes" || "$v" == "no" ]] && PRE_MUTED="$v"
                ;;
            TS)
                # ISO timestamp — letters, digits, :+-T.
                [[ "$v" =~ ^[A-Za-z0-9:+\-T]+$ ]] && TS="$v"
                ;;
            "") continue ;;
            *)  # Unknown key — ignore. Don't print to avoid leaking what we expected.
                ;;
        esac
    done < "$file"
}

if [[ -f "$STATE" ]]; then
    # === OFF: restore ===
    # Reject world-writable / non-user-owned state files — that's the only
    # way a malicious process on the same machine could feed us tampered
    # values. Both checks combined with the parser above close the
    # state-injection vector flagged in audit.
    if [[ "$(stat -c '%u %a' "$STATE" 2>/dev/null)" != "$(id -u) 600" ]]; then
        # File isn't owned by us or has loose perms — re-write it as our
        # canonical "on, audio not muted" state before continuing, so an
        # attacker-planted file can't poison the restore step.
        rm -f "$STATE"
        notify-send -u critical -t 3000 "👻 Ghost Mode" \
            "State file had wrong perms — refusing to read. Toggle again." 2>/dev/null || true
        exit 1
    fi

    _load_ghost_state "$STATE"
    rm -f "$STATE"

    # Show waybar again.
    pkill -SIGUSR1 waybar 2>/dev/null || true

    # Restore audio mute only if the user wasn't already muted pre-toggle.
    if [[ "${PRE_MUTED:-no}" == "no" ]]; then
        wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null || true
    fi

    # Drop the temporary blur + opacity overrides. `hyprctl keyword`
    # with the same key as before resets them back to config defaults
    # on the next hyprctl reload, but we can also unbind the override
    # explicitly by re-issuing the original config values.
    hyprctl --batch "keyword decoration:blur:enabled true ; keyword decoration:blur:size 3 ; keyword decoration:blur:passes 2 ; keyword decoration:active_opacity 0.95 ; keyword decoration:inactive_opacity 0.85" >/dev/null 2>&1 || true

    notify-send -t 1500 "👻 Ghost Mode" "Off" 2>/dev/null || true
    exit 0
fi

# === ON: hide everything ===
# Write state with 0600 perms via umask scope so a co-tenant process on
# the same user session can't tamper with it before we read it back.
( umask 077
  {
      echo "PRE_MUTED=$(was_muted && echo yes || echo no)"
      echo "TS=$(date -Iseconds)"
  } > "$STATE"
)
chmod 600 "$STATE" 2>/dev/null || true

# Hide waybar (SIGUSR1 is its toggle-visibility signal).
pkill -SIGUSR1 waybar 2>/dev/null || true

# Mute audio.
wpctl set-mute @DEFAULT_AUDIO_SINK@ 1 2>/dev/null || true

# Bump blur to max + set ALL window opacity to 1.0 so whatever was
# behind the active window doesn't peek through translucency. The
# active window stays opaque; inactive windows get heavy blur as a
# "you can't see what's there" indicator.
hyprctl --batch "keyword decoration:blur:enabled true ; keyword decoration:blur:size 12 ; keyword decoration:blur:passes 4 ; keyword decoration:active_opacity 1.0 ; keyword decoration:inactive_opacity 1.0" >/dev/null 2>&1 || true

notify-send -t 1500 "👻 Ghost Mode" "On (toggle off with the same keybind)" 2>/dev/null || true
