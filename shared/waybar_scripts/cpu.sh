#!/bin/bash
# Waybar CPU module — usage % (tick delta) + package temp via coretemp.
# Resolved by hwmon "name", so it survives hwmonN renumbering across boots.

# /proc/stat is cumulative since boot — diff against the runtime-cached
# previous sample instead of sleeping 1s mid-exec, so the module renders
# instantly and stops holding a process for a fifth of its 5s cycle.
# First tick after boot reads 0 and warms the cache.
CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/foxml-waybar"
mkdir -p "$CACHE_DIR"
PREV="$CACHE_DIR/cpu_prev"

read -r _cpu user nice system idle iowait irq softirq steal _rest < /proc/stat
total=$((user + nice + system + idle + iowait + irq + softirq + steal))
used=$((total - idle - iowait))

usage=0
if [[ -f "$PREV" ]]; then
    read -r p_used p_total < "$PREV"
    if [[ "$p_used" =~ ^[0-9]+$ && "$p_total" =~ ^[0-9]+$ ]]; then
        dt=$(( total - p_total ))
        (( dt > 0 )) && usage=$(( 100 * (used - p_used) / dt ))
        (( usage < 0 )) && usage=0
        (( usage > 100 )) && usage=100
    fi
fi
printf '%s %s' "$used" "$total" > "$PREV"

temp=""
for d in /sys/class/hwmon/hwmon*/; do
    [[ "$(cat "$d/name" 2>/dev/null)" == "coretemp" ]] || continue
    raw=$(cat "$d/temp1_input" 2>/dev/null)
    [[ -n "$raw" ]] && temp=$(( raw / 1000 ))
    break
done

# NO nvidia-smi here: GPU stats live in the GPU bubble (gpu-stats.sh),
# which skips the query while the dGPU is runtime-suspended. Querying
# from this module too woke the card every cycle and defeated that
# battery saving.

cls=""
if (( usage >= 90 )); then cls=',"class":"critical"'
elif (( usage >= 70 )); then cls=',"class":"warning"'
fi

tooltip="CPU: ${usage}% ${temp}°C"

if [[ -n "$temp" ]]; then
    printf '{"text":"󰻠 %s%% %s°","tooltip":"%s"%s}\n' "$usage" "$temp" "$tooltip" "$cls"
else
    printf '{"text":"󰻠 %s%%","tooltip":"%s"%s}\n' "$usage" "$tooltip" "$cls"
fi
