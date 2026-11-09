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

    def test_the_retired_billing_sync_is_removed_on_upgrade(self):
        for unit in ("fox-credits-sync.timer", "fox-credits-sync.service"):
            self.assertFalse((ROOT / "shared/systemd_user" / unit).exists(), unit + " is still shipped")
            self.assertRegex(SPECIALS, r'\{ "' + re.escape(unit) + r'",\s*nullptr,\s*true,', "upgrades disable and remove " + unit)


class SelfCheckRunsItself(unittest.TestCase):
    def test_installs_and_swaps_end_with_the_check_and_a_weekly_timer_runs_it(self):
        post = Path(glob.glob(str(ROOT / "src/fox-ins*l/modules/post_install.cpp"))[0]).read_text()
        self.assertIn('"--theme", ctx.theme_name', post, "post_install checks the theme it just applied")
        self.assertIn("never fails the install", post)
        unit = (ROOT / "shared/systemd_user/fox-theme-check.service").read_text()
        self.assertIn("--quiet --only D1,D6,D8,D9,D10,D11,D12", unit, "no checks that need the live session")
        self.assertIn("notify-send", unit)
        self.assertIn("OnCalendar=weekly", (ROOT / "shared/systemd_user/fox-theme-check.timer").read_text())
        self.assertIn('"fox-theme-check.timer"', SPECIALS, "enabled on install")


if __name__ == "__main__":
    unittest.main()
