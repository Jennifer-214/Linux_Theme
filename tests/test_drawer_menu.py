#!/usr/bin/env python3
"""tests/test_drawer_menu.py — the drawer menu's key labels and the bars' clicks stay true to what they name.

- Every `keys` label in shared/quickshell/desk/menus.json is a real Hyprland bind in
  shared/hyprland_modules/keybinds.lua that opens that same item, so a moved bind can't leave a stale label.
- Every bar module that opens the drawer names a page the drawer has, the battery opens the power page
  (it used to open pavucontrol), and the secondary bar's shared modules click the same way as the main bar's.
"""
import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MENU = json.loads((ROOT / "shared/quickshell/desk/menus.json").read_text())
KEYBINDS = (ROOT / "shared/hyprland_modules/keybinds.lua").read_text()
DRAWER = ROOT / "src/desk-drawer/desk-drawer"

# Item actions that are not drawer pages: what their bind runs.
ACTION_COMMANDS = {
    "calendar": r"desktop-menu calendar",
    "wallpaper-next": r"rotate_wallpaper\.sh --cycle",
    "color-picker": r"hyprpicker -a|color_picker\.sh",
    "lock": r"/lock\.sh$",
}


def label(spec):
    """'ALT + SHIFT + N' → 'alt ⇧ n', the way menus.json writes keys."""
    parts = [p.strip() for p in spec.split("+")]
    mods = {p.upper() for p in parts[:-1]}
    key = {"grave": "`", "slash": "/", "space": "space", "return": "enter"}.get(parts[-1].lower(), parts[-1].lower())
    return " ".join([m for m, name in (("alt", "ALT"), ("ctrl", "CTRL"), ("⇧", "SHIFT")) if name in mods] + [key])


def binds():
    found = {}
    for m in re.finditer(r'hl\.bind\((mainMod \.\. )?"([^"]*)", hl\.dsp\.exec_cmd\("([^"]+)"\)', KEYBINDS):
        found[label(("ALT" if m.group(1) else "") + m.group(2))] = m.group(3)
    return found


def pages():
    if not DRAWER.exists():
        subprocess.run(["make", "-s", "-C", str(DRAWER.parent)], check=True)
    return set(subprocess.run([str(DRAWER), "pages"], capture_output=True, text=True, timeout=5, check=True).stdout.split())


class MenuKeys(unittest.TestCase):
    def test_every_key_label_is_a_bind_that_opens_that_item(self):
        table = binds()
        labelled = [i for g in MENU["groups"] for i in g["items"] if "keys" in i]
        self.assertGreaterEqual(len(labelled), 10)
        for item in labelled:
            with self.subTest(item=item["id"], keys=item["keys"]):
                self.assertIn(item["keys"], table, "no Hyprland bind has these keys")
                target = ACTION_COMMANDS.get(item["id"], r"desktop-menu " + re.escape(item.get("page", item["id"])) + r"$")
                self.assertRegex(table[item["keys"]], target)

    def test_keys_are_lowercase_with_the_shift_arrow(self):
        for item in (i for g in MENU["groups"] for i in g["items"] if "keys" in i):
            self.assertRegex(item["keys"], r"^alt( ctrl)?( ⇧)? \S+$", item["id"])


class BarClicks(unittest.TestCase):
    def bar(self, name):
        text = (ROOT / "templates/waybar" / name).read_text()
        text = re.sub(r"__[A-Z_]+__", "0", text)
        return json.loads(text)

    def test_drawer_clicks_name_real_pages(self):
        known = pages() | {"root", "calendar", "search"} | {g["id"] for g in MENU["groups"]}
        for name in ("config", "config_secondary"):
            for module, spec in self.bar(name).items():
                if not isinstance(spec, dict):
                    continue
                for key, command in spec.items():
                    m = re.search(r"desktop-menu (\S+)", command) if key.startswith("on-click") and isinstance(command, str) else None
                    if m:
                        with self.subTest(bar=name, module=module):
                            self.assertIn(m.group(1), known)

    def test_battery_opens_the_power_page(self):
        self.assertEqual(self.bar("config")["custom/battery"]["on-click"], "~/.local/bin/desktop-menu power")

    def test_secondary_bar_clicks_like_the_main_bar(self):
        main, secondary = self.bar("config"), self.bar("config_secondary")
        shared = [k for k in secondary if isinstance(secondary[k], dict) and k in main and isinstance(main[k], dict)]
        self.assertIn("custom/ai_status", shared)
        self.assertIn("custom/updates", shared)
        for module in shared:
            for key in ("on-click", "on-click-right", "on-click-asking"):
                with self.subTest(module=module, key=key):
                    self.assertEqual(secondary[module].get(key), main[module].get(key))


if __name__ == "__main__":
    unittest.main()
