import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import "BarLogic.js" as BarLogic

Scope {
    id: bar
    property var controller: null
    property bool shown: true
    readonly property bool ready: barData.ready && barWindows.instances.length > 0
    readonly property string error: barData.error
    readonly property alias windows: barWindows.instances
    function refresh(name) { barData.refresh(name); }
    function hostFor(screenName) {
        if (!shown || !ready) return null;
        var output = barWindows.instances.find(function(window) {return window.screen.name === screenName;});
        return output ? output.drawerContainer : null;
    }
    function anchorFor(screenName, moduleName) {
        if (!shown || !ready) return null;
        var output = barWindows.instances.find(function(window) {return window.screen.name === screenName;});
        if (!output) return null;
        // Read the row extents so the join follows telemetry and output-size changes.
        var layout = output.layoutWidth + output.barScale + output.width;
        if (layout <= 0) return null;
        var item = BarLogic.findItem(output.moduleContainer, "bar-module-" + moduleName);
        if (!item || !item.visible || !item.width) return null;
        var anchor = item.drawerAnchor();
        return {screen:output.screen, x:anchor.x, y:anchor.y, width:anchor.width};
    }
    function status() {
        return {ready:ready, visible:shown, error:error, outputs:barWindows.instances.map(function(output) {
            return {name:output.screen.name, width:output.width, scale:output.barScale, compact:output.compact,
                reserved:output.barHeight, height:output.height, hosting:output.hosting};
        })};
    }
    Theme { id: barTheme }
    BarData { id: barData; active: bar.shown }
    Variants {
        id: barWindows
        model: Quickshell.screens
        PanelWindow {
            id: barWindow
            required property var modelData
            screen: modelData
            visible: bar.shown && barData.ready
            anchors { top: true; left: true; right: true }
            readonly property real barHeight: Math.ceil(66 * barScale)
            readonly property alias drawerContainer: paperHost
            readonly property alias moduleContainer: toolbar
            readonly property bool hosting: !!(bar.controller && bar.controller.drawerVisible && bar.controller.drawerHost === paperHost)
            implicitHeight: hosting ? Math.max(barHeight, bar.controller.drawerPlacement.top + bar.controller.drawerHeight) : barHeight
            exclusiveZone: Quickshell.env("FOXML_BAR_PREVIEW") === "1" ? 0 : barHeight
            color: "transparent"
            WlrLayershell.namespace: "foxml-bar"
            WlrLayershell.layer: hosting ? WlrLayer.Overlay : WlrLayer.Top
            WlrLayershell.keyboardFocus: hosting && bar.controller.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            mask: Region {
                width: barWindow.width; height: barWindow.barHeight
                Region {
                    intersection: Intersection.Combine
                    x: barWindow.hosting ? bar.controller.drawerPlacement.left : 0
                    y: barWindow.hosting ? bar.controller.drawerPlacement.top : 0
                    width: barWindow.hosting ? bar.controller.drawerWidth : 0
                    height: barWindow.hosting ? bar.controller.drawerHeight * bar.controller.drawerReveal : 0
                }
            }
            readonly property bool compact: BarLogic.compactOutput(width, screen.height, screen.name, barData.primaryMonitor)
            readonly property var config: BarLogic.outputConfig(barData.primaryConfig, barData.secondaryConfig, compact)
            readonly property real layoutWidth: left.implicitWidth + middle.implicitWidth + right.implicitWidth + 56
            readonly property real barScale: Math.min(width <= 1920 ? 1 : width <= 2560 ? 1.15 : 1.3, Math.max(.8, (width - 28) / Math.max(1, layoutWidth)))
            readonly property real workspaceBudget: Math.max(180, Math.min(compact ? 620 : 560, width - 390))
            IdleInhibitor { window: barWindow; enabled: barData.idleEnabled && bar.shown }
            Item { id: paperHost; width: parent.width; height: parent.height; z: 1 }
            Rectangle { width: parent.width; height: 7 * barWindow.barScale; color: barTheme.background; z: 2 }
            Item {
                id: toolbar
                z: 2
                x: 14; width: (parent.width - 28) / barWindow.barScale; height: 66
                scale: barWindow.barScale; transformOrigin: Item.TopLeft
                component Section: Row {
                    property string side
                    spacing: 9
                    Repeater {
                        model: BarLogic.modules(barWindow.config, side)
                        BarRibbon {
                            id: group
                            required property string modelData
                            readonly property bool launcher: modelData === "group/launcher"
                            readonly property bool attached: !!(bar.controller && (bar.controller.drawerVisible || bar.controller.opened) && bar.controller.attachment
                                && bar.controller.attachment.screenName === barWindow.screen.name
                                && BarLogic.children(barWindow.config, modelData).indexOf(bar.controller.attachment.moduleName) >= 0)
                            theme: barTheme
                            width: groupRow.implicitWidth > 0 ? groupRow.implicitWidth + (launcher ? 0 : 23) : 0
                            visible: width > 0
                            drawSheet: !launcher
                            inset: launcher ? 0 : 10
                            selected: attached || (modelData === "custom/updates" && /[1-9]/.test(barData.snapshot(modelData).text))
                            holdingPaper: attached
                            depth: modelData === "custom/clock" ? 58 : modelData === "custom/updates" && /[1-9]/.test(barData.snapshot(modelData).text) ? 50 : 43
                            Row {
                                id: groupRow
                                y: -7
                                spacing: group.launcher ? 3 : 4
                                Repeater {
                                    model: BarLogic.children(barWindow.config, group.modelData)
                                    BarModule {
                                        required property string modelData
                                        name: modelData
                                        spec: barWindow.config[modelData] || {}
                                        theme: barTheme
                                        dataSource: barData
                                        panel: barWindow
                                        controller: bar.controller
                                        ribbon: group.launcher ? null : group
                                        compact: barWindow.compact
                                        tight: barWindow.width < 760
                                        workspaceBudget: barWindow.workspaceBudget
                                        depth: group.depth
                                    }
                                }
                            }
                        }
                    }
                }
                Section { id: left; side: "left"; anchors.left: parent.left }
                Section { id: middle; side: "center"; anchors.horizontalCenter: parent.horizontalCenter }
                Section { id: right; side: "right"; anchors.right: parent.right }
            }
        }
    }
}
