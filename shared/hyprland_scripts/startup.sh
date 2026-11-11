#!/bin/bash

# Start UI services (hypridle started via exec-once in autostart.conf).
# start_waybar.sh detects monitor scale + sed-substitutes size tokens into
# the live waybar style.css/config, then execs waybar.
~/.config/hypr/scripts/start_waybar.sh &

if command -v desktop-menu >/dev/null 2>&1 && desktop-menu --available; then
    desktop-menu --start &
fi

# Border telemetry (dynamic earthy borders based on system state)
~/.config/hypr/scripts/border_telemetry.sh &

# Update checker
~/.config/hypr/scripts/update_check.sh &

# Set wallpaper with a small delay
sleep 1
#swww img ~/.wallpapers/fox.png --transition-type simple &

# Wait a bit then switch to workspace 1
sleep 2
desk-hl dispatch "hl.dsp.focus({ workspace = 1 })" "workspace 1" &
