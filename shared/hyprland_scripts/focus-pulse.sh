#!/usr/bin/env bash
# focus-pulse.sh — show a brief OSD on workspace switch.
#
# Listens on Hyprland socket2 for workspace>> events. On each switch,
# fires a short-lived notify-send with the workspace name + active
# window's project context (the cwd of the focused window, when it's
# a terminal/editor we can introspect).
#
# Runs as a systemd user service (foxml-focus-pulse.service) — same
# pattern as fox-monitor-watch.service, with Restart=on-failure and
# socat -u to avoid the systemd-stdin-EOF disconnection bug.

set -u

SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:-}/.socket2.sock"
[[ -S "$SOCKET" ]] || { echo "focus-pulse: no Hyprland socket at $SOCKET" >&2; exit 1; }
command -v socat   >/dev/null 2>&1 || { echo "focus-pulse: socat required"   >&2; exit 1; }
command -v hyprctl >/dev/null 2>&1 || { echo "focus-pulse: hyprctl required" >&2; exit 1; }

# Resolve the "project name" for a workspace: the cwd of the focused
# client if we can read it via /proc. Falls back to the workspace
# name. Terminals + editors typically have their cwd set to the
# project; GUI apps don't, so the fallback covers them.
project_for_active() {
    local pid cwd
    pid=$(hyprctl activewindow -j 2>/dev/null | jq -r '.pid // 0')
    if (( pid > 0 )); then
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
        if [[ -n "$cwd" && "$cwd" != "/" ]]; then
            basename "$cwd"
            return
        fi
    fi
    hyprctl activeworkspace -j 2>/dev/null | jq -r '.name // .id // "?"'
}

# Debounce: workspace events can fire 2-3 times during a single switch
# (e.g. `workspace`, `focusedmon`, `activespecial`). Coalesce within
# 200ms so we only fire one notify-send per switch.
DEBOUNCE_MS=200
last_event_ms=0
pending_pid=""

now_ms() { date +%s%3N; }

socat -u UNIX-CONNECT:"$SOCKET" - 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        workspace*|focusedmon*)
            now=$(now_ms)
            if [[ -n "$pending_pid" ]] && kill -0 "$pending_pid" 2>/dev/null; then
                kill "$pending_pid" 2>/dev/null || true
            fi
            (
                # Sleep for the debounce window. Another fire-and-cancel
                # cycle resets the timer.
                sleep "0.${DEBOUNCE_MS}"
                ws=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '"\(.id):\(.name)"' 2>/dev/null)
                ws_name="${ws#*:}"
                ws_id="${ws%%:*}"
                proj=$(project_for_active)
                # Short OSD — 800ms is long enough to register, short
                # enough not to feel like clutter on rapid switching.
                # x-canonical-private-synchronous makes each OSD REPLACE the
                # previous one instead of queueing a new popup per switch.
                # Without it every workspace change stacks another card and
                # mako collapses the pile into "(N more)".
                notify-send -t 800 -a "focus-pulse" \
                    -h string:x-canonical-private-synchronous:focus-pulse \
                    "Workspace ${ws_id} • ${proj}" "${ws_name}" 2>/dev/null || true
            ) &
            pending_pid=$!
            ;;
    esac
done
