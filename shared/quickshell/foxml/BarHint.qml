import QtQuick
import QtQuick.Controls

ToolTip {
    id: hint
    required property var theme
    delay: 650
    padding: 10
    contentItem: Text {
        text: hint.text
        textFormat: Text.PlainText
        color: hint.theme.ink
        font.family: hint.theme.fontFamily
        font.pixelSize: 12
        wrapMode: Text.Wrap
    }
    background: Rectangle { color: hint.theme.background; border.color: hint.theme.line; radius: 4 }
}
