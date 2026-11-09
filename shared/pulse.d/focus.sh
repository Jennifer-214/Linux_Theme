#!/usr/bin/env bash
# focus.sh — fox-pulse's one-shot focus handler, run once per workspace/monitor
# focus change (debounced by fox-pulse, which owns the Hyprland IPC connection).
#
# It deliberately does nothing. It used to post a "Workspace 3 • project" notice on
# every switch; the bar already shows the workspace, so that was only noise. The
# file stays as the hook point: fox-pulse runs this one-shot handler and never
# falls back to the old persistent focus-pulse.sh listener (which leaked one
# listener per switch). Anything added here must do its work and exit.
exit 0
