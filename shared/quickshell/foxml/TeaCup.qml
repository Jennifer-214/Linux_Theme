import QtQuick
import QtQuick.Shapes

// The week's Claude plan as a little teacup: the tea is what is left, berry once it runs low.
Item {
    id: cup
    required property var theme
    property int remaining: -1
    visible: remaining >= 0
    implicitWidth: 16; implicitHeight: 13
    readonly property real level: Math.max(0, Math.min(100, remaining)) / 100

    // The tea, clipped to the inside of the cup.
    Item {
        x: 2; y: 2; width: 9; height: 9; clip: true
        Rectangle {
            anchors.bottom: parent.bottom; width: parent.width; height: parent.height * cup.level
            radius: 2
            color: cup.remaining <= 20 ? cup.theme.gardenShades[4] : cup.theme.gardenShades[2]
        }
    }
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: "transparent"; strokeColor: cup.theme.muted; strokeWidth: 1.2
            capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
            // the bowl, then the handle
            PathSvg { path: "M1.5 1.5 H11.5 V8 Q11.5 12 7.5 12 H5.5 Q1.5 12 1.5 8 Z M11.5 3.5 Q15 3.5 15 6 Q15 8.5 11.5 8.5" }
        }
    }
    Accessible.role: Accessible.StaticText
    Accessible.name: remaining >= 0 ? remaining + "% of the week's plan left" : ""
}
