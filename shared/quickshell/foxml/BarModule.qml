import QtQuick
import QtQuick.Controls
import "BarLogic.js" as BarLogic

Item {
    id: module
    objectName: "bar-module-" + name
    required property string name
    required property var spec
    required property var dataSource
    required property var theme
    required property var panel
    required property var controller
    property real depth: 43
    property var ribbon: null
    property bool compact: false
    property bool tight: false
    property real workspaceBudget: 560
    readonly property var sample: name === "idle_inhibitor" ? {text:theme.paperDetails ? (dataSource.idleEnabled ? "☼" : "☾") : (spec["format-icons"] || {})[dataSource.idleEnabled ? "activated" : "deactivated"] || "○", tooltip:spec[dataSource.idleEnabled ? "tooltip-format-activated" : "tooltip-format-deactivated"] || (dataSource.idleEnabled ? "Keeping the screen awake · click to let it rest" : "The screen rests when idle · click to keep it awake"), classes:[]}
        : spec.exec || name === "memory" || name === "power-profiles-daemon" ? dataSource.snapshot(name) : {text:spec.format || "", tooltip:spec["tooltip-format"] || (typeof spec.tooltip === "string" ? spec.tooltip : ""), classes:[]}
    readonly property string label: BarLogic.format(sample.text, {icon:sample.text})
    readonly property var clockParts: name === "custom/clock" ? label.trim().match(/^(.*?)\s+(\d{1,2}:\d{2}(?:\s*[AP]M)?)$/i) : null
    readonly property bool special: name === "hyprland/workspaces" || name === "tray"
    readonly property bool botanicalLogo: name === "custom/logo" && theme.paperDetails
    readonly property bool interactive: name === "idle_inhibitor" || ["on-click", "on-click-right", "on-click-middle", "on-scroll-up", "on-scroll-down"].some(function(key) { return !!spec[key]; })
    readonly property bool focused: !!(controller && (controller.drawerVisible || controller.opened) && controller.attachment && controller.attachment.moduleName === name && controller.attachment.screenName === panel.screen.name)
    readonly property real labelLimit: compact && name === "custom/ai_status" ? tight ? 42 : 124 : 2000
    implicitWidth: special ? specialContent.implicitWidth : botanicalLogo ? 35 : clockParts ? clock.implicitWidth + 14 : label ? Math.min(text.implicitWidth, labelLimit) + 14 : 0
    implicitHeight: depth + 4
    visible: implicitWidth > 0

    function drawerAnchor() {
        var sheet = ribbon || module;
        var left = sheet.mapToItem(panel.contentItem, 0, sheet.depth - 3);
        var right = sheet.mapToItem(panel.contentItem, sheet.width, sheet.depth - 3);
        return {x:left.x, y:left.y, width:right.x-left.x};
    }

    function runAction(key) {
        if (name === "idle_inhibitor" && key === "on-click") { dataSource.idleEnabled = !dataSource.idleEnabled; return; }
        var command = spec[key];
        // While a Claude session asks for you, the pill goes straight to it (`on-click-asking`).
        if (key === "on-click" && spec["on-click-asking"] && module.sample.classes.indexOf("asking") >= 0) command = spec["on-click-asking"];
        if (!command) return;
        var drawer = String(command).match(/^(?:\S*\/)?fox-desktop-menu\s+(?:--open\s+)?([a-z][a-z0-9-]*)\s*$/);
        if (drawer) controller.showFromBar(drawer[1], panel.screen.name, name); else dataSource.invoke(command, name);
    }
    Loader {
        id: specialContent
        active: module.special
        sourceComponent: module.name === "tray" ? tray : workspaces
    }
    Component { id: tray; BarTray { theme: module.theme; spec: module.spec; panel: module.panel } }
    Component { id: workspaces; BarWorkspaces { theme: module.theme; spec: module.spec; panel:module.panel; output: module.panel.screen; depth: module.depth; compact: module.compact; tight: module.tight; maxWidth: module.workspaceBudget } }
    BarRibbon { theme: module.theme; anchors.fill: parent; depth: module.depth; visible: module.name === "custom/logo"; selected: module.focused; holdingPaper: module.focused; pressed: mouse.pressed; hovered: mouse.containsMouse && module.interactive }
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: module.clockParts ? clock.y - 2 : text.y - 4
        width: (module.clockParts ? clock.implicitWidth : text.width) + 8
        height: module.clockParts ? clock.implicitHeight + 4 : text.height + 8
        radius: 3
        color: module.focused || mouse.pressed ? module.theme.highlight : module.theme.hoverFill
        visible: !module.special && module.name !== "custom/logo" && (module.focused || mouse.pressed || (module.theme.paperDetails && module.interactive && mouse.containsMouse))
    }
    BotanicalMark {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 6
        width: 22; height: 27
        visible: module.botanicalLogo
        theme: module.theme
    }
    Text {
        id: text
        objectName: "bar-module-text"
        anchors.horizontalCenter: parent.horizontalCenter
        y: 7
        height: 23
        width: Math.min(implicitWidth, module.labelLimit)
        elide: Text.ElideRight
        visible: !module.special && !module.clockParts && !module.botanicalLogo
        text: module.label
        textFormat: Text.PlainText
        color: module.sample.classes.indexOf("critical") >= 0 || module.sample.classes.indexOf("error") >= 0 ? module.theme.error
            : module.sample.classes.indexOf("warning") >= 0 || module.sample.classes.indexOf("stopped") >= 0 ? module.theme.warning
            : module.sample.classes.indexOf("berry") >= 0 ? module.theme.gardenShades[4]
            : module.sample.classes.indexOf("done") >= 0 ? module.theme.gardenShades[3] : module.theme.ink
        font.family: module.theme.fontFamily
        font.pixelSize: module.name === "custom/logo" ? 18 : 13
        verticalAlignment: Text.AlignVCenter
    }
    Column {
        id: clock
        anchors.horizontalCenter: parent.horizontalCenter
        y: 5
        visible: !!module.clockParts
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: module.clockParts ? module.clockParts[1] : ""; color: module.theme.muted; font.family: module.theme.fontFamily; font.pixelSize: 10; textFormat: Text.PlainText }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: module.clockParts ? module.clockParts[2] : ""; color: module.theme.ink; font.family: module.theme.headingFont; font.pixelSize: 21; textFormat: Text.PlainText }
    }
    Rectangle {
        objectName: "bar-api-credit-rail"
        visible: module.name === "custom/api_credits" && module.sample.percentage !== undefined
        anchors.horizontalCenter: parent.horizontalCenter
        y: 33; width: Math.max(0, module.width - 18); height: 3; radius: 1.5
        color: Qt.alpha(module.theme.line, .3)
        Rectangle {
            width: parent.width * Math.max(0, Math.min(100, Number(module.sample.percentage || 0))) / 100
            height: parent.height; radius: parent.radius
            color: Number(module.sample.percentage) <= 20 ? module.theme.error : module.theme.botanicalInk
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: !module.special
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: event => module.runAction(event.button === Qt.RightButton ? "on-click-right" : event.button === Qt.MiddleButton ? "on-click-middle" : "on-click")
        onWheel: event => { module.runAction(event.angleDelta.y > 0 ? "on-scroll-up" : "on-scroll-down"); event.accepted = true; }
    }
    BarBannerHint { theme:module.theme; panel:module.panel; hovered:!module.special && mouse.containsMouse && !mouse.pressed && module.spec.tooltip !== false; text:module.sample.tooltip || "" }
}
