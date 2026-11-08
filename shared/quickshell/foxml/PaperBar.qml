import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import "BarLogic.js" as BarLogic

Scope {
    id: bar
    property var controller: null
    property bool shown: true
    readonly property bool ready: barData.ready && barWindows.instances.length > 0
    readonly property string error: barData.error
    readonly property alias windows: barWindows.instances
    property string notificationScreens: ""
    readonly property string notificationStatePath: Quickshell.env("XDG_RUNTIME_DIR") ? Quickshell.env("XDG_RUNTIME_DIR") + "/foxml-mako-banner" : ""
    readonly property string notificationGeometry: barWindows.instances.map(function(w){return w.screen.name + " " + w.barHeight;}).join("\n") + "\n"
    onNotificationGeometryChanged: notificationGeometryWrite.restart()
    Timer { id:notificationGeometryWrite; interval:50; onTriggered: {if(notificationGeometryFile.path) notificationGeometryFile.setText(bar.notificationGeometry);} }
    FileView {
        id:notificationGeometryFile
        path: Quickshell.env("FOXML_DRAWER_PREVIEW") !== "1" && Quickshell.env("XDG_RUNTIME_DIR") ? Quickshell.env("XDG_RUNTIME_DIR") + "/foxml-bar-geometry" : ""
        blockWrites:true;atomicWrites:true;printErrors:false
    }
    FileView {
        id:notificationState
        path:bar.notificationStatePath
        watchChanges:true;preload:true;printErrors:false
        onFileChanged:reload()
        onLoaded:bar.notificationScreens=text()
        onLoadFailed:bar.notificationScreens=""
    }
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
                reserved:output.barHeight,
                height:output.hosting ? Math.max(output.barHeight,bar.controller.drawerPlacement.top+bar.controller.drawerHeight) : output.barHeight,
                surfaceHeight:output.height, hosting:output.hosting,
                hint:{visible:output.hintVisible,reveal:output.hintReveal,left:output.hintContainer.x,width:output.hintContainer.width,height:output.hintContainer.height}};
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
            visible: bar.shown && barData.ready && (!barTheme.paperDetails || !fullscreenWorkspace || hosting || notificationCover)
            anchors { top: true; left: true; right: true }
            readonly property real barHeight: Math.ceil(66 * barScale)
            readonly property alias drawerContainer: paperHost
            readonly property alias moduleContainer: toolbar
            readonly property alias hintContainer: hintClip
            property var hintOwner: null
            property var hintSource: null
            property string hintText: ""
            property real hintReveal: hintOwner ? 1 : 0
            readonly property bool hintVisible: hintOwner !== null || hintReveal > .001
            Behavior on hintReveal { NumberAnimation { duration:160; easing.type:Easing.OutCubic } }
            function showHint(owner,text,source) {
                if (!text || hosting) return;
                hintSource=source;hintText=text;hintOwner=owner;
            }
            function hideHint(owner) { if (hintOwner===owner) hintOwner=null; }
            readonly property bool hosting: !!(bar.controller && bar.controller.drawerVisible && bar.controller.drawerHost === paperHost)
            onHostingChanged: if (hosting) hintOwner=null
            readonly property bool notificationInFront: barTheme.paperDetails && bar.notificationScreens.trim().length > 0 && bar.notificationScreens.trim().split("\n").indexOf(screen.name) >= 0
            readonly property var monitor: Hyprland.monitorFor(screen)
            readonly property bool fullscreenWorkspace: BarLogic.fullscreenWorkspace(monitor ? monitor.activeWorkspace : null)
            property bool notificationCover: false
            onNotificationInFrontChanged: {
                if (notificationInFront) { notificationCover=true; notificationCoverEnd.stop(); }
                else notificationCoverEnd.restart();
            }
            Timer { id:notificationCoverEnd; interval:450; onTriggered:barWindow.notificationCover=false }
            // Keep the native surface unchanged while the drawer slides. Its
            // input mask and exclusive zone still expose/reserve only the bar
            // and the currently visible sheet.
            implicitHeight: barTheme.paperDetails ? Math.min(screen.height,barHeight+624)
                : hosting ? Math.max(barHeight,bar.controller.drawerPlacement.top+bar.controller.drawerHeight) : barHeight
            exclusiveZone: Quickshell.env("FOXML_BAR_PREVIEW") === "1" ? 0 : barHeight
            color: "transparent"
            WlrLayershell.namespace: "foxml-bar"
            // Never lower the bar while a Top-layer notification is closing.
            // Fullscreen visibility is handled above without remapping layers.
            WlrLayershell.layer: barTheme.paperDetails || hosting || notificationInFront ? WlrLayer.Overlay : WlrLayer.Top
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
            Item {
                id: paperHost
                readonly property real barHeight: barWindow.barHeight
                width: parent.width; height: parent.height; z: 1
                Item {
                    id:hintClip
                    objectName:"bar-banner-hint"
                    z:1
                    visible:barTheme.paperDetails && barWindow.hintVisible
                    readonly property real sourceCenter: {
                        var layout=barWindow.layoutWidth+barWindow.width;
                        return layout>0 && barWindow.hintSource ? barWindow.hintSource.mapToItem(barWindow.contentItem,barWindow.hintSource.width/2,0).x : barWindow.width/2;
                    }
                    width:Math.min(barWindow.width-28,Math.max(160,Math.min(340,hintMeasure.boundingRect.width+28)))
                    height:barWindow.barHeight+hintLabel.implicitHeight+32
                    x:Math.max(14,Math.min(barWindow.width-width-14,sourceCenter-width/2))
                    y:0;clip:true
                    TextMetrics { id:hintMeasure;font.family:barTheme.fontFamily;font.pixelSize:12;text:barWindow.hintText }
                    BarRibbon {
                        theme:barTheme
                        width:parent.width;height:parent.height
                        depth:height-4
                        inset:0
                        y:-height*(1-barWindow.hintReveal)
                        Text {
                            id:hintLabel
                            x:14;y:barWindow.barHeight+3;width:parent.width-28
                            text:barWindow.hintText;textFormat:Text.PlainText
                            color:barTheme.ink;font.family:barTheme.fontFamily;font.pixelSize:12
                            wrapMode:Text.WrapAnywhere;maximumLineCount:8;elide:Text.ElideRight
                            horizontalAlignment:Text.AlignHCenter
                        }
                    }
                }
            }
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
                            // Pending updates, a Claude session asking for you, and the moment the last one
                            // finishes hang a little lower.
                            readonly property bool calling: (modelData === "custom/updates" && /[1-9]/.test(barData.snapshot(modelData).text))
                                || (modelData === "custom/claude" && (barData.snapshot(modelData).classes.indexOf("asking") >= 0
                                                                       || barData.snapshot(modelData).classes.indexOf("done") >= 0))
                            selected: attached || calling
                            holdingPaper: attached
                            depth: modelData === "custom/clock" ? 58 : calling ? 50 : 43
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
