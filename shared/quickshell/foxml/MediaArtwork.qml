import QtQuick

Item {
    id: cover
    required property var theme
    property url source
    readonly property bool ready: image.status === Image.Ready
    implicitWidth: 48
    implicitHeight: 52
    Rectangle {
        objectName: "media-photo-mat"
        visible: cover.ready && cover.theme.paperDetails
        anchors.centerIn: parent; anchors.verticalCenterOffset: 1
        width: 52; height: 55
        color: cover.theme.background
        border.color: Qt.alpha(cover.theme.line, .65); border.width: .6
        Rectangle { x:parent.width; y:2; width:1; height:parent.height-2; color:Qt.alpha(cover.theme.ink,.035) }
        Rectangle { x:2; y:parent.height; width:parent.width-2; height:1; color:Qt.alpha(cover.theme.ink,.035) }
    }
    Image {
        id: image
        anchors.centerIn: parent
        width: 46; height: 46
        source: cover.source
        sourceSize.width: 92; sourceSize.height: 92
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: true
        visible: cover.ready
    }
    Text {
        visible: !cover.ready
        anchors.centerIn: parent
        text: "♪"; color: cover.theme.ink
        font.family: cover.theme.fontFamily; font.pixelSize: 16
    }
    Canvas {
        id: tape
        objectName: "media-washi-tape"
        visible: cover.ready && cover.theme.paperDetails
        width: 34; height: 12; x: (parent.width - width) / 2; y: -1
        rotation: -9
        Connections {
            target: cover.theme
            function onHighlightChanged() { tape.requestPaint(); }
            function onMutedChanged() { tape.requestPaint(); }
            function onBackgroundChanged() { tape.requestPaint(); }
        }
        onPaint: {
            var c = getContext("2d"); c.reset();
            c.fillStyle = Qt.alpha(cover.theme.highlight, .84);
            c.strokeStyle = Qt.alpha(cover.theme.muted, .16); c.lineWidth = .5;
            c.beginPath(); c.moveTo(1,1); c.lineTo(33,1); c.lineTo(31,3); c.lineTo(34,5);
            c.lineTo(32,7); c.lineTo(33,11); c.lineTo(1,11); c.lineTo(3,8);
            c.lineTo(0,6); c.lineTo(2,3); c.closePath(); c.fill(); c.stroke();
            c.strokeStyle = Qt.alpha(cover.theme.background, .28);
            for (var n = 0; n < 6; n++) {
                c.beginPath(); c.moveTo(4+n*5,2); c.lineTo(3+n*5,10); c.stroke();
            }
        }
    }
}
