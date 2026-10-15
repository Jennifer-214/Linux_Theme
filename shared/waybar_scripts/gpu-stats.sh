#!/bin/bash
# Waybar GPU module — NVIDIA temp + utilization, mirrors cpu.sh's output shape.
# Optimus-aware: skips nvidia-smi when the dGPU is runtime-suspended so polling
# doesn't keep it awake and burn battery. Emits a graceful empty/neutral text
# on absence or driver error so the bar never breaks.

ICON='󰢮'

# Locate an NVIDIA display-class PCI device (vendor 0x10de, class 0x03xx).
gpu_path=""
for dev in /sys/bus/pci/devices/*/; do
    [[ "$(cat "$dev/vendor" 2>/dev/null)" == "0x10de" ]] || continue
    [[ "$(cat "$dev/class" 2>/dev/null)" == 0x03* ]] || continue
    gpu_path="$dev"
    break
done

if [[ -z "$gpu_path" ]] || ! command -v nvidia-smi >/dev/null 2>&1; then
    echo '{"text":""}'
    exit 0
fi

# dGPU runtime-suspended — report idle without waking it.
state=$(cat "${gpu_path}power/runtime_status" 2>/dev/null || echo unknown)
if [[ "$state" != "active" ]]; then
    printf '{"text":"%s idle","tooltip":"GPU idle (suspended)","class":"idle"}\n' "$ICON"
    exit 0
fi

# NVIDIA updated without a reboot: nvidia-smi can only fail (each call a kernel log entry) — say "reboot" instead,
# without asking it (fox-nvidia-state asks once per boot or update; shared with the other GPU modules).
read -r nv_state nv_mod nv_lib < <("${FOX_NVIDIA_STATE:-$HOME/.local/bin/fox-nvidia-state}" 2>/dev/null)
if [[ ${nv_state:-} == mismatch ]]; then
    printf '{"text":"%s ⚠ reboot","tooltip":"NVIDIA was updated without a reboot (kernel module %s, driver library %s): GPU tools fail, and windows opened since then draw on the CPU. Reboot to load the new driver.","class":"warning"}\n' "$ICON" "$nv_mod" "$nv_lib"
    exit 0
fi

# Single nvidia-smi call. On hybrid setups it can fail with a driver-comms error
# and print that to stdout, not stderr — so validate exit code AND numeric values.
output=$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu --format=csv,noheader,nounits 2>/dev/null)
temp=""
util=""
if (( $? == 0 )); then
    read -r temp util < <(printf '%s\n' "$output" | head -1 | tr -d ' ' | tr ',' ' ')
fi

if [[ "$temp" =~ ^[0-9]+$ && "$util" =~ ^[0-9]+$ ]]; then
    printf '{"text":"%s %s%% %s°","tooltip":"GPU: %s%% %s°C"}\n' "$ICON" "$util" "$temp" "$util" "$temp"
else
    printf '{"text":"%s on","tooltip":"GPU active (stats unavailable)","class":"idle"}\n' "$ICON"
fi
