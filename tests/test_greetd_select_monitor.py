#!/usr/bin/env python3
"""tests/test_greetd_select_monitor.py — the greeter's monitor picker with a stand-in hyprctl.

Hyprland 0.57 runs shared/greetd_select_monitor.sh from hyprland.start, which can come before its outputs are listed.
On 2026-11-15 that left every monitor on and the login screen on the leftmost one. The picker now waits for a settled
list. The stand-in reports no monitors for the first calls, then the laptop panel and two externals.
"""
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PICKER = ROOT / "shared/greetd_select_monitor.sh"

HYPRCTL = r'''#!/bin/sh
dir=$(dirname "$0")
case "$1" in
  monitors)
    n=$(cat "$dir/calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$dir/calls"
    [ "$n" -le "$(cat "$dir/empty_for")" ] && exit 0
    for m in $(cat "$dir/outputs"); do printf 'Monitor %s (ID 0):\n\t1920x1080@60 at 0x0\n' "$m"; done ;;
  eval)
    case "$2" in
      "return 1") echo ok ;;
      *) echo "$2" >> "$dir/evals" ;;
    esac ;;
esac
'''


class SelectMonitor(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))   # not /tmp: noexec
        base.mkdir(parents=True, exist_ok=True)
        self.dir = Path(tempfile.mkdtemp(prefix="select-monitor-test-", dir=base))
        stub = self.dir / "hyprctl"
        stub.write_text(HYPRCTL)
        stub.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def pick(self, outputs, empty_for):
        (self.dir / "outputs").write_text(" ".join(outputs))
        (self.dir / "empty_for").write_text(str(empty_for))
        env = {"PATH": f"{self.dir}:/usr/bin:/bin"}
        started = time.monotonic()
        r = subprocess.run(["sh", str(PICKER)], env=env, capture_output=True, text=True, timeout=15)
        evals = (self.dir / "evals").read_text().splitlines() if (self.dir / "evals").exists() else []
        return r.returncode, evals, time.monotonic() - started

    def test_late_outputs_still_leave_only_the_laptop_panel_on(self):
        rc, evals, _ = self.pick(["DP-2", "HDMI-A-1", "eDP-1"], empty_for=3)
        self.assertEqual(rc, 0)
        self.assertEqual(evals, ['hl.monitor({ output = "DP-2", disabled = true })',
                                 'hl.monitor({ output = "HDMI-A-1", disabled = true })'])

    def test_a_desktop_without_a_panel_changes_nothing_and_does_not_wait_long(self):
        rc, evals, took = self.pick(["DP-1", "HDMI-A-1"], empty_for=0)
        self.assertEqual((rc, evals), (0, []))
        self.assertLess(took, 2)

    def test_no_outputs_at_all_gives_up_and_changes_nothing(self):
        rc, evals, took = self.pick(["DP-1"], empty_for=10_000)
        self.assertEqual((rc, evals), (0, []))
        self.assertLess(took, 10, "bounded: the greeter starts anyway")


if __name__ == "__main__":
    unittest.main()
