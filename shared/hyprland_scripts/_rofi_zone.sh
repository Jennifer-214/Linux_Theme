#!/bin/bash
# _rofi_zone.sh — sourceable helper that resolves ROFI_ZONE into a
# rofi -theme-str fragment for window positioning.
#
# Usage from another script:
#   source ~/.config/hypr/scripts/_rofi_zone.sh
#   rofi -theme-str "$ROFI_POS_THEME ..."
#
# Zones:
#   nw      — top-left  (launcher menus: drun, window list, clipboard)
#   ne      — top-right (system menus: hub, network, bluetooth, audio, power)
#   center  — global reference (cheatsheet, etc.)
#
# Per-modal nudge still honored via ROFI_X / ROFI_Y env vars.

case "${ROFI_ZONE:-nw}" in
    ne)
        _rz_loc="north east"; _rz_anchor="north east"; _rz_dx=12; _rz_dy=50
        ;;
    center)
        _rz_loc="center";     _rz_anchor="center";     _rz_dx=0;  _rz_dy=0
        ;;
    nw|*)
        _rz_loc="north west"; _rz_anchor="north west"; _rz_dx=12; _rz_dy=50
        ;;
esac

ROFI_X="${ROFI_X:-$_rz_dx}"
ROFI_Y="${ROFI_Y:-$_rz_dy}"
ROFI_POS_THEME="window {location: ${_rz_loc}; anchor: ${_rz_anchor}; x-offset: ${ROFI_X}px; y-offset: ${ROFI_Y}px;}"

unset _rz_loc _rz_anchor _rz_dx _rz_dy
