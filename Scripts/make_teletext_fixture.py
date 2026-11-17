#!/usr/bin/env python3
"""Writes a DVB transport stream with Teletext subtitles: a video (ffmpeg's
transport stream of the video given, on PID 0x100 with its PMT on 0x1000)
and, on PID 0x101, Teletext subtitle page 888 (EBU Teletext in DVB, ETSI EN
300 472 / EN 300 706) showing one line from the first picture on, sent again
every half second. The PMT is replaced by one that also names the Teletext
stream with its descriptor (0x56: English, a subtitle page, 888).

    make_teletext_fixture.py <video.ts from ffmpeg> <out.ts> <line>

Used by Scripts/make_video_fixtures.sh (teletext.ts for TeletextTests).
FFmpeg can read Teletext but not write it, hence this.
"""
import sys

VIDEO_PID, TELETEXT_PID, PMT_PID = 0x100, 0x101, 0x1000
MAGAZINE, PAGE = 8, 0x88          # page 888


def crc32_mpeg(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) if crc & 0x80000000 else crc << 1
            crc &= 0xFFFFFFFF
    return crc


def reverse(byte):
    """The byte's bits in the other order: DVB carries Teletext bytes as
    they come off the line, least significant bit first."""
    return int(f"{byte:08b}"[::-1], 2)


# Hamming 8/4 (EN 300 706, 8.2) of each nibble, as the byte arrives in DVB
HAMMING = [0x15, 0x02, 0x49, 0x5E, 0x64, 0x73, 0x38, 0x2F, 0xD0, 0xC7, 0x8C, 0x9B, 0xA1, 0xB6, 0xFD, 0xEA]


def hamming(nibble):
    return reverse(HAMMING[nibble])


def text_byte(char):
    """A character with odd parity (EN 300 706, 8.1), as DVB carries it."""
    code = ord(char) & 0x7F
    if bin(code).count("1") % 2 == 0:
        code |= 0x80
    return reverse(code)


def address(row):
    """The magazine and packet address (MRAG, EN 300 706, 7.1.2): two
    Hamming bytes, magazine bits 1 to 3 and the row's 5 bits."""
    value = (MAGAZINE & 7) | (row << 3)
    return bytes([hamming(value & 0xF), hamming(value >> 4)])


def data_unit(row, payload):
    """One EBU Teletext subtitle data unit (EN 300 472, 4.3): id 0x03,
    length 44, field parity and line offset, the framing code, the address
    and 40 bytes."""
    assert len(payload) == 40
    return bytes([0x03, 0x2C, 0xE0 | 7, 0xE4]) + address(row) + payload


def header():
    """Packet X/0 of the page (EN 300 706, 9.3.1): page units and tens,
    subcodes, the control bits C4 (erase page), C6 (subtitle), C7
    (suppress header), national option 0 (English), and 32 characters."""
    units, tens = PAGE & 0xF, PAGE >> 4
    # Subcode S1 to S4 with C4 (erase page) in S2 and C5, C6 (subtitle) in
    # S4; then C7 (suppress header) to C10, C11 to C14
    s1, s2, s3, s4c5c6 = 0x0, 0x8, 0x0, 0x8
    c7c10, c11c14 = 0x1, 0x0
    fields = bytes(hamming(n) for n in (units, tens, s1, s2, s3, s4c5c6, c7c10, c11c14))
    return data_unit(0, fields + bytes(text_byte(" ") for _ in range(32)))


def row(number, line):
    """A row of the page: the line in a box (start box twice, end box),
    centred in its 40 characters."""
    text = "\x0b\x0b" + line + "\x0a\x0a"
    padded = text.center(40)
    return data_unit(number, bytes(text_byte(c) for c in padded))


def pes(pts, units):
    """A Teletext PES (EN 300 472, 4.2): private stream 1, a header of 45
    bytes with the PTS, data identifier 0x10, the data units, stuffing units
    to fill two transport packets (PES length N × 184 − 6)."""
    body = bytes([0x10]) + b"".join(units)
    while (45 + len(body)) % 184:
        body += bytes([0xFF, 0x2C]) + bytes([0xFF] * 44)
    assert (45 + len(body)) % 184 == 0
    stamp = bytes([0x21 | ((pts >> 29) & 0x0E), (pts >> 22) & 0xFF, 0x01 | ((pts >> 14) & 0xFE),
                   (pts >> 7) & 0xFF, 0x01 | ((pts << 1) & 0xFE)])
    header_data = stamp + bytes([0xFF] * 31)
    length = 3 + len(header_data) + len(body)
    return bytes([0, 0, 1, 0xBD, length >> 8, length & 0xFF, 0x85, 0x80, len(header_data)]) + header_data + body


def packets(pid, payload, counter):
    out = []
    for start in range(0, len(payload), 184):
        chunk = payload[start:start + 184]
        assert len(chunk) == 184
        out.append(bytes([0x47, (0x40 if start == 0 else 0) | (pid >> 8), pid & 0xFF, 0x10 | (counter & 0xF)]) + chunk)
        counter += 1
    return out, counter


def pmt_section():
    teletext = b"eng" + bytes([(0x02 << 3) | (MAGAZINE & 7), PAGE])
    streams = (bytes([0x1B, 0xE0 | (VIDEO_PID >> 8), VIDEO_PID & 0xFF, 0xF0, 0x00])
               + bytes([0x06, 0xE0 | (TELETEXT_PID >> 8), TELETEXT_PID & 0xFF, 0xF0, 2 + len(teletext), 0x56, len(teletext)])
               + teletext)
    body = bytes([0x00, 0x01, 0xC1, 0x00, 0x00, 0xE0 | (VIDEO_PID >> 8), VIDEO_PID & 0xFF, 0xF0, 0x00]) + streams
    section = bytes([0x02, 0xB0 | ((len(body) + 4) >> 8), (len(body) + 4) & 0xFF]) + body
    return section + crc32_mpeg(section).to_bytes(4, "big")


def pts_of(packet):
    """The PTS of a PES that starts in this packet, or None."""
    if not packet[1] & 0x40:
        return None
    at = 4
    if packet[3] & 0x20:
        at += 1 + packet[4]
    pes_header = packet[at:]
    if pes_header[:3] != b"\x00\x00\x01" or not pes_header[7] & 0x80:
        return None
    p = pes_header[9:14]
    return ((p[0] >> 1) & 7) << 30 | p[1] << 22 | (p[2] >> 1) << 15 | p[3] << 7 | p[4] >> 1


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    source, target, line = sys.argv[1:]
    data = open(source, "rb").read()
    assert len(data) % 188 == 0
    page = [header(), row(22, line)]
    pmt = pmt_section()
    out, counter, last = [], 0, None
    for i in range(0, len(data), 188):
        packet = data[i:i + 188]
        pid = ((packet[1] & 0x1F) << 8) | packet[2]
        if pid == PMT_PID and packet[1] & 0x40:
            packet = packet[:3] + bytes([0x10 | (packet[3] & 0x0F), 0]) + pmt + bytes([0xFF] * (183 - len(pmt)))
        if pid == VIDEO_PID:
            pts = pts_of(packet)
            if pts is not None and (last is None or pts - last >= 45000):
                more, counter = packets(TELETEXT_PID, pes(pts, page), counter)
                out += more
                last = pts
        out.append(packet)
    open(target, "wb").write(b"".join(out))


if __name__ == "__main__":
    main()
