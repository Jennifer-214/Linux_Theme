import QtQuick
import "DrawerLogic.js" as Logic

// Retro: a window drawn the way a DOS program draws one, on whole character cells:
//   ╔═[ SOUND ]═══════ 14:32 ═╗   the title and a clock in the top edge
//   ╟───────┬─────────────────╢   rules across, with a │ column between the first and last
//   ║ ? Help  / Find  q Close  ║   an inverse status line above the bottom edge
//   ╚═════════════════════════╝
// The lines are drawn as pixels where those characters' strokes fall: the installed Big Blue Term carries the Nerd
// Fonts box-drawing set, whose strokes sit between pixels at 12 px and blur; kitty draws its own the same way.
Item {
    id: frame
    required property var theme
    property string title: ""
    property string corner: ""
    property var rules: []
    property int divider: -1
    property string footer: ""
    property bool footerAlert: false
    readonly property int cols: Math.max(8, Math.floor(width / theme.cellW))
    readonly property int rows: Math.max(4, Math.floor(height / theme.cell))
    readonly property real frameWidth: cols * theme.cellW
    readonly property real frameHeight: rows * theme.cell
    readonly property int footerRow: footer.length > 0 ? rows - 2 : -1
    readonly property var ruleRows: rules.filter(function(row) { return row > 0 && row < frame.rows - 1; }).sort(function(a, b) { return a - b; })
    readonly property bool hasDivider: divider > 0 && divider < cols - 1 && ruleRows.length >= 2
    // The text in the top edge: "[ TITLE ]" from the third cell, " 14:32 " ending two cells from the right.
    readonly property string titleText: title ? "[ " + Logic.clip(title, Math.max(0, cols - Logic.cells(corner) - 12)) + " ]" : ""
    readonly property string cornerText: corner ? " " + corner + " " : ""
    readonly property real titleLeft: 2 * theme.cellW
    readonly property real titleRight: titleLeft + Logic.cells(titleText) * theme.cellW
    readonly property real cornerLeft: (cols - 2 - Logic.cells(cornerText)) * theme.cellW
    readonly property real cornerRight: (cols - 2) * theme.cellW
    // Where a cell's strokes fall: double lines 3 px apart, a single line between them.
    readonly property int outerX: 2
    readonly property int innerX: 5
    readonly property int outerY: 4
    readonly property int innerY: 7
    readonly property int singleX: 3
    readonly property int singleY: 5
    readonly property real edgeRight: (cols - 1) * theme.cellW
    readonly property real edgeBottom: (rows - 1) * theme.cell

    // The top edge, in up to three pieces around the title and the clock.
    readonly property var topSpans: {
        var spans = [], from = 0, cuts = [];
        if (titleText) cuts.push([titleLeft, titleRight]);
        if (cornerText) cuts.push([cornerLeft, cornerRight]);
        cuts.forEach(function(cut) { spans.push([from, cut[0]]); from = cut[1]; });
        spans.push([from, frameWidth]);
        return spans;
    }
    Repeater {
        model: frame.topSpans
        Item {
            required property var modelData
            readonly property real from: Math.max(modelData[0], frame.outerX)
            readonly property real to: Math.min(modelData[1], frame.edgeRight + frame.innerX + 1)
            Rectangle { color: frame.theme.line; x: parent.from; y: frame.outerY; width: Math.max(0, parent.to - parent.from); height: 1 }
            Rectangle { color: frame.theme.line;
                x: Math.max(parent.from, frame.innerX); y: frame.innerY; height: 1
                width: Math.max(0, Math.min(parent.to, frame.edgeRight + frame.outerX + 1) - x)
            }
        }
    }
    Rectangle { color: frame.theme.line; x: frame.outerX; y: frame.outerY; width: 1; height: frame.edgeBottom + frame.innerY - frame.outerY + 1 }
    Rectangle { color: frame.theme.line; x: frame.innerX; y: frame.innerY; width: 1; height: frame.edgeBottom + frame.outerY - frame.innerY + 1 }
    Rectangle { color: frame.theme.line; x: frame.edgeRight + frame.innerX; y: frame.outerY; width: 1; height: frame.edgeBottom + frame.innerY - frame.outerY + 1 }
    Rectangle { color: frame.theme.line; x: frame.edgeRight + frame.outerX; y: frame.innerY; width: 1; height: frame.edgeBottom + frame.outerY - frame.innerY + 1 }
    Rectangle { color: frame.theme.line; x: frame.outerX; y: frame.edgeBottom + frame.innerY; width: frame.edgeRight + frame.innerX - frame.outerX + 1; height: 1 }
    Rectangle { color: frame.theme.line; x: frame.innerX; y: frame.edgeBottom + frame.outerY; width: frame.edgeRight + frame.outerX - frame.innerX + 1; height: 1 }
    Repeater {
        model: frame.ruleRows
        Rectangle { color: frame.theme.line;
            required property int modelData
            objectName: "text-frame-rule"
            x: frame.innerX + 1; y: modelData * frame.theme.cell + frame.singleY
            width: frame.edgeRight + frame.outerX - x; height: 1
        }
    }
    Rectangle { color: frame.theme.line;
        objectName: "text-frame-divider"
        visible: frame.hasDivider
        x: frame.divider * frame.theme.cellW + frame.singleX
        y: frame.hasDivider ? frame.ruleRows[0] * frame.theme.cell + frame.singleY : 0
        width: 1
        height: frame.hasDivider ? (frame.ruleRows[frame.ruleRows.length - 1] - frame.ruleRows[0]) * frame.theme.cell + 1 : 0
    }
    TermText {
        objectName: "text-frame-top"
        visible: frame.titleText.length > 0
        theme: frame.theme
        x: frame.titleLeft; y: 0
        text: frame.titleText
        // The whole edge as characters, for anything that reads it.
        readonly property string edge: "╔═" + frame.titleText + "═".repeat(Math.max(0, frame.cols - 4 - Logic.cells(frame.titleText) - Logic.cells(frame.cornerText))) + frame.cornerText + "═╗"
    }
    TermText { visible: frame.cornerText.length > 0; theme: frame.theme; x: frame.cornerLeft; y: 0; text: frame.cornerText }
    // The status line: inverse video, or normal video in the error colour while something went wrong.
    Rectangle {
        objectName: "text-frame-footer"
        visible: frame.footerRow > 0
        x: frame.theme.cellW; y: frame.footerRow * frame.theme.cell
        width: (frame.cols - 2) * frame.theme.cellW; height: frame.theme.cell
        color: frame.footerAlert ? "transparent" : frame.theme.ink
        TermText {
            objectName: "text-frame-footer-text"
            theme: frame.theme
            x: frame.theme.cellW; width: parent.width - 2 * frame.theme.cellW
            text: Logic.clip(frame.footer, frame.cols - 4)
            color: frame.footerAlert ? frame.theme.error : frame.theme.background
        }
    }
}
