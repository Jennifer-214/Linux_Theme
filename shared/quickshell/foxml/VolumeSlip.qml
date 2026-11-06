import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: slip
    required property var theme
    property var output: null
    property int value: 0
    property bool muted: false
    property bool showing: false
    property real reveal: showing ? 1 : 0
    readonly property bool displayable: showing || reveal > .001
    readonly property alias artwork: slipPaper
    function show(level, quiet) {
        value = Math.max(0, Math.min(150, level)); muted = quiet;
        showing = true; lifetime.restart(); speaker.requestPaint();
    }
    Behavior on reveal { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    Timer { id: lifetime; interval: 1600; onTriggered: slip.showing = false }
    screen: output
    visible: displayable
    anchors { bottom: true }
    margins.bottom: 30
    implicitWidth: 300; implicitHeight: 98
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "foxml-volume"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    color: "transparent"
    mask: Region { width: 0; height: 0 }
    Item {
        id: slipPaper
        anchors.fill: parent
        transform: Translate { y: (1 - slip.reveal) * 12 }
        opacity: slip.reveal
        Rectangle {
            x: 3; y: 3; width: parent.width - 7; height: parent.height - 7
            color: slip.theme.background; radius: 4
            border.width: 1; border.color: slip.theme.line
            Rectangle { x: parent.width; y: 2; width: 2; height: parent.height; color: Qt.alpha(slip.theme.ink, .06) }
            Rectangle { x: 2; y: parent.height; width: parent.width; height: 2; color: Qt.alpha(slip.theme.ink, .06) }
            PaperGrain { anchors.fill: parent; theme: slip.theme }
            Canvas {
                id: speaker
                x: 15; y: 15; width: 47; height: 42
                onPaint: {
                    var c = getContext("2d"); c.reset(); c.lineCap = "round"; c.lineJoin = "round";
                    c.strokeStyle = slip.theme.ink; c.lineWidth = 1.2;
                    c.beginPath(); c.moveTo(4, 17); c.lineTo(11, 17); c.lineTo(20, 9);
                    c.quadraticCurveTo(22, 8, 22, 11); c.lineTo(22, 32);
                    c.lineTo(11, 25); c.lineTo(4, 25); c.closePath(); c.stroke();
                    if (slip.muted) {
                        c.beginPath(); c.moveTo(29, 16); c.lineTo(39, 27); c.moveTo(39, 16); c.lineTo(29, 27); c.stroke();
                    } else {
                        if (slip.value > 0) { c.beginPath(); c.moveTo(28, 16); c.quadraticCurveTo(33, 22, 28, 28); c.stroke(); }
                        if (slip.value > 33) { c.beginPath(); c.moveTo(34, 11); c.quadraticCurveTo(44, 22, 34, 33); c.stroke(); }
                        if (slip.value > 66) { c.beginPath(); c.moveTo(40, 7); c.quadraticCurveTo(53, 22, 40, 37); c.stroke(); }
                    }
                    c.fillStyle = Qt.alpha(slip.theme.highlight, .8);
                    c.beginPath(); c.arc(9, 22, 3, 0, Math.PI * 2); c.fill();
                }
            }
            Text { x: 74; y: 16; text: slip.muted ? "a little quiet." : "a little sound."; color: slip.theme.ink; font.family: slip.theme.headingFont; font.pixelSize: 20; font.italic: true }
            Text { x: 75; y: 43; text: slip.muted ? "muted" : slip.value + "%"; color: slip.theme.muted; font.family: slip.theme.fontFamily; font.pixelSize: 10 }
            PencilProgress { x: 22; y: 68; width: parent.width - 44; value: slip.muted ? 0 : slip.value; tickMarks: true; theme: slip.theme }
        }
    }
}
