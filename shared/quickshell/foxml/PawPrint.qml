import QtQuick

// A small pencil paw pressed under the active workspace.
Canvas {
    id: paw
    objectName: "workspace-paw"
    required property var theme
    implicitWidth: 11
    implicitHeight: 10
    width: implicitWidth
    height: implicitHeight
    onPaint: {
        var ctx = getContext("2d");
        ctx.reset();
        ctx.fillStyle = Qt.alpha(theme.ink, .66);
        function pad(x, y, rx, ry) {
            ctx.save();
            ctx.translate(x, y);
            ctx.scale(rx, ry);
            ctx.beginPath();
            ctx.arc(0, 0, 1, 0, Math.PI * 2);
            ctx.restore();
            ctx.fill();
        }
        pad(5.5, 6.9, 2.9, 2.3);
        pad(1.7, 4.2, 1.15, 1.45);
        pad(4.1, 2, 1.15, 1.5);
        pad(6.9, 2, 1.15, 1.5);
        pad(9.3, 4.2, 1.15, 1.45);
    }
}
