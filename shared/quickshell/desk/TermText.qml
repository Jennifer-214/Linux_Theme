import QtQuick

// Retro: one line of terminal text on Big Blue Term's 8×12 cell, drawn without antialiasing.
Text {
    required property var theme
    textFormat: Text.PlainText
    color: theme.ink
    font.family: theme.fontFamily
    font.pixelSize: theme.cell
    renderType: Text.NativeRendering
    height: theme.cell
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideNone
    clip: true
}
