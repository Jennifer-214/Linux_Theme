"""lock-panel: the lock screen's password field lands on a screen you can see, and a lock always happens."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "shared/bin/lock-panel"

CONF = """# foxml:hyprlock-backgrounds-begin
background {
    monitor = eDP-1
    path = ~/a.jpg
}
background {
    monitor = DP-2
    path = ~/b.jpg
}
# foxml:hyprlock-backgrounds-end
label {
    monitor = eDP-1
    text = clock
}
input-field {
    monitor = eDP-1
    size = 280, 46
}
"""


@unittest.skipUnless(shutil.which("jq"), "jq needed")
class LockPanel(unittest.TestCase):
    def setUp(self):
        # Beside the test: stand-in commands must be executable, and /tmp may be noexec.
        self.tmp = Path(tempfile.mkdtemp(prefix=".fox-lock-panel-tests-", dir=Path(__file__).parent))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin, self.run_dir, self.config = self.tmp / "bin", self.tmp / "run", self.tmp / "config"
        for d in (self.bin, self.run_dir, self.config / "hypr"):
            d.mkdir(parents=True)
        self.conf = self.config / "hypr/hyprlock.conf"
        self.conf.write_text(CONF)
        self.lid = self.tmp / "lid"
        self.lid.write_text("state:      open\n")
        self.calls = self.tmp / "hyprlock.calls"
        self.monitors([("eDP-1", True), ("DP-2", False)])
        self.shim("hyprlock", f'echo "$*" >> "{self.calls}"\nexit "${{HYPRLOCK_RC:-0}}"')

    def shim(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def monitors(self, names):
        data = [{"name": n, "focused": f, "disabled": False, "dpmsStatus": True} for n, f in names]
        (self.tmp / "monitors.json").write_text(json.dumps(data))
        self.shim("hyprctl", f'cat "{self.tmp / "monitors.json"}"')

    def run_panel(self, *args, rc=0):
        env = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.tmp), "XDG_CONFIG_HOME": str(self.config),
               "XDG_RUNTIME_DIR": str(self.run_dir), "FOX_LID_STATES": str(self.lid), "HYPRLOCK_RC": str(rc)}
        return subprocess.run(["bash", str(SCRIPT), *args], env=env, text=True, capture_output=True, timeout=10)

    def test_a_visible_pin_uses_the_deployed_config(self):
        self.assertEqual(self.run_panel().stdout.strip(), str(self.conf))
        self.assertFalse((self.run_dir / "foxml/hyprlock.conf").exists())

    def test_a_shut_lid_moves_the_panel_to_a_screen_you_can_see(self):
        self.lid.write_text("state:      closed\n")
        out = Path(self.run_panel().stdout.strip())
        self.assertEqual(out, self.run_dir / "foxml/hyprlock.conf")
        self.assertEqual(out.stat().st_mode & 0o777, 0o600)
        text = out.read_text()
        self.assertEqual(text.count("monitor = DP-2"), 3, "both panel blocks, plus DP-2's own background")
        self.assertIn("background {\n    monitor = eDP-1\n    path = ~/a.jpg", text, "backgrounds stay per monitor")
        self.assertEqual(text.replace("monitor = DP-2", "monitor = eDP-1"),
                         CONF.replace("    monitor = DP-2\n    path = ~/b.jpg", "    monitor = eDP-1\n    path = ~/b.jpg"),
                         "nothing else changes")

    def test_an_unplugged_pin_goes_to_the_focused_monitor(self):
        self.monitors([("DP-2", False), ("HDMI-A-1", True)])
        self.assertIn("monitor = HDMI-A-1", Path(self.run_panel().stdout.strip()).read_text())

    def test_any_doubt_keeps_the_deployed_config(self):
        self.lid.write_text("state:      closed\n")
        self.monitors([("eDP-1", True)])
        self.assertEqual(self.run_panel().stdout.strip(), str(self.conf), "no other screen: keep the pin")
        self.monitors([("eDP-1", False), ("DP-2;rm -rf ~", True)])
        self.assertEqual(self.run_panel().stdout.strip(), str(self.conf), "a strange monitor name is never written")
        (self.bin / "hyprctl").unlink()
        self.assertEqual(self.run_panel().stdout.strip(), str(self.conf), "no hyprctl")
        self.conf.write_text(CONF.replace("monitor = eDP-1\n    text", "monitor =\n    text").replace("monitor = eDP-1\n    size", "monitor =\n    size"))
        self.monitors([("DP-2", True)])
        self.assertEqual(self.run_panel().stdout.strip(), str(self.conf), "an unpinned panel already shows everywhere")

    def test_run_locks_with_the_right_config_and_never_skips_a_lock(self):
        self.run_panel("--run", "--grace", "2")
        self.assertEqual(self.calls.read_text().splitlines(), ["--grace 2"], "pin fine: hyprlock as today")
        self.calls.unlink()
        self.lid.write_text("state:      closed\n")
        self.run_panel("--run")
        self.assertEqual(self.calls.read_text().splitlines(), [f"-c {self.run_dir}/foxml/hyprlock.conf"])
        self.calls.unlink()
        out = self.run_panel("--run", rc=1)
        self.assertEqual(self.calls.read_text().splitlines(), [f"-c {self.run_dir}/foxml/hyprlock.conf", ""],
                         "the re-pinned lock failed at once: lock again the plain way")
        self.assertEqual(out.returncode, 1)


if __name__ == "__main__":
    unittest.main()
