import QtQuick
import QtQuick.Controls

ToolTip {
    id: hint
    required property var theme
    delay: 650
    // Retro: an inverse-video label in whole cells, like a DOS status line.
    readonly property bool retro: theme.style === "retro"
    padding: retro ? 0 : 10
    contentItem: Text {
        text: hint.text
        textFormat: Text.PlainText
        leftPadding: hint.retro ? hint.theme.cellW : 0
        rightPadding: hint.retro ? hint.theme.cellW : 0
        lineHeightMode: hint.retro ? Text.FixedHeight : Text.ProportionalHeight
        lineHeight: hint.retro ? hint.theme.cell : 1
        color: hint.retro ? hint.theme.background : hint.theme.ink
        font.family: hint.theme.fontFamily
        font.pixelSize: 12
        renderType: hint.theme.textRender
        wrapMode: Text.Wrap
    }
    background: Rectangle {
        color: hint.retro ? hint.theme.ink : hint.theme.tooltipFill; border.color:hint.theme.line; border.width: hint.retro ? 0 : 1; radius: hint.retro ? 0 : 4
        Rectangle { x:0; y:(parent.height-height)/2; width:2; height:Math.min(16,parent.height-8); radius:1; color:hint.theme.highlight; visible:hint.theme.paperDetails }
    }
}
