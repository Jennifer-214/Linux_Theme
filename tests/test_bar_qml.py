"""Run the production bar and its poll/action adapters with harmless local commands."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BarLogic(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node is required')
    def test_formats_layouts_and_shared_pollers(self):
        subprocess.run(['node', str(ROOT / 'tests/bar-logic-test.mjs')], check=True, capture_output=True)


@unittest.skipUnless(shutil.which('quickshell'), 'Quickshell is required')
class NativeBar(unittest.TestCase):
    def test_native_modules_and_actions(self):
        for width in [1920, 1080, 720]:
            with self.subTest(width=width):
                self.exercise_width(width)

    def exercise_width(self, width):
        if not (ROOT / 'src/fox-render/fox-render-fast').exists():
            self.skipTest('build fox-render-fast before the native QML test')
        with tempfile.TemporaryDirectory(prefix='foxml-bar-') as tmp:
            work = Path(tmp)
            config = work / 'config'
            (config / 'waybar').mkdir(parents=True)
            (config / 'foxml').mkdir()
            qml = work / 'qml'
            shutil.copytree(ROOT / 'shared/quickshell/foxml', qml)
            subprocess.run([str(ROOT / 'src/fox-render/fox-render-fast'),
                            str(ROOT / 'themes/FoxML_Paper/palette.sh'),
                            str(ROOT / 'templates/quickshell/foxml'), str(qml)], check=True, capture_output=True)
            helper = work / 'helper.py'
            helper.write_text('import json\nfrom pathlib import Path\np=Path(__file__).with_name("polls")\np.write_text(p.read_text()+"x" if p.exists() else "x")\nprint(json.dumps({"text":"42%", "tooltip":"CPU\\n43°", "class":"warning"}))\n')
            action = work / 'action'
            module = {'exec':f'python3 {helper}', 'return-type':'json', 'interval':'once', 'on-click':f'printf clicked > {action}'}
            claude = work / 'claude.json'
            claude.write_text(json.dumps({'text':'✎ 1  ◇ 1', 'tooltip':'Linux_Theme · Opus 5.5 · 41% context · working', 'class':['asking','berry']}))
            layout = {'modules-left':['group/launcher','group/test','custom/claude'], 'modules-center':[], 'modules-right':['idle_inhibitor','memory'],
                      'custom/claude':{'exec':f'cat {claude}', 'return-type':'json', 'interval':'once', 'on-click':'fox-desktop-menu agents',
                                       'on-click-asking':f'printf asked > {action}.asking'},
                      'group/launcher':{'modules':['custom/logo','hyprland/workspaces']},
                      'custom/logo':{'format':'✎','on-click':'fox-desktop-menu root'},
                      'hyprland/workspaces':{'format':'{name} {windows}', 'persistent-workspaces':{'*':list(range(1,10))}},
                      'group/test':{'modules':['custom/test']}, 'custom/test':module}
            for name in ['config', 'config_secondary']:
                output_layout=dict(layout)
                if name == 'config_secondary':
                    output_layout['modules-right']=['idle_inhibitor']
                (config / 'waybar' / name).write_text(json.dumps(output_layout))
            (config / 'foxml/monitor-layout.conf').write_text('PRIMARY=""\n')
            source = (qml / 'PaperBar.qml').read_text().replace('PanelWindow {', 'FloatingWindow {\n            implicitWidth: 1920')
            source = re.sub(r'^\s*(anchors \{ top: true; left: true; right: true \}|exclusiveZone:.*|WlrLayershell\..*|IdleInhibitor \{.*)\n', '\n', source, flags=re.M)
            source = source.replace('implicitWidth: 1920', 'implicitWidth: ' + str(width))
            (qml / 'PaperBar.qml').write_text(source)
            (qml / 'shell.qml').write_text('''import QtQuick
import Quickshell
ShellRoot {
    id: root
    property bool opened: false
    property string page: "root"
    property var attachment: null
    property real stableSurfaceHeight:0
    property real stableToolbarY:0
    function showFromBar(page, output, offset) { root.page = page; root.opened = true; }
    PaperBar { id: bar; controller: root }
    function findModule(item, name) {
        if (item.objectName === "bar-module-" + name) return item;
        var children = item.children || [];
        for (var i=0; i<children.length; i++) { var found=findModule(children[i], name); if (found) return found; }
        return null;
    }
    Timer { interval:800; running:true; onTriggered: {
        var state=bar.status();
        if (!state.ready || state.error || state.outputs.length !== 1 || state.outputs[0].scale < .95 || state.outputs[0].compact !== (Quickshell.env("FOXML_EXPECT_COMPACT") === "1")) { console.error("BAR_BAD_STATE", JSON.stringify(state)); Qt.exit(1); return; }
        var window=bar.windows[0];
        var metric=root.findModule(window.contentItem, "custom/test");
        var idle=root.findModule(window.contentItem, "idle_inhibitor");
        var workspaces=root.findModule(window.contentItem,"hyprland/workspaces").children.find(function(child) {return child.item !== undefined;}).item;
        if (!workspaces || workspaces.rows.length !== 9 || workspaces.width > window.workspaceBudget) {console.error("BAR_WORKSPACES_INVALID");Qt.exit(1);return;}
        var anchor=bar.anchorFor(window.screen.name,"custom/test");
        if (!anchor || anchor.x < 0 || anchor.width <= 0 || anchor.y <= 0) {console.error("BAR_ANCHOR_INVALID");Qt.exit(1);return;}


        var claude=root.findModule(window.contentItem, "custom/claude");
        var claudeText=claude ? claude.children.find(function(child) {return child.objectName === "bar-module-text";}) : null;
        var ribbon=claude ? claude.parent : null;
        while (ribbon && ribbon.calling === undefined) ribbon=ribbon.parent;
        if (!claude || claude.label !== "✎ 1  ◇ 1" || !ribbon || !ribbon.calling || ribbon.depth !== 50 || !claudeText
            || !Qt.colorEqual(claudeText.color, claude.theme.gardenShades[4])) { console.error("BAR_MISSING_CLAUDE", claude ? JSON.stringify([claude.label, ribbon ? ribbon.depth : null, !!claudeText, claudeText ? String(claudeText.color) : "", String(claude.theme.gardenShades[4])]) : "none"); Qt.exit(1); return; }
        claude.runAction("on-click");
        if (root.opened) { console.error("BAR_CLAUDE_ASKING_OPENED_AGENTS"); Qt.exit(1); return; }
        claude.sample.classes=["berry"];
        claude.runAction("on-click");
        if (root.page !== "agents" || !root.opened) { console.error("BAR_MISSING_CLAUDE_CLICK"); Qt.exit(1); return; }
        root.opened=false;
        if (!metric || metric.label !== "42%" || metric.sample.tooltip !== "CPU\\n43°" || metric.sample.classes[0] !== "warning" || !idle) { console.error("BAR_MISSING_METRIC"); Qt.exit(1); return; }
        metric.runAction("on-click");
        idle.runAction("on-click");
        if (!idle.dataSource.idleEnabled) { console.error("BAR_IDLE_TOGGLE_FAILED"); Qt.exit(1); }
        root.stableSurfaceHeight=window.implicitHeight;
        root.stableToolbarY=window.moduleContainer.mapToItem(window.contentItem,0,0).y;
        window.showHint(metric,"A longer pencil tooltip that wraps on narrow displays",metric);
    }}
    Timer { interval:1100; running:true; onTriggered: {
        var window=bar.windows[0],hint=window.hintContainer;
        if (!window.hintVisible || window.hintReveal<.99 || hint.x<0 || hint.x+hint.width>window.width
            || hint.height<=window.barHeight || window.implicitHeight!==root.stableSurfaceHeight
            || window.moduleContainer.mapToItem(window.contentItem,0,0).y!==root.stableToolbarY)
            throw new Error("banner tooltip moved the bar or escaped its output");
        window.hideHint(window.hintOwner);
    }}
    Timer { interval:1800; running:true; onTriggered: { bar.shown=false; if (bar.status().visible) {Qt.exit(1);return;} console.log("BAR_NATIVE_OK"); Qt.quit(); } }
}
''')
            (work / 'runtime').mkdir(mode=0o700)
            env = dict(os.environ, XDG_RUNTIME_DIR=str(work / 'runtime'), QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', XDG_CONFIG_HOME=str(config))
            env['FOXML_EXPECT_COMPACT'] = '1' if width < 1280 else '0'
            env.pop('FOXML_BAR_FIXTURE', None)
            env.pop('WAYLAND_DISPLAY', None)
            env.pop('HYPRLAND_INSTANCE_SIGNATURE', None)
            result = subprocess.run(['quickshell', '-p', str(qml), '--no-duplicate'], env=env, text=True, capture_output=True, timeout=10)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('BAR_NATIVE_OK', output)
            for error in ['TypeError', 'ReferenceError', 'Unable to assign', 'Binding loop', 'BAR_BAD', 'BAR_MISSING', 'BAR_ANCHOR_INVALID', 'BAR_WORKSPACES_INVALID', 'BAR_CLAUDE_ASKING']:
                self.assertNotIn(error, output)
            self.assertEqual(action.read_text(), 'clicked')
            self.assertEqual(Path(f'{action}.asking').read_text(), 'asked', 'a session asking: the pill goes to it')
            # One initial poll shared across both output configurations, then one action refresh.
            self.assertEqual((work / 'polls').read_text(), 'xx')


if __name__ == '__main__':
    unittest.main()
