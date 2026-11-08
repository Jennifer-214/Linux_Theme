import QtQuick

// Retain the component interface while showing plan remaining as a plain meter.
Item {
    id: meter
    required property var theme
    property int remaining: -1
    readonly property real level: Math.max(0,Math.min(100,remaining))/100
    visible: remaining>=0
    implicitWidth: 24; implicitHeight: 10
    Rectangle {
        anchors.centerIn: parent
        width: parent.width; height: 5; radius: 1
        color: "transparent"; border.width: .7; border.color: meter.theme.muted
        Rectangle {
            x: 1; y: 1; width: Math.max(0,(parent.width-2)*meter.level); height: 3
            color: meter.remaining<=20 ? meter.theme.error : meter.theme.botanicalInk
        }
    }
    Accessible.role: Accessible.StaticText
    Accessible.name: remaining>=0 ? remaining+"% of the week's plan left" : ""
}
