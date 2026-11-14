#!/usr/bin/env python3
"""tests/test_theme_tweak.py — shared/bin/theme-tweak stops when the re-render fails.

Runs the real script against a throwaway checkout (FOXML_DIR) whose render binary and hyprctl are stubs.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TWEAK = ROOT / "shared/bin/theme-tweak"


def stub(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(0o755)


class ThemeTweakTest(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))   # not /tmp: noexec
        base.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix="theme-tweak-test-", dir=base))
        self.repo, self.bin, self.log = self.tmp / "repo", self.tmp / "bin", self.tmp / "log"
        (self.repo / "themes/Demo").mkdir(parents=True)
        (self.repo / "themes/Demo/palette.sh").write_text("ROUNDING=8\n")
        (self.repo / ".active-theme").write_text("Demo")
        stub(self.bin / "hyprctl", f'echo "hyprctl $*" >> "{self.log}"')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def tweak(self, render_exit):
        stub(self.repo / "src/desk-install/desk-install",
             f'echo "render sync_skip=$FOXML_SKIP_PLUGIN_SYNC" >> "{self.log}"; exit {render_exit}')
        env = {"HOME": str(self.tmp), "FOXML_DIR": str(self.repo), "PATH": f"{self.bin}:/usr/bin:/bin",
               "LANG": "C.UTF-8"}
        r = subprocess.run(["bash", str(TWEAK), "--rounding", "12"], env=env, capture_output=True, text=True,
                           timeout=30)
        return r.returncode, r.stderr, self.log.read_text() if self.log.exists() else ""

    def test_failed_render_stops_before_reload(self):
        rc, err, log = self.tweak(1)
        self.assertEqual(rc, 1)
        self.assertIn("failed", err)
        self.assertNotIn("hyprctl", log)

    def test_render_skips_plugin_sync_and_reloads(self):
        rc, _, log = self.tweak(0)
        self.assertEqual(rc, 0)
        self.assertEqual(log.splitlines(), ["render sync_skip=1", "hyprctl reload"])


if __name__ == "__main__":
    unittest.main()
