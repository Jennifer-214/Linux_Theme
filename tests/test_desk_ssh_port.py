#!/usr/bin/env python3
"""desk-ssh-port reads the port sshd listens on the way the installer's ssh_port::listen_ports does (2026-11-16): its
own `sshd -T` (listenaddress lines, else port lines), then the Port lines of the SSH wizard's drop-in, then 22. desk-knock
and desk-spa take their port from it: desk-knock's awk printed every Port line, and desk-spa's chain never reached its
`echo 22`, so it denied "/tcp". Runs the real scripts with stub sudo / sshd / systemctl on PATH; nothing reaches root."""
import os, pathlib, subprocess, sys, tempfile

BIN = pathlib.Path(__file__).resolve().parent.parent / "shared/bin"
fails = []

STUBS = {
    # never escalates: runs the command as this user, so the stub sshd answers
    "sudo": '[ "$1" = -n ] && shift; [ "$1" = -v ] && exit 0; exec "$@"',
    "sshd": '[ "$1" = -T ] || exit 2; [ -n "${FAKE_SSHD_T:-}" ] && exec cat "$FAKE_SSHD_T"; echo "sshd: bad config" >&2; exit 255',
    "systemctl": "exit 3",
}


def run(script, args=(), sshd_t=None, dropin=None):
    # the stubs must be executable: /tmp can be noexec (it is on the reference machine), so default to ~/.cache
    tmp_root = os.environ.get("FOX_TEST_TMP") or str(pathlib.Path.home() / ".cache")
    os.makedirs(tmp_root, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=tmp_root) as d:
        d = pathlib.Path(d)
        b = d / "bin"
        b.mkdir()
        for name, body in STUBS.items():
            f = b / name
            f.write_text("#!/usr/bin/env bash\n" + body + "\n")
            f.chmod(0o755)
        env = dict(os.environ, PATH=f"{b}:/usr/bin:/bin", HOME=str(d), FOXML_SSH_DROPIN=str(d / "dropin.conf"))
        env.pop("FAKE_SSHD_T", None)
        if sshd_t is not None:
            (d / "sshd-T").write_text(sshd_t)
            env["FAKE_SSHD_T"] = str(d / "sshd-T")
        if dropin is not None:
            (d / "dropin.conf").write_text(dropin)
        r = subprocess.run(["bash", str(BIN / script), *args], capture_output=True, text=True, env=env, timeout=30)
        return r.stdout


def expect(what, ok):
    if not ok:
        fails.append(what)


MOVED = "port 4022\naddressfamily any\nlistenaddress [::]:4022\nlistenaddress 0.0.0.0:4022\npasswordauthentication no\n"
BOTH = "port 4022\nport 22\nlistenaddress 0.0.0.0:4022\nlistenaddress 0.0.0.0:22\n"
expect("sshd -T: the port it binds", run("desk-ssh-port", sshd_t=MOVED) == "4022\n")
expect("sshd -T: v4 and v6 are one port", run("desk-ssh-port", ["--all"], sshd_t=MOVED) == "4022\n")
expect("several ports, the wizard's first", run("desk-ssh-port", sshd_t=BOTH) == "4022\n")
expect("--all lists each", run("desk-ssh-port", ["--all"], sshd_t=BOTH) == "4022\n22\n")
expect("a ListenAddress with its own port wins over Port",
       run("desk-ssh-port", sshd_t="port 22\nlistenaddress 192.168.1.5:2200\n") == "2200\n")
expect("port lines when there are no sockets listed", run("desk-ssh-port", sshd_t="port 2222\n") == "2222\n")
expect("not ports: skipped", run("desk-ssh-port", sshd_t="port 0\nport 70000\nport 22x\n", dropin="Port 4444\n") == "4444\n")
expect("sshd -T fails: the wizard's drop-in", run("desk-ssh-port", dropin="# x\nPort 4022\nPort 22\n") == "4022\n")
expect("sshd -T fails: every Port line with --all", run("desk-ssh-port", ["--all"], dropin="Port 4022\nPort 22\n") == "4022\n22\n")
expect("nothing to read: 22, never empty", run("desk-ssh-port") == "22\n")
# --no-sudo is for the bar's security pill, which polls every 15 s and never calls sudo: the stub sudo would hand back
# sshd -T's 4022, so the drop-in's port proves it was not asked.
expect("--no-sudo: the drop-in, sudo never asked", run("desk-ssh-port", ["--no-sudo"], sshd_t=MOVED, dropin="Port 2202\n") == "2202\n")
expect("--no-sudo --all: every Port line", run("desk-ssh-port", ["--no-sudo", "--all"], sshd_t=MOVED, dropin="Port 2202\nPort 22\n") == "2202\n22\n")
expect("--no-sudo, nothing to read: 22", run("desk-ssh-port", ["--no-sudo"], sshd_t=MOVED) == "22\n")
expect("a drop-in without a Port line: 22", run("desk-ssh-port", dropin="PasswordAuthentication no\n") == "22\n")

knock = run("desk-knock", ["--status"], sshd_t=MOVED, dropin="Port 9999\n")
expect(f"desk knock --status shows sshd's port (got {knock!r})", "ssh port: 4022\n" in knock)
spa = run("desk-spa", ["--status"], sshd_t=BOTH)
expect(f"desk spa --status shows one port, the wizard's (got {spa!r})", "ssh port: 4022\n" in spa and "ssh port: 4022\n22" not in spa)
spa_none = run("desk-spa", ["--status"])
expect(f"desk spa --status: 22 when nothing says otherwise, never empty (got {spa_none!r})", "ssh port: 22\n" in spa_none)

for f in fails:
    print("FAIL", f)
print(f"desk-ssh-port: {'OK' if not fails else f'{len(fails)} FAILED'}")
sys.exit(1 if fails else 0)
