#!/bin/bash
# Toggle a yazi instance pinned to its own special workspace.
#  - if a window with class=yazi is mapped: toggle the special workspace
#  - if the process is running but the window is gone (zombie): kill it
#  - otherwise: launch yazi, wait for the window, move it to special, show it

CLASS="yazi"
CMD="kitty --class $CLASS -e yazi"
WORKSPACE="special:$CLASS"

window_exists=$(hyprctl clients -j | jq -e --arg c "$CLASS" '.[] | select(.class==$c)' 2>/dev/null)
process_running=$(pgrep -af "$CMD")

if [ -n "$window_exists" ]; then
    desk-hl dispatch "hl.dsp.workspace.toggle_special('$CLASS')" "togglespecialworkspace $CLASS"
    exit 0
elif [ -n "$process_running" ]; then
    echo "Killing zombie Yazi process..."
    pkill -f "$CMD"
    sleep 0.2
fi

$CMD &

address=""
for i in {1..30}; do
    sleep 0.1
    win_info=$(hyprctl clients -j | jq -r --arg c "$CLASS" '.[] | select(.class==$c)')
    if [ -n "$win_info" ]; then
        workspace=$(echo "$win_info" | jq -r '.workspace.id')
        address=$(echo "$win_info" | jq -r '.address')
        if [[ "$workspace" != "null" && "$address" != "null" ]]; then
            break
        fi
    fi
done

if [ -n "$address" ]; then
    desk-hl dispatch "hl.dsp.window.move({ workspace = '$WORKSPACE', follow = false, window = 'address:$address' })" "movetoworkspacesilent $WORKSPACE,address:$address"
    sleep 0.1
    desk-hl dispatch "hl.dsp.workspace.toggle_special('$CLASS')" "togglespecialworkspace $CLASS"
fi
