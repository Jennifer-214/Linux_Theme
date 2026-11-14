import QtQuick
import QtQuick.Layouts

// Compact keeps the label and its rail on one line.
GridLayout {
    id: meter
    required property var theme
    property var credit: null
    property bool compact: false
    signal clicked()
    readonly property bool known: !!credit && credit.remaining_percent !== null && credit.remaining_percent !== undefined
    readonly property real remaining: known ? Math.max(0, Math.min(100, Number(credit.remaining_percent))) : 0
    readonly property bool caution: !!credit && (credit.status === "stale" || credit.status === "error" || (known && remaining <= 20))
    visible: credit !== null
    columns: compact ? 2 : 1
    columnSpacing: 10
    rowSpacing: 4
    Accessible.role: Accessible.Button
    Accessible.name: credit ? credit.headline + ". " + credit.detail : "Monthly API credit budget"

    Text {
        objectName: "api-credit-label"
        Layout.fillWidth: !meter.compact
        textFormat: Text.PlainText
        text: meter.credit ? meter.credit.short : "API · setup"
        color: meter.caution ? meter.theme.error : meter.theme.botanicalInk
        font.family: meter.theme.fontFamily
        font.pixelSize: 11
        elide: Text.ElideRight
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: meter.clicked() }
    }
    Rectangle {
        objectName: "api-credit-rail"
        visible: meter.known
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        implicitHeight: 4
        radius: 2
        color: Qt.alpha(meter.theme.line, .25)
        Rectangle {
            width: parent.width * meter.remaining / 100
            height: parent.height; radius: parent.radius
            color: meter.caution ? meter.theme.error : meter.theme.botanicalInk
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: meter.clicked() }
    }
    Text {
        visible: !meter.compact
        Layout.fillWidth: true
        Layout.columnSpan: meter.columns
        textFormat: Text.PlainText
        text: meter.credit ? meter.credit.detail : ""
        color: meter.theme.muted
        font.family: meter.theme.fontFamily
        font.pixelSize: 9
        wrapMode: Text.WordWrap
    }
}
