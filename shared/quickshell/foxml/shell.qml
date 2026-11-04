import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "DrawerLogic.js" as Logic

ShellRoot {
    id: root

    property bool pickerActive: false
    property bool pickerPrompt: false
    property var pickerItems: []
    property string pickerResponse: ""
    property bool opened: false
    property bool searching: false
    property string searchPage: "search"
    property bool editing: false
    property bool actionBusy: false
    property string page: "root"
    property string pageTitle: "a little room to think."
    property string groupId: ""
    property string message: ""
    property bool failed: false
    property var groups: []
    property var entries: []
    property var trail: []
    readonly property var breadcrumbs: Logic.breadcrumbs(page, groupId, trail, groups, pageTitle)
    property var remembered: ({})
    property string focusArea: "groups"
    property int groupIndex: 0
    property int itemIndex: 0
    property int draftValue: 0
    property var pendingConfirm: null
    property bool confirmYes: false
    property int viewSerial: 0
    property int navigationSerial: 0
    property bool drawerReady: true
    property bool homeFocusPending: false
    property var nextView: null
    property var nextAction: null
    property string backend: Quickshell.env("FOXML_DRAWER_BACKEND") || "fox-drawer"
    property string barStatePath: Quickshell.env("FOXML_DRAWER_BAR_STATE") || (Quickshell.env("FOXML_DRAWER_PREVIEW") === "1" ? ""
        : (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/waybar/drawer-state.css")
    property string lastBarStyle: ""

    onOpenedChanged: barWrite.restart()
    onPageChanged: barWrite.restart()
    onGroupIdChanged: barWrite.restart()

    function syncBar(closing) {
        if (!barStatePath) return;
        var css = Logic.barStyle(closing ? false : opened, page, groupId);
        if (css === lastBarStyle) return;
        barStyle.setText(css);
        lastBarStyle = css;
    }

    Theme { id: theme }

    FileView {
        id: barStyle
        path: root.barStatePath
        preload: false
        atomicWrites: true
        blockWrites: true
        printErrors: false
        onSaveFailed: error => console.warn("Could not update the Waybar drawer marker:", error)
    }
    Timer { id: barWrite; interval: 40; onTriggered: root.syncBar(false) }

    FileView { id: pickerRequest; preload: false; blockLoading: true; blockAllReads: true; printErrors: false }
    FileView { id: pickerReply; preload: false; blockLoading: true; blockAllReads: true; atomicWrites: true; blockWrites: true; printErrors: false }

    function finishPicker(response) {
        if (!pickerActive) return;
        pickerReply.path = pickerResponse;
        pickerReply.reload();
        pickerReply.text();
        pickerReply.setText(JSON.stringify(response));
        pickerActive = false;
        pickerItems = [];
        pickerResponse = "";
    }

    function showPicker(path) {
        var prefix = (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/foxml-picker-";
        if (path.indexOf(prefix) !== 0 || !/^[A-Za-z0-9]{6}\/request\.json$/.test(path.slice(prefix.length))) return;
        pickerRequest.path = path;
        pickerRequest.reload();
        var data;
        try { data = JSON.parse(pickerRequest.text()); } catch (error) { return; }
        if (!data || typeof data.title !== "string" || !Array.isArray(data.items) || data.items.length > 10000) return;
        finishPicker({cancel: true});
        finishEdit();
        remember();
        pickerActive = true;
        pickerPrompt = data.prompt === true;
        pickerResponse = path.replace(/request\.json$/, "response.json");
        pickerItems = data.items.map(function(label, index) {
            return {id: "picker-entry", label: String(label), kind: "action", argument: String(index), pickerIndex: index, enabled: true};
        });
        opened = true;
        searching = pickerPrompt;
        editing = false;
        pendingConfirm = null;
        nextView = null;
        viewSerial++;
        navigationSerial++;
        page = "picker";
        pageTitle = data.title;
        groupId = "";
        trail = [];
        entries = pickerItems;
        itemIndex = 0;
        drawerReady = true;
        focusArea = "items";
        searchInput.text = "";
        note("");
        Qt.callLater(function() { if (root.pickerPrompt) searchInput.forceActiveFocus(); else keyboard.forceActiveFocus(); });
    }

    function backendCommand(args) {
        return [backend].concat(["--config", Quickshell.shellPath("menus.json")]).concat(args);
    }

    function note(text, error) {
        message = text;
        failed = error === true;
    }

    function buttonShade(pressed, hovered) {
        return pressed ? Qt.alpha(theme.line, .4) : hovered ? Qt.alpha(theme.surface, .6) : "transparent";
    }

    function remember() {
        if (page !== "root" && entries.length) {
            var saved = Object.assign({}, remembered);
            saved[page] = { key: Logic.identity(entries[itemIndex]), scroll: itemList.contentY };
            remembered = saved;
        }
    }

    function requestView() {
        if (!opened || pendingConfirm) return;
        if (pickerActive) {
            var needle = searching ? searchInput.text.toLowerCase() : "";
            entries = pickerItems.filter(function(row) { return row.label.toLowerCase().indexOf(needle) >= 0; });
            itemIndex = 0;
            return;
        }
        if (page === "root" && !searching) {
            if (!groupProcess.running) groupProcess.running = true;
            return;
        }
        nextView = { serial: ++viewSerial, page: searching ? searchPage : page,
                     query: searching ? searchInput.text : "", filter: searching };
        startView();
    }

    function startView() {
        if (viewProcess.running || !nextView) return;
        var request = nextView;
        nextView = null;
        viewProcess.serial = request.serial;
        viewProcess.requestedPage = request.page;
        viewProcess.command = backendCommand(["view", request.page].concat(request.filter ? [request.query] : []));
        viewProcess.running = true;
    }

    function applyView(serial, requestedPage, output, exitCode, diagnostic) {
        if (serial !== viewSerial || !opened) return;
        try {
            var data = JSON.parse(output);
            var partial = exitCode !== 0 || Boolean(data.error);
            if (partial && !Array.isArray(data.items)) {
                note(data.error || "This drawer could not be read.", true);
                return;
            }
            var oldKey = Logic.identity(entries[itemIndex]);
            var samePage = entries.length && itemList.viewPage === requestedPage;
            var saved = remembered[page];
            entries = Array.isArray(data.items) ? data.items : [];
            pageTitle = data.title || page;
            drawerReady = true;
            if (data.group && !searching) {
                groupId = data.group;
                var gi = groups.findIndex(function(g) { return g.page === groupId || g.id === groupId; });
                if (gi >= 0 && focusArea !== "groups") groupIndex = gi;
            }
            itemIndex = Logic.restoreIndex(entries, samePage ? oldKey : (saved ? saved.key : ""));
            itemList.viewPage = requestedPage;
            if (!samePage) {
                Qt.callLater(function() {
                    itemList.contentY = saved && !searching ? saved.scroll : 0;
                    itemList.positionViewAtIndex(itemIndex, ListView.Contain);
                });
            }
            if (partial) note(data.error || "Some controls are unavailable.", true);
            else if (failed) note("a little order, restored.");
        } catch (error) {
            note(exitCode !== 0 ? "The drawer service is unavailable. " + diagnostic.trim().slice(0, 180)
                               : "The drawer service returned an unreadable reply.", true);
        }
    }

    function show(pageId) {
        finishPicker({cancel: true});
        opened = true;
        searching = false;
        editing = false;
        pendingConfirm = null;
        searchInput.text = "";
        trail = [];
        page = pageId || "root";
        homeFocusPending = page === "root";
        navigationSerial++;
        focusArea = page === "root" ? "groups" : "items";
        note("");
        if (!groupProcess.running) groupProcess.running = true;
        if (page === "root") {
            entries = [];
            pageTitle = "a little room to think.";
            groupId = "";
        } else requestView();
        Qt.callLater(function() { keyboard.forceActiveFocus(); });
    }

    function hide() {
        homeFocusPending = false;
        finishPicker({cancel: true});
        finishEdit();
        remember();
        opened = false;
        editing = false;
        searching = false;
        pendingConfirm = null;
        nextView = null;
        viewSerial++;
        navigationSerial++;
    }

    function chooseGroup(index) {
        if (pickerActive) return;
        if (!groups[index]) return;
        homeFocusPending = false;
        remember();
        groupIndex = index;
        groupId = groups[index].page || groups[index].id;
        trail = [];
        page = groupId;
        navigationSerial++;
        drawerReady = false;
        entries = [];
        editing = false;
        searching = false;
        pendingConfirm = null;
        focusArea = "items";
        requestView();
        keyboard.forceActiveFocus();
    }

    function goBack() {
        if (pickerActive && (pickerPrompt || !searching)) { hide(); return; }
        if (pendingConfirm) { pendingConfirm = null; return; }
        if (editing) { finishEdit(); return; }
        if (searching) {
            searching = false;
            navigationSerial++;
            searchInput.text = "";
            itemList.viewPage = "";
            requestView();
            keyboard.forceActiveFocus();
            return;
        }
        if (trail.length) {
            remember();
            var stack = trail.slice();
            page = stack.pop();
            navigationSerial++;
            drawerReady = false;
            trail = stack;
            entries = [];
            requestView();
        } else if (focusArea === "items") {
            remember();
            focusArea = "groups";
            note("");
        } else hide();
    }

    function startSearch() {
        remember();
        editing = false;
        searching = true;
        navigationSerial++;
        searchPage = page !== "root" && !groups.some(function(g) { return g.id === page || g.page === page; }) ? page : "search";
        focusArea = "items";
        searchInput.text = "";
        requestView();
        Qt.callLater(function() { searchInput.forceActiveFocus(); });
        note("");
    }

    function step(delta) {
        homeFocusPending = false;
        if (pendingConfirm) { confirmYes = !confirmYes; return; }
        if (editing) return;
        if (focusArea === "groups") {
            groupIndex = Logic.nextIndex(groups, groupIndex, delta);
            groupList.positionViewAtIndex(groupIndex, ListView.Contain);
        } else {
            itemIndex = Logic.nextIndex(entries, itemIndex, delta);
            itemList.positionViewAtIndex(itemIndex, ListView.Contain);
        }
    }

    function activate(item, confirmed) {
        if (pickerActive) {
            if (pickerPrompt) {
                if (!searchInput.text.trim()) return;
                finishPicker({text: searchInput.text}); hide();
            } else if (item && item.enabled !== false) { finishPicker({index: item.pickerIndex}); hide(); }
            return;
        }
        if (!item || item.enabled === false || actionBusy) return;
        if (searching && searchPage === "search" && item.group && (item.kind === "slider" || item.kind === "toggle")) {
            searching = false;
            searchInput.text = "";
            page = item.group;
            groupId = item.group;
            navigationSerial++;
            trail = [];
            var saved = Object.assign({}, remembered);
            saved[page] = { key: Logic.identity(item), scroll: 0 };
            remembered = saved;
            entries = [];
            itemList.viewPage = "";
            requestView();
            keyboard.forceActiveFocus();
            note("");
            return;
        }
        if (item.kind === "page") {
            remember();
            if (searching) {
                searching = false;
                searchInput.text = "";
                trail = [];
            } else trail = trail.concat([page]);
            page = item.page || item.id;
            navigationSerial++;
            drawerReady = false;
            entries = [];
            requestView();
            keyboard.forceActiveFocus();
            return;
        }
        if (item.kind === "slider") {
            draftValue = Math.round(Number(item.value || 0));
            editing = true;
            note("");
            return;
        }
        if (item.confirm && !confirmed) {
            pendingConfirm = item;
            confirmYes = false;
            return;
        }
        runAction(item, undefined, confirmed === true);
    }

    function bookmark(item) {
        if (!item || item.presentation !== "project" || actionBusy || pendingConfirm) return;
        runAction(Object.assign({}, item, {id: "project-bookmark", action: "project-bookmark", close: false}), undefined, false);
    }

    function eject(item) {
        if (!item || item.presentation !== "library" || actionBusy || pendingConfirm) return;
        activate({id: "drive-eject", argument: item.ejectArgument, label: "Eject drive", kind: "action",
            confirm: "Eject this drive? All its volumes will be unmounted. Save your open files first."});
    }

    function runAction(item, value, confirmed) {
        nextAction = { item: item, args: Logic.actionArguments(item, value, confirmed) };
        startAction();
    }

    function startAction() {
        if (actionProcess.running || !nextAction) return;
        var job = nextAction;
        nextAction = null;
        actionProcess.item = job.item;
        actionProcess.location = navigationSerial;
        actionProcess.command = backendCommand(job.args);
        actionBusy = true;
        actionProcess.running = true;
    }

    function adjust(delta) {
        var item = entries[itemIndex];
        if (!editing || !item || item.kind !== "slider") return;
        draftValue = Math.max(0, Math.min(100, draftValue + delta));
        sliderWrite.item = item;
        sliderWrite.value = draftValue;
        sliderWrite.restart();
    }

    function finishEdit() {
        if (!editing) return;
        editing = false;
        if (sliderWrite.running) {
            sliderWrite.stop();
            runAction(sliderWrite.item, sliderWrite.value, false);
        } else if (!actionBusy) requestView();
    }

    function key(event) {
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
        homeFocusPending = false;
        var k = event.key;
        if (searching) {
            if (k === Qt.Key_Escape) { goBack(); event.accepted = true; }
            else if (k === Qt.Key_Down || k === Qt.Key_Up) { step(k === Qt.Key_Down ? 1 : -1); event.accepted = true; }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
                activate(entries[itemIndex]); event.accepted = true;
            }
            return;
        }
        if (pickerActive) {
            if (k === Qt.Key_Escape || k === Qt.Key_H || k === Qt.Key_Left || k === Qt.Key_Q) goBack();
            else if (k === Qt.Key_J || k === Qt.Key_Down) step(1);
            else if (k === Qt.Key_K || k === Qt.Key_Up) step(-1);
            else if (k === Qt.Key_L || k === Qt.Key_Right || k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) activate(entries[itemIndex]);
            else if (k === Qt.Key_Slash) startSearch();
            else return;
            event.accepted = true;
            return;
        }
        if (k === Qt.Key_Escape) goBack();
        else if (k === Qt.Key_R && !editing && !pendingConfirm && !actionBusy && focusArea === "items"
                 && entries[itemIndex] && entries[itemIndex].presentation === "download") {
            runAction(Object.assign({}, entries[itemIndex], {id: "download-folder", action: "download-folder"}), undefined, false);
        }
        else if (k === Qt.Key_B && !editing && !pendingConfirm && focusArea === "items"
                 && entries[itemIndex] && entries[itemIndex].presentation === "project") bookmark(entries[itemIndex]);
        else if (k === Qt.Key_E && !editing && !pendingConfirm && focusArea === "items"
                 && entries[itemIndex] && entries[itemIndex].presentation === "library") eject(entries[itemIndex]);
        else if (k === Qt.Key_T && !editing && !pendingConfirm && !actionBusy && focusArea === "items"
                 && entries[itemIndex] && entries[itemIndex].presentation === "project") {
            runAction(Object.assign({}, entries[itemIndex], {id: "project-terminal", action: "project-terminal"}), undefined, false);
        }
        else if (k === Qt.Key_F && !editing && !pendingConfirm) show("root");
        else if (k === Qt.Key_Q && !editing && !pendingConfirm) hide();
        else if (k === Qt.Key_J || k === Qt.Key_Down) step(1);
        else if (k === Qt.Key_K || k === Qt.Key_Up) step(-1);
        else if (k === Qt.Key_H || k === Qt.Key_Left) {
            if (editing) adjust(-5);
            else if (pendingConfirm) confirmYes = false;
            else goBack();
        } else if (k === Qt.Key_L || k === Qt.Key_Right || k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
            if (editing) {
                if (k === Qt.Key_L || k === Qt.Key_Right) adjust(5);
                else finishEdit();
            } else if (pendingConfirm) {
                if (confirmYes) { var accepted = pendingConfirm; pendingConfirm = null; activate(accepted, true); }
                else pendingConfirm = null;
            } else if (focusArea === "groups") chooseGroup(groupIndex);
            else activate(entries[itemIndex]);
        } else if (k === Qt.Key_Slash) startSearch();
        else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            if (entries.length) focusArea = focusArea === "groups" ? "items" : "groups";
        } else if (k === Qt.Key_Home || (k === Qt.Key_G && !(event.modifiers & Qt.ShiftModifier))) {
            if (focusArea === "groups") groupIndex = 0; else itemIndex = 0;
        } else if (k === Qt.Key_End || (k === Qt.Key_G && (event.modifiers & Qt.ShiftModifier))) {
            if (focusArea === "groups") groupIndex = groups.length - 1; else itemIndex = entries.length - 1;
        } else return;
        event.accepted = true;
    }

    IpcHandler {
        target: "drawer"
        function toggle(page: string): void { if (root.opened && (!page || page === root.page)) root.hide(); else root.show(page); }
        function open(page: string): void { root.show(page); }
        function close(): void { root.hide(); }
        function pick(path: string): void { root.showPicker(path); }
        function cancelPicker(path: string): void {
            if (root.pickerActive && root.pickerResponse === path.replace(/request\.json$/, "response.json")) root.hide();
        }
        function status(): string {
            return JSON.stringify({ open: root.opened, page: root.page, searching: root.searching,
                editing: root.editing, focus: root.focusArea, selected: Logic.identity(root.entries[root.itemIndex]),
                group: root.groupId, count: root.entries.length, busy: root.actionBusy, error: root.failed });
        }
    }

    Process {
        id: groupProcess
        command: root.backendCommand(["view", "root"])
        stdout: StdioCollector { id: groupOut }
        stderr: StdioCollector { id: groupErr }
        onExited: (code, status) => {
            if (!root.opened || root.pickerActive) return;
            try {
                var data = JSON.parse(groupOut.text);
                if ((code !== 0 || data.error) && !Array.isArray(data.items)) throw new Error(data.error || "Cannot read menu groups.");
                if (code !== 0 || data.error) root.note(data.error || "Some home cards are unavailable.", true);
                var previousGroup = Logic.identity(root.groups[root.groupIndex]);
                var refreshedGroups = Array.isArray(data.items) ? data.items : [];
                if (JSON.stringify(root.groups) !== JSON.stringify(refreshedGroups)) root.groups = refreshedGroups;
                if (root.page === "root" && !root.searching && !root.editing && !root.pendingConfirm) {
                    var previous = Logic.identity(root.entries[root.itemIndex]);
                    root.entries = Array.isArray(data.favorites) ? data.favorites : [];
                    root.itemIndex = Logic.restoreIndex(root.entries, previous);
                    root.pageTitle = root.entries.length ? "a few favorites." : "a little room to think.";
                    root.drawerReady = true;
                    itemList.viewPage = "root";
                    if (root.homeFocusPending && root.entries.length) root.focusArea = "items";
                    root.homeFocusPending = false;
                }
                var gi = root.focusArea === "groups" ? -1 : root.groups.findIndex(function(g) { return g.page === root.page || g.id === root.groupId; });
                root.groupIndex = gi >= 0 ? gi : Logic.restoreIndex(root.groups, previousGroup);
            } catch (error) { root.note(String(error.message || error), true); }
        }
    }
    Process {
        id: viewProcess
        property int serial: 0
        property string requestedPage: ""
        stdout: StdioCollector { id: viewOut }
        stderr: StdioCollector { id: viewErr }
        onExited: (code, status) => {
            root.applyView(serial, requestedPage, viewOut.text, code, viewErr.text);
            Qt.callLater(root.startView);
        }
    }
    Process {
        id: actionProcess
        property var item: null
        property int location: 0
        stdout: StdioCollector { id: actionOut }
        stderr: StdioCollector { id: actionErr }
        onExited: (code, status) => {
            root.actionBusy = false;
            try {
                var result = JSON.parse(actionOut.text);
                root.note(result.message || (result.ok ? "all set." : "That action did not complete."), !result.ok || code !== 0);
                if (result.ok && code === 0) {
                    if (root.opened && location === root.navigationSerial && result.page) root.show(result.page);
                    else if (root.opened && location === root.navigationSerial && (result.close || (item && item.close))) root.hide();
                    else if (!root.editing) root.requestView();
                }
            } catch (error) { root.note("That action did not complete. " + actionErr.text.trim().slice(0, 160), true); }
            Qt.callLater(root.startAction);
        }
    }
    Timer {
        id: sliderWrite
        property var item: null
        property int value: 0
        interval: 160
        onTriggered: { if (item) root.runAction(item, value, false); }
    }
    Timer { id: searchDebounce; interval: 160; onTriggered: root.requestView() }
    Timer {
        interval: 4000; repeat: true
        running: root.opened && !root.pickerActive && !root.searching && !root.editing && !root.pendingConfirm && !root.actionBusy
        onTriggered: {
            if (!groupProcess.running) groupProcess.running = true;
            if (root.page !== "root") root.requestView();
        }
    }

    component PaperShadow: Item {
        id: paperShadow
        required property color ink
        property real strength: 0.06
        Behavior on strength { NumberAnimation { duration: 70 } }
        anchors.fill: parent
        z: -1
        Rectangle {
            x: parent.width; y: 4; width: 4; height: Math.max(0, parent.height - 4)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Qt.alpha(paperShadow.ink, paperShadow.strength) }
                GradientStop { position: 1; color: "transparent" }
            }
        }
        Rectangle {
            x: 4; y: parent.height; width: Math.max(0, parent.width - 4); height: 4
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.alpha(paperShadow.ink, paperShadow.strength) }
                GradientStop { position: 1; color: "transparent" }
            }
        }
    }

    PanelWindow {
        id: panel
        visible: root.opened
        anchors { top: true; right: true }
        margins { top: 63; right: 20 }
        implicitWidth: Math.min(root.pickerActive ? 640 : 790, (screen ? screen.width : 1280) - 32)
        implicitHeight: Math.min(root.pickerActive && root.pickerPrompt ? 310 : 624, (screen ? screen.height : 800) - 96)
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "foxml-drawer"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        FocusScope {
            id: keyboard
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => root.key(event)

            Rectangle {
                anchors.fill: parent
                anchors.margins: 5
                color: theme.background
                radius: Math.max(4, Math.min(theme.radius, 12))
                border.width: 1
                border.color: theme.line
                PaperShadow { visible: theme.paperDetails; ink: theme.ink }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    spacing: 14

                    RowLayout {
                        Layout.fillWidth: true
                        Text { textFormat: Text.PlainText; text: "// THE QUIET CORNER"; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 10; font.letterSpacing: 1 }
                        Item { Layout.fillWidth: true }
                        ToolButton {
                            text: "♡"
                            implicitWidth: 28; implicitHeight: 28; padding: 0
                            font.family: theme.fontFamily
                            palette.buttonText: theme.ink
                            background: Rectangle { color: root.buttonShade(parent.down, parent.hovered); radius: 3 }
                            onClicked: root.show("root")
                            Accessible.name: "Pinned favorites (f)"
                            ToolTip.visible: hovered
                            ToolTip.text: "Pinned favorites · f"
                        }
                        Rectangle { width: 5; height: 5; radius: 3; color: root.failed ? theme.error : theme.success }
                        Text { textFormat: Text.PlainText; text: root.actionBusy ? "WORKING" : root.pickerActive && root.pickerPrompt ? "WRITE" : root.searching ? "SEARCH" : root.editing ? "ADJUST" : "NORMAL"; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9 }
                        ToolButton {
                            text: "×"
                            implicitWidth: 28; implicitHeight: 28; padding: 0
                            font.pixelSize: 19
                            palette.buttonText: theme.muted
                            background: Rectangle { color: root.buttonShade(parent.down, parent.hovered); radius: 3 }
                            onClicked: root.hide()
                            Accessible.name: "Close drawer"
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { textFormat: Text.PlainText; text: "make yourself at home."; color: theme.ink; font.family: theme.headingFont; font.italic: true; font.pixelSize: panel.width < 580 ? 21 : 27; Layout.fillWidth: true; elide: Text.ElideRight }
                        Canvas {
                            width: 46; height: 40
                            onPaint: {
                                var c = getContext("2d");
                                c.clearRect(0, 0, width, height);
                                c.strokeStyle = theme.ink;
                                c.lineWidth = 1.1;
                                c.lineJoin = "round";
                                c.lineCap = "round";
                                c.beginPath();
                                c.moveTo(9, 32); c.lineTo(9, 16); c.lineTo(14, 7); c.lineTo(21, 14);
                                c.lineTo(28, 14); c.lineTo(35, 7); c.lineTo(39, 17); c.lineTo(39, 32);
                                c.moveTo(18, 20); c.lineTo(18, 22); c.moveTo(30, 20); c.lineTo(30, 22);
                                c.moveTo(22, 25); c.lineTo(25, 27); c.lineTo(28, 25);
                                c.moveTo(20, 30); c.lineTo(25, 27); c.lineTo(30, 30);
                                c.moveTo(7, 25); c.lineTo(2, 23); c.moveTo(7, 29); c.lineTo(2, 30);
                                c.moveTo(40, 25); c.lineTo(45, 23); c.moveTo(40, 29); c.lineTo(45, 30);
                                c.moveTo(7, 35); c.quadraticCurveTo(24, 38, 41, 34);
                                c.stroke();
                            }
                        }
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 18

                        ListView {
                            id: groupList
                            visible: !root.pickerActive
                            Layout.preferredWidth: panel.width < 580 ? 125 : 179
                            Layout.fillHeight: true
                            clip: true
                            spacing: 7
                            bottomMargin: theme.paperDetails && contentHeight >= height ? 4 : 0
                            model: root.groups
                            currentIndex: root.groupIndex
                            keyNavigationEnabled: false
                            boundsBehavior: Flickable.StopAtBounds
                            boundsMovement: Flickable.StopAtBounds
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                width: groupList.width - (theme.paperDetails ? 4 : 0)
                                height: 65
                                radius: 4
                                color: groupMouse.pressed ? Qt.alpha(theme.line, .35) : index === root.groupIndex && (root.page !== "root" || root.focusArea === "groups") ? (theme.paperDetails || root.focusArea === "groups" ? theme.focusFill : Qt.alpha(theme.selection, theme.selectionOpacity * .45)) : theme.paperDetails ? (groupMouse.containsMouse ? theme.surface : theme.background) : root.buttonShade(false, groupMouse.containsMouse)
                                border.width: theme.paperDetails || (index === root.groupIndex && root.focusArea === "groups") ? 1 : 0
                                border.color: theme.paperDetails && !(index === root.groupIndex && root.focusArea === "groups") ? Qt.alpha(theme.line, .6) : theme.line
                                PaperShadow {
                                    visible: theme.paperDetails
                                    ink: theme.ink
                                    strength: groupMouse.pressed ? .012 : index === root.groupIndex && root.focusArea === "groups" ? .06 : .035
                                }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    spacing: 10
                                    Text { textFormat: Text.PlainText; text: Logic.symbol(modelData); color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 16; font.weight: Font.Normal; Layout.preferredWidth: 24 }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 3
                                        Text { textFormat: Text.PlainText; text: modelData.label || ""; color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 12; elide: Text.ElideRight; Layout.fillWidth: true }
                                        Text { textFormat: Text.PlainText; visible: panel.width >= 580; text: modelData.summary || modelData.detail || ""; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
                                    }
                                    Text { textFormat: Text.PlainText; text: "›"; color: theme.muted; font.pixelSize: 18 }
                                }
                                MouseArea {
                                    id: groupMouse
                                    anchors.fill: parent; hoverEnabled: true
                                    onClicked: root.chooseGroup(index); cursorShape: Qt.PointingHandCursor
                                }
                                ToolTip.visible: groupMouse.containsMouse
                                ToolTip.text: modelData.summary || modelData.detail || ""
                            }
                        }

                        Rectangle { visible: !root.pickerActive; width: 1; Layout.fillHeight: true; color: theme.line }

                        ColumnLayout {
                            id: drawer
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 10
                            opacity: !root.drawerReady ? 0 : root.page === "root" && !root.entries.length ? .65 : 1
                            Behavior on opacity { NumberAnimation { duration: 160 } }
                            transform: Translate {
                                x: root.drawerReady ? 0 : 28
                                Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Text { textFormat: Text.PlainText; text: root.searching && !root.pickerActive ? "find a little thing" : root.pageTitle; color: theme.ink; font.family: theme.headingFont; font.italic: true; font.pixelSize: 20; Layout.fillWidth: true; elide: Text.ElideRight }
                                Text { textFormat: Text.PlainText; text: root.page === "root" || (root.pickerActive && root.pickerPrompt) ? "" : String(root.entries.length).padStart(2, "0"); color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 10 }
                            }
                            Text {
                                id: breadcrumbRow
                                visible: !root.searching && (root.breadcrumbs.length > 1 || text.length > 0)
                                Layout.fillWidth: true
                                textFormat: Text.PlainText
                                text: (root.focusArea === "items" ? Logic.focusDetail(root.entries[root.itemIndex]) : "") || root.breadcrumbs.slice(0, -1).map(function(crumb) { return crumb.label; }).join(" / ")
                                color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9
                                elide: Text.ElideMiddle
                            }

                            Rectangle {
                                visible: root.searching
                                Layout.fillWidth: true
                                height: 38
                                color: theme.surface
                                radius: 4
                                border.width: 1
                                border.color: theme.line
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10
                                    Text { textFormat: Text.PlainText; text: "/"; color: theme.accent; font.family: theme.fontFamily }
                                    TextField {
                                        id: searchInput
                                        Layout.fillWidth: true
                                        color: theme.ink
                                        font.family: theme.fontFamily
                                        font.pixelSize: 12
                                        placeholderText: root.pickerPrompt && root.pickerActive ? "write here…" : "find a little thing…"
                                        placeholderTextColor: theme.muted
                                        selectByMouse: true
                                        background: Item {
                                            Rectangle { anchors.bottom: parent.bottom; width: theme.paperDetails ? Math.min(48, parent.width) : parent.width; height: 1; visible: searchInput.activeFocus; color: theme.paperDetails ? theme.detailAccent : theme.accent }
                                        }
                                        onTextChanged: if (root.searching) searchDebounce.restart()
                                        Keys.onPressed: event => root.key(event)
                                    }
                                    ToolButton {
                                        visible: root.pickerActive && root.pickerPrompt
                                        text: "↵"
                                        palette.buttonText: theme.ink
                                        background: Rectangle { color: root.buttonShade(parent.down, parent.hovered); radius: 3 }
                                        onClicked: root.activate(null)
                                        Accessible.name: "Submit text"
                                    }
                                }
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                ListView {
                                    id: itemList
                                    property string viewPage: ""
                                    anchors.fill: parent
                                    visible: !root.pendingConfirm && (root.page !== "root" || root.entries.length > 0 || root.searching)
                                    clip: true
                                    spacing: 7
                                    bottomMargin: theme.paperDetails && contentHeight >= height ? 4 : 0
                                    model: root.entries
                                    currentIndex: root.itemIndex
                                    keyNavigationEnabled: false
                                    boundsBehavior: Flickable.StopAtBounds
                                    ScrollBar.vertical: ScrollBar {
                                        id: itemScroll
                                        policy: ScrollBar.AsNeeded
                                        visible: itemList.contentHeight > itemList.height
                                        contentItem: Rectangle { implicitWidth: 4; implicitHeight: 20; radius: 2; color: itemScroll.pressed && theme.paperDetails ? theme.detailAccent : theme.line }
                                    }
                                    delegate: Rectangle {
                                        id: itemRow
                                        required property var modelData
                                        required property int index
                                        property bool selected: index === root.itemIndex && root.focusArea === "items"
                                        property string menuIcon: Logic.iconName(modelData) ? Quickshell.iconPath(Logic.iconName(modelData), true) : ""
                                        width: Math.max(0, itemList.width - theme.scrollGutter)
                                        property bool card: modelData.presentation === "project" || modelData.presentation === "library" || modelData.presentation === "download"
                                        height: card ? 94 : modelData.kind === "slider" ? 91 : modelData.image ? 80 : 72
                                        radius: 4
                                        color: itemMouse.pressed ? Qt.alpha(theme.line, .35) : selected ? theme.focusFill : theme.paperDetails ? (itemMouse.containsMouse ? theme.surface : theme.background) : card ? theme.surface : root.buttonShade(false, itemMouse.containsMouse)
                                        border.width: theme.paperDetails || selected || card || itemMouse.containsMouse ? 1 : 0
                                        border.color: itemMouse.pressed ? theme.muted : theme.paperDetails && !selected ? Qt.alpha(theme.line, .6) : theme.line
                                        opacity: modelData.enabled === false ? (theme.paperDetails ? .75 : .48) : 1
                                        PaperShadow {
                                            visible: theme.paperDetails
                                            ink: theme.ink
                                            strength: itemMouse.pressed ? .012 : itemRow.selected ? .06 : .035
                                        }
                                        Text {
                                            visible: itemRow.card
                                            anchors.top: parent.top; anchors.right: parent.right
                                            anchors.topMargin: 7; anchors.rightMargin: 10
                                            text: modelData.presentation === "library" ? (modelData.mounted ? "CHECKED OUT" : "ON THE SHELF") : modelData.presentation === "download" ? (modelData.stamp || "INCOMING") : String(index + 1).padStart(2, "0")
                                            color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 8
                                        }
                                        Rectangle {
                                            visible: itemRow.card
                                            anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
                                            anchors.bottomMargin: 11; anchors.leftMargin: 48; anchors.rightMargin: 12
                                            height: 1; color: theme.line; opacity: .6
                                        }
                                        Rectangle { visible: selected; width: 2; anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; color: theme.detailAccent; radius: 1 }
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.margins: 12
                                            spacing: 10
                                            Image {
                                                visible: Boolean(modelData.image || itemRow.menuIcon)
                                                source: modelData.image || itemRow.menuIcon
                                                sourceSize.width: modelData.image ? 42 : 24
                                                sourceSize.height: modelData.image ? 42 : 24
                                                Layout.preferredWidth: visible ? (modelData.image ? 42 : 24) : 0
                                                Layout.preferredHeight: modelData.image ? 42 : 24
                                                fillMode: Image.PreserveAspectFit
                                                asynchronous: true
                                            }
                                            Text { textFormat: Text.PlainText; visible: !modelData.image && !itemRow.menuIcon; text: Logic.symbol(modelData); color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 16; font.weight: Font.Normal; Layout.preferredWidth: visible ? 24 : 0 }
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 4
                                                Text { textFormat: Text.PlainText; text: modelData.label || ""; color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 12; elide: Text.ElideRight; Layout.fillWidth: true }
                                                Text { textFormat: Text.PlainText; text: Logic.detailText(modelData); visible: text.length > 0; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
                                                Item {
                                                    id: ruler
                                                    visible: modelData.kind === "slider"
                                                    Layout.fillWidth: true
                                                    Layout.topMargin: 6
                                                    Layout.preferredHeight: theme.paperDetails ? 14 : 3
                                                    readonly property real fraction: Math.max(0, Math.min(100, root.editing && selected ? root.draftValue : Number(modelData.value || 0))) / 100
                                                    Rectangle { width: parent.width; height: 1; y: theme.paperDetails ? 5 : 1; color: theme.line }
                                                    Rectangle { height: 2; y: theme.paperDetails ? 4 : 0; width: parent.width * ruler.fraction; color: theme.ink }
                                                    Repeater {
                                                        model: theme.paperDetails ? 11 : 0
                                                        Rectangle { required property int index; x: index * (ruler.width - 1) / 10; y: 8; width: 1; height: index % 5 === 0 ? 5 : 3; color: theme.line }
                                                    }
                                                    Rectangle { visible: theme.paperDetails; width: 5; height: 9; radius: 2; x: Math.max(0, Math.min(parent.width - width, parent.width * ruler.fraction - width / 2)); color: theme.detailAccent }
                                                }
                                            }
                                            ColumnLayout {
                                                Layout.preferredWidth: modelData.kind === "slider" ? 58 : 31
                                                spacing: 5
                                                Rectangle {
                                                    visible: modelData.kind === "toggle"
                                                    width: 29; height: 16; radius: 8
                                                    color: "transparent"; border.width: 1; border.color: theme.muted
                                                    Rectangle { width: 8; height: 8; radius: 4; y: 4; x: modelData.checked || modelData.active ? 17 : 4; color: theme.paperDetails && (modelData.checked || modelData.active) ? theme.detailAccent : theme.ink; Behavior on x { NumberAnimation { duration: 100 } } }
                                                }
                                                Text { textFormat: Text.PlainText; visible: modelData.kind !== "toggle"; text: (theme.paperDetails && root.editing && selected && modelData.kind === "slider" ? "✎ " : "") + Logic.valueText(modelData, root.editing && selected, root.draftValue); color: theme.ink; font.family: theme.fontFamily; font.pixelSize: modelData.kind === "page" ? 18 : 11; Layout.alignment: Qt.AlignRight }
                                                Text { textFormat: Text.PlainText; visible: modelData.kind === "toggle"; text: Logic.valueText(modelData, false, 0); color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 8; Layout.alignment: Qt.AlignRight }
                                            }
                                        }
                                        MouseArea {
                                            id: itemMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: modelData.enabled === false ? Qt.ArrowCursor : Qt.PointingHandCursor
                                            onClicked: { root.itemIndex = index; root.focusArea = "items"; root.activate(modelData); keyboard.forceActiveFocus(); }
                                        }
                                        ToolTip {
                                            id: itemTip
                                            visible: (itemMouse.containsMouse || itemRow.selected) && text.length > 0
                                            delay: 900
                                            timeout: 7000
                                            text: Logic.tooltipText(modelData)
                                            contentItem: Text { text: itemTip.text; textFormat: Text.PlainText; color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 10; wrapMode: Text.WrapAnywhere }
                                            background: Rectangle { color: theme.background; border.color: theme.line; radius: 4 }
                                            width: Math.min(implicitWidth, itemRow.width)
                                        }
                                        Canvas {
                                            visible: modelData.presentation === "project" && modelData.bookmarked === true
                                            anchors.top: parent.top; anchors.right: parent.right; anchors.rightMargin: 30
                                            width: 12; height: 23
                                            onPaint: {
                                                var ctx = getContext("2d"); ctx.clearRect(0, 0, width, height);
                                                ctx.fillStyle = theme.detailAccent;
                                                ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(width, 0);
                                                ctx.lineTo(width, height); ctx.lineTo(width / 2, height - 5);
                                                ctx.lineTo(0, height); ctx.closePath(); ctx.fill();
                                            }
                                        }
                                        ToolButton {
                                            visible: modelData.presentation === "project" || modelData.presentation === "library"
                                            anchors.bottom: parent.bottom; anchors.right: parent.right
                                            anchors.rightMargin: 8; anchors.bottomMargin: 2
                                            width: 23; height: 23
                                            text: modelData.presentation === "library" ? "⏏" : modelData.bookmarked ? "◆" : "◇"
                                            font.pixelSize: 12
                                            background: Rectangle { color: root.buttonShade(parent.down, parent.hovered); radius: 3 }
                                            contentItem: Text { text: parent.text; color: modelData.presentation === "project" && modelData.bookmarked ? theme.detailAccent : theme.ink; font: parent.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                            Accessible.name: modelData.presentation === "library" ? "Eject drive (e)" : "Toggle bookmark ribbon (b)"
                                            ToolTip.visible: hovered
                                            ToolTip.text: Accessible.name
                                            onClicked: {
                                                root.itemIndex = index; root.focusArea = "items";
                                                if (modelData.presentation === "library") root.eject(modelData); else root.bookmark(modelData);
                                                keyboard.forceActiveFocus();
                                            }
                                        }
                                    }
                                }

                                Column {
                                    anchors.centerIn: parent
                                    width: parent.width - 28
                                    spacing: 15
                                    visible: !(root.pickerActive && root.pickerPrompt) && !root.pendingConfirm && !root.entries.length && !viewProcess.running && !groupProcess.running
                                    Text { textFormat: Text.PlainText; width: parent.width; text: root.page === "root" ? "✎" : "·"; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 34; horizontalAlignment: Text.AlignHCenter }
                                    Text { textFormat: Text.PlainText; width: parent.width; text: root.page === "root" ? "everything in its little place." : root.page === "library" ? "the shelves are quiet." : root.page === "bookmarks" ? "save your place." : root.page === "downloads" ? "nothing in the post." : "nothing here just yet."; color: theme.ink; font.family: theme.headingFont; font.italic: true; font.pixelSize: 18; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap }
                                    Text { textFormat: Text.PlainText; width: parent.width; text: root.page === "root" ? "choose a group on the left\nor press / to find any action." : root.page === "library" ? "plug in a removable drive\nand its library card will appear here." : root.page === "bookmarks" ? "press b on a project card\nto leave a little ribbon here." : root.page === "downloads" ? "your latest downloads will land here.\npress / to filter, or h to go back." : "try another search, or h to go back."; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 10; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.5; wrapMode: Text.WordWrap }
                                }

                                Item {
                                    id: confirmationCard
                                    anchors.centerIn: parent
                                    width: parent.width - 24
                                    height: confirmationContent.implicitHeight + (theme.paperDetails ? 48 : 0)
                                    visible: root.pendingConfirm !== null
                                    PaperShadow {
                                        visible: theme.paperDetails
                                        ink: theme.ink
                                    }
                                    Canvas {
                                        visible: theme.paperDetails
                                        anchors.fill: parent
                                        onWidthChanged: requestPaint()
                                        onHeightChanged: requestPaint()
                                        onPaint: {
                                            var ctx = getContext("2d"), fold = 18, w = width - .5, h = height - .5;
                                            ctx.clearRect(0, 0, width, height);
                                            ctx.fillStyle = theme.background;
                                            ctx.strokeStyle = Qt.alpha(theme.line, 0.7);
                                            ctx.lineWidth = 1;
                                            ctx.beginPath(); ctx.moveTo(.5, .5); ctx.lineTo(w - fold, .5);
                                            ctx.lineTo(w, fold); ctx.lineTo(w, h); ctx.lineTo(.5, h); ctx.closePath();
                                            ctx.fill(); ctx.stroke();
                                            ctx.fillStyle = theme.focusFill;
                                            ctx.beginPath(); ctx.moveTo(w - fold, .5); ctx.lineTo(w - fold, fold);
                                            ctx.lineTo(w, fold); ctx.closePath(); ctx.fill(); ctx.stroke();
                                        }
                                    }
                                    ColumnLayout {
                                        id: confirmationContent
                                        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                                        anchors.margins: theme.paperDetails ? 24 : 0
                                        spacing: 20
                                        Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: root.pendingConfirm ? root.pendingConfirm.label + "?" : ""; color: theme.ink; font.family: theme.headingFont; font.italic: true; font.pixelSize: 24; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap }
                                        Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: root.pendingConfirm && typeof root.pendingConfirm.confirm === "string" ? root.pendingConfirm.confirm : "one moment before you go.\nthis action needs your confirmation."; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; lineHeight: 1.5 }
                                        RowLayout {
                                            Layout.alignment: Qt.AlignHCenter
                                            spacing: 12
                                            Repeater {
                                                model: ["stay here", Logic.confirmationLabel(root.pendingConfirm)]
                                                delegate: Rectangle {
                                                    required property string modelData
                                                    required property int index
                                                    width: Math.max(116, confirmationButtonText.implicitWidth + 28); height: 42; radius: 4
                                                    color: root.confirmYes === (index === 1) ? (theme.paperDetails ? theme.focusFill : Qt.alpha(theme.selection, theme.selectionOpacity)) : theme.surface
                                                    border.width: 1; border.color: theme.line
                                                    Text { id: confirmationButtonText; textFormat: Text.PlainText; anchors.centerIn: parent; text: modelData; color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 11 }
                                                    MouseArea { anchors.fill: parent; onClicked: { var item = root.pendingConfirm; root.pendingConfirm = null; if (index === 1) root.activate(item, true); } }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Text { visible: root.message.length > 0; textFormat: Text.PlainText; text: (root.failed ? "! " : "✿ ") + root.message; color: root.failed ? theme.error : theme.muted; font.family: theme.fontFamily; font.pixelSize: 10; Layout.fillWidth: true; elide: Text.ElideRight; Accessible.role: Accessible.StaticText; Accessible.name: root.message }
                    Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }
                    Text {
                        textFormat: Text.PlainText
                        text: Logic.footerHint({confirming: root.pendingConfirm !== null, busy: root.actionBusy,
                            prompt: root.pickerActive && root.pickerPrompt, searching: root.searching,
                            picker: root.pickerActive, editing: root.editing, focus: root.focusArea}, root.entries[root.itemIndex])
                        color: theme.muted; font.family: theme.fontFamily
                        font.pixelSize: panel.width < 580 ? 9 : 10
                        Layout.fillWidth: true; elide: Text.ElideRight
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        barWrite.restart();
        if (Quickshell.env("FOXML_DRAWER_PREVIEW") === "1") show("sound");
    }
    Component.onDestruction: { finishPicker({cancel: true}); syncBar(true); }
}
