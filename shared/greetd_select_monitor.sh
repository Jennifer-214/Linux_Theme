#!/bin/sh
# greetd-side monitor picker — runs inside the minimal Hyprland greeter
# session before regreet starts. If a built-in laptop panel is present
# (eDP*/LVDS*/DSI*), disables every other connected output so regreet
# always lands on the laptop screen, regardless of external monitor names
# or rotation. On desktops with no internal display, does nothing — every
# monitor stays live and Hyprland's default order applies.

monitors=$(hyprctl monitors 2>/dev/null | awk '/^Monitor /{print $2}')
[ -z "$monitors" ] && exit 0

internal=""
for m in $monitors; do
    case "$m" in
        eDP*|LVDS*|DSI*|edp*|lvds*|dsi*)
            internal="$m"
            break
            ;;
    esac
done

[ -z "$internal" ] && exit 0

# Hyprland 0.57+ takes Lua over IPC (no `keyword`); older releases only `keyword`.
case "$(hyprctl eval 'return 1' 2>&1)" in
    *"unknown request"*|*"only supported with the lua"*) lua=0 ;;
    *) lua=1 ;;
esac

for m in $monitors; do
    [ "$m" = "$internal" ] && continue
    if [ "$lua" = 1 ]; then
        hyprctl eval "hl.monitor({ output = \"$m\", disabled = true })" >/dev/null 2>&1
    else
        hyprctl keyword monitor "$m,disable" >/dev/null 2>&1
    fi
done
