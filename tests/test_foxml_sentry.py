#!/usr/bin/env python3
"""foxml_sentry.sh says only what it can verify, and never calls sudo (2026-10-23; plans/2026-10-23-waybar-sentry-
nosudo.md). Runs the real script with stub systemctl / findmnt / fprintd-list / ip / sudo on PATH and temp UFW files:
- sudo is never invoked (its stub leaves a marker), and the output is valid JSON, in every scenario;
- UFW egress deny shows as CONFIGURED (not verified live), outside the active-protection count;
- an unreadable or incomplete config shows "unknown", never a silent off;
- a WireGuard interface is "present", never "up" or "connected"; a failing `ip` shows "unknown";
- a user watcher switched on but not running is a warning, "Watcher down: …", not a quiet drop from the count;
- SSH is "off" while sshd is stopped; running, keys-only or passwords from the drop-in, the port from desk-ssh-port;
  keywords in any case, as sshd reads them (OpenSSH 10 prints them mixed case), its first value, none from a Match;
- what an opt-in module would set up is off by choice until chosen (listed, not counted, not a warning);
- port knocking and SPA count only while UFW's saved rules hold their gate: the first rule for sshd's port from
  anywhere denies it (2026-11-16: an install's `ufw limit` replaced the deny while the bar still counted the gate).
HOME is a scratch folder, so the machine's own knock, SPA or dispatch settings never decide a scenario."""
import json, os, pathlib, stat, subprocess, sys, tempfile

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "shared/waybar_scripts/foxml_sentry.sh"
fails = []


def run(ufw_conf, ufw_default, ip_script, unreadable=False, ufw_unit_active=False, units=None, system_units=(), ssh_dropin=None,
        system_states=None, noexec_live=False, fstab="", gates=(), rules=None, rules6=None):
    # the stubs must be executable: /tmp can be noexec (it is on the reference machine), so default to ~/.cache
    tmp_root = os.environ.get("FOX_TEST_TMP") or str(pathlib.Path.home() / ".cache")
    os.makedirs(tmp_root, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=tmp_root) as d:
        d = pathlib.Path(d); b = d / "bin"; b.mkdir()
        marker = d / "sudo-called"
        # units: {user unit: (what is-active prints, what is-enabled prints)}; system_units: system units running;
        # system_states: {system unit: (is-active, is-enabled)}; every other query is a stopped unit
        systemctl = "".join(f'[[ "$*" == "--user is-active {u}" ]] && {{ echo {a}; [[ {a} == active ]]; exit; }}\n'
                            f'[[ "$*" == "--user is-enabled {u}" ]] && {{ echo {e}; [[ {e} == enabled ]]; exit; }}\n'
                            for u, (a, e) in (units or {}).items())
        systemctl += "".join(f'[[ "$*" == "is-active --quiet {u}" ]] && exit 0\n' for u in system_units)
        systemctl += "".join(f'[[ "$*" == "is-active --quiet {u}" ]] && {{ [[ {a} == active ]]; exit; }}\n'
                             f'[[ "$*" == "is-active {u}" ]] && {{ echo {a}; [[ {a} == active ]]; exit; }}\n'
                             f'[[ "$*" == "is-enabled {u}" ]] && {{ echo {e}; [[ {e} == enabled ]]; exit; }}\n'
                             for u, (a, e) in (system_states or {}).items())
        systemctl += '[[ "$*" == *" ufw" ]] && exit 0; exit 3' if ufw_unit_active else "exit 3"
        # noexec_live: /tmp and /dev/shm are mounted noexec (findmnt shows the option); /proc never hidepid
        findmnt = ('case "$1" in /tmp|/dev/shm) echo "$1 tmpfs tmpfs rw,nosuid,nodev,noexec"; exit 0 ;; esac; exit 1'
                   if noexec_live else "exit 1")
        # sshd -T fails (it needs root), so desk-ssh-port reads the drop-in even where the tests run as root
        stubs = {"systemctl": systemctl, "findmnt": findmnt, "fprintd-list": "exit 1", "ip": ip_script,
                 "sudo": f'touch "{marker}"; exit 1', "sshd": "exit 255"}
        for name, body in stubs.items():
            f = b / name; f.write_text("#!/usr/bin/env bash\n" + body + "\n"); f.chmod(0o755)
        conf, default = d / "ufw.conf", d / "default-ufw"
        if ufw_conf is not None: conf.write_text(ufw_conf)
        if ufw_default is not None: default.write_text(ufw_default)
        if unreadable and conf.exists(): conf.chmod(0)
        dropin = d / "sshd-dropin.conf"
        if ssh_dropin is not None: dropin.write_text(ssh_dropin)
        # the machine's own fstab never decides a scenario: by default one with no /tmp line, as a default install has
        (d / "fstab").write_text(fstab)
        # gates: which of knock.conf / spa.conf the scratch home holds; rules, rules6: UFW's saved rules (None: none)
        home = d / "home"
        (home / ".config/foxml").mkdir(parents=True)
        for name in gates:
            (home / ".config/foxml" / f"{name}.conf").write_text("# a stand-in\n")
        r4, r6 = d / "user.rules", d / "user6.rules"
        if rules is not None: r4.write_text(rules)
        if rules6 is not None: r6.write_text(rules6)
        env = dict(os.environ, PATH=f"{b}:/usr/bin:/bin", HOME=str(home), XDG_RUNTIME_DIR=str(d), XDG_DATA_HOME=str(d / "data"),
                   FOXML_SENTRY_UFW_CONF=str(conf), FOXML_SENTRY_UFW_DEFAULT=str(default), FOXML_SSH_DROPIN=str(dropin),
                   FOXML_SENTRY_UFW_RULES=str(r4), FOXML_SENTRY_UFW_RULES6=str(r6),
                   FOXML_SENTRY_SSH_PORT=str(SCRIPT.parents[2] / "shared/bin/desk-ssh-port"), FOXML_SENTRY_FSTAB=str(d / "fstab"))
        r = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, env=env, timeout=30)
        if conf.exists(): conf.chmod(0o644)
        try:
            out = json.loads(r.stdout)
        except Exception:
            out = None
        return out, marker.exists(), r


def section(tooltip, title):
    """The lines of one tooltip section ("✓ Active protections", "◇ Configured", "? Unknown", "○ Off by choice")."""
    lines = tooltip.replace("\\n", "\n").split("\n")
    out, on = [], False
    for ln in lines:
        if ln.startswith(("🚨", "⚠", "✓", "◇", "?", "○", "Click")):
            on = ln.startswith(title)
            continue
        if on and ln.strip():
            out.append(ln.strip(" ·•"))
    return out


IP_NONE, IP_WG, IP_FAIL = "exit 0", 'echo "wg0             UNKNOWN        "; exit 0', "exit 1"
ON = "ENABLED=yes\n"
cases = [
    ("enabled + DROP, no wg", ON, 'DEFAULT_OUTPUT_POLICY="DROP"\n', IP_NONE, False,
     {"configured": ["Egress deny configured"], "unknown": [], "not_anywhere": ["WireGuard", "Egress lockdown"]}),
    ("enabled + REJECT", ON, 'DEFAULT_OUTPUT_POLICY="REJECT"\n', IP_NONE, False, {"configured": ["Egress deny configured"]}),
    ("enabled + ACCEPT → no egress line", ON, 'DEFAULT_OUTPUT_POLICY="ACCEPT"\n', IP_NONE, False,
     {"not_anywhere": ["Egress"]}),
    ("disabled + DROP → no egress line", "ENABLED=no\n", 'DEFAULT_OUTPUT_POLICY="DROP"\n', IP_NONE, False, {"not_anywhere": ["Egress"]}),
    ("config missing → unknown", None, None, IP_NONE, False, {"unknown": ["Egress policy: unknown"]}),
    ("config unreadable → unknown", ON, 'DEFAULT_OUTPUT_POLICY="DROP"\n', IP_NONE, True, {"unknown": ["Egress policy: unknown"]}),
    ("config incomplete → unknown", "# nothing\n", 'DEFAULT_OUTPUT_POLICY="DROP"\n', IP_NONE, False, {"unknown": ["Egress policy: unknown"]}),
    ("wg interface → present, never up", ON, 'DEFAULT_OUTPUT_POLICY="ACCEPT"\n', IP_WG, False,
     {"configured": ["WireGuard interface present: wg0"], "not_anywhere": ["WireGuard up", "connected"]}),
    ("ip fails → unknown", ON, 'DEFAULT_OUTPUT_POLICY="ACCEPT"\n', IP_FAIL, False, {"unknown": ["WireGuard: unknown"]}),
]
cases += [
    ("ufw unit running → configured, never an active protection", ON, 'DEFAULT_OUTPUT_POLICY="ACCEPT"\n', IP_NONE, False,
     {"configured": ["UFW service running (rules not verified)"], "not_anywhere": ["Firewall (UFW)"], "ufw_unit": True}),
    ("ufw unit stopped → critical, labelled as the service", ON, 'DEFAULT_OUTPUT_POLICY="ACCEPT"\n', IP_NONE, False,
     {"critical": ["UFW service not running"], "not_anywhere": ["Firewall DOWN", "Firewall (UFW)"]}),
]
skipped = 0
for name, conf, default, ip, unreadable, want in cases:
    if unreadable and os.geteuid() == 0:
        # root reads a mode-000 file anyway (CI's cross-config jobs run as root), so "unreadable" can't be staged here;
        # "config missing → unknown" still covers the unknown path everywhere
        print(f"  skip {name}: running as root, which ignores file permissions")
        skipped += 1
        continue
    out, sudo_called, r = run(conf, default, ip, unreadable, ufw_unit_active=want.get("ufw_unit", False))
    if out is None:
        fails.append(f"{name}: output is not JSON: {r.stdout[:120]!r} {r.stderr[:120]!r}"); continue
    if sudo_called:
        fails.append(f"{name}: sudo was called")
    tip = out["tooltip"]
    active, configured, unknown = section(tip, "✓"), section(tip, "◇"), section(tip, "?")
    for w in want.get("configured", []):
        if not any(w in x for x in configured): fails.append(f"{name}: '{w}' not in the configured section")
        if any(w in x for x in active): fails.append(f"{name}: '{w}' counted as an active protection")
    for w in want.get("critical", []):
        if not any(w in x for x in section(tip, "🚨")): fails.append(f"{name}: '{w}' not in the critical section")
    for w in want.get("unknown", []):
        if not any(w in x for x in unknown): fails.append(f"{name}: '{w}' not in the unknown section")
    if "unknown" in want and not want["unknown"] and unknown:
        fails.append(f"{name}: unexpected unknowns {unknown}")
    for w in want.get("not_anywhere", []):
        if w in tip:
            fails.append(f"{name}: '{w}' appears in the tooltip")
    import re as _re
    shield = _re.findall(r"(?:🛡|󰒃) (\d+)", out["text"])   # the shield count, in every class
    if not shield or int(shield[-1]) != len(active):
        fails.append(f"{name}: shield count {shield} ≠ {len(active)} active protections")
    if any("UFW service running" in x for x in active):
        fails.append(f"{name}: the UFW service line is counted as an active protection")

# A user watcher switched on but not running is an alert, "Watcher down: …", never a quiet drop from the count
# (2026-11-15: fox-etcwatch.path sat failed for hours while the pill just counted one protection fewer). Not installed
# or switched off, it is nothing; restarting, it still counts.
import re as _re
watcher_cases = [
    ("failed always-on watcher → a warning", {"fox-etcwatch.path": ("failed", "enabled")},
     {"warn": ["Watcher down: /etc drift alert (fox-etcwatch.path failed)"], "not_active": ["/etc drift alert"]}),
    ("stopped opt-in watcher, still switched on → a warning", {"fox-tripwire.service": ("inactive", "enabled")},
     {"warn": ["Watcher down: User honeypot (tripwire) (fox-tripwire.service inactive)"]}),
    ("failed kernel honeypot → a warning", {"fox-sentry-audit.service": ("failed", "enabled")},
     {"warn": ["Watcher down: Kernel honeypot (auditd) (fox-sentry-audit.service failed)"],
      "not_active": ["Kernel honeypot (auditd)"]}),
    ("failed proximity lock, still switched on → a warning", {"fox-proximity.service": ("failed", "enabled")},
     {"warn": ["Watcher down: Bluetooth proximity lock (fox-proximity.service failed)"],
      "not_active": ["Bluetooth proximity lock"]}),
    ("running watcher → an active protection", {"fox-etcwatch.path": ("active", "enabled")},
     {"active": ["/etc drift alert"], "not_anywhere": ["Watcher down"]}),
    ("restarting watcher → still counted", {"fox-bouncer.service": ("activating", "enabled")},
     {"active": ["USB-locked watcher (bouncer)"], "not_anywhere": ["Watcher down"]}),
    ("switched-off watcher → nothing", {"fox-tripwire.service": ("inactive", "disabled")},
     {"not_anywhere": ["Watcher down", "User honeypot"]}),
]
for name, units, want in watcher_cases:
    out, sudo_called, r = run(ON, 'DEFAULT_OUTPUT_POLICY="ACCEPT"\n', IP_NONE, ufw_unit_active=True, units=units)
    if out is None:
        fails.append(f"{name}: output is not JSON: {r.stdout[:120]!r} {r.stderr[:120]!r}"); continue
    if sudo_called:
        fails.append(f"{name}: sudo was called")
    tip = out["tooltip"]
    active, warns = section(tip, "✓"), section(tip, "⚠")
    for w in want.get("warn", []):
        if w not in warns: fails.append(f"{name}: '{w}' not in the warnings {warns}")
        # Retro draws the tooltip in a code page 437 font: the new line brings no glyph of its own.
        if not w.isascii(): fails.append(f"{name}: '{w}' is not plain text")
        if out["class"] == "ok": fails.append(f"{name}: the pill stays ok with a watcher down")
        count = _re.findall(r"󰀦 (\d+)", out["text"])
        if out["class"] == "warning" and (not count or int(count[-1]) != len(warns)):
            fails.append(f"{name}: the pill's warning count {count} ≠ {len(warns)} warnings")
    for w in want.get("active", []):
        if w not in active: fails.append(f"{name}: '{w}' not among the active protections {active}")
    for w in want.get("not_active", []):
        if w in active: fails.append(f"{name}: '{w}' still counted as an active protection")
    for w in want.get("not_anywhere", []):
        if w in tip: fails.append(f"{name}: '{w}' appears in the tooltip")
    shield = _re.findall(r"(?:🛡|󰒃) (\d+)", out["text"])
    if not shield or int(shield[-1]) != len(active):
        fails.append(f"{name}: shield count {shield} ≠ {len(active)} active protections")

# SSH: while sshd is stopped nothing listens, whatever the drop-in says (2026-11-16: the pill warned "SSH passwords on"
# on a laptop whose sshd is disabled). Running, the drop-in tells keys-only from passwords, with desk-ssh-port's port.
PASSWORDS, KEYS = "Port 2202\nPasswordAuthentication yes\n", "Port 2202\nPasswordAuthentication no\n"
ssh_cases = [
    ("sshd stopped, passwords in the drop-in → off, no warning", (), PASSWORDS,
     {"active": ["SSH server off"], "not_anywhere": ["SSH passwords on", "SSH keys-only"]}),
    ("sshd stopped, no drop-in → off", (), None, {"active": ["SSH server off"], "not_anywhere": ["SSH running"]}),
    ("sshd running, passwords → a warning with its port", ("sshd",), PASSWORDS,
     {"warn": ["SSH passwords on (:2202)"], "not_anywhere": ["SSH server off"]}),
    ("sshd running, keys only → a protection with its port", ("sshd",), KEYS,
     {"active": ["SSH keys-only (:2202)"], "not_anywhere": ["SSH passwords on", "SSH server off"]}),
    ("socket-activated sshd is running too", ("sshd.socket",), "PasswordAuthentication yes\n",
     {"warn": ["SSH passwords on (:22)"], "not_anywhere": ["SSH server off"]}),
    ("sshd running, no drop-in → unknown, never a silent pass", ("sshd",), None,
     {"unknown": ["SSH running: password login unknown (no hardening drop-in)"], "not_anywhere": ["SSH server off", "SSH keys-only"]}),
    # sshd reads keywords and yes/no in any case, "Keyword=value" too, and keeps a keyword's first value; a Match
    # block's lines apply only to what it matches.
    ("keyword in lower case, keys only → a protection", ("sshd",), "port 2202\npasswordauthentication no\n",
     {"active": ["SSH keys-only (:2202)"], "not_anywhere": ["SSH passwords on"]}),
    ("keyword and value in mixed case, with = → keys only", ("sshd",), "Port 2202\n  PASSWORDAUTHENTICATION = No\n",
     {"active": ["SSH keys-only (:2202)"], "not_anywhere": ["SSH passwords on"]}),
    ("the first value wins: no, then yes → keys only", ("sshd",), "Port 2202\nPasswordAuthentication no\nPasswordAuthentication yes\n",
     {"active": ["SSH keys-only (:2202)"], "not_anywhere": ["SSH passwords on"]}),
    ("the first value wins: Yes, then no → passwords on", ("sshd",), "Port 2202\nPasswordauthentication Yes\nPasswordAuthentication no\n",
     {"warn": ["SSH passwords on (:2202)"], "not_anywhere": ["SSH keys-only"]}),
    ("no only inside a Match block → passwords on", ("sshd",), "Port 2202\nMatch User admin\n  PasswordAuthentication no\n",
     {"warn": ["SSH passwords on (:2202)"], "not_anywhere": ["SSH keys-only"]}),
]
for name, system_units, dropin, want in ssh_cases:
    out, sudo_called, r = run(ON, 'DEFAULT_OUTPUT_POLICY="ACCEPT"\n', IP_NONE, ufw_unit_active=True, system_units=system_units, ssh_dropin=dropin)
    if out is None:
        fails.append(f"{name}: output is not JSON: {r.stdout[:120]!r} {r.stderr[:120]!r}"); continue
    if sudo_called:
        fails.append(f"{name}: sudo was called")
    tip = out["tooltip"]
    active, warns, unknown = section(tip, "✓"), section(tip, "⚠"), section(tip, "?")
    for w in want.get("active", []):
        if w not in active: fails.append(f"{name}: '{w}' not among the active protections {active}")
    for w in want.get("warn", []):
        if w not in warns: fails.append(f"{name}: '{w}' not in the warnings {warns}")
    for w in want.get("unknown", []):
        if w not in unknown: fails.append(f"{name}: '{w}' not in the unknowns {unknown}")
    for w in want.get("not_anywhere", []):
        if w in tip: fails.append(f"{name}: '{w}' appears in the tooltip")

# Opt-in protections (2026-11-16, a VM test: a default install's pill read "SEC 4 WARN" forever). What an opt-in module
# would set up — noexec_tmp's /tmp and /dev/shm, perf's chrony — is off by choice until it is chosen: listed under
# "○ Off by choice", never counted, never a warning. Chosen but not working, it warns (as a watcher switched on but
# down does, watcher_cases); working, it counts.
DEFAULT_FSTAB = "UUID=0a1b / ext4 rw,relatime 0 1\n"
NOEXEC_FSTAB = DEFAULT_FSTAB + "tmpfs   /tmp        tmpfs   defaults,noexec,nosuid,nodev,size=4G  0 0\n"
optin_cases = [
    ("default install: noexec_tmp and perf not chosen → off, no warning", {}, False, DEFAULT_FSTAB,
     {"off": ["noexec /tmp", "noexec /dev/shm", "Time sync (no NTP daemon)"],
      "not_warn": ["/tmp exec allowed", "/dev/shm exec allowed", "Time sync", "chronyd"]}),
    ("noexec_tmp chosen, mounts allow exec → warnings", {}, False, NOEXEC_FSTAB,
     {"warn": ["/tmp exec allowed", "/dev/shm exec allowed"], "not_off": ["noexec /tmp", "noexec /dev/shm"]}),
    ("noexec_tmp chosen and live → protections", {}, True, NOEXEC_FSTAB, {"active": ["noexec /tmp", "noexec /dev/shm"]}),
    ("noexec live without the module → protections all the same", {}, True, DEFAULT_FSTAB,
     {"active": ["noexec /tmp", "noexec /dev/shm"], "not_off": ["noexec /tmp"]}),
    ("the base system's timesyncd → time sync", {"systemd-timesyncd": ("active", "enabled")}, False, DEFAULT_FSTAB,
     {"active": ["Time sync"], "not_off": ["Time sync (no NTP daemon)"]}),
    ("perf chosen, chrony running → time sync", {"chronyd": ("active", "enabled")}, False, DEFAULT_FSTAB, {"active": ["Time sync"]}),
    ("perf chosen, chrony failed → a warning", {"chronyd": ("failed", "enabled")}, False, DEFAULT_FSTAB,
     {"warn": ["Time sync down: chronyd failed"], "not_off": ["Time sync (no NTP daemon)"], "not_active": ["Time sync"]}),
]
for name, states, noexec_live, fstab, want in optin_cases:
    out, sudo_called, r = run(ON, 'DEFAULT_OUTPUT_POLICY="ACCEPT"\n', IP_NONE, ufw_unit_active=True, system_states=states,
                              noexec_live=noexec_live, fstab=fstab)
    if out is None:
        fails.append(f"{name}: output is not JSON: {r.stdout[:120]!r} {r.stderr[:120]!r}"); continue
    if sudo_called:
        fails.append(f"{name}: sudo was called")
    tip = out["tooltip"]
    active, warns, off = section(tip, "✓"), section(tip, "⚠"), section(tip, "○")
    for w in want.get("off", []):
        if w not in off: fails.append(f"{name}: '{w}' not off by choice {off}")
    for w in want.get("not_warn", []):
        if any(w in x for x in warns): fails.append(f"{name}: '{w}' is a warning {warns}")
    for w in want.get("warn", []):
        if w not in warns: fails.append(f"{name}: '{w}' not in the warnings {warns}")
    for w in want.get("not_off", []):
        if w in off: fails.append(f"{name}: '{w}' listed as off by choice")
    for w in want.get("active", []):
        if w not in active: fails.append(f"{name}: '{w}' not among the active protections {active}")
    for w in want.get("not_active", []):
        if w in active: fails.append(f"{name}: '{w}' counted as an active protection")
    # Off by choice is neither counted nor warned: the shield counts the protections, the warning count the warnings.
    shield, count = _re.findall(r"(?:🛡|󰒃) (\d+)", out["text"]), _re.findall(r"󰀦 (\d+)", out["text"])
    if not shield or int(shield[-1]) != len(active):
        fails.append(f"{name}: shield count {shield} ≠ {len(active)} active protections")
    if out["class"] == "warning" and (not count or int(count[-1]) != len(warns)):
        fails.append(f"{name}: the pill's warning count {count} ≠ {len(warns)} warnings")

# Port knocking and SPA gate sshd's port: UFW denies it to everyone and knockd / fwknopd open it per address. The pill
# counts one only while UFW's saved rules (user.rules, and user6.rules when UFW handles IPv6) hold that gate: ufw stops
# at the first rule that matches, so the first rule for the port from anywhere must deny it, or, with none, incoming's
# default. 2026-11-16: an install's `ufw limit 2202/tcp` replaced the deny, and the bar still listed "Port knocking".
def tuples(*rows):
    """user.rules as ufw saves it: each rule a tuple comment line, then its iptables lines."""
    body = "".join(f"\n### tuple ### {row}\n-A ufw-user-input -p tcp --dport 2202 -j DROP\n" for row in rows)
    return f"*filter\n:ufw-user-input - [0:0]\n### RULES ###\n{body}\n### END RULES ###\nCOMMIT\n"


DENY4, DENY6 = "deny tcp 2202 0.0.0.0/0 any 0.0.0.0/0 in", "deny tcp 2202 ::/0 any ::/0 in"
LIMIT4, LIMIT6 = "limit tcp 2202 0.0.0.0/0 any 0.0.0.0/0 in", "limit tcp 2202 ::/0 any ::/0 in"
KNOCKED4 = "allow tcp 2202 0.0.0.0/0 any 198.51.100.7 in"      # knockd's opening for one address
WEB4, WEB6 = "allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 in", "allow tcp 80 ::/0 any ::/0 in"
GATE_DEFAULT = 'DEFAULT_INPUT_POLICY="DROP"\nDEFAULT_OUTPUT_POLICY="ACCEPT"\nIPV6=yes\n'
OPEN_MSG, OFF_MSG = "Port knocking set up, but UFW lets anyone reach :2202", "Port knocking set up, but UFW is off"
gate_cases = [
    ("UFW denies the port → the gate counts", ("knock",), ON, GATE_DEFAULT, tuples(DENY4), tuples(DENY6),
     {"active": ["Port knocking"], "not_anywhere": [OPEN_MSG]}),
    ("a LIMIT in the deny's place → a warning, not counted", ("knock",), ON, GATE_DEFAULT, tuples(LIMIT4), tuples(LIMIT6),
     {"warn": [OPEN_MSG], "not_active": ["Port knocking"]}),
    ("the deny first, a LIMIT after it → held", ("knock",), ON, GATE_DEFAULT, tuples(DENY4, LIMIT4), tuples(DENY6, LIMIT6),
     {"active": ["Port knocking"], "not_anywhere": [OPEN_MSG]}),
    ("a knock's opening for one address before the deny → held", ("knock",), ON, GATE_DEFAULT, tuples(KNOCKED4, DENY4),
     tuples(DENY6), {"active": ["Port knocking"], "not_anywhere": [OPEN_MSG]}),
    ("IPv6 limited while IPv4 denies → a warning", ("knock",), ON, GATE_DEFAULT, tuples(DENY4), tuples(LIMIT6),
     {"warn": [OPEN_MSG], "not_active": ["Port knocking"]}),
    ("UFW without IPv6: only IPv4's rules count", ("knock",), ON, GATE_DEFAULT.replace("IPV6=yes", "IPV6=no"), tuples(DENY4),
     tuples(LIMIT6), {"active": ["Port knocking"]}),
    ("no rule for the port, incoming denied by default → held", ("knock",), ON, GATE_DEFAULT, tuples(WEB4), tuples(WEB6),
     {"active": ["Port knocking"]}),
    ("no rule for the port, incoming accepted by default → a warning", ("knock",), ON,
     GATE_DEFAULT.replace('INPUT_POLICY="DROP"', 'INPUT_POLICY="ACCEPT"'), tuples(WEB4), tuples(WEB6), {"warn": [OPEN_MSG]}),
    ("a range allowed ahead of the deny → a warning", ("knock",), ON, GATE_DEFAULT,
     tuples("allow tcp 2000:3000 0.0.0.0/0 any 0.0.0.0/0 in", DENY4), tuples(DENY6), {"warn": [OPEN_MSG]}),
    ("an allow on one interface ahead of the deny → a warning", ("knock",), ON, GATE_DEFAULT,
     tuples("allow tcp 2202 0.0.0.0/0 any 0.0.0.0/0 in_wlan0", DENY4), tuples(DENY6), {"warn": [OPEN_MSG]}),
    ("UFW switched off → a warning", ("knock",), "ENABLED=no\n", GATE_DEFAULT, tuples(DENY4), tuples(DENY6),
     {"warn": [OFF_MSG], "not_active": ["Port knocking"]}),
    ("rule files missing → configured, not verified", ("knock",), ON, GATE_DEFAULT, None, None,
     {"configured": ["Port knocking (UFW's deny of :2202 not verified)"], "not_active": ["Port knocking"]}),
    ("SPA the same way", ("spa",), ON, GATE_DEFAULT, tuples(LIMIT4), tuples(LIMIT6),
     {"warn": ["SPA (replay-immune) set up, but UFW lets anyone reach :2202"], "not_active": ["SPA (replay-immune)"]}),
    ("neither set up → nothing said", (), ON, GATE_DEFAULT, tuples(LIMIT4), tuples(LIMIT6),
     {"not_anywhere": ["Port knocking", "SPA"]}),
    ("UFW's settings in any case, as ufw reads them", ("knock",), "Enabled=Yes\n",
     'default_input_policy="drop"\nDEFAULT_OUTPUT_POLICY="accept"\nIPv6=Yes\n', tuples(DENY4), tuples(DENY6),
     {"active": ["Port knocking"], "not_anywhere": [OPEN_MSG, OFF_MSG]}),
]
for name, gates, conf, default, rules, rules6, want in gate_cases:
    out, sudo_called, r = run(conf, default, IP_NONE, ufw_unit_active=True, ssh_dropin="Port 2202\n", gates=gates,
                              rules=rules, rules6=rules6)
    if out is None:
        fails.append(f"{name}: output is not JSON: {r.stdout[:120]!r} {r.stderr[:120]!r}"); continue
    if sudo_called:
        fails.append(f"{name}: sudo was called")
    tip = out["tooltip"]
    active, warns, configured = section(tip, "✓"), section(tip, "⚠"), section(tip, "◇")
    for w in want.get("active", []):
        if w not in active: fails.append(f"{name}: '{w}' not among the active protections {active}")
    for w in want.get("not_active", []):
        if w in active: fails.append(f"{name}: '{w}' counted as an active protection")
    for w in want.get("warn", []):
        if w not in warns: fails.append(f"{name}: '{w}' not in the warnings {warns}")
        if not w.isascii(): fails.append(f"{name}: '{w}' is not plain text")
    for w in want.get("configured", []):
        if w not in configured: fails.append(f"{name}: '{w}' not in the configured section {configured}")
    for w in want.get("not_anywhere", []):
        if w in tip: fails.append(f"{name}: '{w}' appears in the tooltip")
    shield = _re.findall(r"(?:🛡|󰒃) (\d+)", out["text"])
    if not shield or int(shield[-1]) != len(active):
        fails.append(f"{name}: shield count {shield} ≠ {len(active)} active protections")

for f in fails:
    print("FAIL", f)
print("foxml_sentry:", "OK" if not fails else f"{len(fails)} FAILED",
      f"({len(cases) + len(watcher_cases) + len(ssh_cases) + len(optin_cases) + len(gate_cases) - skipped} scenarios run"
      + (f", {skipped} skipped)" if skipped else ")"))
sys.exit(1 if fails else 0)
