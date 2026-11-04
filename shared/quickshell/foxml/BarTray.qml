import QtQuick
import QtQuick.Window
import QtQuick.Controls
import Quickshell
import Quickshell.Services.SystemTray
import "BarLogic.js" as BarLogic

Row {
    id: tray
    required property var theme
    required property var spec
    required property var panel
    spacing: Number(spec.spacing || 8)
    Repeater {
        model: SystemTray.items
        Item {
            id: icon
            required property var modelData
            width: Number(tray.spec["icon-size"] || 16)
            height: 24
            Image { anchors.centerIn: parent; width: parent.width; height: width; source: icon.modelData.icon; sourceSize.width: width * Screen.devicePixelRatio; sourceSize.height: height * Screen.devicePixelRatio }
            MouseArea {
                id: mouse
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                hoverEnabled: true
                onClicked: event => {
                    if (event.button === Qt.MiddleButton) icon.modelData.secondaryActivate();
                    else if (event.button === Qt.RightButton || icon.modelData.onlyMenu) menu.open();
                    else icon.modelData.activate();
                }
                onWheel: event => { icon.modelData.scroll(event.angleDelta.y || event.angleDelta.x, !event.angleDelta.y); event.accepted = true; }
            }
            QsMenuAnchor {
                id: menu
                menu: icon.modelData.menu
                anchor.window: tray.panel
                anchor.rect.x: icon.mapToItem(tray.panel.contentItem, 0, 0).x
                anchor.rect.y: tray.panel.barHeight
            }
            BarHint { theme: tray.theme; visible: mouse.containsMouse; text: BarLogic.plain(icon.modelData.tooltipTitle || icon.modelData.title) + (icon.modelData.tooltipDescription ? "\n" + BarLogic.plain(icon.modelData.tooltipDescription) : "") }
        }
    }
}
