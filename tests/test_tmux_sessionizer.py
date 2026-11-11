"""What the Ctrl+A w popup lists: sessions by name with what runs there, projects under a heading; a private tmux
server only, sealed away from the user's own (see tests/test_tmux_name_session.py for why)."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "shared/bin/tmux-sessionizer"

if shutil.which("bwrap") and not os.environ.get("FOXML_TMUX_TEST_SEALED"):
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    os.environ["FOXML_TMUX_TEST_SEALED"] = "1"
    os.execvp("bwrap", ["bwrap", "--dev-bind", "/", "/", "--tmpfs", "/tmp", "--tmpfs", runtime,
                        sys.executable, "-B", *sys.argv])


@unittest.skipUnless(shutil.which("tmux"), "needs tmux")
class Sessionizer(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="sesh-"))
        self.home = self.work / "home"
        for d in ("code/Paper", "code/_scratch_x", "code/deprecated", "code/Busy", "school/CS_303"):
            (self.home / d).mkdir(parents=True)
        sockets = self.work / "sock"
        sockets.mkdir(mode=0o700)
        self.socket = sockets / f"tmux-{os.getuid()}" / "default"
        self.socket.parent.mkdir(mode=0o700)
        self.env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE", "HYPRLAND_INSTANCE_SIGNATURE")}
        self.env.update(HOME=str(self.home), TMUX_TMPDIR=str(sockets), FOX_SESH_C1="", FOX_SESH_C2="")
        self.addCleanup(shutil.rmtree, self.work, True)    # last
        self.addCleanup(self.stop_server)                   # first

    def stop_server(self):
        if self.socket.is_socket() and self.work in self.socket.resolve().parents:
            subprocess.run(["tmux", "-S", str(self.socket), "kill-server"], capture_output=True)

    def tmux(self, *args):
        return subprocess.run(["tmux", "-S", str(self.socket), *args], env=self.env, capture_output=True, text=True).stdout

    def test_sessions_say_what_runs_there_and_projects_sit_under_a_heading(self):
        self.tmux("new-session", "-d", "-s", "Busy", "-c", str(self.home / "code/Busy"))
        self.tmux("new-window", "-t", "=Busy:", "-c", str(self.home / "code/Busy"))
        self.tmux("new-session", "-d", "-s", "notes", "-c", str(self.home))
        listed = subprocess.run([str(SCRIPT), "--list"], env=self.env, capture_output=True, text=True, timeout=20).stdout
        rows = [re.sub(r"\x1b\[[0-9;]*m", "", line).split("\t") for line in listed.splitlines()]
        sessions = {r[2]: r[1] for r in rows if r[0] == "s"}
        self.assertRegex(sessions["Busy"], r"Busy · a shell · 2 windows$")
        self.assertRegex(sessions["notes"], r"notes · a shell$")
        kinds = [r[0] for r in rows]
        self.assertEqual(kinds.count("h"), 1, "one heading over the projects")
        self.assertLess(kinds.index("s"), kinds.index("h"))
        projects = [r[1].split()[-1] for r in rows if r[0] == "d"]
        self.assertEqual(sorted(projects), ["CS_303", "Paper"], "open sessions, scratch and deprecated folders are not offered")
        self.assertEqual(subprocess.run([str(SCRIPT), "--preview", "h\tx\t"], env=self.env, capture_output=True, text=True).stdout, "",
                         "a heading has no preview")


if __name__ == "__main__":
    unittest.main()
