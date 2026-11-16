"""The back keys: ALT+Backspace returns to the window you were in before (Hyprland, both config twins), and
Ctrl+a Backspace to the tmux session you were in before. The tmux half presses the key on a private server, sealed
away from the user's own (see tests/test_tmux_name_session.py for why); the since page's half is
tests/test_nvim_since.py."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / "src/desk-render/desk-render-fast"
sys.path.insert(0, str(ROOT / "tests"))
from test_hyprland_lua import conf_binds, lua_binds  # noqa: E402

# (Only where bwrap may make namespaces: a CI container may not, and then the test's own -S socket is the guard.)
if (shutil.which("bwrap") and not os.environ.get("FOXML_TMUX_TEST_SEALED")
        and subprocess.run(["bwrap", "--dev-bind", "/", "/", "true"], capture_output=True).returncode == 0):
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    os.environ["FOXML_TMUX_TEST_SEALED"] = "1"
    os.execvp("bwrap", ["bwrap", "--dev-bind", "/", "/", "--tmpfs", "/tmp", "--tmpfs", runtime,
                        sys.executable, "-B", *sys.argv])


class WindowBack(unittest.TestCase):
    def test_alt_backspace_focuses_the_window_before_in_both_twins(self):
        mods = ROOT / "shared/hyprland_modules"
        key = (frozenset({"ALT"}), "backspace", "", frozenset())
        lua = (mods / "keybinds.lua").read_text()
        self.assertIn(key, lua_binds(lua))
        self.assertIn('hl.bind(mainMod .. " + BackSpace", hl.dsp.focus({ last = true }))', lua)
        self.assertIn(key, conf_binds((mods / "keybinds.conf").read_text()))
        self.assertIn("bind = $mainMod, BackSpace, focuscurrentorlast", (mods / "keybinds.conf").read_text())


@unittest.skipUnless(shutil.which("tmux") and shutil.which("script") and RENDER.exists(), "needs tmux, script and desk-render-fast")
class SessionBack(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="back-keys-"))
        sockets = self.work / "sock"
        sockets.mkdir(mode=0o700)
        self.socket = sockets / f"tmux-{os.getuid()}" / "default"
        self.socket.parent.mkdir(mode=0o700)
        self.env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE", "HYPRLAND_INSTANCE_SIGNATURE")}
        self.env.update(TMUX_TMPDIR=str(sockets), HOME=str(self.work))
        self.addCleanup(shutil.rmtree, self.work, True)    # last
        self.addCleanup(self.stop_server)                   # first

    def stop_server(self):
        if self.socket.is_socket() and self.work in self.socket.resolve().parents:
            subprocess.run(["tmux", "-S", str(self.socket), "kill-server"], capture_output=True, env=self.env)

    def tmux(self, *args):
        return subprocess.run(["tmux", "-S", str(self.socket), *args], env=self.env, capture_output=True, text=True,
                              timeout=10).stdout.strip()

    def test_prefix_backspace_goes_back_to_the_session_before(self):
        rendered = self.work / "render"
        subprocess.run([str(RENDER), str(ROOT / "themes/Paper/palette.sh"), str(ROOT / "templates/tmux"), str(rendered)],
                       check=True, capture_output=True, timeout=60)
        conf = rendered / ".tmux.conf"
        self.tmux("-f", str(conf), "new-session", "-d", "-s", "first")
        self.tmux("new-session", "-d", "-s", "second")
        self.assertIn("switch-client -l", self.tmux("list-keys", "-T", "prefix", "BSpace"))
        client = subprocess.Popen(["script", "-qfc", f"tmux -S {self.socket} attach -t first", "/dev/null"], env=self.env,
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(client.wait, 10)
        self.addCleanup(client.kill)
        name = ""
        for _ in range(100):
            name = self.tmux("list-clients", "-F", "#{client_name}")
            if name:
                break
            time.sleep(0.05)
        self.assertTrue(name, "the client never attached")
        self.tmux("switch-client", "-c", name, "-t", "second")
        self.assertEqual(self.tmux("display", "-p", "-c", name, "#{client_session}"), "second")
        self.tmux("send-keys", "-K", "-c", name, "C-a", "BSpace")
        for _ in range(40):
            if self.tmux("display", "-p", "-c", name, "#{client_session}") == "first":
                break
            time.sleep(0.05)
        self.assertEqual(self.tmux("display", "-p", "-c", name, "#{client_session}"), "first", "Ctrl+a Backspace went nowhere")


if __name__ == "__main__":
    unittest.main()
