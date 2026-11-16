import QtQuick
import QtQuick.Controls
import Quickshell.Hyprland
import "BarLogic.js" as BarLogic

Flickable {
    id: workspaces
    objectName: "bar-workspaces"
    required property var theme
    required property var spec
    required property var output
    property var panel: null
    property real depth: 43
    property bool compact: false
    property bool tight: false
    property real maxWidth: 560
    // Workspace ids where a Claude waits on you; their tabs wear a small pink pin (retro: "2♦").
    property var pins: []
    // Retro: tabs of whole character cells (" 1 "), the current one in reverse video like the bar's alerts, empty ones
    // dimmer, one asking for attention blinking.
    readonly property bool retro: theme.style === "retro"
    readonly property color emptyInk: Qt.alpha(theme.ink, .45)
    property bool blinkOff: false
    Timer {
        interval: 530; repeat: true
        running: workspaces.retro && workspaces.rows.some(function(row) { return !!(row.workspace && row.workspace.urgent); })
        onTriggered: workspaces.blinkOff = !workspaces.blinkOff
        onRunningChanged: if (!running) workspaces.blinkOff = false
    }
    implicitWidth: Math.min(workspaceRow.implicitWidth, maxWidth)
    implicitHeight: depth + 11
    contentWidth: workspaceRow.implicitWidth
    contentHeight: implicitHeight
    clip: true
    flickableDirection: Flickable.HorizontalFlick
    boundsBehavior: Flickable.StopAtBounds
    function followCurrent() {
        var current = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : 0;
        var index = rows.findIndex(function(row) {return row.id === current;});
        var item = tabs.itemAt(index);
        if (!item) return;
        if (item.x < contentX) contentX = item.x;
        else if (item.x + item.width > contentX + width) contentX = item.x + item.width - width;
        contentX = Math.max(0, Math.min(contentX, Math.max(0, contentWidth - width)));
    }
    onWidthChanged: Qt.callLater(followCurrent)
    onContentWidthChanged: Qt.callLater(followCurrent)
    Connections { target: workspaces.monitor; function onActiveWorkspaceChanged() { Qt.callLater(workspaces.followCurrent); } }
    readonly property var monitor: Hyprland.monitorFor(output)
    function activate(request) {
        Hyprland.dispatch(Hyprland.usingLua ? "hl.dsp.focus({workspace=" + JSON.stringify(String(request)) + "})" : "workspace " + request);
    }
    readonly property var rows: {
        var all = Hyprland.workspaces.values;
        var persistent = spec["persistent-workspaces"] || {};
        var ids = (persistent[output.name] || persistent["*"] || []).slice();
        all.forEach(function(ws) {
            if ((spec["all-outputs"] !== false || ws.monitor === monitor) && ids.indexOf(ws.id) < 0) ids.push(ws.id);
        });
        return ids.sort(function(a,b) {return a-b;}).map(function(id) { return {id:id, workspace:all.find(function(ws) {return ws.id === id;}) || null}; });
    }
    Row {
        id: workspaceRow
        spacing: workspaces.retro ? 0 : 3
        Repeater {
            id: tabs
            model: workspaces.rows
            BarRibbon {
                id: tab
                required property var modelData
                readonly property var ws: modelData.workspace
                readonly property bool current: !!(workspaces.monitor && workspaces.monitor.activeWorkspace && workspaces.monitor.activeWorkspace.id === modelData.id)
                readonly property var windows: ws ? ws.toplevels.values : []
                readonly property string allIcons: windows.map(function(w) {return BarLogic.windowIcon((w.lastIpcObject || {}).class || "", workspaces.spec);}).join(workspaces.spec["format-window-separator"] || " ")
                readonly property string icons: workspaces.tight ? "" : workspaces.compact ? allIcons.split(workspaces.spec["format-window-separator"] || " ")[0] : allIcons
                readonly property bool pinned: workspaces.pins.indexOf(modelData.id) >= 0
                readonly property bool reversed: workspaces.retro && (current || (!!(ws && ws.urgent) && !workspaces.blinkOff))
                theme: workspaces.theme
                edgeStyle: "bookmark"
                inset: workspaces.retro ? 0 : 10
                width: workspaces.retro ? label.implicitWidth + 2 * workspaces.theme.cellW
                    : Math.min(workspaces.tight ? 38 : workspaces.compact ? 68 : 180, Math.max(28, label.implicitWidth + 17))
                depth: current && workspaces.theme.style !== "retro" ? workspaces.depth + 7 : workspaces.depth
                selected: current
                pressed: mouse.pressed
                hovered: mouse.containsMouse
                // The same box as the modules' reverse video (BarModule's bar-module-alert).
                Rectangle {
                    objectName: "workspace-reverse"
                    visible: tab.reversed
                    x: 2; y: label.y - 2; width: tab.width - 4; height: workspaces.theme.cell + 4
                    color: workspaces.theme.ink
                }
                Text {
                    id: label
                    // Retro: on the same whole-pixel line as the other modules' text (10 px down the strip).
                    anchors.centerIn: workspaces.retro ? undefined : parent
                    x: workspaces.retro ? workspaces.theme.cellW : Math.round((parent.width - width) / 2); y: 3
                    height: workspaces.retro ? workspaces.theme.cell : implicitHeight
                    text: BarLogic.format(workspaces.spec.format || "{name} {windows}", {name: tab.ws ? tab.ws.name : String(tab.modelData.id), windows:tab.icons}).trim()
                        + (workspaces.retro && tab.pinned ? "♦" : "")
                    width: workspaces.retro ? tab.width - 2 * workspaces.theme.cellW : tab.width - 17
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                    textFormat: Text.PlainText
                    font.family: workspaces.theme.fontFamily
                    font.pixelSize: 12
                    // Retro: Big Blue Term has no bold; reverse video marks the current tab.
                    font.bold: tab.current && workspaces.theme.style !== "retro"
                    renderType: workspaces.theme.textRender
                    color: workspaces.retro ? (tab.reversed ? workspaces.theme.background : tab.windows.length ? workspaces.theme.ink : workspaces.emptyInk)
                        : tab.ws && tab.ws.urgent ? workspaces.theme.error : tab.current || tab.windows.length ? workspaces.theme.ink : workspaces.theme.muted
                }
                Rectangle {
                    objectName: "waiting-pin"
                    visible: tab.pinned && !workspaces.retro
                    anchors.right: parent.right; anchors.top: parent.top
                    anchors.rightMargin: 4; anchors.topMargin: 5
                    width: 5; height: 5; radius: 2.5
                    // Ink on the current (pink) tab, pink on the paper ones: always visible.
                    color: tab.current ? workspaces.theme.ink : (workspaces.theme.detailAccent || workspaces.theme.error)
                }
                Rectangle {
                    anchors.horizontalCenter: label.horizontalCenter
                    anchors.top: label.bottom
                    anchors.topMargin: 1
                    visible: tab.current && workspaces.theme.paperDetails
                    width: 11; height: 1; radius: .5
                    color: workspaces.theme.ink
                }
                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: workspaces.activate(tab.ws && tab.ws.id < 0 ? "name:" + tab.ws.name : tab.modelData.id)
                    onWheel: event => {
                        if (workspaces.spec["disable-scroll"]) return;
                        workspaces.activate(event.angleDelta.y > 0 ? "e-1" : "e+1");
                        event.accepted = true;
                    }
                }
                BarBannerHint { theme:workspaces.theme; panel:workspaces.panel; windows:tab.windows; hovered:mouse.containsMouse && !mouse.pressed; text: (workspaces.theme.paperDetails ? "Page " : "Workspace ") + tab.modelData.id + (tab.windows.length ? "\n" + tab.windows.map(function(w) {return w.title;}).join("\n") : " · empty")
                    + (workspaces.retro && tab.pinned ? "\n♦ a Claude session waits for you here" : "") }
            }
        }
    }
}
