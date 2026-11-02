"""Waybar can render without Quickshell and preserves an existing drawer marker."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WaybarStartupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="foxml-bar-startup-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bar = self.home / ".config/waybar"
        self.bar.mkdir(parents=True)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        # Keep this a headless render: no live compositor tools or desktop processes.
        for name in ("sed", "awk", "tr", "mktemp", "ln", "rm"):
            executable = shutil.which(name)
            self.assertIsNotNone(executable, name)
            (self.bin / name).symlink_to(executable)
        (self.bar / "style.css.tmpl").write_text('@import "drawer-state.css";\n* { font-size: __FONT_BASE__pt; }\n')
        (self.bar / "config.tmpl").write_text('{"height":__HEIGHT__,"margin":"__MARGIN_BAR__"}\n')

    def render(self):
        env = os.environ | {"HOME": str(self.home), "PATH": str(self.bin)}
        subprocess.run(["/bin/bash", str(ROOT / "shared/hyprland_scripts/start_waybar.sh"), "--render-only"],
                       env=env, capture_output=True, text=True, check=True, timeout=10)
        self.assertEqual(json.loads((self.bar / "config").read_text())["height"], 34)
        self.assertIn("font-size: 10pt", (self.bar / "style.css").read_text())
        self.assertEqual(list(self.bar.glob(".drawer-state.*")), [])

    def test_initializes_missing_state_without_a_drawer_installation(self):
        self.render()
        self.assertEqual((self.bar / "drawer-state.css").read_bytes(), b"")

    def test_existing_drawer_marker_survives_repeated_rendering(self):
        marker = "#custom-logo { box-shadow: inset 0 -1px @peach; }\n"
        path = self.bar / "drawer-state.css"
        path.write_text(marker)
        self.render()
        self.render()
        self.assertEqual(path.read_text(), marker)

    def test_dangling_user_symlink_is_left_untouched(self):
        target = self.home / "unavailable.css"
        path = self.bar / "drawer-state.css"
        path.symlink_to(target)
        self.render()
        self.assertTrue(path.is_symlink())
        self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
