#!/bin/bash

# Media keys: play/pause, next or previous through playerctl, then Paper's "a little song." slip
# with what is playing now. Without Paper's Quickshell, a plain notification says the same.

action=${1:-}
case "$action" in
    play-pause|next|previous) ;;
    *) echo "usage: media.sh play-pause|next|previous" >&2; exit 2 ;;
esac

if ! command -v playerctl >/dev/null 2>&1; then
    notify-send -a fox-osd -h string:x-canonical-private-synchronous:media --transient -- "Media keys need playerctl" "Install playerctl to control players."
    exit 1
fi

format=$'{{title}}\x1f{{artist}}\x1f{{status}}\x1f{{mpris:artUrl}}'
read_player() { playerctl --no-messages metadata --format "$format" 2>/dev/null | head -c 16384 | tr -d '\n'; }

before=$(read_player)
playerctl --no-messages "$action" 2>/dev/null

# The player answers on its own time; wait a moment for the new state or track.
now=$before
for _ in 1 2 3 4 5 6; do
    sleep 0.08
    now=$(read_player)
    [[ "$now" != "$before" ]] && break
done

IFS=$'\x1f' read -r title artist status art <<<"$now"
[[ "$status" == Playing || "$status" == Paused || "$status" == Stopped ]] || { title=""; artist=""; status=""; art=""; }

palette="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/modules/border_colors.sh"
[[ -r "$palette" ]] && source "$palette"
if [[ "${C_LITTLE_DETAILS:-}" == fox-little-details-on ]] &&
    quickshell -c desk ipc call media present -- "$title" "$artist" "$status" "$art" >/dev/null 2>&1; then
    exit 0
fi

case "$status" in
    Playing) heading="Playing" ;;
    Paused) heading="Paused" ;;
    Stopped) heading="Stopped" ;;
    *) heading="Nothing is playing" ;;
esac
body=$title
[[ -n "$artist" ]] && body="${body:+$body · }$artist"
notify-send -a fox-osd -h string:x-canonical-private-synchronous:media -i audio-x-generic --transient -- "$heading" "$body"
