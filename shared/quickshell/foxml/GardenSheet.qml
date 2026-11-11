import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "DrawerLogic.js" as Logic

// A year of commits, one little square a day: two half-year beds, shaded deeper the more you wrote.
ColumnLayout {
    id: sheet
    required property var theme
    property var garden: null
    property int selectedIndex: -1
    property int hoveredIndex: -1
    readonly property var counts: garden && Array.isArray(garden.counts) ? garden.counts : []
    readonly property string start: garden ? String(garden.start || "") : ""
    readonly property int todayIndex: counts.length - 1
    readonly property var thresholds: Logic.gardenThresholds(counts)
    readonly property var hearts: Logic.gardenHearts(counts)
    // Days a failing test went green again (desk-work: passed after two or more failures in a row).
    readonly property var greens: garden && Array.isArray(garden.green) ? garden.green : []
    readonly property int weeks: Math.ceil(counts.length / 7)
    readonly property int splitWeek: Math.ceil(weeks / 2)
    readonly property int gap: 3
    readonly property int cell: Math.max(8, Math.min(15, Math.floor((width - 26) / Math.max(1, splitWeek)) - gap))
    signal choose(int index)
    spacing: 9

    Text {
        objectName: "garden-summary"
        text: sheet.garden ? Logic.gardenSummary(sheet.start, sheet.counts) : "counting little squares…"
        textFormat: Text.PlainText; color: sheet.theme.ink; font.family: sheet.theme.fontFamily; font.pixelSize: 11
        Layout.fillWidth: true; wrapMode: Text.WordWrap
    }

    Repeater {
        model: sheet.weeks ? [{from: 0, to: sheet.splitWeek}, {from: sheet.splitWeek, to: sheet.weeks}] : []
        ColumnLayout {
            id: bed
            required property var modelData
            readonly property int columns: modelData.to - modelData.from
            spacing: 3
            Item {
                Layout.preferredHeight: 16; Layout.fillWidth: true
                Repeater {
                    model: Logic.gardenMonths(sheet.start, bed.modelData.from, bed.modelData.to)
                    Text {
                        required property var modelData
                        x: 24 + modelData.week * (sheet.cell + sheet.gap)
                        text: modelData.text; textFormat: Text.PlainText
                        color: sheet.theme.muted; font.family: sheet.theme.headingFont; font.italic: true; font.pixelSize: 12
                    }
                }
            }
            RowLayout {
                spacing: 0
                Column {
                    Layout.preferredWidth: 24; Layout.alignment: Qt.AlignTop
                    spacing: sheet.gap
                    Repeater {
                        model: 7
                        Text {
                            required property int index
                            height: sheet.cell
                            text: index % 2 ? Logic.gardenWeekdays[index].charAt(0) : ""
                            textFormat: Text.PlainText; color: sheet.theme.muted; font.family: sheet.theme.fontFamily; font.pixelSize: 9
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
                Grid {
                    rows: 7; flow: Grid.TopToBottom; spacing: sheet.gap
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
                            readonly property bool selected: day === sheet.selectedIndex
                            objectName: "garden-day-" + day
                            width: sheet.cell; height: sheet.cell
                            visible: planted
                            Rectangle {
                                anchors.fill: parent
                                visible: !plot.heart
                                radius: Math.max(2, sheet.cell / 4)
                                color: sheet.theme.gardenShades[plot.level]
                                // An empty day is a pencil outline, so even the palest bed reads on a bright screen.
                                border.width: plot.selected ? 1.6 : plot.day === sheet.todayIndex || plot.level === 0 ? 1 : 0
                                border.color: plot.selected ? sheet.theme.ink : plot.day === sheet.todayIndex ? sheet.theme.detailAccent : Qt.alpha(sheet.theme.line, .7)
                            }
                            // A pressed flower: the day a failing test went green again.
                            Text {
                                objectName: "garden-green"
                                visible: plot.planted && sheet.greens.indexOf(plot.day) >= 0
                                anchors.right: parent.right; anchors.top: parent.top
                                anchors.rightMargin: -2; anchors.topMargin: -4
                                text: "✿"; textFormat: Text.PlainText
                                font.family: sheet.theme.fontFamily; font.pixelSize: Math.max(8, sheet.cell * .55)
                                color: sheet.theme.detailAccent
                            }
                            // A leaf marks the busiest days without adding another status symbol.
                            Shape {
                                objectName: "garden-heart"
                                visible: plot.heart
                                width: 24; height: 24
                                x: (sheet.cell - 24) / 2; y: (sheet.cell - 24) / 2
                                scale: (sheet.cell + 3) / 24
                                preferredRendererType: Shape.CurveRenderer
                                ShapePath {
                                    fillColor: sheet.theme.gardenShades[4]
                                    strokeColor: plot.selected ? sheet.theme.ink : sheet.theme.gardenShades[4]
                                    strokeWidth: plot.selected ? 2 : 1
                                    PathSvg { path: "M5 20C2 10 11 3 21 3C21 14 12 23 5 20ZM5 20L17 7" }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent; hoverEnabled: true
                                onEntered: sheet.hoveredIndex = plot.day
                                onExited: if (sheet.hoveredIndex === plot.day) sheet.hoveredIndex = -1
                                onClicked: sheet.choose(plot.day)
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
            text: Logic.gardenReadout(sheet.start, sheet.counts, sheet.hoveredIndex >= 0 ? sheet.hoveredIndex : sheet.selectedIndex, sheet.todayIndex)
            textFormat: Text.PlainText; color: sheet.theme.ink; font.family: sheet.theme.fontFamily; font.pixelSize: 11
            Layout.fillWidth: true; elide: Text.ElideRight
        }
        Text { text: "a little"; textFormat: Text.PlainText; color: sheet.theme.muted; font.family: sheet.theme.fontFamily; font.pixelSize: 9 }
        Repeater {
            model: 5
            Rectangle {
                required property int index
                width: 10; height: 10; radius: 3
                color: sheet.theme.gardenShades[index]
                border.width: index === 0 ? 1 : 0; border.color: Qt.alpha(sheet.theme.line, .7)
            }
        }
        Text { text: "a lot"; textFormat: Text.PlainText; color: sheet.theme.muted; font.family: sheet.theme.fontFamily; font.pixelSize: 9 }
    }
    Item { Layout.fillHeight: true }
}
