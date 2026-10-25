"""Shared USB-UART packet protocol for audio, MIDI and synth settings."""
BAUD = 921600
HELLO_ACK = 0xC2
CREDIT_BYTE = 0xC1
CREDIT_SIZE = 255
T_AUDIO, T_MIDI, T_TITLE, T_ALL_OFF, T_HELLO, T_TEXT = range(1, 7)


def packet(ptype, payload=b""):
    payload = bytes(payload)
    if len(payload) > 255:
        raise ValueError("packet payload must fit in 255 bytes")
    return bytes([0xA5, ptype, len(payload)]) + payload


def text_packet(line):
    return packet(T_TEXT, (line.rstrip("\r\n") + "\n").encode("ascii"))


def midi_packet(msg):
    if msg.type in ("note_on", "note_off"):
        return packet(T_MIDI, msg.bytes()[:3])
    if msg.type == "pitchwheel":
        return text_packet(f"BEND {msg.pitch}")
    if msg.type == "control_change":
        if msg.control in (120, 123):
            return packet(T_ALL_OFF)
        return text_packet(f"CC {msg.control} {msg.value}")
    return None
