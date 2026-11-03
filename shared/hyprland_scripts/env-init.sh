#!/bin/bash
# D-Bus: prefer the user-session bus that systemd --user already
# provides. eval $(dbus-launch) was previously spawning a SECOND bus
# instance each session, leading to stale daemons and (in theory)
# bus-address interception. The systemd-managed bus lives at
#     $XDG_RUNTIME_DIR/bus
# and is the standard one every modern app uses. Only fall back to
# dbus-launch if that socket doesn't exist (e.g. very old setups
# without systemd --user).
if [[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus"
elif command -v dbus-launch >/dev/null 2>&1; then
    eval "$(dbus-launch)"
    export DBUS_SESSION_BUS_ADDRESS
    export DBUS_SESSION_BUS_PID
fi

# Cursor — set early so Hyprland and XWayland pick it up.
# install_catppuccin_cursor() drops the theme into ~/.local/share/icons,
# which isn't in the default XCURSOR_PATH. XCURSOR_SIZE is set per-monitor
# by start_waybar.sh after Hyprland is up; pre-launch fallback is 24
# (1080p default — gets corrected on the first apply-scale pass).
export XCURSOR_SIZE=24
# XCURSOR_THEME is inherited from Hyprland (theme.conf, from the palette).
export XCURSOR_THEME="${XCURSOR_THEME:-catppuccin-mocha-peach-cursors}"
export HYPRCURSOR_THEME="${HYPRCURSOR_THEME:-$XCURSOR_THEME}"
export HYPRCURSOR_SIZE="${HYPRCURSOR_SIZE:-$XCURSOR_SIZE}"
export XCURSOR_PATH="$HOME/.local/share/icons:$HOME/.icons:/usr/share/icons:/usr/share/pixmaps"

# systemd --user integration. Push Wayland/desktop env vars into the user
# systemd manager so services launched by it inherit them. Our long-lived
# units use WantedBy=default.target (already active on login) rather than
# graphical-session.target, which is RefuseManualStart=yes upstream and is
# not auto-activated by Hyprland.
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user import-environment \
        WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE \
        DISPLAY DBUS_SESSION_BUS_ADDRESS \
        XCURSOR_THEME XCURSOR_SIZE XCURSOR_PATH HYPRCURSOR_THEME HYPRCURSOR_SIZE 2>/dev/null
fi
