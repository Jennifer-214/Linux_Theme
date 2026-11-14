import QtQuick

Item {
    id: photo
    required property var theme
    property url source
    readonly property bool ready: image.status === Image.Ready
    implicitWidth: 52
    implicitHeight: 56
    Rectangle {
        objectName: "clipboard-photo-mat"
        anchors.fill: parent; visible: photo.ready
        color: photo.theme.background
        border.color: Qt.alpha(photo.theme.line, .7); border.width: .7
        Rectangle { x: parent.width; y: 2; width: 1; height: parent.height - 2; color: Qt.alpha(photo.theme.ink, .04) }
        Rectangle { x: 2; y: parent.height; width: parent.width - 2; height: 1; color: Qt.alpha(photo.theme.ink, .04) }
    }
    Image {
        id: image
        x: 5; y: 5; width: 42; height: 42
        source: photo.source; sourceSize.width: 84; sourceSize.height: 84
        fillMode: Image.PreserveAspectFit; asynchronous: true; cache: true
        visible: photo.ready
    }
    Canvas {
        id: corner
        objectName: "clipboard-photo-corner"
        x: 40; y: 4; width: 8; height: 8; visible: photo.ready
        Connections { target: photo.theme; function onHighlightChanged() { corner.requestPaint(); } }
        onPaint: {
            var c = getContext("2d"); c.reset();
            c.fillStyle = photo.theme.highlight;
            c.beginPath(); c.moveTo(0, 0); c.lineTo(8, 0); c.lineTo(8, 8); c.closePath(); c.fill();
        }
    }
    Text {
        anchors.centerIn: parent; visible: !photo.ready
        text: "⧉"; color: photo.theme.muted; font.family: photo.theme.fontFamily; font.pixelSize: 18
    }
}
