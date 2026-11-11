#!/bin/bash
# Linux_Theme Update Checker
# Sends a notification when updates are available

# Initial sleep to let the system connect to network
sleep 15

while true; do
    # Check for updates (requires pacman-contrib)
    if command -v checkupdates >/dev/null 2>&1; then
        updates=$(checkupdates 2>/dev/null | wc -l)
        
        if [[ "$updates" -gt 0 ]]; then
            # Send notification with action (requires mako or dunst)
            # Note: Actions need to be handled by the notification daemon config
            notify-send -i software-update-available \
                "System Updates" \
                "$updates packages can be updated.\nClick the Hub (Mod+Shift+H) -> Cleanup to update."
        fi
    fi
    
    # Check every 4 hours
    sleep 14400
done
