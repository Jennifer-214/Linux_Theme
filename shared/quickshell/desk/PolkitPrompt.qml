import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Polkit

// The paper slip that asks for your password when something needs an administrator (a restart, an install).
// Polkit takes one prompt per session: hyprpolkitagent holds it from login, this takes it over once the shell is up,
// and hands it back if it cannot hold it. desk-pulse starts hyprpolkitagent again whenever no paper prompt is
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
    // Retro: a ╔═[ PERMISSION ]═╗ box on whole character cells, [CANCEL] and [ OK ] under the field.
    readonly property bool retro: theme.style === "retro"

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

    // Quickshell finds its session from its own pid, and that lookup reads /proc/1, which hidepid hides from you; then it
    // cannot register, so the plain prompt is left alone instead of stopped and handed back (no gap at all).
    Component.onCompleted: if (enabled) canRegister.running = true
    Process {
        id: canRegister
        command: ["sh", "-c", "test -r /proc/1/cgroup"]
        onExited: code => {
            if (code === 0) handover.running = true;
            else console.info("polkit: /proc/1 is hidden (hidepid), so the paper prompt cannot register; the plain prompt stays");
        }
    }
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
        function onAuthenticationFailed() { field.text = ""; if (!prompt.retro) shake.restart(); }
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
            width: prompt.retro ? Math.floor(Math.min(440, parent.width - 48) / prompt.theme.cellW) * prompt.theme.cellW : Math.min(440, parent.width - 48)
            height: prompt.retro ? (Math.ceil(column.implicitHeight / prompt.theme.cell) + 4) * prompt.theme.cell : column.implicitHeight + 48
            anchors.centerIn: prompt.retro ? undefined : parent
            // Retro sits on whole pixels so the characters stay sharp.
            x: Math.floor((parent.width - width) / 2)
            y: Math.floor((parent.height - height) / 2)
            transform: Translate { id: nudge; x: 0 }
            SequentialAnimation {
                id: shake
                NumberAnimation { target: nudge; property: "x"; to: -9; duration: 50 }
                NumberAnimation { target: nudge; property: "x"; to: 8; duration: 70 }
                NumberAnimation { target: nudge; property: "x"; to: -5; duration: 60 }
                NumberAnimation { target: nudge; property: "x"; to: 0; duration: 50 }
            }
            Rectangle { visible: !prompt.retro; anchors.fill: parent; x: 3; y: 4; color: Qt.alpha(prompt.theme.ink, .1); radius: 3 }
            Rectangle {
                anchors.fill: parent; radius: prompt.retro ? 0 : 3
                color: prompt.theme.background
                border.width: prompt.retro ? 0 : 1; border.color: Qt.alpha(prompt.theme.line, .9)
            }
            TextFrame { visible: prompt.retro; anchors.fill: parent; theme: prompt.theme; title: "PERMISSION" }
            Column {
                id: column
                x: prompt.retro ? 2 * prompt.theme.cellW : 24; y: prompt.retro ? 2 * prompt.theme.cell : 24
                width: parent.width - 2 * x
                spacing: prompt.retro ? prompt.theme.cell : 10
                Text {
                    visible: !prompt.retro
                    text: "a little permission."
                    color: prompt.theme.ink; font.family: prompt.theme.headingFont; font.italic: true; font.pixelSize: 24
                }
                Text {
                    objectName: "polkit-what"
                    width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    readonly property string action: prompt.flow ? prompt.plainAction(prompt.flow.actionId) : ""
                    text: action ? "Something wants to " + action + "." : prompt.flow ? prompt.plain(prompt.flow.message) : ""
                    color: prompt.theme.ink; font.family: prompt.theme.fontFamily; font.pixelSize: prompt.retro ? prompt.theme.cell : 14
                    renderType: prompt.theme.textRender
                }
                Text {
                    objectName: "polkit-message"
                    visible: text !== "" && prompt.flow !== null && prompt.plainAction(prompt.flow.actionId) !== ""
                    width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    text: prompt.flow ? prompt.plain(prompt.flow.message) : ""
                    color: prompt.theme.muted; font.family: prompt.theme.fontFamily; font.pixelSize: prompt.theme.px(11)
                    renderType: prompt.theme.textRender
                }
                TextField {
                    id: field
                    objectName: "polkit-field"
                    width: parent.width
                    enabled: prompt.flow !== null && prompt.flow.isResponseRequired
                    echoMode: prompt.flow && prompt.flow.responseVisible ? TextInput.Normal : TextInput.Password
                    placeholderText: prompt.flow ? prompt.plain(prompt.flow.inputPrompt).replace(/:\s*$/, "").toLowerCase() || "password" : ""
                    color: prompt.theme.ink; font.family: prompt.theme.fontFamily; font.pixelSize: prompt.retro ? prompt.theme.cell : 14
                    renderType: prompt.theme.textRender
                    placeholderTextColor: prompt.theme.muted
                    // Retro: one highlighted line with a block cursor; the theme never changes while the shell runs.
                    Component.onCompleted: if (prompt.retro) { padding = 0; leftPadding = prompt.theme.cellW; cursorDelegate = retroCursor; }
                    Component {
                        id: retroCursor
                        Rectangle { width: prompt.theme.cellW; height: prompt.theme.cell; color: prompt.theme.ink; visible: field.cursorVisible }
                    }
                    background: Rectangle {
                        implicitHeight: prompt.retro ? prompt.theme.cell : 34; radius: prompt.retro ? 0 : 2
                        color: prompt.retro ? prompt.theme.highlight : Qt.alpha(prompt.theme.line, .14)
                        border.width: prompt.retro ? 0 : field.activeFocus ? 2 : 1
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
                    renderType: prompt.theme.textRender
                }
                Row {
                    objectName: "polkit-retro-buttons"
                    visible: prompt.retro
                    anchors.right: parent.right
                    spacing: 2 * prompt.theme.cellW
                    Repeater {
                        model: ["[CANCEL]", "[ OK ]"]
                        Rectangle {
                            required property string modelData
                            required property int index
                            // [ OK ] lights up in inverse video once there is something to send.
                            readonly property bool lit: index === 1 && field.enabled && field.text !== ""
                            width: retroButton.implicitWidth; height: prompt.theme.cell
                            color: lit ? prompt.theme.ink : "transparent"
                            TermText { id: retroButton; theme: prompt.theme; text: parent.modelData; color: parent.lit ? prompt.theme.background : index === 1 && !field.enabled ? prompt.theme.muted : prompt.theme.ink }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (index === 1) prompt.submit(); else prompt.cancel() }
                        }
                    }
                }
                Row {
                    visible: !prompt.retro
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
