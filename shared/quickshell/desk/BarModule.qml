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
    readonly property bool retro: theme.style === "retro"
    readonly property var rawSample: name === "idle_inhibitor" ? {text:theme.paperDetails ? (dataSource.idleEnabled ? "☼" : "☾") : (spec["format-icons"] || {})[dataSource.idleEnabled ? "activated" : "deactivated"] || "○", tooltip:spec[dataSource.idleEnabled ? "tooltip-format-activated" : "tooltip-format-deactivated"] || (dataSource.idleEnabled ? "Keeping the screen awake · click to let it rest" : "The screen rests when idle · click to keep it awake"), classes:[]}
        : spec.exec || name === "memory" || name === "power-profiles-daemon" ? dataSource.snapshot(name) : {text:spec.format || "", tooltip:spec["tooltip-format"] || (typeof spec.tooltip === "string" ? spec.tooltip : ""), classes:[]}
    // Retro says what each module is, DOS style: "CPU 16% 40°C" (BarLogic.retroSample).
    readonly property var sample: retro ? BarLogic.retroSample(name, rawSample, {idle: dataSource.idleEnabled}) : rawSample
    readonly property string label: BarLogic.format(sample.text, {icon:sample.text})
    // Retro's flat bar has room for one line: the clock is its plain label there.
    readonly property var clockParts: name === "custom/clock" && theme.style !== "retro" ? label.trim().match(/^(.*?)\s+(\d{1,2}:\d{2}(?:\s*[AP]M)?)$/i) : null
    readonly property bool special: name === "hyprland/workspaces" || name === "tray"
    readonly property bool botanicalLogo: name === "custom/logo" && theme.paperDetails
    readonly property bool interactive: name === "idle_inhibitor" || ["on-click", "on-click-right", "on-click-middle", "on-scroll-up", "on-scroll-down"].some(function(key) { return !!spec[key]; })
    readonly property bool focused: !!(controller && (controller.drawerVisible || controller.opened) && controller.attachment && controller.attachment.moduleName === name && controller.attachment.screenName === panel.screen.name)
    readonly property real labelLimit: compact && name === "custom/ai_status" ? tight ? 42 : 124 : 2000
    // Retro's inverse bar can't colour a warning (amber on amber). Reverse video (normal video on the amber strip) is its
    // one emphasis: what needs you (BarLogic.retroAlert, a critical one blinking), and the module whose drawer is open
    // or that is being pressed. Nothing else is boxed.
    readonly property bool retroAlert: retro && BarLogic.retroAlert(sample.classes)
    readonly property bool retroCritical: retroAlert && BarLogic.retroBlinks(sample.classes)
    readonly property bool reverse: retro && (retroAlert || focused || mouse.pressed)
    property bool blinkOff: false
    Timer { interval: 530; repeat: true; running: module.retroCritical; onTriggered: module.blinkOff = !module.blinkOff; onRunningChanged: if (!running) module.blinkOff = false }
    // Retro pads a label by one character cell each side, so two labels stand two cells apart.
    readonly property real padding: retro ? theme.cellW : 7
    readonly property real naturalWidth: special ? specialContent.implicitWidth : botanicalLogo ? 35 : clockParts ? clock.implicitWidth + 14 : label ? Math.min(text.implicitWidth, labelLimit) + 2 * padding : 0
    // Sticky: a module keeps the widest it has needed, so "9 KB/s" becoming "10 KB/s" and back doesn't slide every
    // module after it (and re-centre the middle). Its content sits right-aligned in that width, so digits stay put.
    // A new layout, output size class or budget starts it over.
    property real widest: 0
    onNaturalWidthChanged: if (naturalWidth > widest) widest = naturalWidth
    function resetWidth() { widest = naturalWidth; }
    onSpecChanged: resetWidth()
    onCompactChanged: resetWidth()
    onTightChanged: resetWidth()
    onWorkspaceBudgetChanged: resetWidth()
    Component.onCompleted: resetWidth()
    // Where the content starts: right-aligned, which is the centre while the module is at its natural width.
    readonly property real contentRight: width - padding
    implicitWidth: naturalWidth > 0 ? Math.max(widest, naturalWidth) : 0
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
        var drawer = String(command).match(/^(?:\S*\/)?desktop-menu\s+(?:--open\s+)?([a-z][a-z0-9-]*)\s*$/);
        if (drawer) controller.showFromBar(drawer[1], panel.screen.name, name); else dataSource.invoke(command, name);
    }
    Loader {
        id: specialContent
        active: module.special
        sourceComponent: module.name === "tray" ? tray : workspaces
    }
    Component { id: tray; BarTray { theme: module.theme; spec: module.spec; panel: module.panel } }
    Component { id: workspaces; BarWorkspaces { theme: module.theme; spec: module.spec; panel:module.panel; output: module.panel.screen; depth: module.depth; compact: module.compact; tight: module.tight; maxWidth: module.workspaceBudget
        pins: ((module.dataSource.snapshots || {})["custom/claude"] || {}).pins || [] } }
    BarRibbon { theme: module.theme; anchors.fill: parent; depth: module.depth; visible: module.name === "custom/logo"; selected: module.focused; holdingPaper: module.focused; pressed: mouse.pressed; hovered: mouse.containsMouse && module.interactive }
    Rectangle {
        x: (module.clockParts ? clock.x : text.x) - 4
        y: module.clockParts ? clock.y - 2 : text.y - 4
        width: (module.clockParts ? clock.implicitWidth : text.width) + 8
        height: module.clockParts ? clock.implicitHeight + 4 : text.height + 8
        radius: 3
        color: module.focused || mouse.pressed ? module.theme.highlight : module.theme.hoverFill
        visible: !module.retro && !module.special && module.name !== "custom/logo" && (module.focused || mouse.pressed || (module.theme.paperDetails && module.interactive && mouse.containsMouse))
    }
    // Reverse video fills the label's cells but two pixels each side, so two boxes side by side stay two.
    Rectangle {
        objectName: "bar-module-alert"
        visible: module.reverse && !module.special && !module.blinkOff
        x: text.x - module.theme.cellW + 2
        y: text.y + (text.height - height) / 2
        width: text.width + 2 * module.theme.cellW - 4; height: module.theme.cell + 4
        color: module.theme.ink
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
        x: module.contentRight - width
        // Retro: one whole cell, centred on the 32 px strip, so the glyphs land on whole pixels.
        y: module.theme.style === "retro" ? 10 : 7
        height: module.theme.style === "retro" ? module.theme.cell : 23
        width: Math.min(implicitWidth, module.labelLimit)
        elide: Text.ElideRight
        visible: !module.special && !module.clockParts && !module.botanicalLogo
        text: module.label
        textFormat: Text.PlainText
        color: module.reverse && !module.blinkOff ? module.theme.background
            : module.sample.classes.indexOf("critical") >= 0 || module.sample.classes.indexOf("error") >= 0 ? module.theme.error
            : module.sample.classes.indexOf("warning") >= 0 || module.sample.classes.indexOf("stopped") >= 0 ? module.theme.warning
            : module.sample.classes.indexOf("berry") >= 0 ? module.theme.gardenShades[4]
            : module.sample.classes.indexOf("done") >= 0 ? module.theme.gardenShades[3] : module.theme.ink
        font.family: module.theme.fontFamily
        font.pixelSize: module.theme.style === "retro" ? module.theme.cell : module.name === "custom/logo" ? 18 : 13
        renderType: module.theme.textRender
        verticalAlignment: Text.AlignVCenter
    }
    Column {
        id: clock
        x: module.contentRight - implicitWidth
        y: 5
        visible: !!module.clockParts
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: module.clockParts ? module.clockParts[1] : ""; color: module.theme.muted; font.family: module.theme.fontFamily; font.pixelSize: 10; textFormat: Text.PlainText }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: module.clockParts ? module.clockParts[2] : ""; color: module.theme.ink; font.family: module.theme.headingFont; font.pixelSize: 21; textFormat: Text.PlainText }
    }
    Rectangle {
        objectName: "bar-api-credit-rail"
        // Retro has no rail: under text it reads as a link. Its label says what is left.
        visible: !module.retro && module.name === "custom/api_credits" && module.sample.percentage !== undefined
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
