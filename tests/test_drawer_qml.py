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
        interval: 450; running: true
        onTriggered: {
            var entries = root.entries, page = root.page;
            root.entries = [];
            root.page = "library";
            root.pageLoading = false;
            root.drawerReady = true;
            if (!emptyNote.visible) throw new Error("empty page is not showing");
            groupProcess.running = true;
            if (!emptyNote.visible) {
                console.error("A background refresh blinked the empty page");
                Qt.exit(1);
                return;
            }
            root.pageLoading = true;
            if (emptyNote.visible) throw new Error("a page still loading showed its empty state");
            root.pageLoading = false;
            root.page = page;
            root.entries = entries;
        }
    }
    Timer {
        interval: 700; running: true
        onTriggered: {
            if (root.groups.length !== 5 || root.entries.length !== 3) throw new Error("views missing");
            if (!barStyle.text().includes("#custom-battery")) throw new Error("sound drawer did not mark the bar");
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
            root.focusArea = "groups";
            root.groupIndex = 3;
            root.requestView();
            groupProcess.running = true;
        }
    }
    Timer {
        interval: 1300; running: true
        onTriggered: {
            if (root.focusArea !== "groups" || root.groupIndex !== 3) {
                console.error("Background page/group refresh moved the keyboard's group selection");
                Qt.exit(1);
                return;
            }
            root.focusArea = "items";
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
            root.show("root");
        }
    }
    Timer {
        interval: 1600; running: true
        onTriggered: {
            if (root.page !== "root" || root.focusArea !== "items") {
                console.error("Home favorites did not receive their normal initial focus");
                Qt.exit(1);
                return;
            }
            root.show("root");
            root.groupIndex = 2;
            root.step(1);
        }
    }
    Timer {
        interval: 2000; running: true
        onTriggered: {
            if (root.page !== "root" || root.entries.length !== 1 || root.entries[0].value !== 42)
                throw new Error("home favorites were not populated with live values");
            if (!itemList.visible) throw new Error("favorite rows are hidden on the home panel");
            if (root.focusArea !== "groups" || root.groupIndex !== 3) {
                console.error("Delayed home favorites stole focus after group navigation started");
                Qt.exit(1);
                return;
            }
            root.focusArea = "items";
            if (root.groups[1].summary !== "42% · speakers")
                throw new Error("favorite keyboard focus or live summary missing");
            var tab = {key: Qt.Key_Tab, modifiers: 0, accepted: false}; root.key(tab);
            if (root.focusArea !== "groups") throw new Error("Tab did not reach groups from favorites");
            root.page = "projects";
            root.focusArea = "items";
            root.entries = [{id: "project-open", argument: "/a literal project", presentation: "project", kind: "action"}];
            root.itemIndex = 0;
            root.actionBusy = false;
            root.key({key: Qt.Key_T, modifiers: 0, accepted: false});
            if (JSON.stringify(actionProcess.command.slice(-3)) !== JSON.stringify(["run", "project-terminal", "/a literal project"]))
                throw new Error("project terminal key lost its selected path");
            root.hide();
            if (!root.drawerVisible || keyboard.enabled) throw new Error("closing lost its reveal or kept keyboard input");
        }
    }
    Timer {
        interval: 2700; running: true
        onTriggered: {
            if (root.drawerVisible) throw new Error("closed drawer did not finish hiding");
            if (barStyle.text().includes("#custom-logo")) throw new Error("hidden drawer left its bar marker active");
            root.opened = true;
            root.page = "projects";
            root.focusArea = "items";
            root.entries = [{id: "project-open", argument: "/a literal project", presentation: "project", kind: "action", close: true, bookmarked: true}];
            root.itemIndex = 0;
            root.key({key: Qt.Key_B, modifiers: 0, accepted: false});
            if (JSON.stringify(actionProcess.command.slice(-3)) !== JSON.stringify(["run", "project-bookmark", "/a literal project"]) || actionProcess.item.close)
                throw new Error("bookmark key lost the selected project or closes the drawer");
            root.hide();
        }
    }
    Timer {
        interval: 3400; running: true
        onTriggered: {
            root.opened = true;
            root.page = "library";
            root.focusArea = "items";
            root.entries = [{id: "drive-open", argument: "/dev/sda1", ejectArgument: "/dev/sda", presentation: "library", kind: "action"}];
            root.itemIndex = 0;
            root.key({key: Qt.Key_E, modifiers: 0, accepted: false});
            if (!root.pendingConfirm || root.confirmYes || actionProcess.running)
                throw new Error("eject did not stop for confirmation");
            root.goBack();
            if (root.pendingConfirm || actionProcess.running) throw new Error("cancelled eject started an action");
            root.key({key: Qt.Key_E, modifiers: 0, accepted: false});
            root.confirmYes = true;
            root.key({key: Qt.Key_Return, modifiers: 0, accepted: false});
            if (JSON.stringify(actionProcess.command.slice(-4)) !== JSON.stringify(["run", "drive-eject", "/dev/sda", "--confirm"]))
                throw new Error("confirmed eject lost its device or confirmation");
            root.hide();
        }
    }
    Timer {
        interval: 4100; running: true
        onTriggered: {
            root.opened = true;
            root.page = "downloads";
            root.focusArea = "items";
            root.entries = [{id: "download-open", argument: "/a literal download.txt", presentation: "download", kind: "action"}];
            root.itemIndex = 0;
            root.key({key: Qt.Key_R, modifiers: 0, accepted: false});
            if (JSON.stringify(actionProcess.command.slice(-3)) !== JSON.stringify(["run", "download-folder", "/a literal download.txt"]))
                throw new Error("folder key lost its selected download path");
            root.hide();
        }
    }
    function testFind(item, name) {
        if (item.objectName === name) return item;
        for (var child of item.children || []) {
            var found = testFind(child, name);
            if (found) return found;
        }
        return null;
    }
    Timer { interval:4300; running:true; onTriggered: {
        root.opened=true; root.page="bookmarks"; root.focusArea="items"; root.itemIndex=0;
        root.entries=Array.from({length:12},function(_,i){return {id:"fixture-"+i,label:"Page "+i,kind:"action"};});
        itemList.positionViewAtBeginning();
    }}
    Timer { interval:4400; running:true; onTriggered: {
        var marker=testFind(itemScroll,"page-edge-marker");
        if (!itemScroll.visible || !marker || Math.abs(marker.mapToItem(itemList,0,0).y)>4)
            throw new Error("page-edge marker did not start at the top");
        itemList.contentY=itemList.originY+(itemList.contentHeight-itemList.height)*.5;
    }}
    Timer { interval:4500; running:true; onTriggered: {
        var marker=testFind(itemScroll,"page-edge-marker");
        if (Math.abs(marker.mapToItem(itemList,0,0).y-(itemList.height-marker.height)*.5)>4)
            throw new Error("page-edge marker did not follow the middle of the page");
        // Native ScrollBar position remains two-way connected to the view.
        itemScroll.position=1-itemScroll.size;
    }}
    Timer { interval:4600; running:true; onTriggered: {
        var marker=testFind(itemScroll,"page-edge-marker");
        if (Math.abs(marker.mapToItem(itemList,0,0).y+marker.height-itemList.height)>4
            || Math.abs(itemList.contentY-itemList.originY-itemList.contentHeight+itemList.height)>4)
            throw new Error("native scrollbar did not reach the page bottom");
        root.itemIndex=0;
        root.entries=[{id:"media-play-pause",label:"A track",detail:"An artist · Paused",mediaState:"Paused",kind:"action",presentation:"media",artwork:Qt.resolvedUrl("paper-cat.png")}];
    }}
    Timer { interval:4700; running:true; onTriggered: {
        var cover=testFind(itemList,"media-artwork"), tape=testFind(cover,"media-washi-tape");
        if (itemScroll.visible || !cover.ready || !tape.visible)
            throw new Error("media artwork/tape did not load or a short page kept its scrollbar");
        if (!testFind(cover,"media-photo-mat").visible || testFind(itemList,"media-state-tag").text!=="paused"
            || Math.abs(theme.tooltipFill.a-.94)>.005)
            throw new Error("photo mat, matching state label or tracing-paper fill is missing");
        root.activate(root.entries[0]);
        if (JSON.stringify(actionProcess.command.slice(-2))!==JSON.stringify(["run","media-play-pause"]))
            throw new Error("media artwork changed the playback action");
        cover.source="";
        if (cover.ready || tape.visible) throw new Error("empty artwork did not restore its fallback");
        root.hide();
    }}
    Timer {
        interval: 5000; running: true
        onTriggered: {
            var base = Quickshell.env("XDG_RUNTIME_DIR");
            root.showPicker(base + "/foxml-picker-abc123/request.json");
            if (!root.pickerActive || root.entries.length !== 2 || groupList.visible)
                throw new Error("generic picker did not replace the sidebar");
            root.startSearch();
            searchInput.text = "literal";
            root.requestView();
            if (root.entries.length !== 1 || root.entries[0].pickerIndex !== 1)
                throw new Error("picker filtering lost original indexes");
            root.activate(root.entries[0]);
            if (root.opened || root.pickerActive || JSON.parse(pickerReply.text()).index !== 1)
                throw new Error("picker did not submit and close");
            root.showPicker(base + "/foxml-picker-def456/request.json");
            var typed = {key: Qt.Key_H, modifiers: 0, accepted: false}; root.key(typed);
            if (!root.pickerPrompt || typed.accepted) throw new Error("prompt stole a letter");
            searchInput.text = "hjkl $literal";
            root.activate(null);
            if (JSON.parse(pickerReply.text()).text !== "hjkl $literal") throw new Error("prompt text changed");
            root.showPicker(base + "/foxml-picker-abc123/request.json");
            root.showPicker(base + "/foxml-picker-def456/request.json");
            pickerRequest.path = base + "/foxml-picker-abc123/response.json";
            if (!JSON.parse(pickerRequest.text()).cancel) throw new Error("superseded picker did not cancel");
            root.hide();
            if (!JSON.parse(pickerReply.text()).cancel) throw new Error("Escape did not cancel picker");
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
            for suffix, prompt in (("abc123", False), ("def456", True)):
                request = directory / "runtime" / ("foxml-picker-" + suffix)
                request.mkdir(mode=0o700)
                (request / "request.json").write_text(json.dumps({"title": "A little fixture", "prompt": prompt, "items": ["first", "a literal $(label)"]}))
                (request / "response.json").write_text("")
            source = (ROOT / "shared/quickshell/foxml/shell.qml").read_text()
            source = source.replace("    PanelWindow {", "    FloatingWindow {")
            source = re.sub(r"^        (?:anchors \{.*|margins \{.*|exclusionMode:.*|WlrLayershell\..*)\n", "", source, flags=re.M)
            source = source.rsplit("\n}", 1)[0] + EXERCISE + "\n}\n"
            (directory / "shell.qml").write_text(source)
            for name in ("DrawerLogic.js", "ClipIcon.qml", "LoadingDots.qml", "PencilProgress.qml", "PaperGrain.qml", "BarHint.qml", "PageEdgeScrollBar.qml", "MediaArtwork.qml", "StateTag.qml", "BarRibbon.qml"):
                shutil.copyfile(ROOT / "shared/quickshell/foxml" / name, directory / name)
            shutil.copyfile(ROOT / "shared/quickshell/foxml/paper-cat.png", directory / "paper-cat.png")
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
                "FOXML_DRAWER_BAR_STATE": str(directory / "drawer-state.css"),
            }
            env.pop("WAYLAND_DISPLAY", None)
            result = subprocess.run(["quickshell", "--path", str(directory), "--no-color"],
                                    env=env, text=True, capture_output=True, timeout=12)
            log = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, log)
            self.assertIn("DRAWER_UI_ASSERTIONS_PASSED", log)
            for suffix in ("abc123", "def456"):
                response = directory / "runtime" / ("foxml-picker-" + suffix) / "response.json"
                self.assertTrue(json.loads(response.read_text()).get("cancel"), "Cancellation must reach each caller on disk")
            self.assertNotIn("TypeError", log)
            self.assertNotIn("ReferenceError", log)
            self.assertNotIn("Could not update the Waybar drawer marker", log)
            self.assertNotIn("#custom-logo", (directory / "drawer-state.css").read_text())
            self.assertEqual([json.loads(line) for line in actions.read_text().splitlines()],
                             [["run", "volume", "47"], ["run", "project-terminal", "/a literal project"],
                              ["run", "project-bookmark", "/a literal project"], ["run", "drive-eject", "/dev/sda", "--confirm"],
                              ["run", "download-folder", "/a literal download.txt"], ["run", "media-play-pause"]])


if __name__ == "__main__":
    unittest.main()
