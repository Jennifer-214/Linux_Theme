#!/usr/bin/env python3
"""Render retro-amber's wallpaper: near-black with faint scanlines, a warm centre and an AMBER-86 badge.

Writes shared/wallpapers/retro_amber.png (3840x2160) and retro_amber_portrait.png (2160x3840). The portrait file is
its own render, so a rotated monitor shows the badge in its corner instead of a centre crop that would cut it off
(desk-monitor uses <name>_portrait for rotated outputs).

    python3 scripts/retro-amber-wallpaper.py [--font PATH]

Needs Pillow and numpy; the font is Big Blue Term (ttf-bigblueterminal-nerd).
"""
import argparse
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FONT = "/usr/share/fonts/TTF/BigBlueTerm437NerdFontMono-Regular.ttf"
BG = np.array([10, 9, 6], float)
AMBER = np.array([255, 176, 0], float)
LABEL = "AMBER-86"


def render(width, height, font_path):
    y, x = np.mgrid[0:height, 0:width]
    edge = np.sqrt(((x - width / 2) / (width / 2)) ** 2 + ((y - height / 2) / (height / 2)) ** 2) / math.sqrt(2)
    spread = min(width, height) / 2.2
    warmth = 0.11 * np.exp(-(((x - width / 2) ** 2 + (y - height / 2) ** 2) / (2 * spread ** 2)))

    # The badge: a lit power light and the model name, bottom right, a margin in from the corner.
    size = 54
    ink = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(ink)
    font = ImageFont.truetype(font_path, size)
    text = "   " + LABEL
    margin = int(min(width, height) * 0.045)
    x0 = width - margin - draw.textlength(text, font=font)
    y0 = height - margin - size * 1.15
    draw.text((x0, y0), text, font=font, fill=150)
    r = size * 0.22
    cx, cy = x0 + size * 0.45, y0 + size * 1.15 * 0.5
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=235)

    # Phosphor glow: a tight and a wide blur over the badge.
    layer = np.asarray(ink, float) / 255
    for radius, amount in ((2, 0.7), (size // 2, 0.45)):
        layer = layer + amount * np.asarray(ink.filter(ImageFilter.GaussianBlur(radius)), float) / 255

    level = np.clip(layer * 0.75 + warmth, 0, 1)[..., None]
    colour = BG + (AMBER - BG) * level
    scanline = (np.arange(height) % 4 < 1).astype(float)[:, None, None]
    colour = colour * (1 - 0.35 * scanline) * (1 - 0.6 * edge ** 1.8)[..., None]
    return Image.fromarray(np.uint8(np.clip(colour, 0, 255)))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--font", default=FONT)
    args = ap.parse_args()
    out = ROOT / "shared" / "wallpapers"
    render(3840, 2160, args.font).save(out / "retro_amber.png", optimize=True)
    render(2160, 3840, args.font).save(out / "retro_amber_portrait.png", optimize=True)
    print("wrote", out / "retro_amber.png", "and", out / "retro_amber_portrait.png")


if __name__ == "__main__":
    main()
