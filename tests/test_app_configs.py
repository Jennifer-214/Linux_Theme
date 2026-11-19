#!/usr/bin/env python3
"""tests/test_app_configs.py — rendered configs use what each app actually reads.

These all rendered cleanly and failed later: the apps accept the file and quietly ignore or misread a value.
"""
import re
import configparser
import base64
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RENDERER = ROOT / "src/desk-render/desk-render-fast"
THEMES = sorted(p.parent.name for p in (ROOT / "themes").glob("*/palette.sh"))


def palette_value(theme, key):
    text = (ROOT / "themes" / theme / "palette.sh").read_text()
    return re.search(rf"^{key}=(\S+)", text, re.M).group(1)


def palette_has(theme, key):
    return re.search(rf"^{key}=", (ROOT / "themes" / theme / "palette.sh").read_text(), re.M) is not None


def css_preludes(css):
    """The text before each '{' (selectors, or an at-rule's prelude), comments dropped; no nesting in these files."""
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    last = 0
    for mark in re.finditer(r"[{};]", css):
        if mark.group() == "{":
            yield " ".join(css[last:mark.start()].split())
        last = mark.end()


def top_level_selectors(prelude):
    parts, depth, current = [], 0, ""
    for ch in prelude:
        depth += (ch in "([") - (ch in ")]")
        if ch == "," and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += ch
    return parts + [current.strip()]


@unittest.skipUnless(RENDERER.exists(), "needs desk-render-fast built")
class EmptyPaletteTest(unittest.TestCase):
    def test_an_empty_palette_is_refused_rather_than_rendered_blank(self):
        with tempfile.TemporaryDirectory() as tmp:
            palette = Path(tmp) / "palette.sh"
            palette.write_text("# nothing here\n")
            run = subprocess.run([RENDERER, palette, ROOT / "templates", Path(tmp) / "out"], capture_output=True, text=True)
            self.assertEqual(run.returncode, 1, run.stderr)
            self.assertIn("palette parsed empty", run.stderr)
            self.assertFalse(any((Path(tmp) / "out").rglob("*.conf")), "nothing was rendered")


@unittest.skipUnless(RENDERER.exists(), "needs desk-render-fast built")
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

    def test_gtk_retro_is_square_on_the_font_grid_and_the_others_keep_their_look(self):
        for theme in THEMES:
            retro = palette_value(theme, "DESK_STYLE") == "retro"
            for version in ("gtk-3.0", "gtk-4.0"):
                ini = configparser.ConfigParser(interpolation=None)
                ini.read(self.out / theme / version / "settings.ini")
                font = ini["Settings"]["gtk-font-name"]
                # Big Blue Term is crisp at 12 px (9 pt at GTK's 96 dpi); the other themes keep 11.5.
                self.assertEqual(font.rsplit(" ", 1)[1], "9" if retro else "11.5", (theme, version))
                css = (self.out / theme / version / "gtk.css").read_text()
                self.assertNotIn("{{", css, (theme, version))
                block = css[css.index("/* retro: a DOS screen"):]
                selectors = block[block.index("*/") + 2:block.index("{ border-radius: 0; }")].split(",")
                for selector in (s.strip() for s in selectors):
                    if retro:
                        self.assertTrue(selector.startswith(("window", "tooltip")), (theme, selector))
                    else:
                        self.assertTrue(selector.startswith(".foxml-retro-off") or selector == ":not(*)", (theme, selector))

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

    def test_firefox_embeds_the_shared_botanical_illustration(self):
        cat = (ROOT / "shared/quickshell/desk/paper-sprig.png").read_bytes()
        for theme in THEMES:
            css = (self.out / theme / "firefox/userContent.css").read_text()
            encoded = re.search(r'data:image/png;base64,([A-Za-z0-9+/=]+)', css)
            self.assertIsNotNone(encoded, theme)
            self.assertEqual(base64.b64decode(encoded.group(1)), cat, theme)

    def test_firefox_retro_rules_reach_retro_only(self):
        # FF_RETRO_SCOPE is ':root' in retro and ':not(*)' (matching nothing) everywhere else, so the retro rules are
        # inert in the other themes' stylesheets; their brace count stays balanced, so nothing after them is swallowed.
        for theme in THEMES:
            retro = palette_value(theme, "DESK_STYLE") == "retro"
            self.assertEqual(palette_value(theme, "FF_RETRO_SCOPE").strip("'\""), ":root" if retro else ":not(*)", theme)
            for name in ("userChrome.css", "userContent.css"):
                css = (self.out / theme / "firefox" / name).read_text()
                self.assertNotIn("{{", css, (theme, name))
                self.assertEqual(css.count("{"), css.count("}"), (theme, name))

    def test_firefox_retro_is_a_dos_screen(self):
        theme = next(t for t in THEMES if palette_value(t, "DESK_STYLE") == "retro")
        fg, bg, gold = (palette_value(theme, key) for key in ("FG", "BG", "GOLD"))
        font = re.search(r'^FONT_FAMILY="([^"]+)"', (ROOT / "themes" / theme / "palette.sh").read_text(), re.M).group(1)
        content = " ".join((self.out / theme / "firefox/userContent.css").read_text().split())
        chrome = " ".join((self.out / theme / "firefox/userChrome.css").read_text().split())
        for want in (
            # Vimium hints: inverse amber cells of the 12 px font, square, no shadow; the Vomnibar and HUD double-framed
            f":root div.internal-vimium-hint-marker {{ background: #{fg} !important; border: 0 !important; "
            "border-radius: 0 !important; box-shadow: none !important;",
            f"color: #{bg} !important; font: 12px/12px \"{font}\", monospace !important;",
            f":root #vomnibar, :root #hud-container {{ background: #{bg} !important; color: #{fg} !important; "
            f"border: 4px double #{fg} !important;",
            # Firefox's own pages: the font on its 12 px cell, amber tokens, a bright 2 px focus ring
            "@-moz-document url-prefix(\"about:preferences\"), url-prefix(\"about:settings\"), url-prefix(\"about:addons\"), "
            "url-prefix(\"about:downloads\"), url-prefix(\"about:profiles\"), url-prefix(\"about:config\"),",
            f"--focus-outline: 2px solid #{gold} !important;",
            "--font-size-root: 12px !important;",
            # the PDF viewer (scoped by pdf.js's own root attribute) and reader view on whole cells
            ":root[mozdisallowselectionprint] {",
            "font-size: round(nearest, var(--font-size), 12px) !important;",
        ):
            self.assertIn(want, content)
        for want in (
            f"--panel-border-color: #{fg} !important;",
            "--panel-box-shadow-margin: 0px !important;",
            f":root :is(menuitem, menu)[_moz-menuactive]:not([disabled]), :root .subviewbutton:not([disabled])"
            f":is(:hover, [_moz-menuactive], :focus-visible),",
            f"background: #{fg} !important; color: #{bg} !important;",
        ):
            self.assertIn(want, chrome)

    def test_firefox_retro_tab_lists_and_accents(self):
        # Firefox marks the open tab with a bare [selected] and keeps vertical tabs outside the tab toolbar, so the menu
        # bar's dark titles stay in #TabsToolbar and the vertical list gets amber ones (it showed none). The pages Firefox
        # draws, and its new tab page, set the accent that would otherwise stay Firefox's lilac.
        theme = next(t for t in THEMES if palette_value(t, "DESK_STYLE") == "retro")
        fg, bg, surface = (palette_value(theme, key) for key in ("FG", "BG", "SURFACE"))
        chrome = " ".join((self.out / theme / "firefox/userChrome.css").read_text().split())
        content = " ".join((self.out / theme / "firefox/userContent.css").read_text().split())
        retro_chrome = chrome[chrome.index("/* retro-amber: the tab strip as a DOS menu bar"):]
        self.assertNotIn('[selected="true"]', retro_chrome)
        for want in (
            f":root #TabsToolbar .tabbrowser-tab[selected] .tab-background {{ background: #{bg} !important;",
            ':root #tabbrowser-tabs[orient="vertical"] .tabbrowser-tab :is(.tab-content, .tab-label, .tab-close-button), '
            f":root #vertical-tabs toolbarbutton {{ color: #{fg} !important;",
            f':root #tabbrowser-tabs[orient="vertical"] .tabbrowser-tab[selected] .tab-background {{ background: #{fg} !important; }}',
            ':root #tabbrowser-tabs[orient="vertical"] .tabbrowser-tab[selected] :is(.tab-content, .tab-label, .tab-close-button) '
            f"{{ color: #{bg} !important;",
            f":root :is(#sidebar-container, sidebar-main) {{ background-color: #{bg} !important;",
            "--color-accent-primary-hover:",
        ):
            self.assertIn(want, retro_chrome)
        for want in (
            'url-prefix("about:config"), url-prefix("about:support"), url-prefix("about:logins"), '
            'url-prefix("about:privatebrowsing") { :root { color-scheme: dark !important;',
            f"--button-background-color-primary-disabled: #{surface} !important;",
            ":root moz-page-header { text-transform: uppercase !important; }",
            f"--content-search-handoff-ui-unfocused-border-color: #{fg} !important;",
            f':root private-browsing-mask-intro {{ --icon-mask-color: #{fg} !important; }}',
            f'@-moz-document url("about:newtab"), url("about:home") {{ :root {{ --color-accent-primary: #{fg} !important;',
        ):
            self.assertIn(want, content)

    def test_fastfetch_configs_are_valid_json_for_every_palette(self):
        for theme in THEMES:
            data = json.loads((self.out / theme / "fastfetch/config.jsonc").read_text())
            self.assertIn(data['logo']['type'], ['small', 'data'], theme)
            self.assertNotIn('{{', json.dumps(data), theme)

    def test_screenshot_editor_uses_valid_palette_ink_and_pencil_strokes(self):
        for theme in THEMES:
            config = configparser.ConfigParser(interpolation=None)
            config.read(self.out / theme / 'swappy/config')
            settings = config['Default']
            self.assertRegex(settings['custom_color'], r'^#[0-9a-fA-F]{6}$', theme)
            self.assertEqual(settings.getint('line_size'), 2)
            self.assertEqual(settings['save_dir'], '$HOME/Pictures/Screenshots')
            self.assertNotIn('{{', settings['text_font'])

    def test_dark_reader_settings_pass_its_own_checks(self):
        # Her ask (2026-11-19): website text in amber and every site dark. Dark Reader cannot take settings from Firefox's
        # policy file, so the installer leaves this file for her to import once; Dark Reader replaces any value it does
        # not accept with its default, so every key is written and checked here against its rules (darkreader
        # src/utils/validation.ts and src/defaults.ts, read 2026-11-19).
        hexcolour = re.compile(r"^#[0-9a-f]{6}$", re.I)
        theme_rules = {
            "mode": lambda v: v in (0, 1), "brightness": lambda v: 0 <= v <= 200, "contrast": lambda v: 0 <= v <= 200,
            "grayscale": lambda v: 0 <= v <= 100, "sepia": lambda v: 0 <= v <= 100, "useFont": lambda v: isinstance(v, bool),
            "fontFamily": lambda v: isinstance(v, str) and v != "", "textStroke": lambda v: 0 <= v <= 1,
            "engine": lambda v: v in ("dynamicTheme", "staticTheme", "cssFilter", "svgFilter"), "stylesheet": lambda v: isinstance(v, str),
            "darkSchemeBackgroundColor": hexcolour.match, "darkSchemeTextColor": hexcolour.match,
            "lightSchemeBackgroundColor": hexcolour.match, "lightSchemeTextColor": hexcolour.match,
            "scrollbarColor": lambda v: v == "" or re.match(r"^(auto)|(#[0-9a-f]{6})$", v, re.I),
            "selectionColor": lambda v: re.match(r"^(auto)|(#[0-9a-f]{6})$", v, re.I),
            "styleSystemControls": lambda v: isinstance(v, bool), "lightColorScheme": lambda v: isinstance(v, str) and v != "",
            "darkColorScheme": lambda v: isinstance(v, str) and v != "", "immediateModify": lambda v: isinstance(v, bool),
        }
        top = {"schemeVersion", "enabled", "fetchNews", "theme", "presets", "customThemes", "enabledByDefault", "enabledFor",
               "disabledFor", "changeBrowserTheme", "syncSettings", "syncSitesFixes", "automation", "time", "location",
               "previewNewDesign", "previewNewestDesign", "enableForPDF", "enableForProtectedPages", "enableContextMenus",
               "detectDarkTheme"}
        for theme in THEMES:
            path = self.out / theme / "firefox/darkreader.json"
            settings = json.loads(path.read_text())
            self.assertEqual(set(settings), top, theme)
            for name, ok in theme_rules.items():
                self.assertTrue(ok(settings["theme"][name]), (theme, name, settings["theme"][name]))
            self.assertEqual(set(settings["theme"]), set(theme_rules), theme)
            self.assertEqual([c["url"] for c in settings["customThemes"]],
                             [["*.officeapps.live.com"], ["*.sharepoint.com"], ["docs.google.com"], ["onedrive.live.com"]],
                             "Dark Reader's own built-in site rules kept")
            for custom in settings["customThemes"]:
                self.assertEqual(set(custom["theme"]), set(theme_rules), theme)
            self.assertTrue(re.match(r"^((0?[0-9])|(1[0-9])|(2[0-3])):([0-5][0-9])$", settings["time"]["activation"]))
            self.assertEqual(settings["automation"]["mode"], "", "no automation: always on")
            # every site, the ones with a dark mode of their own too; no fetch of Dark Reader's news
            self.assertEqual((settings["detectDarkTheme"], settings["fetchNews"], settings["enabledByDefault"]), (False, False, True))
        amber = json.loads((self.out / "retro-amber/firefox/darkreader.json").read_text())["theme"]
        self.assertEqual((amber["darkSchemeTextColor"], amber["darkSchemeBackgroundColor"]), ("#ffb000", "#0c0a06"),
                         "retro-amber: amber text on the near-black")


class SourcesTest(unittest.TestCase):
    def test_ide_base_theme_matches_the_palette(self):
        want = {"light": "vs", "dark": "vs-dark"}
        for theme in THEMES:
            self.assertEqual(palette_value(theme, "VSCODE_UI_THEME"), want[palette_value(theme, "THEME_TYPE")], theme)

    def test_ide_manifest_reads_the_palette(self):
        text = (ROOT / "src/desk-install/modules/specials.cpp").read_text()
        self.assertIn('palette::get(ctx.palette_path, "VSCODE_UI_THEME"', text)
        self.assertNotIn('\\"uiTheme\\": \\"vs-dark\\"', text)

    def test_firefox_retro_rules_scope_every_selector(self):
        # One selector in a retro rule's list without the scope would reach every other theme's Firefox.
        for name in ("userChrome.css", "userContent.css"):
            text = (ROOT / "templates/firefox" / name).read_text().replace("{{FF_RETRO_SCOPE}}", "RETRO")
            preludes = [p for p in css_preludes(re.sub(r"\{\{[A-Z0-9_]+\}\}", "X", text)) if "RETRO" in p]
            self.assertTrue(preludes, name)
            for prelude in preludes:
                for selector in top_level_selectors(prelude):
                    self.assertTrue(selector.startswith("RETRO"), (name, selector))

    def test_firefox_retro_sections_scope_every_rule(self):
        # A retro rule with no scope at all has no RETRO in it, so the test above never sees it. From each retro-only
        # section's heading to the end of its file, every rule (an @-moz-document block aside) is scoped.
        for name, heading in (("userChrome.css", "/* retro-amber: the tab strip as a DOS menu bar"),
                              ("userContent.css", "/* ===== retro-amber: Firefox's own pages")):
            text = (ROOT / "templates/firefox" / name).read_text()
            self.assertEqual(text.count(heading), 1, (name, heading))
            section = text[text.index(heading):].replace("{{FF_RETRO_SCOPE}}", "RETRO")
            rules = [p for p in css_preludes(re.sub(r"\{\{[A-Z0-9_]+\}\}", "X", section)) if not p.startswith("@")]
            self.assertTrue(rules, name)
            for prelude in rules:
                for selector in top_level_selectors(prelude):
                    self.assertTrue(selector.startswith("RETRO"), (name, selector))

    def test_firefox_website_appearance_is_retro_only(self):
        # The installer writes Firefox's website appearance into user.js only for a theme that names one, so every other
        # theme's user.js is written exactly as before.
        for theme in THEMES:
            retro = palette_value(theme, "DESK_STYLE") == "retro"
            self.assertEqual(palette_has(theme, "FF_WEBSITE_APPEARANCE"), retro, theme)
            if retro:
                self.assertEqual(palette_value(theme, "FF_WEBSITE_APPEARANCE"), "dark")
        text = (ROOT / "src/desk-install/modules/specials.cpp").read_text()
        self.assertIn('palette::get(ctx.palette_path, "FF_WEBSITE_APPEARANCE"', text)

    def test_dark_reader_is_asked_for_by_retro_amber_only(self):
        for theme in THEMES:
            self.assertEqual(palette_has(theme, "FF_DARK_READER"), theme == "retro-amber", theme)
        self.assertEqual(palette_value("retro-amber", "FF_DARK_READER"), "on")
        text = (ROOT / "src/desk-install/modules/specials.cpp").read_text()
        self.assertIn('palette::get(ctx.palette_path, "FF_DARK_READER"', text)
        self.assertIn("darkreader-settings.json", text)

    def test_kitty_has_no_keys_it_ignores(self):
        text = (ROOT / "templates/kitty/kitty.conf").read_text()
        self.assertNotRegex(text, r"(?m)^(line|letter)_spacing\b")


if __name__ == "__main__":
    unittest.main(verbosity=2)
