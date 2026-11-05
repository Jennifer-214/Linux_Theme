#!/usr/bin/env python3
"""tests/test_app_configs.py — rendered configs use what each app actually reads.

These all rendered cleanly and failed later: the apps accept the file and quietly ignore or misread a value.
"""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RENDERER = ROOT / "src/fox-render/fox-render-fast"
THEMES = sorted(p.parent.name for p in (ROOT / "themes").glob("*/palette.sh"))


def palette_value(theme, key):
    text = (ROOT / "themes" / theme / "palette.sh").read_text()
    return re.search(rf"^{key}=(\S+)", text, re.M).group(1)


@unittest.skipUnless(RENDERER.exists(), "needs fox-render-fast built")
class RenderedConfigsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name)
        for theme in THEMES:
            subprocess.run([RENDERER, ROOT / "themes" / theme / "palette.sh", ROOT / "templates", cls.out / theme],
                           check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_ide_colours_are_hex(self):
        # VS Code passes these to Color.fromHex, which turns anything else red.
        for theme in THEMES:
            text = (self.out / theme / "cursor/foxml-color-theme.json").read_text()
            self.assertNotIn("rgba(", text, theme)

    def test_zathura_sets_both_recolours(self):
        for theme in THEMES:
            text = (self.out / theme / "zathura/zathurarc").read_text()
            colours = dict(re.findall(r'^set (recolor-(?:light|dark)color)\s+"(#\w+)"', text, re.M))
            self.assertEqual(colours, {"recolor-lightcolor": "#" + palette_value(theme, "BG"),
                                       "recolor-darkcolor": "#" + palette_value(theme, "FG")}, theme)


class SourcesTest(unittest.TestCase):
    def test_ide_base_theme_matches_the_palette(self):
        want = {"light": "vs", "dark": "vs-dark"}
        for theme in THEMES:
            self.assertEqual(palette_value(theme, "VSCODE_UI_THEME"), want[palette_value(theme, "THEME_TYPE")], theme)

    def test_ide_manifest_reads_the_palette(self):
        text = (ROOT / "src/fox-install/modules/specials.cpp").read_text()
        self.assertIn('palette::get(ctx.palette_path, "VSCODE_UI_THEME"', text)
        self.assertNotIn('\\"uiTheme\\": \\"vs-dark\\"', text)

    def test_kitty_has_no_keys_it_ignores(self):
        text = (ROOT / "templates/kitty/kitty.conf").read_text()
        self.assertNotRegex(text, r"(?m)^(line|letter)_spacing\b")


if __name__ == "__main__":
    unittest.main(verbosity=2)
