import QtQuick

Canvas {
    id: clip
    required property var theme
    property bool linked: false
    implicitWidth: 24
    implicitHeight: 24
    onLinkedChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
        var c=getContext("2d");c.reset();c.scale(width/24,height/24);
        if(linked){c.beginPath();c.ellipse(7,7,10,10);c.fillStyle=theme.highlight;c.fill();}
        function paperclip(x,y,angle,ink) {
            c.save();c.translate(x,y);c.rotate(angle);c.beginPath();
            c.moveTo(-1,-4);c.lineTo(-1,3);c.quadraticCurveTo(-1,5,1,5);
            c.quadraticCurveTo(3,5,3,3);c.lineTo(3,-5);c.quadraticCurveTo(3,-8,0,-8);
            c.quadraticCurveTo(-3,-8,-3,-5);c.lineTo(-3,4);
            c.lineWidth=1.2;c.lineCap="round";c.lineJoin="round";c.strokeStyle=ink;c.stroke();c.restore();
        }
        if(linked){paperclip(9,11,.6,theme.ink);paperclip(15,15,.6,theme.ink);}
        else paperclip(12,13,.6,theme.muted);
    }
}
