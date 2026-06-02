#!/usr/bin/env bash
# Watches AC/battery state and runs hypridle with the right config.
# Replaces a static `exec-once = hypridle` so DPMS timing tightens on battery.
set -euo pipefail

HYPR_DIR="${HOME}/.config/hypr"
LIVE_CONF="${HYPR_DIR}/hypridle.conf"
AC_CONF="${HYPR_DIR}/hypridle-ac.conf"
BAT_CONF="${HYPR_DIR}/hypridle-battery.conf"

# This unit is WantedBy=default.target, so systemd starts it at login — before
# env-init.sh runs `systemctl --user import-environment`. Our frozen env can
# therefore lack the Wayland vars, and any hypridle we spawn then exits
# instantly (silently disabling auto-lock). Resolve them from the runtime dir:
# WAYLAND_DISPLAY for hypridle's idle protocol, HYPRLAND_INSTANCE_SIGNATURE for
# the hyprctl dpms calls its listeners run.
ensure_wayland_env() {
    local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" s b sig
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        for s in "$rt"/wayland-*; do
            b="${s##*/}"
            if [[ -S "$s" && "$b" =~ ^wayland-[0-9]+$ ]]; then
                export WAYLAND_DISPLAY="$b"; break
            fi
        done
    fi
    if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        sig="$(ls -1t "$rt/hypr" 2>/dev/null | head -1 || true)"
        [[ -n "$sig" ]] && export HYPRLAND_INSTANCE_SIGNATURE="$sig"
    fi
}

current_state() {
    local online
    for f in /sys/class/power_supply/A{C,DP}*/online; do
        [[ -r "$f" ]] || continue
        online="$(cat "$f")"
        [[ "$online" == "1" ]] && { echo ac; return; }
    done
    echo battery
}

apply_state() {
    local state="$1" src
    case "$state" in
        ac)      src="$AC_CONF"  ;;
        battery) src="$BAT_CONF" ;;
        *)       return 1        ;;
    esac
    [[ -f "$src" ]] || { echo "missing $src" >&2; return 1; }
    cp "$src" "$LIVE_CONF"
    # Make sure hypridle can reach the compositor. If the socket isn't up yet
    # (we started before Hyprland), defer silently — the supervisor loop will
    # retry next tick rather than logging a spurious "failed to start".
    ensure_wayland_env
    [[ -n "${WAYLAND_DISPLAY:-}" ]] || return 0
    # Wait for hypridle to actually exit before launching a new one.
    # The old `pkill + sleep 0.2 + setsid hypridle` raced — under load
    # hypridle held its socket >200ms and the new instance failed to
    # bind, leaving the user with NO auto-lock/dpms — a security gap.
    # Poll the PID, then SIGKILL as a fallback before launching.
    if pgrep -x hypridle >/dev/null 2>&1; then
        pkill -x hypridle 2>/dev/null || true
        for _ in $(seq 1 30); do
            pgrep -x hypridle >/dev/null 2>&1 || break
            sleep 0.1
        done
        # Still around after 3s? Force it.
        pgrep -x hypridle >/dev/null 2>&1 && pkill -KILL -x hypridle 2>/dev/null
        # Small breather for any leftover socket cleanup.
        sleep 0.1
    fi
    setsid hypridle >/dev/null 2>&1 < /dev/null &
    disown
    # Sanity-check the new instance actually came up; if it didn't, log
    # loudly so the user notices instead of silently losing auto-lock.
    sleep 0.3
    if ! pgrep -x hypridle >/dev/null 2>&1; then
        echo "! hypridle failed to start after $state profile swap — auto-lock disabled" >&2
        notify-send -u critical -t 5000 "Power state" \
            "hypridle failed to restart — auto-lock OFF" 2>/dev/null || true
        return 1
    fi
    echo "hypridle profile: $state"
}

trap 'pkill -x hypridle 2>/dev/null || true; exit 0' TERM INT

last=""
while :; do
    now="$(current_state)"
    # Re-apply on a power-state change OR whenever hypridle isn't running. The
    # latter turns this from a transition-only config-swapper into a supervisor:
    # a hypridle that dies, or never came up because we beat the compositor to
    # login, is restarted within one tick instead of leaving auto-lock off until
    # the next AC/battery flip.
    if [[ "$now" != "$last" ]] || ! pgrep -x hypridle >/dev/null 2>&1; then
        apply_state "$now" || true
        last="$now"
    fi
    sleep 30
done
