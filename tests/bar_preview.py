#!/usr/bin/env python3
"""Draw the top bar offscreen from sample module outputs and save it as a PNG.

The bar's QML and the shipped bar config are rendered for a theme, each module's helper is replaced by a file holding
a sample output (a scene), workspaces 1-3 hold windows with 1 current, and Quickshell draws the bar on its offscreen
platform. Nothing reaches the running desktop: no Wayland, Hyprland, D-Bus or tray.

Usage: tests/bar_preview.py [--theme NAME] [--scene NAME] [--width PX] [--out FILE]
  --theme   a folder under themes/ (default retro-amber)
  --scene   today | busy | broken (default today)
  --width   the screen's width in pixels (default 1920)
  --out     the PNG to write (default bar-THEME-SCENE.png here)
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / 'src/desk-render/desk-render-fast'

SENTRY_WARN = ("<span color='#ffc640' weight='bold'>\U000f0026 1</span><span color='#9c6c14'> · </span>"
               "<span color='#d4c46a'>\U000f0483 20</span>")
SENTRY_CRIT = ("<span color='#d0541c' weight='bold'>\U000f0026 2</span><span color='#9c6c14'> · </span>"
               "<span color='#d4c46a'>\U000f0483 18</span>")
# What each helper prints (None: nothing), in the shapes the helpers under shared/ print. "today" is the bar of
# 2026-11-16 01:01: one security warning, two Claude sessions working, the health helper silent.
TODAY = {
    'custom/ai_status': {'text': ' 35B idle', 'tooltip': 'Model: huihui-qwen3.6-abliterated:35b-a3b\nLoaded: (idle)', 'class': 'expert'},
    'custom/claude': {'text': '✎ 2', 'tooltip': 'Linux_Theme · Opus 5.5 · 41% context · working\nFoxML · Opus 5.5 · 12% context · working', 'class': []},
    'custom/api_credits': {'text': 'API ~$200.00 left', 'tooltip': '$0.00 tracked of $200.00', 'class': ['normal'], 'percentage': 100},
    'custom/foxml_sentry': {'text': SENTRY_WARN, 'tooltip': '⚠ Warnings (1):\n  • /dev/shm exec allowed\n\n✓ Active protections (20):\n  · Audit logging', 'class': 'warning'},
    'custom/system_health': None,
    'custom/battery': {'text': "<span foreground='#0c0a06'>✓</span> \U000f06a5 79%", 'class': 'plugged',
                       'tooltip': 'Battery: 79% (Not charging)\n   Power: AC adapter — holding at 80% (charge threshold)'},
    'custom/net_speed': {'text': '↓ 9 KB/s  ↑ 11 KB/s', 'tooltip': 'Interface: wlan0'},
    'custom/cpu': {'text': '\U000f0ee0 16% 40°', 'tooltip': 'CPU: 16% 40°C'},
    'custom/gpu': {'text': '\U000f08ae on', 'tooltip': 'GPU active (stats unavailable)', 'class': 'idle'},
    'custom/disk': {'text': '\U000f02ca 207g/920g', 'tooltip': '22% of /'},
    'custom/updates': {'text': '↻  0', 'tooltip': '0 pending updates\nlast sync: 2h ago\nclick to inspect + update', 'class': 'calm'},
    'custom/clock': {'text': '  Mon Nov 16  1:01 AM', 'tooltip': 'Monday, November 16 2026\n\n  Weather: ⛅️ 9°C\n  Updates: 0 pending'},
}
# Everything that can ask for you at once.
BUSY = dict(TODAY, **{
    'custom/ai_status': {'text': ' 35B 21.3/24.0g', 'tooltip': 'Model: huihui-qwen3.6-abliterated:35b-a3b\nLoaded: (21.3g RAM)', 'class': 'expert'},
    'custom/claude': {'text': '✎ 1  ◇ 2  ! 1', 'tooltip': 'four sessions', 'class': ['asking', 'stopped'], 'pins': [2]},
    'custom/api_credits': {'text': 'API ~$31.20 left', 'tooltip': '$168.80 tracked of $200.00', 'class': ['warning'], 'percentage': 15},
    'custom/foxml_sentry': {'text': SENTRY_CRIT, 'tooltip': '🚨 Critical (2):\n  • UFW service not running', 'class': 'critical'},
    'custom/system_health': {'text': ' CPU 99% 84°', 'tooltip': 'System Stress Detected:\n  • CPU: 99%', 'class': 'critical'},
    'custom/battery': {'text': "<span foreground='#0c0a06'>ϟ</span> \U000f0088 42% +27W", 'tooltip': 'Battery: 42% (Charging, +27W)', 'class': 'charging'},
    'custom/net_speed': {'text': '↓ 12.4 MB/s  ↑ 310 KB/s', 'tooltip': 'Interface: wlan0'},
    'custom/cpu': {'text': '\U000f0ee0 99% 84°', 'tooltip': 'CPU: 99% 84°C', 'class': 'critical'},
    'custom/gpu': {'text': '\U000f08ae 45% 61°', 'tooltip': 'GPU: 45% 61°C'},
    'custom/disk': {'text': '\U000f02ca 870g/920g', 'tooltip': '94% of /', 'class': 'warning'},
    'custom/updates': {'text': '↻  37', 'tooltip': '37 pending updates', 'class': 'mid'},
})
# A helper that crashed (it printed something that is not JSON).
BROKEN = dict(TODAY, **{'custom/gpu': 'nvidia-smi: Segmentation fault'})
SCENES = {'today': TODAY, 'busy': BUSY, 'broken': BROKEN}

WORKSPACES = ('[{id:1,name:"1",urgent:false,toplevels:{values:[{title:"zsh",lastIpcObject:{class:"kitty"}}]}},'
              '{id:2,name:"2",urgent:false,toplevels:{values:[{title:"nvim",lastIpcObject:{class:"kitty"}}]}},'
              '{id:3,name:"3",urgent:false,toplevels:{values:[{title:"claude",lastIpcObject:{class:"kitty"}},'
              '{title:"Firefox",lastIpcObject:{class:"firefox"}}]}}]')

# After the bar has settled: optionally attach a drawer to a module, print the layout, grab the bar, quit.
SHELL = '''import QtQuick
import Quickshell
ShellRoot {
    id: root
    property bool opened: false
    property bool drawerVisible: false
    property var attachment: null
    function showFromBar(page, output, module) {}
    PaperBar { id: bar; controller: root }
    function walk(item, visit) {
        if (!item) return;
        visit(item);
        var children = item.children || [];
        for (var i = 0; i < children.length; i++) walk(children[i], visit);
    }
    function box(item, shot) { var at = item.mapToItem(shot, 0, 0); return {x: at.x, y: at.y, width: item.width, height: item.height}; }
    function dump(window, shot) {
        var out = {modules: [], dividers: [], tabs: [], sections: [], cursor: null, rails: [], scale: window.barScale, layoutWidth: window.layoutWidth,
            barHeight: window.barHeight, flat: bar.flatBar};
        walk(window.moduleContainer, function(item) {
            if (item.side !== undefined && item.spacing !== undefined)
                out.sections.push({side: item.side, box: box(item, shot)});
            if (item.objectName === "bar-divider" && item.visible) out.dividers.push(box(item, shot));
            if (item.objectName === "bar-cursor") out.cursor = box(item, shot);
            if (item.objectName === "bar-api-credit-rail" && item.visible) out.rails.push(box(item, shot));
            if (String(item.objectName).indexOf("bar-module-") === 0 && item.label !== undefined && item.visible) {
                var text = null, alert = null;
                for (var i = 0; i < item.children.length; i++) {
                    if (item.children[i].objectName === "bar-module-text") text = item.children[i];
                    if (item.children[i].objectName === "bar-module-alert") alert = item.children[i];
                }
                var side = "";
                for (var up = item.parent; up && !side; up = up.parent) if (up.side !== undefined && up.spacing !== undefined) side = up.side;
                out.modules.push({name: item.name, label: item.label, box: box(item, shot), text: text && text.visible ? box(text, shot) : null,
                    group: item.ribbon ? item.ribbon.modelData : "group/launcher", side: side,
                    textColor: text ? String(text.color) : "", alert: !!(alert && alert.visible), alertBox: alert ? box(alert, shot) : null,
                    tooltip: item.sample.tooltip || "", classes: item.sample.classes || []});
            }
            if (item.objectName === "bar-workspaces") {
                var row = item.contentItem.children[0];
                for (var t = 0; t < row.children.length; t++) {
                    var tab = row.children[t];
                    if (tab.modelData === undefined) continue;
                    var label = null, reverse = null;
                    walk(tab, function(child) {
                        if (child.objectName === "workspace-reverse") reverse = child;
                        else if (child.text !== undefined && child.font !== undefined && !label) label = child;
                    });
                    out.tabs.push({id: tab.modelData.id, box: box(tab, shot), label: label ? label.text : "", labelBox: label ? box(label, shot) : null,
                        reverse: !!(reverse && reverse.visible), reverseBox: reverse ? box(reverse, shot) : null});
                }
            }
        });
        return out;
    }
    Timer { interval: 1200; running: true; onTriggered: {
        var focus = Quickshell.env("BAR_PREVIEW_FOCUS");
        if (focus) { root.attachment = {screenName: bar.windows[0].screen.name, moduleName: focus}; root.drawerVisible = true; }
    }}
    Timer { interval: 1600; running: true; onTriggered: {
        var window = bar.windows[0];
        var shot = window.contentItem.children.find(function(child) { return child.objectName === "bar-preview-root"; });
        console.log("BAR_PREVIEW_DUMP " + JSON.stringify(root.dump(window, shot)));
        shot.grabToImage(function(result) { result.saveToFile(Quickshell.env("BAR_PREVIEW_OUT")); console.log("BAR_PREVIEW_SAVED"); Qt.quit(); });
    }}
}
'''


def patch(text, old, new, what):
    if old not in text:
        raise RuntimeError(f'bar_preview: {what} no longer matches the bar QML; update tests/bar_preview.py')
    return text.replace(old, new, 1)


def prepare(work, theme, scene, width):
    """Lay out a sealed copy of the bar in WORK; returns the environment to run Quickshell with."""
    if not RENDER.exists():
        raise RuntimeError('build src/desk-render first (make -C src/desk-render)')
    palette = ROOT / 'themes' / theme / 'palette.sh'
    if not palette.exists():
        raise RuntimeError(f'no theme named {theme}')
    qml = work / 'qml'
    shutil.copytree(ROOT / 'shared/quickshell/desk', qml)
    subprocess.run([str(RENDER), str(palette), str(ROOT / 'templates/quickshell/desk'), str(qml)], check=True, capture_output=True)
    rendered = work / 'waybar-render'
    subprocess.run([str(RENDER), str(palette), str(ROOT / 'templates/waybar'), str(rendered)], check=True, capture_output=True)
    outputs = work / 'outputs'
    outputs.mkdir()
    config_dir = work / 'config/waybar'
    config_dir.mkdir(parents=True)
    (work / 'config/foxml').mkdir()
    (work / 'config/foxml/monitor-layout.conf').write_text('PRIMARY=""\n')
    for name in ['config', 'config_secondary']:
        text = (rendered / name).read_text().replace('__HEIGHT__', '32').replace('__MARGIN_BAR__', '0').replace('__TRAY_ICON__', '16')
        config = json.loads(text)
        config['modules-right'] = [module for module in config['modules-right'] if module != 'tray']
        for module, value in scene.items():
            if module in config and config[module].get('exec'):
                path = outputs / module.replace('/', '_')
                path.write_text('' if value is None else value if isinstance(value, str) else json.dumps(value, ensure_ascii=False) + '\n')
                config[module]['exec'] = f'cat {path}'
                config[module]['interval'] = 'once'
        (config_dir / name).write_text(json.dumps(config, ensure_ascii=False))
    meminfo = work / 'meminfo'
    meminfo.write_text('MemTotal:       32603456 kB\nMemAvailable:   23271424 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n')
    # Blinking (critical alerts, an urgent workspace, the cursor) holds its lit phase, so every drawing is the same.
    for name, old, new in [('BarModule.qml', 'Timer { interval: 530;', 'Timer { interval: 86400000;'),
                           ('BarWorkspaces.qml', 'interval: 530; repeat: true', 'interval: 86400000; repeat: true'),
                           ('PaperBar.qml', 'running: bar.flatBar; loops: Animation.Infinite', 'running: false; loops: Animation.Infinite')]:
        (qml / name).write_text(patch((qml / name).read_text(), old, new, 'the blinking in ' + name))
    data = (qml / 'BarData.qml').read_text()
    data = patch(data, '["cat", "/proc/meminfo"]', f'["cat", "{meminfo}"]', 'the memory reader')
    data = patch(data, '["powerprofilesctl", "get"]', '["echo", "balanced"]', 'the power profile reader')
    (qml / 'BarData.qml').write_text(data)
    workspaces = (qml / 'BarWorkspaces.qml').read_text()
    workspaces = patch(workspaces, 'var all = Hyprland.workspaces.values;', 'var all = ' + WORKSPACES + ';', 'the workspace list')
    workspaces = patch(workspaces, 'readonly property var monitor: Hyprland.monitorFor(output)',
                       'readonly property var monitor: previewMonitor\n    QtObject { id: previewMonitor; property var activeWorkspace: ({id: 1}) }', 'the monitor')
    (qml / 'BarWorkspaces.qml').write_text(workspaces)
    bar = (qml / 'PaperBar.qml').read_text()
    bar = patch(bar, 'PanelWindow {', 'FloatingWindow {\n            implicitWidth: %d' % width, 'the bar window')
    bar = re.sub(r'^\s*(?:anchors \{ top: true; left: true; right: true \}|exclusiveZone:.*|WlrLayershell\..*|IdleInhibitor \{.*)\n',
                 '\n', bar, flags=re.M)
    # One item around everything the bar draws, so it can be grabbed (the window's own root cannot).
    bar = patch(bar, '            Item {\n                id: paperHost',
                '            Item {\n            objectName: "bar-preview-root"\n            width: parent.width; height: parent.height\n'
                '            Item {\n                id: paperHost', 'the bar root')
    head, tail = bar.rsplit('        }\n    }\n}', 1)
    (qml / 'PaperBar.qml').write_text(head + '            }\n        }\n    }\n}' + tail)
    (qml / 'shell.qml').write_text(SHELL)
    runtime = work / 'runtime'
    runtime.mkdir(mode=0o700)
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'),
               XDG_STATE_HOME=str(work / 'state'), QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software',
               FOXML_DRAWER_PREVIEW='1', QS_NO_RELOAD_POPUP='1', DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent',
               BAR_PREVIEW_OUT=str(work / 'bar.png'))
    for key in ['WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'FOXML_BAR_FIXTURE', 'DISPLAY', 'QT_QPA_PLATFORMTHEME',
                'QT_GUI_GTK_JSON', 'BAR_PREVIEW_FOCUS']:
        env.pop(key, None)
    return env


def draw(theme='retro-amber', scene='today', width=1920, focus=''):
    """Draw the bar; returns (its layout, the bar as a Pillow image, Quickshell's log)."""
    with tempfile.TemporaryDirectory(prefix='bar-preview-') as tmp:
        work = Path(tmp)
        env = prepare(work, theme, SCENES[scene], width)
        if focus:
            env['BAR_PREVIEW_FOCUS'] = focus
        try:
            result = subprocess.run(['quickshell', '-p', str(work / 'qml'), '--no-duplicate'], env=env, capture_output=True, text=True, timeout=30)
            log = result.stdout + result.stderr
        except subprocess.TimeoutExpired as stuck:
            raise RuntimeError('the bar never finished drawing:\n' + (stuck.stdout or b'').decode() + (stuck.stderr or b'').decode())
        found = re.search(r'BAR_PREVIEW_DUMP (\{.*\})', log)
        if not found or 'BAR_PREVIEW_SAVED' not in log:
            raise RuntimeError('the bar did not draw:\n' + log)
        from PIL import Image
        layout = json.loads(found.group(1))
        image = Image.open(work / 'bar.png').convert('RGB')
        # The flat (retro) strip is the bar; the other bars' ribbons hang below theirs.
        height = round(layout['barHeight']) if layout['flat'] else 80
        image = image.crop((0, 0, image.width, min(height, image.height)))
        return layout, image, log


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--theme', default='retro-amber')
    parser.add_argument('--scene', default='today', choices=sorted(SCENES))
    parser.add_argument('--width', type=int, default=1920)
    parser.add_argument('--out')
    args = parser.parse_args(argv)
    if not shutil.which('quickshell'):
        print('bar_preview: Quickshell is not installed', file=sys.stderr)
        return 1
    try:
        _, image, _ = draw(args.theme, args.scene, args.width)
    except (RuntimeError, ImportError) as error:
        print(error, file=sys.stderr)
        return 1
    out = Path(args.out or f'bar-{args.theme}-{args.scene}.png')
    image.save(out)
    print(out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
