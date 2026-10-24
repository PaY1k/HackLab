#!/usr/bin/env python3
"""Convert a frame dumped by src/tb/tb_vga_ui.sv (lines "x y RGB",
RGB = 3 hex digits, 4 bits each) to a PNG.

Usage:  python3 tools/frame_to_png.py frame.txt frame.png
"""
import sys

from PIL import Image


def main():
    src, dst = sys.argv[1], sys.argv[2]
    img = Image.new("RGB", (800, 600), (255, 0, 255))      # magenta = pixel not written
    with open(src) as f:
        for line in f:
            parts = line.split()
            if len(parts) != 3:
                continue
            x, y, c = int(parts[0]), int(parts[1]), parts[2]
            if x < 800 and y < 600:
                img.putpixel((x, y), (255, 0, 255) if "x" in c else tuple(int(d, 16) * 17 for d in c))
    img.save(dst)
    print(f"saved {dst}")


if __name__ == "__main__":
    main()
