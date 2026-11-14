import QtQuick
import QtQml.Models
import Quickshell
import Quickshell.Io
import "BarLogic.js" as BarLogic

Scope {
    id: data
    property bool active: true
    property var primaryConfig: ({})
    property var secondaryConfig: ({})
    property var snapshots: ({})
    property string primaryMonitor: ""
    property string error: ""
    property bool idleEnabled: false
    property var workers: ({})
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config"
    readonly property string fixture: Quickshell.env("FOXML_BAR_FIXTURE") || ""
    readonly property bool ready: Array.isArray(primaryConfig["modules-left"])
    readonly property var enabledModules: BarLogic.enabled(primaryConfig).concat(BarLogic.enabled(secondaryConfig))
    readonly property var pollers: fixture ? [] : BarLogic.pollers(primaryConfig, secondaryConfig)
    signal actionFinished()

    function publish(name, value) { var next = Object.assign({}, snapshots); next[name] = value; snapshots = next; }
    function snapshot(name) { return snapshots[name] || {text: "…", tooltip: "Waiting for " + name, classes: []}; }
    function loadConfig(file, secondary) {
        try {
            var config = JSON.parse(file.text());
            if (!Array.isArray(config["modules-left"]) || !Array.isArray(config["modules-right"])) throw new Error("Bar module lists are missing");
            if (secondary) secondaryConfig = config; else primaryConfig = config;
            error = "";
        } catch (e) { if (!secondary) error = "Bar configuration: " + String(e); }
    }
    function refresh(name) {
        Object.keys(workers).forEach(function(key) { if (!name || name === key) workers[key].poll(); });
        if (!fixture && (!name || name === "memory") && !memoryProcess.running) memoryProcess.running = true;
        if (!fixture && (!name || name === "power-profiles-daemon") && !profileProcess.running) profileProcess.running = true;
    }
    property string refreshModule: ""
    function invoke(command, name) {
        if (!command || fixture) return;
        // A terminal launched by a click must not hold up unrelated bar actions.
        Quickshell.execDetached(["sh", "-c", String(command)]);
        refreshModule = name || "";
        actionRefresh.restart();
    }
    Timer { id: actionRefresh; interval: 500; onTriggered: { data.refresh(data.refreshModule); data.actionFinished(); } }
    FileView {
        id: primaryFile
        path: Quickshell.env("FOXML_BAR_CONFIG") || data.configHome + "/waybar/config"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: data.loadConfig(primaryFile, false)
        onLoadFailed: data.error = "The rendered bar configuration is unavailable"
    }
    FileView {
        id: secondaryFile
        path: data.configHome + "/waybar/config_secondary"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: data.loadConfig(secondaryFile, true)
    }
    FileView {
        id: layoutFile
        path: data.configHome + "/foxml/monitor-layout.conf"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: data.primaryMonitor = BarLogic.primary(layoutFile.text())
    }
    FileView {
        id: fixtureFile
        path: data.fixture
        printErrors: false
        onLoaded: { try { data.snapshots = JSON.parse(fixtureFile.text()); } catch (e) { data.error = String(e); } }
    }
    Instantiator {
        model: data.pollers
        delegate: Scope {
            id: worker
            required property var modelData
            function poll() { if (data.active && !process.running) process.running = true; }
            Component.onCompleted: { data.workers[modelData.name] = worker; poll(); }
            Component.onDestruction: { if (data.workers[modelData.name] === worker) delete data.workers[modelData.name]; }
            Timer {
                interval: Math.max(1000, Number(worker.modelData.spec.interval || 60) * 1000)
                running: data.active && worker.modelData.spec.interval !== "once"
                repeat: true
                onTriggered: worker.poll()
            }
            Process {
                id: process
                command: ["sh", "-c", worker.modelData.spec.exec]
                stdout: StdioCollector { id: output; waitForEnd: true }
                stderr: StdioCollector { waitForEnd: true }
                onExited: (code, status) => {
                    try { data.publish(worker.modelData.name, BarLogic.sample(output.text, worker.modelData.spec)); }
                    catch (e) { data.publish(worker.modelData.name, {text: "!", tooltip: worker.modelData.name + ": helper unavailable", classes: ["warning"]}); }
                }
            }
        }
    }
    Process {
        id: memoryProcess
        command: ["cat", "/proc/meminfo"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: { try { data.publish("memory", BarLogic.memory(text, data.primaryConfig.memory || {})); } catch (_) {} }
        }
    }
    Process {
        id: profileProcess
        command: ["powerprofilesctl", "get"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var profile = text.trim(), spec = data.primaryConfig["power-profiles-daemon"] || {};
                var icons = spec["format-icons"] || {balanced:"◈", performance:"↟", "power-saver":"❀"};
                data.publish("power-profiles-daemon", {text: icons[profile] || icons.default || "◈",
                    tooltip: BarLogic.format(spec["tooltip-format"] || "Power profile: {profile}", {profile:profile || "unavailable"}), classes: [profile]});
            }
        }
    }
    Timer { interval: 5000; running: data.active && data.ready && !data.fixture && data.enabledModules.indexOf("memory") >= 0; repeat: true; triggeredOnStart: true; onTriggered: { if (!memoryProcess.running) memoryProcess.running = true; } }
    Timer { interval: 10000; running: data.active && data.ready && !data.fixture && data.enabledModules.indexOf("power-profiles-daemon") >= 0; repeat: true; triggeredOnStart: true; onTriggered: { if (!profileProcess.running) profileProcess.running = true; } }
}
