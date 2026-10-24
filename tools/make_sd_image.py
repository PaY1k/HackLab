#!/usr/bin/env python3
"""Build a small FAT32 card image for the sd_player testbench (src/tb/tb_sd_player.sv).

The image is tiny (not a valid FAT32 for an OS - too few clusters) but has
everything the player reads: MBR with a FAT32 partition, boot sector, two
FATs, a root directory with junk entries (long name, deleted file, a text file,
a folder) and two WAV files:

  TONE1.WAV  16 bit mono 48 kHz, 1000 Hz, 1.2 s, LIST chunk before "data",
             clusters not contiguous (the FAT chain must be followed)
  CHORD.WAV  8 bit stereo 22050 Hz, 0.1 s

Writes:  <out>.mem       one byte per line, for $readmemh in the SD card model
         <out>_f0.txt    expected FIFO samples of TONE1 (signed 16, one per line)
         <out>_f1.txt    expected FIFO samples of CHORD

Usage:  python3 tools/make_sd_image.py /tmp/sd
"""
import math
import struct
import sys

SECTOR = 512
PART = 8               # partition start LBA
RSV = 32               # reserved sectors
FATSZ = 8              # sectors per FAT (1024 clusters)
SPC = 1                # sectors per cluster
TOTAL = 2048           # sectors in the image (1 MiB)
DATA = PART + RSV + 2 * FATSZ


def wav(samples, rate, bits, channels, extra_chunk=b""):
    if bits == 16:
        data = b"".join(struct.pack("<h", s) for s in samples)
    else:
        data = bytes(samples)
    fmt = struct.pack("<HHIIHH", 1, channels, rate, rate * channels * bits // 8, channels * bits // 8, bits)
    body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + extra_chunk + b"data" + struct.pack("<I", len(data)) + data
    return b"RIFF" + struct.pack("<I", len(body)) + body


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "sd"
    img = bytearray(TOTAL * SECTOR)

    # MBR: one partition, type 0x0C (FAT32 LBA)
    img[0x1BE + 4] = 0x0C
    struct.pack_into("<II", img, 0x1BE + 8, PART, TOTAL - PART)
    img[510:512] = b"\x55\xAA"

    # boot sector
    b = PART * SECTOR
    img[b:b + 3] = b"\xEB\x58\x90"
    img[b + 3:b + 11] = b"MSWIN4.1"
    struct.pack_into("<HBHB", img, b + 11, SECTOR, SPC, RSV, 2)
    struct.pack_into("<I", img, b + 32, TOTAL - PART)
    struct.pack_into("<I", img, b + 36, FATSZ)
    struct.pack_into("<I", img, b + 44, 2)                    # root cluster
    img[b + 82:b + 90] = b"FAT32   "
    img[b + 510:b + 512] = b"\x55\xAA"

    fat = [0x0FFFFFF8, 0x0FFFFFFF] + [0] * (FATSZ * 128 - 2)
    fat[2] = 0x0FFFFFFF                                        # root dir: one cluster
    next_free = [3]

    def alloc(n, gap=0):
        """n clusters; with gap > 0 every cluster is followed by `gap` unused ones"""
        cl = []
        for _ in range(n):
            cl.append(next_free[0])
            next_free[0] += 1 + gap
        for a, c in zip(cl, cl[1:]):
            fat[a] = c
        fat[cl[-1]] = 0x0FFFFFFF
        return cl

    def put(data, clusters):
        for i, c in enumerate(clusters):
            off = (DATA + (c - 2) * SPC) * SECTOR
            chunk = data[i * SPC * SECTOR:(i + 1) * SPC * SECTOR]
            img[off:off + len(chunk)] = chunk

    # TONE1: 1000 Hz, 16 bit mono 48 kHz, with a LIST chunk (odd size -> pad byte)
    n0 = int(48000 * 1.2)
    s0 = [int(round(12000 * math.sin(2 * math.pi * 1000 * i / 48000))) for i in range(n0)]
    lst = b"LIST" + struct.pack("<I", 7) + b"INFOabc" + b"\x00"
    f0 = wav(s0, 48000, 16, 1, lst)
    c0 = alloc((len(f0) + SECTOR * SPC - 1) // (SECTOR * SPC), gap=1)
    put(f0, c0)

    # CHORD: 8 bit stereo 22050 Hz, left 440 Hz, right 660 Hz
    n1 = int(22050 * 0.1)
    s1 = []
    for i in range(n1):
        s1.append(128 + int(round(60 * math.sin(2 * math.pi * 440 * i / 22050))))
        s1.append(128 + int(round(60 * math.sin(2 * math.pi * 660 * i / 22050))))
    f1 = wav(s1, 22050, 8, 2)
    c1 = alloc((len(f1) + SECTOR * SPC - 1) // (SECTOR * SPC))
    put(f1, c1)
    assert next_free[0] < FATSZ * 128 and DATA + next_free[0] < TOTAL

    def entry(name83, attr, clus, size):
        return name83.encode() + bytes([attr]) + bytes(8) + struct.pack("<H", clus >> 16) + bytes(4) + \
            struct.pack("<HI", clus & 0xFFFF, size)

    root = b""
    root += entry("HACKLAB    ", 0x08, 0, 0)                    # volume label
    root += bytes([0x41]) + "Long".encode("utf-16-le") + b"\x00" * 2 + bytes([0x0F]) + bytes(20)  # LFN (junk)
    root += b"\xE5" + entry("OLD     WAV", 0x20, 5, 100)[1:]      # deleted
    root += entry("README  TXT", 0x20, 0, 0)
    root += entry("MUSIC      ", 0x10, 0, 0)                    # folder
    root += entry("TONE1   WAV", 0x20, c0[0], len(f0))
    root += entry("CHORD   WAV", 0x20, c1[0], len(f1))
    assert len(root) % 32 == 0
    put(root, [2])

    for k in range(2):
        off = (PART + RSV + k * FATSZ) * SECTOR
        for i, v in enumerate(fat):
            struct.pack_into("<I", img, off + 4 * i, v)

    with open(out + ".mem", "w") as f:
        f.write("".join(f"{x:02x}\n" for x in img))
    with open(out + "_f0.txt", "w") as f:
        f.write("".join(f"{x}\n" for x in s0))
    with open(out + "_f1.txt", "w") as f:
        mono = [((((l - 128) << 8) + ((r - 128) << 8)) >> 1) for l, r in zip(s1[::2], s1[1::2])]
        f.write("".join(f"{x}\n" for x in mono))
    print(f"{out}.mem: {TOTAL} sectors; TONE1 {len(f0)} B in {len(c0)} clusters, CHORD {len(f1)} B")


if __name__ == "__main__":
    main()
