#!/bin/bash
# Toggle the Linux_Theme Eww Control Center (and its drawer).

if eww list-windows 2>/dev/null | grep -qE '^\*?\s*control_center( |$)'; then
    eww close control_center control_center_drawer 2>/dev/null
    eww update drawer_panel="" 2>/dev/null
else
    eww update drawer_panel="" 2>/dev/null
    eww open control_center
fi
