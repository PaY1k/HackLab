#!/usr/bin/env python3
"""Generate lookup tables for the audio path (src/rtl/mem/):

  sine1024.mem     1024 x 16-bit signed sine, one period
  note_inc.mem     128 x 32-bit DDS increments for MIDI notes 0..127
  melodies.mem     melody notes: {midi[6:0], duration[8:0]} per word,
                   duration in units of 5 ms, midi 0 = rest, word 0 = end
  melody_info.mem  per melody 4 words: start address, total units,
                   length mm:ss (BCD), 1024*65536/total (for the progress bar)
  strings.mem      CP866 text slots for the screen, 32 x 32 bytes

Sample rate: 49.15865 MHz / 1024 = 48006.5 Hz.

Melodies are public domain folk / classical tunes:
  Коробейники (Russian folk song, the "Tetris" theme)
  Ода к радости (L. van Beethoven, Symphony No. 9)

Usage:  python3 tools/gen_tables.py
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
MEM = os.path.join(HERE, "..", "src", "rtl", "mem")
FS = 49_158_650 / 1024
UNIT_MS = 5

# ---------------------------------------------------------------- melodies
NOTE = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}


def midi(name):
    """'E5' -> 76, 'R' -> 0 (rest)"""
    if name == "R":
        return 0
    return 12 * (int(name[-1]) + 1) + NOTE[name[:-1]]


def parse(text, quarter_ms):
    """'E5:q B4:e ...' -> [(midi, units)]; q quarter, e eighth, h half, w whole, '.' = dotted"""
    beats = {"w": 4, "h": 2, "q": 1, "e": 0.5, "s": 0.25}
    out = []
    for tok in text.split():
        name, dur = tok.split(":")
        b = beats[dur.rstrip(".")] * (1.5 if dur.endswith(".") else 1)
        out.append((midi(name), round(b * quarter_ms / UNIT_MS)))
    return out


KOROBEINIKI = parse("""
    E5:q B4:e C5:e D5:q C5:e B4:e A4:q A4:e C5:e E5:q D5:e C5:e
    B4:q. C5:e D5:q E5:q C5:q A4:q A4:q R:q
    R:e D5:q F5:e A5:q G5:e F5:e E5:q. C5:e E5:q D5:e C5:e
    B4:q B4:e C5:e D5:q E5:q C5:q A4:q A4:q R:q
    E5:h C5:h D5:h B4:h C5:h A4:h G#4:h B4:q R:q
    E5:h C5:h D5:h B4:h C5:q E5:q A5:h G#5:h R:h
""", quarter_ms=400)

ODE_TO_JOY = parse("""
    E5:q E5:q F5:q G5:q G5:q F5:q E5:q D5:q C5:q C5:q D5:q E5:q E5:q. D5:e D5:h
    E5:q E5:q F5:q G5:q G5:q F5:q E5:q D5:q C5:q C5:q D5:q E5:q D5:q. C5:e C5:h
    D5:q D5:q E5:q C5:q D5:q E5:e F5:e E5:q C5:q D5:q E5:e F5:e E5:q D5:q C5:q D5:q G4:h
    E5:q E5:q F5:q G5:q G5:q F5:q E5:q D5:q C5:q C5:q D5:q E5:q D5:q. C5:e C5:h R:h
""", quarter_ms=450)

MELODIES = [KOROBEINIKI, ODE_TO_JOY]

# ---------------------------------------------------------------- strings
# slot -> text (<= 32 chars), used by screen_text_ctrl.sv
STRINGS = [
    "Синтезатор нот · нота ",   # 0  (+ note and octave)
    "Коробейники",               # 1
    "Ода к радости",             # 2
    "SD: нет карты",             # 3
    "SD: нет файла",             # 4
    "Поток с ПК",                # 5
    "СИНТЕЗ",                    # 6  source names, header
    "BRAM",                      # 7
    "SD-КАРТА",                  # 8
    "ПК / UART",                 # 9
    "SD: читаю карту...",        # 10
    "SD: ошибка формата",        # 11
    "СИНТЕЗАТОР ДЛЯ MIDI",       # 12 menu title
    "Волна",                     # 13 menu items (synth_settings.sv order)
    "Атака",                     # 14
    "Спад",                      # 15
    "Сустейн",                   # 16
    "Затухание",                 # 17
    "Вибрато",                   # 18
    "Октава",                    # 19
    "Громкость",                 # 20
    "СИНУС",                     # 21 wave names
    "ТРЕУГОЛЬНИК",               # 22
    "МЕАНДР",                    # 23
    "ПИЛА",                      # 24
    "BTNU/D выбор  BTNL/R знач.",  # 25 menu hint
]


def write(name, words, digits):
    path = os.path.join(MEM, name)
    with open(path, "w") as f:
        f.write("".join(f"{w:0{digits}x}\n" for w in words))
    print(f"wrote {os.path.relpath(path)} ({len(words)} words)")


def bcd_time(seconds):
    m, s = divmod(int(round(seconds)), 60)
    m = min(m, 99)
    return (m // 10) << 12 | (m % 10) << 8 | (s // 10) << 4 | (s % 10)


def main():
    os.makedirs(MEM, exist_ok=True)

    sine = [round(32767 * math.sin(2 * math.pi * i / 1024)) & 0xFFFF for i in range(1024)]
    write("sine1024.mem", sine, 4)

    inc = []
    for n in range(128):
        f = 440.0 * 2 ** ((n - 69) / 12)
        inc.append(min(round(f * 2 ** 32 / FS), 0xFFFFFFFF))
    write("note_inc.mem", inc, 8)

    words, info = [], []
    for mel in MELODIES:
        start = len(words)
        total = 0
        for note, units in mel:
            assert 0 < units < 512, units
            words.append(note << 9 | units)
            total += units
        words.append(0)                                   # end -> loop
        info += [start, total, bcd_time(total * UNIT_MS / 1000), round(1024 * 65536 / total)]
        assert info[-1] < 65536
    assert len(words) <= 1024
    write("melodies.mem", words + [0] * (1024 - len(words)), 4)
    write("melody_info.mem", info, 4)

    data = []
    for s in STRINGS:
        b = s.encode("cp866")
        assert len(b) <= 32, s
        data += list(b) + [0x20] * (32 - len(b))
    assert len(data) <= 1024
    write("strings.mem", data + [0x20] * (1024 - len(data)), 2)


if __name__ == "__main__":
    main()
