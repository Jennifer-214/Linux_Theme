import QtQuick
import QtQuick.Shapes
import "DrawerLogic.js" as Logic

// How full a Claude session's context is, as five drawn hearts (the font's ♥ is an outline). Berry from 80%.
// A context tidied a moment ago (`fresh`) makes them sparkle once, one after another.
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
    Repeater {
        model: 5
        Shape {
            id: heart
            required property int index
            readonly property bool full: index < hearts.filled
            width: 11; height: 11
            transformOrigin: Item.Center
            preferredRendererType: Shape.CurveRenderer
            SequentialAnimation {
                id: pop
                PauseAnimation { duration: heart.index * 90 }
                NumberAnimation { target: heart; property: "scale"; to: 1.35; duration: 120; easing.type: Easing.OutQuad }
                NumberAnimation { target: heart; property: "scale"; to: 1; duration: 180; easing.type: Easing.InOutQuad }
            }
            Connections { target: hearts; function onSparkle() { pop.restart() } }
            ShapePath {
                scale: Qt.size(11 / 24, 11 / 24)
                fillColor: heart.full ? (hearts.percent >= 80 ? hearts.theme.gardenShades[4] : hearts.theme.gardenShades[3]) : "transparent"
                strokeColor: heart.full ? fillColor : hearts.theme.muted
                strokeWidth: heart.full ? 0 : 1.6
                PathSvg { path: "M12 21.2C6.6 17.6 2.5 14.2 2.5 9.6 2.5 6.6 4.8 4.4 7.6 4.4c1.9 0 3.5 1 4.4 2.6.9-1.6 2.5-2.6 4.4-2.6 2.8 0 5.1 2.2 5.1 5.2 0 4.6-4.1 8-9.5 11.6Z" }
            }
        }
    }
    Text {
        id: glint
        objectName: "context-sparkle"
        text: "✧"; textFormat: Text.PlainText; opacity: 0
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
