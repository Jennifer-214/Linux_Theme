"""Exercise the production QML content offscreen against a harmless fixture backend.

PanelWindow needs a compositor backend. Replacing only that window adapter with
FloatingWindow lets the actual content and input handlers run on Qt's software renderer.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

EXERCISE = r'''
    Timer {
        interval: 700; running: true
        onTriggered: {
            if (root.groups.length !== 5 || root.entries.length !== 3) throw new Error("views missing");
            root.step(1);
            if (root.itemIndex !== 1) throw new Error("j does not advance");
            root.step(1);
            if (root.itemIndex !== 0) throw new Error("disabled row was selectable");
            root.activate(root.entries[0]);
            root.adjust(5);
            if (!root.editing || root.draftValue !== 47) throw new Error("slider did not adjust");
            root.goBack();
            if (root.editing || !root.opened) throw new Error("slider Escape closed panel");
            root.itemIndex = 1;
        }
    }
    Timer {
        interval: 1300; running: true
        onTriggered: {
            root.activate({id: "poweroff", label: "Power off", kind: "action", confirm: true});
            if (!root.pendingConfirm || root.confirmYes) throw new Error("confirmation must default to cancel");
            root.goBack();
            root.startSearch();
            searchInput.text = "hjkl";
            var event = {key: Qt.Key_H, modifiers: 0, accepted: false}; root.key(event);
            if (event.accepted || !root.searching || searchInput.text !== "hjkl") throw new Error("search stole typing");
            root.goBack();
            if (root.searching || !root.opened) throw new Error("search Escape closed panel");
            root.applyView(root.viewSerial, root.page,
                JSON.stringify({title:"Partial",items:[{id:"unavailable",kind:"slider",enabled:false},{id:"usable",kind:"action"}],error:"state unavailable"}), 1, "");
            if (root.entries.length !== 2 || !root.failed || root.entries[root.itemIndex].id !== "usable") throw new Error("partial page was discarded");
            root.hide();
            if (root.opened) throw new Error("close did not hide panel");
            console.log("DRAWER_UI_ASSERTIONS_PASSED");
            Qt.quit();
        }
    }
'''


@unittest.skipUnless(shutil.which("quickshell"), "Quickshell is not installed")
class DrawerQmlTest(unittest.TestCase):
    def test_navigation_search_slider_capture_and_partial_errors(self):
        with tempfile.TemporaryDirectory(prefix="foxml-drawer-qml-") as tmp:
            directory = Path(tmp)
            for name in ("runtime", "cache", "state"):
                (directory / name).mkdir(mode=0o700)
            source = (ROOT / "shared/quickshell/foxml/shell.qml").read_text()
            source = source.replace("    PanelWindow {", "    FloatingWindow {")
            source = re.sub(r"^        (?:anchors \{.*|margins \{.*|exclusionMode:.*|WlrLayershell\..*)\n", "", source, flags=re.M)
            source = source.rsplit("\n}", 1)[0] + EXERCISE + "\n}\n"
            (directory / "shell.qml").write_text(source)
            shutil.copyfile(ROOT / "shared/quickshell/foxml/DrawerLogic.js", directory / "DrawerLogic.js")
            renderer = ROOT / "src/fox-render/fox-render-fast"
            render = str(renderer) if renderer.exists() else shutil.which("fox-render-fast")
            if not render:
                self.skipTest("build fox-render-fast before running the QML smoke test")
            subprocess.run([render, str(ROOT / "themes/FoxML_Paper/palette.sh"),
                            str(ROOT / "templates/quickshell/foxml"), str(directory)], check=True, capture_output=True)
            (directory / "menus.json").write_text("{}")
            actions = directory / "actions.jsonl"
            env = os.environ | {
                "QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "software",
                "XDG_RUNTIME_DIR": str(directory / "runtime"), "XDG_CACHE_HOME": str(directory / "cache"),
                "XDG_STATE_HOME": str(directory / "state"), "QS_NO_RELOAD_POPUP": "1",
                "FOXML_DRAWER_PREVIEW": "1", "FOXML_DRAWER_BACKEND": str(ROOT / "tests/drawer-ui-backend.py"),
                "FOXML_DRAWER_TEST_LOG": str(actions),
            }
            env.pop("WAYLAND_DISPLAY", None)
            result = subprocess.run(["quickshell", "--path", str(directory), "--no-color"],
                                    env=env, text=True, capture_output=True, timeout=12)
            log = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, log)
            self.assertIn("DRAWER_UI_ASSERTIONS_PASSED", log)
            self.assertNotIn("TypeError", log)
            self.assertNotIn("ReferenceError", log)
            self.assertEqual([json.loads(line) for line in actions.read_text().splitlines()], [["run", "volume", "47"]])


if __name__ == "__main__":
    unittest.main()
