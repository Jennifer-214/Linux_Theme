import QtQuick
import "DrawerLogic.js" as Logic

Rectangle {
    id: tag
    required property var theme
    property alias text: label.text
    // A tag that opens something takes a click and can carry the keyboard selection.
    property bool interactive: false
    property bool selected: false
    signal clicked()
    // Retro: "[♦ 3 changes] ", one line of cells, the keyboard's tag in inverse video.
    readonly property bool retro: theme.style === "retro"
    implicitWidth: retro ? retroLabel.implicitWidth + theme.cellW : label.implicitWidth + 12
    implicitHeight: retro ? theme.cell : label.implicitHeight + 6
    readonly property bool positive: /^(playing|connected|ready|running|active)$/i.test(text)
    readonly property color restingFill: theme.paperDetails && positive ? Qt.alpha(theme.botanicalInk, .18) : theme.highlight
    // Hovering a tag presses a little more ink into it rather than fading it.
    color: retro ? (selected ? theme.ink : interactive && hover.containsMouse ? theme.highlight : "transparent")
        : selected ? theme.focusFill : interactive && hover.containsMouse ? Qt.tint(restingFill, Qt.alpha(theme.detailAccent, .16)) : restingFill
    // The keyboard's tag wears the accent ring the hearts use, softer than an ink box.
    border.width: selected && !retro ? 1.5 : 0
    border.color: theme.detailAccent
    Text {
        id: label
        visible: !tag.retro
        anchors.centerIn: parent
        textFormat: Text.PlainText
        color: tag.theme.ink
        font.family: tag.theme.fontFamily
        font.pixelSize: 10
    }
    Text {
        id: retroLabel
        visible: tag.retro
        width: tag.retro ? implicitWidth : 0
        textFormat: Text.PlainText
        // A one-word state reads as DOS shouts it ("[PLAYING]"); a sentence keeps its case.
        text: tag.retro ? "[" + (/\s/.test(label.text) ? Logic.retroText(label.text) : label.text.toUpperCase()) + "]" : ""
        color: tag.selected ? tag.theme.background : tag.theme.ink
        font.family: tag.theme.fontFamily
        font.pixelSize: tag.theme.cell
        renderType: Text.NativeRendering
    }
    MouseArea {
        id: hover
        anchors.fill: parent
        enabled: tag.interactive
        hoverEnabled: tag.interactive
        cursorShape: tag.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: tag.clicked()
    }
    Accessible.role: interactive ? Accessible.Button : Accessible.StaticText
    Accessible.name: label.text
}
