#!/bin/bash
# Waybar System Health module
# Only appears when resources are heavily used

# Thresholds
CPU_THRESHOLD=80
RAM_THRESHOLD=85
TEMP_THRESHOLD=80

# ── CPU usage (delta since last tick) ─────────────────────────────
# /proc/stat counters are cumulative since boot — a single read gives
# the boot-long average, which can't see a spike happening NOW. Keep
# the previous sample in the runtime cache (cleared each boot) and
# diff against it; first tick after boot reads 0 and warms the cache.
CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/foxml-waybar"
mkdir -p "$CACHE_DIR"
PREV="$CACHE_DIR/health_cpu_prev"

read -r _cpu user nice system idle iowait irq softirq steal _rest < /proc/stat
total=$((user + nice + system + idle + iowait + irq + softirq + steal))
used=$((total - idle - iowait))

cpu_int=0
if [[ -f "$PREV" ]]; then
    read -r p_used p_total < "$PREV"
    if [[ "$p_used" =~ ^[0-9]+$ && "$p_total" =~ ^[0-9]+$ ]]; then
        dt=$(( total - p_total ))
        (( dt > 0 )) && cpu_int=$(( 100 * (used - p_used) / dt ))
        (( cpu_int < 0 )) && cpu_int=0
    fi
fi
printf '%s %s' "$used" "$total" > "$PREV"

# Get RAM Usage
ram_usage=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
ram_int=${ram_usage%.*}

# ── Package temp via hwmon coretemp ───────────────────────────────
# Resolved by hwmon "name" (survives hwmonN renumbering), same as
# cpu.sh; the old `sensors` text parse needed lm_sensors and broke
# whenever the output layout shifted.
temp_int=0
for d in /sys/class/hwmon/hwmon*/; do
    [[ "$(cat "$d/name" 2>/dev/null)" == "coretemp" ]] || continue
    raw=$(cat "$d/temp1_input" 2>/dev/null)
    [[ "$raw" =~ ^[0-9]+$ ]] && temp_int=$(( raw / 1000 ))
    break
done

# Build warnings
warnings=()
[[ $cpu_int -gt $CPU_THRESHOLD ]] && warnings+=("CPU: ${cpu_int}%")
[[ $ram_int -gt $RAM_THRESHOLD ]] && warnings+=("RAM: ${ram_int}%")
[[ $temp_int -gt $TEMP_THRESHOLD ]] && warnings+=("Temp: ${temp_int}°C")

if [[ ${#warnings[@]} -gt 0 ]]; then
    text="  HEALTH"
    tooltip="System Stress Detected:\\n"
    for w in "${warnings[@]}"; do
        tooltip+="  • $w\\n"
    done
    echo "{\"text\": \"$text\", \"tooltip\": \"$tooltip\", \"class\": \"critical\"}"
else
    echo ""
fi
