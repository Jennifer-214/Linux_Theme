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
            if (root.groups.length !== 6 || root.entries.length !== 3) throw new Error("views missing");
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
            root.show("search");
            if (!root.searching || root.searchPage !== "search" || root.focusArea !== "items")
                throw new Error("Find anything did not enter search directly");
            root.goBack();
            if (root.opened) throw new Error("Escape did not close directly opened search");
            root.show("root");
        }
    }
    Timer {
        interval: 1600; running: true
        onTriggered: {
            if (root.page !== "root" || root.focusArea !== "groups" || root.groupIndex !== 0 || root.groups[0].id !== "today") {
                console.error("Home did not open on Today in the top-level list");
                Qt.exit(1);
                return;
            }
            var tagTexts = todaySheet.tags.map(function(tag) { return tag.text; });
            if (!todaySheet.visible || tagTexts.indexOf("80%") < 0 || tagTexts.indexOf("✉ 2 agent notes") < 0 || tagTexts[tagTexts.length - 1] !== "❦ 2 days active this month")
                throw new Error("Today sheet is missing its overview");
            root.chooseGroup(0);
            if (root.focusArea !== "items" || root.page !== "root") throw new Error("Enter on Today did not step into the favorites");
            root.focusArea = "groups";
            root.show("root");
            root.groupIndex = 2;
            root.step(1);
            previewTimer.stop();  // the sidebar preview has its own stage at 4800
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
            if (root.groups[2].summary !== "42% · speakers")
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
            || Math.abs(itemList.contentY-itemList.originY-itemList.contentHeight+itemList.height)>4.5)
            throw new Error("native scrollbar did not reach the page bottom");
        root.itemIndex=0;
        root.entries=[{id:"media-play-pause",label:"A track",detail:"An artist · Paused",mediaState:"Paused",kind:"action",presentation:"media",artwork:Qt.resolvedUrl("paper-sprig.png")}];
    }}
    Timer { interval:4700; running:true; onTriggered: {
        var cover=testFind(itemList,"media-artwork"), tape=testFind(cover,"media-washi-tape");
        if (itemScroll.visible || !cover.ready || !tape.visible)
            throw new Error("media artwork/tape did not load or a short page kept its scrollbar");
        if (!testFind(cover,"media-photo-mat").visible || testFind(itemList,"media-state-tag").text!=="paused"
            || Math.abs(theme.tooltipFill.a-.98)>.005)
            throw new Error("photo mat, matching state label or tracing-paper fill is missing");
        root.activate(root.entries[0]);
        if (JSON.stringify(actionProcess.command.slice(-2))!==JSON.stringify(["run","media-play-pause"]))
            throw new Error("media artwork changed the playback action");
        cover.source="";
        if (cover.ready || tape.visible) throw new Error("empty artwork did not restore its fallback");
        root.hide();
    }}
    Timer { interval:4800; running:true; onTriggered: root.show("root") }
    Timer { interval:5000; running:true; onTriggered: {
        var texts = todaySheet.tags.map(function(tag) { return tag.text; });
        if (texts[0] !== "✉ Paper notebook is waiting" || texts[1] !== "⋯ 2 working" || texts.indexOf("80%") !== 2)
            throw new Error("Today lost its waiting agent, working count or battery tag: " + JSON.stringify(texts));
        if (testFind(todaySheet, "today-since").text !== "✎ 3 commits since this morning") throw new Error("the commits line is missing");
        var usage = testFind(todaySheet, "today-claude");
        if (!usage || usage.text !== "Claude · 2h 10m today · 17% of the week left · refills sun" || !Qt.colorEqual(usage.color, theme.gardenShades[4]))
            throw new Error("the Claude usage line is missing or not berry past 80%");
        var teacup = testFind(todaySheet, "today-teacup");
        if (!teacup || !teacup.visible || teacup.remaining !== 17 || Math.abs(teacup.level - 0.17) > 0.001)
            throw new Error("the teacup is missing or not filled to what is left");
        root.focusArea = "items"; root.itemIndex = 0;
        root.key({key: Qt.Key_K, modifiers: 0, accepted: false});
        if (root.focusArea !== "tags" || root.tagIndex !== 0 || todaySheet.selectedTag !== 0) throw new Error("k from the first favorite did not reach the tags");
        root.key({key: Qt.Key_L, modifiers: 0, accepted: false});
        root.key({key: Qt.Key_L, modifiers: 0, accepted: false});
        if (root.tagIndex !== 2) throw new Error("l did not move along the tags");
        root.key({key: Qt.Key_Return, modifiers: 0, accepted: false});
        if (root.page !== "power" || root.focusArea !== "items" || JSON.stringify(root.trail) !== JSON.stringify(["root"]))
            throw new Error("the battery tag did not open Power with a way back");
        root.goBack();
        if (root.page !== "root") throw new Error("back from a tag did not return to Today");
        root.goBack();
        if (root.focusArea !== "groups") throw new Error("Esc from the favorites did not reach the sidebar");
        root.step(1);
        if (root.page !== "root" || root.groupIndex !== 1) throw new Error("the preview loaded before the pause");
    }}
    Timer { interval:5300; running:true; onTriggered: {
        if (root.page !== "desk" || root.focusArea !== "groups") throw new Error("moving through the sidebar did not preview the drawer: " + root.page);
        var serial = root.navigationSerial;
        root.key({key: Qt.Key_Return, modifiers: 0, accepted: false});
        if (root.focusArea !== "items" || root.page !== "desk" || root.navigationSerial !== serial) throw new Error("Enter reloaded a previewed drawer");
        root.show("root");
        root.openTag(todaySheet.tags[0]);
    }}
    // The garden is the last Today tag, so the keyboard reaches it like any other.
    Timer { interval:5650; running:true; onTriggered: {
        root.show("root");
        root.focusArea = "tags"; root.tagIndex = 0;
        for (var n = 0; n < todaySheet.tags.length; n++) root.key({key: Qt.Key_L, modifiers: 0, accepted: false});
        if (root.todayTags[root.tagIndex].page !== "garden" || todaySheet.selectedTag !== root.tagIndex) throw new Error("l did not reach the garden tag");
        root.key({key: Qt.Key_Return, modifiers: 0, accepted: false});
    } }
    Timer { interval:5900; running:true; onTriggered: {
        if (root.page !== "garden" || !root.gardenLayout || !gardenSheet.visible || itemList.visible || emptyNote.visible)
            throw new Error("the hearts line did not open the garden sheet: " + root.page + " " + root.gardenLayout + " " + gardenSheet.visible + " " + itemList.visible + " " + emptyNote.visible);
        if (gardenSheet.counts.length !== 371 || root.gardenIndex !== 370) throw new Error("the garden did not start on today");
        if (testFind(gardenSheet, "garden-summary").text !== "· 35 commits this year · longest streak 4 days · busiest nov 2 (9)")
            throw new Error("garden summary: " + testFind(gardenSheet, "garden-summary").text);
        if (testFind(gardenSheet, "garden-readout").text !== "today · 2 commits") throw new Error("the readout does not start on today");
        var today = testFind(gardenSheet, "garden-day-370"), heart = testFind(gardenSheet, "garden-day-365");
        if (!today || today.level !== 1 || !heart || !heart.heart || testFind(gardenSheet, "garden-day-363").level !== 3)
            throw new Error("garden shades or hearts are wrong");
        root.key({key: Qt.Key_H, modifiers: 0, accepted: false});
        root.key({key: Qt.Key_K, modifiers: 0, accepted: false});
        if (root.gardenIndex !== 362 || testFind(gardenSheet, "garden-readout").text !== "fri, oct 30 · no commits")
            throw new Error("h / k did not move a week and a day: " + root.gardenIndex + " " + testFind(gardenSheet, "garden-readout").text);
        root.key({key: Qt.Key_T, modifiers: 0, accepted: false});
        if (root.gardenIndex !== 370) throw new Error("t did not return to today");
        root.key({key: Qt.Key_Escape, modifiers: 0, accepted: false});
        if (root.page !== "root" || !root.opened) throw new Error("Esc did not take the garden back to Today, where it opened from");
        root.hide();
    }}
    Timer { interval:6000; running:true; onTriggered: root.show("agents") }
    Timer { interval:6100; running:true; onTriggered: {
        var hearts = testFind(itemList, "context-hearts");
        if (root.entries.length !== 2 || !hearts || !hearts.visible || hearts.filled !== 2)
            throw new Error("a Claude session row lost its context hearts: " + root.page + " " + root.entries.length + " " + (hearts ? hearts.visible + "/" + hearts.filled : "none"));
        if (!hearts.fresh || !hearts.sparkling || !testFind(hearts, "context-sparkle"))
            throw new Error("a freshly tidied session did not sparkle: " + hearts.fresh + " " + hearts.sparkling);
        root.activate(root.entries[1]);
        if (JSON.stringify(actionProcess.command.slice(-3)) !== JSON.stringify(["run","claude-jump","%4"]))
            throw new Error("picking a session did not jump to its pane: " + JSON.stringify(actionProcess.command));
        root.hide();
    }}
    function testFindAll(item, name, found) {
        found = found || [];
        if (item.objectName === name) found.push(item);
        for (var child of item.children || []) testFindAll(child, name, found);
        return found;
    }
    // The landing page comes back as it last read, at once; `?` opens the drawer's keys; digits jump to groups.
    Timer { interval:6250; running:true; onTriggered: {
        root.show("root");
        if (root.entries.length !== 1 || root.pageLoading || itemList.viewPage !== "root" || root.today.battery !== "80%" || !root.drawerReady)
            throw new Error("the landing page blinked empty on open: " + root.entries.length + " " + root.pageLoading + " " + itemList.viewPage);
        root.key({key: Qt.Key_Question, modifiers: Qt.ShiftModifier, accepted: false, text: "?"});
        if (root.page !== "cheatsheet" || root.keysFilter !== "quickshell drawers" || root.searching || root.focusArea !== "items" || JSON.stringify(root.trail) !== JSON.stringify(["root"]))
            throw new Error("? did not open the drawer keys: " + root.page + " " + root.keysFilter + " " + JSON.stringify(root.trail));
        if (JSON.stringify(viewProcess.command.slice(-3)) !== JSON.stringify(["view", "cheatsheet", "quickshell drawers"]))
            throw new Error("the drawer keys were not filtered: " + JSON.stringify(viewProcess.command));
    }}
    Timer { interval:6600; running:true; onTriggered: {
        if (root.pageTitle !== "drawer keys" || !root.entries.length) throw new Error("the keys page is not titled drawer keys: " + root.pageTitle);
        root.goBack();
        if (root.page !== "root" || root.keysFilter !== "") throw new Error("h from the keys did not return to Today");
        if (root.entries.length !== 1 || root.pageLoading || !root.drawerReady) throw new Error("coming back to Today blinked its favorites");
        root.key({key: Qt.Key_3, modifiers: 0, accepted: false});
        if (root.page !== root.groups[2].id || root.focusArea !== "items" || root.groupIndex !== 2) throw new Error("3 did not open the third group: " + root.page);
        root.key({key: Qt.Key_1, modifiers: 0, accepted: false});
        if (root.page !== "root" || root.groupIndex !== 0) throw new Error("1 did not return to Today: " + root.page);
        root.page = "sound";
        root.entries = [{id: "wifi", label: "With keys", kind: "page", page: "wifi", keys: "alt ⇧ n"}, {id: "plain-row", label: "No keys", kind: "action"}];
    }}
    Timer { interval:6700; running:true; onTriggered: {
        var labels = testFindAll(itemList, "item-keys");
        var shown = labels.filter(function(row) { return row.visible; });
        if (labels.length !== 2 || shown.length !== 1 || JSON.stringify(shown[0].caps) !== JSON.stringify(["alt", "⇧", "n"]))
            throw new Error("row keys did not render as caps on only the row that has them: " + labels.length + " " + shown.length);
        root.hide();
        levelSlip.showMedia("A song\u0007", "An artist", "Playing", "javascript:alert(1)");
        if (levelSlip.heading !== "a little song." || levelSlip.detail !== "A song · An artist" || levelSlip.playState !== "playing" || levelSlip.artUrl !== "")
            throw new Error("the song slip: " + levelSlip.heading + " / " + levelSlip.detail + " / " + levelSlip.playState + " / " + levelSlip.artUrl);
        if (testFind(levelSlip.artwork, "level-slip-glyph").visible || !testFind(levelSlip.artwork, "level-slip-state").visible || !testFind(levelSlip.artwork, "level-slip-artwork").visible)
            throw new Error("the song slip kept the level glyph or lost its state and artwork");
        levelSlip.showMedia("", "", "Stopped", Qt.resolvedUrl("paper-sprig.png"));
        if (levelSlip.detail !== "nothing is playing." || levelSlip.playState !== "stopped" || levelSlip.artUrl.indexOf("file:///") !== 0)
            throw new Error("an empty song slip: " + levelSlip.detail + " / " + levelSlip.artUrl);
        levelSlip.showVolume(40, false);
        if (levelSlip.heading !== "a little sound." || !testFind(levelSlip.artwork, "level-slip-glyph").visible) throw new Error("volume after a song kept the song layout");
    }}
    Timer {
        interval: 7000; running: true
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
            for name in ("DrawerLogic.js", "ClipIcon.qml", "LoadingDots.qml", "PencilProgress.qml", "PaperGrain.qml", "BarHint.qml", "PageEdgeScrollBar.qml", "MediaArtwork.qml", "StateTag.qml", "BarRibbon.qml", "PaperFlourish.qml", "PaperCardSurface.qml", "ClipboardPhoto.qml", "CalendarSheet.qml", "Overview.qml", "PolkitPrompt.qml", "CalendarLogic.js", "ScrapbookSheet.qml", "GardenSheet.qml", "ContextHearts.qml", "TeaCup.qml", "TodaySheet.qml", "ApiCreditMeter.qml", "LevelSlip.qml", "BotanicalMark.qml"):
                shutil.copyfile(ROOT / "shared/quickshell/foxml" / name, directory / name)
            volume = (directory / "LevelSlip.qml").read_text().replace("PanelWindow {", "FloatingWindow {")
            volume = re.sub(r"^    (?:anchors.*|margins\..*|exclusionMode:.*|WlrLayershell\..*)\n", "", volume, flags=re.M)
            (directory / "LevelSlip.qml").write_text(volume)
            overview = (directory / "Overview.qml").read_text().replace("    PanelWindow {", "    FloatingWindow {")
            overview = re.sub(r"^        (?:anchors \{.*|exclusionMode:.*|WlrLayershell\..*)\n", "", overview, flags=re.M)
            (directory / "Overview.qml").write_text(overview)
            polkit = (directory / "PolkitPrompt.qml").read_text().replace("    PanelWindow {", "    FloatingWindow {")
            polkit = re.sub(r"^        (?:anchors \{.*|exclusionMode:.*|WlrLayershell\..*)\n", "", polkit, flags=re.M)
            (directory / "PolkitPrompt.qml").write_text(polkit)
            shutil.copyfile(ROOT / "shared/quickshell/foxml/paper-sprig.png", directory / "paper-sprig.png")
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
                # The paper polkit prompt stops and starts the session's hyprpolkitagent; never from a test.
                "FOXML_POLKIT_PROMPT": "off",
            }
            env.pop("WAYLAND_DISPLAY", None); env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
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
            self.assertNotIn("Error: ", log, "a stage threw; QML timers only log what they throw")
            self.assertNotIn("Could not update the Waybar drawer marker", log)
            self.assertNotIn("#custom-logo", (directory / "drawer-state.css").read_text())
            self.assertEqual([json.loads(line) for line in actions.read_text().splitlines()],
                             [["run", "volume", "47"], ["run", "project-terminal", "/a literal project"],
                              ["run", "project-bookmark", "/a literal project"], ["run", "drive-eject", "/dev/sda", "--confirm"],
                              ["run", "download-folder", "/a literal download.txt"], ["run", "media-play-pause"],
                              ["run", "agent-jump", "sample-agent"], ["run", "claude-jump", "%4"]])


if __name__ == "__main__":
    unittest.main()
