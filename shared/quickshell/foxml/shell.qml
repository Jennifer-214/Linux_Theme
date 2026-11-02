import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "DrawerLogic.js" as Logic

ShellRoot {
    id: root

    property bool opened: false
    property bool searching: false
    property string searchPage: "search"
    property bool editing: false
    property bool actionBusy: false
    property string page: "root"
    property string pageTitle: "a little room to think."
    property string groupId: ""
    property string message: "choose a drawer, make yourself at home."
    property bool failed: false
    property var groups: []
    property var entries: []
    property var trail: []
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
    property var nextView: null
    property var nextAction: null
    property string backend: Quickshell.env("FOXML_DRAWER_BACKEND") || "fox-drawer"

    Theme { id: theme }

    function backendCommand(args) {
        return [backend].concat(["--config", Quickshell.shellPath("menus.json")]).concat(args);
    }

    function note(text, error) {
        message = text;
        failed = error === true;
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
                if (gi >= 0) groupIndex = gi;
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
        opened = true;
        searching = false;
        editing = false;
        pendingConfirm = null;
        searchInput.text = "";
        trail = [];
        page = pageId || "root";
        navigationSerial++;
        focusArea = page === "root" ? "groups" : "items";
        note("j / k move · l opens a drawer · / finds a little thing.");
        if (!groupProcess.running) groupProcess.running = true;
        if (page === "root") {
            entries = [];
            pageTitle = "a little room to think.";
            groupId = "";
        } else requestView();
        Qt.callLater(function() { keyboard.forceActiveFocus(); });
    }

    function hide() {
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
        if (!groups[index]) return;
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
            note("choose another little drawer, or Esc to close.");
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
        note("type normally here — even h, j, k and l.");
    }

    function step(delta) {
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
            note("found it. Enter to use this little control.");
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
            note("h / l adjust · Enter or Esc finishes.");
            return;
        }
        if (item.confirm && !confirmed) {
            pendingConfirm = item;
            confirmYes = false;
            return;
        }
        runAction(item, undefined, confirmed === true);
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
        var k = event.key;
        if (searching) {
            if (k === Qt.Key_Escape) { goBack(); event.accepted = true; }
            else if (k === Qt.Key_Down || k === Qt.Key_Up) { step(k === Qt.Key_Down ? 1 : -1); event.accepted = true; }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
                activate(entries[itemIndex]); event.accepted = true;
            }
            return;
        }
        if (k === Qt.Key_Escape) goBack();
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
            if (page !== "root") focusArea = focusArea === "groups" ? "items" : "groups";
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
            try {
                var data = JSON.parse(groupOut.text);
                if (code !== 0 || data.error) throw new Error(data.error || "Cannot read menu groups.");
                root.groups = Array.isArray(data.items) ? data.items : [];
                var gi = root.groups.findIndex(function(g) { return g.page === root.page || g.id === root.groupId; });
                if (gi >= 0) root.groupIndex = gi;
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
                    if (root.opened && location === root.navigationSerial && (result.close || (item && item.close))) root.hide();
                    else if (root.opened && location === root.navigationSerial && result.page) root.show(result.page);
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
    Timer { interval: 4000; repeat: true; running: root.opened && !root.searching && !root.editing && !root.pendingConfirm && !root.actionBusy; onTriggered: root.requestView() }

    PanelWindow {
        id: panel
        visible: root.opened
        anchors { top: true; right: true }
        margins { top: 63; right: 20 }
        implicitWidth: Math.min(790, (screen ? screen.width : 1280) - 32)
        implicitHeight: Math.min(624, (screen ? screen.height : 800) - 96)
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

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    spacing: 14

                    RowLayout {
                        Layout.fillWidth: true
                        Text { textFormat: Text.PlainText; text: "// THE QUIET CORNER"; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 10; font.letterSpacing: 1 }
                        Item { Layout.fillWidth: true }
                        Rectangle { width: 5; height: 5; radius: 3; color: root.failed ? theme.error : theme.success }
                        Text { textFormat: Text.PlainText; text: root.actionBusy ? "WORKING" : root.searching ? "SEARCH" : root.editing ? "ADJUST" : "NORMAL"; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9 }
                        ToolButton {
                            text: "×"
                            font.pixelSize: 19
                            palette.buttonText: theme.muted
                            background: Item {}
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
                            Layout.preferredWidth: panel.width < 580 ? 125 : 179
                            Layout.fillHeight: true
                            clip: true
                            spacing: 7
                            model: root.groups
                            currentIndex: root.groupIndex
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                width: groupList.width
                                height: 65
                                radius: 4
                                color: index === root.groupIndex ? Qt.alpha(theme.selection, root.focusArea === "groups" ? theme.selectionOpacity : theme.selectionOpacity * .45) : "transparent"
                                border.width: index === root.groupIndex && root.focusArea === "groups" ? 1 : 0
                                border.color: theme.line
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: 11
                                    spacing: 10
                                    Text { textFormat: Text.PlainText; text: Logic.symbol(modelData); color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 19; Layout.preferredWidth: 23 }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 3
                                        Text { textFormat: Text.PlainText; text: modelData.label || ""; color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 12; elide: Text.ElideRight; Layout.fillWidth: true }
                                        Text { textFormat: Text.PlainText; visible: panel.width >= 580; text: modelData.detail || ""; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
                                    }
                                    Text { textFormat: Text.PlainText; text: "›"; color: theme.muted; font.pixelSize: 18 }
                                }
                                MouseArea { anchors.fill: parent; onClicked: root.chooseGroup(index); cursorShape: Qt.PointingHandCursor }
                            }
                        }

                        Rectangle { width: 1; Layout.fillHeight: true; color: theme.line }

                        ColumnLayout {
                            id: drawer
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 10
                            opacity: !root.drawerReady ? 0 : root.page === "root" ? .65 : 1
                            Behavior on opacity { NumberAnimation { duration: 160 } }
                            transform: Translate {
                                x: root.drawerReady ? 0 : 28
                                Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Text { textFormat: Text.PlainText; text: root.searching ? "find a little thing" : root.pageTitle; color: theme.ink; font.family: theme.headingFont; font.italic: true; font.pixelSize: 20; Layout.fillWidth: true; elide: Text.ElideRight }
                                Text { textFormat: Text.PlainText; text: root.page === "root" ? "" : String(root.entries.length).padStart(2, "0"); color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 10 }
                            }
                            Text { textFormat: Text.PlainText; visible: root.page !== "root" && root.trail.length > 0; text: [root.groupId].concat(root.trail.slice(1)).concat([root.page]).join(" › "); color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9; elide: Text.ElideMiddle; Layout.fillWidth: true }

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
                                        placeholderText: "find a little thing…"
                                        placeholderTextColor: theme.muted
                                        selectByMouse: true
                                        background: Item {}
                                        onTextChanged: if (root.searching) searchDebounce.restart()
                                        Keys.onPressed: event => root.key(event)
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
                                    visible: !root.pendingConfirm && root.page !== "root"
                                    clip: true
                                    spacing: 7
                                    model: root.entries
                                    currentIndex: root.itemIndex
                                    boundsBehavior: Flickable.StopAtBounds
                                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                                    delegate: Rectangle {
                                        id: itemRow
                                        required property var modelData
                                        required property int index
                                        property bool selected: index === root.itemIndex && root.focusArea === "items"
                                        property string menuIcon: Logic.iconName(modelData) ? Quickshell.iconPath(Logic.iconName(modelData), true) : ""
                                        width: itemList.width
                                        height: modelData.kind === "slider" ? 91 : modelData.image ? 80 : 72
                                        radius: 4
                                        color: selected ? Qt.alpha(theme.selection, theme.selectionOpacity) : "transparent"
                                        border.width: selected ? 1 : 0
                                        border.color: theme.line
                                        opacity: modelData.enabled === false ? .48 : 1
                                        Rectangle { visible: selected; width: 2; anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; color: theme.accent; radius: 1 }
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
                                            Text { textFormat: Text.PlainText; visible: !modelData.image && !itemRow.menuIcon; text: Logic.symbol(modelData); color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 19; Layout.preferredWidth: visible ? 24 : 0 }
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 4
                                                Text { textFormat: Text.PlainText; text: modelData.label || ""; color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 12; elide: Text.ElideRight; Layout.fillWidth: true }
                                                Text { textFormat: Text.PlainText; text: modelData.detail || ""; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
                                                Rectangle {
                                                    visible: modelData.kind === "slider"
                                                    Layout.fillWidth: true
                                                    Layout.topMargin: 6
                                                    height: 3
                                                    radius: 2
                                                    color: theme.line
                                                    Rectangle { height: 3; radius: 2; width: parent.width * Math.max(0, Math.min(100, root.editing && selected ? root.draftValue : Number(modelData.value || 0))) / 100; color: theme.ink }
                                                }
                                            }
                                            ColumnLayout {
                                                Layout.preferredWidth: modelData.kind === "slider" ? 46 : 31
                                                spacing: 5
                                                Rectangle {
                                                    visible: modelData.kind === "toggle"
                                                    width: 29; height: 16; radius: 8
                                                    color: "transparent"; border.width: 1; border.color: theme.muted
                                                    Rectangle { width: 8; height: 8; radius: 4; y: 4; x: modelData.checked || modelData.active ? 17 : 4; color: theme.ink; Behavior on x { NumberAnimation { duration: 100 } } }
                                                }
                                                Text { textFormat: Text.PlainText; visible: modelData.kind !== "toggle"; text: Logic.valueText(modelData, root.editing && selected, root.draftValue); color: theme.ink; font.family: theme.fontFamily; font.pixelSize: modelData.kind === "page" ? 21 : 11; Layout.alignment: Qt.AlignRight }
                                                Text { textFormat: Text.PlainText; visible: modelData.kind === "toggle" || modelData.kind === "slider"; text: modelData.kind === "slider" ? (root.editing && selected ? "h / l" : "edit ↵") : Logic.valueText(modelData, false, 0); color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 8; Layout.alignment: Qt.AlignRight }
                                            }
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: modelData.enabled === false ? Qt.ArrowCursor : Qt.PointingHandCursor
                                            onClicked: { root.itemIndex = index; root.focusArea = "items"; root.activate(modelData); keyboard.forceActiveFocus(); }
                                        }
                                    }
                                }

                                Column {
                                    anchors.centerIn: parent
                                    width: parent.width - 28
                                    spacing: 15
                                    visible: !root.pendingConfirm && (root.page === "root" || (!root.entries.length && !viewProcess.running))
                                    Text { textFormat: Text.PlainText; width: parent.width; text: root.page === "root" ? "✎" : "·"; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 34; horizontalAlignment: Text.AlignHCenter }
                                    Text { textFormat: Text.PlainText; width: parent.width; text: root.page === "root" ? "everything in its little place." : "nothing here just yet."; color: theme.ink; font.family: theme.headingFont; font.italic: true; font.pixelSize: 18; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap }
                                    Text { textFormat: Text.PlainText; width: parent.width; text: root.page === "root" ? "choose a group on the left\nor press / to find any action." : "try another search, or h to go back."; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 10; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.5; wrapMode: Text.WordWrap }
                                }

                                ColumnLayout {
                                    anchors.centerIn: parent
                                    width: parent.width - 24
                                    spacing: 20
                                    visible: root.pendingConfirm !== null
                                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: root.pendingConfirm ? root.pendingConfirm.label + "?" : ""; color: theme.ink; font.family: theme.headingFont; font.italic: true; font.pixelSize: 24; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap }
                                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: "one moment before you go.\nthis action needs your confirmation."; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; lineHeight: 1.5 }
                                    RowLayout {
                                        Layout.alignment: Qt.AlignHCenter
                                        spacing: 12
                                        Repeater {
                                            model: ["stay here", "continue"]
                                            delegate: Rectangle {
                                                required property string modelData
                                                required property int index
                                                width: 116; height: 42; radius: 4
                                                color: root.confirmYes === (index === 1) ? Qt.alpha(theme.selection, theme.selectionOpacity) : theme.surface
                                                border.width: 1; border.color: theme.line
                                                Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: modelData; color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 11 }
                                                MouseArea { anchors.fill: parent; onClicked: { var item = root.pendingConfirm; root.pendingConfirm = null; if (index === 1) root.activate(item, true); } }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Text { textFormat: Text.PlainText; text: (root.failed ? "! " : "✿ ") + root.message; color: root.failed ? theme.error : theme.muted; font.family: theme.fontFamily; font.pixelSize: 10; Layout.fillWidth: true; elide: Text.ElideRight; Accessible.role: Accessible.StaticText; Accessible.name: root.message }
                    Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }
                    Text { textFormat: Text.PlainText; text: root.searching ? "type to find · ↑ ↓ choose · ↵ select · esc back" : root.editing ? "h l adjust · ↵ / esc finish" : "j k move   h back   l / ↵ open   / find   esc close"; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: panel.width < 580 ? 9 : 10; Layout.fillWidth: true; elide: Text.ElideRight }
                }
            }
        }
    }

    Component.onCompleted: {
        if (Quickshell.env("FOXML_DRAWER_PREVIEW") === "1") show("sound");
    }
}
