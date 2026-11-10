#!/usr/bin/env bash
# focus.sh — fox-pulse's one-shot focus handler, run once per workspace/monitor
# focus change (debounced by fox-pulse, which owns the Hyprland IPC connection).
#
# It deliberately does nothing. It used to post a "Workspace 3 • project" notice on
# every switch; the bar already shows the workspace, so that was only noise. The
# file stays as the hook point: fox-pulse runs this one-shot handler and never
# falls back to the old persistent focus-pulse.sh listener (which leaked one
# listener per switch). Anything added here must do its work and exit.
#
# It records which screen each workspace lives on, so a workspace moved to the laptop when its screen was
# unplugged goes back when that screen returns (fox-drawer screens-changed, run by fox-pulse's monitor handler).
drawer="$HOME/.local/bin/fox-drawer"
[[ -x "$drawer" ]] && exec "$drawer" workspaces-remember >/dev/null 2>&1
exit 0
