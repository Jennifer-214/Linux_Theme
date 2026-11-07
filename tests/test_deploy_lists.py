#!/usr/bin/env python3
"""tests/test_deploy_lists.py — what the installer deploys stays coherent.

- No shared/bin script is named like a tool a src/<tool> Makefile builds. specials' bulk copy puts shared/bin into
  ~/.local/bin, so such a script landed over the compiled binary (installer audit 2026-10-15: fox, fox-vault and
  fox-ai-review). core/built_tools.hpp skips them at install time; this keeps them out of the repo.
- mappings.sh (update.sh captures through it) and symlinks_data.hpp (the installer deploys through it) list the
  same rows, every row's source exists, and every pi extension has a row. The audit found fzf-tab.zsh deployed but
  never captured, and pob / fox-word-count captured but deployed only by the bulk copy.
"""
import os
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The same rule as core/built_tools.hpp: a Makefile's first `BIN = name` / `BIN := name` line.
BIN_RE = re.compile(r"^[ \t]*BIN[ \t]*:?=[ \t]*([^\s#]+)", re.M)

# New surfaces deploy through the native installer; AGENT.md freezes mappings.sh.
ONE_SIDED = {
    ("TEMPLATE_MAPPINGS", "swappy/config", "~/.config/swappy/config"):
        "native-only screenshot annotation colors and pencil strokes; rendered from the selected palette",
    ("TEMPLATE_MAPPINGS", "qt/gtk-palette.json", "~/.config/foxml/qt-palette.json"):
        "native-only Qt GTK bridge palette; generated from the selected palette",
    ("TEMPLATE_MAPPINGS", "yazi/init.lua", "~/.config/yazi/init.lua"):
        "native-only icon styling; generated from the shared icon family",
    ("TEMPLATE_MAPPINGS", "ripgrep/config", "~/.config/ripgrep/config"):
        "native-only search colors; generated from palette tokens",
    ("TEMPLATE_MAPPINGS", "eza/theme.yml", "~/.config/eza/theme.yml"):
        "native-only file-listing theme; generated from palette tokens",
    ("TEMPLATE_MAPPINGS", "hyprlock/capslock-label.sh", "~/.config/hypr/scripts/capslock-label.sh"):
        "native-only lock-screen LED label; rendered from the palette",
    ("TEMPLATE_MAPPINGS", "hyprlock/date-label.sh", "~/.config/hypr/scripts/date-label.sh"):
        "native-only handwritten date; rendered from the palette",
    ("TEMPLATE_MAPPINGS", "hyprland/hyprtoolkit.conf", "~/.config/hypr/hyprtoolkit.conf"):
        "native-only toolkit theme; edit templates/hyprland directly rather than reverse-capturing",
    ("TEMPLATE_MAPPINGS", "codex/foxml.tmTheme", "~/.codex/themes/foxml.tmTheme"):
        "native-only Codex theme; edit templates/codex directly rather than reverse-capturing",
    ("TEMPLATE_MAPPINGS", "claude/foxml-theme.json", "~/.claude/themes/foxml.json"):
        "native-only Claude Code theme; edit templates/claude directly rather than reverse-capturing",
    ("TEMPLATE_MAPPINGS", "claude/statusline.sh", "~/.claude/statusline.sh"):
        "native-only Claude Code status line; edit templates/claude directly rather than reverse-capturing",
}


def sh_rows(name):
    text = (ROOT / "mappings.sh").read_text()
    m = re.search(name + r"=\((.*?)\n\)", text, re.S)
    rows = set()
    for line in m.group(1).splitlines():
        line = line.strip()
        if line.startswith('"'):
            src, dest = line.strip('"').split("|", 1)
            rows.add((src, dest))
    return rows


def hpp_rows(name):
    text = (ROOT / "src/fox-install/modules/symlinks_data.hpp").read_text()
    m = re.search(name + r"\[\] = \{(.*?)\n\};", text, re.S)
    return set(re.findall(r'\{\s*"([^"]+)",\s*"([^"]+)"\s*\}', m.group(1)))


def built_tools():
    names = {}
    for mk in sorted((ROOT / "src").glob("*/Makefile")):
        m = BIN_RE.search(mk.read_text())
        if m:
            names[m.group(1)] = mk.parent.name
    return names


class DeployListsTest(unittest.TestCase):
    def test_no_shared_bin_script_shadows_a_built_tool(self):
        built = built_tools()
        self.assertIn("fox", built)
        self.assertEqual(built.get("fox-render-fast"), "fox-render")
        clashes = sorted(f"shared/bin/{n} vs src/{built[n]}" for n in os.listdir(ROOT / "shared/bin") if n in built)
        self.assertEqual(clashes, [], "a shared/bin script named like a compiled tool would be copied over it")

    def test_mappings_sh_and_symlinks_data_agree(self):
        for name in ("TEMPLATE_MAPPINGS", "SHARED_MAPPINGS"):
            sh, hpp = sh_rows(name), hpp_rows(name)
            self.assertGreater(len(hpp), 20, name)
            only_sh = sorted(r for r in sh - hpp if (name, *r) not in ONE_SIDED)
            only_hpp = sorted(r for r in hpp - sh if (name, *r) not in ONE_SIDED)
            self.assertEqual(only_sh, [], f"{name}: in mappings.sh only (update.sh captures, the installer never deploys)")
            self.assertEqual(only_hpp, [], f"{name}: in symlinks_data.hpp only (deployed, never captured by update.sh)")

    def test_every_row_has_its_source(self):
        for name, base in (("TEMPLATE_MAPPINGS", "templates"), ("SHARED_MAPPINGS", "shared")):
            missing = sorted(src for src, _ in hpp_rows(name) | sh_rows(name) if not (ROOT / base / src).exists())
            self.assertEqual(missing, [], f"{name}: rows whose {base}/ source is gone")

    def test_drawer_runtime_state_is_not_captured_as_configuration(self):
        runtime = ("waybar/drawer-state.css", "~/.config/waybar/drawer-state.css")
        self.assertNotIn(runtime, sh_rows("TEMPLATE_MAPPINGS"))
        self.assertNotIn(runtime, hpp_rows("TEMPLATE_MAPPINGS"))

    def test_theme_swap_keeps_the_login_config_protected(self):
        # A comment between these lines ends the command, and the installer then runs without FOXML_THEME_ONLY,
        # which is what stops a recolour from rewriting /etc/greetd/config.toml.
        text = (ROOT / ("sw" + "ap.sh")).read_text()
        self.assertRegex(text, r'FOXML_THEME_ONLY=1 \\\n\s*"\$fox_install" "\$theme"')

    def test_every_pi_extension_has_a_row(self):
        want = {(f"pi/extensions/{p.name}", f"~/.pi/agent/extensions/{p.name}")
                for p in (ROOT / "shared/pi/extensions").glob("*.ts")}
        self.assertTrue(want)
        self.assertEqual(sorted(want - hpp_rows("SHARED_MAPPINGS")), [], "pi extensions the installer never deploys")
        self.assertEqual(sorted(want - sh_rows("SHARED_MAPPINGS")), [], "pi extensions update.sh never captures")


if __name__ == "__main__":
    unittest.main(verbosity=2)
