import QtQuick

Item {
    id: hint
    required property var theme
    required property var panel
    property bool hovered: false
    property string text: ""
    // Windows to show as photo prints in the banner (a workspace tab's), on Paper.
    property var windows: []
    readonly property bool requested: hovered && text.length > 0 && panel && !panel.hosting
    onRequestedChanged: {
        if (requested && theme.paperDetails) delay.restart();
        else { delay.stop(); if (theme.paperDetails && panel) panel.hideHint(hint); }
    }
    onTextChanged: {
        if (theme.paperDetails && requested && panel.hintOwner === hint)
            panel.showHint(hint, text, parent, windows);
    }
    Timer {
        id: delay
        interval: 650
        onTriggered: if (hint.requested) hint.panel.showHint(hint, hint.text, hint.parent, hint.windows)
    }
    BarHint { parent:hint.parent; theme:hint.theme; visible:!hint.theme.paperDetails && hint.hovered; text:hint.text }
    Component.onDestruction: if (theme && theme.paperDetails && panel) panel.hideHint(hint)
}
