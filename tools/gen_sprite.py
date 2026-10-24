#!/usr/bin/env python3
"""Pixel art of the dancing mascot (original drawing): src/rtl/mem/sprite.mem

24 x 32 pixels per frame, 4-bit palette index per pixel (0 = transparent),
5 frames: 0 idle, 1 idle with blink, 2 dance left, 3 dance middle, 4 dance right.
vga_ui.sv shows it x3 in the corner of the oscilloscope and plays 2-3-4-3
while music is playing. The palette (6-bit RGB) is in vga_ui.sv too.

Output: 5 * 768 lines, one hex digit each, address = frame*768 + y*24 + x.
Usage:  python3 tools/gen_sprite.py [--preview sprite.png]
"""
import argparse
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "src", "rtl", "mem", "sprite.mem")
W, H = 24, 32

# palette: index -> (r, g, b) 6 bit; keep in sync with vga_ui.sv
PAL = {
    1: (4, 8, 8),      # outline
    2: (62, 52, 44),   # skin
    3: (52, 40, 34),   # skin shade
    4: (8, 44, 22),    # hair
    5: (22, 60, 36),   # hair light
    6: (6, 36, 18),    # dress dark
    7: (14, 50, 28),   # dress
    8: (60, 62, 62),   # white
    9: (8, 12, 24),    # eyes
    10: (24, 56, 63),  # eye shine / blue
    11: (63, 38, 42),  # blush
    12: (44, 14, 18),  # mouth
    13: (10, 12, 18),  # shoes
    14: (62, 56, 12),  # yellow
    15: (10, 40, 62),  # blue
}

# Head drawn once (rows 0..14), '.' = transparent
HEAD = [
    "......111111111111......",
    "....1144455555544411....",
    "...144555555555555441...",
    "..14455544444444555441..",
    ".1445541444444441455441.",
    ".1445412222222222145441.",
    "14454122222222222214544.",
    "1445412929222292922145441"[:24],
    "14541229a922229a9221454.",
    "1454122999222299922145 1".replace(" ", "1"),
    "1454.1b2222222222b21454.".replace(".", "1"),
    ".1441.122221c22221.1441.".replace(".", "1"),
    ".1441..1222222221..1441.",
    "..141...11222211...141..",
    "..141......11......141..",
]


def blank():
    return [["."] * W for _ in range(H)]


def put(g, x, y, c):
    if 0 <= x < W and 0 <= y < H:
        g[y][x] = c


def rect(g, x0, y0, x1, y1, c):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            put(g, x, y, c)


def arm(g, side, pose, dy):
    """side -1 left / +1 right; pose 'down', 'up', 'out'"""
    sx = 6 if side < 0 else 17          # shoulder x
    sy = 16 + dy
    if pose == "down":
        pts = [(sx + side * 1, sy + i) for i in range(5)]
    elif pose == "out":
        pts = [(sx + side * (1 + i), sy + i // 2) for i in range(5)]
    else:                               # up: out to the side, then up above the shoulder
        pts = [(sx + side * 1, sy), (sx + side * 2, sy - 1), (sx + side * 3, sy - 2),
               (sx + side * 4, sy - 3), (sx + side * 4, sy - 4), (sx + side * 4, sy - 5),
               (sx + side * 4, sy - 6)]
    for i, (x, y) in enumerate(pts):
        put(g, x, y, "2")
        put(g, x - side, y, "1" if pose == "down" else "2")
        if pose == "up":
            put(g, x + side, y, "1")    # outline on the outer side
    hx, hy = pts[-1]
    put(g, hx, hy, "3")                 # hand
    if pose == "up":
        put(g, hx, hy - 1, "3")
        put(g, hx - side, hy - 1, "3")


def body(g, dy, lean):
    # neck
    rect(g, 11, 15 + dy, 12, 15 + dy, "3")
    # dress: triangle widening down, rows 16..25
    for i, y in enumerate(range(16 + dy, 26 + dy)):
        half = 3 + i // 2
        cx = 11.5 + lean * (i / 9)
        x0, x1 = int(round(cx - half)), int(round(cx + half))
        for x in range(x0, x1 + 1):
            put(g, x, y, "7")
        put(g, x0, y, "1")
        put(g, x1, y, "1")
    # collar
    rect(g, 10, 16 + dy, 13, 16 + dy, "8")
    # badge: green circle with check (Sber-like colours, own drawing)
    for x, y in [(11, 18), (12, 18), (10, 19), (13, 19), (10, 20), (13, 20), (11, 21), (12, 21)]:
        put(g, x, y + dy, "e" if y < 20 else "f")
    put(g, 11, 20 + dy, "8")
    put(g, 12, 19 + dy, "8")
    # hem
    for x in range(5, 19):
        if g[25 + dy][x] == "7":
            put(g, x, 25 + dy, "6")


def legs(g, dy, pose):
    y0 = 26 + dy
    if pose == "together":
        lx, rx = [9, 10], [13, 14]
    elif pose == "left":
        lx, rx = [7, 8], [13, 14]
    else:
        lx, rx = [9, 10], [15, 16]
    for y in range(y0, 30):
        for x in lx + rx:
            put(g, x, y, "2")
    for x in lx + rx:
        put(g, x, 30, "d")
        put(g, x, 31, "d")
    put(g, lx[0] - 1, 31, "d")
    put(g, rx[-1] + 1, 31, "d")


def head(g, dy, dx, blink):
    for y, row in enumerate(HEAD):
        for x, c in enumerate(row[:W]):
            if c != ".":
                put(g, x + dx, y + dy, c)
    if blink:                           # closed eyes: a line
        for x in (8, 9, 10, 13, 14, 15):
            for y in (7, 8, 9):
                if g[y + dy][x + dx] in "9a":
                    put(g, x + dx, y + dy, "2")
        for x in (8, 9, 10, 13, 14, 15):
            put(g, x + dx, 8 + dy, "9")


def bow(g, dy, dx):
    # yellow ribbon on the left side of the head
    for x, y in [(3, 1), (4, 1), (3, 2), (4, 2), (5, 2), (6, 2), (3, 3), (4, 3), (7, 1), (8, 1), (7, 3), (8, 3)]:
        put(g, x + dx, y + dy, "e")
    put(g, 5 + dx, 2 + dy, "1")


def twin_tails(g, dy, swing):
    # tails hang from both sides of the head, swinging with the dance
    for i in range(8):
        y = 9 + i + dy
        off = (swing * i) // 4
        put(g, 0 + off - (1 if i > 3 else 0), y, "4")
        put(g, 1 + off - (1 if i > 3 else 0), y, "5")
        put(g, 23 + off + (1 if i > 3 else 0) - 1, y, "4")
        put(g, 22 + off + (1 if i > 3 else 0) - 1, y, "5")


def frame(kind):
    g = blank()
    if kind in ("idle", "blink"):
        twin_tails(g, 0, 0)
        legs(g, 0, "together")
        body(g, 0, 0)
        head(g, 0, 0, kind == "blink")
        bow(g, 0, 0)
        arm(g, -1, "down", 0)
        arm(g, +1, "down", 0)
    elif kind == "mid":
        twin_tails(g, 1, 0)
        legs(g, 0, "together")
        body(g, 1, 0)
        head(g, 1, 0, False)
        bow(g, 1, 0)
        arm(g, -1, "out", 1)
        arm(g, +1, "out", 1)
    elif kind == "left":
        twin_tails(g, 0, 2)
        legs(g, 0, "left")
        body(g, 0, -1)
        head(g, 0, -1, False)
        bow(g, 0, -1)
        arm(g, -1, "up", 0)
        arm(g, +1, "out", 0)
    else:
        twin_tails(g, 0, -2)
        legs(g, 0, "right")
        body(g, 0, 1)
        head(g, 0, 1, True)              # wink on the right step
        bow(g, 0, 1)
        arm(g, -1, "out", 0)
        arm(g, +1, "up", 0)
    return g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview")
    args = ap.parse_args()
    frames = [frame(k) for k in ("idle", "blink", "left", "mid", "right")]
    code = {".": 0, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9,
            "a": 10, "b": 11, "c": 12, "d": 13, "e": 14, "f": 15}
    with open(OUT, "w") as f:
        for g in frames:
            for row in g:
                f.write("".join(f"{code[c]:x}\n" for c in row))
    print(f"wrote {os.path.relpath(OUT)}")
    if args.preview:
        from PIL import Image
        s = 6
        img = Image.new("RGB", (len(frames) * (W + 4) * s, H * s), (8, 12, 30))
        for n, g in enumerate(frames):
            for y in range(H):
                for x in range(W):
                    c = code[g[y][x]]
                    if c:
                        r, gg, b = PAL[c]
                        for yy in range(s):
                            for xx in range(s):
                                img.putpixel(((n * (W + 4) + x) * s + xx, y * s + yy), (r * 4, gg * 4, b * 4))
        img.save(args.preview)
        print(f"preview {args.preview}")


if __name__ == "__main__":
    main()
