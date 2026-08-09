#!/bin/bash
# Waybar CPU module — usage % (1s sample) + package temp via coretemp.
# Resolved by hwmon "name", so it survives hwmonN renumbering across boots.

read_cpu() {
    local _cpu user nice system idle iowait irq softirq steal _rest
    read -r _cpu user nice system idle iowait irq softirq steal _rest < /proc/stat
    local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    local used=$((total - idle - iowait))
    echo "$used $total"
}

read -r u1 t1 < <(read_cpu)
sleep 1
read -r u2 t2 < <(read_cpu)

dt=$((t2 - t1))
if (( dt > 0 )); then
    usage=$(( 100 * (u2 - u1) / dt ))
else
    usage=0
fi

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
