#!/usr/bin/env python3
"""foxml_sentry.sh says only what it can verify, and never calls sudo (2026-10-23; plans/2026-10-23-waybar-sentry-
nosudo.md). Runs the real script with stub systemctl / findmnt / fprintd-list / ip / sudo on PATH and temp UFW files:
- sudo is never invoked (its stub leaves a marker), and the output is valid JSON, in every scenario;
- UFW egress deny shows as CONFIGURED (not verified live), outside the active-protection count;
- an unreadable or incomplete config shows "unknown", never a silent off;
- a WireGuard interface is "present", never "up" or "connected"; a failing `ip` shows "unknown"."""
import json, os, pathlib, stat, subprocess, sys, tempfile

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "shared/waybar_scripts/foxml_sentry.sh"
fails = []


def run(ufw_conf, ufw_default, ip_script, unreadable=False, ufw_unit_active=False):
    # the stubs must be executable: /tmp can be noexec (it is on the reference machine), so default to ~/.cache
    tmp_root = os.environ.get("FOX_TEST_TMP") or str(pathlib.Path.home() / ".cache")
    os.makedirs(tmp_root, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=tmp_root) as d:
        d = pathlib.Path(d); b = d / "bin"; b.mkdir()
        marker = d / "sudo-called"
        stubs = {"systemctl": ('[[ "$*" == *" ufw" ]] && exit 0; exit 3' if ufw_unit_active else "exit 3"), "findmnt": "exit 1", "fprintd-list": "exit 1", "ip": ip_script,
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
for name, conf, default, ip, unreadable, want in cases:
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
for f in fails:
    print("FAIL", f)
print("foxml_sentry:", "OK" if not fails else f"{len(fails)} FAILED", f"({len(cases)} scenarios)")
sys.exit(1 if fails else 0)
