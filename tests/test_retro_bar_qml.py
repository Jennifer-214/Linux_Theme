"""The retro top bar reads as a DOS status line, and the other themes' bars stay as they were.

Draws the real bar offscreen from sample helper outputs (tests/bar_preview.py) and checks its layout and pixels:
every item names itself in capitals and code page 437 characters; one separator, evenly spaced; reverse video only
for what needs you, the current workspace and an open drawer; the workspaces, your work and the machine as three
zones; tooltips that say what each code means. Paper and Classic draw the same sample with their own bars.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bar_preview', ROOT / 'tests/bar_preview.py')
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)
HAVE_PIL = importlib.util.find_spec('PIL') is not None  # bar_preview crops the drawing with Pillow

# The rule the bar's own table (BarLogic.retroModules) must meet: one short code per module, each meaning one thing.
CODES = {'custom/ai_status': 'LLM', 'custom/claude': 'CLAUDE', 'custom/api_credits': 'API', 'custom/foxml_sentry': 'SEC',
         'custom/system_health': 'STRESS', 'power-profiles-daemon': 'PWR', 'custom/battery': 'BAT', 'idle_inhibitor': 'AWAKE',
         'custom/net_speed': 'NET', 'custom/cpu': 'CPU', 'custom/gpu': 'GPU', 'memory': 'MEM', 'custom/disk': 'DSK',
         'custom/updates': 'UPD'}
WORK = ['custom/ai_status', 'custom/claude', 'custom/api_credits']
# Code page 437 as Big Blue Term draws it: printable ASCII, the upper half, and DOS's glyphs for the control codes.
CP437 = set(bytes(range(0x20, 0x7f)).decode('cp437') + bytes(range(0x80, 0x100)).decode('cp437')
            + '☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼⌂')
NEEDS_YOU = {'critical', 'error', 'warning', 'stopped', 'asking', 'done', 'plugged-drain', 'high'}
STRIP = (0xff, 0xb0, 0x00)  # retro-amber's FG: the bar is an amber strip with dark text

_drawn = {}


def drawn(theme, scene, width=1920, focus=''):
    key = (theme, scene, width, focus)
    if key not in _drawn:
        _drawn[key] = preview.draw(theme, scene, width, focus)
    return _drawn[key]


def classes(name, scene):
    value = preview.SCENES[scene].get(name)
    if not isinstance(value, dict):
        return {'warning'} if isinstance(value, str) else set()  # a broken helper reads as a warning
    found = value.get('class', [])
    return set(found if isinstance(found, list) else str(found).split())


def text_runs(layout, side):
    """The drawn text in one zone, left to right: (left, right, group, name)."""
    runs = [(m['text']['x'], m['text']['x'] + m['text']['width'], m['group'], m['name'])
            for m in layout['modules'] if m['side'] == side and m['text']]
    if side == 'left':
        runs += [(t['labelBox']['x'], t['labelBox']['x'] + t['labelBox']['width'], 'group/launcher', 'tab ' + str(t['id']))
                 for t in layout['tabs']]
    return sorted(runs)


@unittest.skipUnless(shutil.which('quickshell') and preview.RENDER.exists() and HAVE_PIL,
                     'Quickshell, Pillow and a built src/desk-render are required')
class RetroBar(unittest.TestCase):
    def test_every_item_says_what_it_is(self):
        """A short capital code and its value, or the one ≡ menu glyph; code page 437 only; K, M, G and °C units."""
        for scene, width in [('today', 1920), ('busy', 2560), ('broken', 1920), ('today', 1080)]:
            layout = drawn('retro-amber', scene, width)[0]
            codes = []
            for module in layout['modules']:
                name, label = module['name'], module['label']
                if name == 'hyprland/workspaces':
                    continue
                with self.subTest(scene=scene, width=width, module=name, label=label):
                    self.assertLessEqual(set(label), CP437, 'a glyph Big Blue Term would not draw on its grid')
                    self.assertEqual(label, label.upper(), 'DOS writes the bar in capitals')
                    self.assertNotRegex(label, r'[KM]B/s|°(?!C)', 'units are K, M, G and °C')
                    if name == 'custom/logo':
                        self.assertEqual(label, '≡')
                    elif name == 'custom/clock':
                        self.assertRegex(label, r'^(MON|TUE|WED|THU|FRI|SAT|SUN) [A-Z]{3} \d{1,2}  \d{1,2}:\d\d [AP]M$')
                    else:
                        self.assertIn(name, CODES, 'every module needs a code that says what it is')
                        self.assertRegex(label, rf'^{CODES[name]}( \S.*)?$')
                        codes.append(CODES[name])
            self.assertEqual(len(codes), len(set(codes)), 'one code, one meaning')
            for tab in layout['tabs']:
                self.assertRegex(tab['label'], r'^\d+♦?$', 'a workspace is its number (♦: a Claude waits there)')

    def test_one_separator_evenly_spaced(self):
        """Two cells between items, one │ between groups with the same room each side, nowhere else."""
        for scene, width in [('today', 1920), ('busy', 2560)]:
            layout = drawn('retro-amber', scene, width)[0]
            boundaries, group_gaps = 0, set()
            for side in ['left', 'center', 'right']:
                runs = text_runs(layout, side)
                for before, after in zip(runs, runs[1:]):
                    between = [d for d in layout['dividers'] if before[1] <= d['x'] < after[0]]
                    with self.subTest(scene=scene, between=(before[3], after[3])):
                        if before[2] == after[2]:
                            self.assertEqual(after[0] - before[1], 16, 'two cells between the items of a group')
                            self.assertEqual(between, [], 'no │ inside a group')
                        else:
                            boundaries += 1
                            self.assertEqual(len(between), 1, 'one │ between groups')
                            left, right = between[0]['x'] - before[1], after[0] - between[0]['x'] - 1
                            self.assertEqual(left, right, 'the │ sits in the middle of the gap')
                            group_gaps.add(after[0] - before[1])
            self.assertEqual(len(layout['dividers']), boundaries, 'a │ only between the groups of a zone')
            self.assertEqual(len(group_gaps), 1, f'every group gap the same: {group_gaps}')
            self.assertEqual({(d['y'], d['width'], d['height']) for d in layout['dividers']}, {(10, 1, 12)}, 'one │ style')

    def test_reverse_video_only_where_it_needs_you(self):
        """Alerts, an open drawer and the current workspace in reverse video, one box style; nothing else drawn."""
        for scene, width, focus in [('today', 1920, ''), ('busy', 2560, 'custom/battery'), ('broken', 1920, '')]:
            layout, image, _ = drawn('retro-amber', scene, width, focus)
            with self.subTest(scene=scene):
                needs_you = {m['name'] for m in layout['modules'] if classes(m['name'], scene) & NEEDS_YOU} | ({focus} - {''})
                self.assertEqual({m['name'] for m in layout['modules'] if m['alert']}, needs_you)
                self.assertEqual([t['id'] for t in layout['tabs'] if t['reverse']], [1], 'the current workspace only')
                for module in layout['modules']:
                    background = module['textColor'].lower() == '#ffb000'
                    self.assertEqual(background, module['alert'], f"{module['name']}: reverse video means amber text")
                boxes = [m['alertBox'] for m in layout['modules'] if m['alert']] + [t['reverseBox'] for t in layout['tabs'] if t['reverse']]
                self.assertEqual({(b['y'], b['height']) for b in boxes}, {(8, 16)}, 'one box: the text row and two pixels')
                self.assertEqual(layout['rails'], [], 'no rail under the API credits: under text it reads as a link')
                # The strip above and below the text row is untouched: no underline, rail, shade or tall tab.
                pixels = image.load()
                for y in list(range(0, 8)) + list(range(24, image.height)):
                    self.assertEqual({pixels[x, y] for x in range(image.width)}, {STRIP}, f'row {y} is not plain strip')
                # Above the glyphs, inside the box row, only the boxes and the cursor are dark.
                spans = sorted((round(b['x']), round(b['x'] + b['width'])) for b in boxes + [layout['cursor']])
                dark, start = [], None
                for x in range(image.width):
                    if sum(pixels[x, 9]) < 200 and start is None:
                        start = x
                    elif sum(pixels[x, 9]) >= 200 and start is not None:
                        dark.append((start, x))
                        start = None
                self.assertEqual(dark, spans)

    def test_three_zones(self):
        """Left the workspaces, in the middle your work (halfway between), on the right the machine."""
        for scene, width in [('today', 1920), ('busy', 2560), ('today', 1080)]:
            layout = drawn('retro-amber', scene, width)[0]
            with self.subTest(scene=scene, width=width):
                zones = {side: [m['name'] for m in sorted(layout['modules'], key=lambda m: m['box']['x']) if m['side'] == side]
                         for side in ['left', 'center', 'right']}
                self.assertEqual(zones['left'], ['custom/logo', 'hyprland/workspaces'])
                self.assertEqual(zones['center'], [name for name in WORK if name in zones['center']])
                self.assertGreaterEqual(len(zones['center']), 2)
                self.assertFalse(set(WORK) & set(zones['right']), 'work stays in the middle')
                box = {s['side']: s['box'] for s in layout['sections']}
                left_gap = box['center']['x'] - (box['left']['x'] + box['left']['width'])
                right_gap = box['right']['x'] - (box['center']['x'] + box['center']['width'])
                self.assertLessEqual(abs(left_gap - right_gap), 1, 'the middle zone sits halfway')
        layout = drawn('retro-amber', 'today', 1920)[0]
        zone_gap = text_runs(layout, 'center')[0][0] - text_runs(layout, 'left')[-1][1]
        self.assertGreater(zone_gap, group_gap(layout), 'zones stand further apart than groups')

    def test_tooltips_say_what_the_codes_mean(self):
        """Hovering an item explains its code first, in characters the font has."""
        for scene in ['today', 'busy']:
            layout = drawn('retro-amber', scene, 2560)[0]
            for module in layout['modules']:
                name, tooltip = module['name'], module['tooltip']
                with self.subTest(scene=scene, module=name):
                    if name in CODES:
                        self.assertTrue(tooltip.startswith(CODES[name] + ': '), tooltip)
                    elif name == 'custom/logo':
                        self.assertTrue(tooltip.startswith('MENU: '), tooltip)
                    self.assertLessEqual(set(tooltip) - {'\n'}, CP437, 'a tooltip mark the font lacks')

    def test_a_silent_helper_hides_and_a_broken_one_says_err(self):
        """Waybar hides a module whose helper printed nothing; one that printed garbage is an error, in reverse video."""
        names = {m['name'] for m in drawn('retro-amber', 'today')[0]['modules']}
        self.assertNotIn('custom/system_health', names)
        broken = {m['name']: m for m in drawn('retro-amber', 'broken')[0]['modules']}
        self.assertEqual(broken['custom/gpu']['label'], 'GPU ERR')
        self.assertTrue(broken['custom/gpu']['alert'])

    def test_paper_and_classic_keep_their_bar(self):
        """The retro rules stay retro: the same sample on Paper and Classic draws the bar they always had."""
        for theme, logo in [('Paper', '✎'), ('Classic', '✿')]:
            layout = drawn(theme, 'today')[0]
            labels = {m['name']: m['label'] for m in layout['modules']}
            with self.subTest(theme=theme):
                for name, value in preview.TODAY.items():
                    if name not in ('custom/system_health', 'custom/clock'):
                        self.assertEqual(labels[name], re.sub(r'<[^>]*>', '', value['text']), name)
                self.assertEqual(labels['custom/system_health'], '!', 'its silent-helper mark is unchanged')
                self.assertTrue(labels['custom/clock'].endswith('1:01 AM') and 'Mon' in labels['custom/clock'])
                self.assertEqual(labels['custom/logo'], logo)
                self.assertTrue(labels['memory'].endswith('8.9/31g'))
                self.assertEqual([m for m in layout['modules'] if m['side'] == 'center'], [], 'no middle zone')
                self.assertEqual(layout['dividers'], [])
                self.assertEqual(len(layout['rails']), 1, 'the API credit rail')
                self.assertFalse(any(m['alert'] for m in layout['modules']))
                self.assertTrue(all(len(t['label']) > 1 for t in layout['tabs'][:3]), 'workspace tabs keep their window icons')
                for module in layout['modules']:
                    if module['text'] and module['name'] != 'custom/logo':
                        self.assertEqual(module['box']['width'], module['text']['width'] + 14, module['name'])

    @unittest.skipUnless(shutil.which('node'), 'Node is required')
    def test_the_real_helpers_read_in_dos_words(self):
        """The CPU and disk helpers' own output, through the retro table: their format and the parser agree."""
        with tempfile.TemporaryDirectory(prefix='retro-bar-helpers-') as tmp:
            rendered = Path(tmp) / 'waybar'
            subprocess.run([str(preview.RENDER), str(ROOT / 'themes/retro-amber/palette.sh'), str(ROOT / 'templates/waybar'), str(rendered)],
                           check=True, capture_output=True)
            config = json.loads((rendered / 'config').read_text().replace('__HEIGHT__', '32').replace('__TRAY_ICON__', '16'))
            runtime = Path(tmp) / 'runtime'
            runtime.mkdir(mode=0o700)
            for name, script, pattern in [('custom/cpu', 'cpu.sh', r'^CPU \d+%( \d+°C)?$'), ('custom/disk', 'disk.sh', r'^DSK \d+/\d+G$')]:
                glyph = re.search(r"'([^']*)'", config[name]['exec']).group(1)
                output = subprocess.run(['bash', str(ROOT / 'shared/waybar_scripts' / script), glyph], env=dict(os.environ, XDG_RUNTIME_DIR=str(runtime)),
                                        capture_output=True, text=True, timeout=20, check=True).stdout
                label = subprocess.run(['node', '--input-type=module', '-', str(ROOT / 'shared/quickshell/desk/BarLogic.js'), name, output],
                                       input=NODE_LABEL, capture_output=True, text=True, timeout=20, check=True).stdout.strip()
                self.assertRegex(label, pattern, output)


NODE_LABEL = r"""
import fs from 'node:fs'; import vm from 'node:vm';
const [file, name, output] = process.argv.slice(-3);
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(file, 'utf8').replace(/^\.pragma library\s*/, ''), context);
console.log(context.retroSample(name, context.sample(output, {'return-type': 'json'}), {}).text);
"""


def group_gap(layout):
    """Text to text across a │."""
    runs = text_runs(layout, 'right')
    return min(after[0] - before[1] for before, after in zip(runs, runs[1:]) if before[2] != after[2])


if __name__ == '__main__':
    unittest.main()
