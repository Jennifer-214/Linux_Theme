import QtQuick

Canvas {
    id: sprig
    required property var theme
    implicitWidth: 28
    implicitHeight: 32
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
        var c = getContext("2d"); c.reset();
        c.scale(width/28,height/32); c.lineWidth=.85;
        c.lineCap="round";c.lineJoin="round";
        c.strokeStyle=Qt.alpha(theme.ink,.8);
        c.beginPath();c.moveTo(9,29);c.bezierCurveTo(16,23,12,12,20,3);c.stroke();
        function leaf(x,y,dx,dy) {
            c.beginPath();c.moveTo(x,y);
            c.quadraticCurveTo(x+dx*.1,y+dy,x+dx,y+dy);
            c.quadraticCurveTo(x+dx,y+dy*.1,x,y);
            c.fillStyle=Qt.alpha(sprig.theme.botanicalInk,.16);c.fill();c.stroke();
        }
        leaf(13,23,-9,-7);leaf(15,19,10,-6);leaf(15,14,-8,-7);leaf(17,10,8,-5);
        c.beginPath();c.ellipse(18,1,4,5);
        c.fillStyle=Qt.alpha(theme.detailAccent,.38);c.fill();c.stroke();
    }
}
