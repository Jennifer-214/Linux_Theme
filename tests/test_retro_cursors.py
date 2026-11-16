#!/usr/bin/env python3
"""retro-amber's drawn pointer set: every name a toolkit asks for, crisp pixels, sizes that match the desktop's."""
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "shared/cursors/foxml-retro-cursors.py"
PALETTE = ROOT / "themes/retro-amber/palette.sh"

# Names the downloaded Catppuccin set provided (real files and links), so nothing falls back to a smooth pointer.
NAMES = """alias all-scroll bottom_left_corner bottom_right_corner bottom_side cell center_ptr color-picker col-resize
context-menu copy crosshair default dnd-move dnd-no-drop down-arrow draft help left-arrow left_side no-drop
not-allowed openhand pencil pirate pointer progress right-arrow right_ptr right_side row-resize size_bdiag
size_fdiag size_hor size_ver text top_left_corner top_right_corner top_side up-arrow vertical-text wait
wayland-cursor x-cursor zoom-in zoom-out arrow circle closedhand cross crossed_circle dnd-copy dnd-none e-resize
ew-resize fleur forbidden grab grabbing half-busy hand hand1 hand2 h_double_arrow ibeam left_ptr left_ptr_help
left_ptr_watch link ll_angle lr_angle move ne-resize nesw-resize n-resize ns-resize nw-resize nwse-resize plus
pointing_hand question_arrow sb_h_double_arrow sb_v_double_arrow se-resize size_all size-bdiag size-fdiag size-hor
size-ver split_h split_v s-resize sw-resize top_left_arrow ul_angle ur_angle v_double_arrow watch whats_this
w-resize X_cursor xterm""".split()


def images(path):
    data = path.read_bytes()
    magic, _, _, count = struct.unpack_from("<4sIII", data, 0)
    assert magic == b"Xcur", path
    out = []
    for i in range(count):
        kind, nominal, pos = struct.unpack_from("<III", data, 16 + 12 * i)
        _, _, _, _, w, h, xhot, yhot, delay = struct.unpack_from("<9I", data, pos)
        pixels = struct.unpack_from("<%dI" % (w * h), data, pos + 36)
        out.append(dict(nominal=nominal, w=w, h=h, xhot=xhot, yhot=yhot, delay=delay, pixels=pixels))
    return out


class RetroCursors(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name) / "theme"
        subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), str(cls.out)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_retro_amber_uses_the_drawn_set(self):
        palette = PALETTE.read_text()
        self.assertIn("\nCURSOR_THEME=foxml-retro-cursors\n", palette)
        self.assertIn("\nCURSOR_RECOLOR=none\n", palette)

    def test_every_name_resolves_to_a_drawn_cursor(self):
        cursors = self.out / "cursors"
        for name in NAMES:
            path = cursors / name
            self.assertTrue(path.exists(), f"{name} is missing")
            if path.is_symlink():
                self.assertNotIn("/", os.readlink(path), f"{name} must link inside the theme")
            self.assertTrue(images(path.resolve()), name)

    def test_pixels_are_crisp_and_the_desktop_size_is_exact(self):
        allowed = {0, 0xFFFFB000, 0xFF0C0A06}
        for path in (self.out / "cursors").iterdir():
            if path.is_symlink():
                continue
            found = images(path)
            self.assertEqual(sorted({i["nominal"] for i in found}), [15, 30, 45, 60], path.name)
            for image in found:
                self.assertTrue(set(image["pixels"]) <= allowed, f"{path.name}: smoothed pixels")
                self.assertTrue(0 <= image["xhot"] < image["w"] and 0 <= image["yhot"] < image["h"], path.name)
                self.assertLessEqual(max(image["w"], image["h"]), 16 * image["nominal"] // 15, path.name)

    def test_size_30_is_the_approved_arrow_at_2x(self):
        arrow = next(i for i in images(self.out / "cursors/default") if i["nominal"] == 30)
        self.assertEqual((arrow["w"], arrow["h"], arrow["xhot"], arrow["yhot"]), (20, 28, 0, 0))

    def test_the_hourglass_runs(self):
        frames = [i for i in images(self.out / "cursors/wait") if i["nominal"] == 30]
        self.assertEqual(len(frames), 4)
        self.assertTrue(all(f["delay"] > 0 for f in frames))
        self.assertEqual(len({f["pixels"] for f in frames}), 4, "every frame shows the sand somewhere else")

    def test_preview_sheet_is_a_png(self):
        sheet = Path(self.tmp.name) / "sheet.png"
        subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--sheet", str(sheet)], check=True)
        self.assertEqual(sheet.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")


if __name__ == "__main__":
    unittest.main()
