import QtQuick

Rectangle {
    id: tag
    required property var theme
    property alias text: label.text
    // A tag that opens something takes a click and can carry the keyboard selection.
    property bool interactive: false
    property bool selected: false
    signal clicked()
    implicitWidth: label.implicitWidth + 12
    implicitHeight: label.implicitHeight + 6
    readonly property bool positive: /^(playing|connected|ready|running|active)$/i.test(text)
    color: selected ? theme.focusFill : interactive && hover.containsMouse ? theme.hoverFill : theme.paperDetails && positive ? Qt.alpha(theme.botanicalInk, .18) : theme.highlight
    // The keyboard's tag wears the accent ring the hearts use, softer than an ink box.
    border.width: selected ? 1.5 : 0
    border.color: theme.detailAccent
    Text {
        id: label
        anchors.centerIn: parent
        textFormat: Text.PlainText
        color: tag.theme.ink
        font.family: tag.theme.fontFamily
        font.pixelSize: 10
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
