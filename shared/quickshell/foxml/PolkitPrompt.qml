import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Polkit

// The paper slip that asks for your password when something needs an administrator (a restart, an install).
// Polkit takes one prompt per session: hyprpolkitagent holds it from login, this takes it over once the shell is up,
// and hands it back if it cannot hold it. fox-pulse starts hyprpolkitagent again whenever no paper prompt is
// registered (the marker below is missing or its process is gone), so a prompt is always there.
// FOXML_POLKIT_PROMPT=off keeps the plain one; outside a Hyprland session (tests) this never touches either.
Scope {
    id: prompt
    required property var theme
    property var screen: null
    property var testFlow: null
    property bool wanted: false
    property int attempts: 0
    readonly property bool enabled: !!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") && Quickshell.env("FOXML_POLKIT_PROMPT") !== "off"
    readonly property var agent: agentLoader.item
    readonly property bool registered: agent !== null && agent.isRegistered
    readonly property var flow: testFlow || (agent && agent.isActive ? agent.flow : null)
    readonly property string marker: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/foxml-polkit-agent"
    readonly property alias window: window

    // Plain words for the requests that come up most; anything else shows polkit's own message.
    function plainAction(id) {
        id = String(id || "");
        if (/^org\.freedesktop\.login1\.(reboot|set-reboot)/.test(id)) return "restart the computer";
        if (/^org\.freedesktop\.login1\.power-off/.test(id)) return "shut the computer down";
        if (/^org\.freedesktop\.login1\.(suspend|hibernate)/.test(id)) return "put the computer to sleep";
        if (/^org\.freedesktop\.systemd1\.manage-unit/.test(id)) return "start or stop a system service";
        if (/^org\.freedesktop\.packagekit\./.test(id)) return "install or update software";
        if (/^org\.freedesktop\.policykit\.exec/.test(id)) return "run a program as administrator";
        if (/^org\.freedesktop\.NetworkManager\./.test(id)) return "change network settings";
        if (/^org\.freedesktop\.udisks2\./.test(id)) return "use a disk";
        if (/^org\.freedesktop\.timedate1\./.test(id)) return "change the date and time";
        return "";
    }
    function plain(text) { return String(text || "").replace(/[\x00-\x1f\x7f]+/g, " ").trim().slice(0, 400); }
    function submit() {
        if (!flow || !flow.isResponseRequired) return;
        flow.submit(field.text);
        field.text = "";
    }
    function cancel() { if (flow) flow.cancelAuthenticationRequest(); field.text = ""; }

    Component.onCompleted: if (enabled) handover.running = true
    Process {
        id: handover
        command: ["systemctl", "--user", "stop", "hyprpolkitagent.service"]
        onExited: { prompt.attempts = 1; prompt.wanted = true; check.restart(); }
    }
    // Not registered two seconds on: a reload's old agent may still hold it, so try once more, then hand back.
    Timer {
        id: check
        interval: 2000
        onTriggered: {
            if (prompt.registered) return;
            if (prompt.attempts < 2) { prompt.attempts++; prompt.wanted = false; prompt.wanted = true; check.restart(); return; }
            prompt.wanted = false;
            giveBack.running = true;
        }
    }
    Process { id: giveBack; command: ["systemctl", "--user", "start", "hyprpolkitagent.service"] }
    Process {
        id: markHeld
        command: ["sh", "-c", 'printf "%s\\n" "$PPID" > "$1.tmp" && mv -f "$1.tmp" "$1"', "sh", prompt.marker]
    }
    Process { id: markGone; command: ["rm", "-f", prompt.marker] }
    onRegisteredChanged: { if (registered) markHeld.running = true; else if (enabled) markGone.running = true; }

    Loader {
        id: agentLoader
        active: prompt.enabled && prompt.wanted
        sourceComponent: PolkitAgent {}
    }

    Connections {
        target: prompt.flow
        ignoreUnknownSignals: true
        function onAuthenticationFailed() { field.text = ""; shake.restart(); }
        function onIsResponseRequiredChanged() { if (prompt.flow && prompt.flow.isResponseRequired) field.forceActiveFocus(); }
    }

    PanelWindow {
        id: window
        visible: prompt.flow !== null
        screen: prompt.screen
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.namespace: "foxml-polkit"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        onVisibleChanged: if (visible) field.forceActiveFocus()

        Rectangle { anchors.fill: parent; color: Qt.alpha(prompt.theme.ink, .16) }

        Item {
            id: slip
            objectName: "polkit-slip"
            width: Math.min(440, parent.width - 48); height: column.implicitHeight + 48
            anchors.centerIn: parent
            transform: Translate { id: nudge; x: 0 }
            SequentialAnimation {
                id: shake
                NumberAnimation { target: nudge; property: "x"; to: -9; duration: 50 }
                NumberAnimation { target: nudge; property: "x"; to: 8; duration: 70 }
                NumberAnimation { target: nudge; property: "x"; to: -5; duration: 60 }
                NumberAnimation { target: nudge; property: "x"; to: 0; duration: 50 }
            }
            Rectangle { anchors.fill: parent; x: 3; y: 4; color: Qt.alpha(prompt.theme.ink, .1); radius: 3 }
            Rectangle {
                anchors.fill: parent; radius: 3
                color: prompt.theme.background
                border.width: 1; border.color: Qt.alpha(prompt.theme.line, .9)
            }
            Column {
                id: column
                x: 24; y: 24; width: parent.width - 48
                spacing: 10
                Text {
                    text: "a little permission."
                    color: prompt.theme.ink; font.family: prompt.theme.headingFont; font.italic: true; font.pixelSize: 24
                }
                Text {
                    objectName: "polkit-what"
                    width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    readonly property string action: prompt.flow ? prompt.plainAction(prompt.flow.actionId) : ""
                    text: action ? "Something wants to " + action + "." : prompt.flow ? prompt.plain(prompt.flow.message) : ""
                    color: prompt.theme.ink; font.family: prompt.theme.fontFamily; font.pixelSize: 14
                }
                Text {
                    objectName: "polkit-message"
                    visible: text !== "" && prompt.flow !== null && prompt.plainAction(prompt.flow.actionId) !== ""
                    width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    text: prompt.flow ? prompt.plain(prompt.flow.message) : ""
                    color: prompt.theme.muted; font.family: prompt.theme.fontFamily; font.pixelSize: 11
                }
                TextField {
                    id: field
                    objectName: "polkit-field"
                    width: parent.width
                    enabled: prompt.flow !== null && prompt.flow.isResponseRequired
                    echoMode: prompt.flow && prompt.flow.responseVisible ? TextInput.Normal : TextInput.Password
                    placeholderText: prompt.flow ? prompt.plain(prompt.flow.inputPrompt).replace(/:\s*$/, "").toLowerCase() || "password" : ""
                    color: prompt.theme.ink; font.family: prompt.theme.fontFamily; font.pixelSize: 14
                    placeholderTextColor: prompt.theme.muted
                    background: Rectangle {
                        implicitHeight: 34; radius: 2
                        color: Qt.alpha(prompt.theme.line, .14)
                        border.width: field.activeFocus ? 2 : 1
                        border.color: field.activeFocus ? prompt.theme.detailAccent : Qt.alpha(prompt.theme.line, .9)
                    }
                    Keys.onReturnPressed: prompt.submit()
                    Keys.onEnterPressed: prompt.submit()
                    Keys.onEscapePressed: prompt.cancel()
                }
                Text {
                    objectName: "polkit-note"
                    visible: text !== ""
                    width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    text: prompt.flow ? prompt.plain(prompt.flow.supplementaryMessage) : ""
                    color: prompt.flow && prompt.flow.supplementaryIsError ? prompt.theme.error : prompt.theme.muted
                    font.family: prompt.theme.fontFamily; font.pixelSize: 12
                }
                Row {
                    anchors.right: parent.right
                    spacing: 8
                    ToolButton {
                        objectName: "polkit-cancel"
                        text: "not now"; font.family: prompt.theme.fontFamily
                        onClicked: prompt.cancel()
                    }
                    ToolButton {
                        objectName: "polkit-allow"
                        text: "allow"; font.family: prompt.theme.fontFamily; font.bold: true
                        enabled: field.enabled && field.text !== ""
                        onClicked: prompt.submit()
                    }
                }
            }
        }
    }
}
