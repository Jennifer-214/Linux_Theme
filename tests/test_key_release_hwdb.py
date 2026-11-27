#!/usr/bin/env python3
"""The ThinkPad SysRq rule (shared/udev/61-desk-key-release.hwdb), compiled by systemd-hwdb into a throwaway root.

On a ThinkPad, Fn+S (SysRq, scan code 0x54) left held down makes Hyprland 0.57 drop the first key after every
modifier. The rule must parse strictly, give a ThinkPad's built-in keyboard KEYBOARD_KEY_54=!sysrq, and give nothing to
a Lenovo IdeaPad, a Dell, or a ThinkPad's USB keyboard.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RULE = ROOT / "shared/udev/61-desk-key-release.hwdb"
HWDB = shutil.which("systemd-hwdb")

THINKPAD = ("evdev:atkbd:dmi:bvnLENOVO:bvrN37ET51W(1.32):bd01/30/2024:br1.32:efr1.15:svnLENOVO:pn20YRS28202:"
            "pvrThinkPadP15Gen2i:rvnLENOVO:rn20YRS28202:rvrSDK0J40697WIN:cvnLENOVO:ct10:cvrNone:")
IDEAPAD = "evdev:atkbd:dmi:bvnLENOVO:bvrGLCN50WW:bd05/01/2023:svnLENOVO:pn82FG:pvrIdeaPad514ALC05:rvnLENOVO:"
DELL = "evdev:atkbd:dmi:bvnDellInc.:bvr1.2.3:bd01/01/2024:svnDellInc.:pnXPS13:pvr:rvnDellInc.:"
USB = "evdev:input:b0003v17EFp6047e0111-e0,1,4,11,14"


@unittest.skipUnless(HWDB, "needs systemd-hwdb")
class KeyReleaseRule(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        (cls.root / "etc/udev/hwdb.d").mkdir(parents=True)
        shutil.copy(RULE, cls.root / "etc/udev/hwdb.d" / RULE.name)
        cls.update = subprocess.run([HWDB, "update", "--strict", f"--root={cls.root}"], capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def query(self, modalias):
        run = subprocess.run([HWDB, "query", f"--root={self.root}", modalias], capture_output=True, text=True)
        return run.stdout.strip()

    def test_the_rule_parses_strictly(self):
        self.assertEqual(self.update.returncode, 0, self.update.stdout + self.update.stderr)

    def test_a_thinkpad_keyboard_releases_sysrq(self):
        self.assertEqual(self.query(THINKPAD), "KEYBOARD_KEY_54=!sysrq")

    def test_other_keyboards_are_left_alone(self):
        for name, modalias in (("IdeaPad", IDEAPAD), ("Dell", DELL), ("USB keyboard", USB)):
            with self.subTest(name):
                self.assertEqual(self.query(modalias), "")


if __name__ == "__main__":
    unittest.main()
