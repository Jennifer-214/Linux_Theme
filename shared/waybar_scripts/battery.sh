#!/bin/bash
# Waybar composite battery — capacity + status + draw/intake wattage as
# text, current volume and screen brightness as tooltip. Replaces the
# standalone battery, pulseaudio, and backlight modules in one bubble.

# ── Battery ───────────────────────────────────────────────────────
bat=""
for p in /sys/class/power_supply/BAT0 /sys/class/power_supply/BAT1; do
    [[ -d "$p" ]] && { bat="$p"; break; }
done
if [[ -z "$bat" ]]; then
    echo '{"text":""}'
    exit 0
fi

cap=$(cat "$bat/capacity" 2>/dev/null || echo 0)
status=$(cat "$bat/status" 2>/dev/null || echo Unknown)

# ── External power presence ───────────────────────────────────────
# BAT status alone can't tell "on battery" from "charger attached but
# not delivering" (weak adapter / failed PD handshake) — and that
# second state is the one worth alarming on. Barrel adapters report
# at AC/online; USB-C sources report per-connector via ucsi-source-psy
# (online=1 only when the partner FEEDS us — powering a phone off the
# port doesn't trip it).
src=""
if [[ "$(cat /sys/class/power_supply/AC/online 2>/dev/null)" == "1" ]]; then
    src="barrel AC"
else
    for u in /sys/class/power_supply/ucsi-source-psy-*/online; do
        [[ "$(cat "$u" 2>/dev/null)" == "1" ]] && { src="USB-C PD"; break; }
    done
fi

# ── Draw / intake wattage ─────────────────────────────────────────
# power_now where the driver provides it; current×voltage fallback
# (µA·µV → µW) elsewhere. Sub-0.5W = threshold hold, not worth ink.
pw=$(cat "$bat/power_now" 2>/dev/null)
if [[ ! "$pw" =~ ^[0-9]+$ ]]; then
    cur=$(cat "$bat/current_now" 2>/dev/null || echo 0)
    vlt=$(cat "$bat/voltage_now" 2>/dev/null || echo 0)
    pw=$(( cur * vlt / 1000000 ))
fi
watts=""
if (( pw > 500000 )); then
    w=$(( (pw + 500000) / 1000000 ))
    case "$status" in
        Charging)    watts=" +${w}W" ;;
        Discharging) watts=" -${w}W" ;;
    esac
fi

# ── Icon + state class ────────────────────────────────────────────
# Discharge icons step every 20% so all six get used. Charging
# animates a fill from the current level up to full, phased off the
# epoch second — the script is stateless (waybar re-execs it every
# interval), so wall clock is the only counter available.
chg_icons=(󰢜 󰂆 󰂇 󰂈 󰢝 󰂉 󰢞 󰂊 󰂋 󰂅)
icon="󰁹"
class=""
case "$status" in
    Full) icon="󰂅"; class="charging" ;;
    Charging)
        base=$(( cap / 10 )); (( base > 9 )) && base=9
        phase=$(( $(date +%s) % (10 - base) ))
        icon="${chg_icons[base + phase]}"
        class="charging"
        ;;
    *)
        if   (( cap >= 90 )); then icon="󰁹"
        elif (( cap >= 70 )); then icon="󰂀"
        elif (( cap >= 50 )); then icon="󰁾"
        elif (( cap >= 30 )); then icon="󰁼"
        elif (( cap >= 10 )); then icon="󰁺"
        else                       icon="󰂃"
        fi
        # Plug present but not charging: EC holding at threshold is
        # calm; plugged-yet-DRAINING (failed handshake or out-drawing
        # the source) gets the loudest non-critical state.
        if   (( cap < 10 )); then class="critical"
        elif [[ -n "$src" && "$status" == "Discharging" ]]; then
            icon="󰚥"; class="plugged-drain"
        elif [[ -n "$src" ]]; then
            icon="󰚥"; class="plugged"
        elif (( cap < 25 )); then class="warning"
        fi
        ;;
esac

text="$icon $cap%$watts"

# ── Volume ────────────────────────────────────────────────────────
vol="?"
if command -v pactl >/dev/null 2>&1; then
    vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null \
            | grep -oE '[0-9]+%' | head -1)
    [[ -z "$vol" ]] && vol="?"
fi

# ── Brightness ────────────────────────────────────────────────────
bright="?"
if command -v brightnessctl >/dev/null 2>&1; then
    cur=$(brightnessctl g 2>/dev/null)
    max=$(brightnessctl m 2>/dev/null)
    if [[ "$cur" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] && (( max > 0 )); then
        bright="$(( cur * 100 / max ))%"
    fi
fi

tooltip="Battery: ${cap}% (${status}${watts:+,$watts})\\n   Power: ${src:-battery}\\n  Volume: ${vol}\\n  Brightness: ${bright}"

# Emit a class so the CSS can re-apply the old battery state colors
# (charging=gold, plugged=lavender, plugged-drain=red pulse,
# warning=yellow, critical=red). Waybar reserves the 'class' field on
# JSON-mode custom modules for exactly this. Field is only included
# when there's a state — empty class strings tickle a selector edge
# case in GTK's CSS parser.
if [[ -n "$class" ]]; then
    printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tooltip" "$class"
else
    printf '{"text":"%s","tooltip":"%s"}\n' "$text" "$tooltip"
fi
