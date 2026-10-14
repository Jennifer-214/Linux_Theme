#!/usr/bin/env bash
# hw_overwatch.sh — waybar custom module: anomaly detection.
#
# Polled by waybar at a slow interval (15s). Each tick:
#   - Checks for sudden GPU usage spikes by unknown processes.
#   - Checks for newly-listening sockets on non-localhost ports (a
#     process that wasn't accepting connections last poll suddenly is).
#   - Checks for new root processes (uptime < poll interval).
#   - Aggregates findings into a one-line waybar status.
#
# On anomaly, the module's `class` is set to "alert" so the bar styles
# it in red, AND a notify-send fires (rate-limited to one per minute).
# Steady state, status reads "ok" in a dim color.
#
# State is kept in $XDG_RUNTIME_DIR/foxml-overwatch — a small JSON
# snapshot of the previous tick used for diffing.

set -u

STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE="$STATE_DIR/foxml-overwatch.state"
LAST_ALERT="$STATE_DIR/foxml-overwatch.last-alert"
ALERT_COOLDOWN=60  # min seconds between notify-send firings

emit() {
    local text="$1" tooltip="$2" class="${3:-ok}"
    printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' \
        "$(printf '%s' "$text" | head -c 80)" \
        "$(printf '%s' "$tooltip" | head -c 400 | tr '\n' ' ')" \
        "$class"
}

# ─── GPU: NVIDIA pegged by unknown process ────────────────────────
gpu_findings=""
if command -v nvidia-smi >/dev/null 2>&1; then
    # Returns "pid,process_name,used_memory" CSV per process holding the
    # GPU. Anything outside the known-ok allow-list at >1GB VRAM is a
    # flag candidate (cryptominer / surprise ML workload).
    while IFS=',' read -r pid pname used; do
        pname="${pname// /}"; pname="${pname##*/}"; used="${used// /}"   # a path on some drivers
        [[ -z "$pid" || "$used" == "0" ]] && continue
        case "$pname" in
            llama-server)                             continue ;;   # the local models (fox-llm-serve)
            firefox|chromium|chrome|kitty|hyprland)   continue ;;
            python|python3|node|java)                 continue ;;
            *) gpu_findings+="GPU: $pname ($used MiB); " ;;
        esac
    done < <(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null)
fi

# ─── Network: new listening sockets vs last tick ──────────────────
net_findings=""
if command -v ss >/dev/null 2>&1; then
    # Capture current listening sockets, scoped to LISTEN state, non-
    # loopback addresses. Format: addr:port -> process. Compare to
    # last tick's snapshot.
    current_listen=$(ss -tlnp 2>/dev/null \
        | awk 'NR>1 && $4 !~ /^127\./ && $4 !~ /^\[::1\]/ && $4 !~ /^\*:/ {
                  match($0, /users:\(\("[^"]+"/)
                  proc=substr($0, RSTART+8, RLENGTH-9)
                  print $4 "\t" proc
              }' \
        | sort -u)
    prev_listen=""
    if [[ -f "$STATE" ]]; then
        # The persistence format joins lines with `|` so the snapshot
        # fits on a single line. We have to split it back into newlines
        # AND sort it the same way current_listen is sorted — otherwise
        # `comm -23` sees one mega-line vs many lines and every current
        # entry looks "new" on every tick, spamming notifications.
        prev_listen=$(awk '/^LISTEN:/{print substr($0,8)}' "$STATE" \
                      | tr '|' '\n' | grep -v '^$' | sort -u)
    fi
    new_lines=$(comm -23 <(echo "$current_listen") <(echo "$prev_listen") 2>/dev/null)
    if [[ -n "$new_lines" ]]; then
        net_findings="new listener(s): $(echo "$new_lines" | head -3 | tr '\n' ',' | sed 's/,$//')"
    fi
fi

# ─── Processes: brand-new root processes ──────────────────────────
# Root processes that have been alive < 30 seconds AND aren't on the
# allow-list of expected short-lived helpers. ps `etime` is "[[DD-]hh:]mm:ss".
#
# Spoofing note: process comm names CAN be set arbitrarily via
# prctl(PR_SET_NAME, ...) or argv[0], so a name-only allowlist is
# spoofable. We split the check in two:
#
#   1. Kernel-thread allowlist (kworker/*, ksoftirqd/*, rcu_*, etc.) —
#      require BOTH the comm to match AND the process to actually be
#      a kernel thread (PPid=2 = kthreadd, no /proc/<pid>/exe). A
#      userspace process renamed "kworker/5:1" fails both checks and
#      stays flagged.
#
#   2. Userspace-daemon allowlist (sudo, polkitd, sshd, cron, etc.) —
#      name match is enough. Spoofing one of these names from a
#      malicious userspace process doesn't grant privilege — real sudo
#      is suid'd, fake "sudo" can't elevate. So name alone is fine.
proc_findings=""
new_roots_with_pid=$(ps -eo pid,euser,etime,comm 2>/dev/null \
    | awk '$2=="root" {
              t=$3
              n=split(t, a, /[-:]/)
              if (n==2 && a[1]+0 == 0 && a[2]+0 < 30) print $1 "\t" $4
           }')

_is_kernel_thread() {
    # Returns 0 if PID is a real kernel thread.
    local pid="$1"
    [[ -d "/proc/$pid" ]] || return 1
    # Kernel threads have no executable mapped.
    [[ -L "/proc/$pid/exe" && -e "/proc/$pid/exe" ]] && return 1
    # Belt + suspenders: parent is kthreadd (PID 2). User-spawned fakes
    # would have a different PPid (their spawning shell, init system,
    # etc.) so this catches anything that slipped past the exe check.
    local ppid
    ppid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    [[ "$ppid" == "2" ]]
}

_kernel_thread_pattern='^(kworker(/[^[:space:]]*)?|kdmflush[^[:space:]]*|kthreadd|rcu_[^[:space:]]*|ksoftirqd[^[:space:]]*|migration[^[:space:]]*|irq/[^[:space:]]*|kcompactd[^[:space:]]*|khugepaged|writeback|kswapd[^[:space:]]*)$'
_userspace_allow_pattern='^(sudo|polkitd|sshd|cron|systemd[^[:space:]]*|udevd|udevadm)$'

filtered_roots=""
while IFS=$'\t' read -r pid comm; do
    [[ -z "$pid" || -z "$comm" ]] && continue

    # Kernel-thread allow: name pattern AND actually a kernel thread.
    if [[ "$comm" =~ $_kernel_thread_pattern ]]; then
        if _is_kernel_thread "$pid"; then
            continue   # genuinely kernel — allow
        else
            # Name matches a kernel pattern but it's a userspace impostor!
            # Flag with extra hostility so the operator notices.
            filtered_roots+="${comm}[SPOOFED] "
            continue
        fi
    fi

    # Userspace allow: name alone is fine here.
    if [[ "$comm" =~ $_userspace_allow_pattern ]]; then
        continue
    fi

    filtered_roots+="$comm "
done <<<"$new_roots_with_pid"

new_roots=$(echo "$filtered_roots" | tr ' ' '\n' | sort -u | grep -v '^$')
if [[ -n "$new_roots" ]]; then
    proc_findings="new root proc(s): $(echo "$new_roots" | head -3 | tr '\n' ',' | sed 's/,$//')"
fi

# ─── Shared ledger: tripwire / bouncer / fail2ban / dispatch ──────
# Pull any alert entries written by fox-dispatch in the last 5 minutes
# (matches our notify-send cooldown window). Format: epoch\tsource\tmsg.
ledger_findings=""
LEDGER="${XDG_DATA_HOME:-$HOME/.local/share}/foxml/alerts.log"
LEDGER_WINDOW=300   # seconds — anything older is stale
if [[ -f "$LEDGER" ]]; then
    cutoff=$(( $(date +%s) - LEDGER_WINDOW ))
    while IFS=$'\t' read -r ts source msg; do
        [[ -z "$ts" ]] && continue
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        if (( ts >= cutoff )); then
            # Skip overwatch's own entries so the bar doesn't echo itself.
            [[ "$source" == "overwatch anomaly" ]] && continue
            ledger_findings+="${source}: ${msg}; "
        fi
    done < "$LEDGER"
fi

# ─── Compose ──────────────────────────────────────────────────────
combined=""
[[ -n "$gpu_findings"  ]] && combined+="$gpu_findings"
[[ -n "$net_findings"  ]] && combined+="$net_findings; "
[[ -n "$proc_findings" ]] && combined+="$proc_findings"
[[ -n "$ledger_findings" ]] && combined+="$ledger_findings"

# Persist current listen state for next tick's diff.
{
    printf 'LISTEN:%s\n' "$(echo "$current_listen" | tr '\n' '|')"
} > "$STATE"

if [[ -n "$combined" ]]; then
    # Rate-limit notify-send AND fox-dispatch so a sustained anomaly
    # doesn't spam either channel. Same cooldown window for both — if
    # we just sent a local notification, the phone alert is also stale.
    last=0
    [[ -f "$LAST_ALERT" ]] && last=$(cat "$LAST_ALERT" 2>/dev/null || echo 0)
    now=$(date +%s)
    if (( now - last >= ALERT_COOLDOWN )); then
        echo "$now" > "$LAST_ALERT"
        notify-send -u critical -t 8000 -a "overwatch" \
            "Hardware anomaly" "$combined" 2>/dev/null || true
        # Phone alert via fox-dispatch when configured. Silent failure if
        # the webhook config isn't present — local notify-send already
        # covered the case.
        if command -v fox-dispatch >/dev/null 2>&1 \
           && [[ -f "$HOME/.config/foxml/dispatch.conf" ]]; then
            fox-dispatch "overwatch anomaly" "$combined" >/dev/null 2>&1 &
            disown
        fi
    fi
    emit "⚠ overwatch" "$combined" "alert"
else
    emit "ok" "Hardware overwatch: nothing flagged in this tick" "ok"
fi
