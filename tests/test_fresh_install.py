#!/usr/bin/env python3
"""What a brand-new machine needs on first login: the wallpapers, session and shell the theme expects."""
import re
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULES = ROOT / "src/fox-install/modules"
WALLPAPERS = ROOT / "shared/wallpapers"


def jpeg_size(path):
    data = path.read_bytes()
    at = 2
    while at < len(data):
        marker, length = data[at + 1], struct.unpack(">H", data[at + 2:at + 4])[0]
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            height, width = struct.unpack(">HH", data[at + 5:at + 9])
            return width, height
        at += 2 + length
    raise ValueError(path)


class FreshInstall(unittest.TestCase):
    def test_wallpaper_masters_are_full_size_both_ways(self):
        self.assertEqual(jpeg_size(WALLPAPERS / "foxml_paper_nap.jpg"), (3840, 2160))
        png = (WALLPAPERS / "foxml_paper_nap_portrait.png").read_bytes()
        self.assertEqual(struct.unpack(">II", png[16:24]), (2160, 3840))

    def test_theme_wallpaper_is_seeded_after_the_wallpapers_arrive(self):
        specials = (MODULES / "specials.cpp").read_text()
        self.assertLess(specials.index("for (auto& s : BULK) deploy_dir_files(ctx, s);"),
                        specials.index("seed_theme_wallpaper(ctx);"))

    def test_seeding_never_replaces_a_wallpaper_the_user_picked(self):
        helper = (MODULES / "wallpaper_mode.hpp").read_text()
        self.assertLess(helper.index("is_symlink(link, ec)) return;"), helper.index("create_symlink"))

    def test_first_login_state_is_only_written_once(self):
        greetd = (MODULES / "greetd.cpp").read_text()
        self.assertIn("fs::exists(state)) return;", greetd)
        self.assertIn("seed_regreet_state();\n}", greetd)

    def test_oh_my_zsh_lands_where_the_configs_look(self):
        deps = (MODULES / "deps.cpp").read_text()
        self.assertIn('ctx.home / ".oh-my-zsh"', deps)
        self.assertIn('"git", "clone", "--depth", "1"', deps)
        self.assertNotIn("oh-my-zsh-git", deps)
        self.assertNotIn("tools/install.sh", deps)
        self.assertRegex((ROOT / "templates/zsh/.zshrc").read_text(), re.compile(r'ZSH="\$HOME/\.oh-my-zsh"'))

    def test_login_shell_only_changes_when_it_needs_to(self):
        deps = (MODULES / "deps.cpp").read_text()
        self.assertIn('fs::exists("/usr/bin/zsh")', deps)
        self.assertIn('filename() != "zsh"', deps)


if __name__ == "__main__":
    unittest.main()
