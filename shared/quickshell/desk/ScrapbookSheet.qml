import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "DrawerLogic.js" as Logic

ColumnLayout {
    id: book
    required property var theme
    property var entries: []
    property int selectedIndex: 0
    property bool busy: false
    // Retro: no pictures, a DIR listing of the files, one per line (so h/l and j/k move one row).
    readonly property bool retro: theme.style === "retro"
    readonly property int columns: retro ? 1 : width < 500 ? 2 : 3
    signal choose(int index)
    signal openPicture(int index)
    signal copyPicture(int index)
    signal openFolder(int index)
    signal capture()
    spacing: retro ? theme.cell : 10

    function reveal(index) { if (retro) listing.positionViewAtIndex(index, ListView.Contain); else photos.positionViewAtIndex(index, GridView.Contain); }
    onSelectedIndexChanged: reveal(selectedIndex)
    RowLayout {
        visible: book.retro
        Layout.fillWidth: true
        Layout.preferredHeight: book.theme.cell
        spacing: 0
        TermText { theme: book.theme; text: " Directory of C:\\DESK\\SHOTS"; Layout.fillWidth: true }
        TermText {
            theme: book.theme; text: "[NEW]"
            color: newBox.containsMouse ? book.theme.ink : book.theme.muted
            MouseArea { id: newBox; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: book.capture() }
            Accessible.role: Accessible.Button; Accessible.name: "Take a screenshot"
        }
    }
    ListView {
        id: listing
        objectName: "scrapbook-listing"
        visible: book.retro
        Layout.fillWidth: true; Layout.fillHeight: true
        clip: true; model: book.retro ? book.entries : []
        currentIndex: book.selectedIndex
        keyNavigationEnabled: false
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: PageEdgeScrollBar { theme: book.theme; policy: ScrollBar.AsNeeded; visible: listing.contentHeight > listing.height }
        delegate: Rectangle {
            required property int index
            required property var modelData
            readonly property bool selected: index === book.selectedIndex
            width: listing.width - (listing.contentHeight > listing.height ? 2 * book.theme.cellW : 0); height: book.theme.cell
            color: selected ? book.theme.ink : fileMouse.containsMouse ? book.theme.highlight : "transparent"
            TermText {
                objectName: "scrapbook-file"
                theme: book.theme; width: parent.width
                text: " " + Logic.dosEntry(parent.modelData.label, parent.index, parent.modelData.modifiedAt)
                color: parent.selected ? book.theme.background : book.theme.ink
            }
            MouseArea { id: fileMouse; anchors.fill: parent; hoverEnabled: true; onClicked: book.choose(parent.index); onDoubleClicked: book.openPicture(parent.index) }
            Accessible.role: Accessible.Button
            Accessible.name: modelData.label + ", " + modelData.modifiedAt
        }
        TermText {
            anchors.centerIn: parent; visible: !book.entries.length && !book.busy
            theme: book.theme; text: "File not found"; color: book.theme.muted
        }
    }
    TermText {
        visible: book.retro
        theme: book.theme
        Layout.fillWidth: true
        text: "     " + book.entries.length + " File(s)"
        color: book.theme.muted
    }
    RowLayout {
        visible: !book.retro
        Layout.fillWidth: true
        Text { text: entries.length + (entries.length === 1 ? " picture tucked away" : " pictures tucked away"); textFormat: Text.PlainText; color: book.theme.muted; font.family: book.theme.fontFamily; font.pixelSize: book.theme.px(11); renderType: book.theme.textRender; Layout.fillWidth: true }
        ToolButton {
            text: "+ new"; font.family: book.theme.fontFamily; font.pixelSize: book.theme.px(11)
            palette.buttonText: book.theme.ink
            background: Rectangle { radius: 3; color: parent.down ? book.theme.highlight : parent.hovered || parent.activeFocus ? book.theme.hoverFill : "transparent" }
            onClicked: book.capture()
            Accessible.name: "Take a screenshot"
        }
    }
    GridView {
        id: photos
        visible: !book.retro
        Layout.fillWidth: true; Layout.fillHeight: true
        clip: true; model: book.retro ? [] : book.entries
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
                    font.family: book.theme.headingFont; font.italic: book.theme.style !== "retro"; font.pixelSize: book.theme.px(13); renderType: book.theme.textRender
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
            font.family: book.theme.headingFont; font.italic: book.theme.style !== "retro"; font.pixelSize: book.theme.px(17); renderType: book.theme.textRender
        }
    }
    RowLayout {
        visible: book.retro
        Layout.fillWidth: true
        Layout.preferredHeight: book.theme.cell
        spacing: book.theme.cellW
        TermText {
            theme: book.theme; Layout.fillWidth: true; color: book.theme.muted
            text: book.entries[book.selectedIndex] ? String(book.entries[book.selectedIndex].argument || book.entries[book.selectedIndex].label || "") : ""
            elide: Text.ElideMiddle
        }
        Repeater {
            model: [["[COPY]", "copy"], ["[OPEN]", "open"], ["[FOLDER]", "folder"]]
            TermText {
                required property var modelData
                theme: book.theme; text: modelData[0]
                color: !book.entries.length || book.busy ? book.theme.muted : buttonMouse.containsMouse ? book.theme.ink : book.theme.muted
                MouseArea {
                    id: buttonMouse; anchors.fill: parent; hoverEnabled: true; enabled: book.entries.length > 0 && !book.busy
                    cursorShape: Qt.PointingHandCursor
                    onClicked: parent.modelData[1] === "copy" ? book.copyPicture(book.selectedIndex) : parent.modelData[1] === "open" ? book.openPicture(book.selectedIndex) : book.openFolder(book.selectedIndex)
                }
            }
        }
    }
    RowLayout {
        visible: !book.retro
        Layout.fillWidth: true
        Text { text: book.entries[book.selectedIndex] ? book.entries[book.selectedIndex].label : ""; textFormat: Text.PlainText; Layout.fillWidth: true; elide: Text.ElideMiddle; color: book.theme.muted; font.family: book.theme.fontFamily; font.pixelSize: book.theme.px(10); renderType: book.theme.textRender }
        component PhotoButton: ToolButton {
            enabled: book.entries.length > 0 && !book.busy
            font.family: book.theme.fontFamily; font.pixelSize: book.theme.px(11)
            palette.buttonText: book.theme.ink
            background: Rectangle { radius: 3; color: parent.down ? book.theme.highlight : parent.hovered || parent.activeFocus ? book.theme.hoverFill : "transparent" }
        }
        PhotoButton { text: "copy"; onClicked: book.copyPicture(book.selectedIndex); Accessible.name: "Copy selected screenshot" }
        PhotoButton { text: "open"; onClicked: book.openPicture(book.selectedIndex); Accessible.name: "Open selected screenshot" }
        PhotoButton { text: "folder"; onClicked: book.openFolder(book.selectedIndex); Accessible.name: "Open screenshot folder" }
    }
}
