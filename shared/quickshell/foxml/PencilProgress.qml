import QtQuick

Item {
    id: ruler
    required property var theme
    property real value: 0
    property bool tickMarks: false
    readonly property real fraction: isFinite(value) ? Math.max(0, Math.min(100, value)) / 100 : 0
    readonly property real railY: tickMarks ? 5 : height / 2
    implicitHeight: tickMarks ? 14 : 8

    Rectangle { width: parent.width; height: 1; y: ruler.railY; color: ruler.theme.line }
    Rectangle { width: parent.width * ruler.fraction; height: 2; y: ruler.railY - 1; color: ruler.theme.ink }
    Repeater {
        model: ruler.tickMarks ? 11 : 0
        Rectangle {
            required property int index
            x: index * Math.max(0, ruler.width - 1) / 10
            y: ruler.railY + 3
            width: 1; height: index % 5 === 0 ? 5 : 3
            color: ruler.theme.line
        }
    }
    Rectangle {
        objectName: "pencil-progress-tip"
        visible: ruler.theme.paperDetails
        width: ruler.tickMarks ? 5 : 4; height: ruler.tickMarks ? 9 : 6
        radius: 2
        x: Math.max(0, Math.min(parent.width - width, parent.width * ruler.fraction - width / 2))
        y: ruler.railY - height / 2
        color: ruler.theme.highlight
        border.color: ruler.theme.ink; border.width: .6
    }
}
