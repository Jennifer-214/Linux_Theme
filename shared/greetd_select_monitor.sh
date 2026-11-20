#!/bin/sh
# greetd-side monitor picker — runs inside the minimal Hyprland greeter
# session before regreet starts. If a built-in laptop panel is present
# (eDP*/LVDS*/DSI*), moves the focus to it, so regreet (a new window, on the
# focused screen) lands on the laptop screen whatever the external monitors
# are called. Every screen stays on: switching the others off left the login
# black on an NVIDIA laptop (2026-11-19, "Flip event timeout on head 2", a
# screen turned off with a frame on its way). On desktops with no internal
# display, does nothing and Hyprland's default order applies.

# Hyprland 0.57 runs this from hyprland.start, which can come before its outputs are listed: an empty or partial
# list left every monitor on and regreet on the leftmost (2026-11-15). Wait until the list is non-empty and the same
# twice in a row, 0.1 s apart, for at most 5 s; with nothing by then, change nothing.
monitors="" previous="" tries=0
while [ "$tries" -lt 50 ]; do
    monitors=$(hyprctl monitors 2>/dev/null | awk '/^Monitor /{print $2}')
    [ -n "$monitors" ] && [ "$monitors" = "$previous" ] && break
    previous="$monitors"
    tries=$((tries + 1))
    sleep 0.1
done
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

if [ "$lua" = 1 ]; then
    hyprctl eval "hl.dispatch(hl.dsp.focus({ monitor = \"$internal\" }))" >/dev/null 2>&1
else
    hyprctl dispatch focusmonitor "$internal" >/dev/null 2>&1
fi
