"""retro-amber's lock screen (hyprlock.conf, boot-label.sh) and login screen (regreet.css, regreet.toml) as a BIOS
screen, built only from palette keys: every other theme renders exactly as before. Never runs hyprlock or regreet."""
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / 'src/desk-render/desk-render-fast'
THEMES = sorted(p.parent.name for p in (ROOT / 'themes').glob('*/palette.sh'))
# Paper's rendered lock and login files before the retro layout keys; if Paper is changed on purpose, update these.
PAPER_DIGESTS = {
    'hyprlock/hyprlock.conf': 'b647898ca1ce9cf54a43b438ae7b12a4cdfbf8ef65fea64fdbcf340eecf10b53',
    'regreet/regreet.css': '8e264148dbdec27c67c48096dfafffd7101284e9b7fcd4aefcda0c31dcd065a3',
}


def render(theme, sub, dest):
    subprocess.run([str(RENDER), str(ROOT / f'themes/{theme}/palette.sh'), str(ROOT / 'templates' / sub), str(dest)],
                   check=True, capture_output=True)
    return dest


def widgets(conf):
    """[(kind, {key: value})] in file order; hyprlang's ## is read back as #."""
    out = []
    for kind, body in re.findall(r'(?ms)^(label|input-field|image|shape|background) \{\n(.*?)^\}', conf):
        values = {}
        for line in body.splitlines():
            if '=' in line and not line.strip().startswith('#'):
                key, value = line.split('=', 1)
                values[key.strip()] = value.strip().replace('##', '#')
        out.append((kind, values))
    return out


def label(found, needle):
    return next(v for kind, v in found if kind == 'label' and needle in v['text'])


@unittest.skipUnless(RENDER.exists(), 'build desk-render-fast first')
class RetroLock(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='retro-lock-'))
        self.addCleanup(subprocess.run, ['rm', '-rf', str(self.tmp)])

    def test_paper_renders_byte_for_byte_as_before(self):
        for sub, digest in PAPER_DIGESTS.items():
            out = render('Paper', sub.split('/')[0], self.tmp / sub.split('/')[0])
            self.assertEqual(hashlib.sha256((out / sub.split('/')[1]).read_bytes()).hexdigest(), digest, sub)

    def test_other_themes_keep_the_centred_lock(self):
        for theme in THEMES:
            if theme == 'retro-amber':
                continue
            with self.subTest(theme=theme):
                conf = (render(theme, 'hyprlock', self.tmp / theme) / 'hyprlock.conf').read_text()
                self.assertNotIn('{{', conf)
                self.assertNotIn('shape {', conf)
                self.assertNotIn('swap_font_color', conf)
                found = widgets(conf)
                field = next(v for kind, v in found if kind == 'input-field')
                self.assertEqual((field['size'], field['outline_thickness'], field['dots_center'], field['position'],
                                  field['halign'], field['valign']), ('280, 46', '1', 'true', '0, -80', 'center', 'center'))
                self.assertTrue(field['inner_color'].endswith('b3)'))
                image = next(v for kind, v in found if kind == 'image')
                self.assertEqual((image['path'], image['size'], image['valign']),
                                 ('~/.config/quickshell/desk/paper-sprig.png', '110', 'center'))
                caps = label(found, 'capslock-label.sh')
                self.assertEqual((caps['font_size'], caps['position'], caps['halign']), ('11', '0, -36', 'center'))
                self.assertEqual(label(found, 'boot-label.sh"')['position'], '60, 9999')
                self.assertEqual(label(found, 'battery')['position'], '-30, -30')
                self.assertEqual(label(found, 'claude-lock-line')['font_size'], '12')

    def test_retro_lock_is_a_bios_screen(self):
        conf = (render('retro-amber', 'hyprlock', self.tmp / 'retro') / 'hyprlock.conf').read_text()
        self.assertNotIn('{{', conf)
        found = widgets(conf)
        background = next(v for kind, v in found if kind == 'background')
        self.assertEqual(float(background['brightness']), 0.0, 'solid black, not the blurred wallpaper')
        bar = next(v for kind, v in found if kind == 'shape')
        self.assertEqual((bar['size'], bar['position'], bar['halign'], bar['valign'], bar['color']),
                         ('100%, 24', '0, 0', 'center', 'bottom', 'rgba(ffb000ff)'))
        self.assertFalse([kind for kind, _ in found if kind == 'image'])
        status = label(found, ' status ')
        self.assertIn('boot-label.sh" status "$FPRINTPROMPT"', status['text'])
        self.assertEqual((status['halign'], status['valign'], status['position']), ('left', 'bottom', '32, 0'))
        brand = label(found, 'AMBER-86')
        self.assertEqual((brand['halign'], brand['valign'], brand['position']), ('right', 'bottom', '-32, 0'))
        self.assertIn('foreground="#0c0a06"', brand['text'], 'dark on the amber bar')
        clock = label(found, '%H:%M:%S')
        self.assertEqual((clock['halign'], clock['valign'], clock['position']), ('right', 'top', '-32, -24'))
        for gone in ('<span> </span>', '●', 'date +"', 'battery'):
            self.assertIn('9999', label(found, gone)['position'], gone)
        field = next(v for kind, v in found if kind == 'input-field')
        self.assertEqual((field['outline_thickness'], field['inner_color'][-3:], field['dots_center'],
                          field.get('swap_font_color'), field['dots_text_format'], field['placeholder_text']),
                         ('0', '00)', 'false', 'true', '*', ''))
        # Big Blue Term is crisp at 24 px = font_size 18 (pango points at 96 dpi).
        texts = [v for kind, v in found if kind == 'label' and '9999' not in v['position']]
        self.assertEqual({v['font_size'] for v in texts}, {'18'})
        self.assertEqual(round(float(field['size'].split(',')[1]) * float(field['dots_size']) * 0.5) * 2, 18, 'star size')

    def test_password_stars_sit_one_column_after_the_prompt(self):
        try:
            import gi
            gi.require_version('Pango', '1.0'); gi.require_version('PangoCairo', '1.0')
            from gi.repository import Pango, PangoCairo
        except (ImportError, ValueError):
            self.skipTest('Pango is required to measure the labels')
        out = render('retro-amber', 'hyprlock', self.tmp / 'retro')
        found = widgets((out / 'hyprlock.conf').read_text())
        boot = next(v for kind, v in found if kind == 'label' and v['text'].endswith('boot-label.sh"'))
        field = next(v for kind, v in found if kind == 'input-field')
        text = subprocess.run(['sh', str(out / 'boot-label.sh')], capture_output=True, text=True, check=True).stdout
        lines = text.rstrip('\n').split('\n')
        self.assertEqual(lines[-1], 'PASSWORD:')
        self.assertIn('C:\\DESK> LOCK', lines)
        self.assertTrue(any(line.startswith('SYSTEM LOCKED  ') and line == line.upper() for line in lines))

        # The cells are the retro font's: without it (CI has none) Pango measures a stand-in, and the columns say nothing.
        families = {f.get_name() for f in PangoCairo.FontMap.get_default().list_families()}
        if boot['font_family'] not in families:
            self.skipTest(f"the retro font ({boot['font_family']}) is not installed here")

        def layout(markup, size):
            lay = Pango.Layout.new(PangoCairo.FontMap.get_default().create_context())
            lay.set_font_description(Pango.FontDescription(f"{boot['font_family']} {size}"))
            lay.set_markup(markup, -1)
            return lay.get_pixel_size()
        cell_w, row_h = layout('M', 18)
        self.assertEqual((cell_w, row_h), (16, 24), 'the font this layout is measured for')
        self.assertEqual(layout(text.rstrip('\n'), 18)[1], row_h * len(lines))
        boot_x, boot_y = (float(n) for n in boot['position'].split(','))
        field_x, field_y = (float(n) for n in field['position'].split(','))
        field_h = float(field['size'].split(',')[1])
        star_w, star_h = layout('*', int(round(field_h * float(field['dots_size']) * 0.5) * 2))
        pad = (field_h - star_h) / 2                       # hyprlock's DOTPAD, both ways
        self.assertEqual(-field_y + pad, -boot_y + row_h * (len(lines) - 1), 'stars on the PASSWORD: row')
        self.assertEqual(field_x + pad, boot_x + layout('PASSWORD: ', 18)[0], 'one column after the colon')

    def test_status_bar_reads_the_real_state(self):
        out = render('retro-amber', 'hyprlock', self.tmp / 'retro')
        leds, power = self.tmp / 'leds', self.tmp / 'power'
        (leds / 'input3::capslock').mkdir(parents=True)
        (leds / 'input3::capslock/brightness').write_text('0\n')
        power.mkdir()

        def bar(prompt=''):
            return subprocess.run(['sh', str(out / 'boot-label.sh'), 'status', prompt, str(leds), str(power)],
                                  capture_output=True, text=True, check=True).stdout
        self.assertEqual(bar(), '<span foreground="#0c0a06">◄┘ UNLOCK   CAPS LOCK OFF</span>')
        (leds / 'input3::capslock/brightness').write_text('1\n')
        (power / 'BAT0').mkdir(); (power / 'BAT0/capacity').write_text('87\n')
        self.assertEqual(bar('Finger reader ready'),
                         '<span foreground="#0c0a06">◄┘ UNLOCK   FINGER READER READY   CAPS LOCK ON   BATTERY 87%</span>')
        self.assertIn('A &amp; B', bar('a & b'))


    def test_retro_login_sheet(self):
        for theme in THEMES:
            with self.subTest(theme=theme):
                out = render(theme, 'regreet', self.tmp / f'greeter-{theme}')
                css, toml = (out / 'regreet.css').read_text(), tomllib.loads((out / 'regreet.toml').read_text())
                self.assertNotIn('{{', css)
                sheet = css[css.index("/* ─── Paper: the lock screen's language"):]
                if theme not in ('Paper', 'retro-amber'):
                    self.assertIn('window.foxml-off {', sheet, 'the sheet matches nothing on this theme')
                    continue
                self.assertIn('window:not(.foxml-off) {', sheet)
                if theme == 'retro-amber':
                    for shape in ('italic', 'lowercase', 'border-radius: 4px', 'border-radius: 6px'):
                        self.assertNotIn(shape, sheet)
                    self.assertEqual(set(re.findall(r'font-size: (\d+px)', sheet)), {'12px', '24px', '36px'})
                    self.assertEqual(sheet.count('text-transform: uppercase'), 4)
                    self.assertNotIn('\\', toml['appearance']['greeting_msg'])
                    self.assertEqual(toml['appearance']['greeting_msg'], toml['appearance']['greeting_msg'].upper())

if __name__ == '__main__':
    unittest.main()
