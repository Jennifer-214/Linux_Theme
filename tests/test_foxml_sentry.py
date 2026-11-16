#!/usr/bin/env python3
"""foxml_sentry.sh says only what it can verify, and never calls sudo (2026-10-23; plans/2026-10-23-waybar-sentry-
nosudo.md). Runs the real script with stub systemctl / findmnt / fprintd-list / ip / sudo on PATH and temp UFW files:
- sudo is never invoked (its stub leaves a marker), and the output is valid JSON, in every scenario;
- UFW egress deny shows as CONFIGURED (not verified live), outside the active-protection count;
- an unreadable or incomplete config shows "unknown", never a silent off;
- a WireGuard interface is "present", never "up" or "connected"; a failing `ip` shows "unknown";
- a user watcher switched on but not running is a warning, "Watcher down: …", not a quiet drop from the count."""
import json, os, pathlib, stat, subprocess, sys, tempfile

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "shared/waybar_scripts/foxml_sentry.sh"
fails = []


def run(ufw_conf, ufw_default, ip_script, unreadable=False, ufw_unit_active=False, units=None):
    # the stubs must be executable: /tmp can be noexec (it is on the reference machine), so default to ~/.cache
    tmp_root = os.environ.get("FOX_TEST_TMP") or str(pathlib.Path.home() / ".cache")
    os.makedirs(tmp_root, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=tmp_root) as d:
        d = pathlib.Path(d); b = d / "bin"; b.mkdir()
        marker = d / "sudo-called"
        # units: {user unit: (what is-active prints, what is-enabled prints)}; every other query is a stopped unit
        systemctl = "".join(f'[[ "$*" == "--user is-active {u}" ]] && {{ echo {a}; [[ {a} == active ]]; exit; }}\n'
                            f'[[ "$*" == "--user is-enabled {u}" ]] && {{ echo {e}; [[ {e} == enabled ]]; exit; }}\n'
                            for u, (a, e) in (units or {}).items())
        systemctl += '[[ "$*" == *" ufw" ]] && exit 0; exit 3' if ufw_unit_active else "exit 3"
        stubs = {"systemctl": systemctl, "findmnt": "exit 1", "fprintd-list": "exit 1", "ip": ip_script,
                 "sudo": f'touch "{marker}"; exit 1'}
        for name, body in stubs.items():
            f = b / name; f.write_text("#!/usr/bin/env bash\n" + body + "\n"); f.chmod(0o755)
        conf, default = d / "ufw.conf", d / "default-ufw"
        if ufw_conf is not None: conf.write_text(ufw_conf)
        if ufw_default is not None: default.write_text(ufw_default)
        if unreadable and conf.exists(): conf.chmod(0)
        env = dict(os.environ, PATH=f"{b}:/usr/bin:/bin", XDG_RUNTIME_DIR=str(d), XDG_DATA_HOME=str(d / "data"),
                   FOXML_SENTRY_UFW_CONF=str(conf), FOXML_SENTRY_UFW_DEFAULT=str(default))
        r = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, env=env, timeout=30)
        if conf.exists(): conf.chmod(0o644)
        try:
            out = json.loads(r.stdout)
        except Exception:
            out = None
        return out, marker.exists(), r


def section(tooltip, title):
    """The lines of one tooltip section ("✓ Active protections", "◇ Configured", "? Unknown")."""
    lines = tooltip.replace("\\n", "\n").split("\n")
    out, on = [], False
    for ln in lines:
        if ln.startswith(("🚨", "⚠", "✓", "◇", "?", "Click")):
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

for f in fails:
    print("FAIL", f)
print("foxml_sentry:", "OK" if not fails else f"{len(fails)} FAILED",
      f"({len(cases) + len(watcher_cases) - skipped} scenarios run" + (f", {skipped} skipped)" if skipped else ")"))
sys.exit(1 if fails else 0)
