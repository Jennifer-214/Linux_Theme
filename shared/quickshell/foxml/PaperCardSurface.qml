import QtQuick

Canvas {
    id: paper
    required property var theme
    required property string presentation
    property color fillColor: theme.background
    property color edgeColor: theme.line
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onFillColorChanged: requestPaint()
    onEdgeColorChanged: requestPaint()
    onPresentationChanged: requestPaint()
    onPaint: {
        var c = getContext("2d"); c.reset();
        var w = Math.max(0, width - 1), h = Math.max(0, height - 1), r = 4;
        c.beginPath(); c.moveTo(r, .5); c.lineTo(w - r, .5);
        c.quadraticCurveTo(w, .5, w, r);
        if (presentation === "download") {
            c.lineTo(w, h - 3);
            var count = Math.max(1, Math.floor(w / 8)), step = (w - .5) / count;
            for (var i = 0; i < count; ++i) {
                var at = w - i * step;
                c.bezierCurveTo(at - step * .25, h - 1, at - step * .75, h - 4, at - step, h - 3);
            }
            c.lineTo(.5, r);
        } else {
            c.lineTo(w, h - r); c.quadraticCurveTo(w, h, w - r, h);
            c.lineTo(r, h); c.quadraticCurveTo(.5, h, .5, h - r);
            c.lineTo(.5, r);
        }
        c.quadraticCurveTo(.5, .5, r, .5); c.closePath();
        c.fillStyle = fillColor; c.fill();
        c.strokeStyle = edgeColor; c.lineWidth = 1; c.stroke();
        if (presentation === "project") {
            c.strokeStyle = Qt.alpha(theme.line, .6); c.lineWidth = .7;
            c.beginPath(); c.moveTo(14, 23); c.lineTo(w - 14, 23);
            c.moveTo(14, 25); c.lineTo(w - 14, 25); c.stroke();
        }
    }
}
