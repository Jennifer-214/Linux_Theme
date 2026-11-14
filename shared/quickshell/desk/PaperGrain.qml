import QtQuick
Canvas {
    id: grain
    required property var theme
    visible: theme.paperDetails
    Connections { target: theme; function onInkChanged() { grain.requestPaint(); } }
    onWidthChanged:requestPaint()
    onHeightChanged:requestPaint()
    onPaint: {
        var c=getContext("2d");c.reset();if(!visible)return;var seed=34117;
        function rand(){seed=(seed*1664525+1013904223)>>>0;return seed/4294967296;}
        c.lineWidth=.65;c.lineCap="round";
        for(var i=0;i<width*height*.015;i++) {
            var x=rand()*width,y=rand()*height;
            c.strokeStyle=Qt.alpha(theme.ink,.018+rand()*.025);
            c.beginPath();c.moveTo(x,y);c.lineTo(x+.3+rand()*1.4,y+(rand()-.5)*.7);c.stroke();
        }
    }
}
