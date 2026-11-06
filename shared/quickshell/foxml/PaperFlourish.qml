import QtQuick

Canvas {
    id: flourish
    required property var theme
    property string kind: "underline"
    visible: theme.paperDetails && width > 0
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onKindChanged: requestPaint()
    Connections {
        target: flourish.theme
        function onHighlightChanged() { flourish.requestPaint(); }
        function onMutedChanged() { flourish.requestPaint(); }
    }
    onPaint: {
        var c = getContext("2d"); c.reset();
        var w = width, h = height;
        c.lineCap = "round"; c.lineJoin = "round";
        if (kind === "swash") {
            c.fillStyle = Qt.alpha(theme.highlight, .8);
            c.beginPath(); c.moveTo(2, h * .12);
            c.bezierCurveTo(w * .25, 0, w * .65, h * .22, w - 6, h * .05);
            c.lineTo(w - 1, h * .85);
            c.bezierCurveTo(w * .7, h, w * .35, h * .78, 0, h * .97);
            c.closePath(); c.fill();
        } else if (kind === "circle") {
            c.strokeStyle = Qt.alpha(theme.muted, .55); c.lineWidth = .8;
            c.beginPath(); c.moveTo(w * .76, h * .2);
            c.bezierCurveTo(w * .35, h * -.02, w * .02, h * .2, w * .12, h * .65);
            c.bezierCurveTo(w * .22, h * 1.04, w * .98, h * .92, w * .94, h * .46);
            c.bezierCurveTo(w * .92, h * .32, w * .84, h * .25, w * .76, h * .23);
            c.stroke();
        } else {
            c.strokeStyle = theme.highlight; c.lineWidth = Math.min(2, h / 2);
            c.beginPath(); c.moveTo(1, h * .45);
            c.bezierCurveTo(w * .25, h * .15, w * .65, h * .85, w - 1, h * .4);
            c.stroke();
        }
    }
}
