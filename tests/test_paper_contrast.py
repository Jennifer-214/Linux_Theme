"""Keep Paper readable across screens while preserving distinct syntax roles."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT/'src/desk-render/desk-render-fast'

def luminance(hexcolor):
    channels = [int(hexcolor[i:i+2], 16)/255 for i in (0, 2, 4)]
    linear = [v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4 for v in channels]
    return sum(v*w for v, w in zip(linear, [.2126, .7152, .0722]))

def contrast(a, b):
    low, high = sorted([luminance(a), luminance(b)])
    return (high+.05)/(low+.05)

class PaperContrast(unittest.TestCase):
    def test_ink_roles_and_blush_remain_distinct_and_readable(self):
        values = dict(re.findall(r'^([A-Z0-9_]+)=([^\n]+)', (ROOT/'themes/FoxML_Paper/palette.sh').read_text(), re.M))
        bg = values['BG']
        self.assertGreaterEqual(contrast(values['SELECTION'], bg), 1.7)
        self.assertGreaterEqual(contrast(values['FG'], values['SELECTION']), 7)
        self.assertGreaterEqual(contrast(values['NVIM_SYN_COMMENT'], bg), 5.5)
        self.assertGreaterEqual(contrast(values['NVIM_FAINT_FG'], bg), 4)
        self.assertGreaterEqual(contrast(values['NVIM_SYN_PARAM'], bg), 7)
        roles = ['NVIM_FN_DEF', 'NVIM_SYN_VAR', 'NVIM_SYN_PARAM', 'NVIM_SYN_TYPE', 'NVIM_SYN_STRING', 'NVIM_SYN_COMMENT']
        self.assertEqual(len({values[key] for key in roles}), len(roles))
        self.assertLess(luminance(values['NVIM_SYN_PARAM']), luminance(values['NVIM_SYN_COMMENT'])*.65)
        self.assertNotEqual(values['COMMENT'], values['NVIM_SYN_COMMENT'])

    @unittest.skipUnless(RENDER.exists(), 'build desk-render-fast first')
    def test_both_compositor_formats_keep_paper_opaque_and_other_themes_unchanged(self):
        with tempfile.TemporaryDirectory() as temp:
            for palette in sorted((ROOT/'themes').glob('*/palette.sh')):
                with self.subTest(theme=palette.parent.name):
                    out = Path(temp)/palette.parent.name
                    subprocess.run([str(RENDER), str(palette), str(ROOT/'templates'), str(out)], check=True, capture_output=True)
                    paper = palette.parent.name == 'FoxML_Paper'
                    opacity = 1.0 if paper else .88
                    for name in ['theme.conf', 'theme.lua']:
                        text = (out/'hyprland'/name).read_text()
                        self.assertNotIn('{{', text)
                        value = re.search(r'inactive_opacity\s*=\s*([\d.]+)', text).group(1)
                        self.assertEqual(float(value), opacity)
                    kitty = (out/'kitty/kitty.conf').read_text()
                    if paper:
                        self.assertRegex(kitty, r'(?m)^dim_opacity\s+1\.0$')
                        self.assertRegex(kitty, r'(?m)^background_opacity\s+0\.70$')

if __name__ == '__main__': unittest.main()
