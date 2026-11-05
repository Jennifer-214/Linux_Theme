import QtQuick
import QtQuick.Controls

ScrollBar {
    id: control
    required property var theme
    minimumSize: theme.paperDetails ? Math.min(1, 26 / Math.max(1, availableHeight)) : 0
    contentItem: Item {
        implicitWidth: control.theme.paperDetails ? 12 : 4
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
            radius: 2
            color: control.theme.paperDetails ? control.theme.highlight : control.theme.line
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
