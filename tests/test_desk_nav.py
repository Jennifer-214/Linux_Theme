"""Directional desktop shortcuts in Hyprland's two config formats."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "shared/nvim_lua"


class Binds(unittest.TestCase):
    def test_alt_hjkl_focus_the_desktop_directly_in_both_twins(self):
        lua = (ROOT / "shared/hyprland_modules/keybinds.lua").read_text()
        conf = (ROOT / "shared/hyprland_modules/keybinds.conf").read_text()
        for key, direction, legacy in zip("hjkl", ("left", "down", "up", "right"), "ldur"):
            self.assertIn(f'hl.bind(mainMod .. " + {key}", hl.dsp.focus({{ direction = "{direction}" }}))', lua)
            self.assertIn(f"bind = $mainMod, {key}, movefocus, {legacy}", conf)

    def test_neovim_maps_no_alt_direction_key_for_it(self):
        # The keys never reach Neovim under Hyprland; its own Alt maps (move a line, j and k) are left as they are.
        nav = (LUA / "desk/nav.lua").read_text()
        self.assertNotIn("keymap", nav)
        self.assertIn('pcall(function() require("desk.nav").setup() end)', (ROOT / "templates/nvim/init.lua").read_text())


if __name__ == "__main__":
    unittest.main()
