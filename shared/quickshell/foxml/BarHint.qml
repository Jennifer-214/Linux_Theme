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
    background: Rectangle {
        color:hint.theme.tooltipFill; border.color:hint.theme.line; radius:4
        Rectangle { x:0; y:(parent.height-height)/2; width:2; height:Math.min(16,parent.height-8); radius:1; color:hint.theme.highlight; visible:hint.theme.paperDetails }
    }
}
