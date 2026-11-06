#!/bin/sh
# Keep markup colors in the template: palette parsing treats # as a comment.
day=$(LC_TIME=C date +'%A, %B %-d' | LC_ALL=C tr '[:upper:]' '[:lower:]')
printf '<span font_family="{{HYPRLOCK_CLOCK_FONT}}" style="italic" underline="single" underline_color="#{{SELECTION}}">%s</span>\n' "$day"
