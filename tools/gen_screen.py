#!/usr/bin/env python3
"""Generate the static text layer of vga_ui: src/rtl/mem/screen_text.mem

The screen is a grid of 8x16 cells: 100 columns x 40 rows (800x600 visible
-> rows 0..36). Each cell is 12 bits: {attr[3:0], char[7:0]}, char in CP866
(see gen_font.py), attr = text color index (palette in vga_ui.sv):
  0 white   1 grey   2 dim   3 green   4 cyan   5 yellow   6 red   7 dark
Address = row * 128 + col  (5120 words).

Cells that vga_ui rewrites every frame (do not put static text there):
  row 1,  col 84..94  play / pause status
  row 30, col 26..27  note + octave       ("C4")
  row 30, col 70..71  volume              ("08")
  row 33, col 92..96  track length        ("05:00" / "--:--")

Usage:  python3 tools/gen_screen.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "src", "rtl", "mem", "screen_text.mem")

ROWS, STRIDE = 40, 128
WHITE, GREY, DIM, GREEN, CYAN, YELLOW, RED, DARK = range(8)

NOTE, PLAY, PAUSE, SPEAKER, DOT, RIGHT, LEFT = "\x01\x02\x03\x04\x05\x06\x07"

# (row, col, text, color)
TEXT = [
    # header
    (1, 3,  NOTE + " SBER AUDIO", GREEN),
    (1, 16, "· плеер на ПЛИС Nexys A7", GREY),
    (1, 62, "ИСТОЧНИК: СИНТЕЗ", DIM),
    # playlist panel (items: rows 6, 8, ... 16, highlighted by track index)
    (4, 4,  "ПЛЕЙЛИСТ", GREY),
    (6, 5,  "01  Синтезатор нот", GREY),
    (8, 5,  "02  Мелодия из BRAM", GREY),
    (10, 5, "03  WAV с SD-карты", GREY),
    (12, 5, "04  MIDI-клавиатура", GREY),
    (14, 5, "05  Поток с ПК", GREY),
    (16, 5, "06  Свободно", DIM),
    (19, 4, LEFT + " " + RIGHT + "  нота", DIM),
    (20, 4, "SW[2:0] октава", DIM),
    # scope panel
    (4, 35, "ОСЦИЛЛОГРАФ", GREY),
    (4, 82, "48 кГц · ШИМ", DIM),
    # bottom panel
    (29, 4,  "СЕЙЧАС ИГРАЕТ", DIM),
    (30, 4,  "Синтезатор нот · нота", WHITE),
    (29, 70, "ГРОМКОСТЬ", DIM),
    (30, 72, "/15", DIM),
    (33, 90, "/", DIM),
]


def main():
    cells = [0x020] * (ROWS * STRIDE)          # space, white
    for row, col, text, color in TEXT:
        data = text.encode("cp866")
        assert col + len(data) <= 100, f"row {row}: '{text}' does not fit"
        for i, code in enumerate(data):
            cells[row * STRIDE + col + i] = (color << 8) | code
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write("".join(f"{c:03x}\n" for c in cells))
    print(f"wrote {os.path.relpath(OUT)}")


if __name__ == "__main__":
    main()
