"""One drawer, however many callers start it at once: desktop-menu's start and the login's starters.

Sealed: a stand-in Quickshell answers the drawer's calls; PATH holds only it, the scripts under test and the few system
programs they run; HOME, XDG_CONFIG_HOME and XDG_RUNTIME_DIR are private folders. No compositor, no real Quickshell.
"""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

# The stand-in: a start is written down and answers once it has been up STUB_READY_AFTER seconds, as a drawer does
# when its QML has loaded, or (STUB_READY_CALLS) from that many status calls on, however long each call takes; every
# IPC call is written down too.
QUICKSHELL = r'''#!/usr/bin/python3
import json, os, sys, time
state = os.environ["STUB_STATE"]
args = sys.argv[1:]
def note(name, line):
    with open(os.path.join(state, name), "a") as log:
        log.write(line + "\n")
if "ipc" in args:
    call = args[args.index("call") + 1:]
    note("calls", " ".join(call))
    ready = os.path.exists(os.path.join(state, "ready"))
    if os.environ.get("STUB_READY_CALLS"):
        with open(os.path.join(state, "calls")) as log:
            asked = sum(1 for line in log if line.split()[1:2] == ["status"])
        ready = os.path.exists(os.path.join(state, "starts")) and asked >= int(os.environ["STUB_READY_CALLS"])
    if not ready:
        sys.exit(1)
    if call[1:2] == ["status"]:
        print(json.dumps({"open": False}))
    sys.exit(0)
note("starts", str(os.getpid()))
if os.environ.get("STUB_READY_CALLS"):
    sys.exit(0)
time.sleep(float(os.environ.get("STUB_READY_AFTER", "2")))
open(os.path.join(state, "ready"), "w").close()
'''


class DrawerStart(unittest.TestCase):
    def setUp(self):
        # The stand-ins are executed, and /tmp is noexec on these machines.
        temp = tempfile.TemporaryDirectory(prefix=".desk-drawer-start-", dir=ROOT / "tests")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("bash", "setsid", "flock", "sleep", "env", "python3"):
            program = shutil.which(name)
            self.assertIsNotNone(program, name)
            (self.bin / name).symlink_to(program)
        (self.bin / "desktop-menu").symlink_to(ROOT / "shared/bin/desktop-menu")
        self.stub("quickshell", QUICKSHELL)
        self.stub("desk-drawer", "#!/bin/sh\nexit 0\n")
        config = self.root / "config/quickshell/desk"
        config.mkdir(parents=True)
        for name in ("shell.qml", "Theme.qml", "menus.json"):
            (config / name).write_text("")
        runtime = self.root / "runtime"
        runtime.mkdir(mode=0o700)
        self.env = {"PATH": str(self.bin), "HOME": str(self.root), "XDG_CONFIG_HOME": str(self.root / "config"),
                    "XDG_RUNTIME_DIR": str(runtime), "STUB_STATE": str(self.state), "LANG": "C.UTF-8"}
        self.addCleanup(self.stop_stand_ins)

    def stub(self, name, body):
        path = self.bin / name
        path.unlink(missing_ok=True)  # never write through a link to the real program or the repo's script
        path.write_text(body)
        path.chmod(0o755)

    def lines(self, name):
        path = self.state / name
        return path.read_text().splitlines() if path.exists() else []

    def stop_stand_ins(self):
        """The stand-in drawers are detached (setsid -f); each one ends by itself, and none outlives the test."""
        deadline = time.monotonic() + 6
        for pid in (int(line) for line in self.lines("starts")):
            while time.monotonic() < deadline and Path(f"/proc/{pid}").exists():
                time.sleep(0.05)
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

    def run_menus(self, *calls, **stand_in):
        env = self.env | {"STUB_READY_AFTER": "2"} | stand_in
        started = [subprocess.Popen([str(self.bin / "desktop-menu"), *call], env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True) for call in calls]
        results = []
        for process in started:
            out, err = process.communicate(timeout=40)
            results.append((process.returncode, out + err))
        return results

    def test_callers_at_once_start_one_drawer(self):
        # A first login: the bar's start, the session's and the first-launch tour's, all before the drawer answers.
        results = self.run_menus(["--start"], ["--start"], ["--open", "cheatsheet"])
        self.assertEqual([code for code, _ in results], [0, 0, 0], results)
        self.assertEqual(len(self.lines("starts")), 1, "each caller that found the drawer silent started another")
        self.assertIn("drawer open cheatsheet", self.lines("calls"), "the tour's page never opened")

    def test_a_slow_drawer_is_waited_for(self):
        # Answering only at the 45th look: giving up after 30 (three seconds) failed the bar's start, so Waybar came up
        # as a second bar, and let the next caller start a second drawer.
        results = self.run_menus(["--start"], STUB_READY_CALLS="45")
        self.assertEqual(results[0][0], 0, results)
        self.assertEqual(len(self.lines("starts")), 1)

    def test_a_running_drawer_is_not_started_again(self):
        (self.state / "ready").touch()
        results = self.run_menus(["--start"], ["--open", "sound"])
        self.assertEqual([code for code, _ in results], [0, 0], results)
        self.assertEqual(self.lines("starts"), [])

    def test_the_login_starts_the_drawer_once_through_the_bar(self):
        scripts = self.root / ".config/hypr/scripts"
        scripts.mkdir(parents=True)
        log = self.state / "login"
        for name in ("start_waybar.sh", "border_telemetry.sh", "update_check.sh"):
            path = scripts / name
            path.write_text(f'#!/bin/bash\nprintf "%s\\n" "{name}" >> "{log}"\n')
            path.chmod(0o755)
        self.stub("desktop-menu", f'#!/bin/bash\nprintf "desktop-menu %s\\n" "$*" >> "{log}"\n')
        self.stub("desk-hl", f'#!/bin/bash\nprintf "desk-hl\\n" >> "{log}"\n')
        self.stub("sleep", "#!/bin/bash\nexit 0\n")
        subprocess.run([str(self.bin / "bash"), str(ROOT / "shared/hyprland_scripts/startup.sh")], env=self.env,
                       check=True, timeout=10, capture_output=True)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and len(set(self.lines("login"))) < 4:
            time.sleep(0.05)
        calls = self.lines("login")
        self.assertIn("start_waybar.sh", calls)
        self.assertEqual([line for line in calls if line.startswith("desktop-menu")], [],
                         "the session started the drawer beside the bar's start (desk-bar start brings it up)")


if __name__ == "__main__":
    unittest.main()
