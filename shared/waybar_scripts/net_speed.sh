#!/bin/bash
# Network speed HUD for Waybar
# Monitors throughput for HFT DataStream awareness

INTERFACE=$(ip route | awk '/^default/ {print $5; exit}')
[[ -z "$INTERFACE" ]] && exit 0

# /proc/net/dev counters are cumulative — diff against the runtime-
# cached previous sample instead of sleeping 1s mid-exec, so the
# module renders instantly and stops holding a process for half its
# 2s cycle. First tick after boot shows 0 and warms the cache.
CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/foxml-waybar"
mkdir -p "$CACHE_DIR"
PREV="$CACHE_DIR/net_prev"

now=$(date +%s)
# exact-match the interface column ("wlan0:" must not match "wlan0mon:")
read -r RX TX < <(awk -v i="${INTERFACE}:" '$1==i {print $2, $10}' /proc/net/dev)
[[ "$RX" =~ ^[0-9]+$ && "$TX" =~ ^[0-9]+$ ]] || exit 0

RX_SPEED=0
TX_SPEED=0
if [[ -f "$PREV" ]]; then
    read -r p_ts p_if p_rx p_tx < "$PREV"
    # skip the delta on iface flips (wifi↔ethernet) and counter resets
    if [[ "$p_if" == "$INTERFACE" && "$p_ts" =~ ^[0-9]+$ \
          && "$p_rx" =~ ^[0-9]+$ && "$p_tx" =~ ^[0-9]+$ ]] \
        && (( now > p_ts && RX >= p_rx && TX >= p_tx )); then
        dt=$(( now - p_ts ))
        RX_SPEED=$(( (RX - p_rx) / dt / 1024 ))
        TX_SPEED=$(( (TX - p_tx) / dt / 1024 ))
    fi
fi
printf '%s %s %s %s' "$now" "$INTERFACE" "$RX" "$TX" > "$PREV"

# Formatter helper — pure bash, avoids a `bc` runtime dep
format_speed() {
    local speed=$1
    if (( speed > 1024 )); then
        # one decimal place via integer math: 12345 KB → 12.0 MB
        printf "%d.%d MB/s" $(( speed / 1024 )) $(( (speed * 10 / 1024) % 10 ))
    else
        echo "${speed} KB/s"
    fi
}

RX_F=$(format_speed $RX_SPEED)
TX_F=$(format_speed $TX_SPEED)

# Tooltip — interface plus SSID/signal when on a wireless link, since the
# standalone `network` module was retired into this bubble.
tooltip="Interface: $INTERFACE"
if [[ "$INTERFACE" == wl* ]] && command -v nmcli >/dev/null 2>&1; then
    # active wifi line is marked with '*' in column 1
    line=$(nmcli -t -f IN-USE,SSID,SIGNAL device wifi 2>/dev/null \
            | awk -F: '$1=="*"{print; exit}')
    if [[ -n "$line" ]]; then
        ssid=$(awk -F: '{print $2}' <<<"$line")
        signal=$(awk -F: '{print $3}' <<<"$line")
        # SSIDs are free text — strip the JSON-breaking chars
        ssid="${ssid//\"/}"
        ssid="${ssid//\\/}"
        [[ -n "$ssid" ]]   && tooltip+="\\n  SSID: $ssid"
        [[ -n "$signal" ]] && tooltip+="\\n  Signal: ${signal}%"
    fi
fi

printf '{"text":"󰇚 %s  󰕒 %s","tooltip":"%s"}\n' "$RX_F" "$TX_F" "$tooltip"
