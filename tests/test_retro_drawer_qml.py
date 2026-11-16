"""Load the drawer, bar and level slip on retro-amber's render, so the text-mode branches run without QML errors."""
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
    function testFind(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        var children = item.children || [];
        for (var i = 0; i < children.length; i++) { var found = testFind(children[i], name); if (found) return found; }
        var content = item.contentItem;
        return content && content !== item ? testFind(content, name) : null;
    }
    function testRowText(index) {
        var row = itemList.itemAtIndex(index);
        var text = row ? testFind(row, "retro-row-text") : null;
        return text ? text.text : "";
    }
    Timer { interval: 900; running: true; onTriggered: {
        if (!root.retro || !retroFrame.visible || !root.drawerHost) throw new Error("retro frame missing");
        if (retroFrame.frameWidth % 8 || retroFrame.frameHeight % 12) throw new Error("frame is not whole cells");
        if (testFind(retroFrame, "text-frame-top").edge.indexOf("╔═[ SOUND ]═") !== 0) throw new Error("frame title: " + testFind(retroFrame, "text-frame-top").edge);
        if (!testFind(retroFrame, "text-frame-divider").visible) throw new Error("no │ between the groups and the page");
        if (retroPrompt.text !== "C:\\DESK\\SOUND>") throw new Error("prompt: " + retroPrompt.text);
        if (root.entries.length !== 3) throw new Error("sound page did not load");
        var volume = testRowText(0);
        if (!/^Volume \.+ \[█+░+\]  42%$/.test(volume)) throw new Error("slider row: " + volume);
        if (!/^Softer light \.+ \[ \]$/.test(testRowText(1))) throw new Error("toggle row: " + testRowText(1));
        var row = itemList.itemAtIndex(0);
        if (!Qt.colorEqual(row.color, theme.ink) || row.border.width !== 0 || row.height !== 12) throw new Error("selected row is not inverse video");
        if (Logic.symbol({id: "wifi"}) !== "\u{F05A9}" || Logic.symbol({id: "x", icon: "⌁"}) !== "\u{F05A9}") throw new Error("retro glyphs missing");
        if (retroFrame.footer.indexOf("j/k Move") < 0 || retroFrame.footerAlert) throw new Error("status line: " + retroFrame.footer);
        root.activate(root.entries[0]);
        root.adjust(5);
        if (!/\[█+░+\]  47%$/.test(testRowText(0)) || retroFrame.footer.indexOf("h/l Adjust") < 0) throw new Error("slider edit: " + testRowText(0));
        root.goBack();
        root.note("all set.");
        if (retroFrame.footer !== " OK.") throw new Error("message did not replace the hints: " + retroFrame.footer);
        root.note("broken", true);
        if (!retroFrame.footerAlert) throw new Error("an error is not shown in normal video");
        root.note("");
        levelSlip.showVolume(62, false);
        var line = testFind(levelSlip.artwork, "level-slip-retro-line");
        if (!line || !/\[█+░+\]  62%$/.test(line.text)) throw new Error("level slip: " + (line ? line.text : "none"));
        levelSlip.showMedia("A song", "An artist", "Playing", "");
        if (testFind(levelSlip.artwork, "level-slip-retro-line").text.indexOf("♪ A song - An artist") !== 0) throw new Error("media slip");
    }}
    // The slider's write has finished by now, so the drawer takes another action.
    Timer { interval: 1300; running: true; onTriggered: {
        root.activate({id: "drive-eject", label: "Eject drive", kind: "action", confirm: "Eject this drive?"});
        if (!retroConfirm.visible || root.confirmYes) throw new Error("retro confirmation missing");
        root.step(1);
        if (!root.confirmYes) throw new Error("confirmation choice did not move");
        root.goBack();
        root.focusArea = "groups";
        root.groupIndex = 2;
        root.show("root");
    }}
    Timer { interval: 2100; running: true; onTriggered: {
        if (root.page !== "root" || !testFind(todaySheet, "today-date").visible) throw new Error("today page");
        var window = desktopBar.item.windows[0];
        var updates = testFind(window.moduleContainer, "bar-module-custom/updates");
        if (!updates || !updates.retroAlert || !testFind(updates, "bar-module-alert").visible) throw new Error("warning not in normal video");
        if (!testFind(window.moduleContainer, "bar-divider")) throw new Error("bar dividers missing");
        var tag = testFind(todaySheet, "today-tag-0");
        if (!tag || tag.implicitHeight !== 12 || tag.radius !== 0 && tag.color.a > 0 && !Qt.colorEqual(tag.color, theme.ink)) throw new Error("today tag is not one text line");
        root.show("screenshots");
    }}
    // The scrapbook is a DIR listing, one file a line, no pictures.
    Timer { interval: 2700; running: true; onTriggered: {
        var listing = testFind(scrapbookSheet, "scrapbook-listing");
        if (!listing || !listing.visible || scrapbookSheet.columns !== 1) throw new Error("scrapbook is not a listing");
        var first = testFind(listing.itemAtIndex(0), "scrapbook-file");
        if (!first || !/^ LITTLE~1 PNG    11-05-26   2:30p$/.test(first.text)) throw new Error("scrapbook row: " + (first ? JSON.stringify(first.text) : "none"));
        if (testFind(scrapbookSheet, "scrapbook-image-0") && testFind(scrapbookSheet, "scrapbook-image-0").visible) throw new Error("a picture is showing");
        root.show("garden");
    }}
    // The garden is block characters; the busiest days wear a ♦ (no hearts in retro).
    Timer { interval: 3400; running: true; onTriggered: {
        var today = testFind(gardenSheet, "garden-day-" + (gardenSheet.counts.length - 1));
        var mark = today ? testFind(today, "garden-retro-day") : null;
        if (!mark || !mark.visible || ["·", "░", "▒", "▓", "█", "♦", "*"].indexOf(mark.text) < 0) throw new Error("garden day: " + (mark ? mark.text : "none"));
        if (!gardenSheet.retroShades || gardenSheet.dayH !== 12) throw new Error("garden is off the cell grid");
        root.hide();
        polkitPrompt.testFlow = fakeFlow;
    }}
    QtObject {
        id: fakeFlow
        property string actionId: "org.freedesktop.login1.reboot-multiple-sessions"
        property string message: "Authentication is required to reboot the system."
        property string inputPrompt: "Password: "
        property bool responseVisible: false
        property bool isResponseRequired: true
        property string supplementaryMessage: ""
        property bool supplementaryIsError: false
        signal authenticationFailed()
        function submit(value) {}
        function cancelAuthenticationRequest() {}
    }
    Timer { interval: 3800; running: true; onTriggered: {
        var slip = testFind(polkitPrompt.window.contentItem, "polkit-slip");
        if (!slip || slip.width % 8 || slip.height % 12 || slip.x % 1) throw new Error("permission box is off the grid");
        if (!testFind(slip, "polkit-retro-buttons").visible || testFind(slip, "polkit-allow").visible) throw new Error("permission buttons");
        if (testFind(slip, "text-frame-top").edge.indexOf("╔═[ PERMISSION ]") !== 0) throw new Error("permission title: " + testFind(slip, "text-frame-top").edge);
        polkitPrompt.testFlow = null;
        console.log("RETRO_DRAWER_OK"); Qt.quit();
    }}
'''


FONT = Path("/usr/share/fonts/TTF/BigBlueTerm437NerdFontMono-Regular.ttf")
DUMP = r"""
import fs from 'node:fs'; import vm from 'node:vm';
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(process.argv.at(-1), 'utf8').replace(/^\.pragma library\s*/, ''), context);
const marks = [Object.values(context.retroGlyphs), Object.values(context.retroChars), Object.values(context.retroWords),
    ['Current date is', '0 File(s)', '[ ] [X] (•) ◄┘ ► <DIR>', 'C:\\DESK>', '╔═╗║╚╝╟╢─┬┴│♪', context.retroBar(50, 4),
     context.retroHints('items', 'project'), context.retroHints('calendar', ''), context.retroHints('search', '')]];
console.log(JSON.stringify(marks.flat().join('')));
"""


class RetroGlyphs(unittest.TestCase):
    @unittest.skipUnless(shutil.which("node") and FONT.exists(), "node and Big Blue Term are required")
    def test_every_retro_mark_is_in_the_font(self):
        try:
            from fontTools.ttLib import TTFont
        except ImportError:
            self.skipTest("fontTools is required")
        text = json.loads(subprocess.run(["node", "--input-type=module", "-", str(ROOT / "shared/quickshell/desk/DrawerLogic.js")],
                                         input=DUMP, text=True, capture_output=True, check=True).stdout)
        cmap = TTFont(str(FONT)).getBestCmap()
        missing = sorted({ch for ch in text if not ch.isspace() and ord(ch) not in cmap})
        self.assertEqual(missing, [], "drawn by a fallback font, off the 8x12 grid")


@unittest.skipUnless(shutil.which("quickshell"), "Quickshell is required")
class RetroDrawer(unittest.TestCase):
    def test_text_mode_drawer_bar_and_slip(self):
        renderer = ROOT / "src/desk-render/desk-render-fast"
        if not renderer.exists():
            self.skipTest("build desk-render-fast first")
        with tempfile.TemporaryDirectory(prefix="retro-drawer-") as tmp:
            work = Path(tmp); qml = work / "qml"
            shutil.copytree(ROOT / "shared/quickshell/desk", qml)
            subprocess.run([str(renderer), str(ROOT / "themes/retro-amber/palette.sh"), str(ROOT / "templates/quickshell/desk"), str(qml)],
                           check=True, capture_output=True)
            self.assertIn('style: "retro"', (qml / "Theme.qml").read_text())
            config = work / "config/waybar"; config.mkdir(parents=True)
            layout = {"modules-left": ["custom/logo"], "modules-center": [], "modules-right": ["custom/updates", "custom/clock"],
                      "custom/clock": {"format": "Sun 09:09", "on-click": "desktop-menu calendar"},
                      "custom/logo": {"format": "C:\\>", "on-click": "desktop-menu root"},
                      "custom/updates": {"exec": "true", "return-type": "json", "on-click": "desktop-menu updates"}}
            for name in ["config", "config_secondary"]:
                (config / name).write_text(json.dumps(layout))
            fixture = work / "fixture.json"
            fixture.write_text(json.dumps({"custom/updates": {"text": "↑ 4", "tooltip": "4 updates", "classes": ["warning"]}}))
            for name, pattern in [("LevelSlip.qml", r"^    (?:anchors.*|margins\..*|exclusionMode:.*|WlrLayershell\..*)\n"),
                                  ("Overview.qml", r"^        (?:anchors \{.*|exclusionMode:.*|WlrLayershell\..*)\n"),
                                  ("PolkitPrompt.qml", r"^        (?:anchors \{.*|exclusionMode:.*|WlrLayershell\..*)\n")]:
                source = (qml / name).read_text().replace("PanelWindow {", "FloatingWindow {")
                if name == "PolkitPrompt.qml":  # a full-screen layer in a session; give the stand-in window a screen's size
                    source = source.replace("FloatingWindow {", "FloatingWindow {\n        implicitWidth: 1280; implicitHeight: 800", 1)
                (qml / name).write_text(re.sub(pattern, "", source, flags=re.M))
            source = (qml / "shell.qml").read_text().replace("    PanelWindow {", "    FloatingWindow {")
            source = re.sub(r"^        (?:anchors \{.*|margins \{.*|exclusionMode:.*|WlrLayershell\..*)\n", "", source, flags=re.M)
            source = source.replace("screen ? screen.width : 1280", "1280").replace("screen ? screen.height : 800", "1080")
            (qml / "shell.qml").write_text(source.rsplit("\n}", 1)[0] + EXERCISE + "\n}\n")
            source = (qml / "PaperBar.qml").read_text().replace("PanelWindow {", "FloatingWindow {\n            implicitWidth: 1280")
            source = re.sub(r"^\s*(?:anchors \{ top: true; left: true; right: true \}|exclusiveZone:.*|WlrLayershell\..*|IdleInhibitor \{.*)\n",
                            "\n", source, flags=re.M)
            (qml / "PaperBar.qml").write_text(source)
            runtime = work / "runtime"; runtime.mkdir(mode=0o700)
            env = os.environ | {"QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "software", "XDG_RUNTIME_DIR": str(runtime),
                "XDG_CONFIG_HOME": str(work / "config"), "XDG_CACHE_HOME": str(work / "cache"), "XDG_STATE_HOME": str(work / "state"),
                "FOXML_DRAWER_PREVIEW": "1", "FOXML_BAR_AUTOSTART": "1", "FOXML_BAR_FIXTURE": str(fixture),
                "FOXML_DRAWER_BACKEND": str(ROOT / "tests/drawer-ui-backend.py"), "FOXML_DRAWER_TEST_LOG": str(work / "actions"),
                "FOXML_DRAWER_BAR_STATE": str(work / "drawer-state.css"), "QS_NO_RELOAD_POPUP": "1",
                # The polkit prompt stops and starts the session's hyprpolkitagent; never from a test.
                "FOXML_POLKIT_PROMPT": "off"}
            env.pop("WAYLAND_DISPLAY", None); env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
            try:
                result = subprocess.run(["quickshell", "-p", str(qml), "--no-color"], env=env, capture_output=True, text=True, timeout=25)
            except subprocess.TimeoutExpired as stuck:
                self.fail("the exercise never finished:\n" + (stuck.stdout or b"").decode() + (stuck.stderr or b"").decode())
            log = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, log)
            self.assertIn("RETRO_DRAWER_OK", log)
            for error in ["TypeError", "ReferenceError", "Unable to assign", "Binding loop", "Error:"]:
                self.assertNotIn(error, log)


if __name__ == "__main__":
    unittest.main()
