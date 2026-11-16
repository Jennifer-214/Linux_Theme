#!/usr/bin/env python3
"""desk-dispatch shows an alert on this desktop when no webhook is set up (2026-11-15).

It wrote the ledger line and returned 0, so the watchers' `|| notify-send` fallbacks never ran and a trip reached no
one. Runs the real script with stub notify-send and curl first on PATH (nothing reaches a real desktop or network):
- no webhook: one critical notice from FoxML with the title, the body escaped for mako's markup, exit 0;
- DESK_DISPATCH_LOCAL=0 (a caller that shows its own notice): no notice, exit 0;
- notify-send failing: a non-zero exit, so the caller's own fallback runs;
- started without a session bus address (from root via sudo): the notice finds $XDG_RUNTIME_DIR/bus;
- a webhook that answers: no desktop notice; a config with loose permissions is refused, and the alert shows here;
- the ledger gets the line every time;
- audit-timer, which shows its own drift notice, sends both of its desk-dispatch calls with DESK_DISPATCH_LOCAL=0
  (run with stub desk-doctor, desk-dispatch and notify-send): drift is one desktop notice, a clean week none."""
import os, pathlib, socket, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "shared/bin/desk-dispatch"
AUDIT_TIMER = ROOT / "shared/bin/audit-timer"
fails = []


def run(case, conf=None, conf_mode=0o600, local=None, notify_rc=0, bus=False, title="tripwire HIT",
        body="PID 4242 (cat) read <tripwire> & more"):
    # The stubs must be executable: /tmp can be noexec (it is on the reference machine), so default to ~/.cache.
    tmp_root = os.environ.get("FOX_TEST_TMP") or str(pathlib.Path.home() / ".cache")
    os.makedirs(tmp_root, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=tmp_root) as d:
        d = pathlib.Path(d); b = d / "bin"; b.mkdir()
        home, runtime = d / "home", d / "run"
        home.mkdir(); runtime.mkdir(mode=0o700)
        notes, posts = d / "notes", d / "posts"
        stubs = {
            # One block per call: the bus address it saw, then each argument on its own line.
            "notify-send": f'{{ echo "bus=${{DBUS_SESSION_BUS_ADDRESS:-}}"; printf "%s\\n" "$@"; echo "<end of call>"; }} >> "{notes}"; exit {notify_rc}',
            "curl": f'echo "$*" >> "{posts}"; printf 204',
        }
        for name, body_ in stubs.items():
            f = b / name; f.write_text("#!/usr/bin/env bash\n" + body_ + "\n"); f.chmod(0o755)
        if conf is not None:
            (home / ".config/foxml").mkdir(parents=True)
            c = home / ".config/foxml/dispatch.conf"; c.write_text(conf); c.chmod(conf_mode)
        sock = None
        if bus:
            sock = socket.socket(socket.AF_UNIX); sock.bind(str(runtime / "bus"))
        env = {k: v for k, v in os.environ.items() if k != "DBUS_SESSION_BUS_ADDRESS"}
        env.update(PATH=f"{b}:/usr/bin:/bin", HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
                   XDG_DATA_HOME=str(d / "data"), USER="tester")
        if not bus:
            env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/run/user/test/bus"
        if local is not None:
            env["DESK_DISPATCH_LOCAL"] = local
        r = subprocess.run(["bash", str(SCRIPT), title, body], capture_output=True, text=True, env=env,
                           timeout=30, stdin=subprocess.DEVNULL)
        if sock:
            sock.close()
        calls = [blk.strip("\n").split("\n") for blk in notes.read_text().split("<end of call>\n") if blk.strip()] if notes.exists() else []
        ledger = (d / "data/foxml/alerts.log").read_text() if (d / "data/foxml/alerts.log").exists() else ""
        if f"\t{title}\t{body}\n" not in ledger:
            fails.append(f"{case}: the ledger has no line for the alert: {ledger!r}")
        return r.returncode, calls, posts.read_text() if posts.exists() else ""


def expect(case, ok, detail=""):
    if not ok:
        fails.append(f"{case}{': ' + detail if detail else ''}")


def audit(report):
    """`audit-timer run` on a desk doctor report: the desk-dispatch calls (with the DESK_DISPATCH_LOCAL each saw) and
    the notify-send calls, in order."""
    tmp_root = os.environ.get("FOX_TEST_TMP") or str(pathlib.Path.home() / ".cache")
    os.makedirs(tmp_root, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=tmp_root) as d:
        d = pathlib.Path(d); b = d / "bin"; b.mkdir(); (d / "home").mkdir()
        calls, doctor = d / "calls", d / "report"
        doctor.write_text(report)
        stubs = {
            "desk-doctor": f'cat "{doctor}"',
            "desk-dispatch": f'printf "desk-dispatch LOCAL=%s|%s|%s\\n" "${{DESK_DISPATCH_LOCAL-unset}}" "$1" "$2" >> "{calls}"',
            "notify-send": f'printf "notify-send|%s\\n" "$*" >> "{calls}"',
        }
        for name, body_ in stubs.items():
            f = b / name; f.write_text("#!/usr/bin/env bash\n" + body_ + "\n"); f.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if k != "DESK_DISPATCH_LOCAL"}
        env.update(PATH=f"{b}:/usr/bin:/bin", HOME=str(d / "home"))
        r = subprocess.run(["bash", str(AUDIT_TIMER), "run"], capture_output=True, text=True, env=env, timeout=30,
                           stdin=subprocess.DEVNULL)
        return r.returncode, calls.read_text().splitlines() if calls.exists() else []


rc, calls, _ = run("no webhook")
expect("no webhook: exit 0", rc == 0, f"exit {rc}")
expect("no webhook: one desktop notice", len(calls) == 1, f"{calls}")
if calls:
    args = calls[0][1:]
    expect("no webhook: from FoxML, critical, category foxml.alert",
           {"--app-name=FoxML", "--urgency=critical", "--category=foxml.alert"} <= set(args), f"{args}")
    expect("no webhook: title then the body, escaped for mako's markup",
           args[-2:] == ["tripwire HIT", "PID 4242 (cat) read &lt;tripwire&gt; &amp; more"], f"{args[-2:]}")

rc, calls, _ = run("DESK_DISPATCH_LOCAL=0", local="0")
expect("DESK_DISPATCH_LOCAL=0: exit 0", rc == 0, f"exit {rc}")
expect("DESK_DISPATCH_LOCAL=0: no desktop notice", not calls, f"{calls}")

rc, calls, _ = run("notify-send fails", notify_rc=1)
expect("notify-send fails: non-zero exit so the caller's fallback runs", rc != 0, f"exit {rc}")

rc, calls, _ = run("no bus address", bus=True)
expect("no bus address: the notice finds the session bus under XDG_RUNTIME_DIR",
       len(calls) == 1 and calls[0][0].startswith("bus=unix:path=") and calls[0][0].endswith("/run/bus"), f"{calls}")

rc, calls, posts = run("webhook", conf="WEBHOOK_KIND=discord\nWEBHOOK_URL=https://discord.com/api/webhooks/0/test\n")
expect("webhook: exit 0", rc == 0, f"exit {rc}")
expect("webhook: posted", "discord.com/api/webhooks/0/test" in posts, f"{posts!r}")
expect("webhook: no desktop notice as well", not calls, f"{calls}")

rc, calls, posts = run("loose config", conf="WEBHOOK_KIND=discord\nWEBHOOK_URL=https://discord.com/api/webhooks/0/test\n",
                       conf_mode=0o644)
expect("loose config: refused, nothing posted", not posts, f"{posts!r}")
expect("loose config: the alert shows on this desktop", len(calls) == 1 and rc == 0, f"exit {rc}, {calls}")

# Without DESK_DISPATCH_LOCAL=0, desk-dispatch with no webhook would show each call on this desktop as well.
rc, calls = audit("  ✓ ufw: active\n  X fail2ban: not running\n")
expect("audit-timer drift: exit 0", rc == 0, f"exit {rc}")
expect("audit-timer drift: the phone copy with DESK_DISPATCH_LOCAL=0, then its own desktop notice",
       len(calls) == 2 and calls[0].startswith("desk-dispatch LOCAL=0|weekly-audit|desk doctor: 1 FAILED")
       and calls[1].startswith("notify-send|") and "desk doctor: 1 FAILED" in calls[1], f"{calls}")

rc, calls = audit("  ✓ ufw: active\n")
expect("audit-timer clean: exit 0", rc == 0, f"exit {rc}")
expect("audit-timer clean: the heartbeat with DESK_DISPATCH_LOCAL=0, and no desktop notice",
       len(calls) == 1 and calls[0].startswith("desk-dispatch LOCAL=0|weekly-audit|desk doctor: clean"), f"{calls}")

for f in fails:
    print("FAIL", f)
print("desk-dispatch:", "OK" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
