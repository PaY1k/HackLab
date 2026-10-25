#!/usr/bin/env python3
"""MIDI and synth settings over the shared binary protocol, UART 921600 8N1.
Audio and keyboard together: use pc_player.py song.mp3 --midi auto.
The --line and --set commands are encapsulated in type-6 binary packets.

Works on Windows, Linux, macOS:
    pip install pyserial mido python-rtmidi

    python midi_uart_send.py --list                     # COM ports and MIDI inputs
    python midi_uart_send.py --port COM5 --scale        # play a scale, no keyboard needed
    python midi_uart_send.py --port COM5 --midi auto    # MIDI keyboard -> board
    python midi_uart_send.py --port COM5 --line "ON 60 100"
    python midi_uart_send.py --port COM5 --set "WAVE SAW" --set "ATTACK 6" --set "RELEASE 12"

Synth settings (also on the board: SW14 + buttons): WAVE SINE/TRI/SQUARE/SAW,
ATTACK, DECAY, SUSTAIN, RELEASE, VIBRATO 0..15, OCTAVE 0..4 (2 = normal), MVOL 0..15.
The keyboard's pitch bend and mod wheel (vibrato) are forwarded too.

On Windows the board is "USB Serial Port (COMx)" in Device Manager.
"""
import argparse
import sys
import time

from pc_protocol import BAUD, T_MIDI, T_ALL_OFF, packet, text_packet, midi_packet


def open_port(name):
    import serial
    return serial.Serial(name, BAUD, timeout=0.1)


def send(ser, line, echo=True):
    ser.write(text_packet(line))
    if echo:
        print(line)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="serial port: COM5, /dev/ttyUSB1 ...")
    ap.add_argument("--list", action="store_true", help="show serial ports and MIDI inputs")
    ap.add_argument("--scale", action="store_true", help="play C major scale and a chord")
    ap.add_argument("--midi", metavar="NAME", help="MIDI input name or 'auto'")
    ap.add_argument("--line", help="send one line as is")
    ap.add_argument("--set", action="append", default=[], metavar="'NAME VALUE'",
                    help="synth setting, e.g. --set 'WAVE SAW' --set 'ATTACK 6' (repeat)")
    args = ap.parse_args()

    if args.list:
        from serial.tools import list_ports
        for p in list_ports.comports():
            print(f"serial: {p.device:20s} {p.description}")
        try:
            import mido
            for n in mido.get_input_names():
                print(f"midi:   {n}")
        except ImportError:
            print("midi:   (pip install mido python-rtmidi)")
        return
    if not args.port:
        ap.error("--port is required (see --list)")

    ser = open_port(args.port)
    try:
        if args.line:
            send(ser, args.line)
        for item in args.set:
            send(ser, f"SET {item}")
            time.sleep(0.01)
        if args.scale:
            for n in (60, 62, 64, 65, 67, 69, 71, 72):
                ser.write(packet(T_MIDI, [0x90, n, 100]))
                time.sleep(0.3)
                ser.write(packet(T_MIDI, [0x80, n, 0]))
            for n in (60, 64, 67):                     # chord: 3 voices at once
                ser.write(packet(T_MIDI, [0x90, n, 100]))
            time.sleep(1.0)
            ser.write(packet(T_ALL_OFF))
        if args.midi:
            import mido
            names = mido.get_input_names()
            if not names:
                sys.exit("no MIDI inputs found")
            name = next((n for n in names if "Through" not in n), names[0]) if args.midi == "auto" else args.midi
            print(f"MIDI: {name}, Ctrl+C to stop")
            with mido.open_input(name) as inp:
                for msg in inp:
                    data = midi_packet(msg)
                    if data is not None:
                        ser.write(data)
    except KeyboardInterrupt:
        pass
    finally:
        ser.write(packet(T_ALL_OFF))
        ser.close()


if __name__ == "__main__":
    main()
