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
    property string edgeStyle: theme.paperDetails && width >= 96 ? "label" : "bookmark"
    readonly property real foldSize: edgeStyle === "page" ? Math.min(44, width * .09, depth * .09) : 0
    property real shadowStrength: holdingPaper ? .14 : .055
    Behavior on shadowStrength { NumberAnimation { duration: 70 } }
    implicitHeight: depth + 4
    onDepthChanged: surface.requestPaint()
    onEdgeStyleChanged: surface.requestPaint()
    Canvas {
        id: surface
        anchors.fill: parent
        visible: ribbon.drawSheet
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections { target: ribbon; function onSelectedChanged() { surface.requestPaint(); } function onHoveredChanged() { surface.requestPaint(); } function onPressedChanged() { surface.requestPaint(); } function onShadowStrengthChanged() { surface.requestPaint(); } }
        onPaint: {
            var ctx = getContext("2d"); ctx.reset(); var w = Math.max(1, width - 3), h = ribbon.depth;
            var page = ribbon.theme.paperDetails && ribbon.edgeStyle === "page";
            var label = ribbon.theme.paperDetails && ribbon.edgeStyle === "label";
            var r = label ? 7 : 4, fold = ribbon.foldSize;
            function edge(dx,dy,outline) {
                ctx.moveTo(outline ? w+dx : dx,dy);ctx.lineTo(w+dx,dy);
                if (page) {ctx.lineTo(w+dx,h-fold+dy);ctx.lineTo(w-fold+dx,h+dy);}
                else {
                    ctx.lineTo(w+dx,h+dy-r);ctx.quadraticCurveTo(w+dx,h+dy,w+dx-r,h+dy);
                    if (ribbon.theme.paperDetails && !label) {ctx.lineTo(w/2+7+dx,h+dy);ctx.lineTo(w/2+dx,h-6+dy);ctx.lineTo(w/2-7+dx,h+dy);}
                }
                ctx.lineTo(dx+r,h+dy);ctx.quadraticCurveTo(dx,h+dy,dx,h-r+dy);ctx.lineTo(dx,dy);
                if (!outline) ctx.closePath();
            }
            ctx.beginPath();edge(2,3);ctx.fillStyle=Qt.alpha(ribbon.theme.ink,ribbon.pressed ? .025 : ribbon.shadowStrength);ctx.fill();
            if (page || label) {
                ctx.beginPath();edge(1,3);ctx.fillStyle=ribbon.theme.background;ctx.fill();
                ctx.strokeStyle=Qt.alpha(ribbon.theme.line,.55);ctx.lineWidth=.7;ctx.stroke();
            }
            ctx.beginPath();edge(0,0);ctx.fillStyle=ribbon.selected ? ribbon.theme.highlight : ribbon.theme.background;ctx.fill();
            if(ribbon.hovered && !ribbon.selected && ribbon.theme.paperDetails) {ctx.beginPath();edge(0,0);ctx.fillStyle=ribbon.theme.hoverFill;ctx.fill();}
            ctx.beginPath();edge(0,0,true);
            ctx.lineWidth=1;ctx.strokeStyle=ribbon.theme.line;ctx.stroke();
            if (page) {
                ctx.beginPath();ctx.moveTo(w-fold,h);ctx.lineTo(w-fold,h-fold);ctx.lineTo(w,h-fold);ctx.closePath();
                ctx.fillStyle=Qt.alpha(ribbon.theme.highlight,.24);ctx.fill();
                ctx.beginPath();ctx.moveTo(w-fold,h);ctx.lineTo(w-fold,h-fold);ctx.lineTo(w,h-fold);
                ctx.strokeStyle=Qt.alpha(ribbon.theme.line,.8);ctx.lineWidth=.8;ctx.stroke();
                ctx.beginPath();ctx.moveTo(14,Math.min(130,h*.24));ctx.lineTo(14,h-44);
                ctx.strokeStyle=Qt.alpha(ribbon.theme.highlight,.4);ctx.lineWidth=.7;ctx.stroke();
            }
        }
    }
    Item { id: content; anchors.fill: parent; anchors.leftMargin: ribbon.inset; anchors.rightMargin: ribbon.inset + 3; anchors.topMargin: 7; anchors.bottomMargin: 14 }
}
