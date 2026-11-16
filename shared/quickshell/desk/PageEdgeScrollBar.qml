import QtQuick
import QtQuick.Controls

ScrollBar {
    id: control
    required property var theme
    minimumSize: theme.paperDetails ? Math.min(1, 26 / Math.max(1, availableHeight)) : retro ? Math.min(1, theme.cell / Math.max(1, availableHeight)) : 0
    // Retro: a column of ░ with a █ thumb, one character cell wide.
    readonly property bool retro: theme.style === "retro"
    Component.onCompleted: if (retro) { padding = 0; background = retroTrack.createObject(control); }
    Component {
        id: retroTrack
        Text {
            width: control.theme.cellW
            text: "░\n".repeat(Math.max(1, Math.floor(control.height / control.theme.cell))).trim()
            textFormat: Text.PlainText; color: control.theme.muted
            font.family: control.theme.fontFamily; font.pixelSize: control.theme.cell; renderType: Text.NativeRendering
            lineHeightMode: Text.FixedHeight; lineHeight: control.theme.cell
        }
    }
    contentItem: Item {
        implicitWidth: control.retro ? control.theme.cellW : control.theme.paperDetails ? 12 : 4
        implicitHeight: control.theme.paperDetails ? 26 : 20
        Rectangle {
            objectName: "page-edge-marker"
            width: control.theme.paperDetails ? 6 : parent.width
            height: control.theme.paperDetails ? Math.min(26, parent.height) : parent.height
            x: parent.width - width
            // The native thumb keeps its proportional hit area. Move the small
            // visible notch within it so the notch reaches both page edges.
            y: control.theme.paperDetails ? Math.max(0, parent.height - height)
                * Math.max(0, Math.min(1, control.visualPosition / Math.max(.00001, 1 - control.visualSize))) : 0
            radius: control.retro ? 0 : 2
            color: control.retro ? control.theme.ink : control.theme.paperDetails ? control.theme.highlight : control.theme.line
            border.width: control.theme.paperDetails ? .6 : 0
            border.color: Qt.alpha(control.theme.muted, control.pressed ? .8 : .48)
            Rectangle {
                visible: control.theme.paperDetails
                anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
                width: 1; color: Qt.alpha(control.theme.ink, .12)
            }
        }
    }
}
