"""Sessions tmux only numbered take their project's name; a private tmux server, never the user's."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "shared/bin/tmux-name-session"

# Sealed off where bwrap exists: a fresh /tmp and runtime dir, so the user's tmux server is not even reachable.
# (Only where bwrap may make namespaces: a CI container may not, and then the test's own -S socket is the guard.)
if (shutil.which("bwrap") and not os.environ.get("FOXML_TMUX_TEST_SEALED")
        and subprocess.run(["bwrap", "--dev-bind", "/", "/", "true"], capture_output=True).returncode == 0):
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    os.environ["FOXML_TMUX_TEST_SEALED"] = "1"
    os.execvp("bwrap", ["bwrap", "--dev-bind", "/", "/", "--tmpfs", "/tmp", "--tmpfs", runtime,
                        sys.executable, "-B", *sys.argv])


@unittest.skipUnless(shutil.which("tmux") and shutil.which("git"), "needs tmux and git")
class TmuxNameSession(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="tmux-name-"))
        self.home = self.work / "home"
        (self.home / "code/Linux_Theme/src").mkdir(parents=True)
        (self.home / "school/CS 303").mkdir(parents=True)
        (self.home / "notes").mkdir()
        (self.work / "repo.x").mkdir()
        subprocess.run(["git", "init", "-q", str(self.work / "repo.x")], check=True)
        sockets = self.work / "sock"
        sockets.mkdir(mode=0o700)
        # The script runs plain `tmux`, which finds its server through TMUX_TMPDIR. Everything the test runs names
        # the socket outright, and the server is stopped while its folder still exists: with the folder gone, tmux
        # falls back to the user's own server (a test that cleaned up the other way round closed every terminal).
        self.socket = sockets / f"tmux-{os.getuid()}" / "default"
        self.socket.parent.mkdir(mode=0o700)
        self.env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
        self.env.update(HOME=str(self.home), TMUX_TMPDIR=str(sockets))
        self.addCleanup(shutil.rmtree, self.work, True)    # runs last
        self.addCleanup(self.stop_server)                   # runs first

    def stop_server(self):
        if self.socket.is_socket() and self.work in self.socket.resolve().parents:
            subprocess.run(["tmux", "-S", str(self.socket), "kill-server"], capture_output=True)

    def tmux(self, *args):
        return subprocess.run(["tmux", "-S", str(self.socket), *args], env=self.env, capture_output=True, text=True).stdout.strip()

    def new(self, path, name=None):
        self.tmux("new-session", "-d", *(["-s", name] if name else []), "-c", str(path))

    def names(self):
        return sorted(self.tmux("list-sessions", "-F", "#{session_name}").splitlines())

    def test_numbered_sessions_take_their_project_and_named_ones_stay(self):
        self.new(self.home / "code/Linux_Theme/src")          # 0: inside a ~/code project (no git)
        self.new(self.home / "code/Linux_Theme")              # 1: the same project again
        self.new(self.home / "school/CS 303")                 # 2: a space becomes _
        self.new(self.work / "repo.x")                        # 3: a git repo anywhere; . becomes _
        self.new(self.home / "notes")                         # 4: no project: stays 4
        self.new(self.home / "code/Linux_Theme", "mine")      # named by you: stays
        subprocess.run([str(SCRIPT), "--all"], env=self.env, check=True)
        self.assertEqual(self.names(), ["4", "CS_303", "Linux_Theme", "Linux_Theme-2", "mine", "repo_x"])

    def test_inside_a_pane_it_names_only_that_pane_s_session(self):
        self.new(self.home / "notes")
        self.new(self.home / "notes")
        pane = self.tmux("display-message", "-p", "-t", "=1:", "#{pane_id}")
        socket = self.tmux("display-message", "-p", "#{socket_path}")
        self.assertEqual(Path(socket).resolve(), self.socket.resolve(), "the test's own server")
        env = dict(self.env, TMUX=f"{socket},1,0", TMUX_PANE=pane)
        subprocess.run([str(SCRIPT), str(self.home / "code/Linux_Theme")], env=env, check=True)
        self.assertEqual(self.names(), ["0", "Linux_Theme"])
        subprocess.run([str(SCRIPT), str(self.home / "school/CS 303")], env=env, check=True)
        self.assertEqual(self.names(), ["0", "Linux_Theme"], "once named, a later cd leaves it")

    def test_outside_tmux_it_does_nothing(self):
        self.new(self.home / "notes")
        result = subprocess.run([str(SCRIPT), str(self.home / "code/Linux_Theme")], env=self.env)
        self.assertEqual((result.returncode, self.names()), (0, ["0"]))


if __name__ == "__main__":
    unittest.main()
