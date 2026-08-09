#!/bin/bash
# Waybar composite battery — capacity + status + draw/intake wattage as
# text, current volume and screen brightness as tooltip. Replaces the
# standalone battery, pulseaudio, and backlight modules in one bubble.

CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/foxml-waybar"
mkdir -p "$CACHE_DIR"

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
# second state is the one worth alarming on. Enumerate supplies by
# their TYPE file rather than hardcoded names: the barrel adapter is
# "AC" on ThinkPads but ACAD/ADP1 elsewhere, and USB-C partners appear
# as per-connector ucsi psys (online flips only when the partner FEEDS
# us — powering a phone off the port doesn't trip it). Mains outranks
# USB when both report.
src=""
for p in /sys/class/power_supply/*/; do
    [[ "$(cat "$p/online" 2>/dev/null)" == "1" ]] || continue
    case "$(cat "$p/type" 2>/dev/null)" in
        Mains) src="AC adapter"; break ;;
        USB)   src="USB-C PD" ;;
    esac
done

# ── Draw / intake wattage (EMA-smoothed) ──────────────────────────
# power_now where the driver provides it; current×voltage fallback
# (µA·µV → µW) elsewhere. Instantaneous readings swing 2-3× tick to
# tick at a 1s interval, so smooth with an integer EMA (α=1/4) kept in
# the runtime cache — reset on status flips so a charge→discharge
# transition doesn't inherit a stale average. Sub-0.5W = threshold
# hold, not worth ink.
pw=$(cat "$bat/power_now" 2>/dev/null)
if [[ ! "$pw" =~ ^[0-9]+$ ]]; then
    cur=$(cat "$bat/current_now" 2>/dev/null || echo 0)
    vlt=$(cat "$bat/voltage_now" 2>/dev/null || echo 0)
    pw=$(( cur * vlt / 1000000 ))
fi

EMA_F="$CACHE_DIR/battery_pw_ema"
ema="$pw"
if [[ -f "$EMA_F" ]]; then
    # ema first, status second: "Not charging" has a space, so status
    # must be the read's tail-swallowing last field
    read -r p_ema p_status < "$EMA_F"
    [[ "$p_status" == "$status" && "$p_ema" =~ ^[0-9]+$ ]] \
        && ema=$(( p_ema + (pw - p_ema) / 4 ))
fi
printf '%s %s' "$ema" "$status" > "$EMA_F"

watts=""
if (( ema > 500000 )); then
    w=$(( (ema + 500000) / 1000000 ))
    case "$status" in
        Charging)    watts=" +${w}W" ;;
        Discharging) watts=" -${w}W" ;;
    esac
fi

# ── Time remaining ────────────────────────────────────────────────
# energy_now/power → time-to-empty; (energy_full−energy_now)/power →
# time-to-full, on the SMOOTHED draw so the estimate doesn't swing
# with every scheduler burst. charge_* (µAh) batteries convert via
# voltage; absence degrades gracefully (tooltip omits the field).
en=$(cat "$bat/energy_now" 2>/dev/null)
ef=$(cat "$bat/energy_full" 2>/dev/null)
if [[ ! "$en" =~ ^[0-9]+$ ]]; then
    cn=$(cat "$bat/charge_now" 2>/dev/null)
    cf=$(cat "$bat/charge_full" 2>/dev/null)
    vlt=${vlt:-$(cat "$bat/voltage_now" 2>/dev/null || echo 0)}
    [[ "$cn" =~ ^[0-9]+$ ]] && en=$(( cn * vlt / 1000000 ))
    [[ "$cf" =~ ^[0-9]+$ ]] && ef=$(( cf * vlt / 1000000 ))
fi
eta=""
if [[ "$en" =~ ^[0-9]+$ ]] && (( ema > 500000 )); then
    mins=""
    case "$status" in
        Discharging) mins=$(( en * 60 / ema )) ;;
        Charging)
            [[ "$ef" =~ ^[0-9]+$ ]] && (( ef > en )) && mins=$(( (ef - en) * 60 / ema ))
            ;;
    esac
    [[ -n "$mins" ]] && eta=$(printf '~%dh %02dm' $(( mins / 60 )) $(( mins % 60 )))
fi

# ── Icon + state class ────────────────────────────────────────────
# Discharge icons step every 20% so all six get used. Charging
# animates a fill from the current level up to full, phased off the
# epoch second — the script is stateless (waybar re-execs it every
# interval), so wall clock is the only counter available.
chg_icons=(󰢜 󰂆 󰂇 󰂈 󰢝 󰂉 󰢞 󰂊 󰂋 󰂅)
icon="󰁹"
class=""
DRAIN_F="$CACHE_DIR/battery_drain_ticks"
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
        # the source) alarms — but only after 3 consecutive ticks,
        # because on plug-in the EC's status lags `online` by a second
        # or two and the red state would otherwise flash on every
        # connect.
        if [[ -n "$src" && "$status" == "Discharging" ]]; then
            n=$(cat "$DRAIN_F" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0
            n=$(( n + 1 )); printf '%s' "$n" > "$DRAIN_F"
        else
            n=0; printf '0' > "$DRAIN_F"
        fi
        if   (( cap < 10 )); then class="critical"
        elif [[ -n "$src" && "$status" == "Discharging" ]] && (( n >= 3 )); then
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
    [[ "$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null)" == *yes* ]] \
        && vol="muted ($vol)"
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

# Charge-threshold context: threshold-capable firmware (ThinkPads et
# al.) holds at charge_control_end_threshold on purpose — say so, so
# "Not charging at 80%" reads as policy, not a broken charger.
power_line="${src:-battery}"
thr=$(cat "$bat/charge_control_end_threshold" 2>/dev/null)
if [[ -n "$src" && "$status" == "Not charging" && "$thr" =~ ^[0-9]+$ ]] \
    && (( thr < 100 && cap >= thr - 5 )); then
    power_line="$src — holding at ${thr}% (charge threshold)"
fi

tooltip="Battery: ${cap}% (${status}${watts:+,$watts}${eta:+, $eta})\\n   Power: ${power_line}\\n  Volume: ${vol}\\n  Brightness: ${bright}"

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
