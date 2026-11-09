import QtQuick
import Quickshell
import Quickshell.Wayland

// The little paper slip for a volume, brightness or song change. One slip serves all three, so they never stack.
PanelWindow {
    id: slip
    required property var theme
    property var output: null
    property string kind: "sound"
    property int value: 0
    property bool muted: false
    // The song: what the player said, as plain text; artwork only from a file or the web.
    property string title: ""
    property string artist: ""
    property string playState: ""
    property string artUrl: ""
    readonly property bool song: kind === "media"
    property bool showing: false
    property real reveal: showing ? 1 : 0
    readonly property bool displayable: showing || reveal > .001
    readonly property alias artwork: slipPaper
    // Volume goes past full (wpctl --limit 1.5); the ruler then spans 150% with full marked on it.
    readonly property bool overFull: kind === "sound" && !muted && value > 100
    readonly property real span: overFull ? 150 : 100
    readonly property string heading: song ? "a little song." : kind === "light" ? "a little light." : muted ? "a little quiet." : overFull ? "a little loud." : "a little sound."
    readonly property string detail: song ? (title ? title + (artist ? " · " + artist : "") : artist || "nothing is playing.")
        : kind === "sound" && muted ? "muted" : value + "%" + (overFull ? " · past full" : "")
    function present(what, level, quiet) {
        kind = what; value = Math.max(0, Math.min(what === "light" ? 100 : 150, level)); muted = what === "sound" && quiet;
        showing = true; lifetime.interval = 1600; lifetime.restart(); glyph.requestPaint();
    }
    function plain(text) { return String(text || "").replace(/[\x00-\x1f\x7f]+/g, " ").trim().slice(0, 300); }
    function showMedia(name, by, state, art) {
        title = plain(name); artist = plain(by);
        playState = /^(Playing|Paused|Stopped)$/.test(state) ? String(state).toLowerCase() : "";
        art = String(art || "");
        artUrl = art.length < 4096 && /^(file:\/\/\/|https?:\/\/)[^\s\x00-\x1f]+$/.test(art) ? art : "";
        kind = "media"; showing = true; lifetime.interval = 2600; lifetime.restart();
    }
    function showVolume(level, quiet) { present("sound", level, quiet); }
    function showBrightness(level) { present("light", level, false); }
    Behavior on reveal { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    Timer { id: lifetime; interval: 1600; onTriggered: slip.showing = false }
    screen: output
    visible: displayable
    anchors { bottom: true }
    margins.bottom: 30
    implicitWidth: song ? 340 : 300; implicitHeight: 98
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
                id: glyph
                objectName: "level-slip-glyph"
                visible: !slip.song
                x: 15; y: 15; width: 47; height: 42
                onPaint: {
                    var c = getContext("2d"); c.reset(); c.lineCap = "round"; c.lineJoin = "round";
                    c.strokeStyle = slip.theme.ink; c.lineWidth = 1.2;
                    if (slip.kind === "light") {
                        // A pencil sun: its rays lengthen with the level.
                        var reach = 3 + 8 * slip.value / 100;
                        c.fillStyle = Qt.alpha(slip.theme.highlight, .8);
                        c.beginPath(); c.arc(22, 21, 7, 0, Math.PI * 2); c.fill(); c.stroke();
                        for (var ray = 0; ray < 8; ray++) {
                            var angle = ray * Math.PI / 4, cos = Math.cos(angle), sin = Math.sin(angle);
                            c.beginPath(); c.moveTo(22 + cos * 10, 21 + sin * 10); c.lineTo(22 + cos * (10 + reach), 21 + sin * (10 + reach)); c.stroke();
                        }
                        return;
                    }
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
            MediaArtwork {
                objectName: "level-slip-artwork"
                visible: slip.song
                theme: slip.theme
                source: slip.song ? slip.artUrl : ""
                x: 15; y: 21; width: 48; height: 52
            }
            Text { objectName: "level-slip-heading"; x: 74; y: 16; text: slip.heading; textFormat: Text.PlainText; color: slip.theme.ink; font.family: slip.theme.headingFont; font.pixelSize: 20; font.italic: true }
            Text {
                objectName: "level-slip-detail"; x: 75; y: 43; width: parent.width - x - 14; text: slip.detail; textFormat: Text.PlainText; elide: Text.ElideRight
                color: slip.song ? slip.theme.ink : slip.overFull ? slip.theme.detailAccent : slip.theme.muted; font.family: slip.theme.fontFamily; font.pixelSize: slip.song ? 11 : 10
            }
            StateTag {
                objectName: "level-slip-state"
                visible: slip.song && text.length > 0
                theme: slip.theme
                text: slip.playState
                x: 75; y: 64
            }
            PencilProgress {
                id: levelRuler
                visible: !slip.song
                x: 22; y: 68; width: parent.width - 44
                value: slip.muted ? 0 : 100 * slip.value / slip.span
                tickMarks: true; theme: slip.theme
            }
            // Where full is, once the ruler runs past it.
            Rectangle {
                objectName: "level-slip-full-mark"
                visible: slip.overFull && !slip.song
                x: levelRuler.x + (levelRuler.width - 1) * 100 / slip.span - .5; y: levelRuler.y - 3
                width: 2; height: 13; radius: 1
                color: slip.theme.detailAccent
            }
        }
    }
}
