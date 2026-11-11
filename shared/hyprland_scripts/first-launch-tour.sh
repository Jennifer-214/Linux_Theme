#!/usr/bin/env bash
# first-launch-tour.sh — show desk-cheatsheet once after a fresh install.
#
# Gated by ~/.local/share/foxml/.first-launch-shown. On the very first
# Hyprland session after install, we wait ~3s for the bar/notif daemon
# to come up, then pop the cheatsheet so the user sees the keybinds.
# Subsequent sessions are silent.
#
# To re-trigger the tour: `rm ~/.local/share/foxml/.first-launch-shown`
# and relogin (or just run desk-cheatsheet directly any time).

set -u

MARKER="$HOME/.local/share/foxml/.first-launch-shown"
[[ -f "$MARKER" ]] && exit 0

# Wait for the bar to settle so the tour drawer doesn't fight startup
# repaints. ~3 seconds is a comfortable margin.
sleep 3

if command -v desktop-menu >/dev/null 2>&1; then
    desktop-menu --open cheatsheet >/dev/null 2>&1 || true
fi

mkdir -p "$(dirname "$MARKER")"
date -Iseconds > "$MARKER"
