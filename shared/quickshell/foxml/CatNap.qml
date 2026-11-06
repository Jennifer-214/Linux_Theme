import QtQuick

// The idle pill's cat: asleep while the desktop may rest, one eye open while it stays awake.
Canvas {
    id: cat
    objectName: "bar-cat-nap"
    required property var theme
    property bool awake: false
    implicitWidth: 26
    implicitHeight: 17
    width: implicitWidth
    height: implicitHeight
    onAwakeChanged: requestPaint()
    onPaint: {
        var ctx = getContext("2d");
        ctx.reset();
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        ctx.lineWidth = 1;
        ctx.strokeStyle = theme.ink;
        // Back and tail, curled around the sleeper.
        ctx.beginPath();
        ctx.moveTo(10.5, 5.2);
        ctx.bezierCurveTo(15, 2.5, 23.5, 4.5, 24, 10.5);
        ctx.bezierCurveTo(24.3, 14.5, 20, 15.8, 15.5, 15.5);
        ctx.lineTo(5, 15.5);
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(23.6, 12.5);
        ctx.bezierCurveTo(21, 15, 15.5, 13.8, 14.5, 12.2);
        ctx.stroke();
        // Head, resting on the paws.
        ctx.beginPath();
        ctx.moveTo(2.6, 8.4);
        ctx.lineTo(2.2, 3.6);
        ctx.lineTo(5.5, 5.5);
        ctx.quadraticCurveTo(7.4, 4.9, 9.3, 5.5);
        ctx.lineTo(12.4, 3.6);
        ctx.lineTo(12.1, 8.4);
        ctx.bezierCurveTo(12.9, 11.2, 11.2, 14, 7.4, 14);
        ctx.bezierCurveTo(3.6, 14, 1.8, 11.2, 2.6, 8.4);
        ctx.closePath();
        ctx.fillStyle = theme.background;
        ctx.fill();
        ctx.stroke();
        // Left eye stays shut; the right one opens when the desktop is kept awake.
        ctx.beginPath();
        ctx.moveTo(4.1, 9.2);
        ctx.quadraticCurveTo(5.3, 10.4, 6.5, 9.2);
        if (!awake) {
            ctx.moveTo(8.3, 9.2);
            ctx.quadraticCurveTo(9.5, 10.4, 10.7, 9.2);
        }
        ctx.stroke();
        if (awake) {
            ctx.beginPath();
            ctx.arc(9.5, 9.1, 1.25, 0, Math.PI * 2);
            ctx.fillStyle = theme.ink;
            ctx.fill();
        }
        // Nose.
        ctx.beginPath();
        ctx.arc(7.4, 11.3, .55, 0, Math.PI * 2);
        ctx.fillStyle = theme.ink;
        ctx.fill();
    }
}
