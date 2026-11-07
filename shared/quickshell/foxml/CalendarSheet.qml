import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import "CalendarLogic.js" as CalendarLogic

ColumnLayout {
    id: calendar
    required property var theme
    property var commandFor: null
    property bool active: visible
    property var heartCache: ({})
    signal openGarden()
    readonly property string monthKey: Qt.formatDate(month, "yyyy-MM")
    readonly property var hearts: heartCache[monthKey] || []
    property date today: new Date()
    property date month: CalendarLogic.monthAt(today, 0)
    readonly property int firstDay: Qt.locale().firstDayOfWeek % 7
    readonly property var days: CalendarLogic.cells(month, today, firstDay)
    readonly property bool currentMonth: month.getFullYear() === today.getFullYear() && month.getMonth() === today.getMonth()
    spacing: 12

    function reset() { today = new Date(); month = CalendarLogic.monthAt(today, 0); }
    function moveMonth(delta) { month = CalendarLogic.monthAt(month, delta); }
    // In the background: hearts arrive a moment after the sheet opens, and months seen before show theirs at once.
    function loadHearts() {
        if (!active || !theme.paperDetails || !commandFor || heartProcess.running) return;
        heartProcess.requested = monthKey;
        heartProcess.command = commandFor(["commit-days", monthKey]);
        heartProcess.running = true;
    }
    onMonthKeyChanged: loadHearts()
    onActiveChanged: loadHearts()
    Process {
        id: heartProcess
        property string requested: ""
        stdout: StdioCollector { id: heartOut }
        onExited: (code, status) => {
            try {
                var data = JSON.parse(heartOut.text);
                if (code === 0 && Array.isArray(data.days)) {
                    var cache = Object.assign({}, calendar.heartCache);
                    cache[requested] = data.days;
                    calendar.heartCache = cache;
                }
            } catch (error) {}
            if (requested !== calendar.monthKey) calendar.loadHearts();
        }
    }
    function refreshToday() {
        var now = new Date(), follow = currentMonth;
        if (!CalendarLogic.sameDay(today, now)) {
            today = now;
            if (follow) month = CalendarLogic.monthAt(today, 0);
        }
    }
    Timer { interval: 30000; repeat: true; running: calendar.active; onTriggered: calendar.refreshToday() }

    RowLayout {
        Layout.fillWidth: true
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            Text {
                text: Qt.formatDate(calendar.month, "MMMM").toLowerCase()
                textFormat: Text.PlainText
                color: calendar.theme.ink
                font.family: calendar.theme.headingFont; font.pixelSize: 32; font.italic: true
                Layout.fillWidth: true; elide: Text.ElideRight
            }
            Text { text: Qt.formatDate(calendar.month, "yyyy"); color: calendar.theme.muted; font.family: calendar.theme.fontFamily; font.pixelSize: 11 }
        }
        component MonthButton: ToolButton {
            implicitWidth: 32; implicitHeight: 32; padding: 0
            font.family: calendar.theme.fontFamily; font.pixelSize: 20
            palette.buttonText: calendar.theme.ink
            background: Rectangle { radius: 3; color: parent.down ? calendar.theme.highlight : parent.hovered || parent.activeFocus ? calendar.theme.hoverFill : "transparent" }
        }
        MonthButton { text: "‹"; Accessible.name: "Previous month"; onClicked: calendar.moveMonth(-1) }
        MonthButton { text: "›"; Accessible.name: "Next month"; onClicked: calendar.moveMonth(1) }
    }
    PaperFlourish { theme: calendar.theme; kind: "underline"; Layout.preferredWidth: 75; Layout.preferredHeight: 4 }

    GridLayout {
        Layout.fillWidth: true
        columns: 7; columnSpacing: 0; rowSpacing: 4
        Repeater {
            model: 7
            Text {
                required property int index
                Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.preferredHeight: 24
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatDate(new Date(2024, 0, 7 + (calendar.firstDay + index) % 7, 12), "ddd").toLowerCase()
                textFormat: Text.PlainText
                font.family: calendar.theme.fontFamily; font.pixelSize: 10
                color: calendar.theme.muted
            }
        }
        Repeater {
            model: calendar.days
            Item {
                id: dayCell
                required property var modelData
                required property int index
                readonly property bool hearted: modelData.day > 0 && calendar.hearts.indexOf(modelData.day) >= 0
                Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.preferredHeight: 38
                Accessible.role: Accessible.StaticText
                Accessible.name: modelData.day ? Qt.formatDate(new Date(calendar.month.getFullYear(), calendar.month.getMonth(), modelData.day, 12), "dddd, MMMM d, yyyy") + (modelData.today ? ", today" : modelData.past ? ", past" : "") + (hearted ? ", heart" : "") : ""
                Text {
                    anchors.centerIn: parent
                    text: dayCell.modelData.day || ""
                    font.family: calendar.theme.fontFamily; font.pixelSize: 14
                    font.bold: dayCell.modelData.today
                    color: dayCell.modelData.past ? calendar.theme.muted : calendar.theme.ink
                }
                Text {
                    objectName: "calendar-heart"
                    visible: dayCell.hearted
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.horizontalCenterOffset: 14
                    y: 2
                    text: "♥"
                    textFormat: Text.PlainText
                    color: calendar.theme.detailAccent
                    font.pixelSize: 10
                }
                Canvas {
                    id: dayMark
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 2, 43); height: 36
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    Connections { target: dayCell; function onModelDataChanged() { dayMark.requestPaint(); } }
                    Connections {
                        target: calendar.theme
                        function onDetailAccentChanged() { dayMark.requestPaint(); }
                        function onMutedChanged() { dayMark.requestPaint(); }
                    }
                    onPaint: {
                        var c = getContext("2d"); c.reset();
                        var w = width, h = height, day = dayCell.modelData;
                        c.lineCap = "round"; c.lineJoin = "round";
                        if (day.today) {
                            // A single quick pencil loop, deliberately open at the upper right.
                            c.strokeStyle = calendar.theme.detailAccent; c.lineWidth = 1.65;
                            c.beginPath(); c.moveTo(w * .69, h * .13);
                            c.bezierCurveTo(w * .38, h * -.01, w * .05, h * .22, w * .10, h * .58);
                            c.bezierCurveTo(w * .12, h * .91, w * .55, h * 1.02, w * .82, h * .78);
                            c.bezierCurveTo(w * 1.01, h * .60, w * .94, h * .31, w * .83, h * .24);
                            c.stroke();
                        } else if (day.past) {
                            // Vary the two strokes by date so the row doesn't look stamped.
                            var tilt = (day.day % 3 - 1) * .035;
                            c.strokeStyle = Qt.alpha(calendar.theme.muted, .60); c.lineWidth = 1.05;
                            c.beginPath(); c.moveTo(w * .28, h * (.24 + tilt));
                            c.bezierCurveTo(w * .42, h * .39, w * .57, h * .61, w * .73, h * .76);
                            c.moveTo(w * .70, h * (.24 - tilt));
                            c.quadraticCurveTo(w * .50, h * .54, w * .27, h * .74);
                            c.stroke();
                        }
                    }
                }
            }
        }
    }
    Item { Layout.fillHeight: true; Layout.minimumHeight: 0 }
    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        Image { source: "paper-cat.png"; visible: calendar.theme.paperDetails; Layout.preferredWidth: 45; Layout.preferredHeight: 42; fillMode: Image.PreserveAspectFit; sourceSize.width: 90; sourceSize.height: 84 }
        Text { text: calendar.currentMonth ? "one little day at a time." : "a little peek " + (calendar.month < calendar.today ? "back." : "ahead."); color: calendar.theme.muted; font.family: calendar.theme.headingFont; font.pixelSize: 15; font.italic: true; Layout.fillWidth: true; elide: Text.ElideRight }
        ToolButton {
            text: "today"; font.family: calendar.theme.fontFamily; font.pixelSize: 11
            palette.buttonText: calendar.theme.ink
            background: Rectangle { radius: 3; color: parent.down ? calendar.theme.highlight : parent.hovered || parent.activeFocus ? calendar.theme.hoverFill : "transparent" }
            Accessible.name: "Return to current month"
            onClicked: calendar.reset()
        }
        ToolButton {
            objectName: "calendar-garden"
            text: "garden ›"; font.family: calendar.theme.fontFamily; font.pixelSize: 11
            palette.buttonText: calendar.theme.ink
            background: Rectangle { radius: 3; color: parent.down ? calendar.theme.highlight : parent.hovered || parent.activeFocus ? calendar.theme.hoverFill : "transparent" }
            Accessible.name: "Open the commit garden"
            onClicked: calendar.openGarden()
        }
    }
}
