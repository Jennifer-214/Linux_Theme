import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// The desk overview (Alt+O): every workspace laid out as a photo print on the focused screen, each window drawn
// where it sits. Live captures run only while it is open. hjkl / arrows + Enter, a click or a digit goes there;
// Esc or Alt+O puts the prints away.
Scope {
    id: overview
    required property var theme
    property var screen: null
    property bool opened: false
    property int selected: 0

    readonly property var monitors: Hyprland.monitors.values
    readonly property var workspaces: Hyprland.workspaces.values
        .filter(function(ws) { return ws.id > 0; })
        .sort(function(a, b) { return a.id - b.id; })

    function show(target) {
        Hyprland.refreshToplevels();
        Hyprland.refreshMonitors();
        screen = target;
        var focused = Hyprland.focusedMonitor && Hyprland.focusedMonitor.activeWorkspace ? Hyprland.focusedMonitor.activeWorkspace.id : -1;
        selected = Math.max(0, workspaces.findIndex(function(ws) { return ws.id === focused; }));
        opened = true;
    }
    function hide() { opened = false; }
    function go(index) {
        var ws = workspaces[index];
        hide();
        if (ws) Hyprland.dispatch(Hyprland.usingLua ? "hl.dsp.focus({workspace=" + JSON.stringify(String(ws.id)) + "})" : "workspace " + ws.id);
    }
    // A monitor's size as windows are laid out on it: its mode over its scale, turned for portrait.
    function logical(monitor) {
        var m = monitor ? monitor.lastIpcObject || {} : {};
        var w = Number(m.width || 1920) / Number(m.scale || 1), h = Number(m.height || 1080) / Number(m.scale || 1);
        var turned = Number(m.transform || 0) % 2 === 1;
        return {x: Number(m.x || 0), y: Number(m.y || 0), w: turned ? h : w, h: turned ? w : h};
    }

    IpcHandler {
        target: "overview"
        function toggle(): void { if (overview.opened) overview.hide(); else overview.show(Quickshell.screens.find(function(s) { return Hyprland.focusedMonitor && s.name === Hyprland.focusedMonitor.name; }) || Quickshell.screens[0]); }
        function status(): string { return JSON.stringify({open: overview.opened, selected: overview.selected, workspaces: overview.workspaces.length, screen: overview.screen ? overview.screen.name : ""}); }
    }

    PanelWindow {
        id: desk
        visible: overview.opened
        screen: overview.screen
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.namespace: "foxml-overview"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: overview.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // The desk itself: the paper, a little dimmed, so the prints read as laid on top of it.
        Rectangle { anchors.fill: parent; color: Qt.alpha(overview.theme.background, .97) }
        MouseArea { anchors.fill: parent; onClicked: overview.hide() }

        Item {
            id: board
            anchors.fill: parent
            anchors.margins: Math.max(36, Math.min(width, height) * .06)
            focus: overview.opened
            Keys.onPressed: event => {
                var count = overview.workspaces.length, k = event.key;
                if (k === Qt.Key_Escape || k === Qt.Key_Q || (k === Qt.Key_O && (event.modifiers & Qt.AltModifier))) overview.hide();
                else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) overview.go(overview.selected);
                else if (k === Qt.Key_L || k === Qt.Key_Right) overview.selected = Math.min(count - 1, overview.selected + 1);
                else if (k === Qt.Key_H || k === Qt.Key_Left) overview.selected = Math.max(0, overview.selected - 1);
                else if (k === Qt.Key_J || k === Qt.Key_Down) overview.selected = Math.min(count - 1, overview.selected + grid.columns);
                else if (k === Qt.Key_K || k === Qt.Key_Up) overview.selected = Math.max(0, overview.selected - grid.columns);
                else if (k >= Qt.Key_1 && k <= Qt.Key_9) {
                    var at = overview.workspaces.findIndex(function(ws) { return ws.id === k - Qt.Key_0; });
                    if (at >= 0) overview.go(at);
                } else return;
                event.accepted = true;
            }

            Text {
                id: heading
                text: "the desk."
                color: overview.theme.ink; font.family: overview.theme.headingFont; font.italic: true; font.pixelSize: 30
            }
            Grid {
                id: grid
                readonly property int count: Math.max(1, overview.workspaces.length)
                // Columns so the prints fill the screen's shape: wide screens get rows, tall ones get a column or two.
                columns: Math.max(1, Math.min(count, Math.round(Math.sqrt(count * (board.width / Math.max(1, board.height - heading.height - 24)) / 1.6))))
                readonly property int rows: Math.ceil(count / columns)
                readonly property real cellW: (board.width - (columns - 1) * spacing) / columns
                readonly property real cellH: (board.height - heading.height - 24 - (rows - 1) * spacing) / rows
                anchors.top: heading.bottom; anchors.topMargin: 24
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 28
                Repeater {
                    model: overview.workspaces
                    Item {
                        id: cell
                        required property var modelData
                        required property int index
                        readonly property var area: overview.logical(modelData.monitor)
                        readonly property bool chosen: overview.selected === index
                        // The print keeps the screen's shape inside its cell, with room for the caption below.
                        readonly property real scaleTo: Math.min((grid.cellW - 20) / area.w, (grid.cellH - 46) / area.h)
                        width: grid.cellW; height: grid.cellH
                        Item {
                            id: photo
                            width: cell.area.w * cell.scaleTo + 16; height: cell.area.h * cell.scaleTo + 40
                            anchors.centerIn: parent
                            rotation: cell.chosen ? 0 : (cell.index % 3 - 1) * 1.1
                            scale: cell.chosen ? 1.03 : 1
                            Behavior on scale { NumberAnimation { duration: 120 } }
                            Behavior on rotation { NumberAnimation { duration: 120 } }
                            Rectangle { anchors.fill: parent; x: 2; y: 3; color: Qt.alpha(overview.theme.ink, .08); radius: 2 }
                            Rectangle {
                                anchors.fill: parent
                                color: overview.theme.background; radius: 2
                                border.width: cell.chosen ? 2 : 1
                                border.color: cell.chosen ? overview.theme.detailAccent : Qt.alpha(overview.theme.line, .9)
                            }
                            Item {
                                id: shot
                                x: 8; y: 8; width: parent.width - 16; height: parent.height - 40
                                clip: true
                                Rectangle { anchors.fill: parent; color: Qt.alpha(overview.theme.line, .18) }
                                Repeater {
                                    model: cell.modelData.toplevels.values
                                    Item {
                                        required property var modelData
                                        readonly property var ipc: modelData.lastIpcObject || {}
                                        readonly property var at: ipc.at || [cell.area.x, cell.area.y]
                                        readonly property var size: ipc.size || [cell.area.w, cell.area.h]
                                        x: (at[0] - cell.area.x) * cell.scaleTo
                                        y: (at[1] - cell.area.y) * cell.scaleTo
                                        width: size[0] * cell.scaleTo; height: size[1] * cell.scaleTo
                                        ScreencopyView {
                                            anchors.fill: parent
                                            captureSource: overview.opened && parent.modelData ? parent.modelData.wayland : null
                                            live: overview.opened
                                            constraintSize: Qt.size(Math.ceil(parent.width * 2), Math.ceil(parent.height * 2))
                                        }
                                        Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: Qt.alpha(overview.theme.line, .7) }
                                    }
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: cell.modelData.toplevels.values.length === 0
                                    text: "empty page"; color: overview.theme.muted
                                    font.family: overview.theme.headingFont; font.italic: true; font.pixelSize: 13
                                }
                            }
                            Text {
                                anchors.bottom: parent.bottom; anchors.bottomMargin: 9; x: 10; width: parent.width - 20
                                text: "page " + cell.modelData.id + (cell.modelData.toplevels.values.length
                                      ? " · " + (cell.modelData.toplevels.values[0].title || "") : "")
                                elide: Text.ElideRight; textFormat: Text.PlainText
                                color: overview.theme.ink; font.family: overview.theme.fontFamily; font.pixelSize: 11
                                font.bold: cell.chosen
                            }
                            MouseArea {
                                anchors.fill: parent; hoverEnabled: true
                                onEntered: overview.selected = cell.index
                                onClicked: overview.go(cell.index)
                            }
                        }
                    }
                }
            }
        }
    }
}
