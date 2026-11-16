#!/usr/bin/env python3
"""desk-bouncer alerts when usbguard blocks or rejects a device while the screen is locked (2026-11-15).

It matched BLOCK|REJECT, in capitals, anywhere in the line; usbguard writes target.new='block', so in 30 days of real
journal it never fired. Runs the real `desk-bouncer run` with stub journalctl (the usbguard journal in
tests/fixtures/usbguard-journal.txt, plus one case line), pgrep (the screen locker) and desk-dispatch on PATH:
- the fixture alone raises nothing: allow decisions, a Device.Insert whose rule says block, a blocked device being
  allowed, a device named "BLOCK REJECT Receiver";
- target.new='block', 'reject' and an upper-case 'BLOCK' each raise one alert that names the device;
- a block while the screen is unlocked raises nothing; two blocks in one second raise one alert;
- desk-dispatch failing: the alert still shows, through notify-send."""
import os, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "shared/bin/desk-bouncer"
FIXTURE = ROOT / "tests/fixtures/usbguard-journal.txt"


def decision(target, old="block", name="Keyboard", vid="1234:abcd", port="3-9"):
    """A policy decision line shaped like usbguard's own (see the fixture)."""
    return (f"uid=0 pid=779 result='SUCCESS' device.system_name='/devices/pci0000:00/0000:00:14.0/usb3/{port}' "
            f"target.new='{target}' device.rule='block id {vid} serial \"\" name \"{name}\" hash \"fixture-keyboard\" "
            f"parent-hash \"fixture-parent\" via-port \"{port}\" with-interface {{ 03:01:01 03:00:00 }} "
            f"with-connect-type \"hotplug\"' target.old='{old}' type='Policy.Device.Update'")


def run(extra, locked=True, dispatch_fails=False):
    # The stubs must be executable: /tmp can be noexec (it is on the reference machine), so default to ~/.cache.
    tmp_root = os.environ.get("FOX_TEST_TMP") or str(pathlib.Path.home() / ".cache")
    os.makedirs(tmp_root, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=tmp_root) as d:
        d = pathlib.Path(d); b = d / "bin"; b.mkdir()
        journal, sent = d / "journal.txt", d / "sent"
        journal.write_text(FIXTURE.read_text() + "".join(line + "\n" for line in extra))
        stubs = {
            # The usbguard unit's journal, as `journalctl -u usbguard.service -o cat` prints it.
            "journalctl": f'[[ "$*" == *"-u usbguard.service"* && "$*" == *"-o cat"* ]] || exit 1; cat "{journal}"',
            "pgrep": f'[[ "$*" == "-x hyprlock" && "{int(locked)}" == 1 ]]',
            "desk-dispatch": "exit 1" if dispatch_fails else f'printf "%s\\t%s\\n" "$1" "$2" >> "{sent}"',
            "notify-send": f'printf "notify-send\\t%s\\n" "$*" >> "{sent}"',
        }
        for name, body in stubs.items():
            f = b / name; f.write_text("#!/usr/bin/env bash\n" + body + "\n"); f.chmod(0o755)
        env = dict(os.environ, PATH=f"{b}:/usr/bin:/bin", HOME=str(d))
        r = subprocess.run(["bash", str(SCRIPT), "run"], capture_output=True, text=True, env=env, timeout=30)
        return (sent.read_text().splitlines() if sent.exists() else []), r


fails = []
cases = [
    ("the fixture alone", [], True, []),
    ("target.new='block'", [decision("block")], True, ["usbguard blocked 1234:abcd \"Keyboard\" on port 3-9"]),
    ("target.new='reject'", [decision("reject", old="allow")], True, ["usbguard rejected 1234:abcd \"Keyboard\" on port 3-9"]),
    ("upper case BLOCK", [decision("BLOCK")], True, ["usbguard blocked 1234:abcd"]),
    ("a block while unlocked", [decision("block")], False, []),
    ("two blocks in one second", [decision("block"), decision("block", name="Second")], True, ["\"Keyboard\""]),
]
for name, extra, locked, want in cases:
    sent, r = run(extra, locked)
    if r.returncode != 0:
        fails.append(f"{name}: exit {r.returncode}: {r.stderr[-200:]!r}")
    if len(sent) != len(want):
        fails.append(f"{name}: {len(sent)} alerts, expected {len(want)}: {sent}")
        continue
    for line, text in zip(sent, want):
        title, _, body = line.partition("\t")
        if title != "USB blocked (screen LOCKED)":
            fails.append(f"{name}: alert title {title!r}")
        if text not in body:
            fails.append(f"{name}: {text!r} not in the alert body {body!r}")

sent, r = run([decision("block")], dispatch_fails=True)
want = 'notify-send\t-u critical -t 10000 USB blocked (locked) usbguard blocked 1234:abcd "Keyboard" on port 3-9'
if r.returncode != 0 or sent != [want]:
    fails.append(f"desk-dispatch failing: exit {r.returncode}, expected only the notify-send fallback {want!r}, got {sent}")
for f in fails:
    print("FAIL", f)
print("desk-bouncer:", "OK" if not fails else f"{len(fails)} FAILED", f"({len(cases) + 1} scenarios)")
sys.exit(1 if fails else 0)
