#!/usr/bin/env bash
# foxml_sentry.sh — comprehensive waybar security widget.
#
# Single source of truth for the bar:
#   • baseline (--full installs this lot — should always be on)
#   • opt-in (user enables via fox <X> --setup — bonus protections)
#   • live alerts (shared ledger, last 5 min)
#
# Three output states:
#   ok       — class="ok"        active-protection count, peaceful
#   warning  — class="warning"   baseline drifted OR recent ledger entry
#   critical — class="critical"  hardening missing OR active intrusion
#
# Pairs with: fox sec / fox sec --live / fox arm --status — they are
# the deeper-detail views. The widget is the glance.

set -u

STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE="$STATE_DIR/foxml-sentry.state"
LEDGER="${XDG_DATA_HOME:-$HOME/.local/share}/foxml/alerts.log"
LEDGER_WINDOW=300

declare -a oks=()
declare -a warns=()
declare -a crits=()
declare -a configs=()    # configured, but the live state can't be verified without root — never counted as active
declare -a unknowns=()   # a probe that failed — shown, never silently "off"
class="ok"

# The UFW files the egress check reads (overridable for tests/test_foxml_sentry.py).
UFW_CONF="${FOXML_SENTRY_UFW_CONF:-/etc/ufw/ufw.conf}"
UFW_DEFAULT="${FOXML_SENTRY_UFW_DEFAULT:-/etc/default/ufw}"

_bump() {
    case "$1" in
        ok)   oks+=("$2") ;;
        warn) warns+=("$2"); [[ "$class" != "critical" ]] && class="warning" ;;
        crit) crits+=("$2"); class="critical" ;;
    esac
}

_svc()  { systemctl is-active --quiet "$1" 2>/dev/null; }
_usvc() { systemctl --user is-active --quiet "$1" 2>/dev/null; }

# ─── BASELINE (always-on after fox install --full) ────────────────
# Anything missing here is a real warning — the install would have set it up.
# UFW: a running unit is not proof the rules are loaded (that needs root) — so it's listed as configured, outside the
# active-protection count. A stopped unit is still critical: the install sets it up, and nothing then enforces.
_svc ufw       && configs+=("UFW service running (rules not verified)") || _bump crit "UFW service not running"
_svc fail2ban  && _bump ok "Brute-force (fail2ban)" || _bump warn "fail2ban inactive"
_svc auditd    && _bump ok "Audit logging"          || _bump warn "auditd inactive"
_svc usbguard  && _bump ok "USB policy"             || _bump warn "usbguard inactive"
_svc chronyd   && _bump ok "Time sync"              || _bump warn "chronyd inactive"
[[ -d /sys/kernel/security/apparmor ]] && _bump ok "MAC (AppArmor)" || _bump warn "AppArmor not loaded"
[[ -f /etc/sysctl.d/99-foxml-hardening.conf ]] && _bump ok "Kernel sysctls (KSPP+)" || _bump warn "kernel sysctls missing"

# Kernel hardening layers
sysrq=$(cat /proc/sys/kernel/sysrq 2>/dev/null)
if [[ "$sysrq" == "4" || "$sysrq" == "0" ]]; then _bump ok "SysRq hardened"; else _bump warn "SysRq full default"; fi
if findmnt /proc 2>/dev/null | grep -qE 'hidepid=(1|2|noaccess|invisible|ptraceable)'; then _bump ok "hidepid /proc"; else _bump warn "/proc not hidepid"; fi
if findmnt /tmp     2>/dev/null | grep -q noexec; then _bump ok "noexec /tmp"; else _bump warn "/tmp exec allowed"; fi
if findmnt /dev/shm 2>/dev/null | grep -q noexec; then _bump ok "noexec /dev/shm"; else _bump warn "/dev/shm exec allowed"; fi
if grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline 2>/dev/null; then _bump ok "IOMMU active"; fi
[[ -f /etc/systemd/coredump.conf.d/foxml-no-coredumps.conf ]] && _bump ok "Core dumps disabled"

# SSH posture
ssh_conf=/etc/ssh/sshd_config.d/50-foxml-hardening.conf
if [[ -f "$ssh_conf" ]]; then
    port=$(awk '/^Port /{print $2}' "$ssh_conf" 2>/dev/null)
    pa=$(awk '/^PasswordAuthentication /{print $2}' "$ssh_conf" 2>/dev/null)
    if [[ "$pa" == "no" ]]; then _bump ok "SSH keys-only (:${port})"
    else _bump warn "SSH passwords on"; fi
fi

# Browser hardening
[[ -L /usr/local/bin/firefox ]] && readlink /usr/local/bin/firefox 2>/dev/null | grep -q firejail \
    && _bump ok "Firefox firejailed"
[[ -f "$HOME/.config/firejail/firefox.local" ]] && _bump ok "Firejail DoH pinned"

# Local model server: llama.cpp's router must answer this machine only (127.0.0.1:8080/8081).
model_ports=$(ss -ltnH 2>/dev/null | awk '$4 ~ /:808[01]$/ {print $4}')
if [[ -n "$model_ports" ]]; then
    if grep -qvE '^127\.0\.0\.1:' <<<"$model_ports"; then _bump crit "Model server open to the network"
    else _bump ok "Model server loopback-only"; fi
fi

# Keyring components
[[ "$(systemctl --user is-enabled app-gnome-keyring-pkcs11@autostart.service 2>/dev/null)" == "masked" ]] \
    && [[ "$(systemctl --user is-enabled gnome-keyring-daemon.service 2>/dev/null)" == "masked" ]] \
    && _bump ok "Keyring SSH+GPG agents"

# DNS-over-HTTPS
_svc systemd-resolved && _bump ok "DNS-over-HTTPS"

# Endlessh tarpit (if real SSH is on a custom port)
_svc endlessh-go &>/dev/null && _bump ok "SSH tarpit (endlessh)" \
    || _svc endlessh &>/dev/null && _bump ok "SSH tarpit (endlessh)"

# etckeeper /etc git tracking
[[ -d /etc/.git ]] && _bump ok "/etc git-tracked"

# ─── ALWAYS-ON WATCHERS (auto-installed) ──────────────────────────
_usvc fox-bouncer.service       && _bump ok "USB-locked watcher (bouncer)"
_usvc fox-sentry-audit.service  && _bump ok "Kernel honeypot (auditd)"
_usvc fox-etcwatch.path         && _bump ok "/etc drift alert"

# ─── OPT-IN (counted if active; not warned if absent) ─────────────
[[ -f "$HOME/.config/foxml/dispatch.conf" ]]     && _bump ok "Phone alerts (dispatch)"
[[ -f "$HOME/.config/foxml/knock.conf" ]]        && _bump ok "Port knocking"
[[ -f "$HOME/.config/foxml/spa.conf" ]]          && _bump ok "SPA (replay-immune)"
[[ -f "$HOME/.config/foxml/cafe.conf" ]]         && _bump ok "Café Mode (untrusted-SSID)"
[[ -d "$HOME/.password-store" ]]                 && _bump ok "Pass vault"
_usvc fox-tripwire.service                       && _bump ok "User honeypot (tripwire)"
_usvc fox-proximity.service                      && _bump ok "Bluetooth proximity lock"
[[ -f /etc/udev/rules.d/99-foxml-deadman.rules ]] && _bump ok "USB dead-man switch"
_svc opensnitchd                                 && _bump ok "Per-app egress prompts (snitch)"
_svc cowrie                                      && _bump ok "SSH honeypot (cowrie)"
_svc fwknopd                                     && _bump ok "fwknopd (SPA daemon)"
_svc knockd                                      && _bump ok "knockd"

# Egress lockdown — from UFW's config, readable without root (no sudo here: the waybar sudoers entry allows only
# `ufw status`, so `sudo -n ufw status verbose` was refused every 15 s and this never showed). The config is the
# INTENDED policy; the live ruleset can't be read without root, so it's reported as configured, not active.
if [[ -r "$UFW_CONF" && -r "$UFW_DEFAULT" ]]; then
    ufw_enabled=$(sed -n 's/^ENABLED=//p' "$UFW_CONF" | tail -1)
    ufw_out=$(sed -n 's/^DEFAULT_OUTPUT_POLICY=//p' "$UFW_DEFAULT" | tail -1 | tr -d '"')
    if [[ -z "$ufw_enabled" || -z "$ufw_out" ]]; then
        unknowns+=("Egress policy: unknown (UFW config incomplete)")
    elif [[ "$ufw_enabled" == "yes" && ( "$ufw_out" == "DROP" || "$ufw_out" == "REJECT" ) ]]; then
        configs+=("Egress deny configured (UFW config; live rules not verified)")
    fi
else
    unknowns+=("Egress policy: unknown (UFW config unreadable)")
fi

# DNS sinkhole
grep -q '^# foxml-shield BEGIN' /etc/hosts 2>/dev/null && _bump ok "DNS sinkhole (StevenBlack)"

# WireGuard — an interface listed by `ip` (no root). That it EXISTS isn't proof of a working tunnel (the handshake needs
# `wg show`, which needs root), so it's "present", never "up" or "connected".
if wg_ifs=$(ip -br link show type wireguard 2>/dev/null); then
    wg_names=$(awk '{print $1}' <<<"$wg_ifs" | paste -sd, -)
    [[ -n "$wg_names" ]] && configs+=("WireGuard interface present: ${wg_names} (tunnel not verified)")
else
    unknowns+=("WireGuard: unknown (ip failed)")
fi

# Fingerprint enrolled
fprintd-list "$USER" 2>/dev/null | grep -qE '#[0-9]' && _bump ok "Fingerprint enrolled"

# ─── LEDGER: live alerts (last 5 min) ─────────────────────────────
recent_critical=0
if [[ -f "$LEDGER" ]]; then
    cutoff=$(( $(date +%s) - LEDGER_WINDOW ))
    while IFS=$'\t' read -r ts source msg; do
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        if (( ts >= cutoff )); then
            case "$source" in
                ssh-brute|*tripwire*|*HONEY*|USB*locked*|*deadman*|*SPOOFED*)
                    _bump crit "${source}: ${msg}"
                    recent_critical=$((recent_critical+1))
                    ;;
                *) _bump warn "${source}: ${msg}" ;;
            esac
        fi
    done < "$LEDGER"
fi

# ─── compose JSON ─────────────────────────────────────────────────
_tooltip() {
    local out=""
    if (( ${#crits[@]} > 0 )); then
        out+="🚨 Critical (${#crits[@]}):\\n"
        for m in "${crits[@]}"; do out+="  • $m\\n"; done
        out+="\\n"
    fi
    if (( ${#warns[@]} > 0 )); then
        out+="⚠ Warnings (${#warns[@]}):\\n"
        for m in "${warns[@]}"; do out+="  • $m\\n"; done
        out+="\\n"
    fi
    out+="✓ Active protections (${#oks[@]}):\\n"
    for m in "${oks[@]}"; do out+="  · $m\\n"; done
    if (( ${#configs[@]} > 0 )); then
        out+="\\n◇ Configured, not verified live (${#configs[@]}):\\n"
        for m in "${configs[@]}"; do out+="  · $m\\n"; done
    fi
    if (( ${#unknowns[@]} > 0 )); then
        out+="\\n? Unknown (${#unknowns[@]}):\\n"
        for m in "${unknowns[@]}"; do out+="  · $m\\n"; done
    fi
    out+="\\nClick: fox sec --live  •  Detail: fox arm --status"
    # JSON-safe.
    printf '%s' "${out//\"/\\\"}"
}

# Pango markup colours each glyph + count separately. Waybar custom
# modules render the `text` field as pango by default — so the
# warning triangle stays yellow, the shield stays green, the critical
# icon stays red, even when the module's overall class is "critical"
# (which the CSS uses for background tint + outer border colour).
RED='#b05555'; YEL='#c4b48a'; GRN='#7aab88'; PEACH='#d4985a'; DIM='#8a8a8a'

case "$class" in
    critical)
        text="<span color='${RED}' weight='bold'>󰀦 ${#crits[@]}</span><span color='${DIM}'> · </span><span color='${GRN}'>🛡 ${#oks[@]}</span>"
        ;;
    warning)
        text="<span color='${YEL}' weight='bold'>⚠ ${#warns[@]}</span><span color='${DIM}'> · </span><span color='${GRN}'>🛡 ${#oks[@]}</span>"
        ;;
    ok)
        text="<span color='${GRN}' weight='bold'>󰒃 ${#oks[@]}</span>"
        ;;
esac

tooltip="$(_tooltip)"
printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tooltip" "$class"
