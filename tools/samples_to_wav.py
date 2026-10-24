#!/usr/bin/env python3
"""Turn output samples from a testbench (one unsigned 16-bit number per line,
48 kHz) into a WAV file, and print the pitch of a few windows.

Usage:  python3 tools/samples_to_wav.py samples.txt out.wav [window_ms]
"""
import math
import struct
import sys
import wave

FS = 48006


def pitch(sig):
    """Frequency by counting upward zero crossings (interpolated)."""
    mean = sum(sig) / len(sig)
    s = [x - mean for x in sig]
    cross = []
    for i in range(1, len(s)):
        if s[i - 1] < 0 <= s[i]:
            cross.append(i - 1 + (-s[i - 1]) / (s[i] - s[i - 1]))
    if len(cross) < 3:
        return 0.0
    return FS * (len(cross) - 1) / (cross[-1] - cross[0])


def note_name(f):
    if f <= 0:
        return "-"
    n = round(69 + 12 * math.log2(f / 440))
    return "C C# D D# E F F# G G# A A# B".split()[n % 12] + str(n // 12 - 1)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    win = int(FS * (float(sys.argv[3]) if len(sys.argv) > 3 else 100) / 1000)
    samples = [int(x) - 32768 for x in open(src).read().split()]
    with wave.open(dst, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(FS)
        w.writeframes(struct.pack(f"<{len(samples)}h", *samples))
    print(f"{dst}: {len(samples)} samples, {len(samples) / FS:.2f} s")
    for i in range(0, len(samples) - win + 1, win):
        part = samples[i:i + win]
        peak = max(abs(x) for x in part)
        f = pitch(part) if peak > 200 else 0
        print(f"  {i / FS:6.2f} s  peak {peak:5d}  {f:7.1f} Hz  {note_name(f)}")


if __name__ == "__main__":
    main()
