#!/bin/bash
# toggle_btop.sh — toggle a kitty+btop scratchpad on Hyprland's special workspace.
#
# First press: spawn `kitty --class btopterm -e btop`, move to special:btopterm,
#              and show it.
# Subsequent press: hide / show the existing window.
# Zombie kitty without window: kill and respawn.

CLASS="btopterm"
CMD="kitty --class $CLASS -e btop"
WORKSPACE="special:$CLASS"

window_exists=$(hyprctl clients -j 2>/dev/null \
    | jq -e --arg c "$CLASS" '.[] | select(.class==$c)' 2>/dev/null)
process_running=$(pgrep -af "$CMD" 2>/dev/null)

if [ -n "$window_exists" ]; then
    fox-hl dispatch "hl.dsp.workspace.toggle_special('$CLASS')" "togglespecialworkspace $CLASS"
    exit 0
elif [ -n "$process_running" ]; then
    pkill -f "$CMD"
    sleep 0.2
fi

$CMD &

address=""
for _ in {1..30}; do
    sleep 0.1
    win_info=$(hyprctl clients -j 2>/dev/null \
        | jq -r --arg c "$CLASS" '.[] | select(.class==$c)' 2>/dev/null)
    if [ -n "$win_info" ]; then
        workspace=$(echo "$win_info" | jq -r '.workspace.id')
        address=$(echo "$win_info" | jq -r '.address')
        if [[ "$workspace" != "null" && "$address" != "null" ]]; then
            break
        fi
    fi
done

if [ -n "$address" ]; then
    fox-hl dispatch "hl.dsp.window.move({ workspace = '$WORKSPACE', follow = false, window = 'address:$address' })" "movetoworkspacesilent $WORKSPACE,address:$address"
    sleep 0.1
    fox-hl dispatch "hl.dsp.workspace.toggle_special('$CLASS')" "togglespecialworkspace $CLASS"
fi
