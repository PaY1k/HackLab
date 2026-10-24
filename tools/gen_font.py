#!/usr/bin/env python3
"""Generate the 8x16 bitmap font for vga_ui: src/rtl/mem/font8x16.mem

Encoding is CP866 (DOS Cyrillic), so Russian text works on the screen:
  0x20-0x7E  ASCII
  0x80-0xAF  А-Я а-п
  0xE0-0xEF  р-я,  0xF0 Ё, 0xF1 ё,  0xFA · (middle dot)
  0x01-0x07  UI icons drawn below (note, play, pause, speaker, dot, arrows)

Glyphs are rasterized from DejaVu Sans Mono (free license, Bitstream Vera /
public domain changes), 13 px, threshold 96 - this size keeps Cyrillic readable
and the dots of Ё inside the 8x16 cell.

Output: 256 chars * 16 rows = 4096 lines, one hex byte per line,
line index = code * 16 + row, bit 7 = leftmost pixel. Read with $readmemh.

Usage:  python3 tools/gen_font.py [--font PATH] [--preview font.png]
Needs Pillow:  pip install pillow
"""
import argparse
import glob
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "src", "rtl", "mem", "font8x16.mem")

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",           # Ubuntu
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",                       # Arch
    "/Applications/LibreOffice.app/Contents/Resources/fonts/truetype/DejaVuSansMono.ttf",
    "/Library/Fonts/DejaVuSansMono.ttf",
    os.path.expanduser("~/Library/Fonts/DejaVuSansMono.ttf"),
]
# matplotlib ships DejaVu too
FONT_CANDIDATES += glob.glob("/usr/lib/python3*/*-packages/matplotlib/mpl-data/fonts/ttf/DejaVuSansMono.ttf")

SIZE, THRESHOLD = 13, 96

# 8x16 icons: '#' = pixel on. Exactly 16 rows of 8 chars.
ICONS = {
    0x01: [  # note
        "........", "........", "....##..", "....###.", "....#.##", "....#..#",
        "....#...", "....#...", "....#...", "..###...", ".####...", ".####...",
        "..##....", "........", "........", "........"],
    0x02: [  # play
        "........", "........", "........", ".#......", ".##.....", ".###....",
        ".####...", ".#####..", ".####...", ".###....", ".##.....", ".#......",
        "........", "........", "........", "........"],
    0x03: [  # pause
        "........", "........", "........", ".##..##.", ".##..##.", ".##..##.",
        ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.",
        "........", "........", "........", "........"],
    0x04: [  # speaker
        "........", "........", "........", ".....#..", "....##..", "...###..",
        "#####...", "#####.#.", "#####.#.", "#####...", "...###..", "....##..",
        ".....#..", "........", "........", "........"],
    0x05: [  # filled dot
        "........", "........", "........", "........", "........", "..####..",
        ".######.", ".######.", ".######.", ".######.", "..####..", "........",
        "........", "........", "........", "........"],
    0x06: [  # arrow right
        "........", "........", "........", "........", "....#...", "....##..",
        "#######.", "########", "#######.", "....##..", "....#...", "........",
        "........", "........", "........", "........"],
    0x07: [  # arrow left
        "........", "........", "........", "........", "...#....", "..##....",
        ".#######", "########", ".#######", "..##....", "...#....", "........",
        "........", "........", "........", "........"],
}


def find_font(path):
    for p in ([path] if path else []) + FONT_CANDIDATES:
        if p and os.path.isfile(p):
            return p
    sys.exit("DejaVuSansMono.ttf not found: pass it with --font "
             "(Ubuntu: sudo apt install fonts-dejavu-core)")


def render_char(font, ch):
    asc, _ = font.getmetrics()
    img = Image.new("L", (8, 16), 0)
    draw = ImageDraw.Draw(img)
    w = font.getlength(ch)
    draw.text(((8 - w) / 2, 13 - asc), ch, font=font, fill=255)
    rows = []
    for y in range(16):
        b = 0
        for x in range(8):
            if img.getpixel((x, y)) >= THRESHOLD:
                b |= 0x80 >> x
        rows.append(b)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--font", help="path to DejaVuSansMono.ttf")
    ap.add_argument("--preview", help="also save a PNG with all glyphs")
    args = ap.parse_args()

    font = ImageFont.truetype(find_font(args.font), SIZE)
    glyphs = [[0] * 16 for _ in range(256)]

    codes = list(range(0x20, 0x7F)) + list(range(0x80, 0xB0)) + list(range(0xE0, 0xF2)) + [0xFA]
    for code in codes:
        ch = bytes([code]).decode("cp866")
        glyphs[code] = render_char(font, ch)

    for code, pic in ICONS.items():
        assert len(pic) == 16 and all(len(r) == 8 for r in pic), hex(code)
        glyphs[code] = [int(r.replace("#", "1").replace(".", "0"), 2) for r in pic]

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write("".join(f"{b:02x}\n" for g in glyphs for b in g))
    print(f"wrote {os.path.relpath(OUT)}")

    if args.preview:
        img = Image.new("L", (16 * 10, 16 * 18), 0)
        for code, g in enumerate(glyphs):
            ox, oy = (code % 16) * 10, (code // 16) * 18
            for y, b in enumerate(g):
                for x in range(8):
                    if b & (0x80 >> x):
                        img.putpixel((ox + x, oy + y), 255)
        img.resize((img.width * 3, img.height * 3), Image.NEAREST).save(args.preview)
        print(f"preview {args.preview}")


if __name__ == "__main__":
    main()
