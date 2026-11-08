"""Exercise the real battery script against a disposable sysfs-shaped fixture."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BatteryDoodleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=".battery-doodle-", dir=ROOT / "tests")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.supplies = self.base / "power"
        self.battery = self.supplies / "BAT0"
        self.adapter = self.supplies / "AC"
        self.battery.mkdir(parents=True)
        self.adapter.mkdir()
        self.bin = self.base / "bin"
        self.config = self.base / "config"
        self.bin.mkdir()
        for name, body in {
            "pactl": '#!/bin/sh\ncase "$1" in get-sink-volume) echo "Volume: 50%";; get-sink-mute) echo "Mute: no";; esac\n',
            "brightnessctl": '#!/bin/sh\ncase "$1" in m) echo 100;; *) echo 50;; esac\n',
        }.items():
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)
        source = (ROOT / "shared/waybar_scripts/battery.sh").read_text()
        self.script = self.base / "battery.sh"
        self.script.write_text(source.replace("/sys/class/power_supply", str(self.supplies)))

    def read_state(self, status, capacity=80, connected=True):
        for name, value in {"capacity":capacity, "status":status, "power_now":10000000,
                            "energy_now":30000000,"energy_full":50000000,"charge_control_end_threshold":80}.items():
            (self.battery / name).write_text(str(value))
        (self.adapter / "type").write_text("Mains")
        (self.adapter / "online").write_text("1" if connected else "0")
        env = os.environ | {"PATH": str(self.bin) + os.pathsep + os.defpath, "XDG_RUNTIME_DIR": str(self.base), "HOME": str(self.base), "XDG_CONFIG_HOME": str(self.config), "C_DETAIL_ACCENT": ""}
        result = subprocess.run(["/bin/bash",str(self.script)],env=env,capture_output=True,text=True,check=True)
        return json.loads(result.stdout)

    def test_charging_has_doodle_and_keeps_numbers(self):
        state = self.read_state("Charging")
        self.assertTrue(state["text"].startswith("ϟ "))
        self.assertIn("80% +10W", state["text"])
        self.assertEqual(state["class"], "charging")

    def test_threshold_hold_is_not_drawn_as_charging(self):
        state = self.read_state("Not charging")
        self.assertNotIn("ϟ", state["text"])
        self.assertEqual(state["class"], "plugged")
        self.assertIn("holding at 80%", state["tooltip"])

    def test_holding_at_the_charge_limit_fills_the_heart(self):
        state = self.read_state("Not charging")
        self.assertTrue(state["text"].startswith("✓ "))

    def test_full_fills_the_heart(self):
        state = self.read_state("Full", capacity=100)
        self.assertTrue(state["text"].startswith("✓ "))

    def test_not_charging_below_the_limit_has_no_heart(self):
        state = self.read_state("Not charging", capacity=60)
        self.assertNotIn("✓", state["text"])
        self.assertNotIn("ϟ", state["text"])

    def test_filled_heart_uses_the_palette_accent(self):
        palette = self.config / "hypr/modules/border_colors.sh"
        palette.parent.mkdir(parents=True)
        palette.write_text('export C_DETAIL_ACCENT="ab12cd"\n')
        state = self.read_state("Not charging")
        self.assertTrue(state["text"].startswith("<span foreground='#ab12cd'>✓</span> "))

    def test_only_heart_uses_rendered_palette_accent(self):
        palette = self.config / "hypr/modules/border_colors.sh"
        palette.parent.mkdir(parents=True)
        palette.write_text('export C_DETAIL_ACCENT="ab12cd"\n')
        state = self.read_state("Charging")
        self.assertTrue(state["text"].startswith("<span foreground='#ab12cd'>ϟ</span> "))
        self.assertEqual(state["text"].count('<span'), 1)
        self.assertIn('80% +10W',state['text'])
        self.assertNotIn('<span',state['tooltip'])

    def test_unusable_palette_accent_keeps_plain_heart(self):
        palette = self.config / "hypr/modules/border_colors.sh"
        palette.parent.mkdir(parents=True)
        palette.write_text('export C_DETAIL_ACCENT="not-a-color"\n')
        state = self.read_state("Charging")
        self.assertTrue(state["text"].startswith("ϟ "))
        self.assertNotIn('<span',state['text'])

    def test_unplugged_critical_still_has_critical_class(self):
        state = self.read_state("Discharging", capacity=5, connected=False)
        self.assertEqual(state["class"], "critical")
        self.assertNotIn("ϟ", state["text"])

    def test_failed_charger_keeps_drain_warning(self):
        for _ in range(3): state = self.read_state("Discharging")
        self.assertEqual(state["class"], "plugged-drain")
        self.assertNotIn("ϟ", state["text"])


if __name__ == "__main__":
    unittest.main()
