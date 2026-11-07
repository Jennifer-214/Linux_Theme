import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "DrawerLogic.js" as Logic

// The drawer's front page: the day at a glance, above the favorites.
ColumnLayout {
    id: sheet
    required property var theme
    property var today: ({})
    property var groups: []
    property int favorites: 0
    property var commandFor: null
    property bool active: visible
    property date now: new Date()
    property int hearts: 0
    readonly property var tags: Logic.todayTags(today, groups)
    spacing: 7

    function loadHearts() {
        if (!active || !theme.paperDetails || !commandFor || heartProcess.running) return;
        heartProcess.command = commandFor(["commit-days", Qt.formatDate(now, "yyyy-MM")]);
        heartProcess.running = true;
    }
    onActiveChanged: { now = new Date(); loadHearts(); }
    Timer { interval: 30000; repeat: true; running: sheet.active; onTriggered: sheet.now = new Date() }
    Process {
        id: heartProcess
        stdout: StdioCollector { id: heartOut }
        onExited: (code, status) => {
            try {
                var data = JSON.parse(heartOut.text);
                if (code === 0 && Array.isArray(data.days)) sheet.hearts = data.days.length;
            } catch (error) {}
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        Text { text: Qt.formatDate(sheet.now, "dddd, MMMM d").toLowerCase(); textFormat: Text.PlainText; color: sheet.theme.ink; font.family: sheet.theme.headingFont; font.italic: true; font.pixelSize: 19; Layout.fillWidth: true; elide: Text.ElideRight }
        Text { text: Logic.greeting(sheet.now, Quickshell.env("USER")); textFormat: Text.PlainText; color: sheet.theme.muted; font.family: sheet.theme.headingFont; font.italic: true; font.pixelSize: 13 }
    }
    Flow {
        Layout.fillWidth: true
        spacing: 6
        Repeater {
            model: sheet.tags
            StateTag { required property var modelData; theme: sheet.theme; text: modelData }
        }
    }
    Text { visible: Boolean(sheet.today.todo); text: "◇ next: " + (sheet.today.todo || ""); textFormat: Text.PlainText; color: sheet.theme.ink; font.family: sheet.theme.fontFamily; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight }
    Text { objectName: "today-hearts"; visible: sheet.theme.paperDetails; text: Logic.heartLine(sheet.hearts); textFormat: Text.PlainText; color: sheet.theme.detailAccent; font.family: sheet.theme.fontFamily; font.pixelSize: 11; Layout.fillWidth: true }
    Text { visible: sheet.favorites > 0; text: "a few favorites."; textFormat: Text.PlainText; color: sheet.theme.muted; font.family: sheet.theme.headingFont; font.italic: true; font.pixelSize: 14; Layout.topMargin: 3 }
}
