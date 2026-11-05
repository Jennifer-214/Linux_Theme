import QtQuick

Rectangle {
    id: tag
    required property var theme
    property alias text: label.text
    implicitWidth: label.implicitWidth + 12
    implicitHeight: label.implicitHeight + 6
    color: theme.highlight
    Text {
        id: label
        anchors.centerIn: parent
        textFormat: Text.PlainText
        color: tag.theme.ink
        font.family: tag.theme.fontFamily
        font.pixelSize: 10
    }
}
