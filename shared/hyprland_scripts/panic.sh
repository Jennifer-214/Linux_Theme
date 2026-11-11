#!/bin/bash
# Lockdown — wipe clipboard, close Firefox session, stop editors and engines, lock.
# Bound to ALT+CTRL+SHIFT+K (three modifiers, so it is never one slip from a
# focus key). There is no confirmation: it shreds clipboard history and the
# Firefox session, kill -9s every nvim under ~/code, stops the trading engines,
# then locks. For a plain lock use ALT+CTRL+L.
#
# Process kills are scoped by exact binary name (-x) and per-pid cwd
# inspection so we don't nuke unrelated processes that happen to share
# a name (e.g. someone else's `engine` binary, or an nvim editing a
# poem). Generic substring pkill is intentionally avoided.

set -u

# 1. Clipboard wipe — best-effort across the common providers.
#
# Order matters here. cliphist uses bbolt for its on-disk store
# (~/.cache/cliphist/db); bbolt holds an exclusive file lock while
# the cliphist daemon is alive, so:
#   - rm on a locked file may fail silently
#   - even if rm succeeds, the running daemon's in-memory cache will
#     write back to a freshly-recreated db on the next clipboard event,
#     restoring the very entries we're trying to wipe.
#
# Correct sequence:
#   a) cliphist wipe        (clear daemon's in-memory state via API)
#   b) kill the wl-paste/cliphist daemons (release the bbolt lock + stop
#      future writes)
#   c) shred + rm the db file (now safely lockless; shred overwrites
#      blocks before unlink so the data isn't recoverable from the
#      filesystem)
#   d) wl-copy clear (covers the live Wayland clipboard buffer)
if command -v cliphist >/dev/null 2>&1; then
    cliphist wipe 2>/dev/null || true
fi
# Kill any cliphist-feeding wl-paste watchers AND the cliphist daemon
# itself. Without this, the db re-materialises seconds later.
pkill -9 -x cliphist 2>/dev/null || true
pkill -9 -f 'wl-paste --type (text|image) --watch cliphist' 2>/dev/null || true
# Wait for the bbolt lock to release; 1s is overkill but harmless.
for _ in 1 2 3 4 5; do
    fuser "$HOME/.cache/cliphist/db" >/dev/null 2>&1 || break
    sleep 0.1
done
db="$HOME/.cache/cliphist/db"
if [[ -f "$db" ]]; then
    if command -v shred >/dev/null 2>&1; then
        shred -uz "$db" 2>/dev/null || rm -f "$db" 2>/dev/null || true
    else
        rm -f "$db" 2>/dev/null || true
    fi
fi
if command -v wl-copy >/dev/null 2>&1; then
    wl-copy --clear 2>/dev/null || true
    wl-copy --primary --clear 2>/dev/null || true
fi

# 2. Close sensitive UI, including a pending password selection.
quickshell -c foxml ipc call drawer close >/dev/null 2>&1 || true
# Keep covering old manually launched pickers while legacy packages remain.
pkill -9 -x rofi      2>/dev/null || true
pkill -9 -x rofi-pass 2>/dev/null || true

# 2a. Firefox session-state wipe. Closing the browser isn't enough —
# arkenfox + most setups have "restore previous session" on by default,
# so reopening Firefox would put you right back into Gmail / GitHub /
# etc. Stop Firefox cleanly, then shred the sessionstore files so a
# fresh launch starts logged out.
if pgrep -x firefox >/dev/null 2>&1; then
    pkill -SIGTERM -x firefox 2>/dev/null || true
    # Give Firefox up to 3s to flush + exit cleanly; SIGKILL otherwise.
    for _ in 1 2 3 4 5 6; do
        pgrep -x firefox >/dev/null 2>&1 || break
        sleep 0.5
    done
    pgrep -x firefox >/dev/null 2>&1 && pkill -KILL -x firefox 2>/dev/null
fi
# Shred sessionstore + recovery files across all profiles.
for profile in "$HOME/.mozilla/firefox/"*.default* "$HOME/.mozilla/firefox/"*.default-release; do
    [[ -d "$profile" ]] || continue
    for f in \
        "$profile/sessionstore.jsonlz4" \
        "$profile/sessionstore-backups/recovery.jsonlz4" \
        "$profile/sessionstore-backups/recovery.baklz4" \
        "$profile/sessionstore-backups/previous.jsonlz4"; do
        [[ -f "$f" ]] || continue
        if command -v shred >/dev/null 2>&1; then
            shred -uz "$f" 2>/dev/null || rm -f "$f" 2>/dev/null
        else
            rm -f "$f" 2>/dev/null
        fi
    done
done

# 3. nvim: only kill instances whose cwd is under $HOME/code (where
#    Linux_Theme projects live). A bare `pkill nvim` would kill an unrelated
#    nvim session the user has open elsewhere (notes, journal, etc.)
#    which is way too aggressive for a panic button.
for pid in $(pgrep -x nvim 2>/dev/null); do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    [[ "$cwd" == "$HOME/code/"* ]] && kill -9 "$pid" 2>/dev/null || true
done

# 4. Stop trading engines by exact binary name. SIGINT first for a
#    clean P&L flush, then SIGKILL after a beat if anything's hung.
for bin in FoxML_Trader FoxML_Trader_v2 tick_trader; do
    pkill -SIGINT -x "$bin" 2>/dev/null || true
done
sleep 1
for bin in FoxML_Trader FoxML_Trader_v2 tick_trader; do
    pkill -9 -x "$bin" 2>/dev/null || true
done

# 5. Notify briefly before locking. The lock screen overlays this
#    quickly anyway, but notify-send fires the bell sound so the user
#    knows the lockdown actually ran.
notify-send "locking down." "clipboard wiped, firefox session closed, editors and engines stopped" 2>/dev/null || true

# Phone alert via desk-dispatch (no-op silently if webhook isn't
# configured). Background + disown so the lock fires immediately;
# dispatch finishes in the background after we're locked.
if command -v desk-dispatch >/dev/null 2>&1; then
    (desk-dispatch "lockdown" "lockdown ran on $(hostname) at $(date -Iseconds)" >/dev/null 2>&1) &
    disown || true
fi

# 6. Lock. Prefer desk-lock (dbus + awww sanity check) when present.
if command -v desk-lock >/dev/null 2>&1; then
    exec desk-lock
elif [[ -x "$HOME/.config/hypr/scripts/lock.sh" ]]; then
    exec "$HOME/.config/hypr/scripts/lock.sh"
else
    exec hyprlock
fi
