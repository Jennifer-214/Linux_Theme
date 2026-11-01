#!/bin/sh
# greetd's greeter command: start Hyprland with the config the installed
# release can read. Hyprland 0.57 reads only Lua (hyprland.lua); 0.56 and
# older read hyprland.conf. Decided at every boot, so a pacman upgrade or
# downgrade can't leave the login screen with a config it can't parse.
# Unknown versions get Lua, which is what every release from 0.57 on needs.

# shellcheck disable=SC2046  # split "MAJOR MINOR" into $1 $2 on purpose
set -- $(Hyprland --version 2>/dev/null | sed -n '1s/^Hyprland \([0-9][0-9]*\)\.\([0-9][0-9]*\)\..*/\1 \2/p')

if [ "${1:-}" = 0 ] && [ "${2:-57}" -lt 57 ]; then
    exec Hyprland -c /etc/greetd/hyprland.conf
fi
exec Hyprland -c /etc/greetd/hyprland.lua
