#!/bin/bash
# Waybar Security Overwatch
# Monitors firewall, sshd, and failed logins

warnings=()
class="normal"

# 1. Firewall (UFW)
if command -v ufw >/dev/null 2>&1; then
    if ! sudo ufw status | grep -q "Status: active"; then
        warnings+=("Firewall is DISABLED")
        class="critical"
    fi
else
    warnings+=("UFW is not installed")
    class="warning"
fi

# 2. SSH Root Login / Password Auth
# Check the hardening config we created
hard_conf="/etc/ssh/sshd_config.d/50-foxml-hardening.conf"
if [[ -f "$hard_conf" ]]; then
    if grep -q "PasswordAuthentication yes" "$hard_conf"; then
        warnings+=("SSH Passwords ENABLED")
        class="warning"
    fi
else
    warnings+=("SSH Hardening Missing")
    class="warning"
fi

# 3. Failed SSH Attempts (Fail2ban)
if systemctl is-active --quiet fail2ban; then
    # Count total banned IPs across all jails
    banned_count=$(sudo fail2ban-client status sshd 2>/dev/null | grep "Currently banned:" | awk '{print $4}')
    if [[ "$banned_count" -gt 0 ]]; then
        warnings+=("$banned_count IPs currently BANNED")
    fi
else
    warnings+=("Fail2ban is INACTIVE")
    [[ "$class" != "critical" ]] && class="warning"
fi

# 4. Time Sync (Chrony)
if systemctl is-active --quiet chronyd; then
    # Check if we are actually synced
    if ! chronyc tracking | grep -q "Leap status     : Normal"; then
        warnings+=("Time is UNSYNCED")
        [[ "$class" != "critical" ]] && class="warning"
    fi
else
    warnings+=("Chrony is INACTIVE")
    [[ "$class" != "critical" ]] && class="warning"
fi

# 5. Recent intrusion alerts (shared ledger — tripwire, bouncer,
# fail2ban hook, hw_overwatch all write here via desk-dispatch). Any
# entry inside the 5-minute window flips us to at-least-warning.
LEDGER="${XDG_DATA_HOME:-$HOME/.local/share}/foxml/alerts.log"
LEDGER_WINDOW=300
if [[ -f "$LEDGER" ]]; then
    cutoff=$(( $(date +%s) - LEDGER_WINDOW ))
    while IFS=$'\t' read -r ts source msg; do
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        if (( ts >= cutoff )); then
            warnings+=("recent: ${source}: ${msg}")
            # ban / USB-while-locked / tripwire are escalations — treat
            # as critical. Plain overwatch anomalies stay at warning.
            case "$source" in
                ssh-brute|*tripwire*|USB*locked*) class="critical" ;;
                *) [[ "$class" != "critical" ]] && class="warning" ;;
            esac
        fi
    done < "$LEDGER"
fi

if [[ ${#warnings[@]} -gt 0 ]]; then
    # Show different icons based on severity
    icon="󰀦"
    [[ "$class" == "critical" ]] && icon="󰀦"

    text="$icon SECURITY"
    tooltip="Security Overwatch:\\n"
    for w in "${warnings[@]}"; do
        tooltip+="  • $w\\n"
    done
    echo "{\"text\": \"$text\", \"tooltip\": \"$tooltip\", \"class\": \"$class\"}"
else
    # System is secure
    echo "{\"text\": \"󰒃\", \"tooltip\": \"Security Overwatch:\\n  • System is SECURE\", \"class\": \"secure\"}"
fi
