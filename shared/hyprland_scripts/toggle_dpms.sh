#!/usr/bin/env bash
# Stay awake: pause idle auto-lock for a while, or let it resume.
#
# (The name is historical; this never switched displays off.) Auto-lock itself is
# opt-in, owned by `desk-lock --idle on|off`, which enables power-state-watcher —
# the supervisor that runs hypridle. This only pauses that: the pause file makes
# the watcher leave hypridle stopped, and resuming hands back to the watcher, so
# it can never switch on auto-lock that was left off. The drawer's Stay awake
# row runs this script.
set -u

STATE_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypridle_paused"
SVC=power-state-watcher.service

autolock_on() { systemctl --user is-enabled --quiet "$SVC" 2>/dev/null; }
say() { notify-send -h string:x-canonical-private-synchronous:stay-awake "$1" "$2" 2>/dev/null || true; }

if [[ -f "$STATE_FILE" ]]; then
    rm -f "$STATE_FILE"
    if autolock_on; then
        # A restart re-applies the AC/battery profile and starts hypridle at once.
        systemctl --user restart "$SVC" 2>/dev/null || true
        say "auto-lock is back" "the screen will dim and lock when idle again"
    else
        say "awake, as before" "auto-lock is off, so the screen stays awake anyway"
    fi
    exit 0
fi

if ! autolock_on; then
    say "already awake" "auto-lock is off · desk-lock --idle on turns it on"
    exit 0
fi

( umask 077; : > "$STATE_FILE" )
pkill -x hypridle 2>/dev/null || true
say "staying awake" "the screen won't dim or lock on its own until you turn this off"
