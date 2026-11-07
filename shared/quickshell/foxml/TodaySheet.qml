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
    property int commitsToday: 0
    // The tag the keyboard is on, or -1 while the favorites or sidebar have it.
    property int selectedTag: -1
    readonly property var tags: Logic.todayTags(today, groups)
    signal openTag(var tag)
    signal openGarden()
    spacing: 7

    function loadHearts() {
        if (!active || !commandFor || heartProcess.running) return;
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
                if (code === 0) sheet.commitsToday = Number(data.today || 0);
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
            StateTag {
                required property var modelData
                required property int index
                objectName: "today-tag-" + index
                theme: sheet.theme
                text: modelData.text
                interactive: Boolean(modelData.page || modelData.action)
                selected: index === sheet.selectedTag
                onClicked: sheet.openTag(modelData)
            }
        }
    }
    Text { visible: Boolean(sheet.today.todo); text: "◇ next: " + (sheet.today.todo || ""); textFormat: Text.PlainText; color: sheet.theme.ink; font.family: sheet.theme.fontFamily; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight }
    Text {
        objectName: "today-hearts"; visible: sheet.theme.paperDetails; text: Logic.heartLine(sheet.hearts) + "  ›"; textFormat: Text.PlainText
        color: sheet.theme.detailAccent; font.family: sheet.theme.fontFamily; font.pixelSize: 11; font.underline: heartsMouse.containsMouse
        Layout.fillWidth: true
        // The month's hearts open the whole year of them.
        MouseArea { id: heartsMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sheet.openGarden() }
        Accessible.role: Accessible.Button; Accessible.name: "Open the commit garden"
    }
    Text { objectName: "today-since"; visible: text.length > 0; text: Logic.sinceLine(sheet.commitsToday); textFormat: Text.PlainText; color: sheet.theme.muted; font.family: sheet.theme.fontFamily; font.pixelSize: 11; Layout.fillWidth: true }
    // Claude plan usage: berry from 80%, the colour of the garden's busiest days.
    Text {
        objectName: "today-claude"; visible: text.length > 0; text: Logic.claudeLine(sheet.today.claudeUsage); textFormat: Text.PlainText
        color: sheet.today.claudeBerry ? sheet.theme.gardenShades[4] : sheet.theme.muted; font.weight: sheet.today.claudeBerry ? Font.DemiBold : Font.Normal
        font.family: sheet.theme.fontFamily; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight
    }
    Text { visible: sheet.favorites > 0; text: "a few favorites."; textFormat: Text.PlainText; color: sheet.theme.muted; font.family: sheet.theme.headingFont; font.italic: true; font.pixelSize: 14; Layout.topMargin: 3 }
}
