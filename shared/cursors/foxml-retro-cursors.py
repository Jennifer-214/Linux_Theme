#!/usr/bin/env python3
"""Draw retro-amber's pointer set: 1990s pixel cursors, amber with a black edge, no smoothing.

Usage: foxml-retro-cursors.py OUT_DIR          write an Xcursor theme (index.theme + cursors/)
       foxml-retro-cursors.py --sheet OUT.png  a preview sheet of every shape, 4x

Each shape is drawn once on a small grid and written at 1x to 4x (nominal sizes 15, 30, 45, 60): at the desktop's
cursor size 30 every grid cell is exactly 2x2 screen pixels. Standard library only, so the installer can run it.
"""
import os
import struct
import sys
import zlib

AMBER = 0xFFFFB000
DARK = 0xFF0C0A06
COLOURS = {"B": DARK, "D": DARK, "A": AMBER, "S": AMBER}
SCALES = (1, 2, 3, 4)
NOMINAL = 15


def rows(art):
    lines = art.strip("\n").split("\n")
    width = len(lines[0])
    assert all(len(line) == width for line in lines), art
    return lines


def outline(mask):
    """Amber cells of `mask`, with a one-cell black edge around them (the grid grows by one on each side)."""
    h, w = len(mask), len(mask[0])
    grid = [["."] * (w + 2) for _ in range(h + 2)]
    for y in range(h):
        for x in range(w):
            if mask[y][x] == "A":
                grid[y + 1][x + 1] = "A"
    for y in range(h + 2):
        for x in range(w + 2):
            if grid[y][x] != "A" and any(
                0 <= y + dy < h + 2 and 0 <= x + dx < w + 2 and grid[y + dy][x + dx] == "A"
                for dy in (-1, 0, 1) for dx in (-1, 0, 1)):
                grid[y][x] = "B"
    return ["".join(r) for r in grid]


def from_cells(w, h, filled):
    return ["".join("A" if filled(x, y) else "." for x in range(w)) for y in range(h)]


def transpose(grid):
    return ["".join(grid[y][x] for y in range(len(grid))) for x in range(len(grid[0]))]


def mirror(grid):
    return [r[::-1] for r in grid]


def flip(grid):
    return grid[::-1]


def place(base, overlay, ox, oy):
    """`overlay` drawn over `base` at (ox, oy); the canvas grows to hold both."""
    w = max(len(base[0]), ox + len(overlay[0]))
    h = max(len(base), oy + len(overlay))
    canvas = [list(r.ljust(w, ".")) for r in base] + [["."] * w for _ in range(h - len(base))]
    for y, r in enumerate(overlay):
        for x, c in enumerate(r):
            if c != ".":
                canvas[oy + y][ox + x] = c
    return ["".join(r) for r in canvas]


ARROW = rows("""
B.........
BB........
BAB.......
BAAB......
BAAAB.....
BAAAAB....
BAAAAAB...
BAAAAAAB..
BAAAAAAAB.
BAAAABBBBB
BAABAAB...
BAB.BAAB..
BB..BAAB..
B....BB...
""")

BEAM = rows("""
BBB.BBB
BAABAAB
BBBABBB
..BAB..
..BAB..
..BAB..
..BAB..
..BAB..
..BAB..
..BAB..
..BAB..
BBBABBB
BAABAAB
BBB.BBB
""")

HAND = rows("""
.....BB......
....BAAB.....
....BAAB.....
....BAAB.....
....BAABBB...
....BAABAABB.
....BAABAABAB
.BB.BAABAABAB
BAABBAAAAAAAB
BAAABAAAAAAAB
.BAAAAAAAAAAB
..BAAAAAAAAB.
...BAAAAAAB..
...BBBBBBBB..
""")

GLASS = rows("""
BBBBBBBBBB
BAAAAAAAAB
BBBBBBBBBB
.BDDDDDDB.
.BDDDDDDB.
..BDDDDB..
...BDDB...
...BDDB...
..BDDDDB..
.BDDDDDDB.
.BDDDDDDB.
BBBBBBBBBB
BAAAAAAAAB
BBBBBBBBBB
""")

MINI_GLASS = rows("""
BBBBBB
BDDDDB
.BDDB.
..BB..
.BDDB.
BDDDDB
BBBBBB
""")

NO = rows("""
....BBBBB....
..BBAAAAABB..
.BAAABBBAAAB.
.BAABDDDBAAB.
BAAABSDDDBAAB
BAABSSDDDDBAB
BAABDSSDDDBAB
BAABDDSSDDBAB
BAABDDDSSDBAB
BAABDDDDSSBAB
.BAABDDDDBAB.
.BAAABBBAAAB.
..BBAAAAABB..
....BBBBB....
""")

CROSS = rows("""
.....BBB.....
.....BAB.....
.....BAB.....
.....BAB.....
.....BAB.....
BBBBBB.BBBBBB
BAAAAA.AAAAAB
BBBBBB.BBBBBB
.....BAB.....
.....BAB.....
.....BAB.....
.....BAB.....
.....BBB.....
""")

CELL = rows("""
...BBBBB...
...BAAAB...
...BAAAB...
BBBBAAABBBB
BAAAAAAAAAB
BAAAAAAAAAB
BAAAAAAAAAB
BBBBAAABBBB
...BAAAB...
...BAAAB...
...BBBBB...
""")

MOVE = outline(rows("""
......A......
.....AAA.....
....AAAAA....
......A......
..A...A...A..
.AA...A...AA.
AAAAAAAAAAAAA
.AA...A...AA.
..A...A...A..
......A......
....AAAAA....
.....AAA.....
......A......
"""))

SIZE_HOR = outline(rows("""
..A.......A..
.AA.......AA.
AAAAAAAAAAAAA
.AA.......AA.
..A.......A..
"""))

SIZE_FDIAG = outline(from_cells(11, 11, lambda x, y: x == y or (x + y <= 4) or ((10 - x) + (10 - y) <= 4)))

COL_RESIZE = outline(from_cells(13, 13, lambda x, y: x in (5, 7) or (y == 6 and x not in (6,))
                                or (y in (5, 7) and x in (1, 11)) or (y in (4, 8) and x in (2, 10))))

X_SHAPE = outline(from_cells(11, 11, lambda x, y: x == y or x + y == 10))

UP = outline(from_cells(9, 12, lambda x, y: (y <= 4 and abs(x - 4) <= y) or (y > 4 and 3 <= x <= 5)))


def zoom(plus):
    def filled(x, y):
        d2 = (x - 5) ** 2 + (y - 5) ** 2
        ring = 13 <= d2 <= 25
        handle = 9 <= x <= 12 and 9 <= y <= 12 and abs(x - y) <= 1
        sign = (y == 5 and 3 <= x <= 7) or (plus and x == 5 and 3 <= y <= 7)
        return ring or handle or sign
    return outline(from_cells(13, 13, filled))


QUESTION = outline(rows("""
.AAA.
A...A
....A
...A.
..A..
..A..
.....
..A..
"""))

PLUS_BADGE = outline(rows("""
..A..
..A..
AAAAA
..A..
..A..
"""))

ALIAS_BADGE = outline(rows("""
..AAA
...AA
..A.A
.A...
A....
"""))

MENU_BADGE = outline(rows("""
AAAAA
.....
AAAAA
.....
AAAAA
"""))


def glass(level, art=GLASS, top=range(3, 7), bottom=range(7, 11)):
    """The hourglass with `level` of its sand run through, 0 (all on top) to 3 (all below)."""
    grid = [list(r) for r in art]
    top_rows = list(top)[level:]
    bottom_rows = list(bottom)[len(bottom) - level - 1:] if level else []
    for y in list(top_rows) + list(bottom_rows):
        grid[y] = ["S" if c == "D" else c for c in grid[y]]
    if level < 3:
        for y in (6, 7):
            grid[y] = ["S" if c == "D" and (x == len(grid[y]) // 2 or x == len(grid[y]) // 2 - 1) else c
                       for x, c in enumerate(grid[y])]
    return ["".join(r) for r in grid]


def mini_glass(sand_on_top):
    grid = [list(r) for r in MINI_GLASS]
    for y in ((1, 2) if sand_on_top else (4, 5)):
        grid[y] = ["S" if c == "D" else c for c in grid[y]]
    return ["".join(r) for r in grid]


def centre(grid):
    return (len(grid[0]) // 2, len(grid) // 2)


# Each shape: frames (grids), hotspot on the grid, milliseconds per frame.
SHAPES = {
    "default": ([ARROW], (0, 0), 0),
    "right_ptr": ([mirror(ARROW)], (len(ARROW[0]) - 1, 0), 0),
    "text": ([BEAM], centre(BEAM), 0),
    "vertical-text": ([transpose(BEAM)], centre(transpose(BEAM)), 0),
    "pointer": ([HAND], (5, 0), 0),
    "wait": ([glass(level) for level in range(4)], centre(GLASS), 250),
    "progress": ([place(ARROW, mini_glass(top), 10, 7) for top in (True, False)], (0, 0), 500),
    "help": ([place(ARROW, QUESTION, 9, 4)], (0, 0), 0),
    "copy": ([place(ARROW, PLUS_BADGE, 9, 7)], (0, 0), 0),
    "alias": ([place(ARROW, ALIAS_BADGE, 9, 7)], (0, 0), 0),
    "context-menu": ([place(ARROW, MENU_BADGE, 9, 7)], (0, 0), 0),
    "crosshair": ([CROSS], centre(CROSS), 0),
    "cell": ([CELL], centre(CELL), 0),
    "not-allowed": ([NO], centre(NO), 0),
    "move": ([MOVE], centre(MOVE), 0),
    "size_hor": ([SIZE_HOR], centre(SIZE_HOR), 0),
    "size_ver": ([transpose(SIZE_HOR)], centre(transpose(SIZE_HOR)), 0),
    "size_fdiag": ([SIZE_FDIAG], centre(SIZE_FDIAG), 0),
    "size_bdiag": ([mirror(SIZE_FDIAG)], centre(SIZE_FDIAG), 0),
    "col-resize": ([COL_RESIZE], centre(COL_RESIZE), 0),
    "row-resize": ([transpose(COL_RESIZE)], centre(COL_RESIZE), 0),
    "x-cursor": ([X_SHAPE], centre(X_SHAPE), 0),
    "zoom-in": ([zoom(True)], (6, 6), 0),
    "zoom-out": ([zoom(False)], (6, 6), 0),
    "up-arrow": ([UP], (len(UP[0]) // 2, 0), 0),
    "down-arrow": ([flip(UP)], (len(UP[0]) // 2, len(UP) - 1), 0),
    "left-arrow": ([transpose(UP)], (0, len(UP[0]) // 2), 0),
    "right-arrow": ([mirror(transpose(UP))], (len(UP) - 1, len(UP[0]) // 2), 0),
}

# Every other name a toolkit asks for, drawn as the shape that means the same.
ALIASES = {
    "left_ptr": "default", "arrow": "default", "top_left_arrow": "default", "wayland-cursor": "default",
    "size-bdiag": "default", "size-fdiag": "default", "size-hor": "default", "size-ver": "default",
    "xterm": "text", "ibeam": "text",
    "hand": "pointer", "hand1": "pointer", "hand2": "pointer", "pointing_hand": "pointer",
    "openhand": "pointer", "grab": "pointer",
    "9d800788f1b08800ae810202380a0822": "pointer", "e29285e634086352946a0e7090d73106": "pointer",
    "watch": "wait",
    "left_ptr_watch": "progress", "half-busy": "progress", "00000000000000020006000e7e9ffc3f": "progress",
    "08e8e1c95fe2fc01f976f1e063a24ccd": "progress", "3ecb610c1bf2410f44200f48c40d3599": "progress",
    "question_arrow": "help", "whats_this": "help", "left_ptr_help": "help",
    "5c6cd98b3f3ebcb1f9c7f1c204630408": "help", "d9ce0ab605698f320427677b458ad60b": "help",
    "dnd-copy": "copy", "1081e37283d90000800003c07f3ef6bf": "copy", "6407b0e94181790501fd1e167b474872": "copy",
    "b66166c04f8c3109214a4fbd64a50fc8": "copy",
    "link": "alias", "dnd-link": "alias", "3085a0e285430894940527032f8b26df": "alias",
    "640fb0e74195791501fd1ed57b41487f": "alias", "a2a266d0498c3104214a47bd64ab0fc8": "alias",
    "cross": "crosshair", "tcross": "crosshair", "pencil": "crosshair", "draft": "crosshair",
    "color-picker": "crosshair",
    "plus": "cell",
    "circle": "not-allowed", "crossed_circle": "not-allowed", "forbidden": "not-allowed", "no-drop": "not-allowed",
    "dnd-no-drop": "not-allowed", "03b6e0fcb3499374a867c041f52298f0": "not-allowed",
    "all-scroll": "move", "fleur": "move", "size_all": "move", "dnd-move": "move", "dnd-none": "move",
    "closedhand": "move", "grabbing": "move", "4498f0e0c1937ffe01fd06f973665830": "move",
    "9081237383d90e509aa00f00170e968f": "move", "fcf21c00b30f7e3f83fe0dfd12e71cff": "move",
    "e-resize": "size_hor", "w-resize": "size_hor", "ew-resize": "size_hor", "h_double_arrow": "size_hor",
    "sb_h_double_arrow": "size_hor", "left_side": "size_hor", "right_side": "size_hor",
    "n-resize": "size_ver", "s-resize": "size_ver", "ns-resize": "size_ver", "v_double_arrow": "size_ver",
    "sb_v_double_arrow": "size_ver", "top_side": "size_ver", "bottom_side": "size_ver",
    "00008160000006810000408080010102": "size_ver",
    "nw-resize": "size_fdiag", "se-resize": "size_fdiag", "nwse-resize": "size_fdiag",
    "top_left_corner": "size_fdiag", "bottom_right_corner": "size_fdiag", "ul_angle": "size_fdiag",
    "lr_angle": "size_fdiag",
    "ne-resize": "size_bdiag", "sw-resize": "size_bdiag", "nesw-resize": "size_bdiag",
    "top_right_corner": "size_bdiag", "bottom_left_corner": "size_bdiag", "ur_angle": "size_bdiag",
    "ll_angle": "size_bdiag",
    "split_h": "col-resize", "sb_h_double_arrow_col": "col-resize",
    "split_v": "row-resize",
    "X_cursor": "x-cursor", "pirate": "x-cursor",
    "center_ptr": "up-arrow", "sb_up_arrow": "up-arrow", "sb_down_arrow": "down-arrow",
    "sb_left_arrow": "left-arrow", "sb_right_arrow": "right-arrow",
}


def pixels(grid, scale):
    h, w = len(grid) * scale, len(grid[0]) * scale
    out = []
    for y in range(h):
        row = grid[y // scale]
        for x in range(w):
            out.append(COLOURS.get(row[x // scale], 0))
    return w, h, out


def xcursor(frames, hotspot, delay):
    images = []
    for scale in SCALES:
        for grid in frames:
            w, h, px = pixels(grid, scale)
            hx = min(w - 1, hotspot[0] * scale + (scale // 2 if hotspot != (0, 0) else 0))
            hy = min(h - 1, hotspot[1] * scale + (scale // 2 if hotspot != (0, 0) else 0))
            body = struct.pack("<9I", 36, 0xFFFD0002, NOMINAL * scale, 1, w, h, hx, hy, delay)
            images.append((NOMINAL * scale, body + struct.pack("<%dI" % len(px), *px)))
    head = struct.pack("<4sIII", b"Xcur", 16, 0x10000, len(images))
    position = 16 + 12 * len(images)
    toc, chunks = b"", b""
    for nominal, chunk in images:
        toc += struct.pack("<III", 0xFFFD0002, nominal, position)
        position += len(chunk)
        chunks += chunk
    return head + toc + chunks


def write_theme(out):
    cursors = os.path.join(out, "cursors")
    os.makedirs(cursors, exist_ok=True)
    for name, (frames, hotspot, delay) in SHAPES.items():
        assert all(len(f) <= 16 and len(f[0]) <= 16 for f in frames), name
        with open(os.path.join(cursors, name), "wb") as f:
            f.write(xcursor(frames, hotspot, delay))
    for name, target in ALIASES.items():
        assert target in SHAPES, (name, target)
        link = os.path.join(cursors, name)
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(target, link)
    with open(os.path.join(out, "index.theme"), "w") as f:
        f.write("[Icon Theme]\nName=foxml-retro-cursors\n"
                "Comment=Pixel cursors for retro-amber, drawn by shared/cursors/foxml-retro-cursors.py\n"
                "Inherits=Adwaita\n")


def png(path, w, h, px):
    raw = b"".join(b"\x00" + b"".join(struct.pack(">I", ((p & 0xFFFFFF) << 8) | (p >> 24)) for p in px[y * w:(y + 1) * w])
                   for y in range(h))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def sheet(path, scale=4, cell=18, per_row=8):
    names = list(SHAPES)
    frames = [(n, f) for n in names for f in SHAPES[n][0][:1]] + [("wait", f) for f in SHAPES["wait"][0][1:]]
    cols = per_row
    rows_n = (len(frames) + cols - 1) // cols
    w, h = cols * cell * scale, rows_n * cell * scale
    px = [0xFF14100A] * (w * h)
    for i, (_, grid) in enumerate(frames):
        ox, oy = (i % cols) * cell * scale + scale, (i // cols) * cell * scale + scale
        gw, gh, g = pixels(grid, scale)
        for y in range(gh):
            for x in range(gw):
                if g[y * gw + x]:
                    px[(oy + y) * w + ox + x] = g[y * gw + x]
    png(path, w, h, px)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--sheet":
        sheet(sys.argv[2])
    elif len(sys.argv) == 2:
        write_theme(sys.argv[1])
    else:
        sys.exit(__doc__)
