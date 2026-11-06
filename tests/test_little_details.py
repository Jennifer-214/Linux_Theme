#!/usr/bin/env python3
"""Paper's small touches: the waking cat, workspace paw and lock-screen hearts."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QML = ROOT / "shared/quickshell/foxml"


class LittleDetails(unittest.TestCase):
    def test_cat_follows_the_idle_inhibitor_only_on_paper(self):
        module = (QML / "BarModule.qml").read_text()
        self.assertIn('catPill: name === "idle_inhibitor" && theme.paperDetails', module)
        self.assertIn("awake: module.dataSource.idleEnabled", module)
        self.assertIn("!module.catPill", module)
        cat = (QML / "CatNap.qml").read_text()
        self.assertRegex(cat, r"if \(!awake\)")
        self.assertRegex(cat, r"if \(awake\)")

    def test_paw_marks_only_the_active_workspace_on_paper(self):
        bar = (QML / "BarWorkspaces.qml").read_text()
        self.assertIn("visible: tab.current && workspaces.theme.paperDetails", bar)

    def test_only_paper_types_hearts(self):
        for palette in sorted((ROOT / "themes").glob("*/palette.sh")):
            style = re.search(r"^HYPRLOCK_DOTS_STYLE='?([^'\n]*)", palette.read_text(), re.M)
            hearts = bool(style) and "♡" in style.group(1)
            self.assertEqual(hearts, palette.parent.name == "FoxML_Paper", palette.parent.name)


if __name__ == "__main__":
    unittest.main()
