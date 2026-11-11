#!/bin/bash

# Launch Yazi in the background
kitty --class yazi -e yazi &

# Wait until the window appears
for i in {1..10}; do
    sleep 0.2
    # Check if a window with app_id=yazi exists
    if hyprctl clients | grep -q 'class: yazi'; then
        # Move to special workspace silently
        desk-hl dispatch "hl.dsp.window.move({ workspace = 'special:yazi', follow = false })" "movetoworkspacesilent special:yazi"
        break
    fi
done
