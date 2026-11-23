#!/bin/sh
# greetd-side monitor picker — runs inside the minimal Hyprland greeter
# session before regreet starts. If a built-in laptop panel is present
# (eDP*/LVDS*/DSI*), moves the focus to it and regreet's window onto it once
# open, whatever the external monitors are called. Every screen stays
# on: switching the others off left the login black on an NVIDIA laptop
# (2026-11-19, "Flip event timeout on head 2", a screen turned off with a frame
# on its way). On desktops with no internal display, does nothing and
# Hyprland's default order applies.

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
# One line per boot in the journal (`journalctl -t greeter-monitor`): the greeter's own Hyprland log is gone once
# someone logs in.
log() { logger -t greeter-monitor "$*" 2>/dev/null || :; }

[ -z "$monitors" ] && { log "no outputs listed after 5 s; nothing changed"; exit 0; }
outputs=$(printf '%s' "$monitors" | tr '\n' ' ')

internal=""
for m in $monitors; do
    case "$m" in
        eDP*|LVDS*|DSI*|edp*|lvds*|dsi*)
            internal="$m"
            break
            ;;
    esac
done

[ -z "$internal" ] && { log "outputs: $outputs - no laptop panel; nothing changed"; exit 0; }

# A docked laptop with the lid shut still lists its panel: the login must stay on a screen that is lit.
for lid in "${GREETER_LID_DIR:-/proc/acpi/button/lid}"/*/state; do
    case "$(cat "$lid" 2>/dev/null)" in
        *closed*) log "outputs: $outputs - lid closed; nothing changed"; exit 0 ;;
    esac
done

# Hyprland 0.57+ takes Lua over IPC (no `keyword`); older releases only `keyword`.
case "$(hyprctl eval 'return 1' 2>&1)" in
    *"unknown request"*|*"only supported with the lua"*) lua=0 ;;
    *) lua=1 ;;
esac

if [ "$lua" = 1 ]; then
    hyprctl eval "hl.dispatch(hl.dsp.focus({ monitor = \"$internal\" }))" >/dev/null 2>&1
    log "outputs: $outputs - focus on $internal"
else
    hyprctl dispatch focusmonitor "$internal" >/dev/null 2>&1
    log "outputs: $outputs - focus on $internal (Hyprland before 0.57)"
    exit 0
fi

# The focus is not enough (2026-11-22, the login on her vertical external): regreet goes fullscreen on the first screen
# by itself. In the test VM a monitor rule, the focus and the cursor on the target all left it there; moving its window
# put it on the target, still fullscreen. The move names regreet's window: the focus is on the panel by then, and a
# move of "the focused window" moved nothing (54 tries on a fresh boot). Every 0.25 s for at most 15 s, it is moved
# while it is elsewhere; done once it has been on the panel, fullscreen, for 1 s. In the background: regreet starts
# after this script returns.
target=$(hyprctl monitors 2>/dev/null | awk -v m="$internal" '$1 == "Monitor" && $2 == m { gsub(/[^0-9]/, "", $4); print $4 }')
[ -z "$target" ] && { log "no id for $internal; regreet not moved"; exit 0; }
(
    tries=0 moves=0 settled=0
    while [ "$tries" -lt 60 ] && [ "$settled" -lt 4 ]; do
        tries=$((tries + 1))
        sleep 0.25
        # "MONITOR FULLSCREEN" of regreet's window; its block lists monitor, then class, then fullscreen.
        state=$(hyprctl clients 2>/dev/null | awk '
            /^Window /                          { mon = ""; hit = 0 }
            /^[[:space:]]+monitor:/             { mon = $2 }
            /^[[:space:]]+class: apps\.regreet$/ { hit = 1 }
            hit && /^[[:space:]]+fullscreen:/   { print mon, $2; exit }')
        [ -z "$state" ] && continue
        if [ "${state% *}" = "$target" ]; then
            if [ "${state#* }" != 0 ]; then settled=$((settled + 1)); fi
        else
            settled=0 moves=$((moves + 1))
            hyprctl eval "hl.dispatch(hl.dsp.window.move({ monitor = \"$internal\", window = \"class:^(apps\\\\.regreet)\$\" }))" >/dev/null 2>&1
        fi
    done
    if [ "$settled" -ge 4 ]; then log "regreet on $internal (moved $moves times)"
    else log "regreet not settled on $internal after 15 s (moved $moves times, last seen: ${state:-not open})"; fi
) &
