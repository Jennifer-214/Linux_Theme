import QtQuick
import "DrawerLogic.js" as Logic

// How full a Claude session's context is, as five short meter segments. Berry from 80%.
// A context tidied a moment ago (`fresh`) shows a brief reset indicator.
Row {
    id: hearts
    required property var theme
    property real percent: -1
    property bool fresh: false
    readonly property bool sparkling: glintIn.running
    signal sparkle()
    onFreshChanged: if (fresh) sparkle()
    Component.onCompleted: if (fresh) sparkle()
    readonly property int filled: Logic.contextHearts(percent)
    spacing: 3
    visible: filled >= 0
    // Retro: "[███░░] 41%" in character cells.
    readonly property bool retro: theme.style === "retro"
    TermText { visible: hearts.retro; theme: hearts.theme; text: visible ? Logic.retroBar(hearts.percent, 5) + " " + Math.round(hearts.percent) + "%" : ""; color: hearts.percent >= 80 ? hearts.theme.error : hearts.theme.ink }
    Repeater {
        model: hearts.retro ? 0 : 5
        Item {
            required property int index
            width: 9; height: 11
            Rectangle {
                anchors.centerIn: parent
                width: 9; height: 4; radius: 1
                color: parent.index < hearts.filled ? (hearts.percent >= 80 ? hearts.theme.error : hearts.theme.botanicalInk) : "transparent"
                border.width: parent.index < hearts.filled ? 0 : .7
                border.color: hearts.theme.muted
            }
        }
    }

    Text {
        id: glint
        objectName: "context-sparkle"
        visible: !hearts.retro
        text: "↺"; textFormat: Text.PlainText; opacity: 0
        color: hearts.theme.gardenShades[3]; font.pixelSize: 10
        SequentialAnimation {
            id: glintIn
            PauseAnimation { duration: 450 }
            NumberAnimation { target: glint; property: "opacity"; to: 1; duration: 140 }
            PauseAnimation { duration: 500 }
            NumberAnimation { target: glint; property: "opacity"; to: 0; duration: 400 }
        }
        Connections { target: hearts; function onSparkle() { glintIn.restart() } }
    }
    Accessible.role: Accessible.StaticText
    Accessible.name: percent >= 0 ? Math.round(percent) + "% of its context" : ""
}
