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
    property real depth: 43
    property bool compact: false
    property bool tight: false
    property real maxWidth: 560
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
        spacing: 3
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
                theme: workspaces.theme
                width: Math.min(workspaces.tight ? 38 : workspaces.compact ? 68 : 180, Math.max(28, label.implicitWidth + 17))
                depth: current ? workspaces.depth + 7 : workspaces.depth
                selected: current
                pressed: mouse.pressed
                Text {
                    id: label
                    anchors.centerIn: parent
                    text: BarLogic.format(workspaces.spec.format || "{name} {windows}", {name: tab.ws ? tab.ws.name : String(tab.modelData.id), windows:tab.icons}).trim()
                    width: tab.width - 17
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                    textFormat: Text.PlainText
                    font.family: workspaces.theme.fontFamily
                    font.pixelSize: 12
                    font.bold: tab.current
                    color: tab.ws && tab.ws.urgent ? workspaces.theme.error : tab.current || tab.windows.length ? workspaces.theme.ink : workspaces.theme.muted
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
                BarHint { theme: workspaces.theme; visible: mouse.containsMouse; text: "Page " + tab.modelData.id + (tab.windows.length ? " · " + tab.windows.map(function(w) {return w.title;}).join("\n") : " · a little space") }
            }
        }
    }
}
