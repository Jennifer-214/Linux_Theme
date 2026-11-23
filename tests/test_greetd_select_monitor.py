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
# Monitors get IDs in list order. regreet opens on the 3rd look (or never: no_regreet) on monitor 0, fullscreen; a
# window.move puts it on the moved-to monitor, and with yank_once its own late fullscreen request takes it back once.
dir=$(dirname "$0")
case "$1" in
  monitors)
    n=$(cat "$dir/calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$dir/calls"
    [ "$n" -le "$(cat "$dir/empty_for")" ] && exit 0
    i=0; for m in $(cat "$dir/outputs"); do printf 'Monitor %s (ID %s):\n\t1920x1080@60 at 0x0\n' "$m" "$i"; i=$((i + 1)); done ;;
  eval)
    [ -f "$dir/nolua" ] && { echo "unknown request"; exit 1; }
    case "$2" in
      "return 1") echo ok ;;
      *window.move*)
        echo "$2" >> "$dir/evals"
        i=0; for m in $(cat "$dir/outputs"); do case "$2" in *"\"$m\""*) echo "$i" > "$dir/regreet_on" ;; esac; i=$((i + 1)); done
        [ -f "$dir/yank_once" ] && { rm "$dir/yank_once"; echo 0 > "$dir/yank_next"; } ;;
      *) echo "$2" >> "$dir/evals" ;;
    esac ;;
  dispatch|keyword) echo "$*" >> "$dir/evals" ;;
  clients)
    n=$(cat "$dir/client_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$dir/client_calls"
    [ -f "$dir/no_regreet" ] || [ "$n" -lt 3 ] && exit 0
    [ -f "$dir/yank_next" ] && { mv "$dir/yank_next" "$dir/regreet_on"; }
    printf 'Window 55 -> regreet:\n\tmonitor: %s\n\tclass: apps.regreet\n\tfullscreen: 2\n' "$(cat "$dir/regreet_on" 2>/dev/null || echo 0)" ;;
esac
'''

# The picker logs to the journal; the stand-in keeps the lines in the test folder instead.
LOGGER = r'''#!/bin/sh
shift 2
echo "$*" >> "$(dirname "$0")/journal"
'''


class SelectMonitor(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))   # not /tmp: noexec
        base.mkdir(parents=True, exist_ok=True)
        self.dir = Path(tempfile.mkdtemp(prefix="select-monitor-test-", dir=base))
        stub = self.dir / "hyprctl"
        stub.write_text(HYPRCTL)
        stub.chmod(0o755)
        logger = self.dir / "logger"
        logger.write_text(LOGGER)
        logger.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def pick(self, outputs, empty_for, lua=True, regreet_opens=True, yank_once=False, lid="open"):
        if not lua:
            (self.dir / "nolua").write_text("")
        if not regreet_opens:
            (self.dir / "no_regreet").write_text("")
        if yank_once:
            (self.dir / "yank_once").write_text("")
        (self.dir / "outputs").write_text(" ".join(outputs))
        (self.dir / "empty_for").write_text(str(empty_for))
        (self.dir / "lid/LID0").mkdir(parents=True)
        (self.dir / "lid/LID0/state").write_text(f"state:      {lid}\n")
        env = {"PATH": f"{self.dir}:/usr/bin:/bin", "GREETER_LID_DIR": str(self.dir / "lid")}
        started = time.monotonic()
        # The background mover keeps the output pipes open, so this returns once it is done too.
        r = subprocess.run(["sh", str(PICKER)], env=env, capture_output=True, text=True, timeout=25)
        evals = (self.dir / "evals").read_text().splitlines() if (self.dir / "evals").exists() else []
        journal = self.dir / "journal"
        self.journal = journal.read_text().splitlines() if journal.exists() else []
        return r.returncode, evals, time.monotonic() - started

    # 2026-11-19: switching the externals off left the login screen black on her NVIDIA laptop ("Flip event timeout on
    # head 2" in both boots): a screen turned off while a frame was on its way. The picker now only moves the focus to
    # the panel, where regreet opens; every screen stays on, nothing changes state.
    # 2026-11-22: the focus alone did not hold on her laptop (the login came up on a vertical external, DP-2): regreet
    # goes fullscreen on the first screen by itself. The test VM showed only a move after it opens puts it elsewhere.
    def test_late_outputs_put_the_login_on_the_laptop_panel_and_switch_nothing_off(self):
        rc, evals, _ = self.pick(["DP-2", "HDMI-A-1", "eDP-1"], empty_for=3)
        self.assertEqual(rc, 0)
        self.assertEqual(evals, [
            'hl.dispatch(hl.dsp.focus({ monitor = "eDP-1" }))',
            'hl.dispatch(hl.dsp.window.move({ monitor = "eDP-1", window = "class:^(apps\\\\.regreet)$" }))',
        ])
        self.assertFalse([e for e in evals if "disable" in e], "no screen is switched off")
        self.assertEqual(len(self.journal), 2)
        self.assertIn("DP-2 HDMI-A-1 eDP-1 - focus on eDP-1", self.journal[0])
        self.assertEqual(self.journal[1], "regreet on eDP-1 (moved 1 times)")

    # The fresh-boot VM run: regreet's own fullscreen request came after the move and took it back to the first screen.
    def test_a_regreet_that_jumps_back_is_moved_again(self):
        rc, evals, _ = self.pick(["DP-2", "HDMI-A-1", "eDP-1"], empty_for=0, yank_once=True)
        self.assertEqual(rc, 0)
        self.assertEqual(evals.count('hl.dispatch(hl.dsp.window.move({ monitor = "eDP-1", window = "class:^(apps\\\\.regreet)$" }))'), 2)
        self.assertEqual(self.journal[-1], "regreet on eDP-1 (moved 2 times)")

    def test_a_regreet_that_never_opens_moves_nothing_and_the_wait_ends(self):
        rc, evals, took = self.pick(["HDMI-A-1", "eDP-1"], empty_for=0, regreet_opens=False)
        self.assertEqual((rc, evals), (0, ['hl.dispatch(hl.dsp.focus({ monitor = "eDP-1" }))']))
        self.assertIn("not settled on eDP-1 after 15 s (moved 0 times, last seen: not open)", self.journal[-1])
        self.assertLess(took, 20)

    # A docked laptop with the lid shut still lists its panel; moving the login there would leave it on a dark screen.
    def test_a_closed_lid_leaves_the_login_where_it_is(self):
        rc, evals, _ = self.pick(["DP-2", "HDMI-A-1", "eDP-1"], empty_for=0, lid="closed")
        self.assertEqual((rc, evals), (0, []))
        self.assertIn("lid closed; nothing changed", self.journal[-1])

    def test_a_laptop_alone_is_not_moved(self):
        rc, evals, _ = self.pick(["eDP-1"], empty_for=0)
        self.assertEqual((rc, evals), (0, ['hl.dispatch(hl.dsp.focus({ monitor = "eDP-1" }))']))
        self.assertEqual(self.journal[-1], "regreet on eDP-1 (moved 0 times)")

    def test_an_older_hyprland_gets_the_same_focus_by_its_own_command(self):
        rc, evals, _ = self.pick(["HDMI-A-1", "eDP-1"], empty_for=0, lua=False)
        self.assertEqual((rc, evals), (0, ["dispatch focusmonitor eDP-1"]))
        self.assertFalse((self.dir / "client_calls").exists(), "no Lua move on an older Hyprland")

    def test_a_desktop_without_a_panel_changes_nothing_and_does_not_wait_long(self):
        rc, evals, took = self.pick(["DP-1", "HDMI-A-1"], empty_for=0)
        self.assertEqual((rc, evals), (0, []))
        self.assertLess(took, 2)
        self.assertEqual(len(self.journal), 1)
        self.assertIn("no laptop panel", self.journal[0])

    def test_no_outputs_at_all_gives_up_and_changes_nothing(self):
        rc, evals, took = self.pick(["DP-1"], empty_for=10_000)
        self.assertEqual((rc, evals), (0, []))
        self.assertLess(took, 10, "bounded: the greeter starts anyway")


if __name__ == "__main__":
    unittest.main()
