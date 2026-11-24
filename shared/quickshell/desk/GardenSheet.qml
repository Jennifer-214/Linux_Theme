import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "DrawerLogic.js" as Logic

// A year of commits, one little square a day: two half-year beds, shaded deeper the more you wrote. A picture, not a
// list: no day is selected (moving a cursor through 365 of them was in the way of h Back, 2026-11-24); the mouse over a
// day reads it out.
ColumnLayout {
    id: sheet
    required property var theme
    property var garden: null
    property int hoveredIndex: -1
    readonly property var counts: garden && Array.isArray(garden.counts) ? garden.counts : []
    readonly property string start: garden ? String(garden.start || "") : ""
    readonly property int todayIndex: counts.length - 1
    readonly property var thresholds: Logic.gardenThresholds(counts)
    readonly property var hearts: Logic.gardenHearts(counts)
    readonly property bool retro: theme.style === "retro"
    // Days a failing test went green again (desk-work: passed after two or more failures in a row).
    readonly property var greens: garden && Array.isArray(garden.green) ? garden.green : []
    readonly property int weeks: Math.ceil(counts.length / 7)
    readonly property int splitWeek: Math.ceil(weeks / 2)
    readonly property int gap: 3
    readonly property int cell: Math.max(8, Math.min(15, Math.floor((width - 26) / Math.max(1, splitWeek)) - gap))
    // Retro: one character a day (a shade block, ♦ on the busiest; no hearts in retro), two cells wide when the bed has room.
    readonly property int dayW: retro ? Math.max(1, Math.min(2, Math.floor((width - 3 * theme.cellW) / Math.max(1, splitWeek) / theme.cellW))) * theme.cellW : cell
    readonly property int dayH: retro ? theme.cell : cell
    readonly property var retroShades: ["·", "░", "▒", "▓", "█"]
    spacing: retro ? theme.cell : 9

    Text {
        objectName: "garden-summary"
        text: sheet.garden ? Logic.gardenSummary(sheet.start, sheet.counts) : "counting little squares…"
        textFormat: Text.PlainText; color: sheet.theme.ink; font.family: sheet.theme.fontFamily; font.pixelSize: sheet.theme.px(11); renderType: sheet.theme.textRender
        Layout.fillWidth: true; wrapMode: Text.WordWrap
    }

    Repeater {
        model: sheet.weeks ? [{from: 0, to: sheet.splitWeek}, {from: sheet.splitWeek, to: sheet.weeks}] : []
        ColumnLayout {
            id: bed
            required property var modelData
            readonly property int columns: modelData.to - modelData.from
            spacing: sheet.retro ? 0 : 3
            Item {
                Layout.preferredHeight: sheet.retro ? sheet.theme.cell : 16; Layout.fillWidth: true
                Repeater {
                    model: Logic.gardenMonths(sheet.start, bed.modelData.from, bed.modelData.to)
                    Text {
                        required property var modelData
                        x: sheet.retro ? 3 * sheet.theme.cellW + modelData.week * sheet.dayW : 24 + modelData.week * (sheet.cell + sheet.gap)
                        text: sheet.retro ? modelData.text.toUpperCase() : modelData.text; textFormat: Text.PlainText
                        color: sheet.theme.muted; font.family: sheet.theme.headingFont; font.italic: sheet.theme.style !== "retro"; font.pixelSize: sheet.theme.px(12); renderType: sheet.theme.textRender
                    }
                }
            }
            RowLayout {
                spacing: 0
                Column {
                    Layout.preferredWidth: 24; Layout.alignment: Qt.AlignTop
                    spacing: sheet.retro ? 0 : sheet.gap
                    Repeater {
                        model: 7
                        Text {
                            required property int index
                            height: sheet.dayH
                            text: index % 2 ? (sheet.retro ? Logic.gardenWeekdays[index].charAt(0).toUpperCase() : Logic.gardenWeekdays[index].charAt(0)) : ""
                            textFormat: Text.PlainText; color: sheet.theme.muted; font.family: sheet.theme.fontFamily; font.pixelSize: sheet.retro ? sheet.theme.cell : 9
                            renderType: sheet.theme.textRender
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
                Grid {
                    rows: 7; flow: Grid.TopToBottom; spacing: sheet.retro ? 0 : sheet.gap
                    Repeater {
                        model: bed.columns * 7
                        Item {
                            id: plot
                            required property int index
                            readonly property int day: (bed.modelData.from + Math.floor(index / 7)) * 7 + index % 7
                            readonly property bool planted: day < sheet.counts.length
                            readonly property int count: planted ? sheet.counts[day] : 0
                            readonly property int level: Logic.gardenLevel(count, sheet.thresholds)
                            readonly property bool heart: planted && sheet.hearts.indexOf(day) >= 0
                            objectName: "garden-day-" + day
                            width: sheet.dayW; height: sheet.dayH
                            visible: planted
                            // Retro: today on the highlight, each day's shade as a block.
                            Rectangle {
                                visible: sheet.retro && plot.day === sheet.todayIndex
                                width: sheet.theme.cellW; height: sheet.theme.cell
                                color: sheet.theme.highlight
                            }
                            TermText {
                                objectName: "garden-retro-day"
                                visible: sheet.retro
                                theme: sheet.theme
                                text: visible ? (plot.heart ? "♦" : sheet.greens.indexOf(plot.day) >= 0 ? "*" : sheet.retroShades[plot.level]) : ""
                                color: plot.level === 0 && !plot.heart ? sheet.theme.muted : sheet.theme.gardenShades[Math.max(plot.heart ? 4 : 2, plot.level)]
                            }
                            Rectangle {
                                anchors.fill: parent
                                visible: !plot.heart && !sheet.retro
                                radius: sheet.retro ? 0 : Math.max(2, sheet.cell / 4)
                                color: sheet.theme.gardenShades[plot.heart && sheet.retro ? 4 : plot.level]
                                // An empty day is a pencil outline, so even the palest bed reads on a bright screen.
                                border.width: plot.heart && sheet.retro ? 1.6 : plot.day === sheet.todayIndex || plot.level === 0 ? 1 : 0
                                border.color: plot.day === sheet.todayIndex ? sheet.theme.detailAccent : Qt.alpha(sheet.theme.line, .7)
                            }
                            // A pressed flower: the day a failing test went green again.
                            Text {
                                objectName: "garden-green"
                                visible: plot.planted && sheet.greens.indexOf(plot.day) >= 0 && !sheet.retro
                                anchors.right: parent.right; anchors.top: parent.top
                                anchors.rightMargin: -2; anchors.topMargin: -4
                                text: sheet.retro ? "*" : "✿"; textFormat: Text.PlainText
                                font.family: sheet.theme.fontFamily; font.pixelSize: Math.max(8, sheet.cell * .55)
                                color: sheet.theme.detailAccent
                            }
                            // A leaf marks the busiest days without adding another status symbol.
                            Shape {
                                objectName: "garden-heart"
                                visible: plot.heart && !sheet.retro
                                width: 24; height: 24
                                x: (sheet.cell - 24) / 2; y: (sheet.cell - 24) / 2
                                scale: (sheet.cell + 3) / 24
                                preferredRendererType: Shape.CurveRenderer
                                ShapePath {
                                    fillColor: sheet.theme.gardenShades[4]
                                    strokeColor: sheet.theme.gardenShades[4]
                                    strokeWidth: 1
                                    PathSvg { path: "M5 20C2 10 11 3 21 3C21 14 12 23 5 20ZM5 20L17 7" }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent; hoverEnabled: true
                                onEntered: sheet.hoveredIndex = plot.day
                                onExited: if (sheet.hoveredIndex === plot.day) sheet.hoveredIndex = -1
                            }
                            Accessible.role: Accessible.StaticText
                            Accessible.name: Logic.gardenReadout(sheet.start, sheet.counts, plot.day, sheet.todayIndex)
                        }
                    }
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 5
        Text {
            objectName: "garden-readout"
            text: sheet.hoveredIndex >= 0 ? Logic.gardenReadout(sheet.start, sheet.counts, sheet.hoveredIndex, sheet.todayIndex) : Logic.gardenToday(sheet.counts)
            textFormat: Text.PlainText; color: sheet.theme.ink; font.family: sheet.theme.fontFamily; font.pixelSize: sheet.theme.px(11); renderType: sheet.theme.textRender
            Layout.fillWidth: true; elide: Text.ElideRight
        }
        TermText { visible: sheet.retro; theme: sheet.theme; text: "LESS ·░▒▓█ MORE"; color: sheet.theme.muted }
        Text { visible: !sheet.retro; text: "a little"; textFormat: Text.PlainText; color: sheet.theme.muted; font.family: sheet.theme.fontFamily; font.pixelSize: 9 }
        Repeater {
            model: sheet.retro ? 0 : 5
            Rectangle {
                required property int index
                width: 10; height: 10; radius: 3
                color: sheet.theme.gardenShades[index]
                border.width: index === 0 ? 1 : 0; border.color: Qt.alpha(sheet.theme.line, .7)
            }
        }
        Text { visible: !sheet.retro; text: "a lot"; textFormat: Text.PlainText; color: sheet.theme.muted; font.family: sheet.theme.fontFamily; font.pixelSize: 9 }
    }
    Item { Layout.fillHeight: true }
}
