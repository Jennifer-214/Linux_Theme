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
# Pairs with: desk sec / desk sec dashboard --live / desk arm --status — they are
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
declare -a offs=()       # an opt-in protection never switched on: off by choice — shown, never counted, never a warning
class="ok"

# The UFW files the egress and knock/SPA checks read, and the fstab the noexec check reads (overridable for
# tests/test_foxml_sentry.py).
UFW_CONF="${FOXML_SENTRY_UFW_CONF:-/etc/ufw/ufw.conf}"
UFW_DEFAULT="${FOXML_SENTRY_UFW_DEFAULT:-/etc/default/ufw}"
UFW_RULES="${FOXML_SENTRY_UFW_RULES:-/etc/ufw/user.rules}"
UFW_RULES6="${FOXML_SENTRY_UFW_RULES6:-/etc/ufw/user6.rules}"
FSTAB="${FOXML_SENTRY_FSTAB:-/etc/fstab}"

_bump() {
    case "$1" in
        ok)   oks+=("$2") ;;
        warn) warns+=("$2"); [[ "$class" != "critical" ]] && class="warning" ;;
        crit) crits+=("$2"); class="critical" ;;
    esac
}

_svc()  { systemctl is-active --quiet "$1" 2>/dev/null; }

# A KEY=value setting of UFW's, as ufw reads it: the key in any case, the last line wins, the value lowercased and
# unquoted. Empty when the file has none.
_ufw_setting() {
    awk -F= -v k="$1" 'tolower($1) == tolower(k) { v = $2 } END { gsub(/["'\''[:space:]]/, "", v); print tolower(v) }' "$2" 2>/dev/null
}

# Whether UFW holds sshd's port shut to everyone, the gate desk knock and desk spa set up (`ufw deny <port>/tcp`, then
# knockd or fwknopd open it to one address at a time): held, open, off or unknown. ufw stops at the first rule that
# matches, so the first rule for the port from anywhere decides; with none, incoming's default policy does. One that
# names an interface only opens. Read from the rule files ufw saves (no sudo here), IPv6's too when UFW handles IPv6.
_ufw_gate() {
    local port=$1 file enabled default verdict
    local -a files=("$UFW_RULES")
    [[ -r "$UFW_CONF" && -r "$UFW_DEFAULT" ]] || { echo unknown; return; }
    enabled=$(_ufw_setting ENABLED "$UFW_CONF")
    [[ -n "$enabled" ]] || { echo unknown; return; }
    [[ "$enabled" == yes ]] || { echo off; return; }
    [[ "$(_ufw_setting IPV6 "$UFW_DEFAULT")" == yes ]] && files+=("$UFW_RULES6")
    default=$(_ufw_setting DEFAULT_INPUT_POLICY "$UFW_DEFAULT")
    for file in "${files[@]}"; do
        [[ -r "$file" ]] || { echo unknown; return; }
        # ### tuple ### ACTION[_LOG] PROTO DPORT DST SPORT SRC [DAPP SAPP] DIRECTION[_IFACE] [comment=…]
        verdict=$(awk -v port="$port" '
            function hits(spec, n, i, part, lohi) {
                if (spec == "any") return 1
                n = split(spec, part, ",")
                for (i = 1; i <= n; i++) {
                    if (split(part[i], lohi, ":") == 2) { if (port + 0 >= lohi[1] + 0 && port + 0 <= lohi[2] + 0) return 1 }
                    else if (part[i] + 0 == port + 0) return 1
                }
                return 0
            }
            /^### tuple ### / {
                line = $0; sub(/ comment=.*/, "", line)
                n = split(line, t, " ")
                action = tolower(t[4]); proto = tolower(t[5]); dir = tolower(t[n])
                if (action ~ /^route:/ || dir !~ /^in/ || (proto != "tcp" && proto != "any") || !hits(t[6])) next
                if (t[9] != "0.0.0.0/0" && t[9] != "::/0") next     # one address: an opening a knock made
                sub(/_.*/, "", action)
                if (dir != "in" && action != "allow" && action != "limit") next
                found = (action == "deny" || action == "reject") ? "held" : "open"; exit
            }
            END { print (found == "" ? "none" : found) }' "$file")
        if [[ "$verdict" == none ]]; then
            case "$default" in drop|reject) verdict=held ;; accept) verdict=open ;; *) echo unknown; return ;; esac
        fi
        [[ "$verdict" == held ]] || { echo open; return; }
    done
    echo held
}

# A user watcher counts while it runs. Switched on but not running (failed, stopped) it is an alert, never a quiet drop
# from the count: fox-etcwatch.path sat failed from 18:42 on 2026-11-15 while the pill just showed one protection
# fewer. Not installed or switched off, it is nothing.
_watcher() {
    local unit="$1" label="$2" state
    state=$(systemctl --user is-active "$unit" 2>/dev/null)
    case "$state" in
        active|activating|reloading|refreshing) _bump ok "$label" ;;
        *) [[ "$(systemctl --user is-enabled "$unit" 2>/dev/null)" == enabled* ]] \
               && _bump warn "Watcher down: $label ($unit ${state:-not running})" ;;
    esac
}

# A service an opt-in install module sets up, the same way: running counts; switched on but not running is a warning;
# never switched on, it returns 1 and the caller lists it as off by choice (2026-11-16: a default install's pill read
# "SEC 4 WARN" forever, three of them modules the installer leaves off).
_optin_svc() {
    local unit="$1" label="$2" state
    _svc "$unit" && { _bump ok "$label"; return 0; }
    [[ "$(systemctl is-enabled "$unit" 2>/dev/null)" == enabled* ]] || return 1
    state=$(systemctl is-active "$unit" 2>/dev/null)
    _bump warn "$label down: $unit ${state:-not running}"
}

# ─── BASELINE (always-on after desk install --full) ────────────────
# Anything missing here is a real warning — the install would have set it up.
# UFW: a running unit is not proof the rules are loaded (that needs root) — so it's listed as configured, outside the
# active-protection count. A stopped unit is still critical: the install sets it up, and nothing then enforces.
_svc ufw       && configs+=("UFW service running (rules not verified)") || _bump crit "UFW service not running"
_svc fail2ban  && _bump ok "Brute-force (fail2ban)" || _bump warn "fail2ban inactive"
_svc auditd    && _bump ok "Audit logging"          || _bump warn "auditd inactive"
_svc usbguard  && _bump ok "USB policy"             || _bump warn "usbguard inactive"
# Time sync: chrony is opt-in (the perf module); the base system's timesyncd counts the same.
_optin_svc chronyd "Time sync" || _optin_svc systemd-timesyncd "Time sync" || offs+=("Time sync (no NTP daemon)")
[[ -d /sys/kernel/security/apparmor ]] && _bump ok "MAC (AppArmor)" || _bump warn "AppArmor not loaded"
[[ -f /etc/sysctl.d/99-foxml-hardening.conf ]] && _bump ok "Kernel sysctls (KSPP+)" || _bump warn "kernel sysctls missing"

# Kernel hardening layers
sysrq=$(cat /proc/sys/kernel/sysrq 2>/dev/null)
if [[ "$sysrq" == "4" || "$sysrq" == "0" ]]; then _bump ok "SysRq hardened"; else _bump warn "SysRq full default"; fi
if findmnt /proc 2>/dev/null | grep -qE 'hidepid=(1|2|noaccess|invisible|ptraceable)'; then _bump ok "hidepid /proc"; else _bump warn "/proc not hidepid"; fi
# noexec /tmp + /dev/shm is the opt-in noexec_tmp module, chosen when fstab's /tmp line carries noexec (what it
# writes). Chosen, a mount that allows exec is a warning; not chosen, it is off by choice.
noexec_chosen=0
awk '!/^[[:space:]]*#/ && $2 == "/tmp" && $4 ~ /(^|,)noexec(,|$)/ { found = 1 } END { exit !found }' "$FSTAB" 2>/dev/null \
    && noexec_chosen=1
for mnt in /tmp /dev/shm; do
    if findmnt "$mnt" 2>/dev/null | grep -q noexec; then _bump ok "noexec $mnt"
    elif (( noexec_chosen )); then _bump warn "$mnt exec allowed"
    else offs+=("noexec $mnt"); fi
done
if grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline 2>/dev/null; then _bump ok "IOMMU active"; fi
[[ -f /etc/systemd/coredump.conf.d/foxml-no-coredumps.conf ]] && _bump ok "Core dumps disabled"

# SSH posture. While sshd is stopped nothing listens, whatever its config says (2026-11-16: the pill warned "SSH
# passwords on" on a laptop whose sshd is disabled). Running, the wizard's drop-in tells keys-only from passwords;
# without the drop-in, password login can't be read without root. The port is desk-ssh-port's, never through sudo.
ssh_conf="${FOXML_SSH_DROPIN:-/etc/ssh/sshd_config.d/50-foxml-hardening.conf}"
ssh_port() { "${FOXML_SENTRY_SSH_PORT:-$HOME/.local/bin/desk-ssh-port}" --no-sudo 2>/dev/null | head -n1; }
# PasswordAuthentication as sshd reads it: keyword and value in any case (OpenSSH 10's own dump prints them mixed),
# "Keyword value" or "Keyword=value", the first one before any Match block (sshd keeps a keyword's first value).
_ssh_password_auth() {
    awk '{ sub(/^[ \t]+/, "") }
         $0 == "" || /^#/ { next }
         { key = $0; sub(/[ \t=].*/, "", key); key = tolower(key) }
         key == "match" { exit }
         key == "passwordauthentication" {
             value = substr($0, length(key) + 1); sub(/^[ \t]*=?[ \t]*/, "", value); sub(/[ \t#].*/, "", value)
             gsub(/"/, "", value); print tolower(value); exit
         }' "$1" 2>/dev/null
}
if ! _svc sshd && ! _svc sshd.socket; then
    _bump ok "SSH server off"
elif [[ -f "$ssh_conf" ]]; then
    port=$(ssh_port)
    pa=$(_ssh_password_auth "$ssh_conf")
    if [[ "$pa" == "no" ]]; then _bump ok "SSH keys-only${port:+ (:$port)}"
    else _bump warn "SSH passwords on${port:+ (:$port)}"; fi
else
    unknowns+=("SSH running: password login unknown (no hardening drop-in)")
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
_watcher fox-bouncer.service      "USB-locked watcher (bouncer)"
_watcher fox-sentry-audit.service "Kernel honeypot (auditd)"
_watcher fox-etcwatch.path        "/etc drift alert"

# ─── OPT-IN (counted if active; not warned if absent) ─────────────
[[ -f "$HOME/.config/foxml/dispatch.conf" ]]     && _bump ok "Phone alerts (dispatch)"
# Port knocking and SPA count while UFW holds the gate they set up (_ufw_gate), not because their settings exist
# (2026-11-16: an install's `ufw limit` put a public rule in the deny's place, and the bar still counted the gate).
_gate() {   # _gate SETTINGS LABEL
    local state
    [[ -f "$1" ]] || return 0
    [[ -n "${gate_port:-}" ]] || gate_port=$(ssh_port)
    state=$(_ufw_gate "${gate_port:-22}")
    case "$state" in
        held) _bump ok "$2" ;;
        open) _bump warn "$2 set up, but UFW lets anyone reach :${gate_port:-22}" ;;
        off)  _bump warn "$2 set up, but UFW is off" ;;
        *)    configs+=("$2 (UFW's deny of :${gate_port:-22} not verified)") ;;
    esac
}
_gate "$HOME/.config/foxml/knock.conf" "Port knocking"
_gate "$HOME/.config/foxml/spa.conf"   "SPA (replay-immune)"
[[ -f /etc/foxml/cafe.conf ]]                    && _bump ok "Café Mode (untrusted-SSID)"
[[ -d "$HOME/.password-store" ]]                 && _bump ok "Pass vault"
_watcher fox-tripwire.service                    "User honeypot (tripwire)"
_watcher fox-proximity.service                   "Bluetooth proximity lock"
[[ -f /etc/udev/rules.d/99-foxml-deadman.rules ]] && _bump ok "USB dead-man switch"
_svc opensnitchd                                 && _bump ok "Per-app egress prompts (snitch)"
_svc cowrie                                      && _bump ok "SSH honeypot (cowrie)"
_svc fwknopd                                     && _bump ok "fwknopd (SPA daemon)"
_svc knockd                                      && _bump ok "knockd"

# Egress lockdown — from UFW's config, readable without root (no sudo here: the waybar sudoers entry allows only
# `ufw status`, so `sudo -n ufw status verbose` was refused every 15 s and this never showed). The config is the
# INTENDED policy; the live ruleset can't be read without root, so it's reported as configured, not active.
if [[ -r "$UFW_CONF" && -r "$UFW_DEFAULT" ]]; then
    ufw_enabled=$(_ufw_setting ENABLED "$UFW_CONF")
    ufw_out=$(_ufw_setting DEFAULT_OUTPUT_POLICY "$UFW_DEFAULT")
    if [[ -z "$ufw_enabled" || -z "$ufw_out" ]]; then
        unknowns+=("Egress policy: unknown (UFW config incomplete)")
    elif [[ "$ufw_enabled" == "yes" && ( "$ufw_out" == "drop" || "$ufw_out" == "reject" ) ]]; then
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
# Free text (process names, findings, model names) goes into hand-built JSON: escape it there, as media.sh does, or
# one tab or quote makes the module's line invalid and the bar blanks it.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    printf '%s' "$s"
}
_tooltip() {
    local out=""
    if (( ${#crits[@]} > 0 )); then
        out+="🚨 Critical (${#crits[@]}):\\n"
        for m in "${crits[@]}"; do out+="  • $(json_escape "$m")\\n"; done
        out+="\\n"
    fi
    if (( ${#warns[@]} > 0 )); then
        out+="⚠ Warnings (${#warns[@]}):\\n"
        for m in "${warns[@]}"; do out+="  • $(json_escape "$m")\\n"; done
        out+="\\n"
    fi
    out+="✓ Active protections (${#oks[@]}):\\n"
    for m in "${oks[@]}"; do out+="  · $(json_escape "$m")\\n"; done
    if (( ${#configs[@]} > 0 )); then
        out+="\\n◇ Configured, not verified live (${#configs[@]}):\\n"
        for m in "${configs[@]}"; do out+="  · $(json_escape "$m")\\n"; done
    fi
    if (( ${#unknowns[@]} > 0 )); then
        out+="\\n? Unknown (${#unknowns[@]}):\\n"
        for m in "${unknowns[@]}"; do out+="  · $(json_escape "$m")\\n"; done
    fi
    if (( ${#offs[@]} > 0 )); then
        out+="\\n○ Off by choice, opt-in (${#offs[@]}):\\n"
        for m in "${offs[@]}"; do out+="  · $(json_escape "$m")\\n"; done
    fi
    out+="\\nClick: desk sec dashboard --live  •  Detail: desk arm --status"
    printf '%s' "$out"
}

# Pango markup colours each glyph + count separately. Waybar custom
# modules render the `text` field as pango by default — so the
# warning triangle stays yellow, the shield stays green, the critical
# icon stays red, even when the module's overall class is "critical"
# (which the CSS uses for background tint + outer border colour).
# Colours come from the active theme's rendered palette.
_pal="$HOME/.config/hypr/modules/border_colors.sh"
[[ -r "$_pal" ]] && source "$_pal"
RED="#${C_SENTRY_CRIT:-b05555}"; YEL="#${C_SENTRY_WARN:-c4b48a}"
GRN="#${C_SENTRY_OK:-7aab88}"; DIM="#${C_SENTRY_DIM:-8a8a8a}"
shield="󰒃"; warning="󰀦"

case "$class" in
    critical)
        text="<span color='${RED}' weight='bold'>$warning ${#crits[@]}</span><span color='${DIM}'> · </span><span color='${GRN}'>$shield ${#oks[@]}</span>"
        ;;
    warning)
        text="<span color='${YEL}' weight='bold'>$warning ${#warns[@]}</span><span color='${DIM}'> · </span><span color='${GRN}'>$shield ${#oks[@]}</span>"
        ;;
    ok)
        text="<span color='${GRN}'>$shield ${#oks[@]}</span>"
        ;;
esac

tooltip="$(_tooltip)"
printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tooltip" "$class"
