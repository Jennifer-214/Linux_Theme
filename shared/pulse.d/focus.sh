#!/usr/bin/env bash
# focus.sh — one-shot workspace OSD, invoked by fox-pulse per focus event.
#
# MUST do its work and EXIT. fox-pulse owns the Hyprland IPC connection and
# the debounce; this handler is forked per event.
#
# The legacy ~/.config/hypr/scripts/focus-pulse.sh is a standalone socat
# DAEMON (it opens socket2 and loops forever). When this file is absent
# fox-pulse falls back to spawning that daemon on every focus event, so each
# switch leaked one permanent listener and every listener then fired on every
# later event — quadratic notification spam. This file exists to keep
# fox-pulse on its preferred one-shot path.
set -u

command -v hyprctl >/dev/null 2>&1 || exit 0
command -v jq      >/dev/null 2>&1 || exit 0

ws=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '"\(.id):\(.name)"' 2>/dev/null) || exit 0
ws_id="${ws%%:*}"
ws_name="${ws#*:}"
[[ -z "$ws_id" || "$ws_id" == "null" ]] && exit 0

# Project label: cwd of the focused client when readable (terminals/editors),
# else the workspace name.
proj=""
pid=$(hyprctl activewindow -j 2>/dev/null | jq -r '.pid // 0' 2>/dev/null)
if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )); then
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    [[ -n "$cwd" && "$cwd" != "/" ]] && proj=$(basename "$cwd")
fi
[[ -z "$proj" ]] && proj="$ws_name"

# x-canonical-private-synchronous makes each OSD REPLACE the previous one
# rather than queueing another card per switch.
notify-send -t 800 -a "focus-pulse" \
    -h string:x-canonical-private-synchronous:focus-pulse \
    "Workspace ${ws_id} • ${proj}" "${ws_name}" 2>/dev/null || true
