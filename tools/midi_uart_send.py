#!/usr/bin/env python3
"""Reference / test sender for the text MIDI protocol of the board
(src/rtl/midi_text_rx.sv, UART 115200 8N1, one command per line):

    ON <note> <velocity>\\n     OFF <note>\\n     OFF\\n (all notes off)

The board also understands str(msg) from mido ("note_on channel=0 note=60
velocity=100 time=0") and bare "60 100" / "60 0", so your own program may
send any of these.

Works on Windows, Linux, macOS:
    pip install pyserial mido python-rtmidi

    python midi_uart_send.py --list                     # COM ports and MIDI inputs
    python midi_uart_send.py --port COM5 --scale        # play a scale, no keyboard needed
    python midi_uart_send.py --port COM5 --midi auto    # MIDI keyboard -> board
    python midi_uart_send.py --port COM5 --line "ON 60 100"

On Windows the board is "USB Serial Port (COMx)" in Device Manager.
"""
import argparse
import sys
import time

BAUD = 115200


def open_port(name):
    import serial
    return serial.Serial(name, BAUD, timeout=0.1)


def send(ser, line, echo=True):
    ser.write((line + "\n").encode("ascii"))
    if echo:
        print(line)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="serial port: COM5, /dev/ttyUSB1 ...")
    ap.add_argument("--list", action="store_true", help="show serial ports and MIDI inputs")
    ap.add_argument("--scale", action="store_true", help="play C major scale and a chord")
    ap.add_argument("--midi", metavar="NAME", help="MIDI input name or 'auto'")
    ap.add_argument("--line", help="send one line as is")
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
        if args.scale:
            for n in (60, 62, 64, 65, 67, 69, 71, 72):
                send(ser, f"ON {n} 100")
                time.sleep(0.3)
                send(ser, f"OFF {n}")
            for n in (60, 64, 67):                     # chord: 3 voices at once
                send(ser, f"ON {n} 100")
            time.sleep(1.0)
            send(ser, "OFF")
        if args.midi:
            import mido
            names = mido.get_input_names()
            if not names:
                sys.exit("no MIDI inputs found")
            name = next((n for n in names if "Through" not in n), names[0]) if args.midi == "auto" else args.midi
            print(f"MIDI: {name}, Ctrl+C to stop")
            with mido.open_input(name) as inp:
                for msg in inp:
                    if msg.type == "note_on" and msg.velocity > 0:
                        send(ser, f"ON {msg.note} {msg.velocity}")
                    elif msg.type in ("note_on", "note_off"):
                        send(ser, f"OFF {msg.note}")
                    elif msg.type == "control_change" and msg.control in (120, 123):
                        send(ser, "OFF")
    except KeyboardInterrupt:
        pass
    finally:
        send(ser, "OFF", echo=False)
        ser.close()


if __name__ == "__main__":
    main()
