import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: book
    required property var theme
    property var entries: []
    property int selectedIndex: 0
    property bool busy: false
    readonly property int columns: width < 500 ? 2 : 3
    signal choose(int index)
    signal openPicture(int index)
    signal copyPicture(int index)
    signal openFolder(int index)
    signal capture()
    spacing: 10

    function reveal(index) { photos.positionViewAtIndex(index, GridView.Contain); }
    onSelectedIndexChanged: reveal(selectedIndex)
    RowLayout {
        Layout.fillWidth: true
        Text { text: entries.length + (entries.length === 1 ? " picture tucked away" : " pictures tucked away"); textFormat: Text.PlainText; color: book.theme.muted; font.family: book.theme.fontFamily; font.pixelSize: 11; Layout.fillWidth: true }
        ToolButton {
            text: "+ new"; font.family: book.theme.fontFamily; font.pixelSize: 11
            palette.buttonText: book.theme.ink
            background: Rectangle { radius: 3; color: parent.down ? book.theme.highlight : parent.hovered || parent.activeFocus ? book.theme.hoverFill : "transparent" }
            onClicked: book.capture()
            Accessible.name: "Take a screenshot"
        }
    }
    GridView {
        id: photos
        Layout.fillWidth: true; Layout.fillHeight: true
        clip: true; model: book.entries
        cellWidth: width / book.columns; cellHeight: 183
        currentIndex: book.selectedIndex
        keyNavigationEnabled: false
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: PageEdgeScrollBar { theme: book.theme; policy: ScrollBar.AsNeeded; visible: photos.contentHeight > photos.height }
        delegate: Item {
            id: photoPrint
            required property int index
            required property var modelData
            width: photos.cellWidth; height: photos.cellHeight
            readonly property bool selected: index === book.selectedIndex
            Accessible.role: Accessible.Button
            Accessible.name: modelData.label + ", " + modelData.modifiedAt
            Accessible.onPressAction: book.openPicture(index)
            Rectangle {
                x: 8; y: 10; width: parent.width - 16; height: parent.height - 20
                rotation: book.theme.paperDetails ? (photoPrint.index % 3 - 1) * .65 : 0
                color: book.theme.background
                border.color: photoPrint.selected ? book.theme.detailAccent : book.theme.line
                border.width: photoPrint.selected ? 1.2 : .7
                Rectangle { x: parent.width; y: 2; width: 2; height: parent.height; color: Qt.alpha(book.theme.ink, .05) }
                Rectangle { x: 2; y: parent.height; width: parent.width; height: 2; color: Qt.alpha(book.theme.ink, .05) }
                Rectangle { x: 5; y: 5; width: parent.width - 10; height: parent.height - 38; color: Qt.alpha(book.theme.line, .10) }
                Image {
                    id: preview
                    objectName: "scrapbook-image-" + photoPrint.index
                    x: 7; y: 7; width: parent.width - 14; height: parent.height - 42
                    source: photoPrint.modelData.image || ""; asynchronous: true; cache: true
                    sourceSize.width: Math.ceil(width * 2); sourceSize.height: Math.ceil(height * 2)
                    fillMode: Image.PreserveAspectFit
                }
                Text { anchors.centerIn: preview; visible: preview.status !== Image.Ready; text: "▧"; color: book.theme.muted; font.pixelSize: 24 }
                Rectangle {
                    width: 38; height: 10; x: (parent.width - width) / 2; y: -4
                    rotation: -5; color: Qt.alpha(book.theme.highlight, .85)
                    visible: book.theme.paperDetails
                }
                Text {
                    x: 8; y: parent.height - 29; width: parent.width - 16
                    text: {
                        var stamp = String(photoPrint.modelData.modifiedAt || "").slice(0, 19).replace(" ", "T");
                        var date = new Date(stamp);
                        return isNaN(date.getTime()) ? photoPrint.modelData.stamp || "a little moment" : Qt.formatDateTime(date, "MMM d · h:mm AP").toLowerCase();
                    }
                    textFormat: Text.PlainText; color: book.theme.ink
                    font.family: book.theme.headingFont; font.italic: true; font.pixelSize: 13
                    elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                }
            }
            MouseArea {
                id: photoMouse
                anchors.fill: parent
                onClicked: book.choose(photoPrint.index)
                onDoubleClicked: book.openPicture(photoPrint.index)
                hoverEnabled: true
            }
            BarHint { theme: book.theme; visible: photoMouse.containsMouse; text: photoPrint.modelData.label || "" }
        }
        Text {
            anchors.centerIn: parent; visible: !book.entries.length && !book.busy
            text: "a place for little moments.\n\nalt ⇧ o takes one, or press + new."
            horizontalAlignment: Text.AlignHCenter; color: book.theme.muted
            font.family: book.theme.headingFont; font.italic: true; font.pixelSize: 17
        }
    }
    RowLayout {
        Layout.fillWidth: true
        Text { text: book.entries[book.selectedIndex] ? book.entries[book.selectedIndex].label : ""; textFormat: Text.PlainText; Layout.fillWidth: true; elide: Text.ElideMiddle; color: book.theme.muted; font.family: book.theme.fontFamily; font.pixelSize: 10 }
        component PhotoButton: ToolButton {
            enabled: book.entries.length > 0 && !book.busy
            font.family: book.theme.fontFamily; font.pixelSize: 11
            palette.buttonText: book.theme.ink
            background: Rectangle { radius: 3; color: parent.down ? book.theme.highlight : parent.hovered || parent.activeFocus ? book.theme.hoverFill : "transparent" }
        }
        PhotoButton { text: "copy"; onClicked: book.copyPicture(book.selectedIndex); Accessible.name: "Copy selected screenshot" }
        PhotoButton { text: "open"; onClicked: book.openPicture(book.selectedIndex); Accessible.name: "Open selected screenshot" }
        PhotoButton { text: "folder"; onClicked: book.openFolder(book.selectedIndex); Accessible.name: "Open screenshot folder" }
    }
}
