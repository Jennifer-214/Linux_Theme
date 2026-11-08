"""Every shipped user unit can start, and no job has two owners.

foxml-focus-pulse.service once ran a script the installer had stopped deploying (a restart loop on a fresh
install) while fox-pulse showed the same workspace notice (two per switch on an upgraded one)."""
import glob
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPECIALS = Path(glob.glob(str(ROOT / "src/fox-ins*l/modules/specials.cpp"))[0]).read_text()
PULSE = (ROOT / "src/fox-pulse/fox-pulse.cpp").read_text()


class UserUnits(unittest.TestCase):
    def test_every_unit_runs_something_the_installer_deploys(self):
        skipped = set(re.search(r"HYPR_SKIPS\[\] = \{([^}]*)\}", SPECIALS).group(1).replace('"', "").replace(",", " ").split()) - {"nullptr"}
        for unit in sorted((ROOT / "shared/systemd_user").glob("*.service")):
            for script in re.findall(r"^ExecStart=%h/\.config/hypr/scripts/(\S+)", unit.read_text(), re.M):
                self.assertTrue((ROOT / "shared/hyprland_scripts" / script).exists(), f"{unit.name} runs {script}, which is not shipped")
                self.assertNotIn(script, skipped, f"{unit.name} runs {script}, which the installer skips")

    def test_enabled_units_are_shipped(self):
        enabled = re.search(r"for \(const char\* svc : \{([^}]*)\}\) \{\s*if \(fs::exists\(dst_root", SPECIALS).group(1)
        for unit in re.findall(r'"([^"]+)"', enabled):
            self.assertTrue((ROOT / "shared/systemd_user" / unit).exists(), unit)

    def test_the_workspace_notice_has_one_owner(self):
        self.assertFalse((ROOT / "shared/systemd_user/foxml-focus-pulse.service").exists())
        self.assertTrue((ROOT / "shared/pulse.d/focus.sh").exists(), "fox-pulse's one-shot focus handler")
        self.assertRegex(PULSE, r'FOCUS_HANDLER\s*=\s*\{\s*"focus",\s*nullptr,', "no fallback to a persistent listener")
        self.assertIn('"foxml-focus-pulse.service", "focus-pulse.sh"', SPECIALS, "upgrades retire the old unit")


if __name__ == "__main__":
    unittest.main()
