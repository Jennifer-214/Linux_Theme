import QtQuick

Item {
    id: ribbon
    required property var theme
    default property alias contents: content.data
    property bool selected: false
    property bool hovered: false
    property bool drawSheet: true
    property real depth: 45
    property real inset: 10
    property bool pressed: false
    property bool holdingPaper: false
    property real shadowStrength: holdingPaper ? .14 : .055
    Behavior on shadowStrength { NumberAnimation { duration: 70 } }
    implicitHeight: depth + 4
    Canvas {
        id: surface
        anchors.fill: parent
        visible: ribbon.drawSheet
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections { target: ribbon; function onSelectedChanged() { surface.requestPaint(); } function onHoveredChanged() { surface.requestPaint(); } function onPressedChanged() { surface.requestPaint(); } function onShadowStrengthChanged() { surface.requestPaint(); } }
        onPaint: {
            var ctx = getContext("2d"); ctx.reset(); var w = Math.max(1, width - 3), h = ribbon.depth;
            function edge(dx,dy) {
                ctx.moveTo(dx,dy);ctx.lineTo(w+dx,dy);ctx.lineTo(w+dx,h+dy-4);
                ctx.quadraticCurveTo(w+dx,h+dy,w+dx-4,h+dy);
                if (ribbon.theme.paperDetails) {ctx.lineTo(w/2+7+dx,h+dy);ctx.lineTo(w/2+dx,h-6+dy);ctx.lineTo(w/2-7+dx,h+dy);}
                ctx.lineTo(dx+4,h+dy);ctx.quadraticCurveTo(dx,h+dy,dx,h-4+dy);ctx.closePath();
            }
            ctx.beginPath();edge(2,3);ctx.fillStyle=Qt.alpha(ribbon.theme.ink,ribbon.pressed ? .025 : ribbon.shadowStrength);ctx.fill();
            ctx.beginPath();edge(0,0);ctx.fillStyle=ribbon.selected ? ribbon.theme.highlight : ribbon.theme.background;ctx.fill();
            if(ribbon.hovered && !ribbon.selected && ribbon.theme.paperDetails) {ctx.beginPath();edge(0,0);ctx.fillStyle=ribbon.theme.hoverFill;ctx.fill();}
            ctx.beginPath();ctx.moveTo(w,0);ctx.lineTo(w,h-4);ctx.quadraticCurveTo(w,h,w-4,h);
            if(ribbon.theme.paperDetails){ctx.lineTo(w/2+7,h);ctx.lineTo(w/2,h-6);ctx.lineTo(w/2-7,h);}
            ctx.lineTo(4,h);ctx.quadraticCurveTo(0,h,0,h-4);ctx.lineTo(0,0);
            ctx.lineWidth=1;ctx.strokeStyle=ribbon.theme.line;ctx.stroke();
        }
    }
    Item { id: content; anchors.fill: parent; anchors.leftMargin: ribbon.inset; anchors.rightMargin: ribbon.inset + 3; anchors.topMargin: 7; anchors.bottomMargin: 14 }
}
