#!/usr/bin/env python3
"""PC side of the player: streams audio and MIDI to the Nexys A7 over USB-UART.

  * any audio file (MP3, WAV, FLAC ...) is decoded by ffmpeg to 8-bit 48 kHz
    mono and sent as it is played (track 6 "Поток с ПК" on the board)
  * a MIDI keyboard connected to the laptop plays the synth on the board,
    on top of any track
  * the file name is shown in the playlist on the screen

Install:
    sudo apt install ffmpeg            (macOS: brew install ffmpeg)
    pip install pyserial mido python-rtmidi

Examples:
    python3 tools/pc_player.py --list                    # serial ports and MIDI inputs
    python3 tools/pc_player.py song.mp3                  # stream a file
    python3 tools/pc_player.py song.mp3 --midi auto      # file + MIDI keyboard
    python3 tools/pc_player.py --midi auto               # only the keyboard
    python3 tools/pc_player.py song.mp3 --port /dev/ttyUSB1 --loop

The board's USB cable carries both JTAG and UART: the UART is usually the
second port (/dev/ttyUSB1 on Linux, /dev/tty.usbserial-*1 on macOS).
Protocol: see src/rtl/pc_link.sv.
"""
import argparse
import os
import shutil
import subprocess
import sys
import threading
import time

BAUD = 921600
CREDIT_BYTE = 0xC1
CREDIT_SIZE = 255

T_AUDIO, T_MIDI, T_TITLE, T_ALL_OFF, T_HELLO = 1, 2, 3, 4, 5


def packet(ptype, payload=b""):
    assert len(payload) <= 255
    return bytes([0xA5, ptype, len(payload)]) + bytes(payload)


def find_port():
    from serial.tools import list_ports
    ports = sorted(list_ports.comports(), key=lambda p: p.device)
    digilent = [p for p in ports if p.vid == 0x0403 or "Digilent" in (p.manufacturer or "")
                or "usbserial" in p.device or "ttyUSB" in p.device]
    if not digilent:
        sys.exit("board not found: pass --port (see --list)")
    # FT2232: interface 0 = JTAG, interface 1 = UART -> take the last one
    return digilent[-1].device


def title_bytes(name):
    text = os.path.splitext(os.path.basename(name))[0]
    return text.encode("cp866", errors="replace")[:18]


class Link:
    def __init__(self, port):
        import serial
        self.ser = serial.Serial(port, BAUD, timeout=0.05)
        self.lock = threading.Lock()
        self.credits = 0
        self.cv = threading.Condition()
        self.alive = True
        threading.Thread(target=self._reader, daemon=True).start()
        self.send(packet(T_HELLO))

    def _reader(self):
        while self.alive:
            data = self.ser.read(64)
            n = data.count(CREDIT_BYTE)
            if n:
                with self.cv:
                    self.credits += n
                    self.cv.notify_all()

    def send(self, data):
        with self.lock:
            self.ser.write(data)

    def send_audio(self, chunk):
        """chunk <= 255 bytes, waits for a credit"""
        with self.cv:
            while self.credits == 0 and self.alive:
                self.cv.wait(0.5)
            self.credits -= 1
        self.send(packet(T_AUDIO, chunk))

    def close(self):
        self.send(packet(T_ALL_OFF))
        time.sleep(0.05)
        self.alive = False
        self.ser.close()


def stream_file(link, path, loop):
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg not found: sudo apt install ffmpeg")
    link.send(packet(T_TITLE, title_bytes(path)))
    while True:
        proc = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", "48000", "-f", "u8", "-"],
            stdout=subprocess.PIPE)
        sent, t0 = 0, time.time()
        while True:
            chunk = proc.stdout.read(CREDIT_SIZE)
            if not chunk:
                break
            link.send_audio(chunk)
            sent += len(chunk)
            if sent % (48000 * 5) < CREDIT_SIZE:
                print(f"\r{sent / 48000:6.1f} s   ", end="", flush=True)
        proc.wait()
        print(f"\rdone, {sent / 48000:.1f} s of audio in {time.time() - t0:.1f} s")
        if not loop:
            break


def midi_thread(link, name):
    import mido
    names = mido.get_input_names()
    if not names:
        print("no MIDI inputs found")
        return
    if name == "auto":
        name = next((n for n in names if "Through" not in n), names[0])
    print(f"MIDI: {name}")
    with mido.open_input(name) as inp:
        for msg in inp:
            if msg.type in ("note_on", "note_off"):
                link.send(packet(T_MIDI, msg.bytes()[:3]))
            elif msg.type == "control_change" and msg.control in (120, 123):
                link.send(packet(T_ALL_OFF))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", nargs="?", help="audio file to stream (any format ffmpeg reads)")
    ap.add_argument("--port", help="serial port of the board (default: auto)")
    ap.add_argument("--midi", metavar="NAME", help="MIDI input name or 'auto'")
    ap.add_argument("--loop", action="store_true", help="repeat the file")
    ap.add_argument("--list", action="store_true", help="show serial ports and MIDI inputs")
    args = ap.parse_args()

    if args.list:
        from serial.tools import list_ports
        for p in list_ports.comports():
            print(f"serial: {p.device:28s} {p.description}")
        try:
            import mido
            for n in mido.get_input_names():
                print(f"midi:   {n}")
        except ImportError:
            print("midi:   (pip install mido python-rtmidi)")
        return

    if not args.file and not args.midi:
        ap.error("give a file and/or --midi")

    link = Link(args.port or find_port())
    print(f"port {link.ser.port}, {BAUD} baud")
    try:
        if args.midi:
            t = threading.Thread(target=midi_thread, args=(link, args.midi), daemon=True)
            t.start()
        if args.file:
            stream_file(link, args.file, args.loop)
            if args.midi:
                print("file done, MIDI still active, Ctrl+C to quit")
        if args.midi:
            while True:
                time.sleep(1)
    except KeyboardInterrupt:
        print()
    finally:
        link.close()


if __name__ == "__main__":
    main()
